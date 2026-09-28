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
