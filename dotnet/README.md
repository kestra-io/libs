# Kestra (.NET)

Send outputs, metrics, logs and assets from C# and F# script tasks to Kestra, and read the execution context. Each send call prints one `::{...}::` line to stdout, which Kestra reads. One small library with no dependencies beyond .NET, for .NET 8 and later.

## Install

The library is not on NuGet yet. Build it from this repository in `beforeCommands` and reference the DLL with `#r`, as in the flows below. The build needs access to GitHub and nuget.org. The flows pin a release tag, so a push to `main` cannot change what runs. Use the latest tag that includes the .NET library.

## Usage

C#, with `dotnet-script`:

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.csharp.Script
    beforeCommands:
      - git clone --depth 1 --branch v1.4.0 https://github.com/kestra-io/libs /tmp/libs
      - dotnet build /tmp/libs/dotnet/Kestra -c Release -o /tmp/kestra
    script: |
      #r "/tmp/kestra/Kestra.dll"

      var orders = Kestra.Timer("fetch", () => Enumerable.Range(1, 120).ToList());
      Kestra.Outputs(new { count = orders.Count, status = "ok" });
      Kestra.Counter("orders", orders.Count, new { source = "shop" });
      Kestra.Gauge("queue_size", 3);
      Kestra.Logger.Warning("{Count} orders had no customer", 2);

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

F#, with `dotnet fsi`, uses the same calls:

```yaml
  - id: import
    type: io.kestra.plugin.scripts.fsharp.Script
    beforeCommands:
      - git clone --depth 1 --branch v1.4.0 https://github.com/kestra-io/libs /tmp/libs
      - dotnet build /tmp/libs/dotnet/Kestra -c Release -o /tmp/kestra
    script: |
      #r "/tmp/kestra/Kestra.dll"

      Kestra.Outputs {| count = 120; status = "ok" |}
      Kestra.Counter("orders", 120, dict [ ("source", "shop") ])
      Kestra.Logger.Warning("{Count} orders had no customer", 2)
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra.Outputs(object)` | Task outputs under `outputs.<task>.vars`, from an anonymous object, a record or a dictionary. An empty one sends nothing |
| `Kestra.Assets(new { inputs = ..., outputs = ... })` | Input and output assets of the task, as lists. An empty one sends nothing |
| `Kestra.Counter(name, value, tags)` | Counter metric |
| `Kestra.Gauge(name, value, tags)` | Gauge metric |
| `Kestra.Timer(name, seconds or TimeSpan, tags)` or `Kestra.Timer(name, () => ..., tags)` | Timer metric. A function is timed and its result returned. Use `await Kestra.TimerAsync(...)` for async code |
| `Kestra.Logger.Trace/Debug/Information/Warning/Error/Critical(message, args)` | Log line at that level. `message` is a template such as `"{Count} rows"`, filled with `args` in order. An exception as first argument, or as an unused last argument, is added with its stack trace. `Critical` is sent as ERROR |
| `Kestra.Context(path)` | The execution context as a `JsonObject`, for example `Kestra.Context()["labels"]`. Needs `executionContext: true` on the task. Without `path`, or with an empty one, falls back to the base64 `KESTRA_CONTEXT` variable. A `path` that does not exist throws `FileNotFoundException` |

Values are written with System.Text.Json: objects by their public properties and fields, enums as names, dates and `TimeSpan` as ISO text (`PT1M30.5S`), tuples as lists and `byte[]` as base64. Two keys that read the same, such as `1` and `"1"`, fail the call. NaN, Infinity and numbers past the double range fail the call. Tags are optional, an object or a dictionary of single values, and sent as strings. A metric value is a `double`: convert a `decimal` with `(double)` in C#, and an `int64` or a `decimal` with `float` in F#. A log call never fails: a value whose `ToString()` throws is logged as `[FAILED ToString()]`. A collection is logged with its first 100 items. Other sequences are logged with `ToString()` and never enumerated, so a lazy or single-pass one is left untouched.
