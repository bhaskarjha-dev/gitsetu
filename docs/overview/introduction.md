# Introduction to GitSetu

**The Bash-based orchestration engine for directory-scoped Git identity and credential isolation.**

GitSetu reduces the operational risk of managing multiple identities across workspaces, repositories, and organizations. It compiles Git/OpenSSH configuration and provides bounded diagnostics; it is not a security boundary against a compromised same-user process.

---

## The Identity Crisis: What We Solve

Modern developer environments are highly fragmented. Context-switching between distinct organizations creates massive risk surfaces that traditional Git setups simply fail to protect against.

| The Operational Vulnerability | Typical Failure Mode | The GitSetu Automated Engine |
| :--- | :--- | :--- |
| 🔴 **Corporate Identity Leaks** | Committing private proprietary code using a personal email address or public alias. | **Directory-Scoped `includeIf` routing:** Applies the selected profile when Git evaluates a managed path. |
| 🔴 **Silent Authentication Collisions** | Single SSH keys loaded globally against overlapping multi-tenant remote hosts (e.g., `github.com`). | **Profile-scoped key generation:** Bootstraps separate `ed25519` keypairs for each managed profile. |
| 🔴 **Cross-Profile PAT Pollution** | HTTPS pull/push streams blindly pulling cached global tokens from OS credentials, returning `HTTP 403 Forbidden`. | **Namespaced credential broker:** Resolves records by profile, host, and path through the selected native store. |
| 🔴 **Untracked Historical Config Drift** | Manual one-off edits to global `.gitconfig` files drifting out of compliance over time. | **Managed blocks and explicit review:** GitSetu writes recognized managed regions and leaves unrelated configuration for review. |
| 🔴 **Pre-Flight Failure Vulnerability** | Forgetting to execute environment prep scripts before pushing code to protected branches. | **Fail-Closed Identity Guard:** Checks managed identity state during pre-commit and blocks divergent commits. |

---

## Architectural Distinctions

### Indistinguishable from Magic: The Native Clone
Competitor tools require developers to memorize custom SSH host aliases (e.g., `git clone git@github-work:org/repo.git`). GitSetu rejects this sub-optimal design pattern. 

By generating conditional `core.sshCommand` and OpenSSH include rules, GitSetu lets Git and OpenSSH select the profile key for a managed directory. The operating systems and credential stores still enforce their own security controls.

### Minimal Core Dependencies
GitSetu's primary implementation is plain Bash 3.2-compatible source and relies on standard Git/OpenSSH tools. Optional native credential stores and OpenSSL are detected explicitly; unavailable optional features fail clearly rather than silently downgrading.

### Guard Rails
Managed repositories fail closed when their expected identity is unresolved or divergent. Unmanaged repositories fail open for the GitSetu identity check by policy; Git's own `useConfigOnly` and repository configuration still determine whether a commit has an identity.

---

## Getting Started

Ready to eradicate repository configuration friction permanently?
- **[Install GitSetu](../getting-started/installation.md)** — Bootstrap directly in your terminal.
- **[Quickstart Guide](../getting-started/quickstart.md)** — Provision your entire profile architecture from scratch in under 60 seconds.
