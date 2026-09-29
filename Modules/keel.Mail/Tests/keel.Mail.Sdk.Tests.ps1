#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
Integration tests for keel.Mail's Microsoft Graph SDK path.

These run the real Microsoft.Graph.Authentication module against a stub Graph
endpoint on this machine, so they need no tenant, sign in to nothing, and send
no mail. The unit tests mock Invoke-MgGraphRequest, so they can't see what the
SDK does on the wire; these tests can.

They are skipped when the SDK isn't installed or the stub can't listen on
port 80. Port 80 is required: Invoke-MgGraphRequest resolves relative URIs from
the endpoint's scheme and host only, dropping any custom port. macOS allows
unprivileged processes to bind port 80 on all interfaces; Linux and Windows
usually need elevation.

Run just these with:
    Invoke-Pester ./Modules -TagFilter Integration -Output Detailed
#>

BeforeDiscovery {
    $script:SkipReason = $null
    $script:StubPrefix = if ($IsMacOS) { 'http://*:80/' } else { 'http://localhost:80/' }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        $script:SkipReason = 'Microsoft.Graph.Authentication is not installed.'
    }
    else {
        try {
            $probe = [System.Net.HttpListener]::new()
            $probe.Prefixes.Add($StubPrefix)
            $probe.Start()
            $probe.Stop()
            $probe.Close()
        }
        catch {
            $script:SkipReason = "The stub can't listen on port 80: $($_.Exception.Message)"
        }
    }

    if ($SkipReason) {
        Write-Host "Skipping keel.Mail SDK integration tests. $SkipReason" -ForegroundColor Yellow
    }
}

Describe 'keel.Mail through the Microsoft Graph SDK' -Tag Integration -Skip:([bool]$SkipReason) {
    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
        $script:ModulesRoot = Split-Path -Parent $ModuleRoot

        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Get-Module keel.Mail, keel.Http | Remove-Module -Force
        Import-Module (Join-Path $ModulesRoot 'keel.Http/keel.Http.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $ModuleRoot 'keel.Mail.psm1') -Force -ErrorAction Stop

        # Keep the host's Keel configuration out of these tests.
        $script:SavedKeelEnv = @{}
        foreach ($variable in Get-ChildItem Env:KEEL_*) {
            $SavedKeelEnv[$variable.Name] = $variable.Value
            Remove-Item "Env:$($variable.Name)"
        }

        # Stub Graph endpoint. Each request takes the next status from Responses,
        # or DefaultStatus when the queue is empty, and is logged.
        $script:Stub = [hashtable]::Synchronized(@{
                Requests      = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                Responses     = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
                DefaultStatus = 202
            })
        $script:Listener = [System.Net.HttpListener]::new()
        $Listener.Prefixes.Add($StubPrefix)
        $Listener.Start()
        $script:Server = [powershell]::Create().AddScript({
                param($Listener, $Stub)
                while ($Listener.IsListening) {
                    try { $context = $Listener.GetContext() } catch { break }
                    [void]$Stub.Requests.Add("$($context.Request.HttpMethod) $($context.Request.Url.AbsolutePath)")
                    $status = 0
                    if (-not $Stub.Responses.TryDequeue([ref]$status)) { $status = $Stub.DefaultStatus }
                    $context.Response.StatusCode = $status
                    if ($status -ge 400) { $context.Response.Headers.Add('Retry-After', '1') }
                    $context.Response.Close()
                }
            }).AddArgument($Listener).AddArgument($Stub)
        [void]$Server.BeginInvoke()

        function Set-StubResponse {
            # Queues specific statuses for the next requests, then answers every
            # later request with the default status.
            param([int[]]$Next = @(), [int]$Default = 202)
            $Stub.Requests.Clear()
            $ignored = 0
            while ($Stub.Responses.TryDequeue([ref]$ignored)) { }
            foreach ($status in $Next) { $Stub.Responses.Enqueue($status) }
            $Stub.DefaultStatus = $Default
        }

        function New-FakeAccessToken {
            # An unsigned JWT with the claims Connect-MgGraph -AccessToken reads. Nothing
            # validates it: the stub ignores the Authorization header.
            $encode = {
                param($Object)
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Compress))).
                TrimEnd('=').Replace('+', '-').Replace('/', '_')
            }
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $header = & $encode @{ alg = 'none'; typ = 'JWT' }
            $payload = & $encode @{
                aud = 'https://graph.microsoft.com'
                tid = '00000000-0000-0000-0000-000000000000'
                appid = '11111111-1111-1111-1111-111111111111'
                roles = @('Mail.Send')
                iat = $now; nbf = $now; exp = $now + 3600
            }
            ConvertTo-SecureString "$header.$payload.test" -AsPlainText -Force
        }

        $script:EnvironmentName = 'KeelIntegrationStub'
        Add-MgEnvironment -Name $EnvironmentName -GraphEndpoint 'http://localhost' -AzureADEndpoint 'https://login.microsoftonline.com' | Out-Null
        Connect-MgGraph -Environment $EnvironmentName -AccessToken (New-FakeAccessToken) -NoWelcome

        $script:Mail = @{
            Subject     = 'Nightly job failed'
            To          = 'ops@contoso.com'
            From        = 'automation@contoso.com'
            Body        = 'See attached log.'
            WarningAction = 'SilentlyContinue'
        }
        $script:SendMailRequest = 'POST /v1.0/users/automation%40contoso.com/sendMail'
    }

    AfterAll {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Remove-MgEnvironment -Name $EnvironmentName -ErrorAction SilentlyContinue | Out-Null
        Set-MgRequestContext -MaxRetry 3 -RetryDelay 3 -RetriesTimeLimit 0 -ErrorAction SilentlyContinue | Out-Null
        if ($Listener) { $Listener.Stop(); $Listener.Close() }
        if ($Server) { $Server.Dispose() }
        foreach ($name in $SavedKeelEnv.Keys) { Set-Item "Env:$name" $SavedKeelEnv[$name] }
        Get-Module keel.Mail, keel.Http | Remove-Module -Force
    }

    BeforeEach {
        # Keel's own backoff and Retry-After waits aren't what's under test here.
        Mock Start-Sleep -ModuleName keel.Http { }
        Mock Send-MailMessage -ModuleName keel.Mail { }
        Set-MgRequestContext -MaxRetry 3 -RetryDelay 3 -RetriesTimeLimit 0 | Out-Null
    }

    It 'sends once when Graph accepts the message' {
        Set-StubResponse -Default 202

        Send-Email @Mail

        $Stub.Requests | Should-BeCollection @($SendMailRequest)
    }

    It 'sends exactly once and reports unknown delivery when Graph returns 504' {
        Set-StubResponse -Default 504

        $thrown = $null
        try { Send-Email @Mail } catch { $thrown = $_ }

        $Stub.Requests.Count | Should-Be 1
        $thrown.FullyQualifiedErrorId | Should-BeLikeString 'GraphDeliveryUnknown*'
    }

    It 'does not fall back to SMTP after a 504, even with fallback enabled' {
        Set-StubResponse -Default 504

        { Send-Email @Mail -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback } | Should-Throw -ExceptionMessage '*may have been delivered*'

        $Stub.Requests.Count | Should-Be 1
        Should-NotInvoke Send-MailMessage -ModuleName keel.Mail
    }

    It 'retries a 429 through Keel, not the SDK, then falls back to SMTP' {
        Set-StubResponse -Default 429

        Send-Email @Mail -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback

        # Keel's default is three attempts; each must be a single request.
        $Stub.Requests.Count | Should-Be 3
        Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly
    }

    It 'recovers from a single 503' {
        Set-StubResponse -Next 503 -Default 202

        Send-Email @Mail

        $Stub.Requests.Count | Should-Be 2
    }

    It "restores the caller's SDK retry settings after <Case>" -ForEach @(
        @{ Case = 'a successful send'; Status = 202 }
        @{ Case = 'a failed send'; Status = 504 }
    ) {
        Set-StubResponse -Default $Status
        Set-MgRequestContext -MaxRetry 5 -RetryDelay 2 -RetriesTimeLimit 30 | Out-Null

        try { Send-Email @Mail } catch { }

        $after = Get-MgRequestContext
        $after.MaxRetry | Should-Be 5
        $after.RetryDelay | Should-Be 2
        $after.RetriesTimeLimit | Should-Be ([TimeSpan]::FromSeconds(30))
    }
}
