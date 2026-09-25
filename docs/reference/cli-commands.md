# CLI Command Reference

GitSetu is a Bash CLI for directory-scoped Git identities, SSH keys, and credential helpers. Commands that mutate state use explicit validation, private staging, and recoverable writes.

> This reference describes the current v1.1.0 publication-ready release
> candidate. Its canonical release state remains `development` until the
> intentional public-release workflow completes; command availability does not
> imply publication.

## Provisioning and setup

### `gitsetu setup [--auto] [--dry-run]`

Alias: `gitsetu init [--auto] [--dry-run]`

Interactive profile setup and repair. `--auto` uses the documented onboarding flow; `--dry-run` validates and previews changes without persisting state or contacting remote services.

The setup flow can create profiles, generate Ed25519 or FIDO2 keys, write scoped Git configuration, and offer guard installation. A FIDO2 downgrade is never silent: if hardware-key setup cannot proceed, the command reports the failure and requires an explicit choice before using a software-key alternative.

### `gitsetu add <label> <name> <email> <dir>`

Add a profile non-interactively. The label and directory are validated, generated files are written under GitSetu's managed roots, and the v2 profile registry is updated atomically.

### `gitsetu remove <label> [--force|-y]`

Remove a managed profile after confirmation. Only GitSetu-owned files, profile routing entries, and marked SSH/Git configuration blocks are changed. Private keys are preserved by default.

### `gitsetu profile <subcommand>`

Manage profiles programmatically:

- `gitsetu profile add <label> --email=<email> [--dir=<dir>] [--name=<name>] [--key=<key>] [--sign] [--provider=<provider>]`
- `gitsetu profile remove <label> [--force|-y]`

### `gitsetu credential <get|store|erase>`

Git credential-helper protocol. GitSetu scopes records by active profile, host, and path and prefers the native OS store. On systems without a native store, the explicitly selected `GITSETU_CREDENTIAL_BACKEND=file` backend uses a warned-about plaintext `~/.config/gitsetu/.tokens` file with strict permissions.

## Diagnostics and verification

### `gitsetu status`

Lists registered profiles, managed paths, providers, and SSH aliases, and identifies the active profile by canonical path. Unmanaged repositories are not treated as managed profiles.

### `gitsetu doctor [--repair] [--dry-run]`

Runs offline structural, configuration, permission, and identity checks. Network-dependent checks are reported separately from required local checks. `--dry-run` previews repairs; `--repair` changes only recognized GitSetu-managed state.

### `gitsetu verify`

Verifies managed configuration, referenced key paths, permissions, and hook installation. It does not claim that a client-side check can detect every same-user process or server-side credential problem.

### `gitsetu prompt`

Prints the active managed profile label for shell integrations. It uses canonical path matching, including longest-prefix matching and platform-aware case handling. Performance depends on the host shell and filesystem; no fixed sub-millisecond guarantee is made.

## Vault operations

### `gitsetu backup [out_file]`

Creates an authenticated v2 vault from managed state and referenced keys. The archive is prepared and encrypted in private temporary storage and installed atomically. The current format is v2 only; older CBC/unauthenticated vaults are rejected and there is no migration flag.

### `gitsetu restore <in_file>`

Verifies and authenticates a v2 vault before changing state, validates the complete payload in a staging area, and performs a transactional restore. Wrong passwords, tampering, unsafe archive members, and truncated payloads fail without partial installation.

## System operations

### `gitsetu run <profile> -- <command>`

Runs a command with the selected profile's Git identity, SSH command, and credential context. Arguments are passed without shell-word splitting.

### `gitsetu update`

Updates only through the configured release/update path. A development checkout must not be treated as a published v1.1.0 release. Release artifacts and metadata must be pinned and integrity-checked; mutable aliases such as `main` are not release trust roots.

### `gitsetu guard --install` | `gitsetu guard --uninstall`

Installs the generated identity guard under the GitSetu hooks directory and configures the Git hooks path while preserving an existing project hook when possible.

Managed repositories fail closed when their expected identity is missing or divergent. Repositories outside all managed profiles fail open for the identity check by policy; their ordinary project hooks still run.

### `gitsetu teardown [--force] [--deep]`

Removes marked GitSetu configuration and managed state. Private SSH keys are preserved unless an explicit, separately authorized destructive action is added in the future. Deep cleanup is bounded to verified repositories and managed profile boundaries.

### `gitsetu --help`, `gitsetu -h`

Displays command help.

### `gitsetu --version`, `gitsetu -v`

Prints the development version and release channel.
