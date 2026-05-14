# Security & Privacy Center

GitSetu is built with a paranoid security posture designed to pass rigorous Enterprise IT and CISO audits. 

Because GitSetu orchestrates highly sensitive cryptographic material (SSH Keys, Personal Access Tokens), it is engineered to be auditable, offline, and immutable.

## Zero Telemetry
GitSetu does not phone home. It contains zero analytics, zero crash reporting, and zero telemetry. 

The **only** network request GitSetu ever makes is initiated by the user when running `gitsetu update`, which performs a standard `curl` request over TLS to `raw.githubusercontent.com` to fetch the latest verifiable Bash script. 

## Zero-Trust SSH Isolation
Other Git identity tools manipulate your global `~/.ssh/config` using dangerous regex replacements or blind appends. This frequently corrupts unrelated host configurations, leading to broken server access.

GitSetu utilizes a **Zero-Trust `Include` architecture**. It injects a single `Include ~/.config/gitsetu/ssh/*` directive into your global config. All GitSetu profiles are strictly sandboxed into their own files. If GitSetu crashes or is uninstalled, your global SSH config remains mathematically pristine.

## POSIX Lock Integrity
To prevent race conditions during concurrent CI/CD operations or rapid terminal multiplexing (tmux/screen), GitSetu wraps all filesystem modifications in atomic POSIX `mkdir` locks. This guarantees that two parallel `git clone` commands will never corrupt your credential storage.

## AES-256 Encrypted Backups
When exporting identity state via `gitsetu backup`, all private SSH keys are recursively aggregated into a tarball and strictly encrypted using your system's native `openssl` binary with **AES-256-CBC**. The resulting vault file is offline and requires the user-defined password to decrypt.

## Credential Storage
GitSetu never stores Personal Access Tokens in plain-text. The Credential Broker securely interfaces directly with:
- **macOS:** Apple Keychain Access (`security add-generic-password`)
- **Linux:** Secret Service API (`secret-tool`)

## Auditable Runtime
GitSetu is written in pure POSIX Bash 3.2. There are no compiled Go binaries, obscure Node.js package dependency trees, or hidden Python imports. A security engineer can audit the entire execution path by reading the shell source code directly.
