# Identity Routing Engine

**A deep dive into directory-scoped Git conditional mechanics and native credential switching.**

At the core of GitSetu's magical context-switching capability lies a seamless fusion of standard Git configuration files with advanced conditional file inclusion rules.

Unlike brittle wrapper utilities that alias the `git` binary or long-running supervisor daemons that monitor your file descriptors, GitSetu shifts runtime evaluation entirely to Git itself.

---

## The Routing Architecture

When you provision a workspace profile via `gitsetu setup`, GitSetu statefully compiles your global configuration file (`~/.gitconfig`), injecting a structured conditional routing table.

```ini
[gitsetu:managed:start]
[user]
    useConfigOnly = true

[init]
    defaultBranch = main

# Global Fallback Identity (unmapped directories)
[include]
    path = "~/.config/gitsetu/profiles/personal.gitconfig"

# Directory-Scoped Conditional Interceptors
[includeIf "gitdir:~/work/"]
    path = "~/.config/gitsetu/profiles/work.gitconfig"

[includeIf "gitdir:~/clients/acme/"]
    path = "~/.config/gitsetu/profiles/acme.gitconfig"
[gitsetu:managed:end]
```

### How Runtime Evaluation Operates

1. **Working Directory Transition:** You navigate your shell into `~/work/api-service/`.
2. **Git Operation Intercept:** You execute any standard git command (e.g. `git clone`, `git fetch`, or `git commit`).
3. **Path Matching:** Git natively evaluates `~/.gitconfig` top-down. Upon encountering `includeIf "gitdir:~/work/"`, it verifies if the local repository resides within that absolute tree bounds.
4. **Target Inclusion:** Because the bounds match, Git dynamically parses and applies the target profile configuration file (`~/.config/gitsetu/profiles/work.gitconfig`) mid-flight.

---

## Inside the Profile Payload

The isolated target file (`work.gitconfig`) contains your precise overrides:

```ini
[user]
    name = Corporate Author Name
    email = dev@company.com
[core]
    # Injects the exact cryptographic key context required by this profile (safe space-quoted)
    sshCommand = ssh -F ~/.ssh/config -o IdentitiesOnly=yes -i "~/.ssh/id_ed25519_work"
```

This absolute separation of concerns guarantees that **personal sandbox credentials never leak into corporate repositories**, while preventing single-key remote auth failures.

---

## Path Resolution Safeguards & Zero-Trust Architecture

Because cross-platform filesystems handle casing, symlinks, and trailing paths differently, GitSetu applies strict compilation guard rails:
- **Trailing Slashes:** Every compiled `gitdir:` path string strictly terminates with a `/` character to ensure deep sub-folder recursion acts properly.
- **Tilde Expansion:** Standardizes shell `$HOME` prefixes to absolute directory markers to stop parsing errors across disparate terminal environments.
- **Windows Case-Insensitive Matching (`gitdir/i:`):** On Windows / Git Bash, GitSetu automatically compiles `gitdir/i:` instead of `gitdir:`. Because Windows filesystems (NTFS) are case-preserving but case-insensitive, this ensures that directory matching never breaks if paths differ in casing (e.g. `C:/Users` vs `c:/users`).
- **Canonical Drive Letter Normalization:** Converts Windows paths (`/c/Users/...` or `c:\users\...`) into canonical `C:/Users/...` format, which is fully recognized and resolved by native Win32 `git.exe` across both Git Bash and Windows native shells (PowerShell, CMD).
- **Virtualization Support:** Silently filters out malformed line endings and maps target workspace trees across Windows Subsystem for Linux (WSL) boundaries flawlessly.

### Automatic Workspace Directory Provisioning (`mkdir -p`)
When registering a new profile (interactively in `gitsetu setup` or via `gitsetu add`), GitSetu automatically checks if the declared target directory exists on disk. If absent, it provisions the directory hierarchy via `mkdir -p` (while respecting `--dry-run` invariants), eliminating "directory does not exist" failures before cloning or committing.

### Longest-Prefix Match Routing
When nested workspace directories exist (e.g., a general work directory `~/work/` and a nested client project `~/work/clients/acme/`), GitSetu's routing, prompt engine, and pre-commit guard employ a deterministic longest-prefix match algorithm. The most specific directory boundary wins: Git evaluates conditional rules sequentially, and GitSetu tools compute matching prefix lengths to ensure the deeper child profile takes absolute precedence over the parent. On Windows and macOS, path matching is case-insensitive, avoiding casing drift.

### Multi-Profile Persistence & Re-hydration
Running `gitsetu setup` multiple times is safe and non-destructive. GitSetu automatically loads and re-hydrates existing profiles from `~/.config/gitsetu/profiles.conf`, preserving their names, emails, keys, and directory bindings in memory. Users can review, adjust, or append profiles without overwriting previously configured identities.

### Profile Teardown, Unmounting & Orphan Pruning
When a profile is removed via `gitsetu remove <label>`:
1. The profile entry is deleted from `profiles.conf`.
2. Its conditional `includeIf` block is surgically unmounted from `~/.gitconfig`.
3. Its dedicated OpenSSH host block is excised from `~/.config/gitsetu/profiles/ssh_config`.
4. Its profile configuration file `~/.config/gitsetu/profiles/<label>.gitconfig` is permanently pruned from disk.
5. Any unreferenced orphaned `.gitconfig` files in `profiles/` are pruned automatically to prevent configuration clutter.
