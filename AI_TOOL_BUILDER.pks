create or replace PACKAGE ai_tool_builder AS
  --------------------------------------------------------------------------
  -- Author: Rutvik Prajapati
  --
  -- Turns an ordinary PL/SQL FUNCTION into an apex_ai tool - the PL/SQL
  -- analogue of LangChain's @tool decorator + docstring. PL/SQL has
  -- neither decorators nor docstrings, so this reads two things instead:
  --
  --   1. ALL_ARGUMENTS - authoritative parameter names, types, order, and
  --      whether each has a default (DEFAULTED='Y' -> optional).
  --   2. A doc-comment block of contiguous "--" lines, using tags:
  --        -- @tool: <what this tool does>
  --        -- @param <param_name>: <what this parameter is>
  --      Placement depends on the target:
  --        - Packaged function: immediately ABOVE its declaration in the
  --          PACKAGE spec (real signature text precedes it there).
  --        - Standalone function: immediately AFTER the "IS"/"AS" that
  --          opens the declare section, before the first real
  --          declaration or BEGIN. Oracle's ALL_SOURCE for a standalone
  --          object starts exactly at the FUNCTION keyword - anything
  --          written between CREATE OR REPLACE and FUNCTION, comments
  --          included, is discarded before it ever reaches ALL_SOURCE,
  --          so there is no earlier line available to hold a doc block
  --          above the declaration.
  --      extract_doc_block() tries the "above" placement first and falls
  --      back to "after IS/AS" only if that's empty, so a packaged
  --      function can use either placement too.
  --
  -- V1 scope / limitations:
  --   - Target must be a FUNCTION (packaged or standalone), not a
  --     PROCEDURE - the return value becomes the tool result.
  --   - IN parameters only; must be NUMBER or VARCHAR2/CHAR/CLOB.
  --     PL/SQL BOOLEAN is not supported (DBMS_SQL can't bind it portably
  --     across versions) - use VARCHAR2 'Y'/'N' in the target function.
  --   - Return value is converted with TO_CHAR and capped at 32767 chars
  --     when routed through generic_response_handler.
  --   - Overloaded functions are not supported - only the first
  --     ALL_ARGUMENTS match is used.
  --
  -- Usage:
  --   DECLARE
  --     l_tools    apex_ai.t_tools := apex_ai.t_tools();
  --     l_response CLOB;
  --   BEGIN
  --     l_tools.EXTEND;
  --     l_tools(1) := ai_tool_builder.build_tool('MY_PKG.CONVERT_CURRENCY');
  --
  --     l_response := apex_ai.generate(
  --       p_prompt                     => 'How much is 100 USD in EUR?',
  --       p_service_static_id          => 'MY_AI_SERVICE',
  --       p_tools                      => l_tools,
  --       p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER' );
  --   END;
  --
  -- Like MCP_AGENT_BRIDGE_PKG, build_tool() populates a package-level
  -- routing table that generic_response_handler() reads - safe because
  -- both run inside one synchronous apex_ai.generate/chat call. Calling
  -- build_tool() again (e.g. for a second tool) adds to the table; it
  -- isn't cleared between calls.
  --------------------------------------------------------------------------

  -- Introspects p_function_name - accepts 'FUNC', 'PACKAGE.FUNC', or
  -- 'OWNER.PACKAGE.FUNC' (owner/package default to the current schema /
  -- a standalone function) - and returns an apex_ai.t_tool built from
  -- ALL_ARGUMENTS plus the @tool/@param doc comments found above its
  -- declaration. Also registers the function for generic_response_handler.
  FUNCTION build_tool(
    p_function_name IN VARCHAR2,
    p_tool_name     IN VARCHAR2 DEFAULT NULL
  ) RETURN apex_ai.t_tool;

  -- Convenience overload: builds an apex_ai.t_tools collection from
  -- several functions in one call, e.g.
  --   ai_tool_builder.build_tools(
  --     apex_t_varchar2('PKG.CONVERT_CURRENCY', 'PKG.GET_STOCK_PRICE') )
  -- Each function is registered exactly as build_tool() would.
  FUNCTION build_tools(
    p_function_names IN apex_t_varchar2
  ) RETURN apex_ai.t_tools;

  -- Clears the routing table populated by build_tool(). Call before
  -- building a fresh tool list if you don't want tools from a previous
  -- call still routable.
  PROCEDURE reset_registry;

  -- APEX_AI response handler: for each pending tool call, dynamically
  -- invokes whichever function build_tool() registered it to, binding
  -- arguments from the LLM's args_json by parameter name via DBMS_SQL,
  -- and returns TO_CHAR(result) as the tool result. Pass its qualified
  -- name as p_response_handler_procedure.
  PROCEDURE generic_response_handler(
    p_param  IN              apex_ai.t_chat_response_handler_param,
    p_result IN OUT NOCOPY   apex_ai.t_chat_response_handler_result
  );

END ai_tool_builder;
/
