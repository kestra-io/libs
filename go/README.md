# kestra (Go)

Send outputs, metrics and logs from Go script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. Standard library only, Go 1.21+.

## Install

```bash
go mod init flow
go get github.com/kestra-io/libs/go@main
go mod tidy
```

Pin a release instead of `main` in production flows, so a push to `main` cannot change what runs. Releases are tagged `go/vX.Y.Z`, for example `go get github.com/kestra-io/libs/go@v0.1.0`.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.go.Script
    beforeCommands:
      - go mod init flow
      - go get github.com/kestra-io/libs/go@main
      - go mod tidy
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
| `kestra.Counter(name, value, tags)` | Counter metric |
| `kestra.Gauge(name, value, tags)` | Gauge metric |
| `kestra.Timer(name, duration, tags)` | Timer metric |
| `kestra.Logger().Debug/Info/Warn/Error(msg, args...)` | Log line at that level, attributes appended as `key=value` |

`tags` may be nil. Every call returns an error for invalid input, for example empty outputs or a NaN metric. `kestra.Logger()` is a standard `*slog.Logger`, so `slog.SetDefault(kestra.Logger())` sends all `slog` logging to Kestra. Calls are safe from several goroutines.
