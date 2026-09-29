# PSScriptAnalyzer settings for Pester tests (Tests/*.ps1).
# Same gate as module code: Errors and Warnings fail CI. The rules excluded here
# flag patterns that test code needs on purpose.
@{
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Stubs for Graph SDK commands declare the real parameters so Pester can
        # mock them and filter on them, but the stub bodies never use them.
        'PSReviewUnusedParameter'

        # New-* and Set-* helpers build fixtures and configure the stub server;
        # -WhatIf and -Confirm have no meaning for them.
        'PSUseShouldProcessForStateChangingFunctions'

        # Tests build credentials from fake, hard-coded secrets and stub
        # parameters that mirror Connect-MgGraph's signature.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingPlainTextForPassword'
    )

    # The compatibility rules are not enabled here: their 5.1 profile assumes the
    # Pester 3 that ships with Windows, so every Pester 6 parameter is flagged.
}
