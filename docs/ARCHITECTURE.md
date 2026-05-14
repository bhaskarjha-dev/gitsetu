# GitSetu Architecture Guide

Welcome to the internal mechanics of GitSetu. This document serves as a high-level roadmap for contributors looking to understand how GitSetu achieves robust identity management using zero dependencies and pure Bash 3.2.

> For the design philosophy and market positioning behind these decisions, see the [Design Manifesto](MANIFESTO.md).

## Core Philosophy: Single Source of Truth
GitSetu avoids long-running daemons. It operates strictly as a "configuration compiler." When you run `gitsetu setup`, the system parses your inputs, compiles the necessary standard files (`~/.gitconfig`, `~/.ssh/config`), and then completely exits.

Git itself is responsible for dynamic profile switching at runtime using the `includeIf` conditional.

## Subsystem Overviews

### 1. The Global Config Engine
When a profile is generated, GitSetu modifies `~/.gitconfig`.
It creates safe, demarcated blocks (e.g., `[gitsetu:managed:start]`).
Inside this block, it injects `[includeIf "gitdir:~/work/"] path = ~/.config/gitsetu/profiles/work.gitconfig`.

This means whenever your shell `cd`s into `~/work/`, Git natively intercepts this state and dynamically applies the `work.gitconfig` (which contains your Work Email and Work SSH Key), completely transparently.

### 2. The Identity Guard (Pre-Commit Hook)
To protect against dual-state leaks (e.g., configuring `gitsetu` but then accidentally modifying a local `.git/config` manually), GitSetu deploys a global `core.hooksPath`.
1. The global pre-commit hook fires.
2. It quickly parses `~/.config/gitsetu/profiles.conf` (The Single Source of Truth).
3. It detects the current directory.
4. It compares the expected profile email for that directory against the actual active `git config user.email`.
5. If they diverge, it triggers a fatal abort (`exit 1`), blocking the commit entirely.

### 3. The Native Credential Broker
Corporate firewalls often block SSH Port 22, forcing developers to use HTTPS and Personal Access Tokens (PATs).
However, macOS Keychain and Windows Credential Manager frequently merge credentials for the same hostname (e.g., `github.com`), leading to cross-profile pollution.

GitSetu solves this by setting itself as the global Git credential helper:
`[credential] helper = "/path/to/gitsetu credential"`

When Git pulls over HTTPS, it streams an authentication request to `gitsetu credential`. GitSetu uses the fast `cmd_prompt` algorithm to identify the active profile, then queries the OS Keychain for a profile-namespaced token (e.g., `gitsetu:work:github.com`), and injects it back to Git, completely isolating credentials.

### 4. Zero-Trust Atomic Operations
Because Bash scripts are vulnerable to race conditions (Time-of-Check to Time-of-Use), GitSetu performs all filesystem modifications atomically:
* File edits are written to a pre-registered randomized temporary path (`$TMPDIR/..._$$_${RANDOM}`) and then hot-swapped using an atomic `mv` to guarantee no `SIGINT` leaks.
* The `lib/guard.sh` file utilizes `mkdir` to establish an atomic system lock during multi-process operations.
* A unified `EXIT/SIGINT/SIGTERM` trap ensures that no orphaned lock files or raw credentials ever leak if the user mashes `Ctrl+C`.

## Module Map

GitSetu is composed of 15 library modules sourced by the main `gitsetu` script:

| Module | Responsibility |
|--------|---------------|
| `core.sh` | Version, XDG paths, 9 parallel state arrays, `load_profiles()`, `remove_profile_at_index()` |
| `platform.sh` | OS detection (`detect_os`), path normalization, gitdir keyword selection |
| `ui.sh` | Terminal output (`print_success/error/warning/info`), interactive prompts, banner |
| `validate.sh` | Input validation: emails, GitHub noreply, labels, path overlap detection |
| `setup.sh` | Interactive wizard, headless `cmd_add`/`cmd_profile`, blueprint execution, POSIX lock reaper |
| `gitconfig.sh` | `includeIf` block generation, managed block protocol, profile gitconfig, `profiles.conf` registry |
| `ssh.sh` | SSH key generation (ED25519/FIDO2), isolated OpenSSH `Include` directive alias management |
| `guard.sh` | Pre-commit identity guard hook installation, hook script generation, local hook pass-through |
| `doctor.sh` | Diagnostic checks: registry, SSH agent, managed blocks, configuration drift |
| `verify.sh` | Infrastructure verification: SSH key existence/permissions, gitconfig integrity |
| `backup.sh` | File-level timestamped backups, OpenSSL encrypted vault export/import |
| `teardown.sh` | Profile removal, managed block cleanup, deep local-repo identity stripping |
| `discovery.sh` | Auto-discovery: SSH key email extraction, gitconfig identity parsing, workspace detection |
| `keychain.sh` | Credential broker: file-based PAT storage with macOS Keychain / Linux `secret-tool` backends |
| `completion.sh` | TAB completion for Bash/Zsh: subcommands and profile name completion |

## Contributing Constraints
If you submit a Pull Request to GitSetu, you must adhere to the following:
1. **Zero External Dependencies**: No Python, no Node, no `awk` beyond basic POSIX compliance.
2. **Bash 3.2 Compatibility**: You may not use modern Bash 4+ features (like associative arrays `declare -A`) because GitSetu must run natively on outdated macOS systems.
3. **Zero-Trust Network Boundary**: GitSetu strictly prohibits background or telemetry network requests. The only permitted network call is the explicit, user-initiated `gitsetu update` command, which leverages Git's native TLS protocol over HTTPS.

