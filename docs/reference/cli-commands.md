# CLI Command Reference

**The complete GitSetu execution palette.**

GitSetu exposes a highly targeted, heavily validated command palette designed exclusively to interact with Git and SSH state structures. All commands are strictly idempotent.

---

## Provisioning & Setup

### `gitsetu setup`
The primary interactive compilation wizard. Use this command to provision entirely new workspace profiles or seamlessly update existing configuration paths.
- Natively prompts for distinct Profile Labels, Developer Names, Emails, and Target Directories.
- Prompts for Zero-Trust SSH Key generation (ED25519 or FIDO2 hardware tokens).
- Safely injects atomic managed blocks directly into `~/.gitconfig` and OpenSSH configuration files.

### `gitsetu add <label> "<name>" <email> <dir>`
Add a new profile non-interactively via positional arguments.
- Example: `gitsetu add work "Dev Name" dev@company.com ~/work`
- Generates SSH keys, registers the profile in `profiles.conf`, and updates `~/.gitconfig` automatically.
- Automatically creates the workspace directory (`mkdir -p`) if it does not already exist.

### `gitsetu remove <label>`
Remove an existing profile non-interactively.
- Safely unmounts the profile's conditional `includeIf` from `~/.gitconfig`.
- Prunes the profile configuration file `~/.config/gitsetu/profiles/<label>.gitconfig` and any orphaned configs.
- Removes profile SSH host blocks from `~/.config/gitsetu/profiles/ssh_config` and updates `profiles.conf`.

### `gitsetu profile <subcommand>`
Manage profiles programmatically:
- `gitsetu profile add <label> --email=<email> [--dir=<dir>] [--name=<name>] [--key=<key>] [--sign] [--provider=<provider>]`
- `gitsetu profile remove <label>`: Removes specified profile and updates all managed configurations.

### `gitsetu credential <action>`
Standard Git credential helper broker protocol implementation:
- `gitsetu credential get`: Resolves credentials based on active directory profile context.
- `gitsetu credential store`: Persists credentials securely into OS keychain or `~/.config/gitsetu/.tokens`.
- `gitsetu credential erase`: Erases credentials for the current profile context.

---

## Diagnostics & Verification

### `gitsetu status`
Renders a structured, tabular layout of your entire GitSetu configuration state.
- Lists all registered profiles, bounded paths, and linked OpenSSH aliases.
- Dynamically highlights your **currently active profile** based on your active terminal directory context.

### `gitsetu doctor`
An advanced configuration health-scanner designed to identify silent environmental drift.
- Validates global `~/.gitconfig` syntax integrity and verifies the presence of managed identity blocks.
- Ensures the OpenSSH `Include` directive remains valid at the top of `~/.ssh/config`.
- Scans deep local `.git/config` files within mapped directory trees to surface overlapping or conflicting `user.email` hardcodes.

### `gitsetu verify`
Executes aggressive permissions and structural validation testing.
- Checks if generated private cryptographic keys (`~/.ssh/id_*`) possess strict POSIX `600` access boundaries (tolerates `644` under Windows NTFS emulation).
- Verifies SSH Agent socket connection state and pre-loaded signatures.

### `gitsetu prompt`
A specialized, ultra-fast context extractor designed strictly for sub-millisecond shell `$PS1` or Starship rendering integrations.
- Returns exactly one string (the active profile label) in `< 2ms` without spawning blocking subshells.
- Resolves nested paths via longest-prefix matching (most specific directory wins).
- Supports canonical Windows drive paths (`C:/...`) and case-insensitive directory matching on Windows and macOS.

---

## Vault Operations

### `gitsetu backup [out_file]`
The comprehensive export utility.
- Aggregates configuration schemas and cryptographic keys into a single `.tar` block.
- Enforces strict inline AES-256-CBC `-pbkdf2` encryption via native OpenSSL boundaries.

### `gitsetu restore <in_file>`
The bare-metal state re-construction tool.
- Decrypts target vaults and reconstructs structural mapping blocks transparently.
- Creates an automated pre-flight backup of existing state before restoring.

---

## System Operations

### `gitsetu run <profile> -- <cmd>`
Execute any command under a specific identity profile context without changing your current directory or altering configuration files.
- Injects environment variables (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL`, and `GIT_SSH_COMMAND`).
- Enforces escaped double-quoting around SSH key paths containing spaces in `GIT_SSH_COMMAND` to prevent argument splitting.
- Example: `gitsetu run work -- git commit -m "fix"`

### `gitsetu update`
Executes the native OTA (Over-The-Air) update sequence.
- Pulls verified binary payloads exclusively via standard TLS/HTTPS domains.
- Atomically hot-swaps the local `~/.local/share/gitsetu` executable binary.

### `gitsetu guard --install` / `gitsetu guard --uninstall`
Toggles the fail-closed Pre-Commit Identity interceptor bounds inside the global `core.hooksPath` configuration matrix:
- `--install`: Installs and activates the global pre-commit hook in `~/.config/gitsetu/guard.sh` and configures `core.hooksPath`.
- `--uninstall`: Deactivates the global pre-commit hook and unsets `core.hooksPath`.

### `gitsetu teardown [--force] [--deep]`
**[Destructive Command]** The ultimate uninstall and nuclear escape hatch.
- Safely uninstalls GitSetu by completely purging all managed layout boundaries, sub-files, and configuration blocks from the host system cleanly.
- Restores the host Git environments to their pristine, pre-installation state without deleting your private SSH keys.
- `--deep`: Recursively strips matched local repository identity overrides.
- `--force`: Bypasses the confirmation prompt.
