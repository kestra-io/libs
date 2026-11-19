# Kestra (Groovy)

Send outputs, metrics, logs and assets from Groovy script tasks to Kestra, and read the execution context. Each send call prints one `::{...}::` line to stdout, which Kestra reads. A single file with no dependencies beyond Groovy itself, for Groovy 3 and later.

## Install

The class is not on Maven Central yet. Download `Kestra.groovy` into the working directory in `beforeCommands`, where `groovy` finds it:

```bash
curl -fsSLo Kestra.groovy https://raw.githubusercontent.com/kestra-io/libs/main/groovy/Kestra.groovy
```

Pin a release tag instead of `main` in production flows, so a push to `main` cannot change what runs.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.groovy.Script
    beforeCommands:
      - curl -fsSLo Kestra.groovy https://raw.githubusercontent.com/kestra-io/libs/main/groovy/Kestra.groovy
    script: |
      def orders = Kestra.timer('fetch') { (1..120).toList() }
      Kestra.outputs(count: orders.size(), status: 'ok')
      Kestra.counter('orders', orders.size(), [source: 'shop'])
      Kestra.gauge('queue_size', 3)
      Kestra.logger.warn('{} orders had no customer', 2)

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra.outputs(Map outputs)` | Task outputs under `outputs.<task>.vars`. An empty map sends nothing |
| `Kestra.assets(inputs: [...], outputs: [...])` | Input and output assets of the task, as lists. An empty map sends nothing |
| `Kestra.counter(name, value, tags = [:])` or `Kestra.counter(name, value, env: 'qa')` | Counter metric |
| `Kestra.gauge(name, value, tags = [:])` | Gauge metric |
| `Kestra.timer(name, seconds, tags = [:])` or `Kestra.timer(name, tags = [:]) { ... }` | Timer metric, in seconds or as a `Duration`. A closure is timed and its result returned |
| `Kestra.logger.trace/debug/info/warn/error(message, Object... args)` | Log line at that level. `{}` placeholders are filled from `args`, and a `Throwable` as the last argument is added with its stack trace, as in SLF4J. A value whose `toString()` throws is logged as `[FAILED toString()]` |
| `Kestra.context(String path = null)` | The execution context as a map, for example `Kestra.context().labels`. Needs `executionContext: true` on the task. Without `path`, or with an empty one, falls back to the base64 `KESTRA_CONTEXT` variable. A `path` that does not exist throws `FileNotFoundException` |

Tags are optional, given as a map or as named arguments, and sent as strings. Outputs accept maps, lists, arrays, strings, numbers, booleans and null. Dates, `java.time` values and durations, enums, `GString`s, files, paths, URIs and UUIDs are sent as their text. Other objects throw, so convert them first. Keys are strings, numbers, booleans or enums, and two keys that read as the same text, such as `1` and `'1'`, throw instead of one value being lost. An integer of any size keeps its value, while NaN, Infinity and a decimal past the double range throw.
