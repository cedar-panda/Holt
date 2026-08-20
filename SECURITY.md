# Security policy

## Supported versions

Security fixes are applied to the current source branch and the latest
published release. Older releases may not receive separate patches.

## Reporting a vulnerability

Please use GitHub's
[private vulnerability reporting](https://github.com/cedar-panda/Holt/security/advisories/new).
Do not open a public issue for an unpatched vulnerability.

Include the affected version, platform, component, reproduction steps and
impact. Use synthetic test data: do not attach real conversations, memories,
prompts, API keys, screenshots containing private content or full device logs.

Reports are reviewed on a best-effort basis. A maintainer may ask for a minimal
proof of concept, coordinate a fix and credit the reporter if requested. Please
allow time for a fix before public disclosure.

## Security boundaries

Holt is local-first, but remote features send the content needed for a request
to the provider or endpoint selected by the user. Provider retention and data
handling are outside this repository's control. A lost backup password cannot
be recovered by the project.
