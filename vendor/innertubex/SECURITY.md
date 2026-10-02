# Security Policy

## Supported Versions

Until the first stable release, security fixes are provided on the latest
`0.x` release line only.

## Reporting a Vulnerability

Do not open a public issue for a vulnerability or include live YouTube cookies,
tokens, signed URLs, account identifiers, or captured authenticated traffic in
any report.

Use GitHub private vulnerability reporting:

https://github.com/MetrolistGroup/innertubex/security/advisories/new

Include reproduction steps with synthetic or redacted data, affected versions,
and the expected impact. Maintainers will acknowledge the report through the
private advisory and coordinate disclosure there.

## Scope

Security issues include credential disclosure, authenticated request routing to
untrusted hosts, unbounded parsing of remote data, unsafe player-script
execution boundaries, and bypasses of protocol size limits.

Failures caused solely by upstream changes to undocumented YouTube APIs are
normally compatibility bugs rather than vulnerabilities.
