# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0 — Verified publication-ready release candidate]

The v1.1.0 line is a verified, security-hardened, publication-ready release candidate. This versioned entry is intentionally separate from the public release history until the preparation workflow creates the clean source commit, immutable tag, detached release manifest, signed artifacts, provenance, and a separately reviewed publication step. It must not be treated as permission to install a mutable branch artifact. Once those gates pass, this entry becomes the dated `[1.1.0]` public-release entry without requiring a rewrite of the feature or security documentation.

### Changed

- Replaced the colon-delimited profile registry with a versioned, strictly escaped v2 registry. There is no migration reader or legacy flag.
- Replaced backup vaults with an authenticated v2 format and transactional restore validation. Older unauthenticated/CBC vaults are rejected.
- Tightened numeric/path/input validation, canonical worktree routing, lock ownership, process cleanup, SSH command quoting, and FIDO2 failure handling.
- Added explicit managed/unmanaged guard semantics, fail-closed managed identity checks, and honest diagnostics.
- Hardened installer/updater provenance, package metadata, Windows argv/path handling, CI credential isolation, and generated-bundle checks.
- Separated generated release provenance from tagged source metadata; the release workflow is now preparation-only until a separately reviewed publish-only gate exists.
- Made setup dry-run avoid GitHub account lookups and PAT storage, with regression coverage for the offline boundary.
- Made the HTTPS credential broker honor Git's exact `path=` tuple component, with strict protocol parsing and an explicit environment override for controlled wrappers.
- Restricted GitHub Port 443 SSH routing and verification to the exact `github.com` host, with deceptive-host regression coverage.
- Added a fail-latching regression harness, isolated test environments, adversarial tamper/concurrency tests, and supported-platform matrix coverage.

### Security policy notes

- Native OS credential stores are preferred. The explicitly selected zero-dependency file backend remains plaintext and is disclosed as such; it is permission-checked and warned about, not described as encrypted.
- v1.1.0 is not yet a published release. Public asset absence is not treated as a vulnerability; release metadata and mutable aliases must remain withheld or pinned until an intentional release.

## [1.0.0] - 2026-09-10

> Historical release notes below describe the pre-v1.1 implementation. They are not current product guarantees; the v1.1 development branch uses the strict v2 registry, authenticated v2 vaults, explicit credential-backend policy, and the guard semantics documented above.

The inaugural General Availability (GA) production release of GitSetu — a zero-dependency, pure Bash 3.2 CLI compiler for automated Git multi-identity orchestration and OpenSSH key management across Linux, macOS, and Windows.

### Added

#### Core Identity & Configuration Routing
- **Directory-Scoped Identity Engine:** Automatic switching of Git identities (`user.name`, `user.email`, `core.sshCommand`) based on absolute directory paths using Git's native `includeIf` conditional directives.
- **Automated Workspace Directory Provisioning:** Automatically creates missing workspace directories (`mkdir -p`) when profiles are registered during setup or via `gitsetu add`.
- **Multi-Profile Persistence & Re-hydration:** Re-running `gitsetu setup` preserves and re-hydrates existing profiles from `profiles.conf`, allowing safe iterative edits without destructive overwrites.
- **Global Fallback Identity Architecture:** Top-level fallback profile inclusion before conditional `[includeIf]` rules with fail-closed protection via `[user] useConfigOnly = true`.
- **Longest-Prefix Match Routing:** Resolves nested directory structures (e.g. `~/work/` vs `~/work/clients/acme/`) by prioritizing the most specific directory boundary across identity routing, pre-commit guards, and prompt evaluations.
- **Cross-Platform Case-Insensitive Matching:** Automatically injects `gitdir/i:` on Windows (NTFS) and activates case-insensitive matching on macOS (Darwin) across CLI prompt and hook verifications.
- **Profile Removal & Unmounting:** `gitsetu remove <label>` surgically unmounts profile `includeIf` blocks from `~/.gitconfig`, prunes orphaned profile `.gitconfig` files from `~/.config/gitsetu/profiles/`, and removes profile SSH host blocks.

#### SSH & Cryptographic Orchestration
- **Zero-Trust OpenSSH `Include` Sandboxing:** Prepends a single `Include ~/.config/gitsetu/profiles/ssh_config` directive to the top of `~/.ssh/config`, completely isolating managed host aliases without mutating existing user configurations.
- **Automated Key Generation:** Bootstraps ED25519 software keypairs with optional passphrase protection and strict `0600` permissions.
- **Hardware Security Key Integration (FIDO2):** Provisions resident `ed25519-sk` keys for physical security tokens (YubiKey 5 Series) with automated fallback to software keys.
- **Safe SSH Command Quoting:** Enforces escaped double-quoting around SSH key paths containing spaces in `core.sshCommand` and `GIT_SSH_COMMAND` to prevent argument splitting.
- **Dual Routing Architecture (ADR-0001):** Combines directory-scoped `core.sshCommand` with `~/.ssh/config` host aliases to support external package manager clones (`go get`, `npm`, `cargo`) outside mapped directories.
- **SSH Commit Signing:** Native support for SSH-based commit signatures (`gpg.format = ssh`, `commit.gpgsign = true`).

#### Native Credential Broker
- **Cross-Platform HTTPS Authentication:** Namespaced credential helper (`gitsetu credential`) proxying HTTPS Personal Access Tokens (PATs) to prevent cross-account token pollution.
- **Native OS Keychain Integration:** Directly interfaces with macOS Keychain (`security`), Linux Secret Service (`secret-tool`), and Windows Credential Manager (`credential.helper = manager` via Git Credential Manager / DPAPI).
- **Secure File Fallback:** Restrictive fallback token storage in `~/.config/gitsetu/.tokens` enforced with `chmod 600`.

#### Security Guard Rails & Integrity
- **Fail-Closed Pre-Commit Guard (`gitsetu guard`):** Global pre-commit hook (`core.hooksPath`) that blocks commits if `user.email` diverges from the expected profile for the repository directory.
- **Hook Proxying:** Transparently passes through to project-level hooks (`husky`, `lefthook`, `pre-commit`) when identity verification succeeds.
- **Subshell-Free Environment Switching (`gitsetu run`):** Runs one-off commands under an explicit profile identity via environment variables without subshell overhead.
- **Sub-2ms Shell Prompt Integration (`gitsetu prompt`):** Ultra-low-latency `$PS1` / Starship prompt context identifier implemented in pure Bash parameter expansion.
- **Encrypted State Vault (`gitsetu backup` / `restore`):** The historical 1.0.0 implementation used an OpenSSL AES-256-CBC envelope (`-pbkdf2` / `-iter 100000`). Current v1.1.0 candidates use the authenticated v2 format documented above; the older format is rejected.
- **Clean State Teardown (`gitsetu teardown`):** Completely purges GitSetu managed blocks, unsets `core.hooksPath`, and removes application directories while preserving generated SSH keys. Supports deep cleanup (`--deep`) of matched local repository overrides.

#### Windows Platform Support & Sandbox Testing
- **Native Windows PowerShell Distribution:** Added native `install.ps1` and `uninstall.ps1` scripts with automated generation of `gitsetu.cmd` and `gitsetu.ps1` command shims in `%LOCALAPPDATA%\gitsetu\bin`, and User `PATH` environment management.
- **Canonical Windows Path Normalization:** Standardizes paths to `C:/path` canonical format, resolving impedance between native Win32 `git.exe` and MSYS / Git Bash.
- **WSL Hijack Protection:** Both the native C# launcher (`packaging/windows/gitsetu.cs`) and the Node wrapper (`bin/gitsetu.js`) prioritize Git for Windows binaries over System32 WSL bash to prevent environment hijacking.
- **7-Field Windows Drive Compatibility:** Colon collision protection (`IFS=:`) for Windows drive letters across registry parsing, backup bundling, and CLI operations.
- **NTFS Permission Handling:** Tolerates `644` permissions on NTFS filesystems under Git Bash without false-positive verification errors.
- **Windows Sandbox Test Harness:** Fully automated, disposable test harness in `sandbox/` featuring `launch_sandbox.ps1`, `launch_sandbox.bat`, `gitsetu_test.wsb`, `bootstrap.ps1`, and `comprehensive_audit.sh` (31 phases, 107 empirical checks) for host-isolated zero-trust validation.

#### Distribution, Quality Assurance & Tooling

> The distribution notes in this section describe repository capabilities at the 1.0.0 release. They are not current publication claims; the candidate entry above is the authoritative v1.1.0 status.

- **Multi-Platform Packaging Ecosystem:** Complete distribution support across all developer platforms:
  - **Standalone Monolith Bundle (`dist/gitsetu`):** Self-contained, single-file Bash executable built via `scripts/bundle.sh` (`make dist`).
  - **Node.js npm/npx Package (`package.json`, `bin/gitsetu.js`):** The package definition exposes `gitsetu` and `git-setu`; public publication remains withheld by current release policy.
  - **Microsoft WinGet Manifest Templates (`packaging/winget/templates/`):** Validated templates; no public manifest is published for the current candidate.
  - **Native Windows C# Launcher (`packaging/windows/gitsetu.cs`):** Deterministic local launcher with trusted discovery and Windows quoting.
  - **Windows Scoop Template (`packaging/scoop/`):** Validated template; no public package is published for the current candidate.
  - **Homebrew Template (`packaging/homebrew/`):** Validated template; no public formula is published for the current candidate.
  - **Arch Linux AUR Template (`packaging/aur/`):** Validated template; no public package is published for the current candidate.
  - **Nix Flake (`flake.nix`):** Zero-dependency hermetic execution from a reviewed local checkout.
  - **GitHub CLI Extension Wrappers (`packaging/gh-extension/`):** Local `gh-gitsetu` and `gh-setu` wrappers; public extension repositories are not published.
- **Multi-OS GitHub Actions CI Matrix:** Continuous delivery matrix running automated validation across 5 platforms: Ubuntu Linux 24.04, Arch Linux container (`makepkg`), Alpine Linux container (Musl/BusyBox), macOS Apple Silicon (native `/bin/bash` 3.2), and Windows Native (PowerShell, WinGet, Scoop).
- **Installer Regression Pipeline:** Added automated end-to-end testing for both POSIX and Windows PowerShell installer/uninstaller pipelines in `tests/test_installer.sh` with `$GITSETU_INSTALL_DIR` non-destructive test isolation.
- **Comprehensive Regression & E2E Test Suites:** Full serial test coverage spanning core logic, CLI, SSH, Git configuration, guard behavior, credential brokering, backup/restore, concurrency, teardown, validation, platform detection, discovery, doctor, prompt, resilience, installers, keychain, manual-mode policy, bundling, npm wrapper, WinGet, AUR, Nix flake, GitHub extension, CRLF self-healing, audit regressions, clean-room npm E2E, and adversarial/concurrency stress.
- **Unified Test Runner:** `tests/run_all.sh` provides aggregated status, bounded process-tree cleanup, and honest PASS/FAIL/SKIP summaries across the full suite set.
- **Developer Makefile:** Targets for `make test`, `make lint` (ShellCheck), `make check`, and `make hooks`.
- **Shell Autocompletion:** TAB autocompletion for subcommands and profile labels in Bash and Zsh.
- **Diagnostic Doctor (`gitsetu doctor`):** Multi-point diagnostic scanner for registry validity, OpenSSH include directives, SSH agent status, and local repository configuration drift.
- **Native Auto-Updater (`gitsetu update`):** Zero-dependency OTA updater fetching updates directly from GitHub over HTTPS.

[1.0.0]: https://github.com/bhaskarjha-dev/gitsetu/releases/tag/v1.0.0
