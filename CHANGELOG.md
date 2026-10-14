# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-13

### Added

- `DATE`, `TIMESTAMP`, `TIMESTAMP WITH TIME ZONE` and `TIMESTAMP WITH LOCAL TIME ZONE` parameters. The model sends them as ISO 8601 text, and an example format is appended to the parameter description. The handler accepts `YYYY-MM-DD`, an optional time after a space or `T`, and an optional UTC offset (`+05:30` or `Z`), then converts the text with explicit format masks, so `NLS_DATE_FORMAT` has no effect. Previously these parameters were described as plain text and converted by Oracle using the session NLS format, which failed on an ISO date such as `2027-03-14` when the format was `DD-MON-RR`.
- `ORA-20704` for a date/time value the handler cannot read. The message is passed to the model and tells it to send an ISO 8601 value.
- `get_weekday`, `add_hours` and `describe_moment` in `tests/setup_demo_tools.sql`, and `tests/test_dates.sql`.
- `BOOLEAN` parameters. They are sent to the model as a boolean and passed to the function as a real `BOOLEAN` on every Oracle version. The handler binds `'Y'`/`'N'` text and the generated call converts it with `(:n = 'Y')`, so it does not depend on `DBMS_SQL` supporting a `BOOLEAN` bind (added in 23ai). If a model sends text instead of `true`/`false`, `true`, `y`, `yes` and `1` count as true, and `false`, `n`, `no` and `0` count as false.
- `ORA-20703` when `build_tool` is given an overloaded function. Wrap each overload in a function with its own unique name and `@tool` / `@param` comments, and register the wrappers.
- `tests/test_overloads.sql`. The overloaded `get_customer` and its two wrappers live in `demo_tools_pkg` (`tests/setup_demo_tools.sql`).
- This changelog.

### Changed

- Numeric parameters (`NUMBER`, `INTEGER`, `PLS_INTEGER`, `BINARY_INTEGER`, `FLOAT`) are now sent to the model as numbers and bound to the function as `NUMBER`. If a model returns a number as a string, it is bound as text and Oracle converts it on the call. Previously every parameter was sent as text, which avoided an `ORA-20960` raised for numeric-typed parameters by `meta.llama-3.3-70b-instruct` on OCI Generative AI (a deprecated model).
- The package files moved to `src/` and the test scripts to `tests/`.
- `README.md` and `CONTRIBUTING.md` describe the new parameter handling, the overload rule and the test scripts.

### Removed

- The "(numeric value, pass as a plain number)" hint that was appended to numeric parameter descriptions.
- `ORA-20701`, which `build_tool` raised for `BOOLEAN` parameters.
- `tests/test_name_validation.sql` and `test_tool_builder.sql`.

## [1.0.0] - 2026-09-02

Initial release.
