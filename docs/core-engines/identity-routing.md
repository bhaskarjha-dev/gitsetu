# Identity Routing Engine

**A deep dive into directory-scoped Git conditional mechanics and native credential switching.**

At the core of GitSetu's magical context-switching capability lies a seamless fusion of standard Git configuration files with advanced conditional file inclusion rules.

Unlike brittle wrapper utilities that alias the `git` binary or long-running supervisor daemons that monitor your file descriptors, GitSetu shifts runtime evaluation entirely to Git itself.

---

## The Routing Architecture

When you provision a workspace profile via `gitsetu setup`, GitSetu statefully compiles your global configuration file (`~/.gitconfig`), injecting a structured conditional routing table.

```ini
[gitsetu:managed:start]
# Base Global Fallback Identity
[user]
    name = Base Developer Name
    email = personal@example.com

# Target Conditional Path Interceptors
[includeIf "gitdir:~/work/"]
    path = ~/.config/gitsetu/profiles/work.gitconfig

[includeIf "gitdir:~/clients/acme/"]
    path = ~/.config/gitsetu/profiles/acme.gitconfig
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
    # Injects the exact cryptographic key context required by this profile
    sshCommand = ssh -F ~/.ssh/config -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_work
```

This absolute separation of concerns guarantees that **personal sandbox credentials never leak into corporate repositories**, while preventing single-key remote auth failures.

---

## Path Resolution Safeguards

Because cross-platform filesystems handle casing, symlinks, and trailing paths differently, GitSetu applies strict compilation guard rails:
- **Trailing Slashes:** Every compiled `gitdir:` path string strictly terminates with a `/` character to ensure deep sub-folder recursion acts properly.
- **Tilde Expansion:** Standardizes shell `$HOME` prefixes to absolute directory markers to stop parsing errors across disparate terminal environments.
- **Virtualization Support:** Silently filters out malformed line endings and maps target workspace trees across Windows Subsystem for Linux (WSL) boundaries flawlessly.
