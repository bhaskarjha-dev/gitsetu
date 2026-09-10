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
Yes! GitSetu provides first-class support for Windows via **Git Bash** (included by default with Git for Windows) or **WSL**:
1. **CLI Execution**: You run the `gitsetu` commands inside Git Bash (or WSL).
2. **Native Windows Experience**: Because GitSetu compiles canonical Windows paths (`C:/path`) and case-insensitive `gitdir/i:` rules into `~/.gitconfig` and OpenSSH `~/.ssh/config`, the automatic identity switching and SSH key routing work natively everywhere across Windows—including **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, **VS Code**, and GUI Git clients.
3. **Git Credential Manager (GCM)**: GitSetu automatically integrates with Microsoft's native Git Credential Manager on Windows.
4. **Isolated Testing**: Want to test without touching your machine? Run `.\sandbox\launch_sandbox.bat` to test GitSetu safely inside a disposable Windows Sandbox VM.

**How does credential brokering work inside headless WSL or minimal Linux containers?**
If native DBus secret tools (`secret-tool`) or GUI keychains are unavailable inside standard headless environments, GitSetu securely falls back to provisioning an isolated, restricted permissions vault file located at `~/.config/gitsetu/.tokens`. This file is strictly set to POSIX `600` permissions upon creation to guarantee containment.

---

### Zero-Trust Architecture & Edge Cases

**What happens if I have nested workspace folders (e.g. `~/work/` and `~/work/clients/acme/`)?**
GitSetu and Git resolve nested directory structures using **longest-prefix matching**. The most specific (longest) directory path takes precedence. When you navigate into `~/work/clients/acme/my-repo`, Git and GitSetu's guard and prompt engines match the `acme` profile rather than the parent `work` profile.

**Can I run `gitsetu setup` multiple times without losing my existing profiles?**
Yes. GitSetu is fully re-entrant and non-destructive. Running `gitsetu setup` automatically loads and re-hydrates existing profiles from `~/.config/gitsetu/profiles.conf`, allowing you to safely review, modify, or add profiles without overwriting your existing identities or SSH keys.

**Does GitSetu automatically create workspace directories if they don't exist yet?**
Yes. Whenever a profile is registered—whether through `gitsetu setup` or `gitsetu add`—GitSetu automatically provisions the target directory path using `mkdir -p`. In `--dry-run` mode, directory creation is simulated without filesystem mutation.

**How does GitSetu handle commits in unmapped or random directories?**
By default, GitSetu sets `[user] useConfigOnly = true` in the managed Git configuration, which causes Git to halt commits if no identity is matched, preventing accidental identity leaks. If you register a profile with an empty directory (`""`), GitSetu places that profile in a top-level `[include]` directive before conditional `[includeIf]` rules, establishing it as a safe global fallback identity for unmapped directories.
