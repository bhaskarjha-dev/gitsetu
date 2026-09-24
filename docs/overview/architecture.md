# System Architecture

**A comprehensive deep dive into the internal mechanics, modular compilation patterns, and zero-trust execution flows of GitSetu.**

GitSetu achieves robust multi-identity orchestration without relying on long-running daemons or binary runtimes. Operating purely as a **localized configuration compiler**, it statefully compiles native Git and OpenSSH structures, delegating continuous runtime evaluation directly to standard OS routing mechanisms.

---

## The Compilation Paradigm

Unlike traditional switchers that spawn watcher processes or intercept shell execution paths via wrapper functions, GitSetu executes on demand. 

```
[ Developer Input ] 
       │
       ▼
[ gitsetu setup ] ──(Stateful CLI Wizard)
       │
       ▼
[ Atomic Managed Blocks ] ──► ~/.gitconfig (includeIf routing tables)
                            └──► ~/.ssh/config (OpenSSH Include pivot)
       │
       ▼
[ Complete Process Teardown ] (Zero residual runtime daemons)
```

When triggered, GitSetu reads your profile specifications, injects precisely formatted conditional rules into your persistent configuration stores, and exits entirely. Git and OpenSSH handle runtime evaluation natively.

---

## Subsystem Mechanics

### 1. Global Identity Routing (`~/.gitconfig`)
GitSetu establishes a highly secure routing framework by deploying atomic, demarcated blocks labeled with custom signatures (e.g., `[gitsetu:managed:start]`).

Inside these managed bounds, GitSetu maps local folders to isolated target files using Git's built-in `includeIf` condition:
```ini
# Linux / macOS:
[includeIf "gitdir:~/work/"]
    path = ~/.config/gitsetu/profiles/work.gitconfig

# Windows (Case-Insensitive & Canonical C:/ path):
[includeIf "gitdir/i:C:/Users/username/work/"]
    path = ~/.config/gitsetu/profiles/work.gitconfig
```
When your active terminal session traverses into any sub-path of your workspace, Git natively intercepts the operation, seamlessly applying your professional email and custom execution parameters inline. On Windows, the `gitdir/i:` keyword guarantees case-insensitive path evaluation across all shells.

### 2. OpenSSH `Include` Integration
Mutating global `~/.ssh/config` files inline violates zero-trust principles and risks catastrophic corruption of existing host parameters. 

GitSetu resolves this by leveraging OpenSSH 7.3+'s native `Include` directive. During initial setup, GitSetu prepends a single portable routing link to the absolute top of your configuration file:
```ini
Include ~/.config/gitsetu/profiles/ssh_config
```
All generated host configurations, identity file pointers, and verification flags are written inside GitSetu's managed SSH include. Unrelated user host blocks remain outside that file; OpenSSH still controls the final effective configuration.

### 3. Identity Guard (Pre-Commit)

GitSetu installs its generated pre-commit guard in the managed hooks directory and preserves a project hook when the identity check succeeds. For a repository selected by a managed profile, an unresolved or divergent effective identity fails closed. A repository outside all managed profiles is unmanaged: the identity check fails open by policy and ordinary project hooks continue. Malformed managed state is treated as indeterminate and fails closed.

### 4. Namespaced Credential Brokering
When authenticating over HTTPS, standard credential managers frequently mix Personal Access Tokens (PATs) for identical hostnames. 

GitSetu injects itself as a scoped proxy credential helper. It evaluates the active directory context and requests a namespaced token from the selected backend, reducing cross-profile collisions; the operating system credential store and Git still control the final authentication exchange.

---

## Zero-Trust Architecture & Concurrency Boundaries

To reduce risk under parallel builds and automated environments, GitSetu uses bounded integrity controls:
- **Atomic File Hot-Swaps:** All global configuration mutations write out to isolated temp directory contexts (`$TMPDIR/..._$$_${RANDOM}`) before executing immediate atomic renames (`mv`), eliminating mid-write interruption vectors.
- **Lock ownership:** Directory locks use an owner token, PID liveness checks, bounded waiting, and safe stale-lock reaping. They protect normal concurrent operations but are not a security boundary against a same-user attacker.
- **Process cleanup:** EXIT/INT/TERM handlers remove only resources registered by the current process.
- **Automatic workspace provisioning:** Missing profile directories are created only during an explicitly mutating operation; dry-run remains non-persistent.
- **Longest-prefix routing:** Nested paths are resolved by canonical prefix matching, with platform-aware case behavior.
- **Versioned persistence:** Re-running setup reloads the v2 registry and managed profile configs; old registry formats are rejected rather than migrated.
- **Safe SSH Command Quoting:** Enforces escaped double-quoting around SSH key paths containing spaces in `core.sshCommand` and `GIT_SSH_COMMAND`.
- **Windows Sandbox Test Harness:** Disposable, host-isolated validation environment (`sandbox/`) for multi-profile and empirical checks without modifying the host machine.

---

## Core Library Module Map

GitSetu loads distinct library dependencies dynamically during runtime compilation:

| Module Base | Core Responsibility Scope |
| :--- | :--- |
| **`core.sh`** | Version, XDG paths, 9 parallel state arrays, `load_profiles()`, `remove_profile_at_index()`. |
| **`platform.sh`** | OS detection (`detect_os`), path normalization, gitdir keyword selection. |
| **`ui.sh`** | Terminal output (`print_success/error`), interactive prompts, setup banner. |
| **`validate.sh`** | Input validation: emails, GitHub noreply formats, labels, path overlap detection. |
| **`setup.sh`** | Interactive terminal layout generation and POSIX execution lock reapers. |
| **`gitconfig.sh`** | `includeIf` block rendering, configuration bounds validation, and base profile writing. |
| **`ssh.sh`** | Dedicated cryptographic key bootstrapping and isolated OpenSSH `Include` proxy writing. |
| **`guard.sh`** | Pre-commit hook deployment and global hook virtualization handling. |
| **`doctor.sh`** | Multi-point environment diagnostics and configuration drift discovery. |
| **`verify.sh`** | Infrastructure verification: SSH key existence/permissions, gitconfig integrity. |
| **`backup.sh`** | Managed state snapshots, authenticated v2 vault export/import, staging, and rollback. |
| **`teardown.sh`** | Profile removal, managed block cleanup, deep local-repo identity stripping. |
| **`discovery.sh`** | Auto-discovery: SSH key email extraction, gitconfig identity parsing, workspace detection. |
| **`keychain.sh`** | Namespaced native credential routing with an explicit, warned plaintext zero-dependency backend. |
| **`completion.sh`** | TAB completion for Bash/Zsh: subcommands and profile name completion. |
