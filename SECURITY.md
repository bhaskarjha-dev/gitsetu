# Security Policy

## Supported Versions

The v1.1.0 line is a **verified release candidate and is not yet a public release**. Local candidate artifacts have been built and checked, but the canonical release metadata remains non-public until an intentional release process creates a clean tag, signed artifacts, and published provenance. The latest official release remains the release documented by its published tag.

“Release candidate” describes the verified local channel, not a public production claim: the current tree has passed the local regression, adversarial, packaging, and platform gates, but it is not a public production artifact until an intentional release process publishes and signs it.

| Version/channel | Security handling |
| --------------- | ----------------- |
| v1.1.x development branch | Tracked and tested on the development branch; not a published release |
| Latest official release | Supported according to the maintainers' release policy |
| Older development snapshots | Not supported |

Do not treat a local development version, mutable branch URL, or unreleased manifest as a release trust root.

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
