# Security policy

## Reporting privately

Do not open a public issue containing API keys, access tokens, cookies,
passwords, private keys, session exports, raw Tool arguments, raw Tool results,
or local workspace contents.

For a suspected vulnerability, use a private GitHub Security Advisory for
[`shine-233/dsh-plugin-debug`](https://github.com/shine-233/dsh-plugin-debug/security/advisories/new).
If that form is unavailable, contact the maintainer account
[`@shine-233`](https://github.com/shine-233) privately and provide only a
minimal sanitized reproduction. Do not attach a full Profile, `.env`, session
database, or unredacted diagnostic bundle.

The maintainer aims to acknowledge a report within 7 calendar days and will
publish a fix or a status update when the issue is confirmed. Do not expect a
guaranteed SLA for unsupported preview versions or for vulnerabilities in the
upstream DSH runtime; those should also be reported to the upstream project.

## Supported versions

Only the latest published release and the current `main` security fixes are
actively maintained. A local candidate or an old GitHub source snapshot may
not contain security fixes. The package is currently distributed as a GitHub
source release rather than an npm registry package.

Diagnostic reports must remain metadata-only and must not include credentials,
raw prompts, raw Tool arguments/results, cookies, or full local paths.
