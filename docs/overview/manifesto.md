# The Design Manifesto

**The foundational principles, uncompromising constraints, and architectural philosophy driving GitSetu.**

GitSetu was engineered to solve a pervasive operational friction: managing multiple isolated Git identities across overlapping organizational bounds is universally broken. 

Standard workflows require developers to constantly toggle configuration contexts between enterprise source trees, customer delivery repositories, and personal sandboxes. The operational tooling required to maintain these environments—hand-crafting SSH host blocks, writing manual conditional logic, and diagnosing platform virtualization issues—imposes immense operational overhead and massive risk surfaces.

GitSetu exists to reduce these operations to a reviewable, repeatable configuration workflow.

---

## Uncompromising Principles

### 1. Native URLs and Managed Routing
GitSetu does not require specialized clone URLs for ordinary repositories inside mapped workspaces. It also generates optional aliases such as `github-work` for explicit external package-manager and cache workflows; those aliases are an escape hatch, not a requirement.

GitSetu uses directory-scoped `includeIf` mapping to provide profile-specific `core.sshCommand` parameters when Git evaluates a managed path. Developers can use standard Git URLs; the operating system, Git, and OpenSSH still determine the final effective connection. The configuration compiler adds no daemon.

### 2. Minimal Runtime Dependencies
A core environment bootstrapping script that requires downloading complex package managers or language runtimes is unnecessarily fragile.

GitSetu's primary implementation is plain Bash 3.2-compatible source and uses standard Git/OpenSSH tools. Optional native credential stores and OpenSSL are detected explicitly; a feature that needs an unavailable optional tool fails clearly rather than silently downgrading. This keeps the core portable while making trade-offs visible.

### 3. Bounded Idempotency & Safe Self-Healing
Blind configuration string appends frequently corrupt configuration states.

GitSetu uses a managed-block protocol, private staging, strict validation, and atomic replacement where possible. It does not claim that every command is side-effect-free: setup and removal intentionally mutate managed state, while `--dry-run` previews without persistence. CRLF recovery and other repairs are bounded, ownership-checked operations.

### 4. Bootstrapping vs. Switching
GitSetu is primarily a configuration compiler, not a daemon. It can discover existing identities and propose a setup, but users remain responsible for reviewing changes and maintaining third-party configuration outside its managed roots.

---

## The Category Moat

When developers attempt to build multi-identity solutions, they frequently rely on modern languages like Go or Rust. While these languages offer excellent execution speed, introducing a binary runtime dependency breaks the core utility of a lightweight shell setup script. 

GitSetu aims to provide a lightweight developer experience, bounded concurrency controls, and multi-point diagnostics using zero-dependency POSIX shell mechanics.

---

## Strict Non-Goals

To maintain a focused reliability model, GitSetu explicitly rejects the following product additions:
- **OAuth / Single Sign-On Orchestration:** GitSetu proxies Personal Access Tokens via native OS keychains, but intentionally avoids supervising web-based OAuth authentication loops.
- **Git Binary Wrapping:** It primarily acts through native Git/OpenSSH configuration, with optional `gitsetu run`, installer, npm, and GitHub CLI wrappers for explicit workflows rather than intercepting every shell command.
- **General Workspace Dotfiles:** It strictly limits its operational domain to Git and OpenSSH identity structures.
- **Persistent Daemonization:** It operates entirely as an ephemeral configuration compiler, leaving zero lingering background listener tasks.
