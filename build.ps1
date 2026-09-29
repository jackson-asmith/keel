<#
.SYNOPSIS
Lints and tests the keel modules. CI runs this same script.

.DESCRIPTION
Tasks:

  Lint         Runs PSScriptAnalyzer on module and test code, and
               Test-ModuleManifest on each module. Fails on any Error or
               Warning finding.
  Test         Runs the Pester unit tests (everything not tagged Integration).
  Integration  Runs the Pester tests tagged Integration against the real
               Microsoft Graph SDK. Fails if they are skipped, so a missing
               prerequisite can't pass silently.

Tool versions are pinned below. Tools are saved to ./.tools rather than
installed into your profile.

When run under GitHub Actions, findings and failures are also written as
annotations so they appear on the pull request diff.

.PARAMETER Task
One or more tasks to run. Defaults to Lint and Test.

.PARAMETER GraphSdkVersion
The Microsoft.Graph.Authentication version for the Integration task, or
'Latest'. Defaults to the pinned version.

.EXAMPLE
./build.ps1

.EXAMPLE
./build.ps1 -Task Integration -GraphSdkVersion Latest
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'Console output for people and GitHub Actions workflow commands, which must go to stdout.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseCompatibleCommands', '',
    Justification = 'The 5.1 profile only knows the Pester 3 built into Windows; this script loads Pester 6. The Windows PowerShell 5.1 CI job runs this script for real.'
)]
[CmdletBinding()]
param(
    [ValidateSet('Lint', 'Test', 'Integration')]
    [string[]]$Task = @('Lint', 'Test'),

    [string]$GraphSdkVersion = '2.40.0'
)

$ErrorActionPreference = 'Stop'
# No Set-StrictMode here: it would carry into the Pester tests this script runs.

$PinnedVersions = @{
    Pester           = '6.2.0'
    PSScriptAnalyzer = '1.25.0'
}

$RepoRoot = $PSScriptRoot
$ModulesRoot = Join-Path $RepoRoot 'Modules'
$ToolsRoot = Join-Path $RepoRoot '.tools'
$ResultsRoot = Join-Path $RepoRoot 'TestResults'
$InGitHubActions = $env:GITHUB_ACTIONS -eq 'true'

# Make keel.Http resolvable for keel.Mail's RequiredModules, and saved tools
# visible to Get-Module -ListAvailable (the SDK integration tests use it).
$env:PSModulePath = @($ToolsRoot, $ModulesRoot, $env:PSModulePath) -join [System.IO.Path]::PathSeparator

function Save-Tool {
    # Saves a module version into ./.tools if it isn't already there, then imports it.
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version
    )

    if ($Version -eq 'Latest') {
        $Version = if (Get-Command Find-PSResource -ErrorAction SilentlyContinue) {
            (Find-PSResource -Name $Name -Repository PSGallery).Version.ToString()
        }
        else {
            (Find-Module -Name $Name -Repository PSGallery).Version.ToString()
        }
    }

    $target = Join-Path (Join-Path $ToolsRoot $Name) $Version
    if (-not (Test-Path $target)) {
        Write-Host "Saving $Name $Version to .tools"
        $null = New-Item -Path $ToolsRoot -ItemType Directory -Force

        if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            Save-PSResource -Name $Name -Version $Version -Path $ToolsRoot -Repository PSGallery -TrustRepository
        }
        else {
            # Windows PowerShell 5.1 ships PowerShellGet, not PSResourceGet.
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
            }
            Save-Module -Name $Name -RequiredVersion $Version -Path $ToolsRoot -Repository PSGallery -Force
        }
    }

    Import-Module (Join-Path $target "$Name.psd1") -Force -ErrorAction Stop
    Write-Host "Using $Name $Version"
}

function ConvertTo-AnnotationText {
    # Escapes text for a GitHub Actions workflow command.
    param([string]$Text)
    $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Get-RepoRelativePath {
    param([string]$Path)
    $Path.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
}

function Invoke-LintTask {
    Save-Tool -Name PSScriptAnalyzer -Version $PinnedVersions.PSScriptAnalyzer

    $moduleSettings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
    $testSettings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.Tests.psd1'

    # Analyze one file at a time. Invoke-ScriptAnalyzer -Recurse on a folder
    # intermittently throws a NullReferenceException in 1.25.0.
    $files = @(
        Get-ChildItem -Path $ModulesRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
        Get-Item -Path $PSCommandPath
    ) | Sort-Object FullName
    $findings = foreach ($file in $files) {
        $isTest = $file.FullName -match '[\\/]Tests[\\/]'
        $settings = if ($isTest) { $testSettings } else { $moduleSettings }
        Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings
    }
    $findings = @($findings)

    foreach ($finding in $findings) {
        $relativePath = Get-RepoRelativePath $finding.ScriptPath
        $severity = "$($finding.Severity)"
        Write-Host ('{0}:{1}:{2} [{3}] {4}: {5}' -f $relativePath, $finding.Line, $finding.Column, $severity, $finding.RuleName, $finding.Message)

        # Annotate only blocking findings. Warnings fail the build, so they are shown
        # as errors on the PR; Information findings stay in the log.
        if ($InGitHubActions -and $severity -in @('Error', 'Warning', 'ParseError')) {
            Write-Host ('::error file={0},line={1},col={2},title={3}::{4}' -f
                $relativePath, $finding.Line, $finding.Column, $finding.RuleName,
                (ConvertTo-AnnotationText $finding.Message))
        }
    }

    $blocking = @($findings | Where-Object { "$($_.Severity)" -in @('Error', 'Warning', 'ParseError') })
    $informational = $findings.Count - $blocking.Count
    Write-Host "PSScriptAnalyzer: $($files.Count) files, $($blocking.Count) blocking finding(s), $informational informational."

    $manifestFailures = 0
    foreach ($manifest in Get-ChildItem -Path $ModulesRoot -Filter '*.psd1' -Recurse | Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' }) {
        try {
            $null = Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop
            Write-Host "Test-ModuleManifest: $($manifest.Name) OK"
        }
        catch {
            $manifestFailures++
            $relativePath = Get-RepoRelativePath $manifest.FullName
            Write-Host "Test-ModuleManifest: $($manifest.Name) failed: $($_.Exception.Message)"
            if ($InGitHubActions) {
                Write-Host "::error file=$relativePath,title=Test-ModuleManifest::$(ConvertTo-AnnotationText $_.Exception.Message)"
            }
        }
    }

    if ($blocking.Count -gt 0 -or $manifestFailures -gt 0) {
        throw "Lint failed: $($blocking.Count) PSScriptAnalyzer finding(s), $manifestFailures manifest failure(s)."
    }
}

function Invoke-PesterRun {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string[]]$Tag,

        [string[]]$ExcludeTag
    )

    Save-Tool -Name Pester -Version $PinnedVersions.Pester

    $null = New-Item -Path $ResultsRoot -ItemType Directory -Force
    $edition = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'windows-powershell' } else { 'pwsh' }
    $platform = if ($env:RUNNER_OS) { $env:RUNNER_OS.ToLowerInvariant() } else { 'local' }

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $ModulesRoot
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = Join-Path $ResultsRoot "$Name-$platform-$edition.xml"
    if ($Tag) { $configuration.Filter.Tag = $Tag }
    if ($ExcludeTag) { $configuration.Filter.ExcludeTag = $ExcludeTag }

    Invoke-Pester -Configuration $configuration
}

function Invoke-TestTask {
    Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $result = Invoke-PesterRun -Name 'unit' -ExcludeTag 'Integration'

    if ($result.Result -ne 'Passed') {
        throw "Unit tests failed: $($result.FailedCount) failed, $($result.FailedContainersCount) container(s) failed."
    }
}

function Invoke-IntegrationTask {
    param(
        [Parameter(Mandatory)]
        [string]$GraphSdkVersion
    )

    Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    # Import the chosen SDK version first so the tests use it rather than
    # whichever version happens to be highest on this machine.
    Save-Tool -Name Microsoft.Graph.Authentication -Version $GraphSdkVersion

    $result = Invoke-PesterRun -Name 'integration' -Tag 'Integration'

    if ($result.Result -ne 'Passed') {
        throw "Integration tests failed: $($result.FailedCount) failed, $($result.FailedContainersCount) container(s) failed."
    }
    if ($result.SkippedCount -gt 0 -or $result.PassedCount -eq 0) {
        throw "Integration tests did not run: $($result.PassedCount) passed, $($result.SkippedCount) skipped. See the skip reason above."
    }
}

foreach ($name in $Task) {
    Write-Host ''
    Write-Host "=== $name ==="
    switch ($name) {
        'Lint' { Invoke-LintTask }
        'Test' { Invoke-TestTask }
        'Integration' { Invoke-IntegrationTask -GraphSdkVersion $GraphSdkVersion }
    }
}
