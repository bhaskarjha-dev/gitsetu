<div align="center">

<img src="docs/assets/logo.png" alt="GitSetu" width="200" />

# GitSetu

**The bridge between your identities and your repositories.**

*Zero deps. No daemon. Pure Bash.*

[![CI](https://github.com/bhaskarjha-com/gitsetu/actions/workflows/ci.yml/badge.svg)](https://github.com/bhaskarjha-com/gitsetu/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?logo=gnu-bash&logoColor=white)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/github/license/bhaskarjha-com/gitsetu?color=blue)](LICENSE)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-orange?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Tests](https://img.shields.io/badge/tests-168%20passing-brightgreen)]()
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macos%20%7C%20windows-lightgrey)]()

</div>

<br/>

<p align="center">
  <img src="docs/assets/demo.png" alt="GitSetu Terminal Demo" width="600" />
</p>

<br/>

## What is GitSetu?

GitSetu is a zero-dependency, self-updating pipeline that automatically generates your SSH keys and Git configs within a Zero-Trust architecture, then instantly switches them based on your directory. 

Stop pushing freelance projects with your corporate email. Stop fighting "Port 22 blocked" errors. 

**One setup. Automatic forever.**

## Installation

```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-com/gitsetu/main/install.sh | bash
```

## Documentation

The complete documentation has been moved to our Enterprise Portal structure.

- 🚀 **[Getting Started](docs/getting-started/quickstart.md)**
- 🧠 **[Core Concepts (Identity Routing)](docs/core-concepts/identity-routing.md)**
- 🛡️ **[Security & Privacy](docs/enterprise/security-privacy.md)**
- 📖 **[CLI Command Reference](docs/reference/cli-commands.md)**
- 🏗️ **[Internal Architecture](docs/project/architecture.md)**

---

## The Value Proposition

| Problem | GitSetu Fix |
|---------|-------------|
| 🔴 **Wrong author commits** | Directory-scoped `includeIf` auto-switches identity |
| 🔴 **SSH key collisions** | Dedicated ED25519 keypair per profile |
| 🔴 **Corrupted `~/.ssh/config`** | Zero-Trust OpenSSH `Include` architecture |
| 🔴 **HTTPS PAT Chaos** | Per-profile credential broker via OS keychain |
| 🔴 **Tool rot & dependency hell** | Pure Bash 3.2. Zero dependencies. Native auto-updater. |

---

## License

MIT License. See [LICENSE](LICENSE) for more information.
