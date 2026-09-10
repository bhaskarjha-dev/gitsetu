# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-10

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
- **Encrypted State Vault (`gitsetu backup` / `restore`):** Bundles and encrypts all GitSetu state and software SSH keys using OpenSSL AES-256-CBC (`-pbkdf2` / `-iter 100000`). Pre-flight safety net backs up existing state before restore.
- **Clean State Teardown (`gitsetu teardown`):** Completely purges GitSetu managed blocks, unsets `core.hooksPath`, and removes application directories while preserving generated SSH keys. Supports deep cleanup (`--deep`) of matched local repository overrides.

#### Windows Platform Support & Sandbox Testing
- **Native Windows PowerShell Distribution:** Added native `install.ps1` and `uninstall.ps1` scripts with automated generation of `gitsetu.cmd` and `gitsetu.ps1` command shims in `%LOCALAPPDATA%\gitsetu\bin`, and User `PATH` environment management.
- **Canonical Windows Path Normalization:** Standardizes paths to `C:/path` canonical format, resolving impedance between native Win32 `git.exe` and MSYS / Git Bash.
- **7-Field Windows Drive Compatibility:** Colon collision protection (`IFS=:`) for Windows drive letters across registry parsing, backup bundling, and CLI operations.
- **NTFS Permission Handling:** Tolerates `644` permissions on NTFS filesystems under Git Bash without false-positive verification errors.
- **Windows Sandbox Test Harness:** Fully automated, disposable test harness in `sandbox/` featuring `launch_sandbox.bat`, `gitsetu_test.wsb`, `bootstrap.ps1`, and `comprehensive_audit.sh` (24 phases, 70 empirical checks) for host-isolated zero-trust validation.

#### Distribution, Quality Assurance & Tooling
- **Multi-Platform Packaging Ecosystem:** Complete distribution support across all developer platforms:
  - **Standalone Monolith Bundle (`dist/gitsetu`):** Self-contained, single-file Bash executable built via `scripts/bundle.sh` (`make dist`).
  - **Node.js npm/npx Package (`package.json`, `bin/gitsetu.js`):** Instant zero-install execution via `npx gitsetu setup --auto` and global installation via `npm i -g gitsetu`.
  - **Microsoft WinGet Manifest Triad (`packaging/winget/`):** Official Microsoft Windows Package Manager manifests validated against Microsoft CLI schema.
  - **Native Windows C# Launcher (`packaging/windows/gitsetu.cs`):** Compiled via `build_launcher.ps1` (`csc.exe`) for transparent execution.
  - **Windows Scoop Manifest (`packaging/scoop/gitsetu.json`):** Compatible with Scoop package manager.
  - **Homebrew Formula (`packaging/homebrew/gitsetu.rb`):** Compatible with macOS & Linux Homebrew.
  - **Arch Linux AUR (`packaging/aur/`):** Validated `PKGBUILD` and `.SRCINFO` package specification.
  - **Nix Flake (`flake.nix`):** Zero-dependency hermetic execution via `nix run github:bhaskarjha-dev/gitsetu`.
  - **GitHub CLI Extension (`packaging/gh-extension/`):** Executable extension wrapper (`gh gitsetu`).
- **Installer Regression Pipeline:** Added automated end-to-end testing for both POSIX and Windows PowerShell installer/uninstaller pipelines in `tests/test_installer.sh`.
- **32 Comprehensive Regression Test Suites:** Full test suite covering core logic, CLI, SSH, gitconfig, guard, credential broker, backup/restore, concurrency, teardown, validation, platform detection, discovery, doctor, prompt, resilience, installer, keychain, manual mode, bundler, npm wrapper, winget, AUR, Nix flake, GH extension, and audit regressions.
- **Unified Test Runner:** Added `tests/run_all.sh` providing aggregated status and colored summaries across all 32 test suites.
- **Developer Makefile:** Targets for `make test`, `make lint` (ShellCheck), `make check`, and `make hooks`.
- **Shell Autocompletion:** TAB autocompletion for subcommands and profile labels in Bash and Zsh.
- **Diagnostic Doctor (`gitsetu doctor`):** Multi-point diagnostic scanner for registry validity, OpenSSH include directives, SSH agent status, and local repository configuration drift.
- **Native Auto-Updater (`gitsetu update`):** Zero-dependency OTA updater fetching updates directly from GitHub over HTTPS.
