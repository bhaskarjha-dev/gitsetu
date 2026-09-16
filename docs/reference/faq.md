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

### Existing Manual Setups & Migration

**I already have manual `includeIf` configurations and custom `~/.ssh/config` host aliases. Will GitSetu overwrite or delete them?**
**No, absolutely not.** GitSetu is designed with a strict zero-destruction philosophy:
1. **In `~/.gitconfig`:** GitSetu writes exclusively between `# [gitsetu:managed:start]` and `# [gitsetu:managed:end]` sentinel markers. Any pre-existing manual `includeIf` directives, `[user]` identities, `[alias]` definitions, or custom configurations outside those markers remain completely untouched.
2. **In `~/.ssh/config`:** GitSetu never edits or reorders your existing `Host` blocks (such as `Host github-pro` or `Host personal`). It only prepends a single directive to the very top: `Include ~/.config/gitsetu/profiles/ssh_config`. All of your manual SSH aliases and key mappings underneath remain 100% functional and active.
3. **Pre-Modification Backups:** Before touching any configuration file, GitSetu automatically creates a timestamped backup in `~/.config/gitsetu/backups/` (`.gitconfig.<TIMESTAMP>.bak` and `config.<TIMESTAMP>.bak`).

**Do I have to start fresh from scratch if I already have manual profiles?**
**No.** GitSetu provides a smooth, automated transition via its built-in **Auto-Discovery Engine**:
- When you run `gitsetu setup --auto` (or during interactive `gitsetu setup`), the discovery engine parses your existing `~/.gitconfig` for existing `includeIf` directories, inspects `~/.ssh/` for existing keys (`id_ed25519_*`), and extracts emails from public keys.
- It pre-populates your profile blueprint with your existing paths and keys so you don't have to retype them.
- You can either choose **Peaceful Co-existence** (leave manual configs as-is and only use GitSetu for new profiles) or **Smooth Migration** (let GitSetu manage all profiles so you gain `gitsetu guard`, `gitsetu doctor`, and instant prompt status).

**What happens if both a manual `includeIf` and a GitSetu profile target the same folder?**
Git processes `~/.gitconfig` sequentially from top to bottom. If the same configuration key (such as `user.email`) is matched multiple times, Git's native precedence rule applies: **the last matching entry wins**. Because GitSetu's managed block is placed at the end of `~/.gitconfig`, GitSetu's profile will take precedence for that specific directory. For any other directories covered only by your manual configs, your manual setup continues to govern.

**What if I want to remove GitSetu and go back to my manual setup?**
Run `gitsetu teardown`. GitSetu will surgically excise only its managed block from `~/.gitconfig`, remove the `Include` line from `~/.ssh/config`, and remove `~/.config/gitsetu/`. Your manual `includeIf` blocks, SSH keys, and custom settings remain intact in their original state.

---

### Security Boundaries

**Where does GitSetu store HTTPS Personal Access Tokens?**
GitSetu fundamentally rejects storing plain-text credentials inside unencrypted filesystems. The internal Credential Broker engine proxies authentication tokens directly into your host operating system's native encrypted layers (e.g., Apple Keychain Access on macOS, or the Secret Service DBus API natively via `secret-tool` on Linux environments). 

**Does GitSetu track telemetry or phone home?**
No. GitSetu contains zero tracking dependencies, zero background daemon listeners, and zero crash reporting capabilities. It acts entirely offline. The only network call executed natively is explicitly user-triggered via the `gitsetu update` command, which communicates securely with verifiable GitHub release channels.

---

### Windows & WSL

**What are the prerequisites for running GitSetu on Windows?**
The only prerequisite on Windows is **Git for Windows** (which provides standard `git.exe` and `bash.exe`). You can install it via:
```powershell
winget install Git.Git
# Or download directly from: https://git-scm.com/download/win
```
Once Git for Windows is installed, GitSetu requires zero external runtimes (no Node.js, Python, or Go). GitSetu provides native Windows command shims (`gitsetu.cmd`, `gitsetu.ps1`, `gitsetu.exe`) so you can run all commands directly from **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, and **VS Code**.

**Why does WinGet use `winget install BhaskarJha.GitSetu` instead of `winget install GitSetu`?**
Microsoft's official Windows Package Manager repository requires every package to have a unique, collision-proof Package Identifier formatted as `Publisher.PackageName`. `BhaskarJha.GitSetu` is the canonical identifier. Once WinGet updates its local search indexes, typing `winget install GitSetu` also automatically resolves to the official package.

**Does GitSetu operate properly on native Windows environments?**
Yes! GitSetu provides first-class support for Windows. When installed via `install.ps1`, WinGet, Scoop, or npm, GitSetu creates native command shims (`gitsetu.cmd`, `gitsetu.ps1`) so you can run `gitsetu` directly from **PowerShell**, **Command Prompt**, **Windows Terminal**, or **VS Code** — no need to open Git Bash.
1. **CLI Execution**: Run `gitsetu` commands from any Windows shell — PowerShell, CMD, Git Bash, or WSL.
2. **Native Windows Experience**: Because GitSetu compiles canonical Windows paths (`C:/path`) and case-insensitive `gitdir/i:` rules into `~/.gitconfig` and OpenSSH `~/.ssh/config`, the automatic identity switching and SSH key routing work natively everywhere across Windows—including **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, **VS Code**, and GUI Git clients.
3. **Git Credential Manager (GCM)**: GitSetu automatically integrates with Microsoft's native Git Credential Manager on Windows.
4. **Isolated Testing**: Want to test without touching your machine? Run `.\sandbox\launch_sandbox.ps1` (or `launch_sandbox.bat`) to test GitSetu safely inside a disposable Windows Sandbox VM.

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
