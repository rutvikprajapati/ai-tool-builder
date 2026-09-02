create or replace PACKAGE BODY ai_tool_builder AS

  TYPE t_param_bind IS RECORD (
    param_name VARCHAR2(128)
  );
  TYPE t_param_binds IS TABLE OF t_param_bind INDEX BY PLS_INTEGER;

  TYPE t_registration IS RECORD (
    fq_name VARCHAR2(400),
    params  t_param_binds
  );
  TYPE t_registry IS TABLE OF t_registration INDEX BY VARCHAR2(64);

  g_registry t_registry;

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
  -- Maps an Oracle parameter data type to the type EXPOSED to the LLM in
  -- the tool schema. NUMBER is deliberately mapped to VARCHAR2 here, not
  -- apex_ai.c_tool_param_type_number: empirically, a genuine NUMBER-typed
  -- tool parameter reliably makes apex_ai.generate raise ORA-20960 ("tool
  -- ... invalid parameters") against OCI Generative AI / meta.llama-3.3-
  -- 70b-instruct - looks like the model's returned argument value isn't
  -- in the exact form APEX_AI's NUMBER validator demands. Exposing it as
  -- VARCHAR2 instead sidesteps that entirely; PL/SQL's implicit
  -- VARCHAR2->NUMBER conversion handles the actual call in
  -- generic_response_handler, since args are always bound as strings.
  ----------------------------------------------------------------------------
  FUNCTION map_type(p_data_type IN VARCHAR2) RETURN apex_ai.t_tool_parameter_data_type IS
  BEGIN
    IF p_data_type = 'CLOB' THEN
      RETURN apex_ai.c_tool_param_type_clob;
    ELSIF p_data_type = 'BOOLEAN' THEN
      RAISE_APPLICATION_ERROR(-20701,
        'ai_tool_builder: PL/SQL BOOLEAN parameters are not supported - ' ||
        'use VARCHAR2 (''Y''/''N'') instead.');
    ELSE
      RETURN apex_ai.c_tool_param_type_varchar2; -- NUMBER, VARCHAR2, CHAR, DATE-as-string, etc.
    END IF;
  END map_type;

  ----------------------------------------------------------------------------
  -- Doc-comment block for "FUNCTION <p_target_name> (" in p_owner/p_src_name
  -- (p_src_type PACKAGE or FUNCTION). Tries two placements:
  --
  --   1. The contiguous run of "--" lines immediately ABOVE the
  --      declaration - works for a packaged function's declaration in
  --      the PACKAGE spec, since real signature text precedes it there.
  --   2. If that's empty, the contiguous run of "--" lines immediately
  --      AFTER the "IS"/"AS" that opens the declare section (before the
  --      first real declaration or BEGIN) - this is the only placement
  --      that works for a STANDALONE function, because Oracle's
  --      ALL_SOURCE for a standalone object starts exactly at the
  --      FUNCTION keyword: anything written between CREATE OR REPLACE
  --      and FUNCTION - comments included - is discarded before it ever
  --      reaches ALL_SOURCE, so there is no earlier line to hold a doc
  --      block above the declaration.
  --
  -- NULL if the declaration isn't found, or neither placement has a block.
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

    FOR i IN 1 .. l_lines.COUNT LOOP
      IF REGEXP_LIKE(l_lines(i), 'FUNCTION\s+' || p_target_name || '\s*\(', 'i') THEN
        l_decl_idx := i;
        EXIT;
      END IF;
    END LOOP;

    IF l_decl_idx IS NULL THEN
      RETURN NULL;
    END IF;

    -- Placement 1: scan backward from the declaration.
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

    -- Placement 2: find "IS"/"AS" ending the parameter/return clause,
    -- then scan forward for comments right after it.
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
  FUNCTION tag_value(p_block IN CLOB, p_tag_pattern IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_block IS NULL THEN RETURN NULL; END IF;
    RETURN TRIM(REGEXP_SUBSTR(p_block, '--\s*@' || p_tag_pattern || '\s*:\s*([^' || CHR(10) || CHR(13) || ']*)',
                               1, 1, 'i', 1));
  END tag_value;

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
  BEGIN
    parse_name(p_function_name, l_owner, l_pkg, l_func);

    IF l_pkg IS NOT NULL THEN
      l_src_type := 'PACKAGE';
      l_src_name := l_pkg;
    ELSE
      l_src_type := 'FUNCTION';
      l_src_name := l_func;
    END IF;

    l_doc_block := extract_doc_block(l_owner, l_src_name, l_src_type, l_func);
    l_tool_desc := tag_value(l_doc_block, 'tool');

    l_reg.fq_name := l_owner || '.' || CASE WHEN l_pkg IS NOT NULL THEN l_pkg || '.' END || l_func;

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
      BEGIN
        -- data_type is always VARCHAR2/CLOB in the exposed schema (see
        -- map_type) - for an underlying NUMBER param, say so in the
        -- description since the type itself no longer signals it.
        IF r.data_type IN ('NUMBER', 'INTEGER', 'PLS_INTEGER', 'BINARY_INTEGER', 'FLOAT') THEN
          l_pdesc := TRIM(l_pdesc || ' (numeric value, pass as a plain number)');
        END IF;

        l_params.EXTEND;
        l_params(l_params.COUNT) := apex_ai.t_tool_parameter(
          name           => LOWER(r.argument_name),
          description    => l_pdesc,
          data_type      => map_type(r.data_type),
          is_required    => (r.defaulted = 'N'),
          allowed_values => NULL );

        l_reg.params(l_reg.params.COUNT + 1) := t_param_bind(param_name => r.argument_name);
      END;
    END LOOP;

    -- apex_ai.generate/chat require tool names to be lowercase letters,
    -- digits, and underscores, starting with a letter (ORA-20950
    -- otherwise) - ALL_ARGUMENTS/l_func are uppercase, so lowercase it.
    l_name := NVL(p_tool_name, LOWER(SUBSTR(l_func, 1, 64)));
    g_registry(l_name) := l_reg;

    RETURN apex_ai.t_tool(
      name                   => l_name,
      description            => NVL(l_tool_desc, 'Calls the PL/SQL function ' || l_reg.fq_name || '.'),
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
  PROCEDURE reset_registry IS
  BEGIN
    g_registry.DELETE;
  END reset_registry;

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
          l_args      sys.json_object_t := p_param.pending_tool_calls(i).args_json;
        BEGIN
          IF NOT g_registry.EXISTS(l_call_name) THEN
            apex_ai.set_tool_result(
              p_response_handler_param  => p_param,
              p_response_handler_result => p_result,
              p_tool_call               => p_param.pending_tool_calls(i),
              p_result                  => 'Error: no function registered for tool "' || l_call_name || '"' );
            CONTINUE;
          END IF;

          l_reg := g_registry(l_call_name);

          l_stmt := ':ret := TO_CHAR(' || l_reg.fq_name || '(';
          FOR p IN 1 .. l_reg.params.COUNT LOOP
            l_stmt := l_stmt || l_reg.params(p).param_name || ' => :' || p;
            IF p < l_reg.params.COUNT THEN l_stmt := l_stmt || ','; END IF;
          END LOOP;
          l_stmt := l_stmt || '));';

          l_cur := DBMS_SQL.OPEN_CURSOR;
          BEGIN
            DBMS_SQL.PARSE(l_cur, 'BEGIN ' || l_stmt || ' END;', DBMS_SQL.NATIVE);

            FOR p IN 1 .. l_reg.params.COUNT LOOP
              -- Every parameter is exposed to the LLM as VARCHAR2/CLOB
              -- (see map_type), so every arg is bound as a string here
              -- too - PL/SQL's implicit VARCHAR2->NUMBER conversion
              -- handles the actual call when the target parameter is
              -- NUMBER. args_json keys match the *lowercase* names the
              -- schema exposed (see build_tool), not the uppercase
              -- ALL_ARGUMENTS.argument_name used in the named bind
              -- clause above (case-insensitive there).
              DBMS_SQL.BIND_VARIABLE(l_cur, ':' || p,
                DBMS_LOB.SUBSTR(l_args.get_clob(LOWER(l_reg.params(p).param_name)), 32767, 1));
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
              IF DBMS_SQL.IS_OPEN(l_cur) THEN DBMS_SQL.CLOSE_CURSOR(l_cur); END IF;
              apex_ai.set_tool_result(
                p_response_handler_param  => p_param,
                p_response_handler_result => p_result,
                p_tool_call               => p_param.pending_tool_calls(i),
                p_result                  => 'Error calling ' || l_reg.fq_name || ': ' || SQLERRM );
          END;
        END;
      END LOOP;
    END IF;
  END generic_response_handler;

END ai_tool_builder;
/
