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

### `gitsetu auth <profile>`
The secure Credential Broker interface. Use this command to securely bind HTTPS Personal Access Tokens (PATs) to specific identity contexts.
- Securely prompts inline for your Git provider token without echoing to the terminal (`stty -echo`).
- Encrypts and stores the token directly into the OS keychain within the `gitsetu:<profile>:hostname` namespace.

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
- Checks if generated private cryptographic keys (`~/.ssh/id_*`) possess strict POSIX `600` access boundaries.
- Verifies SSH Agent socket connection state and pre-loaded signatures.

### `gitsetu prompt`
A specialized, ultra-fast context extractor designed strictly for sub-millisecond shell `$PS1` or Starship rendering integrations.
- Returns exactly one string (the active profile label) in `< 2ms` without spawning blocking subshells.

---

## Vault Operations

### `gitsetu backup`
The comprehensive export utility.
- Aggregates configuration schemas and cryptographic keys into a single `.tar` block.
- Enforces strict inline AES-256-CBC `-pbkdf2` encryption via native OpenSSL boundaries.

### `gitsetu restore <file>`
The bare-metal state re-construction tool.
- Decrypts target vaults and reconstructs structural mapping blocks transparently.

---

## System Operations

### `gitsetu update`
Executes the native OTA (Over-The-Air) update sequence.
- Pulls verified binary payloads exclusively via standard TLS/HTTPS domains.
- Atomically hot-swaps the local `~/.local/share/gitsetu` executable binary.

### `gitsetu install-guard` / `gitsetu remove-guard`
Toggles the fail-closed Pre-Commit Identity interceptor bounds inside the global `core.hooksPath` configuration matrix.

### `gitsetu teardown`
**[Destructive Command]** The ultimate nuclear escape hatch.
- Completely purges all GitSetu managed layouts, sub-files, and configuration blocks from the host system cleanly.
- Restores the host Git environments to their pristine, pre-installation state.
