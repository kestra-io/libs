# kestra (Ruby)

Send outputs, metrics, logs and assets from Ruby script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. A single file with no dependencies outside the standard library.

## Install

The gem is not on RubyGems yet. Download the file in `beforeCommands`:

```bash
curl -fsSLo kestra.rb https://raw.githubusercontent.com/kestra-io/libs/main/ruby/lib/kestra.rb
```

Pin a release tag instead of `main` in production flows, so a push to `main` cannot change what runs.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.ruby.Script
    beforeCommands:
      - curl -fsSLo kestra.rb https://raw.githubusercontent.com/kestra-io/libs/main/ruby/lib/kestra.rb
    script: |
      require_relative "kestra"

      orders = Kestra.timer("fetch") { (1..120).to_a }
      Kestra.outputs(count: orders.size, status: "ok")
      Kestra.counter("orders", orders.size, tags: { source: "shop" })
      Kestra.gauge("queue_size", 3)
      Kestra.logger.warn("2 orders had no customer")

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra.outputs(hash)` | Task outputs under `outputs.<task>.vars` |
| `Kestra.assets(inputs: [...], outputs: [...])` | Input and output assets of the task |
| `Kestra.counter(name, value, tags: {})` | Counter metric |
| `Kestra.gauge(name, value, tags: {})` | Gauge metric |
| `Kestra.timer(name, seconds, tags: {})` or `Kestra.timer(name) { ... }` | Timer metric. A block is timed and its result returned |
| `Kestra.logger.debug/info/warn/error(message)` | Log line at that level. `fatal` is sent as ERROR |
| `Kestra.context(path = nil)` | The execution context as a Hash, for example `Kestra.context["labels"]`. Needs `executionContext: true` on the task |

Metric tags are sent as strings, and invalid bytes in a log message become U+FFFD. `Kestra.logger` is a standard `Logger`, so it can be passed to any library that accepts one. Values are serialized with `JSON.generate`, so a `Time` is sent as its `to_s` string. Call `iso8601` first if a downstream task parses it.
