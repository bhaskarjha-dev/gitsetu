# CLI Command Reference

GitSetu is a Bash CLI for directory-scoped Git identities, SSH keys, and credential helpers. Commands that mutate state use explicit validation, private staging, and recoverable writes.

> This reference describes the current v1.1.0 publication-ready release
> candidate. Its canonical release state remains `development` until the
> intentional public-release workflow completes; command availability does not
> imply publication.

## Provisioning and setup

### `gitsetu setup [--auto] [--dry-run] [--guard|--no-guard]`

Alias: `gitsetu init [--auto] [--dry-run] [--guard|--no-guard]`

Interactive profile setup and repair. `--auto` discovers identities and
applies the resulting blueprint without interactive input in non-TTY use (a
TTY setup can still ask about guard installation or an explicit FIDO2
fallback). `--guard` and `--no-guard` explicitly enable or disable pre-commit
identity guard hook deployment. `--dry-run` validates and previews changes without persisting state
or contacting remote services.

The setup flow can create profiles, generate Ed25519 or FIDO2 keys, write scoped Git configuration, and offer guard installation. A FIDO2 downgrade is never silent: if hardware-key setup cannot proceed, the command reports the failure and requires an explicit choice before using a software-key alternative.

### `gitsetu add <label> <name> <email> <dir>`

Add a profile non-interactively. The label and directory are validated, generated files are written under GitSetu's managed roots, and the v2 profile registry is updated atomically.

### `gitsetu remove <label> [--force|-y]`

Remove a managed profile after confirmation. Only GitSetu-owned files, profile routing entries, and marked SSH/Git configuration blocks are changed. Private keys are preserved by default.

### `gitsetu profile <add|edit|remove>`

Manage the strict v2 profile registry programmatically:

- `gitsetu profile add <label> --email=<email> [--name=<name>] [--dir=<dir>] [--provider=<provider>] [--key=<key>] [--fido2] [--sign|--no-sign]`
- `gitsetu profile edit <label> [--name=<name>] [--email=<email>] [--dir=<dir>] [--provider=<provider>] [--key=<key>] [--fido2] [--sign|--no-sign]`
- `gitsetu profile remove <label>`

`--email` is required when a new or incomplete profile is processed in
headless mode. `--key` accepts a canonical path (a relative path is resolved
from the invoking directory); `--fido2` selects the default
`~/.ssh/id_ed25519_sk_<label>` path.
`--sign` and `--no-sign` set the profile's signing flag. The global/default
profile cannot be removed. The top-level `gitsetu remove <label> --force|-y`
command is the command that accepts the force flag; `profile remove` has no
force flag.

### `gitsetu credential <get|store|erase>`

In GitSetu v1.1.0, HTTPS credential management is delegated to Git's native platform helpers (Git Credential Manager on Windows, Apple Keychain on macOS, or Secret Service on Linux) by configuring per-profile `[credential "https://<provider>"] username = <name>` routing.

The `gitsetu credential` command is retained as an inert backwards-compatibility shim for installations upgrading from v1.0.0 (where global `credential.helper = gitsetu credential` may have been installed). When invoked by Git's credential protocol, it drains `stdin` to `/dev/null` and returns exit code `0` to prevent breaking existing Git workflows. Run `gitsetu doctor --repair` to inspect and clean any legacy GitSetu credential helper configuration.

## Diagnostics and verification

### `gitsetu status [--porcelain] [--json]`

Writes a diagnostic report to stderr (or structured key-value lines with `--porcelain`, or machine-readable telemetry JSON with `--json` on stdout). It shows the canonical current directory,
active Git identity (name, email, and `core.sshCommand` inside a repository),
the guard policy and hook-path state, configured profiles with their email,
provider, and path, and selected environment details. The active marker is the
longest matching mapped profile; otherwise status shows the unmanaged/global
fallback context. It does not enumerate OpenSSH aliases, and an unmanaged
repository is not treated as a managed profile.

### `gitsetu audit [count]`

Audits the last `N` commits (default: 10) in the current repository against the managed profile's expected identity. It inspects commit author and committer emails to ensure neither diverges from the configured profile. Returns exit code `0` when all evaluated commits match the expected profile (or when run in an unmanaged repository), and returns exit code `1` if any commit contains mismatched author or committer identities, providing immediate fix instructions (`git commit --amend --reset-author --no-edit`).

### `gitsetu doctor [--repair] [--dry-run] [--json]`

Runs required offline checks for the strict v2 registry, managed Git markers,
profile identity/configuration, referenced SSH key files and permissions, and
the managed SSH `Include`/configuration. Also inspects system and cryptographic
environment health (Git version >= 2.36, OpenSSL AES-256 cipher support, clipboard tool,
and SSH known hosts). With `--json`, outputs a machine-readable JSON status object on stdout. SSH-agent availability is reported
as informational; doctor does not make a network request. It exits nonzero
when a required check fails. `--repair` regenerates recognized managed Git/SSH
state and registers missing keys under the mutation lock, with rollback on a
failed repair. `gitsetu doctor --repair --dry-run` previews the planned
repairs without taking the lock or changing files.

### `gitsetu explain [path]`

Traces identity resolution and effective Git/SSH configuration for a given directory (defaults to current working directory). Shows exactly which profile matches, whether routing occurred via `gitdir` or `hasconfig:remote.*.url`, the effective `user.name`, `user.email`, `core.sshCommand`, and the specific config file source where each directive originates.

### `gitsetu import [--yes|-y]`

Scans `~/.gitconfig` for existing unmanaged `[includeIf "gitdir:..."]` rules outside GitSetu's managed blocks and offers to adopt them into GitSetu profile management. In non-interactive mode or when passed `--yes`, automatically imports valid unmanaged identities into the v2 profile registry and rewrites managed include blocks cleanly.

### `gitsetu verify`

Runs the required offline key and Git validators and writes their report to
stderr. It checks the strict v2 registry, global/profile config syntax and
expected identities, effective author/committer identities in repositories
discovered under mapped profiles, key existence and ownership, private-key
permissions, and matching private/public-key fingerprints. It does not check
hook installation, SSH
agent state, or the network by default, and returns nonzero if a required
validation group fails. Network verification is opt-in with
`GITSETU_VERIFY_NETWORK=1`; first-use host-key trust must be separately
approved with `GITSETU_ALLOW_SSH_HOST_KEY=1` (or the equivalent
`GITSETU_SSH_ACCEPT_NEW_HOST=1`). Dry-run verification never contacts SSH or
changes `known_hosts`.

### `gitsetu prompt`

Prints the label of the longest matching mapped profile for shell
integrations. It uses canonical path matching, including platform-aware case
handling; it prints nothing outside mapped profile directories. Performance
depends on the host shell and filesystem, so no fixed sub-millisecond guarantee
is made.

## Vault operations

### `gitsetu backup [out_file]`

Creates an authenticated v2 vault from the managed registry, profile configs,
managed SSH config, referenced SSH key pairs, and (when present) the managed
`pre-commit` hook and legacy `.tokens` file. Native OS keychain
and GCM records are not exported, and the user's global `~/.gitconfig` and
`~/.ssh/config` are regenerated rather than copied into the vault. The
archive is prepared and encrypted in private temporary storage and installed
atomically. With no output argument, the name is
`gitsetu_vault_YYYYMMDD_HHMMSS.gitsetu-v2.vault`. The current format is v2
only; older CBC/unauthenticated vaults are rejected and there is no migration
flag.

### `gitsetu restore <in_file>`

Authenticates and validates a v2 vault in private staging before changing live
state, then performs a transactional restore. Wrong passwords, tampering,
unsafe archive members, and truncated payloads fail without partial
installation. A failed transaction is rolled back when possible. If rollback
is incomplete, the command leaves a private transaction snapshot with a
`RECOVERY_REQUIRED` marker and reports its path; it does not create a
plaintext recovery-password sidecar.

## System operations

### `gitsetu run <profile> -- <command>`

Requires the literal `--` separator and executes the command without changing
the current directory or configuration files. Before exec, it exports
`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`,
`GIT_COMMITTER_EMAIL`, and `GIT_SSH_COMMAND` for the selected profile. The SSH
key is shell-quoted as one argument, for example
`GIT_SSH_COMMAND="ssh -i '/home/alice/.ssh/id_ed25519_work'"`; command arguments
are passed without shell-word splitting. The selected profile must have a valid
config and existing private/public key pair—there is no global-identity or
missing-key fallback.

### `gitsetu update --development` (`--dev` is also accepted)

Production updates are disabled while v1.1.0 is in development. The `--development` update option verifies a clean development checkout on the
active branch and required tracked runtime files without fetching remote tags.
When invoked without flags in a Git checkout, `gitsetu update` fetches tags from
origin to inspect release availability.

### `gitsetu guard --install` | `gitsetu guard --uninstall`

Installs the generated identity guard under the GitSetu hooks directory and
configures the Git hooks path while preserving an existing project hook when
possible.

Managed repositories fail closed when their expected identity is missing or
divergent. Repositories outside all managed profiles fail open for the identity
check by policy; their ordinary project hooks still run.

### `gitsetu teardown [--force] [--deep]`

Removes marked GitSetu configuration and managed state. Private SSH keys are
preserved unless an explicit, separately authorized destructive action is
added in the future. Deep cleanup is bounded to verified repositories and
managed profile boundaries.

### `gitsetu --help`, `gitsetu -h`

Displays command help.

### `gitsetu --version`, `gitsetu -v`

Prints exactly the current CLI version line, `gitsetu v1.1.0`. It does not
print a release channel or imply that the candidate is publicly published.
