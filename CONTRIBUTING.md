# Contributing

Issues and PRs are welcome.

## Testing changes

There's no CI for this repo — testing `ai_tool_builder` requires a live Oracle database with **APEX 26.1+** and a Generative AI Service configured as a shared component, so it can't be automated in a hosted runner. Don't expect a green checkmark on your PR; instead:

1. Compile [`AI_TOOL_BUILDER.pks`](AI_TOOL_BUILDER.pks) and [`AI_TOOL_BUILDER.pkb`](AI_TOOL_BUILDER.pkb) against your own APEX workspace.
2. Run [`test_tool_builder.sql`](test_tool_builder.sql) after filling in your own app ID, username, and AI Service static ID (the placeholders are marked with `<-- ...`).
3. In your PR description, say what you tested and paste the relevant output (e.g. `DBMS_OUTPUT` from the sanity-check block, or the agent's final response).

## Coding conventions for `@tool` / `@param` comments

If your change touches how the doc-comment block is written or parsed:

- Keep every line of the block starting with `--`. The parser (`extract_doc_block` / `tag_value` in the package body) stops at the first non-`--` line, so mixing in `/* ... */` breaks the scan — see the README's [Why this exists](README.md#why-this-exists) section for the exact rule.
- `@tool:` and `@param <name>:` are matched case-insensitively, and the text after the colon is taken verbatim (trimmed) as the description — keep descriptions to one line.
- Placement still matters: above the declaration for packaged functions, after `IS`/`AS` for standalone ones. See the README's [Packaged and standalone functions are both supported](README.md#packaged-and-standalone-functions-are-both-supported) section before changing the placement logic.

## Where to make common changes

- **Add support for another parameter type** — edit `map_type` in [`AI_TOOL_BUILDER.pkb`](AI_TOOL_BUILDER.pkb).
- **Change the comment convention** — edit `extract_doc_block` / `tag_value` in the same file.

## Pull requests

- Keep PRs focused on one change. Explain the *why*, not just the *what*, in the description.
- Update the README if the change affects usage, limitations, or the API surface described there.
