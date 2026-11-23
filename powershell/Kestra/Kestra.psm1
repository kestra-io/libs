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
    throw [System.ArgumentException]::new("$What must be a hashtable or a PSCustomObject, for example @{ key = 'value' }.")
}

$MaxDepth = 90

# Copies a value into one ConvertTo-Json sends as Kestra reads it, and fails on what it would send wrong or lose.
function ConvertTo-KestraValue {
    param([object] $Value, [int] $Depth = 0)

    if ($Depth -gt $MaxDepth) {
        throw [System.ArgumentException]::new("This value cannot be sent to Kestra as JSON: it is nested more than $MaxDepth levels deep or contains itself.")
    }
    if ($null -eq $Value) {
        return $null
    }
    # [string] also drops the note properties Windows PowerShell would send as an object.
    if ($Value -is [string] -or $Value -is [char]) {
        return [string]$Value
    }
    if (($Value -is [double] -or $Value -is [float]) -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) {
        throw [System.ArgumentException]::new('This value cannot be sent to Kestra as JSON. Replace NaN and Infinity with $null.')
    }
    # Windows PowerShell would send \/Date(...)\/. A DateTime without a time zone stays local.
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $map = ConvertTo-KestraMap -InputObject $Value -What 'A map'
        $copy = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        # GetEnumerator, since $map[$key] with an [int] key reads an [ordered] dictionary by position.
        foreach ($entry in $map.GetEnumerator()) {
            $text = [string]$entry.Key
            if ($copy.Contains($text)) {
                throw [System.ArgumentException]::new("This value cannot be sent to Kestra as JSON: two keys read as '$text'.")
            }
            $copy[$text] = ConvertTo-KestraValue -Value $entry.Value -Depth ($Depth + 1)
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-KestraValue -Value $item -Depth ($Depth + 1)))
        }
        return , $items.ToArray()
    }
    $Value
}

# Checks the tags before any work is done, and returns them as strings, which is how Kestra reads them.
function ConvertTo-KestraTag {
    param([string] $Name, [object] $Tags)

    $stringTags = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ($null -ne $Tags) {
        $map = ConvertTo-KestraMap -InputObject $Tags -What 'Tags'
        foreach ($entry in $map.GetEnumerator()) {
            $key = $entry.Key
            $tag = $entry.Value
            if ($null -eq $tag -or ($tag -isnot [string] -and $tag -is [System.Collections.IEnumerable]) -or $tag -is [System.Management.Automation.PSCustomObject]) {
                throw [System.ArgumentException]::new("Metric '$Name' tag '$key' must be a single value, for example @{ env = 'prod' }.")
            }
            $text = [string]$key
            if ($stringTags.Contains($text)) {
                throw [System.ArgumentException]::new("Metric '$Name' has two tags named '$text'.")
            }
            $stringTags[$text] = if ($tag -is [bool]) { if ($tag) { 'true' } else { 'false' } } else { [string]$tag }
        }
    }
    $stringTags
}

$MaxLogItems = 1000

# Expands only a finite collection, so a lazy or endless sequence is never enumerated. A LINQ iterator also implements ICollection`1.
function Test-KestraLogCollection {
    param([object] $Value)

    $null -ne $Value -and $Value -isnot [System.Collections.IDictionary] -and $Value -isnot [System.Collections.IEnumerator] -and
        ($Value -is [System.Collections.ICollection] -or $null -ne $Value.GetType().GetInterface('ICollection`1'))
}

# The first $MaxLogItems items, then '...' if there are more.
function Get-KestraLogItem {
    param([System.Collections.IEnumerable] $Collection)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Collection) {
        if ($items.Count -eq $MaxLogItems) {
            $items.Add('...')
            break
        }
        $items.Add($item)
    }
    , $items
}

# ToString() for a collection, since [string] would enumerate it.
function ConvertTo-KestraItemText {
    param([object] $Value)

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { $Value.ToString() } else { [string]$Value }
}

# A log call never fails: a ToString() that throws or returns $null shows the type name instead.
function ConvertTo-KestraText {
    param([object] $Value)

    if ($null -eq $Value) {
        return ''
    }
    try {
        $text = if (Test-KestraLogCollection $Value) {
            # One level joined with spaces, as [string] does, so a collection that contains itself shows its type name.
            @(foreach ($item in (Get-KestraLogItem $Value)) { ConvertTo-KestraItemText $item }) -join ' '
        } else {
            ConvertTo-KestraItemText $Value
        }
    } catch {
        $text = $null
    }
    if ($null -eq $text) { "<$($Value.GetType().FullName)>" } else { $text }
}

function Send-KestraMetric {
    param(
        [string] $Name,
        [string] $Type,
        [object] $Value,
        [object] $Tags
    )

    $stringTags = ConvertTo-KestraTag -Name $Name -Tags $Tags
    # Typed as object, since a [double] parameter turns $null into 0 before any check runs.
    $number = if ($Value -isnot [bool]) { $Value -as [double] }
    if ($null -eq $number -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw [System.ArgumentException]::new("Metric '$Name' value must be a finite number.")
    }

    $metric = [ordered]@{ name = $Name; type = $Type; value = $number; tags = $stringTags }
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
        # get_Count(), since $map.Count reads a key named count.
        if ($map.get_Count() -gt 0) {
            Send-KestraMessage -Message @{ outputs = (ConvertTo-KestraValue -Value $map) }
        }
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
        foreach ($entry in $map.GetEnumerator()) {
            $key = $entry.Key
            if ($key -cne 'inputs' -and $key -cne 'outputs') {
                throw [System.ArgumentException]::new("Assets hold only inputs and outputs, not '$key'.")
            }
            $list = $entry.Value
            if ($list -isnot [System.Collections.IList] -or $list -is [System.Collections.IDictionary]) {
                throw [System.ArgumentException]::new("Asset $key must be an array, for example @(@{ id = 'sales.orders'; type = 'TABLE' }).")
            }
        }
        if ($map.get_Count() -gt 0) {
            Send-KestraMessage -Message @{ assets = (ConvertTo-KestraValue -Value $map) }
        }
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
        [Parameter(Mandatory, Position = 1)] [object] $Value,
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
        [Parameter(Mandatory, Position = 1)] [object] $Value,
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
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Seconds')] [object] $Seconds,
        [Parameter(Mandatory, ParameterSetName = 'ScriptBlock')] [scriptblock] $ScriptBlock,
        [Parameter(Position = 2)] [object] $Tags
    )

    if ($PSCmdlet.ParameterSetName -eq 'Seconds') {
        Send-KestraMetric -Name $Name -Type 'timer' -Value $Seconds -Tags $Tags
        return
    }

    # Checked before the block runs, so a typo does not cost a long run.
    $null = ConvertTo-KestraTag -Name $Name -Tags $Tags
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
        [Parameter(Mandatory, Position = 1, ValueFromPipeline, ValueFromRemainingArguments)] [AllowNull()] [AllowEmptyString()] [AllowEmptyCollection()] [object] $Message
    )

    process {
        # Windows PowerShell wraps a single remaining argument in a list, which PowerShell 6 and later do not.
        if ($PSVersionTable.PSVersion.Major -lt 6 -and $Message -is [System.Collections.Generic.List[object]] -and $Message.Count -eq 1) {
            $Message = $Message[0]
        }
        # Typed as object, so binding never enumerates a lazy or endless sequence.
        if (Test-KestraLogCollection $Message) {
            $lines = Get-KestraLogItem $Message
        } else {
            $lines = [object[]]::new(1)
            $lines[0] = $Message
        }
        $logs = @(foreach ($line in $lines) { [ordered]@{ level = $Level.ToUpperInvariant(); message = (ConvertTo-KestraText $line) } })
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
    # Only a missing file falls back: a directory or an unreadable file is reported.
    $isFile = Test-Path -LiteralPath $file
    $json = if ($isFile) {
        if (Test-Path -LiteralPath $file -PathType Container) {
            throw [System.IO.IOException]::new("Kestra execution context file '$file' cannot be read: it is a directory.")
        }
        try {
            [System.IO.File]::ReadAllText($PSCmdlet.GetUnresolvedProviderPathFromPSPath($file), [System.Text.Encoding]::UTF8)
        } catch {
            throw [System.IO.IOException]::new("Kestra execution context file '$file' cannot be read: $($_.Exception.InnerException.Message)", $_.Exception.InnerException)
        }
    } elseif (-not $Path -and $env:KESTRA_CONTEXT) {
        try {
            $bytes = [System.Convert]::FromBase64String($env:KESTRA_CONTEXT)
        } catch {
            throw [System.FormatException]::new('The KESTRA_CONTEXT environment variable is not valid base64.')
        }
        [System.Text.Encoding]::UTF8.GetString($bytes)
    } elseif ($Path) {
        throw [System.IO.FileNotFoundException]::new("Kestra execution context file '$Path' does not exist.", $Path)
    } else {
        throw [System.IO.FileNotFoundException]::new("No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT environment variable is not set. The execution context is only available when the script runs inside a Kestra task.", $file)
    }

    $source = if ($isFile) { $file } else { 'KESTRA_CONTEXT' }
    $context = try {
        ConvertFrom-Json -InputObject $json -ErrorAction Stop
    } catch {
        throw [System.IO.InvalidDataException]::new("The execution context in $source is not valid JSON.")
    }
    if ($context -isnot [System.Management.Automation.PSCustomObject]) {
        throw [System.IO.InvalidDataException]::new("The execution context in $source is not a JSON object.")
    }
    if (-not $Path) {
        $script:ContextJson = $json
    }
    $context
}

Export-ModuleMember -Function Send-KestraOutput, Send-KestraAsset, Send-KestraCounter, Send-KestraGauge, Send-KestraTimer, Write-KestraLog, Get-KestraContext
