SET SERVEROUTPUT ON SIZE UNLIMITED

--------------------------------------------------------------------------
-- AI_TOOL_BUILDER with ONE tool: expose demo_tools_pkg.convert_currency
-- as an apex_ai tool.
--
-- Prerequisites: run setup_demo_tools.sql first. Block 2 also needs
-- APEX 26.1+, a Generative AI Service shared component, and a real APEX
-- session (see the apex_session.create_session call). Block 1 needs none
-- of that.
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- 1. Sanity check, no LLM: introspect the function and print what got
--    captured.
--------------------------------------------------------------------------
DECLARE
  l_tool apex_ai.t_tool;
BEGIN
  ai_tool_builder.reset_registry;
  l_tool := ai_tool_builder.build_tool('DEMO_TOOLS_PKG.CONVERT_CURRENCY');

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
-- 2. The real agent run: the model must call the tool to answer.
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
  l_tools(1) := ai_tool_builder.build_tool('DEMO_TOOLS_PKG.CONVERT_CURRENCY');

  l_response := apex_ai.generate(
    p_prompt                     => 'Convert 250 USD to EUR and tell me the result. Use the tool, do not compute it yourself.',
    p_system_prompt              => 'You are a helpful assistant. Always use the available tools for currency conversion; never calculate rates yourself.',
    p_service_static_id          => c_ai_service,
    p_tools                      => l_tools,
    p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER',
    p_max_tool_roundtrips        => 5 );

  -- EXPECT: the answer contains 230.00 EUR (250 * the demo rate 0.92).
  DBMS_OUTPUT.PUT_LINE('--- agent response ---');
  DBMS_OUTPUT.PUT_LINE(l_response);
END;
/
