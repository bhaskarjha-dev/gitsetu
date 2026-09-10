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

## 2. Zero-Trust SSH Isolation & Safe Command Quoting

Standard configuration utilities often manipulate global `~/.ssh/config` structures via aggressive regex replacements, risking catastrophic corruption of enterprise host routing blocks.

GitSetu strictly isolates operations using an **OpenSSH Include Pivot**. It injects a single `Include ~/.config/gitsetu/profiles/ssh_config` directive into your global configuration. All dynamically generated key aliases, Host targets, and isolation flags (`IdentitiesOnly yes`) are tightly sandboxed within localized files. If GitSetu is purged, your global SSH config remains mathematically uncorrupted.

Furthermore, GitSetu prevents CLI argument splitting by strictly wrapping SSH key paths containing whitespace characters in escaped double-quotes within `core.sshCommand` and runtime `GIT_SSH_COMMAND` exports.

## 3. Atomic Concurrency Integrity

To support highly concurrent headless CI/CD runners or rapid execution within multiplexed terminal sessions (`tmux`/`zellij`), GitSetu protects all filesystem state changes utilizing atomic POSIX primitives.

- **Write Isolation:** Mutating global blocks writes heavily to `$TMPDIR` isolation bounds before triggering single-cycle `mv` atomic swaps.
- **State Locks:** Cross-process conflicts are entirely mitigated using localized `mkdir` execution locks (`profiles.lock`) with PID inspection and automatic stale-lock eviction, strictly guaranteeing that simultaneous commands across parallel processes never corrupt state pipelines.

## 4. Protected Credential Storage

GitSetu enforces a strict policy against storing authentication payloads in plain text.
The native **Credential Broker Engine** routes Personal Access Tokens (PATs) securely directly into your operating system's native encrypted security enclaves:
- **macOS:** Apple Keychain Access (`security add-generic-password`).
- **Windows:** Microsoft Git Credential Manager (GCM) backed by Windows DPAPI / Windows Credential Manager (`credential.helper = manager`).
- **Linux:** Native Secret Service DBus API (`secret-tool`).
- **Fallback Storage:** When native keychains are unavailable, tokens are written to an isolated vault file at `~/.config/gitsetu/.tokens` enforced with strict `chmod 600` permissions (readable only by the file owner).

## 5. Fail-Closed Identity Guard & Orphaned Config Pruning

- **Pre-Commit Enforcement:** The global pre-commit hook acts as a fail-closed interceptor, halting commits with an instant fatal abort if the staged commit author email diverges from the directory-scoped profile email. It dynamically resolves nested directory trees via longest-prefix matching and re-reads live profile email definitions to prevent configuration desync.
- **Orphan Pruning:** Removing a profile (`gitsetu remove <label>`) cleanly unmounts conditional `includeIf` directives from `~/.gitconfig`, prunes corresponding `.gitconfig` files from `~/.config/gitsetu/profiles/`, and purges orphaned configuration remnants.

## 6. End-to-End Cryptographic Vaults

When operators export GitSetu state architecture via the `gitsetu backup` command, all compiled targets—and more critically, the private software SSH keys—are aggressively bundled into a compressed target payload.

GitSetu mandates that this payload is encrypted instantaneously using the host system's native `openssl` binaries. It utilizes **AES-256-CBC** cryptography scaled via heavy `-pbkdf2` derivation loops, rendering the offline vault mathematically secure against brute-force extraction attempts.

## 7. Transparent Auditable Execution

Pre-compiled binary toolchains obscure their execution paths, forcing security analysts to rely on trust or reverse-engineering toolkits.

Because GitSetu is compiled entirely in pure, un-obfuscated POSIX **Bash 3.2**, organizational security engineers can transparently audit the entire operational chain simply by reading the plain-text shell source payload prior to deployment.
