--------------------------------------------------------------------------
-- Creates demo_tools_pkg, the example tools used by test_single_tool.sql,
-- test_multi_tool.sql and test_overloads.sql.
-- Run this once before those scripts.
--
-- The functions are ordinary PL/SQL documented with @tool / @param tags;
-- ai_tool_builder introspects them, no manual apex_ai.t_tool wiring.
-- To remove: DROP PACKAGE demo_tools_pkg;
--------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE demo_tools_pkg AS

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

  -- @tool: Returns the weekday for a date
  -- @param p_date: The date to look up
  FUNCTION get_weekday(
    p_date IN DATE
  ) RETURN VARCHAR2;

  -- @tool: Adds a number of hours to a timestamp and returns the new timestamp
  -- @param p_start: The starting timestamp
  -- @param p_hours: How many hours to add
  FUNCTION add_hours(
    p_start IN TIMESTAMP,
    p_hours IN NUMBER
  ) RETURN VARCHAR2;

  -- @tool: Describes a moment in time, including its UTC offset
  -- @param p_at: The moment to describe
  FUNCTION describe_moment(
    p_at IN TIMESTAMP WITH TIME ZONE
  ) RETURN VARCHAR2;

  -- Overloads: NOT registrable directly (build_tool raises ORA-20703).
  -- Used by test_overloads.sql.
  FUNCTION get_customer(p_id   IN NUMBER)   RETURN VARCHAR2;
  FUNCTION get_customer(p_name IN VARCHAR2) RETURN VARCHAR2;

  -- Wrappers for the overloads: one function per overload with a unique
  -- name and its own @tool / @param comments. These are the tools.

  -- @tool: Looks up a customer by numeric customer id and returns their details
  -- @param p_id: The customer id, e.g. 1042
  FUNCTION get_customer_by_id(
    p_id IN NUMBER
  ) RETURN VARCHAR2;

  -- @tool: Looks up a customer by name and returns their details
  -- @param p_name: Full customer name, e.g. Acme
  FUNCTION get_customer_by_name(
    p_name IN VARCHAR2
  ) RETURN VARCHAR2;

END demo_tools_pkg;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE BODY demo_tools_pkg AS

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

  FUNCTION get_weekday(
    p_date IN DATE
  ) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_date, 'YYYY-MM-DD HH24:MI:SS') || ' is a ' ||
           TRIM(TO_CHAR(p_date, 'Day', 'NLS_DATE_LANGUAGE=ENGLISH'));
  END get_weekday;

  FUNCTION add_hours(
    p_start IN TIMESTAMP,
    p_hours IN NUMBER
  ) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_start + NUMTODSINTERVAL(p_hours, 'HOUR'), 'YYYY-MM-DD"T"HH24:MI:SS.FF3');
  END add_hours;

  FUNCTION describe_moment(
    p_at IN TIMESTAMP WITH TIME ZONE
  ) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_at, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM');
  END describe_moment;

  FUNCTION get_customer(p_id IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'Customer #' || p_id || ': Acme Ltd';
  END get_customer;

  FUNCTION get_customer(p_name IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'Customer "' || p_name || '": id 1042';
  END get_customer;

  FUNCTION get_customer_by_id(p_id IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN get_customer(p_id);    -- resolves to the NUMBER overload
  END get_customer_by_id;

  FUNCTION get_customer_by_name(p_name IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN get_customer(p_name);  -- resolves to the VARCHAR2 overload
  END get_customer_by_name;

END demo_tools_pkg;
/
SHOW ERRORS
