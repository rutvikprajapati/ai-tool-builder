SET SERVEROUTPUT ON SIZE UNLIMITED

--------------------------------------------------------------------------
-- AI_TOOL_BUILDER with DATE, TIMESTAMP and TIMESTAMP WITH TIME ZONE
-- parameters: demo_tools_pkg.get_weekday, add_hours and describe_moment.
--
-- The model sends dates and timestamps as ISO 8601 text. The handler
-- converts them with explicit masks, so NLS_DATE_FORMAT does not matter.
--
-- Prerequisites: run setup_demo_tools.sql first. Block 2 also needs
-- APEX 26.1+, a Generative AI Service shared component, and a real APEX
-- session (see the apex_session.create_session call). Block 1 needs none
-- of that.
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- 1. Sanity check, no LLM: build the tools and print what the model sees.
--    EXPECT: three tools, each date/time parameter exposed as VARCHAR2 with
--    an ISO 8601 example appended to its description.
--------------------------------------------------------------------------
DECLARE
  l_tools apex_ai.t_tools;
BEGIN
  ai_tool_builder.reset_registry;
  l_tools := ai_tool_builder.build_tools(
    apex_t_varchar2(
      'DEMO_TOOLS_PKG.GET_WEEKDAY',
      'DEMO_TOOLS_PKG.ADD_HOURS',
      'DEMO_TOOLS_PKG.DESCRIBE_MOMENT' ) );

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
-- 2. The real agent run: one question per date/time type.
--    EXPECT:
--      DATE      -> 2027-03-14 00:00:00 is a Sunday
--      TIMESTAMP -> 2027-03-16T10:15:00.000
--      TZ        -> 2027-03-14T10:30:00.000+05:30
--------------------------------------------------------------------------
DECLARE
  c_app_id     CONSTANT NUMBER        := 0;                    -- <-- an application id in your workspace
  c_username   CONSTANT VARCHAR2(200) := 'YOUR_USERNAME';      -- <-- a valid user in that workspace
  c_ai_service CONSTANT VARCHAR2(200) := 'YOUR_AI_SERVICE_ID'; -- <-- your AI Service static ID

  l_tools    apex_ai.t_tools;
  l_response CLOB;

  PROCEDURE ask(p_label IN VARCHAR2, p_prompt IN VARCHAR2) IS
  BEGIN
    l_response := apex_ai.generate(
      p_prompt                     => p_prompt,
      p_system_prompt              =>
        'You are a helpful assistant. Always use the available tools; never work out dates or times yourself. ' ||
        'Quote the tool result exactly.',
      p_service_static_id          => c_ai_service,
      p_tools                      => l_tools,
      p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER',
      p_max_tool_roundtrips        => 5 );
    DBMS_OUTPUT.PUT_LINE('--- ' || p_label || ' ---');
    DBMS_OUTPUT.PUT_LINE(l_response);
  END ask;
BEGIN
  apex_session.create_session(p_app_id => c_app_id, p_page_id => 1, p_username => c_username);
  ai_tool_builder.reset_registry;

  l_tools := ai_tool_builder.build_tools(
    apex_t_varchar2(
      'DEMO_TOOLS_PKG.GET_WEEKDAY',
      'DEMO_TOOLS_PKG.ADD_HOURS',
      'DEMO_TOOLS_PKG.DESCRIBE_MOMENT' ) );

  ask('DATE', 'What weekday is 14 March 2027? Use the tool.');
  ask('TIMESTAMP', 'What is 36 hours after 2027-03-14 22:15:00? Use the tool.');
  ask('TIMESTAMP WITH TIME ZONE',
      'Describe the moment 10:30 on 14 March 2027 in India (UTC+05:30). Use the tool.');
END;
/
