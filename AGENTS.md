# Kestra libs

One library per language, so script tasks can talk to Kestra without hand-writing `::{...}::` lines. Python (`python/src/kestra.py`) is the reference implementation.

## Same features in every language

Every library exposes all of these. A feature added to one library is added to all of them, or tracked in an issue under #41.

| Feature | Line sent to Kestra |
|---------|---------------------|
| Outputs | `{"outputs": {...}}` |
| Counter, gauge and timer metrics with optional string tags | `{"metrics": [{"name", "type", "value", "tags"}]}`. Timers are in seconds |
| Logs at TRACE, DEBUG, INFO, WARN and ERROR | `{"logs": [{"level", "message"}]}`. `message` is always a string |
| Assets | `{"assets": {"inputs": [...], "outputs": [...]}}` |
| Execution context | Read, not sent. See below |

Use the language's own idioms for the API (a `Logger` in Ruby, `slog` in Go, `Verb-Noun` commands in PowerShell), but keep the names recognizable across languages.

## Execution context

Read `path`, then `KESTRA_EXECUTION_CONTEXT_FILE`, then `.kestra-execution-context.json`, which the task writes when `executionContext: true`. Fall back to the base64-encoded `KESTRA_CONTEXT` variable. Load lazily, cache the default context, and fail with the language's "file not found" error outside a Kestra task.

## Line format

- Kestra matches `^::(\{.*})::$` on a single line (`TaskLogLineMatcher` in kestra core). One call prints one line.
- Escape U+0085, U+2028 and U+2029: Java treats them as line terminators, so a raw one splits the payload.
- Write UTF-8 bytes, or escape non-ASCII, so the console code page cannot change the text (Windows PowerShell).
- Never send a value Kestra cannot read: validate input first and fail with a plain sentence that says what to pass.

## Code

- Standard library only, plus the JSON package where the language has none built in (`jsonlite` for R).
- Write lines in one call, so concurrent output never interleaves.
- Test every feature, including the line terminators and non-ASCII text. CI tests the oldest supported and the latest language version, and the `release` job needs every language job.
- Each language has a README with install, a flow example and a table of calls. List new languages in the root README.
