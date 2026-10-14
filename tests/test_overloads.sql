SET SERVEROUTPUT ON SIZE UNLIMITED

--------------------------------------------------------------------------
-- AI_TOOL_BUILDER overload handling. No LLM or APEX session needed.
--
-- An overloaded function cannot be registered: build_tool raises ORA-20703.
-- The way out is one wrapper function per overload, each with a unique name
-- and its own @tool / @param comments. The wrappers are what you register.
--
-- Prerequisites: run setup_demo_tools.sql first. It creates demo_tools_pkg
-- with the overloaded get_customer and its two wrappers.
--------------------------------------------------------------------------

DECLARE
  l_tool apex_ai.t_tool;

  PROCEDURE try(p_name IN VARCHAR2) IS
  BEGIN
    l_tool := ai_tool_builder.build_tool(p_name);
    DBMS_OUTPUT.PUT_LINE('OK   ' || p_name || ' -> ' || l_tool.name ||
      ' (' || l_tool.parameters.COUNT || ' param) ' || l_tool.description);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('FAIL ' || p_name || ' -> ' || SQLERRM);
  END try;
BEGIN
  ai_tool_builder.reset_registry;
  -- EXPECT ORA-20703: overloaded.
  try('DEMO_TOOLS_PKG.GET_CUSTOMER');
  -- EXPECT OK: one param each, own description.
  try('DEMO_TOOLS_PKG.GET_CUSTOMER_BY_ID');
  try('DEMO_TOOLS_PKG.GET_CUSTOMER_BY_NAME');
  -- EXPECT ORA-20702: unchanged behavior for a missing name.
  try('DEMO_TOOLS_PKG.NOPE');
END;
/
