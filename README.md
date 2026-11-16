<div align="center">

<img src="docs/assets/logo.png" alt="GitSetu" width="140" />

# GitSetu

**One command. All identities. Every machine.**

*Stop pushing freelance commits with your corporate email.*

[![CI](https://github.com/bhaskarjha-dev/gitsetu/actions/workflows/ci.yml/badge.svg)](https://github.com/bhaskarjha-dev/gitsetu/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/bhaskarjha-dev/gitsetu?color=blue)](LICENSE)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-orange?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macos%20%7C%20windows-lightgrey)](#cross-platform)
[![Website](https://img.shields.io/badge/docs-gitsetu.bhaskarjha.dev-00c4cc)](https://gitsetu.bhaskarjha.dev)

<br/>

<img src="docs/assets/demo.jpg" alt="GitSetu — zero-prompt setup and identity status" width="700" />

<br/>

[Getting Started](#getting-started) · [How It Works](#how-it-works) · [Features](#features) · [Installation](#installation) · [Documentation](#documentation)

</div>

<br/>

## The Problem

You have a work GitHub, a personal GitHub, maybe a freelance GitLab. Every day you juggle SSH keys, `.gitconfig` conditionals, and credential helpers — and one mistake means a commit with the wrong email that lives in history forever.

Existing solutions require Go binaries, YAML configs, or manual `includeIf` wrangling. They solve half the problem and break on Windows.

## The Fix

```bash
gitsetu setup --auto
```

GitSetu scans your machine, discovers your existing Git identities, and **in one command** generates SSH keys, wires `includeIf` routing, configures credential helpers, and provisions workspace directories. Then it exits. No daemon. No background process. Git and OpenSSH handle everything natively from that point forward.

**Pure Bash 3.2 core. Native Git and OpenSSH integration. Optional platform stores and OpenSSL are detected explicitly.**

> **Release:** GitSetu v1.1.0 is released via GitHub Releases and npm. See [Installation](#installation) and [Security Policy](SECURITY.md).

---

## Getting Started

### Quick Start

```bash
# Install the latest release
curl -fsSL https://github.com/bhaskarjha-dev/gitsetu/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"

# Add a profile
gitsetu add work "Your Name" you@company.com ~/work

# Verify configuration
gitsetu status
```

Add the printed public key at [github.com/settings/ssh/new](https://github.com/settings/ssh/new), then run:
```bash
GITSETU_VERIFY_NETWORK=1 gitsetu verify
```

### What Just Happened?

GitSetu compiled native configuration into three places and exited:

```
~/.gitconfig          ← includeIf rules route identity by directory
~/.ssh/config         ← Include directive sandboxes SSH host aliases
~/.config/gitsetu/    ← Versioned profile registry and managed configs/keys
```

There is no daemon. There is no runtime. Git and OpenSSH evaluate these rules natively on every operation.

> [!NOTE]
> **Managed-file safety:** GitSetu writes only its own generated profile files and marked configuration blocks. Existing manual `includeIf` rules, aliases, and unrelated `~/.ssh/config` host blocks are left outside those blocks. `setup --auto` can discover existing identities; review the proposed changes before applying them.

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│  $ cd ~/work && git commit                              │
│                                                         │
│  Git reads ~/.gitconfig                                 │
│    → includeIf "gitdir:~/work/" matches                 │
│    → loads ~/.config/gitsetu/profiles/work.gitconfig     │
│    → user.name = "Dev Name"                             │
│    → user.email = "dev@company.com"                     │
│    → core.sshCommand = ssh -i ~/.ssh/id_ed25519_work    │
│                                                         │
│  ✓ Correct identity. Correct SSH key. Zero intervention.│
└─────────────────────────────────────────────────────────┘
```

GitSetu is a **configuration compiler**, not a daemon. It generates rules once; Git and OpenSSH evaluate them on each operation, subject to their own configuration semantics and performance.

---

## Features

### Core

| Feature | Description |
|---------|-------------|
| **Auto-Discovery** | `setup --auto` scans your machine for existing Git identities and SSH keys |
| **Directory Routing** | `includeIf` rules auto-switch identity when you `cd` into a project |
| **SSH Key Generation** | Ed25519 keypairs per profile, with FIDO2/YubiKey support |
| **Credential Routing** | Per-profile HTTPS username routing delegating authentication to Git's native credential ecosystem |
| **Pre-Commit Guard** | Blocks commits in managed repositories when the effective identity is unresolved or divergent; unmanaged repositories fail open |
| **Authenticated Backup** | `gitsetu backup` exports managed keys and configuration in an authenticated v2 vault; old vault formats are rejected |

### Developer Experience

| Feature | Description |
|---------|-------------|
| **Context Runner** | `gitsetu run work -- git push` executes commands under a specific identity |
| **Shell Prompt** | `gitsetu prompt` returns the active profile label for `$PS1` / Starship integration |
| **Doctor** | `gitsetu doctor` runs diagnostic checks on your entire identity infrastructure |
| **Verify** | `gitsetu verify` checks key files, managed configuration, and effective identities; network checks are opt-in with `GITSETU_VERIFY_NETWORK=1` |
| **Completions** | Bash and Zsh tab completion with profile suggestions: `source lib/completion.sh` from a checkout or the npm package (the release installer doesn't install it) |

### Cross-Platform

| | Linux | macOS | Windows |
|--|:-----:|:-----:|:-------:|
| **Shell Support** | Bash, Zsh | Bash, Zsh | Git Bash, PowerShell, CMD, VS Code |
| **SSH Keys** | ✓ | ✓ | ✓ (NTFS-aware permissions) |
| **Credential Delegation** | libsecret | Keychain (`osxkeychain`) | Git Credential Manager |
| **CRLF Handling** | — | — | 4-tier self-healing cascade |
| **Installer** | Release installer or npm | Release installer or npm | Release installer in Git Bash; `install.ps1` from a checkout for PowerShell and CMD |

---

## Installation

### Linux, macOS, WSL and Git Bash

```bash
curl -fsSL https://github.com/bhaskarjha-dev/gitsetu/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```

The installer downloads the release's single-file `gitsetu`, checks its SHA-256 and size against the values pinned in the installer, and installs it under `~/.local/share/gitsetu`, with the `gitsetu` and `git-setu` commands in `~/.local/bin`. It needs Bash, `curl` or `wget`, and `sha256sum` or `shasum`. When the GitHub CLI is installed and logged in, it also verifies the release's build attestation.

### npm (all platforms)

Requires Node.js 18 or later:

```bash
npm install -g gitsetu
```

### Windows (PowerShell and CMD)

> **Prerequisite:** [Git for Windows](https://git-scm.com/download/win) (`winget install Git.Git`).

In Git Bash, the installer above works as on Linux. To use `gitsetu` from PowerShell and CMD, install from a checkout of the release tag:

```powershell
git clone https://github.com/bhaskarjha-dev/gitsetu
cd gitsetu
git checkout v1.1.0
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` builds the native launcher, creates `gitsetu.cmd` in `%LOCALAPPDATA%\gitsetu\bin`, and can add that folder to your user PATH.

### From source

From a clean checkout on Linux, macOS or Git Bash, `bash install.sh` builds the single-file bundle and installs it. Building the bundle needs Node.js 18 or later.

> [!NOTE]
> On Windows, once configured, automatic identity switching works natively everywhere — PowerShell, CMD, Windows Terminal, VS Code, and JetBrains IDEs. No shell hook required.

---

## Usage

### Interactive Setup

```bash
gitsetu setup
```

Walks you through creating profiles one at a time. Generates SSH keys, creates `includeIf` rules, provisions directories.

### Non-TTY Auto Setup

```bash
gitsetu setup --auto
```

Scans your machine for existing Git identities and applies the discovered blueprint without interactive input in non-TTY use. In a TTY, setup can still ask about guard installation or an explicit FIDO2 fallback; use interactive `gitsetu setup` when you need a review step.

### Add a Profile Non-Interactively

```bash
gitsetu add work "Your Name" dev@company.com ~/work
```

### Day-to-Day Commands

```bash
# See all profiles and which is active
gitsetu status

# Verify SSH keys and config integrity
gitsetu verify

# Run diagnostic checks
gitsetu doctor

# Run a command as a specific profile
gitsetu run work -- git push origin main

# Install pre-commit identity guard
gitsetu guard --install

# Create an authenticated v2 vault
gitsetu backup

# Restore on a new machine (v2 vaults only)
gitsetu restore /path/to/gitsetu_vault_YYYYMMDD_HHMMSS.gitsetu-v2.vault

# Clean removal of all GitSetu configs
gitsetu teardown
```

---

## Why GitSetu?

- **Native, then gone.** It writes plain Git `includeIf` rules and an OpenSSH `Include`, then exits: no daemon, no shell hook, no wrapper around `git`.
- **Your setup keeps working.** It writes only its own files and marked blocks, so your `includeIf` rules, `Host` aliases, hooks and signing settings stay in effect.
- **One key per identity.** An Ed25519 or FIDO2 key per profile, pinned with `IdentitiesOnly` and kept out of the SSH agent.
- **Guard rails when you want them.** An opt-in pre-commit guard blocks commits with the wrong identity in managed repositories, and `gitsetu audit` checks existing history.
- **Portable.** Linux, macOS (Bash 3.2), WSL and Windows (Git Bash, PowerShell, CMD), with an authenticated backup vault to move a setup between machines.

See [how it compares →](docs/overview/comparisons.md)

---

## Documentation

> **📘 [gitsetu.bhaskarjha.dev →](https://gitsetu.bhaskarjha.dev)**

| Guide | Description |
|-------|-------------|
| [Quickstart](docs/getting-started/quickstart.md) | 4-step setup guide |
| [Installation](docs/getting-started/installation.md) | All installation methods |
| [CLI Reference](docs/reference/cli-commands.md) | Every command, flag, and option |
| [Architecture](docs/overview/architecture.md) | How the configuration compiler works |
| [Identity Routing](docs/core-engines/identity-routing.md) | Deep dive into `includeIf` engine |
| [SSH Orchestrator](docs/core-engines/ssh-orchestrator.md) | Key generation and host alias routing |
| [HTTPS Credentials](docs/core-engines/https-credentials.md) | Per-profile HTTPS username with your platform's credential helper |
| [Pre-Commit Guard](docs/core-engines/precommit-guard.md) | Fail-closed identity verification |
| [Hardware Keys](docs/guides/hardware-keys.md) | FIDO2 / YubiKey setup |
| [Vault Backups](docs/guides/vault-backups.md) | Encrypted export/import |
| [Shell Prompt](docs/guides/shell-prompt.md) | PS1 / Starship integration |
| [WSL Integration](docs/guides/wsl-integration.md) | Windows Subsystem for Linux |
| [Security & Privacy](docs/enterprise/security-privacy.md) | Threat model and security posture |
| [Troubleshooting](docs/reference/troubleshooting.md) | Common issues and fixes |
| [FAQ](docs/reference/faq.md) | Frequently asked questions |

---

## Testing

GitSetu has comprehensive automated test coverage validated in CI: the full test suite on Linux and macOS, and the end-to-end harness and native PowerShell suites on Windows.

```bash
# Run all test suites (Linux & macOS)
bash tests/run_all.sh

# Run end-to-end cleanroom harness (Linux, macOS, and Windows Git Bash)
bash tests/e2e_installed.sh

# Run tests against bundled artifact
make dist-check
make test-bundle
```

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a PR.

```bash
# Fork & clone
git clone https://github.com/YOUR_USERNAME/gitsetu.git
cd gitsetu

# Run tests
bash tests/run_all.sh

# Check shell quality for the files changed
shellcheck gitsetu lib/*.sh tests/*.sh
```

See also: [Code of Conduct](CODE_OF_CONDUCT.md) · [Security Policy](SECURITY.md)

---

## License

MIT — see [LICENSE](LICENSE).

<div align="center">

**[Website](https://gitsetu.bhaskarjha.dev)** · **[Documentation](docs/getting-started/quickstart.md)** · **[Changelog](CHANGELOG.md)** · **[Report a Bug](https://github.com/bhaskarjha-dev/gitsetu/issues/new?template=bug_report.yml)**

</div>
