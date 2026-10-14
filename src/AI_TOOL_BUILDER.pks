create or replace PACKAGE ai_tool_builder AS
  --------------------------------------------------------------------------
  -- Author: Rutvik Prajapati
  --
  -- Turns a PL/SQL FUNCTION into an apex_ai tool, like LangChain's @tool
  -- decorator. Parameters come from ALL_ARGUMENTS; descriptions come from
  -- "--" comment lines using these tags:
  --     -- @tool: <what this tool does>
  --     -- @param <param_name>: <what this parameter is>
  --
  -- Where the comment goes:
  --   - Packaged function:   directly above its declaration in the package spec.
  --   - Standalone function: right after the IS/AS, before BEGIN. Oracle
  --     discards anything written before the FUNCTION keyword.
  --
  -- Limits:
  --   - FUNCTION only (not PROCEDURE). build_tool raises ORA-20702 if the
  --     name is not found, not visible, or not a function.
  --   - IN parameters only: NUMBER, VARCHAR2, CHAR, CLOB, BOOLEAN, DATE,
  --     TIMESTAMP, or TIMESTAMP WITH [LOCAL] TIME ZONE. The model sends dates
  --     and timestamps as ISO 8601 text (2027-03-14, 2027-03-14T10:30:00,
  --     2027-03-14T10:30:00+05:30); the handler converts them with explicit
  --     masks, so NLS_DATE_FORMAT does not matter. Bad text raises ORA-20704
  --     and the model is told which format to send.
  --   - Result is TO_CHAR'd and capped at 32767 characters.
  --   - Overloaded functions are not supported: build_tool raises ORA-20703.
  --     Wrap each overload in a function with a unique name (its own @tool /
  --     @param comments) and register the wrappers.
  --
  -- Usage:
  --   DECLARE
  --     l_tools    apex_ai.t_tools;
  --     l_response CLOB;
  --   BEGIN
  --     l_tools := ai_tool_builder.build_tools(
  --                  apex_t_varchar2('MY_PKG.CONVERT_CURRENCY') );
  --
  --     l_response := apex_ai.generate(
  --       p_prompt                     => 'How much is 100 USD in EUR?',
  --       p_service_static_id          => 'MY_AI_SERVICE',
  --       p_tools                      => l_tools,
  --       p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER' );
  --   END;
  --
  -- Build tools in the same request as the apex_ai call that uses them.
  -- The tool registry is package state, so it is not available across
  -- requests, background jobs or workflows. Rebuilding on every request is
  -- cheap.
  --------------------------------------------------------------------------

  -- Builds an apex_ai.t_tool from one function and registers it for
  -- generic_response_handler. p_function_name is 'FUNC', 'PKG.FUNC' or
  -- 'OWNER.PKG.FUNC'. The tool name defaults to the lowercased function name.
  -- Raises ORA-20702 (not found / not a function) or ORA-20703 (overloaded).
  FUNCTION build_tool(
    p_function_name IN VARCHAR2,
    p_tool_name     IN VARCHAR2 DEFAULT NULL
  ) RETURN apex_ai.t_tool;

  -- Same as build_tool for several functions.
  FUNCTION build_tools(
    p_function_names IN apex_t_varchar2
  ) RETURN apex_ai.t_tools;

  -- Clears the registry of tools registered by build_tool.
  PROCEDURE reset_registry;

  -- Pass as p_response_handler_procedure. Runs each tool the model requests
  -- and returns the result. Never raises. On failure the model receives a
  -- sanitized message, not SQLERRM; the full error is written to the APEX
  -- debug log. Messages from RAISE_APPLICATION_ERROR (-20000..-20999) are
  -- passed to the model, so write them for the model to read.
  PROCEDURE generic_response_handler(
    p_param  IN              apex_ai.t_chat_response_handler_param,
    p_result IN OUT NOCOPY   apex_ai.t_chat_response_handler_result
  );

END ai_tool_builder;
/
