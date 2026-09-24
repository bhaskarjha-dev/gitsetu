# Enterprise Security & Privacy

GitSetu manages private SSH keys, Git identity configuration, and HTTPS credential routing. It does not include telemetry, analytics, or crash-reporting services. Its source is plain Bash and can be audited before deployment.

## Network boundary

GitSetu does not "phone home." Network access is limited to operations that explicitly perform remote work, including first-use discovery/SSH verification and an optional authenticated GitHub CLI upload requested by the user. The development updater refuses remote branch fetches and hard resets. Dry-run and purely local validation do not perform network requests. Operators who require an offline workflow should disable or avoid explicit network commands and should not install the optional `gh` integration unless it is needed.

## SSH configuration and quoting

Managed OpenSSH rules are written to GitSetu's included configuration file rather than by rewriting unrelated user host blocks. Paths and tokens are quoted for the OpenSSH config parser and for the runtime `ssh` command. Existing user settings remain outside the managed block.

## Atomic writes and locks

State files are prepared in private temporary files and installed with atomic replacement where the platform permits it. A directory lock with an owner token, process liveness checks, and a bounded wait protects normal concurrent GitSetu operations.

The lock is an integrity aid, not a kernel security boundary. A malicious process running as the same user can still modify files or bypass client-side checks; use filesystem permissions, operating-system isolation, and repository review controls where stronger guarantees are required.

## Credential storage

Native credential stores are preferred:

- macOS Keychain (`security`);
- Windows Git Credential Manager / Windows Credential Manager;
- Linux Secret Service (`secret-tool`).

The credential broker namespaces records by profile, host, and path so one profile cannot retrieve another profile's token by accident.

Some minimal or headless Linux installations have no native Secret Service daemon. For those systems, GitSetu supports an **explicit zero-dependency plaintext fallback** at `~/.config/gitsetu/.tokens`. It is not encrypted, is not a compatibility mode, and must be treated as sensitive as the token itself:

- the file is created with mode `0600` and its directory with mode `0700`;
- malformed, symlinked, or incorrectly permissioned files are rejected;
- every operation using the fallback emits a clear warning;
- native/GCM storage remains the default and preferred path.

A plaintext fallback cannot protect a token from malware or another process already running as the same operating-system user. Use a native keychain whenever possible.

## Identity guard policy

The pre-commit guard is installed in the generated hooks directory and preserves an existing project hook when the identity check succeeds.

- A repository outside every managed profile is **unmanaged**: the identity check fails open and the repository's ordinary hooks continue.
- A repository selected by a managed profile is **managed**: an unresolved or divergent identity fails closed.
- If managed state is malformed or cannot be resolved, the guard fails closed rather than guessing.

This is a client-side identity guard, not a replacement for server-side controls, signed commits, or review policy.

## Authenticated vaults

`gitsetu backup` creates a versioned authenticated v2 vault containing managed configuration and referenced keys. The v2 format provides confidentiality and integrity/authentication, uses private staging, validates the complete payload before mutation, and rolls back failed restores. Older unauthenticated/CBC vaults and the old profile-registry format are rejected; no migration or legacy flag is provided.

## Transparent execution

GitSetu is plain Bash 3.2-compatible source rather than an opaque binary. Review the shell modules, generated bundle, package provenance, and deployment permissions before using it in a high-trust environment.
