# The Design Manifesto

**The foundational principles, uncompromising constraints, and architectural philosophy driving GitSetu.**

GitSetu was engineered to solve a pervasive operational friction: managing multiple isolated Git identities across overlapping organizational bounds is universally broken. 

Standard workflows require developers to constantly toggle configuration contexts between enterprise source trees, customer delivery repositories, and personal sandboxes. The operational tooling required to maintain these environments—hand-crafting SSH host blocks, writing manual conditional logic, and diagnosing platform virtualization issues—imposes immense operational overhead and massive risk surfaces.

GitSetu exists to automate these operations out of existence permanently.

---

## Uncompromising Principles

### 1. The Magical Clone (Absolute Frictionless UX)
Traditional dual-identity approaches force developers to use non-standard clone URLs containing specialized host aliases (`git clone git@github-work:org/repo.git`). We fundamentally reject this design pattern.

GitSetu leverages directory-scoped `includeIf` conditional mapping to inject custom `core.sshCommand` parameters mid-flight during repository cloning. Developers clone, fetch, and push standard URLs exactly as they normally would (`git clone git@github.com:org/repo.git`). GitSetu intercepts the local path evaluation and dynamically routes execution through the designated cryptographic keypair. The bridging layer is entirely invisible.

### 2. Absolute Zero Runtime Dependencies
A core environment bootstrapping script that requires downloading complex package managers or language runtimes to install is fundamentally contradictory.

GitSetu is compiled strictly in hardened, POSIX-compliant **Bash 3.2**. It relies on zero external language dependencies—no Go runtimes, no Python scripts, no Node packages, and no Homebrew installations. It executes using `bash`, `git`, and `ssh-keygen` exclusively. This guarantees extreme multi-platform portability across legacy OS bounds, minimal container builds, and headless CI/CD execution environments.

### 3. Strict Idempotency & Safe Self-Healing
Blind configuration string appends frequently corrupt configuration states. 

GitSetu enforces a strict **Managed Block Protocol**. Utilizing stateful line parsing, it surgically injects or refreshes only the layout blocks it explicitly owns, leaving all user-defined global options completely untouched. It is safe to run repeatedly. Furthermore, it automatically self-heals against virtualization environments, aggressively removing CRLF line endings from VirtualBox shared mounts and injecting localized `safe.directory` rules to bypass restrictive platform ownership blocks.

### 4. Bootstrapping vs. Switching
GitSetu acts as an initial environment bootstrapper, not a manual context switcher. It does not exist to supervise custom configurations you have already manually assembled. It exists to eliminate manual assembly entirely. From a bare-metal OS setup, GitSetu securely seeds your complete identity layout architecture in under 60 seconds.

---

## The Category Moat

When developers attempt to build multi-identity solutions, they frequently rely on modern languages like Go or Rust. While these languages offer excellent execution speed, introducing a binary runtime dependency breaks the core utility of a lightweight shell setup script. 

GitSetu is highly unique because it achieved compiled-binary-level developer experience, robust concurrency isolation, and multi-point diagnostics purely using zero-dependency POSIX shell mechanics.

---

## Strict Non-Goals

To maintain absolute system reliability and maximum focus, GitSetu explicitly rejects the following product additions:
- **OAuth / Single Sign-On Orchestration:** GitSetu proxies Personal Access Tokens via native OS keychains, but intentionally avoids supervising web-based OAuth authentication loops.
- **Git Binary Wrapping:** It acts exclusively via native hooks and credential helpers, avoiding command-line alias intercepts.
- **General Workspace Dotfiles:** It strictly limits its operational domain to Git and OpenSSH identity structures.
- **Persistent Daemonization:** It operates entirely as an ephemeral configuration compiler, leaving zero lingering background listener tasks.
