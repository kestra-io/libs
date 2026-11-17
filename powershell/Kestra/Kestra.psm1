Set-StrictMode -Version Latest

$ContextFile = '.kestra-execution-context.json'
$ContextJson = $null

# Written to the console, not the pipeline, so callers that capture function output do not swallow it.
function Send-KestraMessage {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Message)

    $json = ConvertTo-Json -InputObject $Message -Compress -Depth 100
    # Pure ASCII survives any console code page, and escaping U+0085/2028/2029 keeps the payload on the one line Kestra matches.
    $json = [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u{0:x4}' -f [int][char]$match.Value })
    [Console]::Out.WriteLine('::' + $json + '::')
}

# Accepts a hashtable or a PSCustomObject, as returned by ConvertFrom-Json, Invoke-RestMethod or Select-Object.
function ConvertTo-KestraMap {
    param([object] $InputObject, [string] $What)

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $map[$property.Name] = $property.Value
        }
        return $map
    }
    throw [System.ArgumentException]::new("$What must be a hashtable or a PSCustomObject, for example @{ rows = 42 }.")
}

function Send-KestraMetric {
    param(
        [string] $Name,
        [string] $Type,
        [double] $Value,
        [object] $Tags
    )

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        throw [System.ArgumentException]::new("Metric '$Name' value must be a finite number.")
    }
    $Tags = if ($null -eq $Tags) { @{} } else { ConvertTo-KestraMap -InputObject $Tags -What 'Tags' }

    $metric = [ordered]@{ name = $Name; type = $Type; value = $Value; tags = $Tags }
    Send-KestraMessage -Message @{ metrics = @($metric) }
}

function Send-KestraOutput {
    <#
    .SYNOPSIS
    Sends task outputs to Kestra, readable as outputs.<task>.vars.<key>.
    .EXAMPLE
    Send-KestraOutput @{ disabled = 42; status = 'ok' }
    .EXAMPLE
    Send-KestraOutput (Invoke-RestMethod https://api.example.com/status)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipeline)] [object] $Outputs)

    process {
        $map = ConvertTo-KestraMap -InputObject $Outputs -What 'Outputs'
        if ($map.Count -eq 0) {
            throw [System.ArgumentException]::new('Outputs must contain at least one key, for example @{ rows = 42 }.')
        }
        Send-KestraMessage -Message @{ outputs = $map }
    }
}

function Send-KestraAsset {
    <#
    .SYNOPSIS
    Declares the input and output assets of the task, for example tables or files it reads and writes.
    .EXAMPLE
    Send-KestraAsset @{ outputs = @(@{ id = 'sales.orders'; type = 'TABLE' }) }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0, ValueFromPipeline)] [object] $Assets)

    process {
        $map = ConvertTo-KestraMap -InputObject $Assets -What 'Assets'
        if ($map.Count -eq 0) {
            throw [System.ArgumentException]::new('Assets must contain inputs or outputs, for example @{ outputs = @(@{ id = ''sales.orders''; type = ''TABLE'' }) }.')
        }
        Send-KestraMessage -Message @{ assets = $map }
    }
}

function Send-KestraCounter {
    <#
    .SYNOPSIS
    Sends a counter metric to Kestra.
    .EXAMPLE
    Send-KestraCounter rows 15000 @{ source = 's3' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory, Position = 1)] [double] $Value,
        [Parameter(Position = 2)] [object] $Tags
    )

    Send-KestraMetric -Name $Name -Type 'counter' -Value $Value -Tags $Tags
}

function Send-KestraGauge {
    <#
    .SYNOPSIS
    Sends a gauge metric to Kestra.
    .EXAMPLE
    Send-KestraGauge queue_size 3
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory, Position = 1)] [double] $Value,
        [Parameter(Position = 2)] [object] $Tags
    )

    Send-KestraMetric -Name $Name -Type 'gauge' -Value $Value -Tags $Tags
}

function Send-KestraTimer {
    <#
    .SYNOPSIS
    Sends a timer metric to Kestra, from a duration in seconds or by timing a script block.
    .DESCRIPTION
    With -ScriptBlock, the block runs in the caller's scope and its output is returned. No metric is sent if the block throws.
    .EXAMPLE
    Send-KestraTimer export 2.5
    .EXAMPLE
    $users = Send-KestraTimer fetch -ScriptBlock { Get-ADUser -Filter * }
    #>
    [CmdletBinding(DefaultParameterSetName = 'Seconds')]
    param(
        [Parameter(Mandatory, Position = 0)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Seconds')] [double] $Seconds,
        [Parameter(Mandatory, ParameterSetName = 'ScriptBlock')] [scriptblock] $ScriptBlock,
        [Parameter(Position = 2)] [object] $Tags
    )

    if ($PSCmdlet.ParameterSetName -eq 'Seconds') {
        Send-KestraMetric -Name $Name -Type 'timer' -Value $Seconds -Tags $Tags
        return
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    # Dot-sourced, so variables the block sets stay visible to the caller.
    . $ScriptBlock
    Send-KestraMetric -Name $Name -Type 'timer' -Value $watch.Elapsed.TotalSeconds -Tags $Tags
}

function Write-KestraLog {
    <#
    .SYNOPSIS
    Writes one log line per message, which Kestra records at the given level.
    .EXAMPLE
    Write-KestraLog Warn '3 accounts could not be disabled'
    .EXAMPLE
    try { Get-Item missing.txt -ErrorAction Stop } catch { Write-KestraLog Error ($_ | Out-String) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error')] [string] $Level,
        [Parameter(Mandatory, Position = 1, ValueFromPipeline, ValueFromRemainingArguments)] [AllowEmptyString()] [string[]] $Message
    )

    process {
        $logs = @(foreach ($line in $Message) { [ordered]@{ level = $Level.ToUpperInvariant(); message = $line } })
        Send-KestraMessage -Message @{ logs = $logs }
    }
}

function Get-KestraContext {
    <#
    .SYNOPSIS
    Returns the execution context (labels, inputs, vars, trigger, outputs of earlier tasks), read once. Each call returns a new object the caller may change.
    .DESCRIPTION
    Reads -Path, then $env:KESTRA_EXECUTION_CONTEXT_FILE, then .kestra-execution-context.json, which the task writes when executionContext is true.
    Without -Path, falls back to the base64-encoded $env:KESTRA_CONTEXT. Throws System.IO.FileNotFoundException outside a Kestra task.
    .EXAMPLE
    (Get-KestraContext).labels.env
    #>
    [CmdletBinding()]
    param([string] $Path)

    if (-not $Path -and $null -ne $script:ContextJson) {
        return ConvertFrom-Json -InputObject $script:ContextJson
    }

    $file = if ($Path) { $Path } elseif ($env:KESTRA_EXECUTION_CONTEXT_FILE) { $env:KESTRA_EXECUTION_CONTEXT_FILE } else { $ContextFile }
    $json = if (Test-Path -LiteralPath $file -PathType Leaf) {
        Get-Content -LiteralPath $file -Raw -Encoding UTF8
    } elseif (-not $Path -and $env:KESTRA_CONTEXT) {
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($env:KESTRA_CONTEXT))
    } else {
        throw [System.IO.FileNotFoundException]::new("No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT environment variable is not set. The execution context is only available when the script runs inside a Kestra task.", $file)
    }

    $context = ConvertFrom-Json -InputObject $json
    if (-not $Path) {
        $script:ContextJson = $json
    }
    $context
}

Export-ModuleMember -Function Send-KestraOutput, Send-KestraAsset, Send-KestraCounter, Send-KestraGauge, Send-KestraTimer, Write-KestraLog, Get-KestraContext
