SET SERVEROUTPUT ON SIZE UNLIMITED

--------------------------------------------------------------------------
-- AI_TOOL_BUILDER with SEVERAL tools: build_tools() takes an
-- apex_t_varchar2 of 'FUNC' / 'PKG.FUNC' names.
--
-- Prerequisites: run setup_demo_tools.sql first. Block 2 also needs
-- APEX 26.1+, a Generative AI Service shared component, and a real APEX
-- session (see the apex_session.create_session call). Block 1 needs none
-- of that.
--
-- Model behavior (OCI Generative AI, meta.llama-3.3-70b-instruct): a
-- sequential ask ("call A, then call B") works. A parallel ask ("do both")
-- sometimes makes the model print the calls as plain JSON text, which
-- APEX_AI treats as a final answer and never dispatches. Ask for one tool
-- call per turn.
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- 1. Sanity check, no LLM: build both tools and list them.
--------------------------------------------------------------------------
DECLARE
  l_tools apex_ai.t_tools;
BEGIN
  ai_tool_builder.reset_registry;
  l_tools := ai_tool_builder.build_tools(
    apex_t_varchar2(
      'DEMO_TOOLS_PKG.CONVERT_CURRENCY',
      'DEMO_TOOLS_PKG.GET_HEADCOUNT' ) );

  -- EXPECT: 2 tools, convert_currency (4 params) and get_headcount (1 param).
  DBMS_OUTPUT.PUT_LINE('--- tools built: ' || l_tools.COUNT || ' ---');
  FOR i IN 1 .. l_tools.COUNT LOOP
    DBMS_OUTPUT.PUT_LINE('name: ' || l_tools(i).name);
    DBMS_OUTPUT.PUT_LINE('description: ' || l_tools(i).description);
    FOR j IN 1 .. l_tools(i).parameters.COUNT LOOP
      DBMS_OUTPUT.PUT_LINE('  param ' || j || ': ' || l_tools(i).parameters(j).name ||
        ' type=' || l_tools(i).parameters(j).data_type ||
        ' required=' || CASE WHEN l_tools(i).parameters(j).is_required THEN 'Y' ELSE 'N' END ||
        ' desc=' || l_tools(i).parameters(j).description);
    END LOOP;
  END LOOP;
END;
/

--------------------------------------------------------------------------
-- 2. The real agent run: the model must call both tools, one per turn.
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
      'DEMO_TOOLS_PKG.CONVERT_CURRENCY',
      'DEMO_TOOLS_PKG.GET_HEADCOUNT' ) );

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

  -- EXPECT: the answer mentions a headcount of 42 and 92.00 EUR.
  DBMS_OUTPUT.PUT_LINE('--- agent response (multi-tool) ---');
  DBMS_OUTPUT.PUT_LINE(l_response);
END;
/
