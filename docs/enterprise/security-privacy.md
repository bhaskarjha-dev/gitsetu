# Enterprise Security & Privacy

GitSetu manages private SSH keys, Git identity configuration, and HTTPS credential routing. It does not include telemetry, analytics, or crash-reporting services. Its source is plain Bash and can be audited before deployment.

## Network boundary

GitSetu does not "phone home." Network access is limited to operations that explicitly perform remote work, including first-use discovery/SSH verification and an optional authenticated GitHub CLI upload requested by the user. The development updater refuses remote branch fetches and hard resets. Dry-run suppresses the known remote probes and credential writes; operators who require an offline workflow should still disable or avoid optional network commands and review the installed environment.

## SSH configuration and quoting

Managed OpenSSH rules are written to GitSetu's included configuration file rather than by rewriting unrelated user host blocks. Paths and tokens are quoted for the OpenSSH config parser and for the runtime `ssh` command. Existing user settings remain outside the managed block.

## Atomic writes and locks

State files are prepared in private temporary files and installed with atomic replacement where the platform permits it. A directory lock with an owner token, process liveness checks, and a bounded wait protects normal concurrent GitSetu operations.

The lock is an integrity aid, not a kernel security boundary. A malicious process running as the same user can still modify files or bypass client-side checks; use filesystem permissions, operating-system isolation, and repository review controls where stronger guarantees are required.

## Credential storage & delegation

HTTPS authentication is delegated directly to Git's native credential-helper ecosystem (Git Credential Manager, Apple Keychain via `git-credential-osxkeychain`, or Linux Secret Service via `git-credential-libsecret`) rather than routing through a custom token intermediary:

- macOS Keychain (`git-credential-osxkeychain`);
- Windows Git Credential Manager (`manager`);
- Linux Secret Service (`git-credential-libsecret`).

GitSetu configures `credential.https://<host>.username` inside each profile-specific Git configuration (`~/.config/gitsetu/profiles/<label>.gitconfig`). When Git executes remote operations within a profile's directory tree, it queries the authoritative system credential helper disambiguated by the configured username. This eliminates custom token broker intermediaries, respects OS keychain security policies, and prevents cross-profile credential collisions.

An inert compatibility shim (`gitsetu credential`) drains input and exits cleanly if invoked by legacy Git configurations, while `gitsetu doctor` flags stale helper configurations and `gitsetu doctor --repair` safely unsets them.

## Identity guard policy

The pre-commit guard is opt-in (`gitsetu guard --install`), applies to repositories classified as managed, and preserves an existing project hook when the identity check succeeds. A repository-local `core.hooksPath`, `git commit --no-verify`, direct hook/configuration changes, and later history rewrites can bypass this client-side boundary.

- A repository outside every managed profile is **unmanaged**: the identity check fails open and the repository's ordinary hooks continue.
- A repository selected by a managed profile is **managed**: an unresolved or divergent identity fails closed.
- If managed state is malformed or cannot be resolved, the guard fails closed rather than guessing.

This is a client-side identity guard, not a replacement for server-side controls, signed commits, or review policy.

## Authenticated vaults

`gitsetu backup` creates a versioned authenticated v2 vault containing the v2 registry, generated profile configuration, managed SSH configuration, referenced keys under the managed `$HOME/.ssh` root, the installed managed hook, and—if present from a legacy installation—the `.tokens` file. Native OS keychain/GCM entries are not exported, so a vault does not contain secrets held only in those stores. The v2 format provides confidentiality and integrity/authentication, uses private staging, validates the complete payload before mutation, and rolls back failed restores. Older unauthenticated/CBC vaults and the old profile-registry format are rejected; no migration or legacy flag is provided.

## Transparent execution

GitSetu is plain Bash 3.2-compatible source rather than an opaque binary. Review the shell modules, generated bundle, package provenance, and deployment permissions before using it in a high-trust environment.
