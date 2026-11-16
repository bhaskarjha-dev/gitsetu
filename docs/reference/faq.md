# Frequently Asked Questions

**Common inquiries regarding GitSetu's operational philosophy, architecture constraints, and security limits.**

---

### General Operations

**Why utilize global `includeIf` boundaries instead of simply running `git config --local` inside each repository?**
Manually typing `git config --local` commands inside every newly cloned repository introduces operational friction and human error. GitSetu reduces that repetition by routing managed directories through `includeIf`; review the effective identity before committing.

**Do I need Go, Python, or Node.js to execute GitSetu?**
No for the Bash CLI itself. GitSetu's runtime uses Bash 3.2-compatible source and standard Git/OpenSSH tools. Node.js is used by the repository's tests, packaging, and release-preparation scripts; those are development/build tool requirements, not a runtime dependency of the installed shell CLI. Optional native credential stores and OpenSSL are detected explicitly; unavailable optional features fail clearly.

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
`gitsetu setup --auto` is an apply mode: it discovers a blueprint and writes it directly. It is non-blocking in non-TTY use, but a TTY setup may still ask about guard installation or an explicit FIDO2 fallback. Use interactive `gitsetu setup` when review is required. This is discovery, not a migration path for GitSetu's old registry format. You can keep manual configuration outside GitSetu's managed blocks or explicitly adopt the proposed profiles.

**What happens if both a manual `includeIf` and a GitSetu profile target the same folder?**
Git processes conditional includes in configuration order. GitSetu emits and tests deterministic parent/child rules so the intended most-specific managed profile wins; manual rules outside the managed block remain Git's responsibility. Check the effective values with `git config --show-origin` if both systems match the same path.

**What if I want to remove GitSetu and go back to my manual setup?**
Run `gitsetu teardown`. It removes only recognized managed blocks and files, preserves private keys by default, and refuses ambiguous or unsafe targets. Review the generated backup if you need to compare the resulting configuration.

---

### Security Boundaries

**Where does GitSetu store HTTPS Personal Access Tokens?**
GitSetu does not store personal access tokens. Instead, it delegates HTTPS authentication directly to Git's native credential-helper ecosystem (Git Credential Manager on Windows, Apple Keychain on macOS, or Secret Service on Linux) by configuring per-profile `credential.https://<host>.username` directives.

**Does GitSetu track telemetry or phone home?**
No. GitSetu contains no telemetry or background daemon. Network access is limited to explicit operations such as first-use discovery/SSH verification and optional authenticated GitHub CLI actions. The current dry-run guards suppress the known remote probes and credential writes, but an offline guarantee still depends on the commands and environment selected by the operator.

---

### Windows & WSL

**What are the prerequisites for running GitSetu on Windows?**
The only prerequisite on Windows is **Git for Windows** (which provides standard `git.exe` and `bash.exe`). You can install it via:
```powershell
winget install Git.Git
# Or download directly from: https://git-scm.com/download/win
```
Once Git for Windows is installed, the installed program needs no other runtime (no Node.js, Python, or Go). Installed with `install.ps1`, GitSetu provides `gitsetu.cmd`, backed by the native `gitsetu.exe` launcher, so you can run all commands directly from **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, and **VS Code**.

**Which package managers can install GitSetu?**
npm (`npm install -g gitsetu`). No other package manager ships v1.1.0. Use the
release installer in Git Bash, or `install.ps1` from a checkout of the release
tag for PowerShell and CMD.

**Does GitSetu operate properly on native Windows environments?**
Yes. `install.ps1` creates the native `gitsetu.cmd` command shim, backed by
the `gitsetu.exe` launcher, so you can run `gitsetu` directly from
**PowerShell**, **Command Prompt**, **Windows Terminal**, or **VS Code**, with
no need to open Git Bash.
1. **CLI Execution**: Run `gitsetu` commands from any Windows shell — PowerShell, CMD, Git Bash, or WSL.
2. **Native Windows Experience**: Because GitSetu compiles canonical Windows paths (`C:/path`) and case-insensitive `gitdir/i:` rules into `~/.gitconfig` and OpenSSH `~/.ssh/config`, the automatic identity switching and SSH key routing work natively everywhere across Windows—including **PowerShell**, **Command Prompt (CMD)**, **Windows Terminal**, **VS Code**, and GUI Git clients.
3. **Git Credential Manager (GCM)**: On Windows, Git seamlessly routes HTTPS credentials to GCM, partitioned by each profile's configured username.

**How does HTTPS authentication work inside headless WSL or minimal Linux containers?**

GitSetu configures `credential.https://<host>.username` in each profile. In WSL, you can point Git's helper to Windows GCM (`git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"`). In minimal Linux containers without GUI keychains, standard Git helpers like `cache` (in-memory storage) or `store` can be configured globally to manage credentials.

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
