# Frequently Asked Questions

**Common inquiries regarding GitSetu's operational philosophy, architecture constraints, and security limits.**

---

### General Operations

**Why utilize global `includeIf` boundaries instead of simply running `git config --local` inside each repository?**
Manually typing `git config --local` commands inside every newly cloned repository introduces massive operational friction and inevitable human error. Developers frequently forget to execute the command, resulting in personal credentials instantly leaking into corporate branch history upon their first commit. GitSetu orchestrates `includeIf` interceptors to ensure identities swap flawlessly *before* the commit phase activates.

**Do I need Go, Python, or Node.js to execute GitSetu?**
No. GitSetu is compiled strictly utilizing un-obfuscated, POSIX-compliant Bash 3.2. It executes natively across macOS, modern Linux targets, and headless WSL container environments relying exclusively on core host utilities (`bash`, `git`, `ssh-keygen`).

**Will GitSetu corrupt my pre-existing global Git aliases?**
Absolutely not. GitSetu respects a strict *Managed Block Protocol*. It only manipulates internal strings wrapped specifically inside its own `[gitsetu:managed:start]` boundary markers. Your custom `[alias]`, `[core]`, and syntax formatting blocks are completely ignored and preserved safely.

---

### Security Boundaries

**Where does GitSetu store HTTPS Personal Access Tokens?**
GitSetu fundamentally rejects storing plain-text credentials inside unencrypted filesystems. The internal Credential Broker engine proxies authentication tokens directly into your host operating system's native encrypted layers (e.g., Apple Keychain Access on macOS, or the Secret Service DBus API natively via `secret-tool` on Linux environments). 

**Does GitSetu track telemetry or phone home?**
No. GitSetu contains zero tracking dependencies, zero background daemon listeners, and zero crash reporting capabilities. It acts entirely offline. The only network call executed natively is explicitly user-triggered via the `gitsetu update` command, which communicates securely with verifiable GitHub release channels.

---

### Windows & WSL

**Does GitSetu operate properly on native Windows environments?**
Because GitSetu leverages POSIX Bash mechanisms, it does not support native Windows PowerShell (`.ps1`) execution natively at this time. Windows developers **must** execute the tool utilizing **Windows Subsystem for Linux (WSL)** or the standard Git Bash emulator terminal environments. Native PowerShell wrappers are planned for Phase 1 of the official Product Roadmap.

**How does credential brokering work inside headless WSL?**
If native DBus secret tools are unavailable inside standard headless WSL distributions, GitSetu will securely fall back to provisioning an isolated, restricted permissions vault file located at `~/.config/gitsetu/credentials`.
