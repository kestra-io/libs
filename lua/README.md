# Kestra (Lua)

Send outputs, metrics, logs and assets from Lua script tasks to Kestra, and read the execution context. Each send call prints one `::{...}::` line to stdout, which Kestra reads. A single pure Lua file with no dependencies, for Lua 5.1 to 5.5 and LuaJIT.

## Install

The module is not on LuaRocks yet, and the default `nickblah/lua` image has no `curl`. Download the file with a Kestra task and pass it to the script in `inputFiles`, as in the flow below. Pin a release tag instead of `main` in production flows, so a push to `main` cannot change what runs.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: kestra_lua
    type: io.kestra.plugin.core.http.Download
    uri: https://raw.githubusercontent.com/kestra-io/libs/main/lua/kestra.lua

  - id: import
    type: io.kestra.plugin.scripts.lua.Script
    inputFiles:
      kestra.lua: "{{ outputs.kestra_lua.uri }}"
    script: |
      local kestra = require('kestra')

      local orders = kestra.timer('fetch', function()
        local rows = {}
        for i = 1, 120 do rows[i] = i end
        return rows
      end)
      kestra.outputs({ count = #orders, status = 'ok' })
      kestra.counter('orders', #orders, { source = 'shop' })
      kestra.gauge('queue_size', 3)
      kestra.logger:warn('%d orders had no customer', 2)

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `kestra.outputs(outputs)` | Task outputs under `outputs.<task>.vars` |
| `kestra.assets({ inputs = {...}, outputs = {...} })` | Input and output assets of the task |
| `kestra.counter(name, value, tags)` | Counter metric |
| `kestra.gauge(name, value, tags)` | Gauge metric |
| `kestra.timer(name, seconds, tags)` or `kestra.timer(name, fn, tags)` | Timer metric. A function is timed and its results returned |
| `kestra.logger:trace/debug/info/warn/error/fatal(message, ...)` | Log line at that level. With more values, `message` is a `string.format` pattern. `fatal` is sent as ERROR |
| `kestra.context(path)` | The execution context as a table, for example `kestra.context().labels`. Needs `executionContext: true` on the task. Without `path`, or with an empty one, falls back to the base64 `KESTRA_CONTEXT` variable. A `path` that does not exist fails |
| `kestra.array(t)` | Marks `t`, or a new table, to be sent as a JSON list |

A table with the keys 1 to n is sent as a list, and any other table as an object with string keys, so `{ [1001] = 'a' }` is sent as `{"1001": "a"}`. An empty table is sent as `{}`: use `kestra.array()` for an empty list. Empty asset `inputs` and `outputs` are sent as lists already. Tags are optional and sent as strings. Lua strings are bytes: outputs must be valid UTF-8, and invalid bytes in a log message become U+FFFD. A log call never fails: a pattern that does not match its values is logged as is, with the values after it. JSON `null` in the context reads as `nil`.

Plain Lua has no precise clock, so a timed function is measured in 10 ms steps on Linux and in seconds elsewhere. Pass seconds measured with your own clock for anything shorter.
