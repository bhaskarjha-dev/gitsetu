# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-22

The Developer Experience (DX) release — zero-friction onboarding, automated SSH verification, and self-healing diagnostics.

### Added

#### First-Time Onboarding UX
- **3-Path Guided On-Ramp (`preset_guided_onboarding`):** First-run experience offers Single Identity, Dual Identity, or Custom Setup presets with auto-discovery of existing Git identities and SSH keys.
- **Bare `gitsetu` Smart Entrypoint:** Running `gitsetu` without arguments now shows `gitsetu status` when configured (interactive TTY), or launches the guided on-ramp when unconfigured.
- **Dashboard UX Improvements:** ENTER on incomplete profile auto-opens edit prompt; single-profile `[E]dit` skips number selection; `[⚠ Incomplete]` tag rendered next to profiles missing name/email.
- **Post-Setup Completion Summary (`render_setup_summary`):** Structured summary table with profile details, guard status, and quick reference commands.

#### SSH Automation & Verification
- **Automated `ssh-agent` Key Registration (`auto_register_ssh_keys`):** Socket liveness detection, fingerprint deduplication, macOS `--apple-use-keychain` support. All failures non-fatal.
- **GitHub CLI Key Upload (`try_gh_key_upload`):** One-click SSH public key upload to authenticated GitHub account via `gh ssh-key add`. Scope-disciplined: uses only `gh api user -q .login`.
- **SSH Handshake Verification with Port 443 Fallback (`verify_ssh_handshake`):** Post-setup connectivity test with automatic corporate firewall detection. Regenerates SSH config with `Port 443` + `HostName ssh.github.com` when needed.
- **Guard Activation Prompt:** `execute_blueprint()` now prompts to enable pre-commit identity guard (default yes) after setup.

#### Diagnostics & Self-Healing
- **Doctor Repair Mode (`gitsetu doctor --repair`):** Auto-restores missing `~/.gitconfig` managed blocks, SSH Include directives, and registers unloaded SSH keys with the agent.
- **Doctor Repair Hint:** `run_doctor()` now prints `"try: gitsetu doctor --repair"` footer when issues are detected.

#### Workspace Management
- **Automated Workspace Directory Provisioning (`ensure_workspace_dirs`):** Automatically creates missing workspace directories during setup with `mkdir -p`.

### Changed
- **Comparisons Documentation Rewrite (`docs/overview/comparisons.md`):** Browser-verified competitor data with honest "Where Competitors Excel" section. Removed fabricated self-assessment scores.
- **Test Suite Expansion:** 44 comprehensive regression & E2E test suites (up from 36), including `test_onboarding.sh` (15 tests), `test_ssh_automation.sh` (19 tests), `test_doctor_repair.sh` (6 tests), `test_gh_keys.sh`, `test_setup_load_and_dirs.sh`, `test_status.sh`, `test_update.sh`, and `test_audit_regressions.sh`.
- **Shell Completion Expansion:** Added `--repair` and `--dry-run` to `doctor` completions; `--auto` to `setup` completions.

### Fixed
- Dashboard ENTER with incomplete profile no longer prints error and sleeps — auto-opens edit for first incomplete profile.
- Single-profile `[E]dit` no longer prompts for profile number selection.

[1.1.0]: https://github.com/bhaskarjha-dev/gitsetu/releases/tag/v1.1.0

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
- **WSL Hijack Protection:** Both the native C# launcher (`packaging/windows/gitsetu.cs`) and the Node wrapper (`bin/gitsetu.js`) prioritize Git for Windows binaries over System32 WSL bash to prevent environment hijacking.
- **7-Field Windows Drive Compatibility:** Colon collision protection (`IFS=:`) for Windows drive letters across registry parsing, backup bundling, and CLI operations.
- **NTFS Permission Handling:** Tolerates `644` permissions on NTFS filesystems under Git Bash without false-positive verification errors.
- **Windows Sandbox Test Harness:** Fully automated, disposable test harness in `sandbox/` featuring `launch_sandbox.ps1`, `launch_sandbox.bat`, `gitsetu_test.wsb`, `bootstrap.ps1`, and `comprehensive_audit.sh` (31 phases, 107 empirical checks) for host-isolated zero-trust validation.

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
- **Multi-OS GitHub Actions CI Matrix:** Continuous delivery matrix running automated validation across 5 platforms: Ubuntu Linux 24.04, Arch Linux container (`makepkg`), Alpine Linux container (Musl/BusyBox), macOS Apple Silicon (native `/bin/bash` 3.2), and Windows Native (PowerShell, WinGet, Scoop).
- **Installer Regression Pipeline:** Added automated end-to-end testing for both POSIX and Windows PowerShell installer/uninstaller pipelines in `tests/test_installer.sh` with `$GITSETU_INSTALL_DIR` non-destructive test isolation.
- **44 Comprehensive Regression & E2E Test Suites:** Full test suite covering core logic, CLI, SSH, gitconfig, guard, credential broker, backup/restore, concurrency, teardown, validation, platform detection, discovery, doctor, prompt, resilience, installer, keychain, manual mode, bundler, npm wrapper, winget, AUR, Nix flake, GH extension, CRLF self-healing, audit regressions, clean-room npm E2E (`test_npm_cleanroom_e2e.sh`), and adversarial & concurrency stress (`test_adversarial_stress.sh`).
- **Unified Test Runner:** Added `tests/run_all.sh` providing aggregated status and colored summaries across all 44 test suites.
- **Developer Makefile:** Targets for `make test`, `make lint` (ShellCheck), `make check`, and `make hooks`.
- **Shell Autocompletion:** TAB autocompletion for subcommands and profile labels in Bash and Zsh.
- **Diagnostic Doctor (`gitsetu doctor`):** Multi-point diagnostic scanner for registry validity, OpenSSH include directives, SSH agent status, and local repository configuration drift.
- **Native Auto-Updater (`gitsetu update`):** Zero-dependency OTA updater fetching updates directly from GitHub over HTTPS.

[1.0.0]: https://github.com/bhaskarjha-dev/gitsetu/releases/tag/v1.0.0
