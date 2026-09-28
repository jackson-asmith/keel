@{
    RootModule = 'keel.Mail.psm1'
    ModuleVersion = '1.0.0'
    GUID = '9df7bcd4-121b-4ad4-8ebd-72433f326489'
    Author = 'jackson-asmith'
    Copyright = '(c) 2026 jackson-asmith. Licensed under the MIT License.'
    CompanyName       = 'jacksonasmith.com'
    Description = 'Graph-first mail delivery for various workflows. Supports Microsoft Graph (default), explicit SMTP, and SMTP fallback for Exchange Online environments. Includes Cc, ReplyTo, recipients and client-secret Graph authentication.'
    PowerShellVersion = '5.1'
    RequiredModules = @('keel.Http')
    FunctionsToExport = @(
        'Send-Email'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://github.com/jackson-asmith/keel/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jackson-asmith/keel'
            Tags = @('Mail', 'Graph', 'SMTP', 'ExchangeOnline', 'Automation', 'keel', 'ServicePrincipal', 'ClientSecret')
        }
    }
}