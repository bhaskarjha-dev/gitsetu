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
[includeIf "gitdir:~/work/"]
    path = ~/.config/gitsetu/profiles/work.gitconfig
```
When your active terminal session traverses into any sub-path of `~/work/`, Git natively intercepts the operation, seamlessly applying your professional email and custom execution parameters inline.

### 2. OpenSSH `Include` Integration
Mutating global `~/.ssh/config` files inline violates zero-trust principles and risks catastrophic corruption of existing host parameters. 

GitSetu resolves this by leveraging OpenSSH 7.3+'s native `Include` directive. During initial setup, GitSetu prepends a single routing link to the absolute top of your configuration file:
```ini
Include ~/.config/gitsetu/ssh_config
```
All distinct host configurations, custom identity file pointers (`IdentityFile ~/.ssh/id_ed25519_work`), and strict verification flags (`IdentitiesOnly yes`) are exclusively orchestrated inside GitSetu's isolated layout layer, guaranteeing absolute sandboxing.

### 3. Fail-Closed Identity Guard (Pre-Commit)
To eliminate multi-state identity drift (e.g., configuring GitSetu but accidentally setting local `.git/config` overrides manually), GitSetu deploys a lightweight global hooks boundary (`core.hooksPath`).

1. **Commit Interception:** The global hook triggers the moment `git commit` executes.
2. **Registry Verification:** Rapidly loads the master profile state from `~/.config/gitsetu/profiles.conf`.
3. **Identity Verification:** Compares the expected profile email address for the local file path against the active runtime string returned by `git config user.email`.
4. **Execution Decision:** If values match, execution proceeds. If values diverge, it raises an instant fatal termination (`exit 1`), blocking unauthorized code from hitting remote branches.

### 4. Namespaced Credential Brokering
When authenticating over HTTPS, standard credential managers frequently mix Personal Access Tokens (PATs) for identical hostnames. 

GitSetu injects itself as a proxy credential helper (`[credential] helper = "/path/to/gitsetu credential"`). When upstream syncs fire, GitSetu intercepts the authentication pipeline, evaluates active directory context, and requests heavily namespaced tokens from the underlying operating system (e.g., `gitsetu:work:github.com`), completely stopping cross-tenant authentication cross-talk.

---

## POSIX Security & Concurrency Boundaries

To ensure absolute resilience under parallel builds or automated Continuous Integration environments:
- **Atomic File Hot-Swaps:** All global configuration mutations write out to isolated temp directory contexts (`$TMPDIR/..._$$_${RANDOM}`) before executing immediate atomic renames (`mv`), eliminating mid-write interruption vectors.
- **POSIX Lock Reaping:** Subsystem routines generate dedicated execution lock blocks via `mkdir` primitives to safely process concurrent requests without race conditions.
- **Unified Global Traps:** Comprehensive signal traps (`EXIT / SIGINT / SIGTERM`) guarantee orphaned states, transient arrays, and partial file descriptors are cleanly collected even if execution panics.

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
| **`backup.sh`** | File-level timestamped backups, OpenSSL encrypted vault export/import. |
| **`teardown.sh`** | Profile removal, managed block cleanup, deep local-repo identity stripping. |
| **`discovery.sh`** | Auto-discovery: SSH key email extraction, gitconfig identity parsing, workspace detection. |
| **`keychain.sh`** | Cross-platform credential broker routing to macOS Keychain and Linux Secret Service. |
| **`completion.sh`** | TAB completion for Bash/Zsh: subcommands and profile name completion. |
