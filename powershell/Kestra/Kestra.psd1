@{
    RootModule        = 'Kestra.psm1'
    ModuleVersion     = '0.0.0'
    GUID              = '59470a79-66a9-439a-a9d1-def189dde1f0'
    Author            = 'Kestra'
    CompanyName       = 'Kestra Technologies'
    Copyright         = '(c) Kestra Technologies'
    Description       = 'Send outputs, metrics and logs from PowerShell script tasks to Kestra.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Send-KestraOutput', 'Send-KestraAsset', 'Send-KestraCounter', 'Send-KestraGauge', 'Send-KestraTimer', 'Write-KestraLog', 'Get-KestraContext')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Kestra', 'Orchestration')
            LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0'
            ProjectUri = 'https://github.com/kestra-io/libs'
        }
    }
}
