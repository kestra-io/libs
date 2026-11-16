Set-StrictMode -Version Latest

# Kestra matches one line, and Java treats these as line terminators.
$LineTerminators = @{ ([string][char]0x85) = '\u0085'; ([string][char]0x2028) = '\u2028'; ([string][char]0x2029) = '\u2029' }

# Written to the console, not the pipeline, so callers that capture function output do not swallow it.
function Send-KestraMessage {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Message)

    $json = ConvertTo-Json -InputObject $Message -Compress -Depth 100
    foreach ($terminator in $LineTerminators.GetEnumerator()) {
        $json = $json.Replace($terminator.Key, $terminator.Value)
    }
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
    param([Parameter(Mandatory, Position = 0)] [object] $Outputs)

    $map = ConvertTo-KestraMap -InputObject $Outputs -What 'Outputs'
    if ($map.Count -eq 0) {
        throw [System.ArgumentException]::new('Outputs must contain at least one key, for example @{ rows = 42 }.')
    }
    Send-KestraMessage -Message @{ outputs = $map }
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
        [Parameter(Position = 2)] [object] $Tags
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
        [Parameter(Mandatory, Position = 1)] [AllowEmptyString()] [string] $Message
    )

    $log = [ordered]@{ level = $Level.ToUpperInvariant(); message = $Message }
    Send-KestraMessage -Message @{ logs = @($log) }
}

Export-ModuleMember -Function Send-KestraOutput, Send-KestraCounter, Send-KestraGauge, Send-KestraTimer, Write-KestraLog
