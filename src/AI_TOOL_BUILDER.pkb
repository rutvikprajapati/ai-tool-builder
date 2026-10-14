create or replace PACKAGE BODY ai_tool_builder AS

  ----------------------------------------------------------------------------
  -- Registry: remembers, for each tool built by build_tool, which function
  -- to call and in what parameter order. The model only sends a tool NAME
  -- and argument values, so generic_response_handler needs this lookup to
  -- turn that name back into a function call.
  --
  -- It is package state: it exists only in the database session that built
  -- the tools (see "Build tools in the same request" in the package spec).
  ----------------------------------------------------------------------------
  TYPE t_param_bind IS RECORD (
    param_name  VARCHAR2(128),  -- as in ALL_ARGUMENTS; used for the args_json key
    quoted_name VARCHAR2(130),  -- DBMS_ASSERT.ENQUOTE_NAME of param_name; used in the SQL text
    is_numeric  BOOLEAN,        -- exposed to the model as a number; bound as NUMBER
    is_boolean  BOOLEAN,        -- exposed to the model as a boolean; bound as 'Y'/'N' text
    temporal    VARCHAR2(4)     -- NULL, or 'DATE', 'TS' (TIMESTAMP) or 'TSTZ' (with time zone)
  );
  -- Parameters in call order (ALL_ARGUMENTS.position).
  TYPE t_param_binds IS TABLE OF t_param_bind INDEX BY PLS_INTEGER;

  TYPE t_registration IS RECORD (
    fq_name VARCHAR2(400),      -- "OWNER"."PKG"."FUNC", already validated and quoted
    params  t_param_binds
  );
  -- Keyed by tool name (the name the model sends back in a tool call).
  TYPE t_registry IS TABLE OF t_registration INDEX BY VARCHAR2(64);

  g_registry t_registry;

  ----------------------------------------------------------------------------
  -- Splits a function name into owner, package and function. Accepts:
  --   'FUNC'            standalone function in the current schema
  --   'PKG.FUNC'        packaged function in the current schema
  --   'OWNER.PKG.FUNC'  packaged function in another schema
  -- Parts are uppercased to match how Oracle stores unquoted names. A
  -- standalone function in another schema ('OWNER.FUNC') cannot be
  -- written: two parts are always read as PKG.FUNC.
  ----------------------------------------------------------------------------
  PROCEDURE parse_name(
    p_name  IN  VARCHAR2,
    p_owner OUT VARCHAR2,
    p_pkg   OUT VARCHAR2,
    p_func  OUT VARCHAR2
  ) IS
    l_dot1 PLS_INTEGER := INSTR(p_name, '.');
    l_dot2 PLS_INTEGER;
  BEGIN
    IF l_dot1 = 0 THEN
      p_owner := USER;
      p_pkg   := NULL;
      p_func  := UPPER(p_name);
      RETURN;
    END IF;

    l_dot2 := INSTR(p_name, '.', l_dot1 + 1);
    IF l_dot2 = 0 THEN
      p_owner := USER;
      p_pkg   := UPPER(SUBSTR(p_name, 1, l_dot1 - 1));
      p_func  := UPPER(SUBSTR(p_name, l_dot1 + 1));
    ELSE
      p_owner := UPPER(SUBSTR(p_name, 1, l_dot1 - 1));
      p_pkg   := UPPER(SUBSTR(p_name, l_dot1 + 1, l_dot2 - l_dot1 - 1));
      p_func  := UPPER(SUBSTR(p_name, l_dot2 + 1));
    END IF;
  END parse_name;

  ----------------------------------------------------------------------------
  -- TRUE for the ALL_ARGUMENTS data types that are exposed to the model as a
  -- number.
  ----------------------------------------------------------------------------
  FUNCTION is_numeric_type(p_data_type IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN p_data_type IN ('NUMBER', 'INTEGER', 'PLS_INTEGER', 'BINARY_INTEGER', 'FLOAT');
  END is_numeric_type;

  ----------------------------------------------------------------------------
  -- Which kind of date/time a parameter is, or NULL if it is not one.
  --   'DATE'  DATE
  --   'TS'    TIMESTAMP
  --   'TSTZ'  TIMESTAMP WITH TIME ZONE and TIMESTAMP WITH LOCAL TIME ZONE
  ----------------------------------------------------------------------------
  FUNCTION temporal_kind(p_data_type IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE
             WHEN p_data_type = 'DATE' THEN 'DATE'
             WHEN p_data_type = 'TIMESTAMP' THEN 'TS'
             WHEN p_data_type IN ('TIMESTAMP WITH TIME ZONE',
                                  'TIMESTAMP WITH LOCAL TIME ZONE') THEN 'TSTZ'
           END;
  END temporal_kind;

  ----------------------------------------------------------------------------
  -- Added to the end of a date/time parameter's description, so the model
  -- knows which format to send. Dates and timestamps travel as text.
  ----------------------------------------------------------------------------
  FUNCTION temporal_hint(p_kind IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_kind
             WHEN 'DATE' THEN ' (ISO 8601 date or date-time, e.g. 2027-03-14 or 2027-03-14T10:30:00)'
             WHEN 'TS'   THEN ' (ISO 8601 date-time, e.g. 2027-03-14T10:30:00)'
             WHEN 'TSTZ' THEN ' (ISO 8601 date-time with UTC offset, e.g. 2027-03-14T10:30:00+05:30)'
           END;
  END temporal_hint;

  ----------------------------------------------------------------------------
  -- Reads the text the model sent for a date/time parameter and returns it
  -- in one fixed format, which the generated call converts with an explicit
  -- mask. This is why the result never depends on NLS_DATE_FORMAT.
  --
  -- Accepted: YYYY-MM-DD, with an optional time (HH24:MI[:SS[.FF]]) after a
  -- space or an ISO 'T', and an optional UTC offset (+05:30 or Z). Without
  -- an offset, a time-zone parameter uses the session time zone.
  -- Raises ORA-20704 for anything else. The message reaches the model, so
  -- it says what to send instead.
  ----------------------------------------------------------------------------
  FUNCTION canonical_temporal(
    p_kind  IN VARCHAR2,
    p_param IN VARCHAR2,
    p_text  IN VARCHAR2
  ) RETURN VARCHAR2 IS
    TYPE t_masks IS VARRAY(7) OF VARCHAR2(40);
    c_masks CONSTANT t_masks := t_masks(
      'YYYY-MM-DD HH24:MI:SS.FFTZH:TZM',
      'YYYY-MM-DD HH24:MI:SSTZH:TZM',
      'YYYY-MM-DD HH24:MITZH:TZM',
      'YYYY-MM-DD HH24:MI:SS.FF',
      'YYYY-MM-DD HH24:MI:SS',
      'YYYY-MM-DD HH24:MI',
      'YYYY-MM-DD' );
    -- The shape the masks below are allowed to see. Oracle's masks are
    -- lenient (MM even accepts a month name), so the shape is checked first.
    c_shape CONSTANT VARCHAR2(100) :=
      '^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?$';
    l_txt VARCHAR2(100) := TRIM(SUBSTR(p_text, 1, 100));
    l_val TIMESTAMP(9) WITH TIME ZONE;
    l_ok  BOOLEAN := FALSE;
  BEGIN
    IF l_txt IS NULL THEN
      RETURN NULL;
    END IF;

    IF REGEXP_LIKE(l_txt, c_shape, 'i') THEN
      l_txt := REGEXP_REPLACE(l_txt, '^(\d{4}-\d{2}-\d{2})T', '\1 ', 1, 1, 'i');
      l_txt := REGEXP_REPLACE(l_txt, 'Z$', '+00:00', 1, 1, 'i');

      FOR i IN 1 .. c_masks.COUNT LOOP
        BEGIN
          l_val := TO_TIMESTAMP_TZ(l_txt, c_masks(i));
          l_ok  := TRUE;
          EXIT;
        EXCEPTION
          WHEN OTHERS THEN NULL; -- try the next shape
        END;
      END LOOP;
    END IF;

    IF NOT l_ok THEN
      RAISE_APPLICATION_ERROR(-20704,
        'Invalid date/time "' || SUBSTR(REPLACE(REPLACE(p_text, CHR(10), ' '), CHR(13), ' '), 1, 50) ||
        '" for parameter ' || LOWER(p_param) ||
        '. Send an ISO 8601 value, for example 2027-03-14 or 2027-03-14T10:30:00.');
    END IF;

    RETURN CASE p_kind
             WHEN 'DATE' THEN TO_CHAR(l_val, 'YYYY-MM-DD"T"HH24:MI:SS')
             WHEN 'TS'   THEN TO_CHAR(l_val, 'YYYY-MM-DD"T"HH24:MI:SS.FF9')
             ELSE             TO_CHAR(l_val, 'YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM')
           END;
  END canonical_temporal;

  ----------------------------------------------------------------------------
  -- Maps a parameter type to the type exposed to the model. Numeric types
  -- are sent as numbers. (An earlier version sent them as VARCHAR2 because a
  -- NUMBER-typed tool parameter raised ORA-20960 in apex_ai.generate against
  -- OCI Generative AI with meta.llama-3.3-70b-instruct, a deprecated model.)
  ----------------------------------------------------------------------------
  FUNCTION map_type(p_data_type IN VARCHAR2) RETURN apex_ai.t_tool_parameter_data_type IS
  BEGIN
    IF p_data_type = 'CLOB' THEN
      RETURN apex_ai.c_tool_param_type_clob;
    ELSIF p_data_type = 'BOOLEAN' THEN
      -- DBMS_SQL cannot bind a PL/SQL BOOLEAN before Oracle 23ai, so the
      -- handler binds 'Y'/'N' text and the generated call turns it back
      -- into a BOOLEAN with (:n = 'Y'). That works on every version.
      RETURN apex_ai.c_tool_param_type_boolean;
    ELSIF is_numeric_type(p_data_type) THEN
      RETURN apex_ai.c_tool_param_type_number;
    ELSE
      -- VARCHAR2, CHAR and anything else are described as text.
      RETURN apex_ai.c_tool_param_type_varchar2;
    END IF;
  END map_type;

  ----------------------------------------------------------------------------
  -- Returns the "--" comment block that documents FUNCTION <p_target_name>,
  -- or NULL if there is none. It reads the stored source (ALL_SOURCE) and
  -- looks in two places:
  --
  --   1. Directly ABOVE the declaration. This is the natural place and is
  --      what works for a function declared in a package specification.
  --   2. Directly AFTER the IS/AS that ends the declaration. This is the
  --      only place that works for a STANDALONE function: Oracle stores
  --      its source starting at the FUNCTION keyword, so anything written
  --      before it (including comments after CREATE OR REPLACE) is not
  --      kept, and there is nothing above the declaration to read.
  --
  -- p_src_name / p_src_type say which stored object holds the source: the
  -- PACKAGE (spec) for a packaged function, the FUNCTION itself otherwise.
  ----------------------------------------------------------------------------
  FUNCTION extract_doc_block(
    p_owner       IN VARCHAR2,
    p_src_name    IN VARCHAR2,
    p_src_type    IN VARCHAR2,
    p_target_name IN VARCHAR2
  ) RETURN CLOB IS
    TYPE t_lines IS TABLE OF all_source.text%TYPE INDEX BY PLS_INTEGER;
    l_lines    t_lines;
    l_decl_idx PLS_INTEGER;
    l_is_idx   PLS_INTEGER;
    l_block    CLOB;
  BEGIN
    SELECT text BULK COLLECT INTO l_lines
    FROM all_source
    WHERE owner = p_owner AND name = p_src_name AND type = p_src_type
    ORDER BY line;

    -- Find the line holding "FUNCTION <name> (". A package spec can declare
    -- many functions, so this locates the right one.
    FOR i IN 1 .. l_lines.COUNT LOOP
      IF REGEXP_LIKE(l_lines(i), 'FUNCTION\s+' || p_target_name || '\s*\(', 'i') THEN
        l_decl_idx := i;
        EXIT;
      END IF;
    END LOOP;

    IF l_decl_idx IS NULL THEN
      RETURN NULL;
    END IF;

    -- Placement 1: walk upward from the declaration, collecting comment
    -- lines (blank lines are skipped) and stopping at the first line of code.
    FOR i IN REVERSE 1 .. l_decl_idx - 1 LOOP
      IF REGEXP_LIKE(l_lines(i), '^\s*--') THEN
        l_block := l_lines(i) || l_block;
      ELSIF TRIM(l_lines(i)) IS NOT NULL THEN
        EXIT; -- real code above - no backward block here
      END IF;
    END LOOP;

    IF l_block IS NOT NULL THEN
      RETURN l_block;
    END IF;

    -- Placement 2: the declaration can span several lines, so find the line
    -- ending in IS/AS, then collect the comment lines right after it
    -- (up to the first declaration or BEGIN).
    FOR i IN l_decl_idx .. l_lines.COUNT LOOP
      IF REGEXP_LIKE(l_lines(i), '(^|\s)(IS|AS)\s*$', 'i') THEN
        l_is_idx := i;
        EXIT;
      END IF;
    END LOOP;

    IF l_is_idx IS NOT NULL THEN
      FOR i IN l_is_idx + 1 .. l_lines.COUNT LOOP
        IF REGEXP_LIKE(l_lines(i), '^\s*--') THEN
          l_block := l_block || l_lines(i);
        ELSIF TRIM(l_lines(i)) IS NOT NULL THEN
          EXIT; -- BEGIN or a real declare-section line
        END IF;
      END LOOP;
    END IF;

    RETURN l_block;
  END extract_doc_block;

  ----------------------------------------------------------------------------
  -- Reads the text after one tag in a comment block, e.g. for
  --   -- @param p_amount: The amount to convert
  -- tag_value(block, 'param\s+p_amount') returns 'The amount to convert'.
  -- p_tag_pattern is a regular expression; the value runs to end of line.
  -- Returns NULL if the tag is not present.
  ----------------------------------------------------------------------------
  FUNCTION tag_value(p_block IN CLOB, p_tag_pattern IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_block IS NULL THEN RETURN NULL; END IF;
    RETURN TRIM(REGEXP_SUBSTR(p_block, '--\s*@' || p_tag_pattern || '\s*:\s*([^' || CHR(10) || CHR(13) || ']*)',
                               1, 1, 'i', 1));
  END tag_value;

  ----------------------------------------------------------------------------
  -- Steps:
  --   1. Resolve and validate the function name (must exist, be a FUNCTION).
  --   2. Read the @tool / @param descriptions from the function's comments.
  --   3. Read the parameters from ALL_ARGUMENTS and describe each to the model.
  --   4. Register the function in g_registry so the handler can find it.
  --   5. Return the apex_ai.t_tool to pass in p_tools.
  ----------------------------------------------------------------------------
  FUNCTION build_tool(
    p_function_name IN VARCHAR2,
    p_tool_name     IN VARCHAR2 DEFAULT NULL
  ) RETURN apex_ai.t_tool IS
    l_owner     VARCHAR2(128);
    l_pkg       VARCHAR2(128);
    l_func      VARCHAR2(128);
    l_src_type  VARCHAR2(30);
    l_src_name  VARCHAR2(128);
    l_doc_block CLOB;
    l_tool_desc VARCHAR2(32767);
    l_params    apex_ai.t_tool_parameters := apex_ai.t_tool_parameters();
    l_name      VARCHAR2(64);
    l_reg       t_registration;
    l_found     PLS_INTEGER;
  BEGIN
    parse_name(p_function_name, l_owner, l_pkg, l_func);

    IF l_pkg IS NOT NULL THEN
      l_src_type := 'PACKAGE';
      l_src_name := l_pkg;
    ELSE
      l_src_type := 'FUNCTION';
      l_src_name := l_func;
    END IF;

    -- Must exist and be a FUNCTION (only functions have a position 0 row).
    SELECT COUNT(*)
      INTO l_found
      FROM all_arguments
     WHERE owner = l_owner
       AND object_name = l_func
       AND NVL(package_name, '~') = NVL(l_pkg, '~')
       AND data_level = 0
       AND position = 0
       AND ROWNUM = 1;
    IF l_found = 0 THEN
      RAISE_APPLICATION_ERROR(-20702,
        'ai_tool_builder: "' || SUBSTR(p_function_name, 1, 200) ||
        '" was not found, is not accessible, or is not a FUNCTION.');
    END IF;

    -- An overloaded function cannot be told apart here: the parameter query
    -- below and the handler's call by name both work on the name alone. Fail
    -- now instead of building a garbled tool. Each overload has one
    -- position = 0 (return value) row, so count the distinct overloads.
    SELECT COUNT(DISTINCT NVL(overload, '0'))
      INTO l_found
      FROM all_arguments
     WHERE owner = l_owner
       AND object_name = l_func
       AND NVL(package_name, '~') = NVL(l_pkg, '~')
       AND data_level = 0
       AND position = 0;
    IF l_found > 1 THEN
      RAISE_APPLICATION_ERROR(-20703,
        'ai_tool_builder: "' || SUBSTR(p_function_name, 1, 200) ||
        '" is overloaded (' || l_found || ' versions). Wrap each overload in ' ||
        'a function with a unique name and register the wrappers instead.');
    END IF;

    -- fq_name goes into the dynamic PL/SQL block the handler runs, so each
    -- part is validated and quoted here (ORA-44003 if invalid).
    l_reg.fq_name := DBMS_ASSERT.ENQUOTE_NAME(l_owner, FALSE) || '.'
                  || CASE WHEN l_pkg IS NOT NULL
                          THEN DBMS_ASSERT.ENQUOTE_NAME(l_pkg, FALSE) || '.' END
                  || DBMS_ASSERT.ENQUOTE_NAME(l_func, FALSE);

    -- After validation: extract_doc_block builds a regex from the name.
    l_doc_block := extract_doc_block(l_owner, l_src_name, l_src_type, l_func);
    l_tool_desc := tag_value(l_doc_block, 'tool');

    -- One row per IN parameter, in call order. position = 0 is the return
    -- value (skipped), data_level = 0 skips fields of record/collection
    -- types, and defaulted = 'Y' marks a parameter with a default value,
    -- which becomes optional for the model.
    FOR r IN (
      SELECT argument_name,
             data_type,
             defaulted
       FROM all_arguments
      WHERE owner = l_owner
        AND object_name = l_func
        AND NVL(package_name, '~') = NVL(l_pkg, '~')
        AND data_level = 0
        AND position > 0
        AND in_out = 'IN'
      ORDER BY position
    ) LOOP
      DECLARE
        l_pdesc VARCHAR2(4000) := tag_value(l_doc_block, 'param\s+' || LOWER(r.argument_name));
        l_kind  VARCHAR2(4)    := temporal_kind(r.data_type);
      BEGIN
        IF l_kind IS NOT NULL THEN
          l_pdesc := TRIM(l_pdesc || temporal_hint(l_kind));
        END IF;
        l_params.EXTEND;
        l_params(l_params.COUNT) := apex_ai.t_tool_parameter(
          name           => LOWER(r.argument_name),
          description    => l_pdesc,
          data_type      => map_type(r.data_type),
          is_required    => (r.defaulted = 'N'),
          allowed_values => NULL );

        l_reg.params(l_reg.params.COUNT + 1) := t_param_bind(
          param_name  => r.argument_name,
          quoted_name => DBMS_ASSERT.ENQUOTE_NAME(r.argument_name, FALSE),
          is_numeric  => is_numeric_type(r.data_type),
          is_boolean  => (r.data_type = 'BOOLEAN'),
          temporal    => l_kind );
      END;
    END LOOP;

    -- apex_ai accepts only lowercase letters, digits and underscores in a
    -- tool name (ORA-20950 otherwise). The default is the lowercased
    -- function name; pass p_tool_name to choose another. Building a tool
    -- with the same name again replaces the earlier registration.
    l_name := NVL(p_tool_name, LOWER(SUBSTR(l_func, 1, 64)));
    g_registry(l_name) := l_reg;

    RETURN apex_ai.t_tool(
      name                   => l_name,
      description            => NVL(l_tool_desc, 'Runs the "' || l_name || '" tool.'),
      parameters             => l_params,
      parameters_json_schema => NULL,
      callback_procedure     => NULL );
  END build_tool;

  ----------------------------------------------------------------------------
  FUNCTION build_tools(
    p_function_names IN apex_t_varchar2
  ) RETURN apex_ai.t_tools IS
    l_tools apex_ai.t_tools := apex_ai.t_tools();
  BEGIN
    FOR i IN 1 .. p_function_names.COUNT LOOP
      l_tools.EXTEND;
      l_tools(l_tools.COUNT) := build_tool(p_function_names(i));
    END LOOP;
    RETURN l_tools;
  END build_tools;

  ----------------------------------------------------------------------------
  -- Tools stay registered until the session ends or this is called. Call it
  -- before building a new tool list if tools from an earlier call should no
  -- longer be callable.
  ----------------------------------------------------------------------------
  PROCEDURE reset_registry IS
  BEGIN
    g_registry.DELETE;
  END reset_registry;

  ----------------------------------------------------------------------------
  -- Error text the model may see. Raw SQLERRM can contain object names, so
  -- only RAISE_APPLICATION_ERROR messages (-20000..-20999, written on
  -- purpose) are passed through; everything else is generic.
  ----------------------------------------------------------------------------
  FUNCTION model_error_text(
    p_tool_name IN VARCHAR2,
    p_code      IN PLS_INTEGER,
    p_msg       IN VARCHAR2
  ) RETURN VARCHAR2 IS
    l_text VARCHAR2(4000);
  BEGIN
    IF p_code BETWEEN -20999 AND -20000 THEN
      l_text := REGEXP_REPLACE(p_msg, '^ORA-[0-9]+:\s*', '');
      l_text := SUBSTR(l_text, 1, INSTR(l_text || CHR(10), CHR(10)) - 1);
      RETURN 'Error from tool "' || p_tool_name || '": ' || SUBSTR(l_text, 1, 500);
    ELSIF p_code IN (-6502, -1722, -1858, -1861) THEN
      RETURN 'Error: tool "' || p_tool_name || '" rejected an argument value '
          || '(wrong format or too long). Check the argument values and try again.';
    ELSE
      RETURN 'Error: tool "' || p_tool_name || '" failed. '
          || 'Do not retry with the same arguments.';
    END IF;
  END model_error_text;

  ----------------------------------------------------------------------------
  -- Called by apex_ai each time the model answers. If the answer asks for
  -- tools, then for each requested tool this:
  --   1. looks the tool name up in g_registry,
  --   2. builds a small PL/SQL block that calls the real function,
  --   3. binds the model's argument values and runs it,
  --   4. hands the result back with apex_ai.set_tool_result, so apex_ai can
  --      send it to the model and continue the conversation.
  -- If the answer is not a tool request, it does nothing.
  --
  -- DBMS_SQL is used instead of EXECUTE IMMEDIATE because the number of
  -- arguments differs per tool, and EXECUTE IMMEDIATE ... USING needs a
  -- fixed number of bind variables when the code is compiled.
  ----------------------------------------------------------------------------
  PROCEDURE generic_response_handler(
    p_param  IN              apex_ai.t_chat_response_handler_param,
    p_result IN OUT NOCOPY   apex_ai.t_chat_response_handler_result
  ) IS
    l_reg  t_registration;
    l_stmt VARCHAR2(32767);
    l_ret  VARCHAR2(32767);
    l_cur  PLS_INTEGER;
    l_rows PLS_INTEGER;
  BEGIN
    IF p_result.response.type = apex_ai.c_response_type_tool_calls THEN
      FOR i IN 1 .. p_param.pending_tool_calls.COUNT LOOP
        DECLARE
          l_call_name VARCHAR2(64)     := p_param.pending_tool_calls(i).name;
          l_err_code  PLS_INTEGER;
          l_err_msg   VARCHAR2(4000);
          l_err_trace VARCHAR2(4000);
          l_args      sys.json_object_t := p_param.pending_tool_calls(i).args_json;
          l_key       VARCHAR2(128);
          l_el        sys.json_element_t;
          l_txt       VARCHAR2(1);
        BEGIN
          IF NOT g_registry.EXISTS(l_call_name) THEN
            -- Usually: tools were built in a different request or session.
            apex_debug.warn(
              'ai_tool_builder: no function registered for tool "' || l_call_name ||
              '" (registry holds ' || g_registry.COUNT || ' tool(s)). ' ||
              'Build tools in the same request as apex_ai.generate/chat.' );
            apex_ai.set_tool_result(
              p_response_handler_param  => p_param,
              p_response_handler_result => p_result,
              p_tool_call               => p_param.pending_tool_calls(i),
              p_result                  => 'Error: no function registered for tool "' || l_call_name || '"' );
            CONTINUE;
          END IF;

          l_reg := g_registry(l_call_name);

          -- Builds, for a tool with two parameters:
          --   :ret := TO_CHAR("OWNER"."PKG"."FUNC"("P_A" => :1,"P_B" => :2));
          -- Parameters are passed by name, so their order does not matter.
          -- A BOOLEAN parameter is passed as ("P_FLAG" => (:2 = 'Y')): the
          -- bind holds 'Y'/'N' text and PL/SQL makes the BOOLEAN.
          -- A date/time parameter is passed as TO_DATE(:3, '<mask>') (or
          -- TO_TIMESTAMP / TO_TIMESTAMP_TZ). The bind holds the fixed-format
          -- text from canonical_temporal, so NLS settings are never used.
          -- TO_CHAR turns whatever the function returns into text for the
          -- model. Only validated identifiers and bind positions go into the
          -- SQL text; argument values are bound below.
          l_stmt := ':ret := TO_CHAR(' || l_reg.fq_name || '(';
          FOR p IN 1 .. l_reg.params.COUNT LOOP
            l_stmt := l_stmt || l_reg.params(p).quoted_name || ' => '
                   || CASE
                        WHEN l_reg.params(p).is_boolean
                          THEN '(:' || p || ' = ''Y'')'
                        WHEN l_reg.params(p).temporal = 'DATE'
                          THEN 'TO_DATE(:' || p || ', ''YYYY-MM-DD"T"HH24:MI:SS'')'
                        WHEN l_reg.params(p).temporal = 'TS'
                          THEN 'TO_TIMESTAMP(:' || p || ', ''YYYY-MM-DD"T"HH24:MI:SS.FF9'')'
                        WHEN l_reg.params(p).temporal = 'TSTZ'
                          THEN 'TO_TIMESTAMP_TZ(:' || p || ', ''YYYY-MM-DD"T"HH24:MI:SS.FF9TZH:TZM'')'
                        ELSE ':' || p
                      END;
            IF p < l_reg.params.COUNT THEN l_stmt := l_stmt || ','; END IF;
          END LOOP;
          l_stmt := l_stmt || '));';

          l_cur := DBMS_SQL.OPEN_CURSOR;
          BEGIN
            DBMS_SQL.PARSE(l_cur, 'BEGIN ' || l_stmt || ' END;', DBMS_SQL.NATIVE);

            FOR p IN 1 .. l_reg.params.COUNT LOOP
              -- The model's JSON keys are the lowercase names that build_tool
              -- exposed, hence LOWER(). A numeric parameter is bound as a
              -- NUMBER when the model sent a JSON number. If it sent a string
              -- instead (some models do), it is bound as text and Oracle
              -- converts it on the call. Text values are cut at 32767
              -- characters, the VARCHAR2 limit.
              l_key := LOWER(l_reg.params(p).param_name);
              l_el  := l_args.get(l_key);
              IF l_reg.params(p).is_numeric AND l_el IS NOT NULL AND l_el.is_number THEN
                DBMS_SQL.BIND_VARIABLE(l_cur, ':' || p, l_args.get_number(l_key));
              ELSIF l_reg.params(p).is_boolean THEN
                -- JSON true/false, or the text a model may send instead.
                -- Anything else binds NULL, which the function sees as NULL.
                IF l_el IS NOT NULL AND l_el.is_boolean THEN
                  l_txt := CASE WHEN l_args.get_boolean(l_key) THEN 'Y' ELSE 'N' END;
                ELSE
                  l_txt := CASE LOWER(l_args.get_string(l_key))
                             WHEN 'true'  THEN 'Y' WHEN 'y' THEN 'Y' WHEN 'yes' THEN 'Y' WHEN '1' THEN 'Y'
                             WHEN 'false' THEN 'N' WHEN 'n' THEN 'N' WHEN 'no'  THEN 'N' WHEN '0' THEN 'N'
                           END;
                END IF;
                DBMS_SQL.BIND_VARIABLE(l_cur, ':' || p, l_txt);
              ELSIF l_reg.params(p).temporal IS NOT NULL THEN
                -- Dates and timestamps arrive as text. canonical_temporal
                -- checks it and raises ORA-20704 (shown to the model) if
                -- it is not a date.
                DBMS_SQL.BIND_VARIABLE(l_cur, ':' || p,
                  canonical_temporal(
                    l_reg.params(p).temporal,
                    l_reg.params(p).param_name,
                    DBMS_LOB.SUBSTR(l_args.get_clob(l_key), 100, 1)));
              ELSE
                DBMS_SQL.BIND_VARIABLE(l_cur, ':' || p,
                  DBMS_LOB.SUBSTR(l_args.get_clob(l_key), 32767, 1));
              END IF;
            END LOOP;

            DBMS_SQL.BIND_VARIABLE(l_cur, ':ret', l_ret, 32767);
            l_rows := DBMS_SQL.EXECUTE(l_cur);
            DBMS_SQL.VARIABLE_VALUE(l_cur, ':ret', l_ret);
            DBMS_SQL.CLOSE_CURSOR(l_cur);

            apex_ai.set_tool_result(
              p_response_handler_param  => p_param,
              p_response_handler_result => p_result,
              p_tool_call               => p_param.pending_tool_calls(i),
              p_result                  => l_ret );
          EXCEPTION
            WHEN OTHERS THEN
              -- Capture first: later calls can overwrite the error.
              l_err_code  := SQLCODE;
              l_err_msg   := SUBSTR(SQLERRM, 1, 4000);
              l_err_trace := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
              IF DBMS_SQL.IS_OPEN(l_cur) THEN DBMS_SQL.CLOSE_CURSOR(l_cur); END IF;

              -- Full detail goes to the APEX debug log; the model gets a
              -- sanitized message.
              apex_debug.error(
                'ai_tool_builder: tool "' || l_call_name || '" (' || l_reg.fq_name
                || ') failed: ' || l_err_msg || ' | ' || l_err_trace );

              apex_ai.set_tool_result(
                p_response_handler_param  => p_param,
                p_response_handler_result => p_result,
                p_tool_call               => p_param.pending_tool_calls(i),
                p_result                  => model_error_text(l_call_name, l_err_code, l_err_msg) );
          END;
        END;
      END LOOP;
    END IF;
  END generic_response_handler;

END ai_tool_builder;
/
