# Kestra .NET Client

This .NET client library provides functionality to interact with the Kestra engine from C# / .NET script tasks, enabling output passing, custom metrics, structured logging, asset tracking, and execution context access.

---

## Installation

Add the package via NuGet:

```bash
dotnet add package Kestra
```

Or reference in `.csx` script tasks (`io.kestra.plugin.scripts.csharp.Script`):

```csharp
#r "nuget:Kestra, 0.1.0"
using Kestra;
```

Compatible with `.NET 8.0` and `.NET Standard 2.0+`.

---

## Usage

### Outputs

Send key-value outputs back to the Kestra server:

```csharp
using Kestra;

KestraClient.Outputs(new
{
    result_count = 150,
    status = "COMPLETED",
    metadata = new
    {
        worker_id = "dotnet-worker-1"
    }
});
```

### Metrics

Send custom metrics (counters, timers, gauges) to Kestra:

#### Counters
```csharp
// Simple counter
KestraClient.Counter("items_processed", 100);

// Counter with tags
KestraClient.Counter("api_requests", 1, new { endpoint = "/orders", status = 200 });
```

#### Timers
```csharp
// Explicit duration in seconds
KestraClient.Timer("batch_duration", 12.45, new { batch_id = "b102" });

// Measure execution time of an action automatically
KestraClient.Timer("database_sync", () =>
{
    // execute long running task
    Thread.Sleep(50);
}, new { table = "orders" });
```

#### Gauges
```csharp
KestraClient.Gauge("memory_usage_mb", 256.4, new { host = "worker-01" });
```

### Assets

Track data assets and pipeline artifacts:

```csharp
KestraClient.Assets(new
{
    inputs = new[]
    {
        new { id = "raw_orders", type = "FILE" }
    },
    outputs = new[]
    {
        new { id = "cleaned_orders_table", type = "TABLE", metadata = new { rows = 5000 } }
    }
});
```

### Logging

Send structured logs captured at the appropriate log level by Kestra:

```csharp
var logger = KestraClient.Logger;

logger.Trace("Detailed trace event");
logger.Debug("Debugging connection parameters");
logger.Info("Processing started for batch 42");
logger.Warn("Rate limit approaching threshold");
logger.Error("Failed to parse incoming payload");

// Log multiple messages at once
logger.Info("Step 1 complete", "Step 2 complete");
```

### Execution Context

Access execution metadata injected by Kestra:

```csharp
using var context = KestraClient.Context();

string flowId = context.RootElement.GetProperty("flow").GetProperty("id").GetString();
string executionId = context.RootElement.GetProperty("execution").GetProperty("id").GetString();
```

---

## Testing

Run tests using the .NET CLI:

```bash
dotnet test
```
