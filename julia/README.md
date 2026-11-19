# Kestra (Julia)

Send outputs, metrics, logs and assets from Julia script tasks to Kestra, and read the execution context. Each send call prints one `::{...}::` line to stdout, which Kestra reads. A single file using only the standard library, for Julia 1.6 and later.

## Install

The module is not in the General registry yet. Download `Kestra.jl` with a Kestra task, pass it to the script in `inputFiles` and `include` it, as in the flow below. Pin a release tag instead of `main` in production flows, so a push to `main` cannot change what runs.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: kestra_jl
    type: io.kestra.plugin.core.http.Download
    uri: https://raw.githubusercontent.com/kestra-io/libs/main/julia/Kestra.jl

  - id: import
    type: io.kestra.plugin.scripts.julia.Script
    inputFiles:
      Kestra.jl: "{{ outputs.kestra_jl.uri }}"
    script: |
      include("Kestra.jl")
      using Logging
      global_logger(Kestra.logger())

      orders = Kestra.timer("fetch") do
          collect(1:120)
      end
      Kestra.outputs(count = length(orders), status = "ok")
      Kestra.counter("orders", length(orders), (source = "shop",))
      Kestra.gauge("queue_size", 3)
      @warn "orders had no customer" count = 2

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra.outputs(; outputs...)` or `Kestra.outputs(dict)` | Task outputs under `outputs.<task>.vars`. An empty call sends nothing |
| `Kestra.assets(inputs = [...], outputs = [...])` | Input and output assets of the task, as vectors. An empty call sends nothing |
| `Kestra.counter(name, value, tags)` | Counter metric |
| `Kestra.gauge(name, value, tags)` | Gauge metric |
| `Kestra.timer(name, seconds, tags)` or `Kestra.timer(name, tags) do ... end` | Timer metric. Takes seconds or a `Dates` period. A function or block is timed and its result returned |
| `global_logger(Kestra.logger())` | `@debug`, `@info`, `@warn` and `@error` lines reach Kestra at that level, with their key-value pairs as `key=value`. An `exception = (e, catch_backtrace())` pair adds the stack trace |
| `Kestra.context(path)` | The execution context as a `Dict`, for example `Kestra.context()["labels"]`. Needs `executionContext: true` on the task. Without `path`, or with an empty one, falls back to the base64 `KESTRA_CONTEXT` variable. A `path` that does not exist fails with a `SystemError` |

Tags are optional, a dictionary or named tuple, and sent as strings. Dictionaries and named tuples are sent as objects, vectors, tuples and sets as lists, and dates, periods, symbols and enums as text. `nothing` and `missing` are sent as `null`, and JSON `null` in the context reads as `nothing`. NaN, Inf and invalid UTF-8 in outputs fail the call. A log call never fails: invalid UTF-8 becomes U+FFFD and a value that cannot be printed is logged as `[FAILED string()]`. Julia drops levels below `Debug`: call `Logging.disable_logging(Logging.BelowMinLevel)` to send them as TRACE.
