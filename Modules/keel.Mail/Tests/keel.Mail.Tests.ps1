#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulesRoot = Split-Path -Parent $ModuleRoot
    $script:ManifestPath = Join-Path $ModuleRoot 'keel.Mail.psd1'

    # keel.Mail calls Invoke-WithBoundedRetry from keel.Http. Import both by path so the
    # behavioral tests don't depend on PSModulePath; the manifest tests cover RequiredModules.
    Get-Module keel.Mail, keel.Http | Remove-Module -Force
    Import-Module (Join-Path $ModulesRoot 'keel.Http/keel.Http.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $ModuleRoot 'keel.Mail.psm1') -Force -ErrorAction Stop

    # Pester can only mock commands that exist. When the Microsoft Graph SDK isn't installed,
    # define global stubs with the parameters keel.Mail uses, and remove them in AfterAll.
    $script:GraphStubs = @()
    $stubs = @{
        'Connect-MgGraph'        = {
            param($TenantId, $ClientId, $CertificateThumbprint, $ClientSecretCredential, [switch]$NoWelcome)
        }
        'Get-MgContext'          = { param() }
        'Invoke-MgGraphRequest'  = { param($Method, $Uri, $Body, $ContentType) }
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value $stubs[$name]
            $script:GraphStubs += $name
        }
    }

    $script:EnvNames = @(
        'KEEL_MAIL_DELIVERY_METHOD'
        'KEEL_GRAPH_SENDER_USER_ID'
        'KEEL_GRAPH_ACCESS_TOKEN'
        'KEEL_MAIL_ALLOW_SMTP_FALLBACK'
        'KEEL_MAIL_CC'
        'KEEL_MAIL_REPLY_TO'
        'KEEL_SMTP_SERVER'
        'KEEL_SMTP_RELAY'
        'KEEL_GRAPH_TENANT_ID'
        'KEEL_GRAPH_CLIENT_ID'
        'KEEL_GRAPH_CERTIFICATE_THUMBPRINT'
        'KEEL_GRAPH_CLIENT_SECRET'
        'KEEL_GRAPH_AUTH_MODE'
        'GRAPH_CLIENT_SECRET'
    )
    $script:SavedEnv = @{}
    foreach ($name in $EnvNames) {
        $SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    function Clear-KeelEnvironment {
        foreach ($name in $script:EnvNames) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    function Get-RecipientAddress {
        # Reads addresses out of Graph recipient objects. Plain member enumeration
        # ($list.emailAddress.address) doesn't work here: on an array, .address
        # resolves to the built-in Array.Address() method instead.
        param($Recipients)
        @($Recipients | ForEach-Object { $_.emailAddress.address })
    }

    function New-SizedFile {
        # Creates a file of an exact size under TestDrive. SetLength avoids writing
        # megabytes of data just to test the attachment size limit.
        param([string]$Name, [long]$Bytes)

        $path = Join-Path $TestDrive $Name
        $stream = [System.IO.File]::Create($path)
        try {
            $stream.SetLength($Bytes)
        }
        finally {
            $stream.Dispose()
        }
        $path
    }

    # Shared arguments for a minimal valid message.
    $script:BaseMail = @{
        Subject = 'Nightly job failed'
        To      = 'ops@contoso.com'
        From    = 'automation@contoso.com'
        Body    = 'See attached log.'
    }
}

AfterAll {
    foreach ($name in $script:EnvNames) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name])
    }
    foreach ($name in $script:GraphStubs) {
        Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue
    }
    Get-Module keel.Mail, keel.Http | Remove-Module -Force
}

Describe 'keel.Mail' {
    BeforeEach {
        Clear-KeelEnvironment

        # Nothing in this suite should ever reach a real transport or sleep between retries.
        Mock Invoke-RestMethod -ModuleName keel.Mail { throw 'Unexpected Invoke-RestMethod call' }
        Mock Send-MailMessage -ModuleName keel.Mail { throw 'Unexpected Send-MailMessage call' }
        Mock Start-Sleep -ModuleName keel.Http { }
    }

    Describe 'module manifest' {
        It 'passes Test-ModuleManifest' {
            # RequiredModules must resolve, so make keel.Http discoverable for this check.
            $originalPath = $env:PSModulePath
            try {
                $env:PSModulePath = $ModulesRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
                Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop | Should-NotBeNull
            }
            finally {
                $env:PSModulePath = $originalPath
            }
        }

        It 'declares keel.Http as a required module' {
            $manifest = Import-PowerShellDataFile -Path $ManifestPath
            @($manifest.RequiredModules) -contains 'keel.Http' | Should-BeTrue
        }

        It 'declares a non-empty GUID' {
            $manifest = Import-PowerShellDataFile -Path $ManifestPath
            $guid = $manifest.GUID -as [guid]

            $guid | Should-NotBeNull -Because 'GUID must be a valid GUID string'
            $guid | Should-NotBe ([guid]::Empty)
        }

        It 'exports only Send-Email' {
            $manifest = Import-PowerShellDataFile -Path $ManifestPath
            @($manifest.FunctionsToExport) | Should-BeCollection @('Send-Email')
            @((Get-Module keel.Mail).ExportedFunctions.Keys) | Should-BeCollection @('Send-Email')
        }
    }

    Describe 'Convert-EmailAddresses' {
        It 'trims whitespace around each address' {
            $result = InModuleScope keel.Mail { Convert-EmailAddresses -AddressList '  a@contoso.com ', "`tb@contoso.com" }
            $result | Should-BeCollection @('a@contoso.com', 'b@contoso.com')
        }

        It 'removes case-insensitive duplicates, keeping the first spelling and original order' {
            $result = InModuleScope keel.Mail {
                Convert-EmailAddresses -AddressList 'User@Contoso.com', 'b@contoso.com', 'user@contoso.com', ' USER@CONTOSO.COM '
            }
            $result | Should-BeCollection @('User@Contoso.com', 'b@contoso.com')
        }

        It 'skips null, empty, and whitespace-only entries' {
            $result = InModuleScope keel.Mail { Convert-EmailAddresses -AddressList $null, '', '   ', 'a@contoso.com' }
            $result | Should-Be 'a@contoso.com'
        }

        It 'returns nothing for null input' {
            $result = InModuleScope keel.Mail { Convert-EmailAddresses -AddressList $null }
            @($result).Count | Should-Be 0
        }
    }

    Describe 'ConvertTo-BooleanValue' {
        It 'converts "<Value>" to true' -ForEach @(
            @{ Value = '1' }, @{ Value = 'true' }, @{ Value = 'TRUE' }, @{ Value = 'yes' }
            @{ Value = 'y' }, @{ Value = 'on' }, @{ Value = ' On ' }
        ) {
            InModuleScope keel.Mail -Parameters @{ Value = $Value } {
                param($Value)
                ConvertTo-BooleanValue -Value $Value -Default $false
            } | Should-BeTrue
        }

        It 'converts "<Value>" to false' -ForEach @(
            @{ Value = '0' }, @{ Value = 'false' }, @{ Value = 'False' }, @{ Value = 'no' }
            @{ Value = 'n' }, @{ Value = 'off' }
        ) {
            InModuleScope keel.Mail -Parameters @{ Value = $Value } {
                param($Value)
                ConvertTo-BooleanValue -Value $Value -Default $true
            } | Should-BeFalse
        }

        It 'returns the default for null or whitespace input' {
            InModuleScope keel.Mail { ConvertTo-BooleanValue -Value $null -Default $true } | Should-BeTrue
            InModuleScope keel.Mail { ConvertTo-BooleanValue -Value '  ' -Default $false } | Should-BeFalse
        }

        It 'returns the default for unrecognized input' {
            $result = InModuleScope keel.Mail { ConvertTo-BooleanValue -Value 'maybe' -Default $true }
            $result | Should-BeTrue
        }
    }

    Describe 'Convert-ToGraphRecipient' {
        It 'wraps each address in a Graph emailAddress object' {
            $result = @(InModuleScope keel.Mail { Convert-ToGraphRecipient -AddressList 'a@contoso.com', 'b@contoso.com' })

            $result.Count | Should-Be 2
            $result[0].emailAddress.address | Should-Be 'a@contoso.com'
            $result[1].emailAddress.address | Should-Be 'b@contoso.com'
        }

        It 'normalizes and de-duplicates addresses before conversion' {
            $result = @(InModuleScope keel.Mail { Convert-ToGraphRecipient -AddressList ' a@contoso.com ', 'A@contoso.com', '' })

            $result.Count | Should-Be 1
            $result[0].emailAddress.address | Should-Be 'a@contoso.com'
        }

        It 'accumulates addresses from the pipeline' {
            $result = @(InModuleScope keel.Mail { 'a@contoso.com', 'b@contoso.com' | Convert-ToGraphRecipient })
            Should-BeCollection -Actual (Get-RecipientAddress $result) -Expected @('a@contoso.com', 'b@contoso.com')
        }

        It 'returns nothing when there are no addresses' {
            $result = @(InModuleScope keel.Mail { Convert-ToGraphRecipient -AddressList $null })
            $result.Count | Should-Be 0
        }
    }

    Describe 'Resolve-AttachmentFilePath' {
        It 'returns the full path of an existing file' {
            $file = New-Item -Path (Join-Path $TestDrive 'report.txt') -ItemType File -Value 'data' -Force
            $result = InModuleScope keel.Mail -Parameters @{ Path = $file.FullName } {
                param($Path)
                Resolve-AttachmentFilePath -Path $Path
            }

            $result | Should-Be (Resolve-Path -LiteralPath $file.FullName).Path
        }

        It 'throws when the file does not exist' {
            $missing = Join-Path $TestDrive 'missing.txt'
            {
                InModuleScope keel.Mail -Parameters @{ Path = $missing } {
                    param($Path)
                    Resolve-AttachmentFilePath -Path $Path
                }
            } | Should-Throw -ExceptionMessage 'Attachment file not found:*'
        }

        It 'throws when the path is a directory' {
            {
                InModuleScope keel.Mail -Parameters @{ Path = $TestDrive } {
                    param($Path)
                    Resolve-AttachmentFilePath -Path $Path
                }
            } | Should-Throw -ExceptionMessage 'Attachment file not found:*'
        }

        It 'accepts a file object from the pipeline by property name' {
            $file = New-Item -Path (Join-Path $TestDrive 'piped.txt') -ItemType File -Value 'data' -Force
            $result = InModuleScope keel.Mail -Parameters @{ File = $file } {
                param($File)
                [pscustomobject]@{ Path = $File.FullName } | Resolve-AttachmentFilePath
            }

            $result | Should-Be (Resolve-Path -LiteralPath $file.FullName).Path
        }
    }

    Describe 'New-GraphFileAttachment' {
        BeforeAll {
            $script:AttachmentFile = Join-Path $TestDrive 'summary.csv'
            [System.IO.File]::WriteAllBytes($AttachmentFile, [byte[]](0x61, 0x2C, 0x62, 0x0A, 0x00, 0xFF))
        }

        It 'builds a Graph fileAttachment with base64 content' {
            $attachment = InModuleScope keel.Mail -Parameters @{ Path = $AttachmentFile } {
                param($Path)
                New-GraphFileAttachment -Path $Path
            }

            $attachment['@odata.type'] | Should-Be '#microsoft.graph.fileAttachment'
            $attachment['name'] | Should-Be 'summary.csv'
            $attachment['contentType'] | Should-Be 'application/octet-stream'
            $attachment['contentBytes'] | Should-Be ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($AttachmentFile)))
        }

        It 'serializes property names using the Graph schema casing' {
            $json = InModuleScope keel.Mail -Parameters @{ Path = $AttachmentFile } {
                param($Path)
                New-GraphFileAttachment -Path $Path | ConvertTo-Json
            }

            $json -cmatch '"contentBytes"' | Should-BeTrue
            $json -cmatch '"contentType"' | Should-BeTrue
        }

        It 'throws when the file does not exist' {
            {
                InModuleScope keel.Mail -Parameters @{ Path = (Join-Path $TestDrive 'nope.bin') } {
                    param($Path)
                    New-GraphFileAttachment -Path $Path
                }
            } | Should-Throw -ExceptionMessage 'Attachment file not found:*'
        }
    }

    Describe 'Connect-AutomationGraph' {
        BeforeEach {
            Mock Connect-MgGraph -ModuleName keel.Mail { }
            $env:KEEL_GRAPH_TENANT_ID = 'tenant-id'
            $env:KEEL_GRAPH_CLIENT_ID = 'client-id'
        }

        It 'throws when the Graph SDK is not installed' {
            Mock Get-Command -ModuleName keel.Mail -ParameterFilter { $Name -eq 'Connect-MgGraph' } { $null }

            { InModuleScope keel.Mail { Connect-AutomationGraph } } |
                Should-Throw -ExceptionMessage 'Connect-MgGraph is not available*'
        }

        It 'uses certificate auth when a thumbprint is configured' {
            $env:KEEL_GRAPH_CERTIFICATE_THUMBPRINT = 'ABC123'

            InModuleScope keel.Mail { Connect-AutomationGraph }

            Should-Invoke Connect-MgGraph -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq 'tenant-id' -and
                $ClientId -eq 'client-id' -and
                $CertificateThumbprint -eq 'ABC123' -and
                $NoWelcome
            }
        }

        It 'uses client-secret auth when KEEL_GRAPH_CLIENT_SECRET is configured' {
            $env:KEEL_GRAPH_CLIENT_SECRET = 'not-a-real-secret'

            InModuleScope keel.Mail { Connect-AutomationGraph }

            Should-Invoke Connect-MgGraph -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq 'tenant-id' -and
                $ClientSecretCredential.UserName -eq 'client-id' -and
                $ClientSecretCredential.GetNetworkCredential().Password -eq 'not-a-real-secret'
            }
        }

        It 'prefers certificate auth when both a thumbprint and a secret are configured' {
            $env:KEEL_GRAPH_CERTIFICATE_THUMBPRINT = 'ABC123'
            $env:KEEL_GRAPH_CLIENT_SECRET = 'not-a-real-secret'

            InModuleScope keel.Mail { Connect-AutomationGraph }

            Should-Invoke Connect-MgGraph -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                $CertificateThumbprint -eq 'ABC123' -and $null -eq $ClientSecretCredential
            }
        }

        It 'honors KEEL_GRAPH_AUTH_MODE=ClientSecret even when a thumbprint is present' {
            $env:KEEL_GRAPH_AUTH_MODE = 'ClientSecret'
            $env:KEEL_GRAPH_CERTIFICATE_THUMBPRINT = 'ABC123'
            $env:KEEL_GRAPH_CLIENT_SECRET = 'not-a-real-secret'

            InModuleScope keel.Mail { Connect-AutomationGraph }

            Should-Invoke Connect-MgGraph -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                $null -ne $ClientSecretCredential -and [string]::IsNullOrEmpty($CertificateThumbprint)
            }
        }

        It 'throws when KEEL_GRAPH_AUTH_MODE=Certificate but no thumbprint is set' {
            $env:KEEL_GRAPH_AUTH_MODE = 'Certificate'
            $env:KEEL_GRAPH_CLIENT_SECRET = 'not-a-real-secret'

            { InModuleScope keel.Mail { Connect-AutomationGraph } } |
                Should-Throw -ExceptionMessage '*incomplete certificate app-only configuration*'
            Should-NotInvoke Connect-MgGraph -ModuleName keel.Mail
        }

        It 'throws when the tenant ID is missing' {
            $env:KEEL_GRAPH_TENANT_ID = $null
            $env:KEEL_GRAPH_CERTIFICATE_THUMBPRINT = 'ABC123'

            { InModuleScope keel.Mail { Connect-AutomationGraph } } | Should-Throw
            Should-NotInvoke Connect-MgGraph -ModuleName keel.Mail
        }

        It 'warns about an unrecognized KEEL_GRAPH_AUTH_MODE and chooses the mode automatically' {
            Mock Write-Warning -ModuleName keel.Mail { }
            $env:KEEL_GRAPH_AUTH_MODE = 'Kerberos'
            $env:KEEL_GRAPH_CERTIFICATE_THUMBPRINT = 'ABC123'

            InModuleScope keel.Mail { Connect-AutomationGraph }

            Should-Invoke Write-Warning -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $Message -like "*KEEL_GRAPH_AUTH_MODE value 'Kerberos'*" }
            Should-Invoke Connect-MgGraph -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $CertificateThumbprint -eq 'ABC123' }
        }

        It 'throws a configuration error when no credentials are configured' {
            { InModuleScope keel.Mail { Connect-AutomationGraph } } |
                Should-Throw -ExceptionMessage 'No active Graph connection and incomplete app-only configuration*'
            Should-NotInvoke Connect-MgGraph -ModuleName keel.Mail
        }
    }

    Describe 'Send-GraphEmail' {
        BeforeAll {
            function Get-LastPayload {
                $script:RestCalls[-1].Body | ConvertFrom-Json
            }
        }

        BeforeEach {
            $script:RestCalls = [System.Collections.Generic.List[hashtable]]::new()
            Mock Invoke-RestMethod -ModuleName keel.Mail {
                $script:RestCalls.Add(@{
                        Method      = $Method
                        Uri         = [string]$Uri
                        Headers     = $Headers
                        Body        = $Body
                        ContentType = $ContentType
                    })
            }
        }

        Context 'with an access token' {
            It 'POSTs JSON to the users/{id}/sendMail endpoint with a bearer token' {
                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 'sender@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -GraphAccessToken 'token-123'
                }

                $script:RestCalls.Count | Should-Be 1
                $call = $script:RestCalls[0]
                $call.Method | Should-Be 'Post'
                $call.Uri | Should-Be 'https://graph.microsoft.com/v1.0/users/sender%40contoso.com/sendMail'
                $call.Headers.Authorization | Should-Be 'Bearer token-123'
                $call.ContentType | Should-Be 'application/json'
            }

            It 'builds a text message with recipients and does not save to Sent Items' {
                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com', 'b@contoso.com' -Body 'Plain body' -GraphAccessToken 't'
                }

                $payload = Get-LastPayload
                $payload.saveToSentItems | Should-BeFalse
                $payload.message.subject | Should-Be 'Hi'
                $payload.message.body.contentType | Should-Be 'Text'
                $payload.message.body.content | Should-Be 'Plain body'
                Should-BeCollection -Actual (Get-RecipientAddress $payload.message.toRecipients) -Expected @('a@contoso.com', 'b@contoso.com')
            }

            It 'marks the body as HTML when -BodyAsHtml is set' {
                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body '<p>x</p>' -BodyAsHtml -GraphAccessToken 't'
                }

                (Get-LastPayload).message.body.contentType | Should-Be 'HTML'
            }

            It 'includes Cc, Bcc, and ReplyTo recipients when provided' {
                InModuleScope keel.Mail {
                    $params = @{
                        SendUserId       = 's@contoso.com'
                        Subject          = 'Hi'
                        To               = 'a@contoso.com'
                        Cc               = 'cc@contoso.com'
                        Bcc              = 'bcc1@contoso.com', 'bcc2@contoso.com'
                        ReplyTo          = 'reply@contoso.com'
                        Body             = 'B'
                        GraphAccessToken = 't'
                    }
                    Send-GraphEmail @params
                }

                $message = (Get-LastPayload).message
                (Get-RecipientAddress $message.ccRecipients) | Should-Be 'cc@contoso.com'
                Should-BeCollection -Actual (Get-RecipientAddress $message.bccRecipients) -Expected @('bcc1@contoso.com', 'bcc2@contoso.com')
                (Get-RecipientAddress $message.replyTo) | Should-Be 'reply@contoso.com'
            }

            It 'omits Cc, Bcc, ReplyTo, and attachments when not provided' {
                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -GraphAccessToken 't'
                }

                $propertyNames = (Get-LastPayload).message.PSObject.Properties.Name
                $propertyNames -contains 'ccRecipients' | Should-BeFalse
                $propertyNames -contains 'bccRecipients' | Should-BeFalse
                $propertyNames -contains 'replyTo' | Should-BeFalse
                $propertyNames -contains 'attachments' | Should-BeFalse
            }

            It 'attaches a file as a base64 fileAttachment' {
                $file = Join-Path $TestDrive 'log.txt'
                Set-Content -Path $file -Value 'log line' -NoNewline

                InModuleScope keel.Mail -Parameters @{ File = $file } {
                    param($File)
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -AttachmentPath $File -GraphAccessToken 't'
                }

                $attachments = @((Get-LastPayload).message.attachments)
                $attachments.Count | Should-Be 1
                $attachments[0].name | Should-Be 'log.txt'
                $attachments[0].contentBytes | Should-Be ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('log line')))
            }

            It 'attaches multiple files in the order given' {
                $files = @(
                    New-SizedFile -Name 'first.log' -Bytes 10
                    New-SizedFile -Name 'second.csv' -Bytes 20
                )

                InModuleScope keel.Mail -Parameters @{ Files = $files } {
                    param($Files)
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -AttachmentPath $Files -GraphAccessToken 't'
                }

                $attachments = @((Get-LastPayload).message.attachments)
                Should-BeCollection -Actual @($attachments | ForEach-Object { $_.name }) -Expected @('first.log', 'second.csv')
            }

            It 'ignores empty entries in the attachment list' {
                $file = New-SizedFile -Name 'only.txt' -Bytes 5

                InModuleScope keel.Mail -Parameters @{ File = $file } {
                    param($File)
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -AttachmentPath '', $File, ' ' -GraphAccessToken 't'
                }

                @((Get-LastPayload).message.attachments).Count | Should-Be 1
            }

            It 'accepts attachments totaling exactly 3 MB' {
                $files = @(
                    New-SizedFile -Name 'half-a.bin' -Bytes 1.5MB
                    New-SizedFile -Name 'half-b.bin' -Bytes 1.5MB
                )

                InModuleScope keel.Mail -Parameters @{ Files = $files } {
                    param($Files)
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -AttachmentPath $Files -GraphAccessToken 't'
                }

                $script:RestCalls.Count | Should-Be 1
            }

            It 'rejects <Case> over the 3 MB inline limit without calling Graph' -ForEach @(
                @{ Case = 'a single file'; Sizes = @(3MB + 1) }
                @{ Case = 'files that are small individually but'; Sizes = @(2MB, 2MB) }
            ) {
                $files = for ($i = 0; $i -lt $Sizes.Count; $i++) { New-SizedFile -Name "big$i.bin" -Bytes $Sizes[$i] }

                {
                    InModuleScope keel.Mail -Parameters @{ Files = $files } {
                        param($Files)
                        Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -AttachmentPath $Files -GraphAccessToken 't'
                    }
                } | Should-Throw -ExceptionMessage 'Attachments total * MB, which exceeds the 3 MB Graph inline attachment limit.*'

                $script:RestCalls.Count | Should-Be 0
            }

            It 'fails before sending when any attachment in the list is missing' {
                $file = New-SizedFile -Name 'present.txt' -Bytes 5

                {
                    InModuleScope keel.Mail -Parameters @{ Files = @($file, (Join-Path $TestDrive 'absent.txt')) } {
                        param($Files)
                        Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -AttachmentPath $Files -GraphAccessToken 't'
                    }
                } | Should-Throw -ExceptionMessage 'Attachment file not found:*absent.txt'

                $script:RestCalls.Count | Should-Be 0
            }

            It 'retries transient Graph failures through Invoke-WithBoundedRetry' {
                $script:GraphAttempts = 0
                Mock Invoke-RestMethod -ModuleName keel.Mail {
                    $script:GraphAttempts++
                    if ($script:GraphAttempts -eq 1) {
                        throw 'Response status code does not indicate success: 503 (Service Unavailable).'
                    }
                }

                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -GraphAccessToken 't'
                }

                $script:GraphAttempts | Should-Be 2
            }

            It 'does not use the Graph SDK when a token is supplied' {
                Mock Invoke-MgGraphRequest -ModuleName keel.Mail { }

                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B' -GraphAccessToken 't'
                }

                Should-NotInvoke Invoke-MgGraphRequest -ModuleName keel.Mail
            }
        }

        Context 'with the Graph SDK' {
            BeforeEach {
                Mock Invoke-MgGraphRequest -ModuleName keel.Mail { }
                Mock Connect-AutomationGraph -ModuleName keel.Mail { }
            }

            It 'uses the existing SDK session without reconnecting' {
                Mock Get-MgContext -ModuleName keel.Mail { [pscustomobject]@{ TenantId = 'tenant-id' } }

                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 'sender@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B'
                }

                Should-NotInvoke Connect-AutomationGraph -ModuleName keel.Mail
                Should-Invoke Invoke-MgGraphRequest -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'POST' -and
                    $Uri -eq '/v1.0/users/sender%40contoso.com/sendMail' -and
                    $ContentType -eq 'application/json' -and
                    ($Body | ConvertFrom-Json).message.subject -eq 'Hi'
                }
            }

            It 'connects with app-only configuration when there is no SDK session' {
                # Get-MgContext returns $null (it does not throw) when disconnected.
                $script:ContextCalls = 0
                Mock Get-MgContext -ModuleName keel.Mail {
                    $script:ContextCalls++
                    if ($script:ContextCalls -gt 1) { [pscustomobject]@{ TenantId = 'tenant-id' } }
                }

                InModuleScope keel.Mail {
                    Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B'
                }

                Should-Invoke Connect-AutomationGraph -ModuleName keel.Mail -Times 1 -Exactly
                Should-Invoke Invoke-MgGraphRequest -ModuleName keel.Mail -Times 1 -Exactly
            }

            It 'propagates connection failures without sending' {
                Mock Get-MgContext -ModuleName keel.Mail { }
                Mock Connect-AutomationGraph -ModuleName keel.Mail { throw 'bad config' }

                {
                    InModuleScope keel.Mail {
                        Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B'
                    }
                } | Should-Throw -ExceptionMessage 'bad config'

                Should-NotInvoke Invoke-MgGraphRequest -ModuleName keel.Mail
            }
        }

        Context 'with no Graph auth available' {
            It 'throws a clear error message' {
                Mock Get-Command -ModuleName keel.Mail -ParameterFilter { $Name -eq 'Invoke-MgGraphRequest' } { $null }

                {
                    InModuleScope keel.Mail {
                        Send-GraphEmail -SendUserId 's@contoso.com' -Subject 'Hi' -To 'a@contoso.com' -Body 'B'
                    }
                } | Should-Throw -ExceptionMessage 'No Graph auth method available*'
            }
        }
    }

    Describe 'Send-SmtpEmail' {
        BeforeEach {
            Mock Send-MailMessage -ModuleName keel.Mail { }
        }

        It 'sends the core message fields via Send-MailMessage' {
            InModuleScope keel.Mail {
                Send-SmtpEmail -SmtpServer 'smtp.contoso.com' -Subject 'Hi' -To 'a@contoso.com' -From 'f@contoso.com' -Body 'B'
            }

            Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                $SmtpServer -eq 'smtp.contoso.com' -and
                $Subject -eq 'Hi' -and
                $To -eq 'a@contoso.com' -and
                $From -eq 'f@contoso.com' -and
                $Body -eq 'B' -and
                -not $BodyAsHtml
            }
        }

        It 'omits optional parameters that were not provided' {
            InModuleScope keel.Mail {
                Send-SmtpEmail -SmtpServer 'smtp.contoso.com' -Subject 'Hi' -To 'a@contoso.com' -From 'f@contoso.com' -Body 'B' -Cc @() -Bcc $null
            }

            Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                -not $PesterBoundParameters.ContainsKey('Cc') -and
                -not $PesterBoundParameters.ContainsKey('Bcc') -and
                -not $PesterBoundParameters.ContainsKey('ReplyTo') -and
                -not $PesterBoundParameters.ContainsKey('Attachments') -and
                -not $PesterBoundParameters.ContainsKey('BodyAsHtml')
            }
        }

        It 'passes Cc, Bcc, ReplyTo, BodyAsHtml, and the resolved attachment path' {
            $file = New-Item -Path (Join-Path $TestDrive 'smtp.txt') -ItemType File -Value 'x' -Force

            InModuleScope keel.Mail -Parameters @{ File = $file.FullName } {
                param($File)
                $params = @{
                    SmtpServer     = 'smtp.contoso.com'
                    Subject        = 'Hi'
                    To             = 'a@contoso.com'
                    Cc             = 'cc@contoso.com'
                    Bcc            = 'bcc@contoso.com'
                    ReplyTo        = 'reply@contoso.com'
                    From           = 'f@contoso.com'
                    Body           = '<b>B</b>'
                    AttachmentPath = $File
                    BodyAsHtml     = $true
                }
                Send-SmtpEmail @params
            }

            $expectedPath = (Resolve-Path -LiteralPath $file.FullName).Path
            Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                $Cc -eq 'cc@contoso.com' -and
                $Bcc -eq 'bcc@contoso.com' -and
                $ReplyTo -eq 'reply@contoso.com' -and
                $Attachments -eq $expectedPath -and
                $BodyAsHtml
            }
        }

        It 'passes every resolved attachment path' {
            $files = @(
                New-SizedFile -Name 'smtp-a.txt' -Bytes 1
                New-SizedFile -Name 'smtp-b.txt' -Bytes 1
            )

            InModuleScope keel.Mail -Parameters @{ Files = $files } {
                param($Files)
                Send-SmtpEmail -SmtpServer 's' -Subject 'Hi' -To 'a@contoso.com' -From 'f@contoso.com' -Body 'B' -AttachmentPath $Files
            }

            $expected = $files | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }
            Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                ($Attachments -join '|') -eq ($expected -join '|')
            }
        }

        It 'does not apply the Graph size limit to SMTP' {
            $file = New-SizedFile -Name 'large-smtp.bin' -Bytes 4MB

            InModuleScope keel.Mail -Parameters @{ File = $file } {
                param($File)
                Send-SmtpEmail -SmtpServer 's' -Subject 'Hi' -To 'a@contoso.com' -From 'f@contoso.com' -Body 'B' -AttachmentPath $File
            }

            Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly
        }

        It 'throws before sending when the attachment is missing' {
            {
                InModuleScope keel.Mail -Parameters @{ File = (Join-Path $TestDrive 'missing.txt') } {
                    param($File)
                    Send-SmtpEmail -SmtpServer 's' -Subject 'Hi' -To 'a@contoso.com' -From 'f@contoso.com' -Body 'B' -AttachmentPath $File
                }
            } | Should-Throw -ExceptionMessage 'Attachment file not found:*'

            Should-NotInvoke Send-MailMessage -ModuleName keel.Mail
        }
    }

    Describe 'Invoke-Delivery' {
        BeforeEach {
            Mock Send-GraphEmail -ModuleName keel.Mail { }
            Mock Send-SmtpEmail -ModuleName keel.Mail { }
            Mock Write-Warning -ModuleName keel.Mail { }

            $script:DeliveryArgs = @{
                Subject           = 'Hi'
                To                = 'a@contoso.com'
                From              = 'f@contoso.com'
                Body              = 'B'
                GraphSenderUserId = 'sender@contoso.com'
            }
        }

        Context 'SMTP delivery' {
            It 'sends via SMTP only' {
                InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                    param($A)
                    Invoke-Delivery -DeliveryMethod Smtp -SmtpServer 'smtp.contoso.com' @A
                }

                Should-Invoke Send-SmtpEmail -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $SmtpServer -eq 'smtp.contoso.com' -and $From -eq 'f@contoso.com'
                }
                Should-NotInvoke Send-GraphEmail -ModuleName keel.Mail
            }

            It 'requires an SMTP server' {
                {
                    InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                        param($A)
                        Invoke-Delivery -DeliveryMethod Smtp @A
                    }
                } | Should-Throw -ExceptionMessage 'SmtpServer is required when DeliveryMethod is Smtp.'
            }

            It 'passes -BodyAsHtml through to SMTP as a switch' {
                InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                    param($A)
                    Invoke-Delivery -DeliveryMethod Smtp -SmtpServer 'smtp.contoso.com' -BodyAsHtml @A
                }

                Should-Invoke Send-SmtpEmail -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $BodyAsHtml -eq $true }
            }
        }

        Context 'Graph delivery' {
            It 'sends via Graph using the Graph sender identity and token' {
                InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                    param($A)
                    Invoke-Delivery -DeliveryMethod Graph -GraphAccessToken 'tok' @A
                }

                Should-Invoke Send-GraphEmail -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $SendUserId -eq 'sender@contoso.com' -and $GraphAccessToken -eq 'tok'
                }
                Should-NotInvoke Send-SmtpEmail -ModuleName keel.Mail
            }

            It 'passes -BodyAsHtml through to Graph as a switch' {
                InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                    param($A)
                    Invoke-Delivery -DeliveryMethod Graph -BodyAsHtml @A
                }

                Should-Invoke Send-GraphEmail -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $BodyAsHtml -eq $true }
            }

            It 'rethrows Graph failures when fallback is not enabled' {
                Mock Send-GraphEmail -ModuleName keel.Mail { throw 'graph down' }

                {
                    InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                        param($A)
                        Invoke-Delivery -DeliveryMethod Graph -SmtpServer 'smtp.contoso.com' @A
                    }
                } | Should-Throw -ExceptionMessage 'graph down'

                Should-NotInvoke Send-SmtpEmail -ModuleName keel.Mail
            }

            It 'rethrows Graph failures when fallback is explicitly disabled' {
                Mock Send-GraphEmail -ModuleName keel.Mail { throw 'graph down' }

                {
                    InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                        param($A)
                        Invoke-Delivery -DeliveryMethod Graph -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback:$false @A
                    }
                } | Should-Throw -ExceptionMessage 'graph down'

                Should-NotInvoke Send-SmtpEmail -ModuleName keel.Mail
            }

            It 'falls back to SMTP with a warning when Graph fails and fallback is enabled' {
                Mock Send-GraphEmail -ModuleName keel.Mail { throw 'graph down' }

                InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                    param($A)
                    Invoke-Delivery -DeliveryMethod Graph -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback @A
                }

                Should-Invoke Send-SmtpEmail -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $SmtpServer -eq 'smtp.contoso.com' }
                Should-Invoke Write-Warning -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $Message -like '*graph down*' }
            }

            It 'throws with the Graph error when fallback is enabled but no SMTP server is set' {
                Mock Send-GraphEmail -ModuleName keel.Mail { throw 'graph down' }

                {
                    InModuleScope keel.Mail -Parameters @{ A = $DeliveryArgs } {
                        param($A)
                        Invoke-Delivery -DeliveryMethod Graph -AllowSmtpFallback @A
                    }
                } | Should-Throw -ExceptionMessage '*SmtpServer was not provided*Graph error: graph down'

                Should-NotInvoke Send-SmtpEmail -ModuleName keel.Mail
            }
        }
    }

    Describe 'Send-Email' {
        Context 'parameter contract' {
            It 'requires <Name>' -ForEach @(
                @{ Name = 'Subject' }, @{ Name = 'To' }, @{ Name = 'From' }, @{ Name = 'Body' }
            ) {
                Get-Command Send-Email | Should-HaveParameter $Name -Mandatory
            }

            It 'accepts multiple attachment paths' {
                Get-Command Send-Email | Should-HaveParameter AttachmentPath -Type 'string[]'
            }

            It 'exposes <Name> as a switch' -ForEach @(
                @{ Name = 'BodyAsHtml' }, @{ Name = 'AllowSmtpFallback' }
            ) {
                Get-Command Send-Email | Should-HaveParameter $Name -Type switch
            }

            It 'defaults DeliveryMethod to Graph' {
                Get-Command Send-Email | Should-HaveParameter DeliveryMethod -DefaultValue 'Graph'
            }

            It 'rejects an unknown DeliveryMethod' {
                { Send-Email @BaseMail -DeliveryMethod 'Carrier Pigeon' } | Should-Throw
            }

            It 'supports -WhatIf' {
                Get-Command Send-Email | Should-HaveParameter WhatIf
            }
        }

        Context 'input validation and normalization' {
            BeforeEach {
                Mock Invoke-Delivery -ModuleName keel.Mail { }
            }

            It 'rejects a whitespace-only <Name>' -ForEach @(
                @{ Name = 'Subject'; Expected = 'Subject cannot be null, empty, or whitespace.' }
                @{ Name = 'From'; Expected = 'From cannot be null, empty, or whitespace.' }
                @{ Name = 'Body'; Expected = 'Body cannot be null, empty, or whitespace.' }
                @{ Name = 'To'; Expected = 'To must include at least one non-empty recipient address.' }
            ) {
                $mail = $BaseMail.Clone()
                $mail[$Name] = '   '

                { Send-Email @mail } | Should-Throw -ExceptionMessage $Expected
                Should-NotInvoke Invoke-Delivery -ModuleName keel.Mail
            }

            It 'trims and de-duplicates To, Cc, and Bcc before delivery' {
                Send-Email @BaseMail -To ' a@contoso.com', 'A@contoso.com', 'b@contoso.com' -Cc 'c@contoso.com ', 'C@contoso.com' -Bcc ' d@contoso.com'

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    ($To -join ',') -eq 'a@contoso.com,b@contoso.com' -and
                    ($Cc -join ',') -eq 'c@contoso.com' -and
                    ($Bcc -join ',') -eq 'd@contoso.com'
                }
            }

            It 'trims From and uses it as the Graph sender when no sender is given' {
                Send-Email @BaseMail -From '  automation@contoso.com  '

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $From -eq 'automation@contoso.com' -and $GraphSenderUserId -eq 'automation@contoso.com'
                }
            }

            It 'uses an explicit GraphSenderUserId, trimmed' {
                Send-Email @BaseMail -GraphSenderUserId ' shared-mailbox@contoso.com '

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $GraphSenderUserId -eq 'shared-mailbox@contoso.com'
                }
            }

            It 'delivers via Graph without fallback by default' {
                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $DeliveryMethod -eq 'Graph' -and -not [bool]$AllowSmtpFallback
                }
            }

            It 'passes -BodyAsHtml through' {
                Send-Email @BaseMail -BodyAsHtml

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { [bool]$BodyAsHtml }
            }

            It 'passes -AllowSmtpFallback through when used as a switch' {
                Send-Email @BaseMail -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { [bool]$AllowSmtpFallback }
            }

            It 'does not deliver under -WhatIf, even with Cc recipients' {
                Send-Email @BaseMail -Cc 'cc@contoso.com' -Bcc 'bcc@contoso.com' -WhatIf

                Should-NotInvoke Invoke-Delivery -ModuleName keel.Mail
            }
        }

        Context 'environment defaults' {
            BeforeEach {
                Mock Invoke-Delivery -ModuleName keel.Mail { }
            }

            It 'reads the delivery method from KEEL_MAIL_DELIVERY_METHOD' {
                $env:KEEL_MAIL_DELIVERY_METHOD = 'Smtp'

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $DeliveryMethod -eq 'Smtp' }
            }

            It 'lets an explicit -DeliveryMethod override KEEL_MAIL_DELIVERY_METHOD' {
                $env:KEEL_MAIL_DELIVERY_METHOD = 'Smtp'

                Send-Email @BaseMail -DeliveryMethod Graph

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $DeliveryMethod -eq 'Graph' }
            }

            It 'ignores an unsupported KEEL_MAIL_DELIVERY_METHOD value with a warning' {
                Mock Write-Warning -ModuleName keel.Mail { }
                $env:KEEL_MAIL_DELIVERY_METHOD = 'Fax'

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $DeliveryMethod -eq 'Graph' }
                Should-Invoke Write-Warning -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $Message -like "*KEEL_MAIL_DELIVERY_METHOD value 'Fax'*" }
            }

            It 'does not warn about a valid KEEL_MAIL_DELIVERY_METHOD' {
                Mock Write-Warning -ModuleName keel.Mail { }
                $env:KEEL_MAIL_DELIVERY_METHOD = 'Smtp'

                Send-Email @BaseMail

                Should-NotInvoke Write-Warning -ModuleName keel.Mail
            }

            It 'reads the Graph sender and token from the environment' {
                $env:KEEL_GRAPH_SENDER_USER_ID = 'env-sender@contoso.com'
                $env:KEEL_GRAPH_ACCESS_TOKEN = 'env-token'

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $GraphSenderUserId -eq 'env-sender@contoso.com' -and $GraphAccessToken -eq 'env-token'
                }
            }

            It 'prefers explicit Graph sender and token over the environment' {
                $env:KEEL_GRAPH_SENDER_USER_ID = 'env-sender@contoso.com'
                $env:KEEL_GRAPH_ACCESS_TOKEN = 'env-token'

                Send-Email @BaseMail -GraphSenderUserId 'param-sender@contoso.com' -GraphAccessToken 'param-token'

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $GraphSenderUserId -eq 'param-sender@contoso.com' -and $GraphAccessToken -eq 'param-token'
                }
            }

            It 'enables SMTP fallback when KEEL_MAIL_ALLOW_SMTP_FALLBACK is "<Value>"' -ForEach @(
                @{ Value = 'true' }, @{ Value = 'yes' }, @{ Value = '1' }
            ) {
                $env:KEEL_MAIL_ALLOW_SMTP_FALLBACK = $Value

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { [bool]$AllowSmtpFallback }
            }

            It 'leaves SMTP fallback disabled when KEEL_MAIL_ALLOW_SMTP_FALLBACK is "<Value>"' -ForEach @(
                @{ Value = 'false' }, @{ Value = '0' }, @{ Value = 'garbage' }
            ) {
                $env:KEEL_MAIL_ALLOW_SMTP_FALLBACK = $Value

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { -not [bool]$AllowSmtpFallback }
            }

            It 'warns about an unrecognized KEEL_MAIL_ALLOW_SMTP_FALLBACK value' {
                Mock Write-Warning -ModuleName keel.Mail { }
                $env:KEEL_MAIL_ALLOW_SMTP_FALLBACK = 'garbage'

                Send-Email @BaseMail

                Should-Invoke Write-Warning -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $Message -like "*KEEL_MAIL_ALLOW_SMTP_FALLBACK value 'garbage'*" }
            }

            It 'does not warn about a recognized KEEL_MAIL_ALLOW_SMTP_FALLBACK value' {
                Mock Write-Warning -ModuleName keel.Mail { }
                $env:KEEL_MAIL_ALLOW_SMTP_FALLBACK = 'off'

                Send-Email @BaseMail

                Should-NotInvoke Write-Warning -ModuleName keel.Mail
            }

            It 'parses comma- and semicolon-delimited KEEL_MAIL_CC when -Cc is not supplied' {
                $env:KEEL_MAIL_CC = 'one@contoso.com; two@contoso.com,three@contoso.com'

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    ($Cc -join ',') -eq 'one@contoso.com,two@contoso.com,three@contoso.com'
                }
            }

            It 'lets an explicit -Cc override KEEL_MAIL_CC' {
                $env:KEEL_MAIL_CC = 'env@contoso.com'

                Send-Email @BaseMail -Cc 'param@contoso.com'

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { ($Cc -join ',') -eq 'param@contoso.com' }
            }

            It 'throws when KEEL_MAIL_CC contains only delimiters' {
                $env:KEEL_MAIL_CC = ' ; , '

                { Send-Email @BaseMail } | Should-Throw -ExceptionMessage 'Cc must include at least one non-empty recipient address.'
            }

            It 'parses KEEL_MAIL_REPLY_TO into ReplyTo without changing To' {
                $env:KEEL_MAIL_REPLY_TO = 'helpdesk@contoso.com;noc@contoso.com'

                Send-Email @BaseMail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    ($ReplyTo -join ',') -eq 'helpdesk@contoso.com,noc@contoso.com' -and
                    ($To -join ',') -eq 'ops@contoso.com'
                }
            }

            It 'lets an explicit -ReplyTo override KEEL_MAIL_REPLY_TO' {
                $env:KEEL_MAIL_REPLY_TO = 'env@contoso.com'

                Send-Email @BaseMail -ReplyTo 'param@contoso.com'

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { ($ReplyTo -join ',') -eq 'param@contoso.com' }
            }

            It 'throws when KEEL_MAIL_REPLY_TO contains only delimiters' {
                $env:KEEL_MAIL_REPLY_TO = ';'

                { Send-Email @BaseMail } | Should-Throw -ExceptionMessage 'ReplyTo must include at least one non-empty recipient address.'
            }

            It 'resolves the SMTP server from <Source>' -ForEach @(
                @{ Source = 'KEEL_SMTP_SERVER'; Server = 'server.contoso.com'; Relay = 'relay.contoso.com'; Param = $null; Expected = 'server.contoso.com' }
                @{ Source = 'KEEL_SMTP_RELAY'; Server = $null; Relay = 'relay.contoso.com'; Param = $null; Expected = 'relay.contoso.com' }
                @{ Source = '-SmtpServer (trimmed)'; Server = 'server.contoso.com'; Relay = $null; Param = ' param.contoso.com '; Expected = 'param.contoso.com' }
            ) {
                $env:KEEL_SMTP_SERVER = $Server
                $env:KEEL_SMTP_RELAY = $Relay
                $mail = $BaseMail.Clone()
                if ($Param) { $mail.SmtpServer = $Param }

                Send-Email @mail

                Should-Invoke Invoke-Delivery -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $SmtpServer -eq $Expected }
            }
        }

        Context 'end-to-end transport' {
            BeforeEach {
                $script:RestCalls = [System.Collections.Generic.List[hashtable]]::new()
                Mock Invoke-RestMethod -ModuleName keel.Mail {
                    $script:RestCalls.Add(@{ Uri = [string]$Uri; Body = $Body })
                }
                Mock Send-MailMessage -ModuleName keel.Mail { }
                Mock Write-Warning -ModuleName keel.Mail { }
            }

            It 'sends through Graph REST when an access token is available' {
                Send-Email @BaseMail -GraphAccessToken 'tok' -Cc 'cc@contoso.com'

                $script:RestCalls.Count | Should-Be 1
                $script:RestCalls[0].Uri | Should-Be 'https://graph.microsoft.com/v1.0/users/automation%40contoso.com/sendMail'
                $message = ($script:RestCalls[0].Body | ConvertFrom-Json).message
                (Get-RecipientAddress $message.toRecipients) | Should-Be 'ops@contoso.com'
                (Get-RecipientAddress $message.ccRecipients) | Should-Be 'cc@contoso.com'
                Should-NotInvoke Send-MailMessage -ModuleName keel.Mail
            }

            It 'sends through SMTP when DeliveryMethod is Smtp' {
                Send-Email @BaseMail -DeliveryMethod Smtp -SmtpServer 'smtp.contoso.com' -BodyAsHtml

                $script:RestCalls.Count | Should-Be 0
                Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter {
                    $SmtpServer -eq 'smtp.contoso.com' -and $To -eq 'ops@contoso.com' -and $BodyAsHtml
                }
            }

            It 'falls back to SMTP when Graph rejects the request and fallback is enabled' {
                Mock Invoke-RestMethod -ModuleName keel.Mail {
                    throw 'Response status code does not indicate success: 403 (Forbidden).'
                }

                Send-Email @BaseMail -GraphAccessToken 'tok' -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback

                Should-Invoke Invoke-RestMethod -ModuleName keel.Mail -Times 1 -Exactly
                Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly
            }

            It 'does not fall back to SMTP when fallback is not enabled, even if an SMTP server is configured' {
                Mock Invoke-RestMethod -ModuleName keel.Mail {
                    throw 'Response status code does not indicate success: 403 (Forbidden).'
                }
                $env:KEEL_SMTP_SERVER = 'smtp.contoso.com'

                { Send-Email @BaseMail -GraphAccessToken 'tok' } | Should-Throw -ExceptionMessage '*403*'

                Should-NotInvoke Send-MailMessage -ModuleName keel.Mail
            }

            It 'falls back to SMTP with all attachments when they are too large for Graph' {
                $files = @(
                    New-SizedFile -Name 'e2e-a.bin' -Bytes 2MB
                    New-SizedFile -Name 'e2e-b.bin' -Bytes 2MB
                )

                Send-Email @BaseMail -GraphAccessToken 'tok' -SmtpServer 'smtp.contoso.com' -AllowSmtpFallback -AttachmentPath $files

                $script:RestCalls.Count | Should-Be 0
                Should-Invoke Write-Warning -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { $Message -like '*Graph inline attachment limit*' }
                Should-Invoke Send-MailMessage -ModuleName keel.Mail -Times 1 -Exactly -ParameterFilter { @($Attachments).Count -eq 2 }
            }
        }
    }
}
