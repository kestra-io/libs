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

    It 'rejects empty outputs and values that are not maps' {
        { Send-KestraOutput @{} } | Should -Throw '*at least one key*'
        { Send-KestraOutput ([pscustomobject]@{}) } | Should -Throw '*at least one key*'
        { Send-KestraOutput @(1, 2) } | Should -Throw '*must be a hashtable or a PSCustomObject*'
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
        $metric.tags.ok | Should -BeExactly 'True'
        { Send-KestraGauge queue 3 @{ shard = @{ a = 1 } } } | Should -Throw "*tag 'shard' must be a single value*"
        { Send-KestraGauge queue 3 @{ shard = @(1, 2) } } | Should -Throw "*tag 'shard' must be a single value*"
        { Send-KestraGauge queue 3 @{ shard = $null } } | Should -Throw "*tag 'shard' must be a single value*"
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

    It 'rejects empty assets' {
        { Send-KestraAsset @{} } | Should -Throw '*inputs or outputs*'
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

        { Get-KestraContext -Path (Join-Path $TestDrive 'typo.json') } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'names the source when the context is not a JSON object' {
        foreach ($content in '', '  ', 'null', '[1]', '{') {
            Set-Content -LiteralPath $env:KESTRA_EXECUTION_CONTEXT_FILE -Value $content -NoNewline
            { Get-KestraContext -Path $env:KESTRA_EXECUTION_CONTEXT_FILE } |
                Should -Throw -ExceptionType ([System.IO.InvalidDataException]) -ExpectedMessage "*$($env:KESTRA_EXECUTION_CONTEXT_FILE)*"
        }
    }

    It 'throws FileNotFoundException outside a Kestra task' {
        $env:KESTRA_EXECUTION_CONTEXT_FILE = Join-Path $TestDrive 'missing.json'

        { Get-KestraContext } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }
}
