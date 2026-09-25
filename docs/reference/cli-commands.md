# CLI Command Reference

GitSetu is a Bash CLI for directory-scoped Git identities, SSH keys, and credential helpers. Commands that mutate state use explicit validation, private staging, and recoverable writes.

> This reference describes the current v1.1.0 publication-ready release
> candidate. Its canonical release state remains `development` until the
> intentional public-release workflow completes; command availability does not
> imply publication.

## Provisioning and setup

### `gitsetu setup [--auto] [--dry-run]`

Alias: `gitsetu init [--auto] [--dry-run]`

Interactive profile setup and repair. `--auto` discovers identities and
applies the resulting blueprint without interactive input in non-TTY use (a
TTY setup can still ask about guard installation or an explicit FIDO2
fallback). `--dry-run` validates and previews changes without persisting state
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

Implements the Git credential-helper protocol. It handles HTTPS requests and
resolves the active profile from the current directory. The lower-level
keychain API keys records by profile, host, and optional path, but the normal
CLI currently parses `protocol`, `host`, `username`, and `password` and does
not parse Git's `path=` field; its path is empty unless
`GITSETU_CREDENTIAL_PATH` is supplied. Requests outside a mapped profile, or
for another protocol, produce no credential.

The default backend is native-only: macOS Keychain, Linux Secret Service, or
Windows Git Credential Manager. A missing native backend fails closed; it does
not silently select a file. To deliberately use the zero-dependency plaintext
backend, select it explicitly:

```bash
# With Git credential-protocol input on stdin:
GITSETU_CREDENTIAL_BACKEND=file gitsetu credential store
```

That backend writes the v2 record file at
`${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu/.tokens`, with a private `0700`
directory and `0600` file, and warns on every operation. It is plaintext, not
an encrypted vault. `GITSETU_ALLOW_PLAINTEXT=1` is an equivalent explicit
opt-in. Windows GCM is native and is not emulated by the file backend.

When compiling the managed Git configuration, GitSetu preserves an existing
user or system `credential.helper` policy and adds no helper. Only when no
such policy exists does it add its exact, shell-quoted canonical
`gitsetu credential` helper. Profile configs may add a provider-scoped
`credential` username, but that does not replace the helper policy above.

## Diagnostics and verification

### `gitsetu status`

Writes a diagnostic report to stderr. It shows the canonical current directory,
active Git identity (name, email, and `core.sshCommand` inside a repository),
the guard policy and hook-path state, configured profiles with their email,
provider, and path, and selected environment details. The active marker is the
longest matching mapped profile; otherwise status shows the unmanaged/global
fallback context. It does not enumerate OpenSSH aliases, and an unmanaged
repository is not treated as a managed profile.

### `gitsetu doctor [--repair] [--dry-run]`

Runs required offline checks for the strict v2 registry, managed Git markers,
profile identity/configuration, referenced SSH key files and permissions, and
the managed SSH `Include`/configuration. SSH-agent availability is reported
as informational; doctor does not make a network request. It exits nonzero
when a required check fails. `--repair` regenerates recognized managed Git/SSH
state and registers missing keys under the mutation lock, with rollback on a
failed repair. `gitsetu doctor --repair --dry-run` previews the planned
repairs without taking the lock or changing files.

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
`pre-commit` hook and explicit file-backend `.tokens` file. Native OS keychain
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

Production updates are disabled while v1.1.0 is in development. The only
supported update command verifies a clean checkout on the
`feature/v1.1.0-onboarding-overhaul` branch and required tracked runtime files.
It does not fetch a remote, reset a branch, or use a mutable URL as a trust
root. Bare `gitsetu update` fails with the development-mode guidance.

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
