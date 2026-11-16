Set-StrictMode -Version Latest

function Format-KestraMessage {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Message)

    $json = ConvertTo-Json -InputObject $Message -Compress -Depth 100
    # Kestra matches one line, and Java treats U+0085, U+2028 and U+2029 as line terminators.
    foreach ($code in 0x85, 0x2028, 0x2029) {
        $json = $json.Replace([string][char]$code, ('\u{0:x4}' -f $code))
    }
    '::' + $json + '::'
}

# Written to the console, not the pipeline, so callers that capture function output do not swallow it.
function Send-KestraMessage {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Message)

    [Console]::Out.WriteLine((Format-KestraMessage -Message $Message))
}

function Send-KestraMetric {
    param(
        [string] $Name,
        [string] $Type,
        [double] $Value,
        [System.Collections.IDictionary] $Tags
    )

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        throw [System.ArgumentException]::new("Metric '$Name' value must be a finite number.")
    }
    if ($null -eq $Tags) {
        $Tags = @{}
    }

    $metric = [ordered]@{ name = $Name; type = $Type; value = $Value; tags = $Tags }
    Send-KestraMessage -Message @{ metrics = @($metric) }
}

function Send-KestraOutput {
    <#
    .SYNOPSIS
    Sends task outputs to Kestra, readable as outputs.<task>.vars.<key>.
    .EXAMPLE
    Send-KestraOutput @{ disabled = 42; status = 'ok' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)] [System.Collections.IDictionary] $Outputs)

    if ($Outputs.Count -eq 0) {
        throw [System.ArgumentException]::new('Outputs must contain at least one key, for example @{ rows = 42 }.')
    }
    Send-KestraMessage -Message @{ outputs = $Outputs }
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
        [Parameter(Position = 2)] [System.Collections.IDictionary] $Tags
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
        [Parameter(Position = 2)] [System.Collections.IDictionary] $Tags
    )

    Send-KestraMetric -Name $Name -Type 'gauge' -Value $Value -Tags $Tags
}

function Send-KestraTimer {
    <#
    .SYNOPSIS
    Sends a timer metric to Kestra, from a duration in seconds or by timing a script block.
    .DESCRIPTION
    With -ScriptBlock, the block's output is returned. No metric is sent if the block throws.
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
        [System.Collections.IDictionary] $Tags
    )

    if ($PSCmdlet.ParameterSetName -eq 'Seconds') {
        Send-KestraMetric -Name $Name -Type 'timer' -Value $Seconds -Tags $Tags
        return
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & $ScriptBlock
    Send-KestraMetric -Name $Name -Type 'timer' -Value $watch.Elapsed.TotalSeconds -Tags $Tags
}

function Write-KestraLog {
    <#
    .SYNOPSIS
    Writes a log line that Kestra records at the given level.
    .EXAMPLE
    Write-KestraLog Warn '3 accounts could not be disabled'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error')] [string] $Level,
        [Parameter(Mandatory, Position = 1)] [string] $Message
    )

    $log = [ordered]@{ level = $Level.ToUpperInvariant(); message = $Message }
    Send-KestraMessage -Message @{ logs = @($log) }
}

Export-ModuleMember -Function Send-KestraOutput, Send-KestraCounter, Send-KestraGauge, Send-KestraTimer, Write-KestraLog
