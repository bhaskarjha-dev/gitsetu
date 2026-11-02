# Security Policy

## Supported Versions

The v1.1.0 release is distributed via GitHub Releases and npm. Cryptographic release artifacts and provenance are published to the official GitHub repository releases page.

| Version/channel | Security handling |
| --------------- | ----------------- |
| v1.1.0 release | Actively supported |
| Latest official release | Supported according to the maintainers' release policy |
| Older development snapshots | Not supported |

Only install release artifacts downloaded from verified release channels with matching cryptographic signatures.

## Reporting a Vulnerability

Security issues involving identity routing, private keys, credential helpers, vaults, installers, or update provenance should be reported privately. Do not open a public issue containing exploit details or secrets.

Use GitHub Security Advisories for the repository, or contact `security@bhaskarjha.dev`.

Please include:

- affected version/channel and commit;
- operating system, Bash version, Git version, and relevant package manager;
- minimal reproduction steps;
- expected and observed authorization, identity, or confidentiality impact;
- whether a real token or private key was exposed (redact it; never send the secret itself).

Maintainers will acknowledge reports within 48 hours when possible and coordinate disclosure after a verified fix is available.
