# Identity Routing Engine

**A deep dive into directory-scoped Git conditional mechanics and native credential switching.**

At the core of GitSetu's context-switching capability is a combination of standard Git configuration files with conditional file-inclusion rules.

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

# Global fallback identity (the mandatory global profile)
[include]
    path = "/home/alice/.config/gitsetu/profiles/global.gitconfig"

# Directory-scoped conditional interceptors (POSIX example)
[includeIf "gitdir:/home/alice/work/"]
    path = "/home/alice/.config/gitsetu/profiles/work.gitconfig"

[includeIf "gitdir:/home/alice/clients/acme/"]
    path = "/home/alice/.config/gitsetu/profiles/acme.gitconfig"
[gitsetu:managed:end]
```

### How Runtime Evaluation Operates

1. **Working Directory Transition:** You navigate your shell into `/home/alice/work/api-service/`.
2. **Git Operation Intercept:** You execute any standard git command (e.g. `git clone`, `git fetch`, or `git commit`).
3. **Path Matching:** Git evaluates the managed `includeIf` conditions. Generated
   paths are canonical absolute paths; the compiler uses `gitdir/i:` on
   case-insensitive macOS and Windows/Git Bash filesystems.
4. **Target Inclusion:** When the condition matches, Git reads the target
   profile configuration (`/home/alice/.config/gitsetu/profiles/work.gitconfig`)
   and applies its values.

---

## Inside the Profile Payload

The isolated target file (`work.gitconfig`) contains your precise overrides:

```ini
[user]
    name = Corporate Author Name
    email = dev@company.com
[core]
    # The key is one shell-quoted argument; no -F option is generated.
    sshCommand = "ssh -o IdentitiesOnly=yes -i '~/.ssh/id_ed25519_work'"
```

This separation of concerns substantially reduces accidental cross-profile routing and avoids loading a single global key for every remote. It is not a guarantee against a compromised same-user process, manually overridden Git configuration, or a provider-side account mistake; review effective identity and repository state before committing.

---

## Path Resolution Safeguards & Zero-Trust Architecture

Because cross-platform filesystems handle casing, symlinks, and trailing paths differently, GitSetu applies strict compilation guard rails:
- **Trailing Slashes:** Every compiled `gitdir:`/`gitdir/i:` path string
  strictly terminates with a `/` character to ensure deep sub-folder recursion
  acts properly.
- **Tilde Expansion:** Standardizes shell `$HOME` prefixes to absolute directory markers to stop parsing errors across disparate terminal environments.
- **Case-Insensitive Matching (`gitdir/i:`):** On macOS and Windows/Git
  Bash, GitSetu compiles `gitdir/i:` instead of `gitdir:`. This handles
  case differences on the supported case-insensitive filesystems (for
  example, `C:/Users` vs `c:/users`).
- **Canonical Drive Letter Normalization:** Converts Windows paths (`/c/Users/...` or `c:\users\...`) into canonical `C:/Users/...` format, which is fully recognized and resolved by native Win32 `git.exe` across both Git Bash and Windows native shells (PowerShell, CMD).
- **Virtualization Support:** Normalizes supported Windows/WSL path representations and rejects malformed or ambiguous path input rather than silently guessing.

### Automatic Workspace Directory Provisioning (`mkdir -p`)
When registering a new profile (interactively in `gitsetu setup` or via `gitsetu add`), GitSetu automatically checks if the declared target directory exists on disk. If absent, it provisions the directory hierarchy via `mkdir -p` (while respecting `--dry-run` invariants), eliminating "directory does not exist" failures before cloning or committing.

### Longest-Prefix Match Routing
When nested workspace directories exist (e.g., a general work directory `~/work/` and a nested client project `~/work/clients/acme/`), GitSetu's routing, prompt engine, and pre-commit guard use a deterministic longest-prefix match. The most specific directory boundary wins in the tested configuration; Git evaluates conditional rules sequentially. On Windows and macOS, path matching is case-insensitive, reducing casing drift.

### Multi-Profile Persistence & Re-hydration
Running `gitsetu setup` multiple times reloads the current v2 registry and managed profile configs. Existing unrelated SSH keys and configuration remain outside GitSetu's managed roots, but the old colon-delimited registry is rejected; there is no migration reader. Review changes before applying them.

### Co-existence with Pre-Existing Manual `includeIf` Setups
For developers transitioning from hand-crafted `includeIf` directives and custom `.gitconfig` files:
1. **Zero-Destruction Boundary:** GitSetu encapsulates all generated rules strictly within `# [gitsetu:managed:start]` and `# [gitsetu:managed:end]`. Any manual `includeIf` rules, aliases, and settings outside this block are never altered, deleted, or reordered.
2. **Deterministic precedence:** Git evaluates conditional includes in configuration order. GitSetu tests nested parent/child routing and emits rules in an order that gives the most-specific managed profile the intended result.
3. **Explicit discovery:** `gitsetu setup --auto` discovers identities and
   applies the resulting blueprint in non-TTY use; it does not silently
   import or migrate an old registry format.
4. **Clean reversibility:** `gitsetu teardown` removes only recognized GitSetu-managed blocks and files. It is bounded cleanup, not a claim that every third-party mutation can be perfectly reconstructed.

### Profile Teardown, Unmounting & Orphan Pruning
When a profile is removed via `gitsetu remove <label>`, GitSetu rewrites the
strict v2 registry and regenerates the managed Git/SSH views. It does not
edit or reorder content outside the managed markers:
1. The profile entry is removed from `profiles.conf`.
2. The managed routing block in `~/.gitconfig` is regenerated without that
   profile; unrelated `includeIf` rules and settings remain untouched.
3. The generated `~/.config/gitsetu/profiles/ssh_config` is rebuilt without
   the profile's host alias.
4. The profile payload
   `~/.config/gitsetu/profiles/<label>.gitconfig` and unreferenced generated
   payloads are pruned.
5. Private SSH keys are preserved unless the separate post-removal confirmation
   is accepted.
