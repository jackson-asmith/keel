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

- The SDK's request context is process-wide, shared by every runspace. Without coordination, two overlapping sends can undo each other: one restores SDK retries while the other's request is going out, which lets the SDK resend it, and the last to finish restores the other's `MaxRetry` of 0. So sends take a process-wide lock, stored in AppDomain data because module variables aren't shared between runspaces, around saving, changing, and restoring the settings. Sends in the same process therefore run one at a time through the SDK. A send that waits more than 5 minutes for the lock fails as `NotSent`.
- While a `sendMail` request is in flight, other Graph calls running in parallel in the same process also run without SDK retries.
- `keel.Mail.Sdk.Tests.ps1` runs the real SDK against a local stub to guard this. It needs `Microsoft.Graph.Authentication` and permission to listen on port 80, because `Invoke-MgGraphRequest` drops custom ports from relative URIs. It skips itself when either is missing.

## Amendment: an explicit list of refusal statuses (2026-11-23)

### Context

The original decision treated **any** 4xx response as proof that Graph refused the message. An external review of the project pointed out that this claims something about every 4xx status, including ones added later, and that some don't support it. 408 Request Timeout is the clearest case: a proxy or gateway in front of Graph can send it after the request was forwarded, so the message may have been accepted. Statuses like 409 or 423 have no defined meaning for `sendMail` at all.

The [`sendMail` reference](https://learn.microsoft.com/en-us/graph/api/user-sendmail) documents only `202 Accepted` and a `400` for invalid MIME content. The other statuses Keel sees in practice (authorization, a missing mailbox, an oversized or wrongly typed body, throttling, an unavailable service) come from Graph's general error behavior and HTTP's definitions, not from anything `sendMail`-specific.

The original text also called a 503 proof that Graph "did not process the request". HTTP defines 429 and 503 as statuses the server sends without acting on the request, and Graph follows that, but a client can't verify it. That's a convention, not proof.

### Decision

- `Test-GraphSendRefused` treats a status as a refusal only if it is on an explicit list: **400, 401, 403, 404, 413, 415, 429, and 503**. Every other status, including 408, is classified as possibly delivered and raises `GraphDeliveryUnknown`.
  - 400, 401, 403, 404, 413, and 415 reject the request before a message exists: it's malformed, unauthorized, aimed at a mailbox that doesn't exist, too large, or the wrong content type.
  - 429 and 503 are refusals by HTTP convention, as above. They stay on the list, because throttling and outages are the main reason SMTP fallback exists.
- Adding a status to the list needs a reason it can't follow acceptance for `sendMail`, and a Pester test.
- The retry list (429 and 503) is unchanged.

### Consequences

- A `sendMail` failure with 405, 408, 409, 410, 411, 412, 422, 423, or any other unlisted 4xx no longer falls back to SMTP and is no longer reported as refused. It fails with `GraphDeliveryUnknown`, so the operator checks message trace before resending. This is a behavior change for callers using `-AllowSmtpFallback`: for those statuses a message that used to arrive through SMTP now fails instead. None of these statuses are documented for `sendMail`, so we expect this to be rare, and it errs toward the visible failure this ADR already prefers to a duplicate.
- A new status Graph starts returning defaults to Unknown until someone looks at it, instead of to "refused".
- The docs now describe 429 and 503 as refusal signals Graph follows by convention, not proof.
