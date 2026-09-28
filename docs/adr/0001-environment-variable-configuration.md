# 1. Configure mail delivery through environment variables

- **Status:** Accepted
- **Date:** 2026-09-28
- **Module:** keel.Mail

## Context

`Send-Email` is called from scheduled tasks, runbooks, and other unattended scripts, often many of them on the same host. The settings that decide how mail is sent belong to the host, not to any one script. These include the delivery method, SMTP server, Graph sender, credentials, and default Cc and Reply-To addresses, and they usually change for operational reasons: a new relay, a rotated secret, or a move from SMTP to Graph.

If every script passed these values as parameters, each change would mean editing and redeploying every script. Credentials would also tend to end up in script files.

## Decision

`keel.Mail` reads its defaults from 13 `KEEL_`-prefixed environment variables, listed in the [README](../../README.md#environment-variables). **We accept this much hidden configuration so that operators can change mail routing and credentials for every job on a host in one place, without touching or redeploying the scripts that send mail.**

To keep the hidden configuration manageable:

- Explicit parameters always take precedence over environment variables, so a script can always state exactly what it wants.
- All variables share the `KEEL_` prefix, named for the library that reads them, and are grouped by concern: `KEEL_MAIL_*`, `KEEL_SMTP_*`, and `KEEL_GRAPH_*`. The prefix keeps them from colliding with variables other tools set on the same host.
- Every variable is documented in the README and in `Send-Email`'s help.
- `Send-Email -Debug` reports which values came from the environment.
- No invalid value changes behavior silently. An unrecognized `KEEL_MAIL_DELIVERY_METHOD`, `KEEL_MAIL_ALLOW_SMTP_FALLBACK`, or `KEEL_GRAPH_AUTH_MODE` is ignored with a warning that names the variable and the default used instead. A `KEEL_MAIL_CC` or `KEEL_MAIL_REPLY_TO` that contains no addresses is an error.
- `keel.Http` reads no environment variables. It stays a plain library.

## Alternatives considered

- **Parameters only.** Explicit and easy to reason about, but every routing or credential change becomes a change to every calling script.
- **A configuration file.** Keeps settings visible in one place, but adds a file format, a location convention, and file permissions to manage, and secrets would sit on disk next to the rest of the settings. Environment variables are already how schedulers and CI systems pass protected values to jobs.

## Consequences

- The same call can behave differently on different hosts. When troubleshooting, check the host's environment as well as the script.
- Tests must clear and restore these variables so the test machine's settings can't leak in. The Pester suite does this before every test.
- Adding a new setting means deciding whether it belongs to the host (environment variable) or the caller (parameter only). New variables should meet the same bar: a host-level concern that operators need to change without editing scripts.
