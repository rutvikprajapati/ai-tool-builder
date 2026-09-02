SET SERVEROUTPUT ON SIZE UNLIMITED

--------------------------------------------------------------------------
-- AI_TOOL_BUILDER demo: expose an ordinary PL/SQL FUNCTION as an
-- apex_ai tool automatically, using ALL_ARGUMENTS for the parameter list
-- and a "-- @tool:/-- @param:" doc-comment convention (the closest
-- PL/SQL equivalent of LangChain's @tool decorator + docstring) for the
-- descriptions the LLM sees.
--
-- Prerequisites: same as test_agent_bridge.sql - APEX 26.1+, a
-- Generative AI Service shared component, and a real APEX session (see
-- the apex_session.create_session call below).
--------------------------------------------------------------------------

-- The "tool": an ordinary function, documented with @tool/@param tags.
-- Everything after these comments is introspected automatically - no
-- manual apex_ai.t_tool_parameters wiring required.
CREATE OR REPLACE PACKAGE mcp_test_tools_pkg AS

  -- @tool: Converts an amount from one currency to another using a fixed demo rate table
  -- @param p_amount: The amount to convert
  -- @param p_from_currency: ISO 4217 source currency code, e.g. USD
  -- @param p_to_currency: ISO 4217 target currency code, e.g. EUR
  -- @param p_note: Optional free-text note to include in the result
  FUNCTION convert_currency(
    p_amount        IN NUMBER,
    p_from_currency IN VARCHAR2,
    p_to_currency   IN VARCHAR2,
    p_note          IN VARCHAR2 DEFAULT NULL
  ) RETURN VARCHAR2;

  -- @tool: Looks up the current headcount for a department in a fixed demo dataset
  -- @param p_department: Department name, e.g. Engineering, Sales, Finance
  FUNCTION get_headcount(
    p_department IN VARCHAR2
  ) RETURN VARCHAR2;

END mcp_test_tools_pkg;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE BODY mcp_test_tools_pkg AS

  FUNCTION convert_currency(
    p_amount        IN NUMBER,
    p_from_currency IN VARCHAR2,
    p_to_currency   IN VARCHAR2,
    p_note          IN VARCHAR2 DEFAULT NULL
  ) RETURN VARCHAR2 IS
    l_rate NUMBER;
  BEGIN
    l_rate := CASE WHEN p_from_currency = 'USD' AND p_to_currency = 'EUR' THEN 0.92 ELSE 1 END;
    RETURN TO_CHAR(p_amount * l_rate, 'FM999999990.00') || ' ' || p_to_currency ||
           CASE WHEN p_note IS NOT NULL THEN ' (' || p_note || ')' END;
  END convert_currency;

  FUNCTION get_headcount(
    p_department IN VARCHAR2
  ) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE UPPER(p_department)
      WHEN 'ENGINEERING' THEN '42'
      WHEN 'SALES' THEN '17'
      WHEN 'FINANCE' THEN '9'
      ELSE '0'
    END;
  END get_headcount;

END mcp_test_tools_pkg;
/
SHOW ERRORS

--------------------------------------------------------------------------
-- Sanity check: introspect the function and print what got captured,
-- before ever involving an LLM.
--------------------------------------------------------------------------
DECLARE
  l_tool apex_ai.t_tool;
BEGIN
  l_tool := ai_tool_builder.build_tool('MCP_TEST_TOOLS_PKG.CONVERT_CURRENCY');

  DBMS_OUTPUT.PUT_LINE('name: ' || l_tool.name);
  DBMS_OUTPUT.PUT_LINE('description: ' || l_tool.description);
  FOR i IN 1 .. l_tool.parameters.COUNT LOOP
    DBMS_OUTPUT.PUT_LINE('  param ' || i || ': ' || l_tool.parameters(i).name ||
      ' type=' || l_tool.parameters(i).data_type ||
      ' required=' || CASE WHEN l_tool.parameters(i).is_required THEN 'Y' ELSE 'N' END ||
      ' desc=' || l_tool.parameters(i).description);
  END LOOP;
END;
/

--------------------------------------------------------------------------
-- The real agent run.
--------------------------------------------------------------------------
DECLARE
  c_app_id     CONSTANT NUMBER        := 0;                    -- <-- an application id in your workspace
  c_username   CONSTANT VARCHAR2(200) := 'YOUR_USERNAME';      -- <-- a valid user in that workspace
  c_ai_service CONSTANT VARCHAR2(200) := 'YOUR_AI_SERVICE_ID'; -- <-- your AI Service static ID

  l_tools    apex_ai.t_tools := apex_ai.t_tools();
  l_response CLOB;
BEGIN
  apex_session.create_session(p_app_id => c_app_id, p_page_id => 1, p_username => c_username);
  ai_tool_builder.reset_registry;

  l_tools.EXTEND;
  l_tools(1) := ai_tool_builder.build_tool('MCP_TEST_TOOLS_PKG.CONVERT_CURRENCY');

  l_response := apex_ai.generate(
    p_prompt                     => 'Convert 250 USD to EUR and tell me the result. Use the tool, do not compute it yourself.',
    p_system_prompt              => 'You are a helpful assistant. Always use the available tools for currency conversion; never calculate rates yourself.',
    p_service_static_id          => c_ai_service,
    p_tools                      => l_tools,
    p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER',
    p_max_tool_roundtrips        => 5 );

  DBMS_OUTPUT.PUT_LINE('--- agent response ---');
  DBMS_OUTPUT.PUT_LINE(l_response);
END;
/

--------------------------------------------------------------------------
-- Multiple tools in one call: build_tools() takes an apex_t_varchar2 of
-- 'FUNC'/'PKG.FUNC' names, same idea as
-- MCP_AGENT_BRIDGE_PKG.build_tools(p_server_names). Each is introspected
-- and registered exactly as build_tool() would do individually.
--
-- Note on model behavior (found by testing against OCI Generative AI /
-- meta.llama-3.3-70b-instruct): a single-topic ask works fine even with
-- several tools on offer, and a *sequential* compound ask ("call tool A,
-- then after that result call tool B") works too - both go through
-- generic_response_handler correctly, one tool call per roundtrip. A
-- *parallel* compound ask in one breath ("do both") sometimes makes the
-- model print its intended calls as literal JSON text instead of real
-- tool calls, which APEX_AI then treats as a plain final answer and
-- never dispatches - not something this package can paper over. Prefer
-- prompts/system instructions that push one tool call per turn when
-- several tools are in play.
--------------------------------------------------------------------------
DECLARE
  c_app_id     CONSTANT NUMBER        := 0;                    -- <-- an application id in your workspace
  c_username   CONSTANT VARCHAR2(200) := 'YOUR_USERNAME';      -- <-- a valid user in that workspace
  c_ai_service CONSTANT VARCHAR2(200) := 'YOUR_AI_SERVICE_ID'; -- <-- your AI Service static ID

  l_tools    apex_ai.t_tools;
  l_response CLOB;
BEGIN
  apex_session.create_session(p_app_id => c_app_id, p_page_id => 1, p_username => c_username);
  ai_tool_builder.reset_registry;

  l_tools := ai_tool_builder.build_tools(
    apex_t_varchar2(
      'MCP_TEST_TOOLS_PKG.CONVERT_CURRENCY',
      'MCP_TEST_TOOLS_PKG.GET_HEADCOUNT' ) );

  DBMS_OUTPUT.PUT_LINE('--- tools built ---');
  FOR i IN 1 .. l_tools.COUNT LOOP
    DBMS_OUTPUT.PUT_LINE('  - ' || l_tools(i).name || ': ' || l_tools(i).description);
  END LOOP;

  l_response := apex_ai.generate(
    p_prompt                     =>
      'Step 1: call get_headcount for the Engineering department. ' ||
      'Step 2: after you get that result, call convert_currency to convert 100 USD to EUR. ' ||
      'Step 3: summarize both results in one sentence. Call only one tool at a time.',
    p_system_prompt              =>
      'You are a helpful assistant. Always use the available tools when relevant. ' ||
      'Call tools one at a time, never more than one tool call per turn.',
    p_service_static_id          => c_ai_service,
    p_tools                      => l_tools,
    p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER',
    p_max_tool_roundtrips        => 6 );

  DBMS_OUTPUT.PUT_LINE('--- agent response (multi-tool) ---');
  DBMS_OUTPUT.PUT_LINE(l_response);
END;
/
