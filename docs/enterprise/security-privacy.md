# Enterprise Security & Privacy

**Uncompromising Zero-Trust safeguards built to pass rigorous organizational and CISO audits seamlessly.**

GitSetu manages highly sensitive cryptographic boundaries, orchestrating private SSH keys, executing HTTPS credential injections, and modifying global environment states. Operating within these domains requires a structurally paranoid architectural posture. 

GitSetu is deliberately engineered to be transparent, offline, and functionally immutable.

---

## 1. Absolute Zero Telemetry

GitSetu does not "phone home."
- **Zero Analytics:** The codebase contains no telemetry payloads, usage trackers, or crash reporting pipelines.
- **Zero External Runtimes:** Execution requires no cloud infrastructure or backend synchronization servers.
- **Strict Network Boundary:** The *only* network outbound call GitSetu natively invokes is explicitly user-triggered via the `gitsetu update` command, which fetches raw verified source code dynamically over standard TLS/HTTPS bounds natively from the verified GitHub repository.

## 2. Zero-Trust SSH Isolation

Standard configuration utilities often manipulate global `~/.ssh/config` structures via aggressive regex replacements, risking catastrophic corruption of enterprise host routing blocks.

GitSetu strictly isolates operations using an **OpenSSH Include Pivot**. It injects a single `Include ~/.config/gitsetu/ssh_config` directive into your global configuration. All dynamically generated key aliases, Host targets, and isolation flags (`IdentitiesOnly yes`) are tightly sandboxed within localized files. If GitSetu is purged, your global SSH config remains mathematically uncorrupted.

## 3. Atomic Concurrency Integrity

To support highly concurrent headless CI/CD runners or rapid execution within multiplexed terminal sessions (`tmux`/`zellij`), GitSetu protects all filesystem state changes utilizing atomic POSIX primitives.

- **Write Isolation:** Mutating global blocks writes heavily to `$TMPDIR` isolation bounds before triggering single-cycle `mv` atomic swaps.
- **State Locks:** Cross-process conflicts are entirely mitigated using localized `mkdir` execution locks, strictly guaranteeing that simultaneous `git pull` triggers across parallel processes never corrupt active credential extraction pipelines.

## 4. Protected Credential Storage

GitSetu enforces a strict policy against storing authentication payloads in plain text.
The native **Credential Broker Engine** routes Personal Access Tokens (PATs) securely directly into your operating system's native encrypted security enclaves:
- **macOS:** Apple Keychain Access (`security add-generic-password`).
- **Linux:** Native Secret Service DBus API (`secret-tool`).

## 5. End-to-End Cryptographic Vaults

When operators export GitSetu state architecture via the `gitsetu backup` command, all compiled targets—and more critically, the private software SSH keys—are aggressively bundled into a compressed target payload.

GitSetu mandates that this payload is encrypted instantaneously using the host system's native `openssl` binaries. It utilizes **AES-256-CBC** cryptography scaled via heavy `-pbkdf2` derivation loops, rendering the offline vault mathematically secure against brute-force extraction attempts.

## 6. Transparent Auditable Execution

Pre-compiled binary toolchains obscure their execution paths, forcing security analysts to rely on trust or reverse-engineering toolkits.

Because GitSetu is compiled entirely in pure, un-obfuscated POSIX **Bash 3.2**, organizational security engineers can transparently audit the entire operational chain simply by reading the plain-text shell source payload prior to deployment.
