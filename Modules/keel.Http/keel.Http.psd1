@{
    RootModule        = 'keel.Http.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '1fe23d06-6add-4c6f-8835-95e72d026c2a'
    Author            = 'jackson-asmith'
    Copyright         = '(c) 2026 jackson-asmith. Licensed under the MIT License.'
    CompanyName       = 'jacksonasmith.com'
    Description       = 'Transport-agnostic HTTP retry primitive for REST API calls in automation workflows. Works with any REST API that uses standard HTTP status codes for throttling and transient errors.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-RetryableStatusCode'
        'Invoke-WithBoundedRetry'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            LicenseUri = 'https://github.com/jackson-asmith/keel/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jackson-asmith/keel'
            Tags = @('HTTP', 'Retry', 'REST', 'Automation', 'Graph', 'keel')
        }
    }
}