# 2. Never resend mail after an ambiguous Graph failure

- **Status:** Accepted
- **Date:** 2026-09-28
- **Modules:** keel.Mail, keel.Http

## Context

`Send-Email` sends through the Graph `sendMail` endpoint, retries transient failures with `Invoke-WithBoundedRetry`, and can fall back to SMTP when Graph fails.

`sendMail` is a POST and is not idempotent. Graph returns no message ID and accepts no idempotency key, so a caller can't safely ask "did that go through?" and resend only if it didn't. Some failures leave the answer unknown. A 504 from a gateway, a 500, or a connection that drops after the request was sent can all happen after Graph has accepted the message.

Originally, `keel.Mail` retried `sendMail` on 408, 429, 500, 502, 503, and 504, and fell back to SMTP on any Graph failure. A single 504 could therefore produce three Graph sends plus one SMTP send, and each of them could reach the recipients.

For an alerting library a duplicate is not harmless: repeated alerts train people to ignore them, and a duplicated notice to an end user looks like a malfunction.

## Decision

**Keel resends a message, through Graph or SMTP, only when the failure proves Graph did not accept it. When delivery is uncertain, it stops and says so.**

- `Invoke-WithBoundedRetry` takes a `RetryableStatusCode` list. The default list is unchanged, but its help and the README tell callers to narrow it for non-idempotent calls.
- `keel.Mail` retries `sendMail` only on 429 and 503, where Graph refused the request.
- `Test-GraphSendRefused` classifies every Graph failure. It treats as refused any 4xx or 503 response, and any connection failure raised before the request was sent (name resolution, connection refused, TLS, proxy tunnel). Everything else, including 500, 502, 504, timeouts, and connections dropped mid-request, is treated as possibly delivered.
- A possibly-delivered failure is rethrown as a `GraphDeliveryUnknown` error with `Exception.Data['KeelDeliveryState'] = 'Unknown'`. `Invoke-Delivery` never falls back to SMTP after that error, even when `-AllowSmtpFallback` is set, and writes a warning explaining why.
- Problems found before any request is sent, such as a missing or oversized attachment or missing credentials, still fall back to SMTP, because nothing reached Graph.

## Alternatives considered

- **Keep retrying all transient statuses.** Best chance of delivery, but duplicates are likely under exactly the conditions (gateway timeouts, overloaded service) where retries happen most.
- **Check Sent Items before resending.** `Send-Email` sets `saveToSentItems` to `false`, and searching a mailbox for a match is slow, needs `Mail.Read`, and is still racy. Rejected as too much permission and complexity for the benefit.
- **Let callers decide.** Exposing the raw error pushes the same hard judgment onto every script. The library is the right place to make it once, and the typed error still lets a caller choose to resend after checking message trace.

## Consequences

- Some messages that would have arrived through a retry or SMTP fallback now fail instead. The job fails loudly, with a message telling the operator to check message trace before resending. We prefer a visible failure to a silent duplicate.
- SMTP fallback now covers outages and misconfiguration (Graph unreachable, credentials rejected, throttling that outlasts the retries) but not ambiguous server errors. The README documents which failures fall back.
- Connection failures are classified from exception details that differ between PowerShell 7 (`HttpRequestError`, .NET 8) and Windows PowerShell 5.1 (`WebExceptionStatus`), with socket errors as a common layer. Anything the classifier doesn't recognize is treated as possibly delivered, so gaps fail safe.
- Output from a failed attempt is no longer returned, because `Invoke-WithBoundedRetry` now buffers each attempt's output and returns only the successful attempt's. Output arrives at the end instead of streaming.

## Amendment: the Graph SDK path (2026-09-29)

### Context

The original decision was only enforced on the direct REST path, where `Send-Email` has an access token and calls `Invoke-RestMethod`. Without a token, `keel.Mail` sends through the Graph PowerShell SDK's `Invoke-MgGraphRequest`. The SDK has its own [retry handler](https://github.com/microsoftgraph/msgraph-sdk-design/blob/main/middleware/RetryHandler.md) that retries 429, 503, and 504, up to `MaxRetry` times (3 by default), including POSTs with a buffered body. The unit tests mock `Invoke-MgGraphRequest`, so they could not see it.

This was found while checking a write-up about this ADR against Microsoft's documentation, confirmed in the SDK and Kiota source, and reproduced against Microsoft.Graph.Authentication 2.40.0 with a local stub endpoint: one `Send-Email` call that got a 504 reached the endpoint **4 times**. The SDK's final error ("HTTP request failed with status code: GatewayTimeout") also used wording `keel.Http` didn't parse, so an exhausted 429 would have been classified as unknown and lost its SMTP fallback.

### Decision

- `keel.Mail` sets the SDK's `MaxRetry` to 0 for each `sendMail` request and restores the caller's settings afterward, so `Invoke-WithBoundedRetry` is the only thing that decides what to retry.
- Failures while reading or changing the SDK settings happen before anything is sent. They are marked `Exception.Data['KeelDeliveryState'] = 'NotSent'`, so SMTP fallback still applies.
- A failure to restore the caller's settings is a warning, not an error, because it doesn't change what happened to the message.
- `keel.Http` also recognizes the SDK's "status code: <Name>" wording, for callers that leave SDK retries on.

Sending through the direct REST path in both modes was rejected: the SDK has no supported way to hand an access token to other code.

### Consequences

- The SDK's request context is process-wide. While a `sendMail` request is in flight, other Graph calls running in parallel in the same process also run without SDK retries.
- `keel.Mail.Sdk.Tests.ps1` runs the real SDK against a local stub to guard this. It needs `Microsoft.Graph.Authentication` and permission to listen on port 80, because `Invoke-MgGraphRequest` drops custom ports from relative URIs. It skips itself when either is missing.
