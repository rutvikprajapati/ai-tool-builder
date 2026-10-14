# ai-tool-builder

This package takes an ordinary PL/SQL `FUNCTION` and turns it into an `apex_ai` tool automatically. You give it a function name. It looks up the function's parameters in the data dictionary, reads a short comment you wrote above the function, and builds the `apex_ai.t_tool` that `apex_ai.generate`/`apex_ai.chat` needs. You never have to hand-build a `t_tool_parameters` list yourself.

If you've used LangChain or the OpenAI Agents SDK in Python, this package does the same job as their `@tool` decorator + docstring. PL/SQL has no decorators and no docstrings, so this package reads the database instead.

This is for building **ad-hoc AI agents entirely in PL/SQL** — see Oracle's blog post, [Build Ad-Hoc AI Agents Entirely in PL/SQL](https://blogs.oracle.com/apex/build-ad-hoc-ai-agents-entirely-in-pl-sql), for the broader pattern this package plugs into.

> **Requires APEX 26.1+** — the tool-calling parameters (`p_tools`, `p_response_handler_procedure`) on `APEX_AI.GENERATE` / `APEX_AI.CHAT` were introduced in that release. See [Prerequisites](#prerequisites).

## Why this exists

The [ad-hoc AI agents pattern](https://blogs.oracle.com/apex/build-ad-hoc-ai-agents-entirely-in-pl-sql) shows how to give `apex_ai.generate`/`chat` a tool by hand-building the `p_tools` parameter directly in your PL/SQL block — one `apex_ai.t_tool`, with a nested `apex_ai.t_tool_parameters` list, per tool:

```sql
l_tools(1) := apex_ai.t_tool(
  name        => 'convert_currency',
  description => 'Converts an amount from one currency to another using a fixed demo rate table',
  parameters  => apex_ai.t_tool_parameters(
    apex_ai.t_tool_parameter(
      name        => 'p_amount',
      description => 'The amount to convert',
      type        => 'VARCHAR2',
      is_required => TRUE ),
    apex_ai.t_tool_parameter(
      name        => 'p_from_currency',
      description => 'ISO 4217 source currency code, e.g. USD',
      type        => 'VARCHAR2',
      is_required => TRUE ),
    apex_ai.t_tool_parameter(
      name        => 'p_to_currency',
      description => 'ISO 4217 target currency code, e.g. EUR',
      type        => 'VARCHAR2',
      is_required => TRUE ) ) );
```

That's ~20 lines to describe one function that already declares its own name and parameters. It works, but it doesn't scale: every parameter's name, description, and required-ness is retyped by hand, next to a function signature that already says most of that. Give the agent a second tool and you paste the whole block again, with new field values to keep in sync with the function by hand — a five- or six-tool agent, a completely ordinary size for something meant to be ad-hoc, turns into a wall of nested constructors where the actual logic (which tools, what prompt) is buried under scaffolding that has nothing to do with the agent's behavior. This is exactly what LangChain's `@tool` decorator and the OpenAI Agents SDK avoid in Python, by introspecting the function instead of making you describe it separately.

`ai_tool_builder` removes that boilerplate the same way: the function's own signature already has the parameter names, types, order, and defaults — Oracle tracks all of that already, via `ALL_ARGUMENTS` — so the only thing left to write by hand is what a human has to supply anyway: a one-line description of the tool and of each parameter, as a `--` comment above the function:

```sql
-- @tool: Converts an amount from one currency to another using a fixed demo rate table
-- @param p_amount: The amount to convert
-- @param p_from_currency: ISO 4217 source currency code, e.g. USD
-- @param p_to_currency: ISO 4217 target currency code, e.g. EUR
```

`build_tool`/`build_tools` do the rest — see [Quick start](#quick-start) below for the one-line call that replaces the whole manual block above.

### Packaged and standalone functions are both supported

Where the comment block goes depends on which kind of function you're documenting:

- **Packaged function** — put the comment directly above the function's declaration, in the package spec:

  ```sql
  PACKAGE my_pkg AS
    -- @tool: Converts an amount from one currency to another using a fixed demo rate table
    -- @param p_amount: The amount to convert
    -- @param p_from_currency: ISO 4217 source currency code, e.g. USD
    -- @param p_to_currency: ISO 4217 target currency code, e.g. EUR
    FUNCTION convert_currency(
      p_amount        IN NUMBER,
      p_from_currency IN VARCHAR2,
      p_to_currency   IN VARCHAR2
    ) RETURN VARCHAR2;
  END my_pkg;
  ```

- **Standalone function** — put the comment after `IS`/`AS`, before `BEGIN`:

  ```sql
  CREATE OR REPLACE FUNCTION convert_currency(
    p_amount        IN NUMBER,
    p_from_currency IN VARCHAR2,
    p_to_currency   IN VARCHAR2
  ) RETURN VARCHAR2 IS
    -- @tool: Converts an amount from one currency to another using a fixed demo rate table
    -- @param p_amount: The amount to convert
    -- @param p_from_currency: ISO 4217 source currency code, e.g. USD
    -- @param p_to_currency: ISO 4217 target currency code, e.g. EUR
  BEGIN
    ...
  END convert_currency;
  ```

Standalone functions need the "after `IS`/`AS`" placement because Oracle discards everything written between `CREATE OR REPLACE` and `FUNCTION` before storing the source — a comment placed above the declaration never survives to be read. Packaged functions don't have this problem, so they can use either placement.

## Architecture

```
                caller (PL/SQL block, APEX AI Agent, ORDS handler)
                                 |
                                 v
                     ai_tool_builder.build_tool /
                     ai_tool_builder.build_tools
                                 |
              +------------------+------------------+
              |                                     |
        ALL_ARGUMENTS                         ALL_SOURCE
   (param names, types,                (your @tool / @param
    order, defaults)                       comment block)
              |                                     |
              +------------------+------------------+
                                 |
                                 v
                        apex_ai.t_tool
              (name, description, parameter list)
                                 |
                                 v            (also recorded in a package
                      APEX_AI.GENERATE / CHAT   variable, g_registry:
                      (p_tools => ..., ...)      tool name -> real function)
                                 |
                                 v
                 the AI model decides to call the tool
                                 |
                                 v
             ai_tool_builder.generic_response_handler
                (the callback APEX_AI invokes for you)
                                 |
                                 v
              looks up g_registry, runs the real function
                          dynamically via native SQL
                                 |
                                 v
                    result goes back to the AI model,
                    which produces its final answer
```

## Quick start

```sql
DECLARE
  l_tools    apex_ai.t_tools := apex_ai.t_tools();
  l_response CLOB;
BEGIN
  apex_session.create_session(p_app_id => 100, p_page_id => 1, p_username => 'ADMIN');
  ai_tool_builder.reset_registry;

  l_tools.EXTEND;
  l_tools(1) := ai_tool_builder.build_tool('MY_PKG.CONVERT_CURRENCY');

  l_response := apex_ai.generate(
    p_prompt                     => 'How much is 100 USD in EUR?',
    p_service_static_id          => 'MY_AI_SERVICE',
    p_tools                      => l_tools,
    p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER',
    p_max_tool_roundtrips        => 5 );

  DBMS_OUTPUT.PUT_LINE(l_response);
END;
/
```

Multiple tools at once — see [`test_multi_tool.sql`](tests/test_multi_tool.sql) for a full working example:

```sql
l_tools := ai_tool_builder.build_tools(
  apex_t_varchar2('MY_PKG.CONVERT_CURRENCY', 'MY_PKG.GET_HEADCOUNT') );
```

## Registry lifetime: build tools in the same request

`build_tool`/`build_tools` record each tool in a package variable (`g_registry`), and `generic_response_handler` reads it when the model asks for a tool. Package variables live as long as the **database session's package state** does, so:

- **Do:** call `build_tool`/`build_tools` in the same request, ideally the same PL/SQL block, as the `apex_ai.generate`/`chat` call. The handler runs synchronously inside that call, in the same session, so it sees the registry.
- **Don't:** build tools in one request (for example a page-load process) and call `generate`/`chat` in another (an AJAX callback, a background job, a workflow). Package state may not be there, and the model is told `Error: no function registered for tool "..."`.
- **When in doubt, rebuild on every request.** Building only reads `ALL_ARGUMENTS` and `ALL_SOURCE`.

```sql
-- Safe per-request pattern: build and call together, every time.
l_tools := ai_tool_builder.build_tools(apex_t_varchar2('MY_PKG.CONVERT_CURRENCY'));
l_response := apex_ai.generate(
  p_prompt                     => :P1_QUESTION,
  p_service_static_id          => 'MY_AI_SERVICE',
  p_tools                      => l_tools,
  p_response_handler_procedure => 'AI_TOOL_BUILDER.GENERIC_RESPONSE_HANDLER',
  p_max_tool_roundtrips        => 5 );
```

If a tool call arrives for a name that isn't registered, the handler writes a warning to the APEX debug log (`ai_tool_builder: no function registered for tool ...`). Enable debug and look for it.

## API

| Call | What it does |
|---|---|
| `build_tool(p_function_name, p_tool_name DEFAULT NULL)` | Reads one function, returns its `apex_ai.t_tool`, registers it |
| `build_tools(p_function_names apex_t_varchar2)` | Same, for several functions — returns `apex_ai.t_tools` |
| `reset_registry` | Clears everything `build_tool`/`build_tools` has registered |
| `generic_response_handler(p_param, p_result)` | The callback `apex_ai` invokes to actually run a tool |

`p_function_name` accepts `'FUNC'`, `'PKG.FUNC'`, or `'OWNER.PKG.FUNC'`. Tool names default to the function name, lowercased.

## Contents

| File | Purpose |
|---|---|
| [`src/AI_TOOL_BUILDER.pks`](src/AI_TOOL_BUILDER.pks) | Package spec — public API |
| [`src/AI_TOOL_BUILDER.pkb`](src/AI_TOOL_BUILDER.pkb) | Package body — implementation |
| [`tests/setup_demo_tools.sql`](tests/setup_demo_tools.sql) | Creates `demo_tools_pkg`, the example tools (including an overloaded function and its wrappers) the other scripts use. Run first |
| [`tests/test_single_tool.sql`](tests/test_single_tool.sql) | Runnable example: one tool (sanity check without an LLM, then a real agent run) |
| [`tests/test_multi_tool.sql`](tests/test_multi_tool.sql) | Runnable example: two tools via `build_tools` (sanity check without an LLM, then a real agent run) |
| [`tests/test_overloads.sql`](tests/test_overloads.sql) | Checks that an overloaded function raises `ORA-20703` and that per-overload wrapper functions work (no LLM needed) |
| [`tests/test_dates.sql`](tests/test_dates.sql) | Runnable example: `DATE`, `TIMESTAMP` and `TIMESTAMP WITH TIME ZONE` parameters (sanity check without an LLM, then a real agent run) |

## Prerequisites

- **APEX 26.1+**, with a Generative AI Service already configured as a shared component (you'll pass its static ID as `p_service_static_id`).
- **A real, logged-in APEX session** before calling `apex_ai.generate`/`chat` with tools: `apex_session.create_session(p_app_id, p_page_id, p_username)`. `apex_util.set_workspace` alone is not enough once tools are involved — `apex_ai` validates the caller and will raise `Could not validate caller for user ""` without a real session.
- Any existing app ID and username in your workspace (only used to establish the session).

## Installation

Compile the package into the schema that your APEX workspace is mapped to (the schema that will run the agent). The spec must be compiled before the body.

```sql
-- SQLcl / SQL*Plus, from the repository root
@src/AI_TOOL_BUILDER.pks
@src/AI_TOOL_BUILDER.pkb
```

In APEX, you can instead paste each file into **SQL Workshop > SQL Commands** and run it, spec first.

Check that it compiled:

```sql
SELECT object_type, status FROM user_objects WHERE object_name = 'AI_TOOL_BUILDER';
-- expect PACKAGE and PACKAGE BODY, both VALID
```

If either shows `INVALID` or the compile reports errors, the most likely cause is APEX older than 26.1 (the `apex_ai` tool types don't exist). See [Prerequisites](#prerequisites).

To confirm it works without calling an LLM, run [`tests/setup_demo_tools.sql`](tests/setup_demo_tools.sql) and then [`tests/test_overloads.sql`](tests/test_overloads.sql), or the first block of [`tests/test_single_tool.sql`](tests/test_single_tool.sql). To remove it: `DROP PACKAGE ai_tool_builder;`.

## What it can and can't do

- **Functions only**, not procedures — packaged or standalone both work. `build_tool` raises `ORA-20702` if the name isn't found, isn't visible to the calling schema, or isn't a function, so a typo fails at build time instead of during a tool call.
- **`IN` parameters only**, and only `NUMBER`-like, `VARCHAR2`/`CHAR`, `CLOB`, `BOOLEAN`, `DATE` or `TIMESTAMP` types. A `BOOLEAN` is sent to the model as a boolean and passed to the function as a real `BOOLEAN` on every Oracle version (the handler binds `'Y'`/`'N'` and converts it in the generated call, because `DBMS_SQL` can't bind a `BOOLEAN` before 23ai).
- **`DATE`, `TIMESTAMP` and `TIMESTAMP WITH [LOCAL] TIME ZONE` parameters are supported.** They are sent to the model as text, with an ISO 8601 example appended to the parameter description. The handler accepts `YYYY-MM-DD`, optionally followed by a time (`HH24:MI[:SS[.FF]]`) after a space or `T`, and optionally a UTC offset (`+05:30` or `Z`). It converts the text with explicit format masks, so `NLS_DATE_FORMAT` and other NLS settings have no effect. A time-zone parameter with no offset uses the session time zone; a `DATE` or `TIMESTAMP` takes the time as written and ignores any offset. Anything else (`14 March 2027`, `03/14/2027`, `2027-02-30`) raises `ORA-20704`, whose message tells the model to send an ISO 8601 value, so it can retry.
- **Numeric parameters are sent to the model as numbers** and bound as `NUMBER`. If a model returns a number as a string, it is bound as text and Oracle converts it on the call.
- **Tool results are capped at 32,767 characters** (a `VARCHAR2` limit in the dispatch code).
- **Overloaded functions are rejected** — `build_tool` raises `ORA-20703` if the function name has more than one overload. Wrap each overload in a function with its own unique name and `@tool`/`@param` comments, and register the wrappers. See [`tests/test_overloads.sql`](tests/test_overloads.sql).
- **Asking a model to call two tools in one sentence can be unreliable** — this is model behavior, not something this package causes. Sequential requests ("call A, then call B") work fine.

`generic_response_handler` never raises: a failed dispatch or unknown tool name is returned to the model as `Error ...` text instead of crashing the request.

## How the call is built (and why it is safe from injection)

The handler runs the function with a small dynamic PL/SQL block. Two kinds of values go into it:

- **Identifiers** (the function name and parameter names): taken from the name *you* pass to `build_tool` and from `ALL_ARGUMENTS`, never from the model. Each part is validated and quoted with `DBMS_ASSERT.ENQUOTE_NAME` when the tool is registered, and the function is confirmed to exist. The model can only choose among tools you registered.
- **Argument values**: always bound with `DBMS_SQL.BIND_VARIABLE`, never concatenated into the SQL text.

Names are used exactly as Oracle stores them, so lowercase quoted identifiers (`"myFunc"`) are not supported.

## What the model sees when a tool fails

The model never sees raw `SQLERRM`, because Oracle error text can contain schema, package, table and column names. The handler logs the full detail with `apex_debug.error` (message, function name and error backtrace) and returns a sanitized message:

| Failure | What the model receives |
|---|---|
| Your function raises `RAISE_APPLICATION_ERROR(-20000..-20999, ...)` | `Error from tool "name": <your message>` (first line, max 500 chars) |
| Argument rejected on conversion (`ORA-06502`, `ORA-01722`, `ORA-01858`, `ORA-01861`) | `Error: tool "name" rejected an argument value (wrong format or too long). Check the argument values and try again.` |
| Any other error | `Error: tool "name" failed. Do not retry with the same arguments.` |
| Unregistered tool name | `Error: no function registered for tool "name"` |

Because `-20xxx` messages are passed through on purpose (they are how a tool tells the model "customer not found" or "amount must be positive"), write them as if the model, and therefore the end user, will read them: no table names, no internal IDs. To see the real error, enable APEX debug and search for `ai_tool_builder:`.

The default tool description (used when a function has no `@tool` comment) is `Runs the "<tool name>" tool.` and does not include the owner, package or function name.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for how to test changes (there's no CI; it needs a live APEX 26.1+ workspace) and the two extension points (`map_type` for parameter types, `extract_doc_block`/`tag_value` for the comment convention).

## License

[MIT](LICENSE)
