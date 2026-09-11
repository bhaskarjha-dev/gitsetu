<div align="center">

<img src="docs/assets/logo.png" alt="GitSetu" width="200" />

# GitSetu

**The bridge between your identities and your repositories.**

*Zero deps. No daemon. Pure Bash.*

[![CI](https://github.com/bhaskarjha-dev/gitsetu/actions/workflows/ci.yml/badge.svg)](https://github.com/bhaskarjha-dev/gitsetu/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=gnu-bash&logoColor=white)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/github/license/bhaskarjha-dev/gitsetu?color=blue)](LICENSE)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-orange?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Tests](https://img.shields.io/badge/tests-33%20suites%20passing-brightgreen)]()
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macos%20%7C%20windows-lightgrey)]()

</div>

<br/>

<p align="center">
  <img src="docs/assets/demo.png" alt="GitSetu Terminal Demo" width="600" />
</p>

<br/>

## What is GitSetu?

GitSetu is a zero-dependency, self-updating pipeline that automatically generates your SSH keys and Git configs within a Zero-Trust architecture, automatically provisions workspace directories (`mkdir -p`), integrates natively with OS credential managers (including Windows Credential Manager), and instantly switches identities based on your directory. 

Stop pushing freelance projects with your corporate email. Stop fighting "Port 22 blocked" errors. 

**One setup. Automatic forever.** Runs seamlessly across **Linux**, **macOS**, and **Windows** (Git Bash, PowerShell, CMD, VS Code).

## Installation

### Instant Zero-Prompt Run (Node / npx)
```bash
npx gitsetu setup --auto
```

### Linux & macOS (POSIX Shell)
```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.sh | bash
# Or via Homebrew: brew tap bhaskarjha-dev/tap && brew install gitsetu
```

### Windows (PowerShell)
Open **PowerShell** or **Windows Terminal** and run:
```powershell
irm https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.ps1 | iex
```
*(Also installable via **WinGet**: `winget install BhaskarJha.GitSetu`, **Scoop**: `scoop install gitsetu`, or **npm**: `npm i -g gitsetu`)*

> [!NOTE]
> On Windows, once configured, automatic identity switching works natively everywhere—in **PowerShell**, **Command Prompt**, **Windows Terminal**, and **VS Code**.
> Want to test risk-free in an isolated VM? Check out the [Windows Sandbox Test Harness](sandbox/README.md).

## Documentation

- 🚀 **[Getting Started & Quickstart](docs/getting-started/quickstart.md)**
- 📥 **[Installation Guide](docs/getting-started/installation.md)**
- 🧠 **[Identity Routing Engine](docs/core-engines/identity-routing.md)**
- 🛡️ **[Security & Privacy](docs/enterprise/security-privacy.md)**
- 📖 **[CLI Command Reference](docs/reference/cli-commands.md)**
- 🏗️ **[System Architecture](docs/overview/architecture.md)**
- 🔧 **[Troubleshooting & Diagnostics](docs/reference/troubleshooting.md)**
- ❓ **[FAQ](docs/reference/faq.md)**

---

## The Value Proposition

| Problem | GitSetu Fix |
|---------|-------------|
| 🔴 **Wrong author commits** | Directory-scoped `includeIf` auto-switches identity |
| 🔴 **SSH key collisions** | Dedicated ED25519 keypair per profile |
| 🔴 **Corrupted `~/.ssh/config`** | Zero-Trust OpenSSH `Include` architecture |
| 🔴 **HTTPS PAT Chaos** | Per-profile credential broker via OS keychain (macOS Keychain, Linux Secret Service, Windows Credential Manager) |
| 🔴 **Manual directory setup** | Auto-provisions workspace folders (`mkdir -p`) on registration |
| 🔴 **Tool rot & dependency hell** | Pure Bash 3.2. Zero dependencies. Native auto-updater. |

---

## License

MIT License. See [LICENSE](LICENSE) for more information.
