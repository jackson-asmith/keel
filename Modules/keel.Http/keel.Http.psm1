<#
.SYNOPSIS
HTTP retry helpers for REST API calls in automation workflows.

.DESCRIPTION
Provides transport-agnostic retry primitives for REST API calls. Functions in
this module are not specific to any API vendor and can be reused across Graph,
Atlassian, ServiceNow, or any other endpoint that uses standard HTTP throttling
and transient error codes.

The public entry points are Get-RetryableStatusCode and Invoke-WithBoundedRetry.
#>

$script:RetryableStatusCodes = @(408, 429, 500, 502, 503, 504)

# Status-code phrasings emitted by the HTTP stacks this module is used with. Each
# pattern captures the status as a number or an HttpStatusCode name. Bare numbers
# elsewhere in a message are deliberately ignored so text like "quota of 500 items"
# is not mistaken for an HTTP 500.
$script:StatusCodeMessagePatterns = @(
    # PowerShell 7 / HttpClient: "Response status code does not indicate success: 503 (Service Unavailable)."
    # Graph SDK variant:         "Response status code does not indicate success: TooManyRequests (Too Many Requests)."
    'Response status code does not indicate success:\s*(?<code>\d{3}|[A-Za-z]+)\b'
    # Windows PowerShell 5.1 / WebException: "The remote server returned an error: (429) Too Many Requests."
    'The remote server returned an error:\s*\((?<code>\d{3})\)'
    # Generic "HTTP 503", "HTTP/1.1 503", "status code 503", "StatusCode: 503", "status=503"
    '\bHTTP(?:/\d(?:\.\d)?)?\s+(?<code>\d{3})\b'
    '\bstatus\s*code\s*[:=]?\s*(?<code>\d{3})\b'
    '\bstatus\s*[:=]\s*(?<code>\d{3})\b'
)

function ConvertTo-HttpStatusCode {
    # Converts a status value (int, HttpStatusCode, or enum name) to an integer HTTP status code.
    # Returns $null when the value is not a valid 1xx-5xx status.
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $statusCode = $null
    if ($Value -is [System.Net.HttpStatusCode]) {
        $statusCode = [int]$Value
    }
    elseif ("$Value" -match '^\d{3}$') {
        $statusCode = [int]"$Value"
    }
    elseif ("$Value" -match '^[A-Za-z]+$') {
        # Status names such as 'TooManyRequests'; PowerShell enum conversion is case-insensitive.
        try {
            $statusCode = [int][System.Net.HttpStatusCode]"$Value"
        }
        catch {
            $statusCode = $null
        }
    }

    if ($null -ne $statusCode -and $statusCode -ge 100 -and $statusCode -le 599) {
        $statusCode
    }
}

function Get-RetryAfterMilliseconds {
    <#
    .SYNOPSIS
    Reads the Retry-After header from a failed HTTP response.

    .DESCRIPTION
    Returns the server-requested wait, in milliseconds, from a Retry-After
    header on the error's response. Supports both delta-seconds and HTTP-date
    forms, and the response shapes produced by PowerShell 7
    (HttpResponseMessage) and Windows PowerShell 5.1 (HttpWebResponse).
    Returns $null when no usable Retry-After value is present.

    .PARAMETER ErrorRecord
    The error record from a failed HTTP request.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response -or $null -eq $response.Headers) {
        return $null
    }

    $headers = $response.Headers
    $delay = $null

    if ($headers.GetType().FullName -eq 'System.Net.Http.Headers.HttpResponseHeaders') {
        # PowerShell 7: typed header value. Compared by name because the type isn't
        # loaded by default in Windows PowerShell 5.1.
        $retryAfter = $headers.RetryAfter
        if ($null -ne $retryAfter) {
            # PowerShell unwraps Nullable<T>, so Delta and Date are the values themselves.
            if ($null -ne $retryAfter.Delta) {
                $delay = $retryAfter.Delta
            }
            elseif ($null -ne $retryAfter.Date) {
                $delay = $retryAfter.Date - [System.DateTimeOffset]::UtcNow
            }
        }
    }
    else {
        # Windows PowerShell 5.1 WebHeaderCollection, or any dictionary-like header bag.
        $rawValue = $null
        if ($headers -is [System.Collections.IDictionary]) {
            foreach ($key in $headers.Keys) {
                if ("$key" -eq 'Retry-After') {
                    $rawValue = $headers[$key]
                    break
                }
            }
        }
        else {
            $rawValue = $headers['Retry-After']
        }

        $rawValue = "$(@($rawValue)[0])".Trim()
        $seconds = 0
        $date = [System.DateTimeOffset]::MinValue
        if ([int]::TryParse($rawValue, [ref]$seconds)) {
            $delay = [TimeSpan]::FromSeconds($seconds)
        }
        elseif ([System.DateTimeOffset]::TryParse(
                $rawValue,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$date
            )) {
            $delay = $date - [System.DateTimeOffset]::UtcNow
        }
    }

    if ($null -eq $delay) {
        return $null
    }

    $milliseconds = [Math]::Max([double]0, [Math]::Ceiling($delay.TotalMilliseconds))
    Write-Debug "Get-RetryAfterMilliseconds: Server requested a $milliseconds ms wait"
    [long]$milliseconds
}

function Get-RetryableStatusCode {
    <#
    .SYNOPSIS
    Extracts the HTTP status code from an error record for retry evaluation.

    .DESCRIPTION
    Returns the HTTP status code of a failed request so callers can decide
    whether to retry. The status is read, in order, from:

    1. The exception's Response.StatusCode (Invoke-RestMethod, Invoke-WebRequest,
       Invoke-MgGraphRequest).
    2. The exception's own StatusCode (HttpRequestException in .NET 5+).
    3. Well-known status phrasings in the exception message, such as
       "Response status code does not indicate success: 503" or
       "The remote server returned an error: (429)".

    Any status code found is returned, including non-retryable ones such as
    404. Returns nothing when no status code can be determined. The retryable
    codes used by Invoke-WithBoundedRetry are 408, 429, 500, 502, 503, and 504.

    .PARAMETER ErrorRecord
    The error record from a failed HTTP request. Accepts pipeline input.

    .EXAMPLE
    try {
        Invoke-RestMethod @params
    }
    catch {
        $statusCode = Get-RetryableStatusCode -ErrorRecord $_
        if ($statusCode -in @(429, 503)) {
            # Retry logic
        }
    }

    .EXAMPLE
    $_ | Get-RetryableStatusCode
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    process {
        $exception = $ErrorRecord.Exception
        $statusCode = $null

        if ($exception -and $exception.Response) {
            $statusCode = ConvertTo-HttpStatusCode $exception.Response.StatusCode
            if ($null -ne $statusCode) {
                Write-Debug "Get-RetryableStatusCode: Extracted status code $statusCode from exception response"
            }
        }

        if ($null -eq $statusCode -and $exception -and $exception.PSObject.Properties['StatusCode']) {
            $statusCode = ConvertTo-HttpStatusCode $exception.StatusCode
            if ($null -ne $statusCode) {
                Write-Debug "Get-RetryableStatusCode: Extracted status code $statusCode from exception"
            }
        }

        if ($null -eq $statusCode -and $exception) {
            foreach ($pattern in $script:StatusCodeMessagePatterns) {
                if ($exception.Message -match $pattern) {
                    $statusCode = ConvertTo-HttpStatusCode $Matches['code']
                    if ($null -ne $statusCode) {
                        Write-Debug "Get-RetryableStatusCode: Extracted status code $statusCode from exception message"
                        break
                    }
                }
            }
        }

        $statusCode
    }
}

function Invoke-WithBoundedRetry {
    <#
    .SYNOPSIS
    Invokes an operation with exponential backoff retry logic.

    .DESCRIPTION
    Executes a scriptblock with automatic retry on transient HTTP failures.
    Retries only on status codes 408, 429, 500, 502, 503, and 504.

    Between attempts the function waits using exponential backoff with jitter,
    capped at 5 seconds, to avoid thundering-herd retries.

    When a retryable response includes a Retry-After header, the
    server-requested wait is used instead of the backoff delay (plus a small
    jitter). HTTP defines Retry-After for 429 and 503, but gateways and some
    APIs, including Microsoft Graph, also send it with other transient
    responses, so it is honored on any retryable status. If the server asks
    for a longer wait than MaxRetryAfterSeconds, the error is rethrown
    immediately rather than retrying before the server is ready.

    .PARAMETER ScriptBlock
    The scriptblock containing the operation or API request to retry.

    .PARAMETER MaxAttempts
    Maximum number of attempts, including the first. Must be at least 1.
    Defaults to 3.

    .PARAMETER BaseDelayMilliseconds
    The initial delay in milliseconds before the first retry. Must be zero or
    greater. Defaults to 500. Subsequent retries use exponential backoff.

    .PARAMETER MaxRetryAfterSeconds
    The longest Retry-After wait, in seconds, the function will honor.
    Longer requested waits cause the error to be rethrown. Defaults to 60.

    .EXAMPLE
    Invoke-WithBoundedRetry -ScriptBlock { Invoke-RestMethod @params } -MaxAttempts 5 -BaseDelayMilliseconds 1000

    .EXAMPLE
    Invoke-WithBoundedRetry -ScriptBlock { Invoke-MgGraphRequest @request } -MaxRetryAfterSeconds 120

    Honors Graph throttling responses that ask the caller to wait up to two minutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxAttempts = 3,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$BaseDelayMilliseconds = 500,

        [ValidateRange(0, 3600)]
        [int]$MaxRetryAfterSeconds = 60
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Debug "Invoke-WithBoundedRetry: Attempt $attempt of $MaxAttempts"
            & $ScriptBlock
            break
        }
        catch {
            $statusCode = Get-RetryableStatusCode -ErrorRecord $_
            $isRetryable = $statusCode -in $script:RetryableStatusCodes

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                Write-Debug "Invoke-WithBoundedRetry: Non-retryable error or max attempts reached (StatusCode: $statusCode)"
                throw
            }

            $jitterMilliseconds = Get-Random -Minimum 0 -Maximum 250
            $retryAfterMilliseconds = Get-RetryAfterMilliseconds -ErrorRecord $_

            if ($null -ne $retryAfterMilliseconds) {
                if ($retryAfterMilliseconds -gt ($MaxRetryAfterSeconds * 1000)) {
                    Write-Verbose "Invoke-WithBoundedRetry: Server requested a $retryAfterMilliseconds ms wait, which exceeds MaxRetryAfterSeconds ($MaxRetryAfterSeconds). Not retrying."
                    throw
                }

                $delayMilliseconds = $retryAfterMilliseconds + $jitterMilliseconds
                Write-Verbose "Invoke-WithBoundedRetry: Honoring Retry-After, waiting $delayMilliseconds ms (StatusCode: $statusCode, Attempt: $attempt/$MaxAttempts)"
            }
            else {
                $exponentialDelay = $BaseDelayMilliseconds * [Math]::Pow(2, $attempt - 1)
                $delayMilliseconds = [Math]::Min(5000, $exponentialDelay + $jitterMilliseconds)
                Write-Verbose "Invoke-WithBoundedRetry: Retrying after $delayMilliseconds ms (StatusCode: $statusCode, Attempt: $attempt/$MaxAttempts)"
            }

            Start-Sleep -Milliseconds ([int]$delayMilliseconds)
        }
    }
}

Export-ModuleMember -Function Get-RetryableStatusCode, Invoke-WithBoundedRetry
