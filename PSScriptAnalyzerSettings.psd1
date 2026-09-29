# PSScriptAnalyzer settings for module code (*.psm1, *.psd1).
# CI fails on any Error or Warning; Information findings are reported only.
# To accept a specific finding, suppress it in code with a
# [Diagnostics.CodeAnalysis.SuppressMessageAttribute()] and a Justification,
# so the exception is reviewed in the pull request that adds it.
@{
    Severity     = @('Error', 'Warning', 'Information')

    # All default rules, plus the compatibility rules below.
    IncludeDefaultRules = $true

    Rules        = @{
        # Both manifests declare PowerShellVersion 5.1. Flag syntax, commands,
        # and .NET types that Windows PowerShell 5.1 doesn't have.
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
