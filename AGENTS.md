# Kestra libs

One library per language, so script tasks can talk to Kestra without hand-writing `::{...}::` lines. Python (`python/src/kestra.py`) is the reference implementation.

## Same features in every language

Every library exposes all of these. A feature added to one library is added to all of them, or tracked in an issue under #41.

| Feature | Line sent to Kestra |
|---------|---------------------|
| Outputs | `{"outputs": {...}}` |
| Counter, gauge and timer metrics with optional string tags | `{"metrics": [{"name", "type", "value", "tags"}]}`. `value` is a plain JSON number (timers in seconds) and tag values are strings, or Kestra drops the metric |
| Logs at TRACE, DEBUG, INFO, WARN and ERROR | `{"logs": [{"level", "message"}]}`. `message` is always a string |
| Assets | `{"assets": {"inputs": [...], "outputs": [...]}}` |
| Execution context | Read, not sent. See below |

Use the language's own idioms for the API (a `Logger` in Ruby, `slog` in Go, `Verb-Noun` commands in PowerShell, PSR-3 logger methods in PHP, Log4perl method names in Perl, LuaLogging method names in Lua, SLF4J-style `{}` placeholders in Groovy, Microsoft.Extensions.Logging method names in .NET, a `Logging.AbstractLogger` in Julia), but keep the names recognizable across languages.

## Execution context

Read `path` (empty counts as unset), then `KESTRA_EXECUTION_CONTEXT_FILE` (empty counts as unset), then `.kestra-execution-context.json`, which the task writes when `executionContext: true`. Only without `path`, fall back to the base64-encoded `KESTRA_CONTEXT` variable: a `path` that does not exist always fails, so a typo is never hidden. Only a missing file falls back: a directory or an unreadable file fails with its read error. Fail with distinct messages when `KESTRA_CONTEXT` is not base64, when the content is not valid JSON, and when it is JSON but not an object. Load lazily, cache the default context, and fail with a clear error outside a Kestra task, using the language's "file not found" error where it has one.

## Line format

- Kestra matches `^::(\{.*})::$` on a single line (`TaskLogLineMatcher` in kestra core). One call prints one line.
- Escape U+0085, U+2028 and U+2029: Java treats them as line terminators, so a raw one splits the payload.
- Write UTF-8 bytes, or escape non-ASCII, so the console code page cannot change the text (Windows PowerShell).
- Never send a value Kestra cannot read: validate input first and fail with a plain sentence that says what to pass.

## Values

- Empty outputs or assets send nothing and do not fail, as in Python.
- Asset `inputs` and `outputs` are lists. Any other key fails.
- NaN and Infinity fail with a plain sentence, never sent as `null`. A value the library cannot send fails with a plain sentence, not the serializer's error. Dates are sent as ISO text, and a SQL DATE or TIME keeps its local value.
- Two keys that read as the same JSON key, such as `1` and `"1"`, fail instead of one value being lost. The same goes for tag names.
- Tag values are single values sent as strings: booleans as `true` and `false`, numbers as their text.
- A timer that takes a function checks the name and tags before running it, returns the function's result, and sends nothing if it throws.
- A log call never fails or hangs: not on a value whose string conversion throws, not on a value that contains itself. A lazy or single-pass sequence is never enumerated, and a library that expands collections itself shows at most 1000 items.
- A released library never changes the line a working call sends, and never starts failing a call that works. Python and JavaScript keep `"True"` tags, `null` for NaN, duplicate keys, unchecked assets and the JavaScript line for empty outputs for that reason. Fix only what fails or sends a line Kestra drops.

## Code

- The features above need no dependency beyond the standard library, plus a JSON package where the language has none built in (`jsonlite` for R).
- Write each line in one call and flush it. Kestra reads a pipe, where output is buffered, so an unflushed line arrives late or is lost when the task is killed. Lines from several threads never interleave.
- Test every feature, including the line terminators and non-ASCII text. Each language has a CI job, and the `release` job needs all of them.
- A new language gets a README with install, a flow example and a table of calls, and a row in the root README.
