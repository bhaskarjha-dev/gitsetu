# Frequently Asked Questions

**Common inquiries regarding GitSetu's operational philosophy, architecture constraints, and security limits.**

---

### General Operations

**Why utilize global `includeIf` boundaries instead of simply running `git config --local` inside each repository?**
Manually typing `git config --local` commands inside every newly cloned repository introduces operational friction and human error. GitSetu reduces that repetition by routing managed directories through `includeIf`; review the effective identity before committing.

**Do I need Go, Python, or Node.js to execute GitSetu?**
No. GitSetu is plain Bash 3.2-compatible source and uses standard Git/OpenSSH tools. Optional native credential stores and OpenSSL are detected explicitly; unavailable optional features fail clearly.

**Will GitSetu corrupt my pre-existing global Git aliases?**
GitSetu writes only its own generated profile files and marked managed blocks. Unrelated custom aliases, core settings, and SSH host blocks are left outside those managed regions; review the staged changes if you keep important manual configuration nearby.

---

### Existing Manual Setups & Coexistence

**I already have manual `includeIf` configurations and custom `~/.ssh/config` host aliases. Will GitSetu overwrite or delete them?**
GitSetu is designed to minimize destructive changes. It edits only its own marked blocks and generated files, but a malformed marker or unsafe target causes it to stop rather than guess:
1. **In `~/.gitconfig`:** GitSetu writes between `# [gitsetu:managed:start]` and `# [gitsetu:managed:end]` sentinel markers. Manual `includeIf` directives, identities, aliases, and other settings outside those markers are left for Git and the user to manage; review the effective configuration.
2. **In `~/.ssh/config`:** GitSetu writes one managed `Include` directive and keeps generated host aliases in its private file. Unrelated manual SSH host blocks remain outside the managed region; if the target is ambiguous or redirected, GitSetu refuses to edit it.
3. **Pre-Modification Backups:** Before touching any configuration file, GitSetu automatically creates a timestamped backup in `~/.config/gitsetu/backups/` (`.gitconfig.<TIMESTAMP>.bak` and `config.<TIMESTAMP>.bak`).

**Do I have to start fresh from scratch if I already have manual profiles?**
No. `gitsetu setup --auto` can inspect existing Git and SSH configuration and pre-populate a proposal for review. This is discovery, not a migration path for GitSetu's old registry format. You can keep manual configuration outside GitSetu's managed blocks or explicitly adopt the proposed profiles.

**What happens if both a manual `includeIf` and a GitSetu profile target the same folder?**
Git processes conditional includes in configuration order. GitSetu emits and tests deterministic parent/child rules so the intended most-specific managed profile wins; manual rules outside the managed block remain Git's responsibility. Check the effective values with `git config --show-origin` if both systems match the same path.

**What if I want to remove GitSetu and go back to my manual setup?**
Run `gitsetu teardown`. It removes only recognized managed blocks and files, preserves private keys by default, and refuses ambiguous or unsafe targets. Review the generated backup if you need to compare the resulting configuration.

---

### Security Boundaries

**Where does GitSetu store HTTPS Personal Access Tokens?**
GitSetu prefers native OS credential stores. On a minimal system without a native store, an explicitly selected zero-dependency backend can use a warned-about plaintext `~/.config/gitsetu/.tokens` file with strict permissions; it is not encrypted and does not protect against same-user malware.

**Does GitSetu track telemetry or phone home?**
No. GitSetu contains no telemetry or background daemon. Network access is limited to explicit operations such as first-use discovery/SSH verification and optional authenticated GitHub CLI actions. Local validation and dry-run do not intentionally contact the network.

---

### Windows & WSL

**What are the prerequisites for running GitSetu on Windows?**
The only prerequisite on Windows is **Git for Windows** (which provides standard `git.exe` and `bash.exe`). You can install it via:
```powershell
winget install Git.Git
# Or download directly from: https://git-scm.com/download/win
```
Once Git for Windows is installed, GitSetu requires zero external runtimes (no Node.js, Python, or Go). GitSetu provides native Windows command shims (`gitsetu.cmd`, `gitsetu.ps1`, `gitsetu.exe`) so you can run all commands directly from **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, and **VS Code**.

**Why is there no WinGet installation command for the release candidate?**
The v1.1.0 WinGet manifest is deliberately withheld until an intentional
release. `BhaskarJha.GitSetu` is reserved for that future, pinned manifest; do
not install an unreleased or mutable package. Use `install.ps1` from a reviewed
checkout for local testing.

**Does GitSetu operate properly on native Windows environments?**
Yes! GitSetu provides first-class support for Windows. The development
`install.ps1` path creates native command shims (`gitsetu.cmd`, `gitsetu.ps1`,
and `gitsetu.exe`) so you can run `gitsetu` directly from **PowerShell**,
**Command Prompt**, **Windows Terminal**, or **VS Code** — no need to open
Git Bash. Public package-manager shims remain withheld until release.
1. **CLI Execution**: Run `gitsetu` commands from any Windows shell — PowerShell, CMD, Git Bash, or WSL.
2. **Native Windows Experience**: Because GitSetu compiles canonical Windows paths (`C:/path`) and case-insensitive `gitdir/i:` rules into `~/.gitconfig` and OpenSSH `~/.ssh/config`, the automatic identity switching and SSH key routing work natively everywhere across Windows—including **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, **VS Code**, and GUI Git clients.
3. **Git Credential Manager (GCM)**: GitSetu automatically integrates with Microsoft's native Git Credential Manager on Windows.
4. **Isolated Testing**: Want to test without touching your machine? Run `.\sandbox\launch_sandbox.ps1` (or `launch_sandbox.bat`) to test GitSetu safely inside a disposable Windows Sandbox VM.

**How does credential brokering work inside headless WSL or minimal Linux containers?**

If native DBus secret tools or GUI keychains are unavailable, native-store operations fail with an explanation. A user who explicitly selects the zero-dependency backend can use `GITSETU_CREDENTIAL_BACKEND=file`; GitSetu then writes a warned-about **plaintext** `~/.config/gitsetu/.tokens` file with a `0700` directory and `0600` file. It is permission-restricted, not encrypted and not protected from another process running as the same user.

---

### Zero-Trust Architecture & Edge Cases

**What happens if I have nested workspace folders (e.g. `~/work/` and `~/work/clients/acme/`)?**
GitSetu and Git resolve nested directory structures using **longest-prefix matching**. The most specific (longest) directory path takes precedence. When you navigate into `~/work/clients/acme/my-repo`, Git and GitSetu's guard and prompt engines match the `acme` profile rather than the parent `work` profile.

**Can I run `gitsetu setup` multiple times without losing my existing profiles?**
Yes, for the current v2 registry. Running `gitsetu setup` reloads the versioned, strictly escaped registry and its managed profile configs, allowing review, modification, or addition without replacing unrelated SSH keys. The old colon-delimited registry is rejected; there is no migration reader.

**Does GitSetu automatically create workspace directories if they don't exist yet?**
Yes. Whenever a profile is registered—whether through `gitsetu setup` or `gitsetu add`—GitSetu automatically provisions the target directory path using `mkdir -p`. In `--dry-run` mode, directory creation is simulated without filesystem mutation.

**How does GitSetu handle commits in unmapped or random directories?**
By default, GitSetu sets `[user] useConfigOnly = true` in the managed Git configuration, which causes Git to halt commits if no identity is matched, preventing accidental identity leaks. Only the mandatory `global` profile may have an empty directory (`""`); GitSetu places that profile in a top-level `[include]` directive before conditional `[includeIf]` rules. Other profiles require a canonical, non-empty directory so ambiguous global fallbacks are rejected.
