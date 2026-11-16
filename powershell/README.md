# Kestra (PowerShell)

Send outputs, metrics and logs from PowerShell script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. No dependencies, works on PowerShell 5.1 and 7+.

## Install

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/kestra-io/libs/main/powershell/Kestra/Kestra.psm1 -OutFile Kestra.psm1
Import-Module ./Kestra.psm1
```

## Usage

```yaml
id: disable_stale_accounts
namespace: company.ops

tasks:
  - id: cleanup
    type: io.kestra.plugin.scripts.powershell.Script
    beforeCommands:
      - Invoke-WebRequest https://raw.githubusercontent.com/kestra-io/libs/main/powershell/Kestra/Kestra.psm1 -OutFile Kestra.psm1
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
| `Send-KestraOutput @{ ... }` | Task outputs under `outputs.<task>.vars` |
| `Send-KestraCounter <name> <value> [@{ tags }]` | Counter metric |
| `Send-KestraGauge <name> <value> [@{ tags }]` | Gauge metric |
| `Send-KestraTimer <name> <seconds>` or `-ScriptBlock { }` | Timer metric. A script block is timed and its output returned |
| `Write-KestraLog <Trace\|Debug\|Info\|Warn\|Error> <message>` | Log line at that level |

The commands write straight to the console, so `$x = Send-KestraOutput ...` or calls inside a function whose output is captured still reach Kestra.
