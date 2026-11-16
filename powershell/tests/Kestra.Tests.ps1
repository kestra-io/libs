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
        $status = '{"rows": 42, "name": "caf\u00e9", "nested": {"ok": true}}' | ConvertFrom-Json
        $payload = ConvertFrom-Emitted (Get-Emitted { Send-KestraOutput $status })

        $payload.outputs.rows | Should -Be 42
        $payload.outputs.name | Should -BeExactly ('caf' + [char]0xe9)
        $payload.outputs.nested.ok | Should -BeTrue
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

    It 'rejects unknown levels' {
        { Write-KestraLog Fatal 'x' } | Should -Throw
    }
}
