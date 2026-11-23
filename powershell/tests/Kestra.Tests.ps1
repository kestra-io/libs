BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Kestra/Kestra.psd1') -Force

    function Get-Emitted([scriptblock] $Action) {
        $original = [Console]::Out
        $writer = [System.IO.StringWriter]::new()
        [Console]::SetOut($writer)
        try {
            $null = & $Action
        }
        finally {
            [Console]::SetOut($original)
        }
        @($writer.ToString().TrimEnd("`r", "`n") -split "`r?`n")
    }

    function ConvertFrom-Emitted([string] $Line) {
        $Line | Should -Match '^::\{.*\}::$'
        $Line.Substring(2, $Line.Length - 4) | ConvertFrom-Json
    }
}

Describe 'Send-KestraOutput' {
    It 'writes one line with scalars, nested values and arrays' {
        $lines = @(Get-Emitted { Send-KestraOutput @{ accuracy = 0.912345678; model = 'glm'; ids = @(1, 2); nested = @{ ok = $true } } })

        $lines.Count | Should -Be 1
        $payload = ConvertFrom-Emitted $lines[0]
        $payload.outputs.accuracy | Should -Be 0.912345678
        $payload.outputs.model | Should -Be 'glm'
        $payload.outputs.ids | Should -Be @(1, 2)
        $payload.outputs.nested.ok | Should -BeTrue
    }

    It 'reads an [ordered] dictionary with integer keys by key, not by position' {
        Get-Emitted { Send-KestraOutput ([ordered]@{ 1 = 'a'; 0 = 'b' }) } | Should -BeExactly '::{"outputs":{"1":"a","0":"b"}}::'
        Get-Emitted { Send-KestraOutput ([ordered]@{ 5 = 'x' }) } | Should -BeExactly '::{"outputs":{"5":"x"}}::'
        $tags = (ConvertFrom-Emitted (Get-Emitted { Send-KestraCounter rows 1 ([ordered]@{ 1 = 'a'; 0 = 'b' }) })).metrics[0].tags
        $tags.'1' | Should -BeExactly 'a'
        $tags.'0' | Should -BeExactly 'b'
    }

    It 'keeps multi-line strings and Java line terminators on one line' {
        $text = "a`nb" + [char]0x2028 + 'c' + [char]0x2029 + 'd' + [char]0x85 + 'e'
        $lines = @(Get-Emitted { Send-KestraOutput @{ text = $text } })

        $lines.Count | Should -Be 1
        $lines[0] | Should -BeLikeExactly '*a\nb\u2028c\u2029d\u0085e*'
        (ConvertFrom-Emitted $lines[0]).outputs.text | Should -BeExactly $text
    }

    It 'is not swallowed when the caller captures the function output' {
        $lines = @(Get-Emitted { $captured = Send-KestraOutput @{ rows = 1 }; $captured | Should -BeNullOrEmpty })

        $lines[0] | Should -BeExactly '::{"outputs":{"rows":1}}::'
    }

    It 'accepts a PSCustomObject, as returned by ConvertFrom-Json or Invoke-RestMethod' {
        $status = '{"rows": 42, "nested": {"ok": true}}' | ConvertFrom-Json
        $payload = ConvertFrom-Emitted (Get-Emitted { Send-KestraOutput $status })

        $payload.outputs.rows | Should -Be 42
        $payload.outputs.nested.ok | Should -BeTrue
    }

    It 'escapes non-ASCII, so a console code page cannot mangle it' {
        $name = 'caf' + [char]0xe9 + ' ' + [char]0xd83d + [char]0xde00
        $line = Get-Emitted { Send-KestraOutput @{ name = $name } }

        $line | Should -BeExactly '::{"outputs":{"name":"caf\u00e9 \ud83d\ude00"}}::'
        (ConvertFrom-Emitted $line).outputs.name | Should -BeExactly $name
    }

    It 'counts keys correctly when one of them is named count' {
        Get-Emitted { Send-KestraOutput @{ count = 0 } } | Should -BeExactly '::{"outputs":{"count":0}}::'
        Get-Emitted { 'count,ok', '0,1' | ConvertFrom-Csv | Send-KestraOutput } | Should -BeExactly '::{"outputs":{"count":"0","ok":"1"}}::'
    }

    It 'takes outputs from the pipeline' {
        Get-Emitted { '{"rows": 1}' | ConvertFrom-Json | Send-KestraOutput } |
            Should -BeExactly '::{"outputs":{"rows":1}}::'
    }

    It 'sends nothing for empty outputs and rejects values that are not maps' {
        Get-Emitted { Send-KestraOutput @{} } | Should -BeExactly ''
        Get-Emitted { Send-KestraOutput ([pscustomobject]@{}) } | Should -BeExactly ''
        { Send-KestraOutput @(1, 2) } | Should -Throw '*must be a hashtable or a PSCustomObject*'
    }

    It 'fails on two keys that read as the same text, at any depth' {
        $outputs = @{ 1 = 'a' }
        $outputs['1'] = 'b'
        { Send-KestraOutput $outputs } | Should -Throw "*two keys read as '1'*"
        { Send-KestraOutput @{ nested = $outputs } } | Should -Throw "*two keys read as '1'*"
    }

    It 'fails on NaN and Infinity and on a map that contains itself' {
        { Send-KestraOutput @{ x = [double]::NaN } } | Should -Throw '*Replace NaN and Infinity with $null*'
        { Send-KestraOutput @{ x = @(1, [double]::NegativeInfinity) } } | Should -Throw '*Replace NaN and Infinity with $null*'
        $map = @{}
        $map.self = $map
        { Send-KestraOutput $map } | Should -Throw '*nested more than 90 levels deep or contains itself*'
    }

    It 'sends dates as ISO text, and a date without a time zone stays local' {
        $local = [datetime]::new(2026, 11, 16, 10, 0, 0, [System.DateTimeKind]::Unspecified)
        $utc = [datetime]::new(2026, 11, 16, 9, 0, 0, [System.DateTimeKind]::Utc)
        $offset = [datetimeoffset]::new(2026, 11, 16, 10, 0, 0, [timespan]::FromHours(1))

        Get-Emitted { Send-KestraOutput ([ordered]@{ local = $local; utc = $utc; offset = $offset }) } |
            Should -BeExactly '::{"outputs":{"local":"2026-11-16T10:00:00.0000000","utc":"2026-11-16T09:00:00.0000000Z","offset":"2026-11-16T10:00:00.0000000+01:00"}}::'
    }

    It 'keeps empty and one-element arrays as arrays' {
        Get-Emitted { Send-KestraOutput ([ordered]@{ none = @(); one = @(1); nested = @(@(), @(2)) }) } |
            Should -BeExactly '::{"outputs":{"none":[],"one":[1],"nested":[[],[2]]}}::'
    }
}

Describe 'metrics' {
    It 'sends a counter with empty tags by default' {
        $metric = (ConvertFrom-Emitted (Get-Emitted { Send-KestraCounter rows 15000 })).metrics[0]

        $metric.name | Should -Be 'rows'
        $metric.type | Should -Be 'counter'
        $metric.value | Should -Be 15000
        @($metric.tags.PSObject.Properties).Count | Should -Be 0
    }

    It 'sends a gauge with tags' {
        $metric = (ConvertFrom-Emitted (Get-Emitted { Send-KestraGauge queue 3 @{ env = 'prod' } })).metrics[0]

        $metric.type | Should -Be 'gauge'
        $metric.value | Should -Be 3
        $metric.tags.env | Should -Be 'prod'
    }

    It 'accepts PSCustomObject tags and positional timer tags' {
        $gauge = (ConvertFrom-Emitted (Get-Emitted { Send-KestraGauge queue 3 ([pscustomobject]@{ env = 'prod' }) })).metrics[0]
        $timer = (ConvertFrom-Emitted (Get-Emitted { Send-KestraTimer export 2.5 @{ env = 'prod' } })).metrics[0]

        $gauge.tags.env | Should -Be 'prod'
        $timer.tags.env | Should -Be 'prod'
    }

    It 'sends tag values as strings and rejects nested or null ones' {
        $metric = (ConvertFrom-Emitted (Get-Emitted { Send-KestraGauge queue 3 ([ordered]@{ shard = 2; ok = $true }) })).metrics[0]

        $metric.tags.shard | Should -BeExactly '2'
        $metric.tags.ok | Should -BeExactly 'true'
        { Send-KestraGauge queue 3 @{ shard = @{ a = 1 } } } | Should -Throw "*tag 'shard' must be a single value*"
        { Send-KestraGauge queue 3 @{ shard = @(1, 2) } } | Should -Throw "*tag 'shard' must be a single value*"
        { Send-KestraGauge queue 3 @{ shard = $null } } | Should -Throw "*tag 'shard' must be a single value*"
    }

    It 'fails on two tags that read as the same text' {
        $tags = @{ 1 = 'a' }
        $tags['1'] = 'b'
        { Send-KestraGauge queue 3 $tags } | Should -Throw "Metric 'queue' has two tags named '1'."
    }

    It 'rejects a missing or non-numeric value instead of sending 0' {
        { Send-KestraCounter rows $null } | Should -Throw
        { Send-KestraCounter rows $true } | Should -Throw "*must be a finite number*"
        { Send-KestraCounter rows 'many' } | Should -Throw "*must be a finite number*"
        (ConvertFrom-Emitted (Get-Emitted { Send-KestraCounter rows '3' })).metrics[0].value | Should -Be 3
    }

    It 'rejects non-finite values and empty names' {
        { Send-KestraGauge queue ([double]::NaN) } | Should -Throw "*Metric 'queue' value must be a finite number*"
        { Send-KestraCounter '' 1 } | Should -Throw
    }

    It 'times a script block and returns its output' {
        $lines = @(Get-Emitted { $script:result = Send-KestraTimer fit -ScriptBlock { Start-Sleep -Milliseconds 200; 42 } })

        $script:result | Should -Be 42
        $metric = (ConvertFrom-Emitted $lines[0]).metrics[0]
        $metric.type | Should -Be 'timer'
        $metric.value | Should -BeGreaterOrEqual 0.2
    }

    It 'checks the tags before running the script block, and sends nothing if it throws' {
        $script:isRun = $false
        { Send-KestraTimer fit -ScriptBlock { $script:isRun = $true } -Tags @{ env = @(1, 2) } } | Should -Throw "*tag 'env' must be a single value*"
        $script:isRun | Should -BeFalse
        Get-Emitted { try { Send-KestraTimer fit -ScriptBlock { throw 'boom' } } catch { $null = $_ } } | Should -BeExactly ''
    }

    It 'runs the script block in the caller scope' {
        Get-Emitted { Send-KestraTimer fit -ScriptBlock { $rows = 5 }; $rows | Should -Be 5 }
    }

    It 'sends a timer from seconds' {
        $metric = (ConvertFrom-Emitted (Get-Emitted { Send-KestraTimer export 2.5 })).metrics[0]

        $metric.type | Should -Be 'timer'
        $metric.value | Should -Be 2.5
    }
}

Describe 'Write-KestraLog' {
    It 'writes the level in upper case' {
        Get-Emitted { Write-KestraLog warn '3 accounts skipped' } |
            Should -BeExactly '::{"logs":[{"level":"WARN","message":"3 accounts skipped"}]}::'
    }

    It 'accepts an empty message' {
        Get-Emitted { Write-KestraLog Info '' } |
            Should -BeExactly '::{"logs":[{"level":"INFO","message":""}]}::'
    }

    It 'sends one entry per message, from arguments or the pipeline' {
        Get-Emitted { Write-KestraLog Info 'a' 'b' } |
            Should -BeExactly '::{"logs":[{"level":"INFO","message":"a"},{"level":"INFO","message":"b"}]}::'
        @(Get-Emitted { 'a', 'b' | Write-KestraLog Error }) |
            Should -BeExactly @('::{"logs":[{"level":"ERROR","message":"a"}]}::', '::{"logs":[{"level":"ERROR","message":"b"}]}::')
    }

    It 'sends an empty message for $null, from arguments or the pipeline' {
        @(Get-Emitted { 'a', $null | Write-KestraLog Info }) |
            Should -BeExactly @('::{"logs":[{"level":"INFO","message":"a"}]}::', '::{"logs":[{"level":"INFO","message":""}]}::')
    }

    It 'never fails on a value whose ToString() throws or a list that contains itself' {
        $broken = [pscustomobject]@{ a = 1 }
        $broken | Add-Member -MemberType ScriptMethod -Name ToString -Value { throw 'no text' } -Force
        $list = [System.Collections.ArrayList]::new()
        $null = $list.Add($list)

        # Parsed, as Windows PowerShell escapes < and > as \u003c and \u003e.
        (ConvertFrom-Emitted (Get-Emitted { Write-KestraLog Info $broken })).logs[0].message |
            Should -BeExactly '<System.Management.Automation.PSCustomObject>'
        Get-Emitted { Write-KestraLog Info 'x' $list } |
            Should -BeExactly '::{"logs":[{"level":"INFO","message":"x"},{"level":"INFO","message":"System.Collections.ArrayList"}]}::'
    }

    It 'sends one entry per item of any collection, and joins a nested collection with spaces' {
        $values = @{ a = 'v1' }
        $set = [System.Collections.Generic.HashSet[int]]::new()
        $null = $set.Add(7)
        $null = $set.Add(8)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue('m1')
        $queue.Enqueue('m2')

        Get-Emitted { Write-KestraLog Info $values.Values } | Should -BeExactly '::{"logs":[{"level":"INFO","message":"v1"}]}::'
        Get-Emitted { Write-KestraLog Info $set } | Should -BeExactly '::{"logs":[{"level":"INFO","message":"7"},{"level":"INFO","message":"8"}]}::'
        Get-Emitted { Write-KestraLog Info $queue } | Should -BeExactly '::{"logs":[{"level":"INFO","message":"m1"},{"level":"INFO","message":"m2"}]}::'
        Get-Emitted { Write-KestraLog Info @(@(1, 2), 'z') } | Should -BeExactly '::{"logs":[{"level":"INFO","message":"1 2"},{"level":"INFO","message":"z"}]}::'
    }

    It 'shows at most 1000 items' {
        $payload = ConvertFrom-Emitted (Get-Emitted { Write-KestraLog Info (1..1500) })
        $payload.logs.Count | Should -Be 1001
        $payload.logs[-1].message | Should -BeExactly '...'

        (ConvertFrom-Emitted (Get-Emitted { Write-KestraLog Info @(, (1..1500)) })).logs[0].message | Should -BeLike '* 999 1000 ...'
    }

    It 'never enumerates a sequence that is not a list' {
        $endless = [System.Linq.Enumerable]::Repeat('x', [int]::MaxValue)

        Get-Emitted { Write-KestraLog Info $endless } | Should -Match '^::\{"logs":\[\{"level":"INFO","message":"System\.Linq\.[^"]+"\}\]\}::$'
    }

    It 'rejects unknown levels' {
        { Write-KestraLog Fatal 'x' } | Should -Throw
    }
}

Describe 'Send-KestraAsset' {
    It 'sends input and output assets' {
        $assets = @{ inputs = @(@{ id = 'raw.orders' }); outputs = @(@{ id = 'sales.orders'; type = 'TABLE'; metadata = @{ owner = 'team_a' } }) }
        $payload = ConvertFrom-Emitted (Get-Emitted { Send-KestraAsset $assets })

        $payload.assets.inputs[0].id | Should -Be 'raw.orders'
        $payload.assets.outputs[0].type | Should -Be 'TABLE'
        $payload.assets.outputs[0].metadata.owner | Should -Be 'team_a'
    }

    It 'sends empty lists, and nothing for empty assets' {
        Get-Emitted { Send-KestraAsset @{ outputs = @() } } | Should -BeExactly '::{"assets":{"outputs":[]}}::'
        Get-Emitted { Send-KestraAsset @{} } | Should -BeExactly ''
    }

    It 'accepts only inputs and outputs arrays' {
        { Send-KestraAsset @{ output = @() } } | Should -Throw "Assets hold only inputs and outputs, not 'output'."
        { Send-KestraAsset @{ inputs = @{ id = 'raw.orders' } } } | Should -Throw '*Asset inputs must be an array*'
        { Send-KestraAsset @{ inputs = 'raw.orders' } } | Should -Throw '*Asset inputs must be an array*'
    }
}

Describe 'Get-KestraContext' {
    BeforeEach {
        & (Get-Module Kestra) { $script:ContextJson = $null }
        $json = '{"labels": {"env": "prod"}, "inputs": {"text": "a\nb"}, "trigger": {"startDate": "2025-01-01T00:00:00Z"}}'
        $file = Join-Path $TestDrive 'context.json'
        Set-Content -LiteralPath $file -Value $json -Encoding UTF8
        $env:KESTRA_EXECUTION_CONTEXT_FILE = $file
        $env:KESTRA_CONTEXT = $null
    }

    AfterEach {
        $env:KESTRA_EXECUTION_CONTEXT_FILE = $null
        $env:KESTRA_CONTEXT = $null
    }

    It 'reads the file named by KESTRA_EXECUTION_CONTEXT_FILE and allows dot access' {
        $context = Get-KestraContext

        $context.labels.env | Should -Be 'prod'
        $context.inputs.text | Should -BeExactly "a`nb"
        $context.trigger.startDate | Should -Not -BeNullOrEmpty
    }

    It 'reads the context once and returns a new object per call' {
        $first = Get-KestraContext
        Remove-Item -LiteralPath $env:KESTRA_EXECUTION_CONTEXT_FILE
        $first.labels.env = 'changed'

        (Get-KestraContext).labels.env | Should -Be 'prod'
    }

    It 'reads an explicit path' {
        (Get-KestraContext -Path $env:KESTRA_EXECUTION_CONTEXT_FILE).labels.env | Should -Be 'prod'
    }

    It 'falls back to base64 KESTRA_CONTEXT' {
        $env:KESTRA_EXECUTION_CONTEXT_FILE = Join-Path $TestDrive 'missing.json'
        $env:KESTRA_CONTEXT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"vars": {"n": 42}}'))

        (Get-KestraContext).vars.n | Should -Be 42
    }

    It 'does not fall back to KESTRA_CONTEXT for an explicit path' {
        $env:KESTRA_CONTEXT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"vars": {"n": 42}}'))

        $typo = Join-Path $TestDrive 'typo.json'
        $thrown = { Get-KestraContext -Path $typo } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException]) -PassThru
        $thrown.Exception.Message | Should -BeLike "*$typo*"
        $thrown.Exception.Message | Should -Not -BeLike '*KESTRA_CONTEXT*'
    }

    It 'names the source when the context is not a JSON object' {
        foreach ($content in '', '  ', 'null', '[1]', '{') {
            Set-Content -LiteralPath $env:KESTRA_EXECUTION_CONTEXT_FILE -Value $content -NoNewline
            { Get-KestraContext -Path $env:KESTRA_EXECUTION_CONTEXT_FILE } |
                Should -Throw -ExceptionType ([System.IO.InvalidDataException]) -ExpectedMessage "*$($env:KESTRA_EXECUTION_CONTEXT_FILE)*"
        }
    }

    It 'treats an empty path as none' {
        (Get-KestraContext -Path '').labels.env | Should -Be 'prod'
    }

    It 'fails on a directory instead of falling back to KESTRA_CONTEXT' {
        $env:KESTRA_EXECUTION_CONTEXT_FILE = $TestDrive
        $env:KESTRA_CONTEXT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"vars": {"n": 42}}'))

        { Get-KestraContext } | Should -Throw -ExceptionType ([System.IO.IOException]) -ExpectedMessage "Kestra execution context file '$TestDrive' cannot be read: it is a directory."
    }

    It 'fails with distinct messages for invalid base64, invalid JSON and JSON that is not an object' {
        $env:KESTRA_EXECUTION_CONTEXT_FILE = Join-Path $TestDrive 'missing.json'
        $env:KESTRA_CONTEXT = 'not base64!'
        { Get-KestraContext } | Should -Throw 'The KESTRA_CONTEXT environment variable is not valid base64.'
        $env:KESTRA_CONTEXT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{oops'))
        { Get-KestraContext } | Should -Throw 'The execution context in KESTRA_CONTEXT is not valid JSON.'
        $env:KESTRA_CONTEXT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[1]'))
        { Get-KestraContext } | Should -Throw 'The execution context in KESTRA_CONTEXT is not a JSON object.'
    }

    It 'throws FileNotFoundException outside a Kestra task' {
        $env:KESTRA_EXECUTION_CONTEXT_FILE = Join-Path $TestDrive 'missing.json'

        { Get-KestraContext } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }
}
