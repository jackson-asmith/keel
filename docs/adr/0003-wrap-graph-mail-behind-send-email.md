# 3. Wrap Graph mail behind Send-Email instead of calling the SDK directly

- **Status:** Accepted
- **Date:** 2026-10-14
- **Modules:** keel.Mail

## Context

`Send-MailMessage` is obsolete, and Microsoft has been retiring Basic authentication for SMTP AUTH in Exchange Online, so scripts that send through `smtp.office365.com` with a username and password stop working. Microsoft's recommended replacement is the Graph `sendMail` API with app-only authentication, which the Microsoft Graph PowerShell SDK exposes as `Send-MgUserMail`.

For a single script, calling `Send-MgUserMail` directly is a handful of lines. For a fleet of scheduled scripts, each call site would also have to handle:

- **Authentication:** app-only sign-in with a certificate or client secret, and what to do when no session exists.
- **Message shaping:** `Send-MgUserMail` takes a nested `-BodyParameter` structure with recipient objects and base64-encoded attachments, not `Send-MailMessage`'s flat parameters. Graph also limits inline attachments to about 3 MB per request.
- **Failure policy:** throttling, retries, and duplicates. `sendMail` is not idempotent, and the SDK's own retry handler resends it after errors where Graph may already have delivered the message (see [ADR 0002](0002-no-resend-after-ambiguous-graph-failure.md)).

Repeated across many scripts, each of these would be written slightly differently, and a fix to one copy would not reach the others.

## Decision

**keel.Mail provides one command, `Send-Email`, with `Send-MailMessage`-style parameters. Scripts call `Send-Email` and never call the Graph SDK or REST API for mail themselves.**

`Send-Email` owns everything between "send this message" and the transport:

- Authentication: an access token, an existing SDK session, or app-only sign-in from host configuration ([ADR 0001](0001-environment-variable-configuration.md)).
- Message shaping: recipients, HTML or text bodies, attachments, and the attachment size limit, checked before anything is sent.
- Failure policy: which errors are retried, which fall back to SMTP, and which stop because delivery is uncertain ([ADR 0002](0002-no-resend-after-ambiguous-graph-failure.md)).
- Transport: Graph by default, SMTP when asked for, and SMTP fallback only when the failure proves Graph did not accept the message.

## Alternatives considered

- **Call `Send-MgUserMail` directly in each script.** No library to maintain, and full access to every Graph mail feature. But authentication, payload shaping, and failure handling are duplicated at every call site, and fixes such as turning off the SDK's retries for `sendMail` have to be found and applied everywhere.
- **Share a snippet that scripts copy.** Less code to write per script than calling Graph directly, but copies drift as soon as they are pasted, and fixes still don't reach existing copies.
- **Keep `Send-MailMessage` and point it at a relay that doesn't need Basic auth.** Works for now, but keeps every script on an obsolete cmdlet with no path to modern authentication.

## Consequences

- keel is a library to maintain, and its bugs reach every caller. For example, CI found that Windows PowerShell 5.1's `Send-MailMessage` can't set Reply-To, which would have broken every SMTP send with Reply-To on 5.1. The test suite and CI matrix exist because of this.
- Fixes and policy changes reach every caller by updating one module, without editing the scripts.
- Scripts depend on `Send-Email`'s parameters, not on Graph SDK commands, so SDK changes are absorbed inside keel.
- Callers can use only what `Send-Email` exposes. Graph features it doesn't offer, such as message importance or saving to Sent Items, need a change to keel or a direct Graph call.
- Not every script needs keel. When only a few scripts send mail, or a script already uses the Graph SDK for other work, calling `Send-MgUserMail` directly is simpler.
