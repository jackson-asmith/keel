<#
.SYNOPSIS
Mail delivery helpers for automation workflows.

.DESCRIPTION
Provides common mail delivery behavior for automation scripts.
The module is designed to support unattended automation in an Exchange Online
environment by sending mail through Microsoft Graph by default, while still
allowing explicit SMTP usage or SMTP fallback when required.

The public entry point is Send-Email. Internal helper functions
support Graph recipient shaping, attachment conversion, and delivery transport
selection.

HTTP retry primitives are provided by keel.Http, declared as a required module
in the manifest.
#>

# Graph caps a sendMail request at about 4 MB. Base64 encoding inflates attachment
# content by a third, so 3 MB of raw attachment data is the most that fits inline.
# Larger files need a Graph upload session, which this module does not implement.
$script:GraphInlineAttachmentLimitBytes = 3MB

# sendMail is not idempotent: repeating a request Graph already accepted sends the
# message again. Only retry statuses where Graph refused the request outright.
# A 500, 502, or 504 can arrive after the message was accepted, so those are
# never retried and never trigger SMTP fallback.
$script:GraphSendRetryableStatusCodes = @(429, 503)

# Failures raised before a connection exists, so the request never reached Graph.
# HttpRequestError is PowerShell 7.4+ (.NET 8), WebExceptionStatus is Windows
# PowerShell 5.1, and SocketError covers the socket layer underneath either one.
$script:NotSentHttpRequestErrors = @(
    'NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ProxyTunnelError'
)
$script:NotSentWebExceptionStatuses = @(
    'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure',
    'SecureChannelFailure', 'TrustFailure'
)
$script:NotSentSocketErrors = @(
    'HostNotFound', 'NoData', 'TryAgain', 'ConnectionRefused', 'NetworkUnreachable', 'HostUnreachable'
)


function Convert-ToGraphRecipient {
    <#
    .SYNOPSIS
    Converts email addresses to Microsoft Graph recipient objects.

    .DESCRIPTION
    Transforms an array of email addresses into the Microsoft Graph format
    for use in mail send operations. Addresses are validated and normalized
    before conversion.

    .PARAMETER AddressList
    An array of email addresses to convert. Accepts input from the pipeline.

    .EXAMPLE
    Convert-ToGraphRecipient -AddressList 'user@contoso.com', 'admin@contoso.com'

    .EXAMPLE
    'user@contoso.com', 'admin@contoso.com' | Convert-ToGraphRecipient
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string[]]$AddressList
    )

    begin {
        $allAddresses = @()
    }

    process {
        if ($null -ne $AddressList) {
            $allAddresses += $AddressList
        }
    }

    end {
        $normalizeAddressList = Convert-EmailAddress -AddressList $allAddresses
        Write-Debug "Convert-ToGraphRecipient: Processing $($normalizeAddressList.Count) addresses"

        $recipientList = @()
        foreach ($address in $normalizeAddressList) {
            if (-not [string]::IsNullOrWhiteSpace($address)) {
                $recipientList += @{ emailAddress = @{ address = $address } }
            }
        }

        Write-Debug "Convert-ToGraphRecipient: Created $($recipientList.Count) recipient objects"
        $recipientList
    }
}

function ConvertTo-BooleanValue {
    <#
    .SYNOPSIS
    Converts string representations to boolean values.

    .DESCRIPTION
    Parses string values that represent boolean states, including common
    variations like 'true', 'yes', '1', and 'on', 'false', 'no', '0', and 'off'.
    Returns the specified default value if the input is null or unrecognized.

    .PARAMETER Value
    The string value to convert. Can be null or whitespace.

    .PARAMETER Default
    The default boolean value to return if Value is null or unrecognized.
    Defaults to $false.

    .EXAMPLE
    ConvertTo-BooleanValue -Value 'yes' -Default $false
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value,

        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Default
    }

    else {
        switch -Regex ($Value.Trim()) {
            '^(1|true|yes|y|on)$' { $true }
            '^(0|false|no|n|off)$' { $false }
            default { $Default }
        }
    }
}

function Convert-EmailAddress {
    <#
    .SYNOPSIS
    Normalizes and deduplicates email addresses.

    .DESCRIPTION
    Trims whitespace from email addresses, removes duplicates based on
    case-insensitive comparison, and returns a deduplicated array.

    .PARAMETER AddressList
    An array of email addresses to normalize and deduplicate.

    .EXAMPLE
    Convert-EmailAddress -AddressList 'USER@contoso.com', 'user@contoso.com'
    #>
    [CmdletBinding()]
    param(
        [string[]]$AddressList
    )

    $normalized = [System.Collections.Generic.List[string]]::new()
    $seen = @{}

    foreach ($address in $AddressList) {
        if ([string]::IsNullOrWhiteSpace($address)) {
            continue
        }

        $trimmedAddress = $address.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedAddress)) {
            continue
        }

        $dedupeKey = $trimmedAddress.ToLowerInvariant()
        if ($seen.ContainsKey($dedupeKey)) {
            continue
        }

        $seen[$dedupeKey] = $true
        [void]$normalized.Add($trimmedAddress)
    }

    @($normalized)
}

function Resolve-AttachmentFilePath {
    <#
    .SYNOPSIS
    Resolves and validates an attachment file path.

    .DESCRIPTION
    Verifies that the specified path exists as a file and returns the
    full resolved path. Throws an error if the file is not found.

    .PARAMETER Path
    The literal path to the attachment file. Accepts pipeline input by property name.

    .EXAMPLE
    Resolve-AttachmentFilePath -Path 'C:\attachments\report.pdf'

    .EXAMPLE
    Get-Item 'C:\attachments\report.pdf' | Resolve-AttachmentFilePath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName = $true)]
        [string]$Path
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Debug "Resolve-AttachmentFilePath: File not found at path: $Path"
            throw "Attachment file not found: $Path"
        }

        $resolved = (Resolve-Path -LiteralPath $Path).Path
        Write-Debug "Resolve-AttachmentFilePath: Resolved path to: $resolved"
        $resolved
    }
}

function Connect-AutomationGraph {
    <#
    .SYNOPSIS
    Establishes a connection to Microsoft Graph for automation.

    .DESCRIPTION
    Connects to Microsoft Graph using app-only authentication.
    Supports both certificate-based and client-secret-based authentication.
    Requires the Microsoft Graph PowerShell SDK and environment variables
    configured with tenant, client, and authentication details.

    .NOTES
    Supported environment variables:
    KEEL_GRAPH_TENANT_ID
    KEEL_GRAPH_CLIENT_ID
    KEEL_GRAPH_CERTIFICATE_THUMBPRINT
    KEEL_GRAPH_CLIENT_SECRET
    KEEL_GRAPH_AUTH_MODE

    .EXAMPLE
    Connect-AutomationGraph
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The client secret arrives as plain text in KEEL_GRAPH_CLIENT_SECRET and must become a PSCredential for Connect-MgGraph.'
    )]
    [CmdletBinding()]
    param ()

    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw (
            'Connect-MgGraph is not available. Install the Microsoft Graph PowerShell SDK ' +
            'or provide -GraphAccessToken.'
        )
    }

    $tenantId = $env:KEEL_GRAPH_TENANT_ID
    $clientId = $env:KEEL_GRAPH_CLIENT_ID
    $certificateThumbprint = $env:KEEL_GRAPH_CERTIFICATE_THUMBPRINT
    $clientSecret = $env:KEEL_GRAPH_CLIENT_SECRET
    $authMode = $env:KEEL_GRAPH_AUTH_MODE

    # Determine which auth mode to use
    $selectedMode = $null
    if ($authMode -eq 'Certificate') {
        $selectedMode = 'Certificate'
    }
    elseif ($authMode -eq 'ClientSecret') {
        $selectedMode = 'ClientSecret'
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($authMode)) {
            Write-Warning "Ignoring KEEL_GRAPH_AUTH_MODE value '$authMode'. Expected Certificate or ClientSecret. Choosing the mode automatically."
        }

        # Auto mode: prefer certificate if available, then client-secret
        if (-not [string]::IsNullOrWhiteSpace($certificateThumbprint)) {
            $selectedMode = 'Certificate'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($clientSecret)) {
            $selectedMode = 'ClientSecret'
        }
    }

    if ($selectedMode -eq 'Certificate') {
        if (
            [string]::IsNullOrWhiteSpace($tenantId) -or
            [string]::IsNullOrWhiteSpace($clientId) -or
            [string]::IsNullOrWhiteSpace($certificateThumbprint)
        ) {
            throw (
                'No active Graph connection and incomplete certificate app-only configuration. ' +
                'Set KEEL_GRAPH_TENANT_ID, KEEL_GRAPH_CLIENT_ID, and ' +
                'KEEL_GRAPH_CERTIFICATE_THUMBPRINT, or provide -GraphAccessToken.'
            )
        }

        Write-Verbose "Connect-AutomationGraph: Connecting using certificate auth to tenant $tenantId"
        $connectGraphParams = @{
            TenantId              = $tenantId
            ClientId              = $clientId
            CertificateThumbprint = $certificateThumbprint
            NoWelcome             = $true
        }

        Write-Debug "Connect-AutomationGraph: Connecting to tenant $tenantId with client $clientId (certificate mode)"
        Connect-MgGraph @connectGraphParams | Out-Null
    }
    elseif ($selectedMode -eq 'ClientSecret') {
        if (
            [string]::IsNullOrWhiteSpace($tenantId) -or
            [string]::IsNullOrWhiteSpace($clientId) -or
            [string]::IsNullOrWhiteSpace($clientSecret)
        ) {
            throw (
                'No active Graph connection and incomplete client-secret app-only configuration. ' +
                'Set KEEL_GRAPH_TENANT_ID, KEEL_GRAPH_CLIENT_ID, and ' +
                'KEEL_GRAPH_CLIENT_SECRET, or provide -GraphAccessToken.'
            )
        }

        Write-Verbose "Connect-AutomationGraph: Connecting using client-secret auth to tenant $tenantId"
        $secureSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
        $credential = [System.Management.Automation.PSCredential]::new($clientId, $secureSecret)

        Write-Debug "Connect-AutomationGraph: Connecting to tenant $tenantId with client $clientId (client-secret mode)"
        Connect-MgGraph -ClientSecretCredential $credential -TenantId $tenantId -NoWelcome | Out-Null
    }
    else {
        throw (
            'No active Graph connection and incomplete app-only configuration. ' +
            'Set either certificate variables (KEEL_GRAPH_TENANT_ID, KEEL_GRAPH_CLIENT_ID, ' +
            'KEEL_GRAPH_CERTIFICATE_THUMBPRINT) or secret variables (KEEL_GRAPH_TENANT_ID, ' +
            'KEEL_GRAPH_CLIENT_ID, KEEL_GRAPH_CLIENT_SECRET), or provide -GraphAccessToken.'
        )
    }

    Write-Verbose "Connect-AutomationGraph: Successfully connected to Microsoft Graph"
}

function New-GraphFileAttachment {
    <#
    .SYNOPSIS
    Creates a Microsoft Graph file attachment object.

    .DESCRIPTION
    Reads a file from disk and creates a Graph-compatible attachment
    object with base64-encoded content.

    .PARAMETER Path
    The literal path to the file to attach.

    .EXAMPLE
    New-GraphFileAttachment -Path 'C:\reports\summary.pdf'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory attachment object; changes no system state.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = Resolve-AttachmentFilePath -Path $Path

    $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    @{
        '@odata.type' = '#microsoft.graph.fileAttachment'
        name          = [System.IO.Path]::GetFileName($resolvedPath)
        contentType   = 'application/octet-stream'
        contentBytes  = [System.Convert]::ToBase64String($bytes)
    }
}

function Test-GraphSendRefused {
    <#
    .SYNOPSIS
    Reports whether a failed sendMail request was definitely not accepted by Graph.

    .DESCRIPTION
    Returns $true only when the failure proves Graph did not accept the message,
    so resending it, through Graph or SMTP, cannot create a duplicate:

    - A 4xx status: Graph rejected the request.
    - A 503 status: Graph was unavailable and did not process the request.
    - A connection failure with no response: name resolution, connection,
      TLS, or proxy tunnel errors raised before the request was sent.

    - A failure raised before the request was sent, marked with
      Exception.Data['KeelDeliveryState'] = 'NotSent'.

    Returns $false for anything else, including 500, 502, and 504 responses,
    timeouts, and connections dropped mid-request. In those cases Graph may
    have accepted the message before the failure.

    .PARAMETER ErrorRecord
    The error record from the failed sendMail request.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.Exception.Data['KeelDeliveryState'] -eq 'NotSent') {
        return $true
    }

    $statusCode = Get-RetryableStatusCode -ErrorRecord $ErrorRecord
    if ($null -ne $statusCode) {
        return (($statusCode -ge 400 -and $statusCode -le 499) -or $statusCode -eq 503)
    }

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $properties = $exception.PSObject.Properties
        if (
            ($properties['HttpRequestError'] -and "$($exception.HttpRequestError)" -in $script:NotSentHttpRequestErrors) -or
            ($exception -is [System.Net.WebException] -and "$($exception.Status)" -in $script:NotSentWebExceptionStatuses) -or
            ($exception -is [System.Net.Sockets.SocketException] -and "$($exception.SocketErrorCode)" -in $script:NotSentSocketErrors)
        ) {
            return $true
        }

        $exception = $exception.InnerException
    }

    $false
}

function Invoke-GraphRequestWithoutSdkRetry {
    <#
    .SYNOPSIS
    Calls Invoke-MgGraphRequest with the Graph SDK's own retries turned off.

    .DESCRIPTION
    The Microsoft Graph PowerShell SDK sends every Invoke-MgGraphRequest call
    through a retry handler that retries 429, 503, and 504 responses, up to
    MaxRetry times (3 by default), including POSTs with a buffered body. For
    sendMail that means one 504 can resend the message several times before
    Keel sees an error.

    This function sets the SDK's MaxRetry to 0 for one request and then
    restores the caller's settings, so Invoke-WithBoundedRetry is the only
    thing that decides what to retry.

    The SDK's request context is process-wide. While the request is in flight,
    other Graph calls running in parallel in the same process also run without
    SDK retries.

    .PARAMETER Parameters
    The parameters to splat into Invoke-MgGraphRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    # Nothing has been sent yet. Mark any failure here as NotSent so the caller
    # knows it is safe to fall back to SMTP.
    try {
        $saved = Get-MgRequestContext
        if ($null -eq $saved) {
            throw 'Could not read the Graph SDK request context, so SDK retries could not be disabled. The message was not sent.'
        }

        # Get-MgRequestContext reports RetriesTimeLimit as a TimeSpan, but
        # Set-MgRequestContext takes whole seconds.
        $retriesTimeLimit = $saved.RetriesTimeLimit
        $restore = @{
            MaxRetry         = $saved.MaxRetry
            RetryDelay       = $saved.RetryDelay
            RetriesTimeLimit = if ($retriesTimeLimit -is [TimeSpan]) { [int]$retriesTimeLimit.TotalSeconds } elseif ($null -ne $retriesTimeLimit) { [int]$retriesTimeLimit } else { 0 }
        }

        Set-MgRequestContext -MaxRetry 0 | Out-Null
    }
    catch {
        $_.Exception.Data['KeelDeliveryState'] = 'NotSent'
        throw
    }

    try {
        Invoke-MgGraphRequest @Parameters
    }
    finally {
        # A failure to restore must not change what happened to the message, so
        # it is reported as a warning rather than thrown.
        try {
            Set-MgRequestContext @restore | Out-Null
        }
        catch {
            Write-Warning (
                'Could not restore the Graph SDK request context ' +
                "(MaxRetry $($restore.MaxRetry), RetryDelay $($restore.RetryDelay), RetriesTimeLimit $($restore.RetriesTimeLimit)): " +
                $_.Exception.Message
            )
        }
    }
}

function Send-GraphEmail {
    <#
    .SYNOPSIS
    Sends an email through Microsoft Graph.

    .DESCRIPTION
    Delivers an email message using Microsoft Graph API, supporting both
    direct token-based authentication and SDK-based authentication.

    The request is retried only on 429 and 503, where Graph refused it. If the
    request fails in a way that leaves it unclear whether Graph accepted the
    message (for example a 500, 502, or 504, or a timeout), the function throws
    an error with the ErrorId 'GraphDeliveryUnknown' and sets
    Exception.Data['KeelDeliveryState'] to 'Unknown'. Callers must not resend
    the message after that error without checking whether it was delivered.

    .PARAMETER SendUserId
    The Graph user ID of the sender.

    .PARAMETER Subject
    The email subject line.

    .PARAMETER To
    Recipient email address or addresses.

    .PARAMETER Cc
    Carbon copy recipient address or addresses.

    .PARAMETER Bcc
    Blind carbon copy recipient address or addresses.

    .PARAMETER ReplyTo
    Reply-to email address or addresses.

    .PARAMETER Body
    The email body content.

    .PARAMETER AttachmentPath
    Optional path or paths to attachment files. The combined size must not
    exceed 3 MB, the most Graph accepts inline in a sendMail request.

    .PARAMETER BodyAsHtml
    Indicates whether the body should be treated as HTML.

    .PARAMETER GraphAccessToken
    Optional OAuth access token for Graph authentication.

    .EXAMPLE
    Send-GraphEmail -SendUserId 'user@contoso.com' -Subject 'Alert' -To 'admin@contoso.com' -Body 'Test message'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SendUserId,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string[]]$To,

        [string[]]$Cc,

        [string[]]$Bcc,

        [string[]]$ReplyTo,

        [Parameter(Mandatory)]
        [string]$Body,

        [string[]]$AttachmentPath,

        [switch]$BodyAsHtml,

        [string]$GraphAccessToken
    )

    # Resolve and size-check attachments before building the message so an
    # oversized or missing file fails fast, without a network call.
    $attachmentFiles = @(
        $AttachmentPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { Get-Item -LiteralPath (Resolve-AttachmentFilePath -Path $_) }
    )

    $attachmentBytes = ($attachmentFiles | Measure-Object -Property Length -Sum).Sum
    if ($attachmentBytes -gt $script:GraphInlineAttachmentLimitBytes) {
        $totalMegabytes = '{0:N1}' -f ($attachmentBytes / 1MB)
        $limitMegabytes = $script:GraphInlineAttachmentLimitBytes / 1MB
        throw (
            "Attachments total $totalMegabytes MB, which exceeds the $limitMegabytes MB Graph inline " +
            'attachment limit. Send fewer or smaller files, or use SMTP delivery.'
        )
    }

    $contentType = if ($BodyAsHtml) { 'HTML' } else { 'Text' }
    Write-Verbose "Send-GraphEmail: Sending via Graph, ContentType=$contentType, Recipients=$($To.Count)"

    $message = @{
        subject      = $Subject
        toRecipients = @(Convert-ToGraphRecipient -AddressList $To)
        body         = @{
            contentType = $contentType
            content     = $Body
        }
    }

    $ccRecipients = @(Convert-ToGraphRecipient -AddressList $Cc)
    if ($ccRecipients.Count -gt 0) {
        $message['ccRecipients'] = $ccRecipients
    }

    $bccRecipients = @(Convert-ToGraphRecipient -AddressList $Bcc)
    if ($bccRecipients.Count -gt 0) {
        $message['bccRecipients'] = $bccRecipients
    }

    $replyToRecipients = @(Convert-ToGraphRecipient -AddressList $ReplyTo)
    if ($replyToRecipients.Count -gt 0) {
        $message['replyTo'] = $replyToRecipients
    }

    if ($attachmentFiles.Count -gt 0) {
        $message['attachments'] = @(
            $attachmentFiles | ForEach-Object { New-GraphFileAttachment -Path $_.FullName }
        )
    }

    $payload = @{
        message         = $message
        saveToSentItems = $false
    }

    $encodedUserId = [System.Uri]::EscapeDataString($SendUserId)
    $requestBody = $payload | ConvertTo-Json -Depth 10

    if (-not [string]::IsNullOrWhiteSpace($GraphAccessToken)) {
        $restParams = @{
            Method      = 'Post'
            Uri         = "https://graph.microsoft.com/v1.0/users/$encodedUserId/sendMail"
            Headers     = @{ Authorization = "Bearer $GraphAccessToken" }
            Body        = $requestBody
            ContentType = 'application/json'
        }
        $sendRequest = { Invoke-RestMethod @restParams }
    }

    elseif (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue) {
        if (-not (Get-MgContext)) {
            Connect-AutomationGraph
        }

        $graphRequestParams = @{
            Method      = 'POST'
            Uri         = "/v1.0/users/$encodedUserId/sendMail"
            Body        = $requestBody
            ContentType = 'application/json'
        }
        # The SDK would otherwise retry 504s on its own and resend the message.
        $sendRequest = { Invoke-GraphRequestWithoutSdkRetry -Parameters $graphRequestParams }
    }

    else {
        throw (
            'No Graph auth method available. Provide -GraphAccessToken or install/connect ' +
            'the Microsoft Graph PowerShell SDK.'
        )
    }

    # Everything above fails before a request is sent. From here on, a failure
    # may come after Graph accepted the message.
    try {
        Invoke-WithBoundedRetry -ScriptBlock $sendRequest -RetryableStatusCode $script:GraphSendRetryableStatusCodes
    }
    catch {
        if (Test-GraphSendRefused -ErrorRecord $_) {
            throw
        }

        $unknownDelivery = [System.InvalidOperationException]::new(
            "Graph did not confirm whether the message was sent, so it may have been delivered. " +
            "Check the sender's message trace before resending. Graph error: $($_.Exception.Message)",
            $_.Exception
        )
        $unknownDelivery.Data['KeelDeliveryState'] = 'Unknown'
        throw [System.Management.Automation.ErrorRecord]::new(
            $unknownDelivery,
            'GraphDeliveryUnknown',
            [System.Management.Automation.ErrorCategory]::OperationTimeout,
            $SendUserId
        )
    }
}

function Test-SendMailMessageReplyTo {
    <#
    .SYNOPSIS
    Reports whether Send-MailMessage supports -ReplyTo in this PowerShell.

    .DESCRIPTION
    PowerShell 7's Send-MailMessage has a -ReplyTo parameter. Windows
    PowerShell 5.1's does not.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    (Get-Command Send-MailMessage).Parameters.ContainsKey('ReplyTo')
}

function Send-SmtpEmail {
    <#
    .SYNOPSIS
    Sends an email through SMTP.

    .DESCRIPTION
    Delivers an email message using SMTP via the Send-MailMessage cmdlet.

    Windows PowerShell 5.1's Send-MailMessage cannot set a Reply-To header.
    There, ReplyTo is left out of the message and a warning is written, so
    the message is still delivered.

    .PARAMETER SmtpServer
    The SMTP server address.

    .PARAMETER Subject
    The email subject line.

    .PARAMETER To
    Recipient email address or addresses.

    .PARAMETER Cc
    Carbon copy recipient address or addresses.

    .PARAMETER Bcc
    Blind carbon copy recipient address or addresses.

    .PARAMETER ReplyTo
    Reply-To email address or addresses.

    .PARAMETER From
    The sender email address.

    .PARAMETER Body
    The email body content.

    .PARAMETER AttachmentPath
    Optional path or paths to attachment files.

    .PARAMETER BodyAsHtml
    Indicates whether the body should be treated as HTML.

    .EXAMPLE
    Send-SmtpEmail -SmtpServer 'smtp.contoso.com' -Subject 'Alert' -To 'admin@contoso.com' -From 'alerts@contoso.com' -Body 'Test message'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$SmtpServer,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string[]]$To,

        [string[]]$Cc,

        [string[]]$Bcc,

        [string[]]$ReplyTo,

        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string]$Body,

        [string[]]$AttachmentPath,

        [switch]$BodyAsHtml
    )

    $mailParams = @{
        SmtpServer = $SmtpServer
        Subject    = $Subject
        To         = $To
        From       = $From
        Body       = $Body
    }

    Write-Verbose "Send-SmtpEmail: Sending via SMTP, SmtpServer=$SmtpServer, Recipients=$($To.Count)"

    if ($BodyAsHtml) {
        $mailParams['BodyAsHtml'] = $true
    }

    if ($Cc -and $Cc.Count -gt 0) {
        $mailParams['Cc'] = $Cc
    }

    if ($Bcc -and $Bcc.Count -gt 0) {
        $mailParams['Bcc'] = $Bcc
    }

    if ($ReplyTo -and $ReplyTo.Count -gt 0) {
        if (Test-SendMailMessageReplyTo) {
            $mailParams['ReplyTo'] = $ReplyTo
        }
        else {
            Write-Warning (
                "Send-MailMessage in PowerShell $($PSVersionTable.PSVersion) can't set Reply-To. " +
                "Sending without Reply-To ($($ReplyTo -join ', ')). Use Graph delivery or PowerShell 7 to keep it."
            )
        }
    }

    $attachments = @(
        $AttachmentPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { Resolve-AttachmentFilePath -Path $_ }
    )
    if ($attachments.Count -gt 0) {
        $mailParams['Attachments'] = $attachments
    }

    Send-MailMessage @mailParams
}

function Invoke-Delivery {
    <#
    .SYNOPSIS
    Routes and delivers emails.

    .DESCRIPTION
    Handles the delivery of emails, routing to either Graph
    or SMTP based on the specified method. Supports SMTP fallback when enabled.

    .PARAMETER DeliveryMethod
    The transport method: 'Graph' or 'Smtp'.

    .PARAMETER SmtpServer
    The SMTP server address (required for SMTP delivery or fallback).

    .PARAMETER Subject
    The email subject line.

    .PARAMETER To
    Recipient email address or addresses.

    .PARAMETER Cc
    Carbon copy recipient address or addresses.

    .PARAMETER Bcc
    Blind carbon copy recipient address or addresses.

    .PARAMETER ReplyTo
    Reply-to email addresses.

    .PARAMETER From
    The sender email address.

    .PARAMETER Body
    The email body content.

    .PARAMETER AttachmentPath
    Optional path or paths to attachment files.

    .PARAMETER BodyAsHtml
    Indicates whether the body should be treated as HTML.

    .PARAMETER GraphSenderUserId
    The Graph user ID for sending (Graph delivery only).

    .PARAMETER GraphAccessToken
    Optional OAuth access token for Graph authentication.

    .PARAMETER AllowSmtpFallback
    Allows falling back to SMTP when Graph delivery fails in a way that proves
    the message was not sent. When Graph may have accepted the message, the
    error is rethrown instead, to avoid a duplicate.

    .EXAMPLE
    Invoke-Delivery -DeliveryMethod Graph -Subject 'Alert' -To 'admin@contoso.com' -From 'alerts@contoso.com' -Body 'Test message.' -AllowSmtpFallback
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Graph', 'Smtp')]
        $DeliveryMethod,

        [string]$SmtpServer,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string[]]$To,

        [string[]]$Cc,

        [string[]]$Bcc,

        [string[]]$ReplyTo,

        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string]$Body,

        [string[]]$AttachmentPath,

        [switch]$BodyAsHtml,

        [string]$GraphSenderUserId,

        [string]$GraphAccessToken,

        [switch]$AllowSmtpFallback
    )

    $smtpSendParams = @{
        SmtpServer     = $SmtpServer
        Subject        = $Subject
        To             = $To
        Cc             = $Cc
        Bcc            = $Bcc
        ReplyTo        = $ReplyTo
        From           = $From
        Body           = $Body
        AttachmentPath = $AttachmentPath
        BodyAsHtml     = $BodyAsHtml
    }

    Write-Debug "Invoke-Delivery: DeliveryMethod=$DeliveryMethod, Recipients=$($To.Count)"

    if ($DeliveryMethod -eq 'Smtp') {
        if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
            throw 'SmtpServer is required when DeliveryMethod is Smtp.'
        }

        Write-Verbose "Invoke-Delivery: Routing to SMTP delivery"
        Send-SmtpEmail @smtpSendParams
    }
    else {
        Write-Verbose "Invoke-Delivery: Routing to Graph delivery"
        try {
            $graphSendParams = @{
                SendUserId       = $GraphSenderUserId
                Subject          = $Subject
                To               = $To
                Cc               = $Cc
                Bcc              = $Bcc
                ReplyTo          = $ReplyTo
                Body             = $Body
                AttachmentPath   = $AttachmentPath
                BodyAsHtml       = $BodyAsHtml
                GraphAccessToken = $GraphAccessToken
            }

            Send-GraphEmail @graphSendParams
        }
        catch {
            if (-not $AllowSmtpFallback) {
                throw
            }

            # Graph may already have delivered the message. Sending it again through
            # SMTP could deliver a duplicate, so fallback is only for failures that
            # prove Graph did not accept it.
            if ($_.Exception.Data['KeelDeliveryState'] -eq 'Unknown') {
                Write-Warning 'Graph delivery state is unknown. Not falling back to SMTP, to avoid sending a duplicate.'
                throw
            }

            if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
                $graphError = $_.Exception.Message
                throw (
                    'Graph send failed and SMTP fallback is enabled, but SmtpServer was not provided. ' +
                    "Graph error: $graphError"
                )
            }

            Write-Warning "Graph send failed. Falling back to SMTP. Graph error: $($_.Exception.Message)"
            Write-Verbose "Invoke-Delivery: Falling back to SMTP delivery"
            Send-SmtpEmail @smtpSendParams
        }
    }
}

function Send-Email {
    <#
    .SYNOPSIS
    Sends email through Microsoft Graph or SMTP.

    .DESCRIPTION
    Sends email for automation workflows.
    Microsoft Graph is the default delivery method. SMTP can be used explicitly,
    or as a fallback when Graph delivery fails and fallback is enabled.

    This function also supports environment-driven defaults so scheduled tasks
    and other unattended jobs can be configured without changing caller code.

    .PARAMETER SmtpServer
    The SMTP server or relay to use when DeliveryMethod is Smtp, or when SMTP
    fallback is enabled.

    .PARAMETER Subject
    The email subject line.

    .PARAMETER To
    One or more primary recipients.

    .PARAMETER Cc
    One or more carbon copy recipients.

    .PARAMETER Bcc
    One or more blind carbon copy recipients.

    .PARAMETER ReplyTo
    One or more reply-to addresses.

    .PARAMETER From
    The sender address. When GraphSenderUserId is not provided, this value is
    also used as the Graph sender identity.

    .PARAMETER Body
    The message body.

    .PARAMETER AttachmentPath
    Optional path or paths to file attachments. When Graph is used, the files
    are sent as Microsoft Graph file attachments and their combined size must
    not exceed 3 MB. With SMTP fallback enabled, an oversized Graph send falls
    back to SMTP.

    .PARAMETER BodyAsHtml
    Indicates that the body content should be treated as HTML.

    .PARAMETER DeliveryMethod
    The transport to use. Supported values are Graph and Smtp. Defaults to
    Graph unless overridden by KEEL_MAIL_DELIVERY_METHOD.

    .PARAMETER GraphSenderUserId
    Optional Graph sender mailbox identity. If omitted, the From value is used.

    .PARAMETER GraphAccessToken
    Optional OAuth token for direct Graph REST calls. If omitted, the
    function will attempt to use an existing Graph SDK session or connect using
    app-only environment configuration.

    .PARAMETER AllowSmtpFallback
    If specified, allows the function to fall back to SMTP when Graph delivery
    fails and the failure proves Graph did not accept the message: a 4xx or 503
    response, a connection failure before the request was sent, or a problem
    found before sending, such as an oversized attachment. When Graph may have
    accepted the message, such as after a 500, 502, or 504 or a timeout, no
    fallback is attempted and the error is rethrown.

    .NOTES
    Supported environment variables:
    KEEL_MAIL_DELIVERY_METHOD
    KEEL_GRAPH_SENDER_USER_ID
    KEEL_GRAPH_ACCESS_TOKEN
    KEEL_MAIL_ALLOW_SMTP_FALLBACK
    KEEL_MAIL_CC
    KEEL_MAIL_REPLY_TO
    KEEL_SMTP_SERVER
    KEEL_SMTP_RELAY
    KEEL_GRAPH_TENANT_ID
    KEEL_GRAPH_CLIENT_ID
    KEEL_GRAPH_CERTIFICATE_THUMBPRINT
    KEEL_GRAPH_CLIENT_SECRET
    KEEL_GRAPH_AUTH_MODE

    For unattended Graph SDK authentication, the scheduled-task host can set
    KEEL_GRAPH_TENANT_ID, KEEL_GRAPH_CLIENT_ID, and
    KEEL_GRAPH_CERTIFICATE_THUMBPRINT for certificate-based auth, or
    KEEL_GRAPH_TENANT_ID, KEEL_GRAPH_CLIENT_ID, and KEEL_GRAPH_CLIENT_SECRET
    for client-secret-based auth. This mode will use Auto mode by default
    or respect the KEEL_GRAPH_AUTH_MODE setting.

    .EXAMPLE
    $mail = @{
        Subject = 'Automation Failed'
        To      = 'alerts@contoso.com'
        From    = 'alerts@contoso.com'
        Body    = '<p>Failure details</p>'
    }
    Send-Email @mail -BodyAsHtml

    Sends mail using the default Graph configuration available in the current
    environment.

    .EXAMPLE
    $mail = @{
        DeliveryMethod = 'Smtp'
        SmtpServer     = 'smtp.contoso.com'
        Subject        = 'Automation Failed'
        To             = 'alerts@contoso.com'
        From           = 'alerts@contoso.com'
        Body           = 'Failure details'
    }
    Send-Email @mail

    Sends mail directly through SMTP.

    .EXAMPLE
    $mail = @{
        SmtpServer = 'smtp.contoso.com'
        Subject    = 'Automation Failed'
        To         = 'alerts@contoso.com'
        Cc         = 'management@contoso.com'
        From       = 'alerts@contoso.com'
        Body       = 'Failure details'
    }
    Send-Email @mail -AllowSmtpFallback

    Attempts Graph delivery first and falls back to SMTP if Graph delivery
    fails, with a carbon copy recipient.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$SmtpServer,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$To,

        [string[]]$Cc,

        [string[]]$Bcc,

        [string[]]$ReplyTo,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$From,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Body,

        [string[]]$AttachmentPath,

        [switch]$BodyAsHtml,

        [ValidateSet('Graph', 'Smtp')]
        [string]$DeliveryMethod = 'Graph',

        [string]$GraphSenderUserId,

        [string]$GraphAccessToken,

        [switch]$AllowSmtpFallback
    )

    if ([string]::IsNullOrWhiteSpace($Subject)) {
        throw 'Subject cannot be null, empty, or whitespace.'
    }

    $normalizedTo = Convert-EmailAddress -AddressList $To

    if ($normalizedTo.Count -eq 0) {
        throw 'To must include at least one non-empty recipient address.'
    }

    # Parse and validate Cc with environment defaults
    if ($PSBoundParameters.ContainsKey('Cc')) {
        $normalizedCc = Convert-EmailAddress -AddressList $Cc
    }
    else {
        $ccFromEnv = $env:KEEL_MAIL_CC
        if (-not [string]::IsNullOrWhiteSpace($ccFromEnv)) {
            # Parse comma/semicolon-delimited values
            $ccAddresses = $ccFromEnv -split '[,;]' | ForEach-Object { $_.Trim() }
            $normalizedCc = Convert-EmailAddress -AddressList $ccAddresses
            Write-Debug "Send-Email: Using CC from environment, resolved $($normalizedCc.Count) addresses"
        }
        else {
            $normalizedCc = @()
        }
    }

    # Validate Cc
    if ($normalizedCc.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ccFromEnv)) {
        throw 'Cc must include at least one non-empty recipient address.'
    }

    # Parse and validate ReplyTo with environment defaults
    if ($PSBoundParameters.ContainsKey('ReplyTo')) {
        $normalizedReplyTo = Convert-EmailAddress -AddressList $ReplyTo
    }
    else {
        $replyToFromEnv = $env:KEEL_MAIL_REPLY_TO
        if (-not [string]::IsNullOrWhiteSpace($replyToFromEnv)) {
            # Parse comma/semicolon-delimited values
            $replyToAddresses = $replyToFromEnv -split '[,;]' | ForEach-Object { $_.Trim() }
            $normalizedReplyTo = Convert-EmailAddress -AddressList $replyToAddresses
            Write-Debug "Send-Email: Using ReplyTo from environment, resolved $($normalizedReplyTo.Count) addresses"
        }
        else {
            $normalizedReplyTo = @()
        }
    }

    # Validate ReplyTo
    if ($normalizedReplyTo.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($replyToFromEnv)) {
        throw 'ReplyTo must include at least one non-empty recipient address.'
    }

    $normalizedBcc = Convert-EmailAddress -AddressList $Bcc

    $normalizedFrom = $From.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedFrom)) {
        throw 'From cannot be null, empty, or whitespace.'
    }

    if ([string]::IsNullOrWhiteSpace($Body)) {
        throw 'Body cannot be null, empty, or whitespace.'
    }

    if (
        -not $PSBoundParameters.ContainsKey('DeliveryMethod') -and
        -not [string]::IsNullOrWhiteSpace($env:KEEL_MAIL_DELIVERY_METHOD)
    ) {
        $deliveryMethodFromEnv = $env:KEEL_MAIL_DELIVERY_METHOD.Trim()
        if ($deliveryMethodFromEnv -in @('Graph', 'Smtp')) {
            $DeliveryMethod = $deliveryMethodFromEnv
            Write-Debug "Send-Email: Using delivery method from environment: $DeliveryMethod"
        }
        else {
            Write-Warning "Ignoring KEEL_MAIL_DELIVERY_METHOD value '$deliveryMethodFromEnv'. Expected Graph or Smtp. Using $DeliveryMethod."
        }
    }

    if (
        -not $PSBoundParameters.ContainsKey('GraphSenderUserId') -and
        -not [string]::IsNullOrWhiteSpace($env:KEEL_GRAPH_SENDER_USER_ID)
    ) {
        $GraphSenderUserId = $env:KEEL_GRAPH_SENDER_USER_ID
        Write-Debug "Send-Email: Using Graph sender from environment"
    }

    if (
        -not $PSBoundParameters.ContainsKey('GraphAccessToken') -and
        -not [string]::IsNullOrWhiteSpace($env:KEEL_GRAPH_ACCESS_TOKEN)
    ) {
        $GraphAccessToken = $env:KEEL_GRAPH_ACCESS_TOKEN
        Write-Debug "Send-Email: Using Graph access token from environment"
    }

    if (-not $PSBoundParameters.ContainsKey('AllowSmtpFallback')) {
        $fallbackFromEnv = $env:KEEL_MAIL_ALLOW_SMTP_FALLBACK
        if (
            -not [string]::IsNullOrWhiteSpace($fallbackFromEnv) -and
            $fallbackFromEnv.Trim() -notmatch '^(1|true|yes|y|on|0|false|no|n|off)$'
        ) {
            Write-Warning "Ignoring KEEL_MAIL_ALLOW_SMTP_FALLBACK value '$($fallbackFromEnv.Trim())'. Expected true or false. SMTP fallback stays disabled."
        }

        $AllowSmtpFallback = ConvertTo-BooleanValue -Value $fallbackFromEnv -Default $false
        Write-Debug "Send-Email: AllowSmtpFallback from environment: $AllowSmtpFallback"
    }

    if ([string]::IsNullOrWhiteSpace($SmtpServer) -and -not [string]::IsNullOrWhiteSpace($env:KEEL_SMTP_SERVER)) {
        $SmtpServer = $env:KEEL_SMTP_SERVER
        Write-Debug "Send-Email: Using SMTP server from KEEL_SMTP_SERVER"
    }

    if ([string]::IsNullOrWhiteSpace($SmtpServer) -and -not [string]::IsNullOrWhiteSpace($env:KEEL_SMTP_RELAY)) {
        $SmtpServer = $env:KEEL_SMTP_RELAY
        Write-Debug "Send-Email: Using SMTP server from KEEL_SMTP_RELAY"
    }

    if (-not [string]::IsNullOrWhiteSpace($SmtpServer)) {
        $SmtpServer = $SmtpServer.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($GraphSenderUserId)) {
        $GraphSenderUserId = $GraphSenderUserId.Trim()
    }

    $resolvedGraphSender = if ([string]::IsNullOrWhiteSpace($GraphSenderUserId)) {
        $normalizedFrom
    }
    else {
        $GraphSenderUserId
    }

    # Build target recipients string for ShouldProcess
    $targetRecipientsList = @()
    $targetRecipientsList += $normalizedTo
    if ($normalizedCc.Count -gt 0) {
        $targetRecipientsList += $normalizedCc
    }
    if ($normalizedBcc.Count -gt 0) {
        $targetRecipientsList += $normalizedBcc
    }

    $targetRecipientsList = $targetRecipientsList -join ', '
    if ([string]::IsNullOrWhiteSpace($targetRecipientsList)) {
        $targetRecipientsList = '(no recipients resolved)'
    }

    $transportLabel = if ($DeliveryMethod -eq 'Smtp') { 'SMTP'}
    elseif ($AllowSmtpFallback) { 'Graph with SMTP fallback'}
    else { 'Graph'}
    $actionDescription = "Send email via $transportLabel to $(@($normalizedTo).Count + @($normalizedCc).Count + @($normalizedBcc).Count) recipient(s)"

    if ($PSCmdlet.ShouldProcess($targetRecipientsList, $actionDescription)) {
        $deliveryParams = @{
            DeliveryMethod = $DeliveryMethod
            SmtpServer = $SmtpServer
            Subject = $Subject
            To = $normalizedTo
            Cc = $normalizedCc
            Bcc = $normalizedBcc
            ReplyTo = $normalizedReplyTo
            From = $normalizedFrom
            Body = $Body
            AttachmentPath = $AttachmentPath
            BodyAsHtml = $BodyAsHtml
            GraphSenderUserId = $resolvedGraphSender
            GraphAccessToken = $GraphAccessToken
            AllowSmtpFallback = $AllowSmtpFallback
        }

        Invoke-Delivery @deliveryParams
    }
}

Export-ModuleMember -Function Send-Email