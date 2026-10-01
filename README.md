# keel

[![CI](https://github.com/jackson-asmith/keel/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jackson-asmith/keel/actions/workflows/ci.yml)

PowerShell modules for unattended automation: Graph-first email delivery and bounded retries for HTTP requests.

| Module | Purpose |
|---|---|
| [`keel.Mail`](Modules/keel.Mail) | Sends email through Microsoft Graph by default, with explicit SMTP delivery or automatic SMTP fallback when needed. |
| [`keel.Http`](Modules/keel.Http) | Vendor-neutral retry helpers for REST calls. Exponential backoff with jitter, `Retry-After` support, and status-code detection across PowerShell versions. |

`keel.Mail` depends on `keel.Http`. You can use `keel.Http` on its own with any REST API that uses standard HTTP status codes for throttling and transient errors.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- For Graph delivery, one of:
  - An OAuth access token for Microsoft Graph, or
  - The [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/installation) (`Microsoft.Graph.Authentication`) with an existing session or app-only credentials
- For Graph delivery, the app registration needs the `Mail.Send` application permission. Consider scoping it with an [Exchange Online application access policy](https://learn.microsoft.com/graph/auth-limit-mailbox-access) or RBAC for Applications so it can only send as the mailboxes you intend.
- For SMTP delivery, a reachable SMTP server or relay

## Installation

Clone the repository and put the `Modules` folder on your module path:

```powershell
git clone https://github.com/jackson-asmith/keel.git
$env:PSModulePath = "$PWD/keel/Modules" + [System.IO.Path]::PathSeparator + $env:PSModulePath

Import-Module keel.Mail   # also loads keel.Http
```

To make this permanent, copy `Modules/keel.Http` and `Modules/keel.Mail` into one of the folders listed in `$env:PSModulePath`.

## keel.Mail

The module exports one command, `Send-Email`.

### Send through Graph (default)

```powershell
$mail = @{
    Subject = 'Nightly sync failed'
    To      = 'ops@contoso.com'
    From    = 'automation@contoso.com'
    Body    = '<p>See the attached log for details.</p>'
}
Send-Email @mail -BodyAsHtml -AttachmentPath 'C:\Logs\sync.log', 'C:\Logs\summary.csv'
```

`From` is also used as the Graph sender mailbox unless you pass `-GraphSenderUserId`. Graph messages are not saved to the sender's Sent Items.

`-AttachmentPath` accepts one or more files. For Graph delivery, their combined size must be 3 MB or less, which is the most Graph accepts inline in a single send. Larger sends fail before any request is made, or fall back to SMTP when `-AllowSmtpFallback` is set. SMTP delivery has no module-side size limit, but your mail server may enforce one.

Graph authentication is resolved in this order:

1. `-GraphAccessToken` (or `KEEL_GRAPH_ACCESS_TOKEN`): calls the Graph REST API directly.
2. An existing Microsoft Graph SDK session (`Connect-MgGraph`).
3. App-only sign-in through the SDK, using the `KEEL_GRAPH_*` environment variables below. Certificate auth is preferred when a thumbprint is set. Set `KEEL_GRAPH_AUTH_MODE` to `Certificate` or `ClientSecret` to force one mode.

### Send through SMTP

```powershell
$mail = @{
    DeliveryMethod = 'Smtp'
    SmtpServer     = 'smtp.contoso.com'
    Subject        = 'Nightly sync failed'
    To             = 'ops@contoso.com'
    From           = 'automation@contoso.com'
    Body           = 'See the log for details.'
}
Send-Email @mail
```

### Graph with SMTP fallback

```powershell
$mail = @{
    SmtpServer = 'smtp.contoso.com'
    Subject    = 'Nightly sync failed'
    To         = 'ops@contoso.com'
    Cc         = 'management@contoso.com'
    From       = 'automation@contoso.com'
    Body       = 'See the log for details.'
}
Send-Email @mail -AllowSmtpFallback
```

If Graph refuses the message, a warning with the Graph error is written and the message is sent through SMTP instead.

### Delivery safety

`sendMail` is not safe to repeat: if Graph has already accepted a message, sending it again delivers a duplicate. So `Send-Email` only retries or falls back to SMTP when the failure proves Graph did not accept the message:

| Graph failure | Retried through Graph | SMTP fallback |
|---|---|---|
| 429 or 503 | Yes | Yes, if retries run out |
| Other 4xx (400, 401, 403, 404, 413, ...) | No | Yes |
| Name resolution, connection, TLS, or proxy failure before the request was sent | No | Yes |
| Problem found before sending, such as an attachment over 3 MB | No | Yes |
| 500, 502, or 504, a timeout, or a connection dropped mid-request | No | **No** |

This applies whether `Send-Email` calls Graph directly with an access token or through the Graph PowerShell SDK. The SDK normally retries 429, 503, and 504 on its own, so `keel.Mail` turns the SDK's retries off for each `sendMail` request and restores your settings afterward. Because the SDK's retry settings are process-wide, other Graph calls running in parallel in the same process also skip SDK retries while a message is being sent.

In the last row Graph may already have delivered the message, so `Send-Email` stops with a `GraphDeliveryUnknown` error, and `$_.Exception.Data['KeelDeliveryState']` is `Unknown`. Check the sender's message trace before resending. See [ADR 0002](docs/adr/0002-no-resend-after-ambiguous-graph-failure.md) for the reasoning.

### Recipients

`To`, `Cc`, `Bcc`, and `ReplyTo` are trimmed, and duplicates are removed without regard to case, before sending. `Send-Email` supports `-WhatIf` and `-Confirm`.

On Windows PowerShell 5.1, SMTP delivery can't set a Reply-To header, because 5.1's `Send-MailMessage` has no `-ReplyTo` parameter. The message is sent without it and a warning is written. Graph delivery, and SMTP on PowerShell 7, keep Reply-To.

### Environment variables

Scheduled tasks and other unattended jobs can be configured without changing the calling script. Explicit parameters always take precedence over these variables. For why the module relies on this much environment configuration, see [ADR 0001](docs/adr/0001-environment-variable-configuration.md).

| Variable | Used for |
|---|---|
| `KEEL_MAIL_DELIVERY_METHOD` | Default delivery method, `Graph` or `Smtp` |
| `KEEL_MAIL_ALLOW_SMTP_FALLBACK` | Enables SMTP fallback. Accepts `true`/`false`, `yes`/`no`, `1`/`0`, and `on`/`off` |
| `KEEL_MAIL_CC` | Default Cc recipients, separated by commas or semicolons |
| `KEEL_MAIL_REPLY_TO` | Default Reply-To addresses, separated by commas or semicolons |
| `KEEL_SMTP_SERVER` | SMTP server |
| `KEEL_SMTP_RELAY` | SMTP relay, used when `KEEL_SMTP_SERVER` is not set |
| `KEEL_GRAPH_SENDER_USER_ID` | Graph sender mailbox |
| `KEEL_GRAPH_ACCESS_TOKEN` | Graph access token for direct REST calls |
| `KEEL_GRAPH_TENANT_ID` | Tenant ID for app-only SDK sign-in |
| `KEEL_GRAPH_CLIENT_ID` | Application (client) ID for app-only SDK sign-in |
| `KEEL_GRAPH_CERTIFICATE_THUMBPRINT` | Certificate thumbprint for certificate auth |
| `KEEL_GRAPH_CLIENT_SECRET` | Client secret for client-secret auth |
| `KEEL_GRAPH_AUTH_MODE` | Forces `Certificate` or `ClientSecret` auth. When unset, the mode is chosen automatically |

An unrecognized value in `KEEL_MAIL_DELIVERY_METHOD`, `KEEL_MAIL_ALLOW_SMTP_FALLBACK`, or `KEEL_GRAPH_AUTH_MODE` is ignored with a warning that names the variable and the default used instead. `KEEL_MAIL_CC` or `KEEL_MAIL_REPLY_TO` set to only delimiters is an error.

Prefer certificate auth for unattended jobs. If you use a client secret, keep it out of source control and scripts. Load it from a secret store such as `Microsoft.PowerShell.SecretManagement` or your scheduler's protected variables.

## keel.Http

### Invoke-WithBoundedRetry

Runs a scriptblock and retries it on transient HTTP failures. Non-retryable errors are rethrown immediately, and the last error is rethrown once attempts run out.

Each attempt's output is buffered, and only the output of the successful attempt is returned. If an attempt writes some output and then fails, that output is discarded, so it never appears twice. The trade-off is that output arrives all at once when the call finishes instead of streaming.

```powershell
$issues = Invoke-WithBoundedRetry -ScriptBlock {
    Invoke-RestMethod -Uri $uri -Headers $headers
} -MaxAttempts 5 -BaseDelayMilliseconds 1000
```

| Parameter | Default | Description |
|---|---|---|
| `ScriptBlock` | (required) | The operation to run |
| `MaxAttempts` | `3` | Total attempts, including the first. Must be at least 1 |
| `BaseDelayMilliseconds` | `500` | First backoff delay, 0 or greater. Doubles on each retry, plus 0-250 ms of jitter, capped at 5 seconds |
| `MaxRetryAfterSeconds` | `60` | Longest `Retry-After` wait the function will honor |
| `RetryableStatusCode` | `408, 429, 500, 502, 503, 504` | Status codes to retry. Any other status, or an error with no status, is rethrown immediately |

**Only retry operations that are safe to repeat.** A 500, 502, or 504 can arrive after the server finished the work, so retrying a POST that sends a message or creates a record can do it twice. For those calls, narrow the list to statuses where the server refused the request:

```powershell
Invoke-WithBoundedRetry -ScriptBlock {
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
} -RetryableStatusCode 429, 503
```

**Retry-After:** when a retryable response includes a `Retry-After` header, in either delta-seconds or HTTP-date form, the function waits that long (plus jitter) instead of using the backoff delay. The 5-second cap does not apply. If the server asks for a longer wait than `MaxRetryAfterSeconds`, the error is rethrown right away rather than retrying before the server is ready.

HTTP defines `Retry-After` for 429 and 503, but gateways and some APIs, including Microsoft Graph, also send it with other transient errors. For that reason it is honored on any retryable status. Non-retryable responses fail immediately even if they include the header.

### Get-RetryableStatusCode

Returns the HTTP status code from an error record, or nothing if it can't be determined. Use it for your own retry decisions:

```powershell
try {
    Invoke-RestMethod @request
}
catch {
    $statusCode = $_ | Get-RetryableStatusCode
    if ($statusCode -eq 404) {
        # Handle a missing resource
    }
}
```

The status is read, in order, from:

1. The exception's `Response.StatusCode`, as set by `Invoke-RestMethod`, `Invoke-WebRequest`, and `Invoke-MgGraphRequest`
2. The exception's own `StatusCode` (`HttpRequestException` in .NET 5+)
3. Known status-code phrasings in the error message, such as `Response status code does not indicate success: 503`, `The remote server returned an error: (429)`, `HTTP 502`, or `StatusCode: 504`. Named statuses like `TooManyRequests` are also recognized.

Numbers that aren't presented as a status code are ignored, so a message like `Quota of 500 items exceeded` isn't treated as an HTTP 500.

## Running the tests

`build.ps1` runs the same checks as CI. It saves pinned versions of Pester, PSScriptAnalyzer, and (for integration tests) the Graph SDK into a gitignored `.tools` folder, so nothing is installed into your profile.

```powershell
./build.ps1                        # Lint and unit tests
./build.ps1 -Task Lint             # PSScriptAnalyzer and Test-ModuleManifest only
./build.ps1 -Task Test             # Pester unit tests only
./build.ps1 -Task Integration      # Graph SDK integration tests
```

Each module keeps its tests in its own `Tests` folder. All network calls, SMTP sends, and sleeps are mocked, so the unit tests need no Graph tenant, SMTP server, or network access. If the Microsoft Graph SDK isn't installed, the tests stub the commands they need.

`keel.Mail.Sdk.Tests.ps1` is an integration test for the Graph SDK path. It runs the real `Microsoft.Graph.Authentication` module against a stub Graph endpoint on your machine, so it still needs no tenant and sends no mail. It needs permission to listen on port 80, which macOS allows; Linux and Windows usually need elevation. Run on its own with `Invoke-Pester`, it skips itself when a prerequisite is missing. `./build.ps1 -Task Integration` fails instead, so a skip can't pass silently.

### Linting

PSScriptAnalyzer settings live at the repository root:

- `PSScriptAnalyzerSettings.psd1` applies to module code and `build.ps1`. It includes compatibility rules that flag syntax, commands, and types that Windows PowerShell 5.1 doesn't have.
- `PSScriptAnalyzerSettings.Tests.psd1` applies to tests. It turns off a few rules for patterns test code needs on purpose, such as stub parameters and fake credentials.

Errors and warnings fail the build. To accept a specific finding, suppress it next to the code with `[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]` and a `Justification`, so the exception is reviewed in the pull request that adds it.

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull request and every push to `main`:

| Job | Runs on |
|---|---|
| Lint | Ubuntu, PowerShell 7 |
| Test | Ubuntu, macOS, and Windows on PowerShell 7, plus Windows PowerShell 5.1 |
| Integration | macOS, with the pinned Graph SDK version |

A weekly scheduled run also runs the integration tests against the latest Graph SDK, so SDK behavior changes show up before you upgrade.

## License

[MIT](LICENSE) © 2026 jackson-asmith
