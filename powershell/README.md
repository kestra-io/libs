# Kestra (PowerShell)

Send outputs, metrics and logs from PowerShell script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. No dependencies, works on PowerShell 5.1 and 7+.

## Install

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/kestra-io/libs/main/powershell/Kestra/Kestra.psm1 -OutFile Kestra.psm1 -UseBasicParsing
Import-Module ./Kestra.psm1
```

Replace `main` with a release tag in production flows, so a push to `main` cannot change what runs. `-UseBasicParsing` is needed on Windows PowerShell 5.1 without Internet Explorer and ignored on PowerShell 7.

## Usage

```yaml
id: disable_stale_accounts
namespace: company.ops

tasks:
  - id: cleanup
    type: io.kestra.plugin.scripts.powershell.Script
    beforeCommands:
      - Invoke-WebRequest https://raw.githubusercontent.com/kestra-io/libs/main/powershell/Kestra/Kestra.psm1 -OutFile Kestra.psm1 -UseBasicParsing
    script: |
      Import-Module ./Kestra.psm1

      $accounts = Send-KestraTimer fetch -ScriptBlock { 1..42 }
      Send-KestraOutput @{ disabled = $accounts.Count; status = 'ok' }
      Send-KestraCounter disabled_accounts $accounts.Count @{ domain = 'corp' }
      Write-KestraLog Warn '3 accounts could not be disabled'

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Disabled {{ outputs.cleanup.vars.disabled }} accounts"
```

| Command | Result in Kestra |
|---------|------------------|
| `Send-KestraOutput <hashtable or PSCustomObject>` | Task outputs under `outputs.<task>.vars`. Also takes pipeline input. An empty map sends nothing |
| `Send-KestraAsset @{ inputs = @(...); outputs = @(...) }` | Input and output assets of the task. Both are optional arrays, and an empty map sends nothing |
| `Send-KestraCounter <name> <value> [@{ tags }]` | Counter metric |
| `Send-KestraGauge <name> <value> [@{ tags }]` | Gauge metric |
| `Send-KestraTimer <name> <seconds> [@{ tags }]` or `-ScriptBlock { }` | Timer metric. A script block runs in the caller's scope, is timed and its output returned. Tags are checked before it runs, and no metric is sent if it throws |
| `Write-KestraLog <Trace\|Debug\|Info\|Warn\|Error> <message...>` | One log line per message, at that level. Also takes pipeline input. A collection sends one line per item, at most 1000, and a lazy sequence is sent as its type name. A message whose `ToString()` throws is sent as its type name |
| `Get-KestraContext [-Path <file>]` | The execution context, for example `(Get-KestraContext).labels.env`. Needs `executionContext: true` on the task. Without `-Path`, a missing file falls back to the base64 `$env:KESTRA_CONTEXT`. A directory or an unreadable file throws |

In a `catch` block, send the whole error with `Write-KestraLog Error ($_ | Out-String)`. Metric tags are sent as strings, booleans as `true` or `false`, and two tags whose names read the same throw. On pwsh 7, `Get-KestraContext` turns ISO date strings into `DateTime` values, while Windows PowerShell 5.1 keeps them as strings.

The commands write straight to the console, so `$x = Send-KestraOutput ...` or calls inside a function whose output is captured still reach Kestra.

Send plain values, hashtables or `PSCustomObject`s. Raw .NET objects such as `Get-Item` or `Get-Process` results serialize their whole object graph, so pick the properties first, for example `Get-Process | Select-Object Name, Id`. Dates are sent as ISO text, and a `DateTime` without a time zone stays local. Outputs throw on NaN, Infinity and two keys whose names read the same.
