# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-05-14

### Added
- **Native Auto-Updater (`gitsetu update`):** A secure, zero-dependency self-updating mechanism that leverages Git's TLS protocol and the live repository installation (`~/.local/share/gitsetu`) to securely fetch and apply patches.

### Changed
- **Zero-Trust OpenSSH Pivot:** Migrated the entire SSH orchestration architecture from inline `awk` mutations of `~/.ssh/config` to a fully isolated `Include ~/.config/gitsetu/ssh_config` directive. This guarantees 100% idempotency and zero footprint on the user's manual SSH configuration.
- **Teardown Command:** `gitsetu teardown` has been refactored to cleanly remove the `Include` directive.
- **Diagnostic Tooling:** `gitsetu doctor` has been updated to assert the integrity of the new `Include` directive architecture.

## [1.0.0] - 2026-05-10

The first official public release of GitSetu — a zero-dependency, pure Bash 3.2 CLI tool for automated Git multi-identity and SSH key management across Linux, macOS, and Windows.

### Added

#### Core Features
- **Identity Bootstrapping Engine:** Automated provisioning of Git identities with directory-scoped `includeIf` configuration, dedicated ED25519 SSH keypairs, and SSH host aliases.
- **Native Git Credential Broker:** Fully isolated HTTPS PAT management powered by macOS Keychain (`security`) and Linux (`secret-tool`), with automatic file-based fallback.
- **Identity Guard:** Global pre-commit hook (`gitsetu guard`) that blocks commits when `user.email` doesn't match the expected profile for the current directory.
- **Encrypted State Export:** `gitsetu backup` / `gitsetu restore` — bundles and encrypts all GitSetu state using OpenSSL (`-pbkdf2` / `-sha256`). Pre-flight safety net automatically backs up existing state before restore.
- **Sub-millisecond Shell Prompt:** `gitsetu prompt` for native `$PS1` integration using 100% Bash parameter expansion (zero subshells, ~2ms execution).
- **FIDO2 / YubiKey Support:** `ed25519-sk` hardware key generation with automatic fallback to software keys.
- **Custom SSH Key Paths:** Map and link arbitrary existing SSH keys to profiles.
- **Subshell-free Environment Overwrites:** `gitsetu run` executes commands with correct identity without spawning subshells.
- **`useConfigOnly` Security Boundary:** Commits outside mapped directories are blocked by default to prevent identity leakage.

#### Architecture
- **Zero-Dependency:** Pure Bash 3.2 — requires only `bash`, `git`, and `ssh-keygen`.
- **Cross-Platform:** Linux, macOS, Windows (Git Bash), WSL.
- **Atomic POSIX Locks:** `mkdir`-based directory locks with automatic stale lock reaping via atomic `mv` swap. EXIT trap verifies lock ownership (`cat pid == $$`) before deletion.
- **Atomic Filesystem Writes:** All config modifications use temp-file + atomic `mv`. No partial writes. Pre-registered cleanup array eliminates SIGINT temp file leaks.
- **Strict Idempotency:** Managed Block Protocol ensures safe re-execution — no duplicate entries, no user config corruption.
- **CRLF Self-Healing:** Automatic `\r` stripping for VirtualBox shared folder environments.

#### Testing & CI
- **165 automated tests** across 20 test suites covering: core logic, SSH, gitconfig, guard, credential broker, backup/restore, concurrency, teardown, validation, platform detection, and audit regressions.
- **Cross-platform CI:** GitHub Actions matrix (Ubuntu, macOS, Windows) with ShellCheck linting.
- **Manual QA Playbook:** 16-section integration test checklist (`docs/MANUAL_QA.md`) for pre-release verification.

#### Documentation
- **README:** Professional landing page with logo, terminal demo, feature table, ecosystem comparison, and one-command install.
- **Architecture Guide:** Internal mechanics documentation for contributors.
- **Troubleshooting Guide:** Common SSH, Git, and hook issues with solutions.
- **Prompt Library:** 19 AI-assisted development prompts (`docs/PROMPTS.md`).
- **Product Roadmap:** Feature planning document.
- **Manifesto:** Design philosophy and architectural constraints.

#### DevOps
- **Shell Autocompletion:** Rich TAB completion for subcommands and profile names (Bash/Zsh).
- **Enterprise CI/CD:** Dependabot, SECURITY.md, CODEOWNERS, YAML issue templates, PR lint, release drafter.
- **SHA-Pinned Actions:** All GitHub Actions pinned to exact commit SHAs for supply-chain security.

### Security
- **Vault encryption** uses OpenSSL with `-pbkdf2` key derivation. SIGINT during encryption registers temp archives with cleanup trap — no unencrypted leaks.
- **Keychain permissions** enforced with `chmod 600` after all writes (not before), preventing umask-default world-readable tokens.
- **Terminal echo restoration** in cleanup trap after `stty -echo` during password input.
- **Hook subversion detection** for locally overridden `core.hooksPath`.
- **No environment variable leaks:** `MANAGED_BLOCK` unset after use, `GITSETU_DEFAULT_SIGN` and `GITSETU_USE_PASSPHRASE` not exported.
