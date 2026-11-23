# Changelog

Notable changes to keel. Both modules share a version (see the README). Releases before this file existed are described in [GitHub Releases](https://github.com/jackson-asmith/keel/releases).

## 1.2.0 (2026-11-23)

### Changed

- **Only listed statuses count as a Graph refusal.** Before, `Send-Email` treated any 4xx response from `sendMail` as proof Graph refused the message, so it was safe to resend and `-AllowSmtpFallback` applied. Now only 400, 401, 403, 404, 413, 415, 429, and 503 count. Any other status, including 408 Request Timeout, is treated as possibly delivered: `Send-Email` throws `GraphDeliveryUnknown` and doesn't fall back to SMTP. A proxy or gateway can send a 408 after the request was forwarded, and other statuses have no defined meaning for `sendMail`, so resending after them could deliver a duplicate. See the amendment to [ADR 0002](docs/adr/0002-no-resend-after-ambiguous-graph-failure.md).

  If you use `-AllowSmtpFallback`, a message that failed with one of these statuses used to arrive through SMTP and now fails instead. Check message trace before resending it.

keel.Http has no changes; it's at 1.2.0 because both modules share a version.
