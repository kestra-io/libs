# kestra (Go)

Send outputs, metrics, logs and assets from Go script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. Standard library only, Go 1.21+.

## Install

```bash
go mod init flow
go get github.com/kestra-io/libs/go@main
go mod tidy
```

The `go` tool writes progress such as `go: downloading ...` to stderr, which Kestra logs as ERROR, so the flow below redirects it with `2>&1`.

Each release `vX.Y.Z` also tags `go/vX.Y.Z`, so from the first release that includes this module, pin it with `go get github.com/kestra-io/libs/go@vX.Y.Z` instead of `main`. A pinned version cannot change when `main` does.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.go.Script
    beforeCommands:
      - go mod init flow 2>&1
      - go get github.com/kestra-io/libs/go@main 2>&1
      - go mod tidy 2>&1
    script: |
      package main

      import (
          "time"

          "github.com/kestra-io/libs/go/kestra"
      )

      func main() {
          start := time.Now()
          orders := 120
          kestra.Timer("fetch", time.Since(start), nil)
          kestra.Outputs(map[string]any{"count": orders, "status": "ok"})
          kestra.Counter("orders", float64(orders), map[string]string{"source": "shop"})
          kestra.Logger().Warn("orders had no customer", "count", 2)
      }

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `kestra.Outputs(map[string]any)` | Task outputs under `outputs.<task>.vars` |
| `kestra.Assets(map[string]any{"inputs": ..., "outputs": ...})` | Input and output assets of the task |
| `kestra.Counter(name, value, tags)` | Counter metric |
| `kestra.Gauge(name, value, tags)` | Gauge metric |
| `kestra.Timer(name, duration, tags)` | Timer metric |
| `kestra.Logger().Debug/Info/Warn/Error(msg, args...)` | Log line at that level, attributes appended as `key=value` |
| `kestra.Context()` or `kestra.LoadContext(path)` | The execution context as a map, read once by `Context()`. Needs `executionContext: true` on the task |

`tags` may be nil. Every call returns an error for invalid input, for example a NaN output or metric, or an asset key other than `inputs` and `outputs`, which must be lists. Empty outputs or assets send nothing. Log attribute values are expanded at most 10 levels deep and 1000 items long, so a map or slice that contains itself is safe to log. `kestra.Logger()` is a standard `*slog.Logger`, so `slog.SetDefault(kestra.Logger())` sends all `slog` logging to Kestra. Calls are safe from several goroutines.
