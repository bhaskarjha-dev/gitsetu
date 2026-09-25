# Troubleshooting & Diagnostics

**A comprehensive guide to rapidly surfacing and resolving environmental configuration drift.**

GitSetu is engineered to self-heal and fail-closed natively, but localized Git configurations, OS keychain constraints, and complex virtualization bounds frequently introduce obscure connectivity issues. This reference provides immediate resolution paths for the most common errors.

---

## ⚡ First-Line Defense: Built-in Scanners

Before executing manual log investigation, rely on GitSetu's built-in advanced diagnostic execution paths:

### `gitsetu status`
Surfaces configuration context. Run this inside the affected repository. It evaluates your current directory path against managed `includeIf` rules and states which identity Git currently resolves.

### `gitsetu doctor`
Runs offline structural, configuration, permission, and identity diagnostics. It does not test provider connectivity; use an explicit SSH or provider test for network failures.

---

## 🔑 OpenSSH Authentication Collisions

> [!WARNING]
> If a `git push` or `git fetch` operation hangs or immediately returns **`Permission denied (publickey)`**, your public SSH signature is either missing from your Git hosting provider, or OpenSSH is aggressively returning cached failures.

### Resolution: Unmapped Public Keys
If GitSetu generated a fresh keypair for your target profile, you **must** manually associate the public side of that signature with your upstream provider (GitHub, GitLab, Bitbucket).
1. Output the public signature: `cat ~/.ssh/id_ed25519_<profile>.pub`
2. Navigate to your provider's SSH Settings portal and paste the block exactly.
3. Verify connection manually using the generated alias when needed: `ssh -T git@github-<profile>` (for example, `github-work`).

> [!IMPORTANT]
> **"Key already exists" Error on GitHub:** GitHub strictly enforces a 1-to-1 mapping. Each SSH public key can only be attached to **ONE** GitHub account. If you see this error, you are trying to add a key to your `work` account that is already attached to your `personal` account. You must generate a unique key for each account (which `gitsetu setup` handles automatically).

> [!NOTE]
> **"Could not resolve hostname github-pro":** GitSetu generates aliases such as `github-work` for explicit external workflows. You do not need to use them for ordinary clones; continue with standard `git@github.com:...` URLs and review the effective SSH configuration.

### Resolution: Agent Saturation ("Too many authentication failures")
If you manually loaded multiple legacy keys into your global `ssh-agent`, target hosts may disconnect after your host attempts to cycle blindly through incorrect signatures.
GitSetu explicitly sets `IdentitiesOnly = yes` in your generated profiles to mitigate this, but if problems persist, restart the SSH agent or use `ssh-add -D` to clear transient caches.

---

## 🛑 Pre-Commit Identity Guard Blocks

```text
[GitSetu Guard] BLOCKING COMMIT! Identity mismatch detected.
Expected Email: dev@company.com (Target Profile: 'work')
Active Runtime Email: personal@example.com
```

The GitSetu Pre-Commit Identity Guard threw a fatal error to intentionally protect your commit history from leaking. 

### Resolution: Local Configuration Overrides
The most common cause of this error is that a developer manually executed `git config user.email` inside the target directory at some point in the past. This places an explicit override block inside the hidden `.git/config` file, overriding GitSetu's conditional routing matrices.

To clear the conflict and allow GitSetu to resume control:
```bash
git config --local --unset user.email
git config --local --unset user.name
```

> [!IMPORTANT]
> **Do not bypass the identity guard.** Do not use `git commit --no-verify` or
> `git commit -n` to work around an identity mismatch. Clear the local override,
> select the correct managed profile, or investigate the effective configuration
> with `gitsetu status` and `git config --show-origin`. A deliberate policy
> exception must be handled as a separately reviewed change, not as a
> troubleshooting shortcut.

---

## ⚙️ Path Interception Failures (`includeIf` ignoring directories)

If you navigate into a configured directory and your terminal `$PS1` integration or `gitsetu status` command still reports your global fallback identity, Git is refusing to execute the conditional intercept rule.

### Resolution: Symlinks & Virtualization Bounds
Git is highly pedantic regarding target path strings.
1. **Trailing Slashes:** Ensure the mapped path ends in `/`. GitSetu handles this natively during `setup`.
2. **Mount Point Normalization:** If you are operating inside WSL or virtualized Windows mounts (`/mnt/c/`), ensure you utilized the absolute Linux `/mnt/c/` path structure during `gitsetu setup`, not the abstract Windows path.
3. **Safe Directory Checks:** If your target `.git` repository folder is owned by a different internal OS user (e.g. `root` inside a container mount), Git may refuse to inspect it. Use `git config --global --add safe.directory /path/to/target/repository` only after verifying the path and ownership; prefer a command-scoped or container-specific trust decision where possible.

---

## 🪟 Windows-Specific Considerations

### NTFS Key Permissions (`644` vs `600`)
Under Linux/macOS, OpenSSH strictly demands `chmod 600` for private keys. On Windows NTFS filesystems, POSIX file permissions do not natively exist and Git Bash emulates permissions as `644`. 
- **GitSetu Behavior**: `gitsetu verify` automatically tolerates `644` on Windows (`gitbash`), preventing false-positive errors.
- **OpenSSH on Windows**: Native Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`) relies on Windows NTFS Access Control Lists (ACLs) instead of POSIX bits.

### Path Casing & Virtual Mount Points
- **Drive Letters**: Always use forward slashes in Git configurations (e.g. `C:/Users/name/work` rather than `C:\Users\name\work`). GitSetu automatically normalizes all paths to canonical `C:/path` format.
- **Case Sensitivity**: Windows paths are case-insensitive. GitSetu automatically injects `gitdir/i:` so directory matching works whether paths are referenced with uppercase or lowercase drive letters (`C:` vs `c:`).

### Isolated Verification via Windows Sandbox
If you want to verify GitSetu, test adding profiles, or debug configurations in total isolation from your host:
```powershell
# Native PowerShell:
powershell -ExecutionPolicy Bypass -File .\sandbox\launch_sandbox.ps1

# Or via Command Prompt / Explorer:
.\sandbox\launch_sandbox.bat
```
This boots a clean, disposable Windows Sandbox container and attempts the available regression and audit checks without modifying the host setup. The harness is experimental and is not a release qualification gate while its legacy fixtures are reconciled. A run with no terminal status is **inconclusive**, not a product pass.

---

## ☢️ The Nuclear Option: Clean State Teardown

If your environment is irrecoverably corrupted by cross-platform manual file tampering, execute GitSetu's native cleanup utility.

```bash
gitsetu teardown
```

This operation cleans the recognized GitSetu-managed boundaries in `~/.gitconfig` and OpenSSH paths without modifying unrelated user content, allowing a fresh `gitsetu setup` workflow after review.
