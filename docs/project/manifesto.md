# The GitSetu Manifesto & Architecture

GitSetu was born from a singular, profound frustration: managing multiple Git identities across diverse environments is a universally broken experience.

Modern software development requires engineers to constantly context-switch between enterprise monorepos, open-source contributions, and personal sandboxes. Yet, the infrastructure required to securely isolate these identities—generating keys, configuring SSH aliases, writing conditional Git includes, and mitigating virtualization quirks—is deeply tedious, highly error-prone, and entirely manual.

GitSetu exists to solve this problem permanently.

---

## 1. The Core Philosophy

### The Magical Clone (Zero-Friction UX)
Competitors require developers to memorize custom SSH host aliases (`git clone git@github-work:...`). We fundamentally reject this design.

GitSetu leverages the `includeIf` gitdir directive to dynamically inject `core.sshCommand` *mid-flight* during the clone process. This allows developers to clone repositories exactly as they normally would (`git clone git@github.com:...`). GitSetu intercepts the request and silently applies the correct SSH key based entirely on the target directory. It is frictionless, intuitive, and indistinguishable from magic.

### Absolute Zero Dependencies
A bootstrapping tool that requires a package manager to install is a contradiction in terms. 

GitSetu is written in pure, POSIX-compliant Bash 3.2. It requires no Go runtimes, no Node modules, no Rust toolchains, and no Homebrew installations. It relies strictly on `bash`, `git`, and `ssh-keygen`—tools guaranteed to exist on every developer workstation on earth. This guarantees zero "binary rot" and absolute portability.

### Strict Idempotency and Self-Healing
Configuration scripts that append data blindly are dangerous. 

GitSetu implements a strict Managed Block Protocol. It surgically updates only the sections it owns using a stateful parsing engine, leaving custom user configurations perfectly intact. It is safe to execute ten times in a row. Furthermore, it natively self-heals against virtualization environments, automatically stripping CRLF injections from VirtualBox shared folders and injecting `safe.directory` rules to bypass Git's dubious ownership blocks.

### Bootstrapping vs. Switching
GitSetu is a bootstrapper, not a switcher. It does not exist to manage identities you have already painstakingly configured. It exists to obliterate the configuration process entirely. From a fresh OS install, GitSetu provisions your entire Git identity infrastructure from scratch in under 60 seconds.

---

## 2. The Market Void: Why We Built This

It is astonishing that a tool like GitSetu did not exist until now. However, analyzing the history of Git and developer habits reveals exactly why this void occurred:

### The "Host Alias" Legacy Bias
For over a decade, the *only* way to manage multiple GitHub accounts on one machine was to create fake Host aliases in `~/.ssh/config` (e.g., `Host github-work`). Millions of developers were trained to use this sub-optimal workflow. When Git finally introduced `includeIf` (in v2.13) and `core.sshCommand` (in v2.10), the community was already anchored to the old ways. Tool builders created utilities to patch the old workflow, rather than architecting a modern `includeIf` interceptor.

### The Language Trap
Writing an interactive, idempotent configuration bootstrapper is highly complex. When developers attempt to automate this, they instinctively reach for modern languages like Go, Node.js, or Rust. However, introducing a compiled language or a package manager completely defeats the purpose of a "bootstrapper" script. You end up having to install dependencies just to configure your SSH keys. GitSetu is unique because it achieved compiled-CLI-level UX purely using POSIX Bash 3.2.

---

## 3. The Architecture

The entire magic of GitSetu relies on connecting standard SSH mechanics with advanced Git conditional configurations.

### Stage 1: Global Identity Routing (`~/.gitconfig`)

When you run `gitsetu setup`, it creates a globally managed block in your `~/.gitconfig`. This file serves as the routing table.

```ini
[gitsetu:managed:start]
# The fallback identity (used outside of any specific profile folders)
[user]
    name = Global Name
    email = global@example.com

# The conditional routers. If the current directory is within ~/dev/work/,
# load the work profile overrides.
[includeIf "gitdir:~/dev/work/"]
    path = ~/.config/gitsetu/work.gitconfig

[includeIf "gitdir:~/dev/personal/"]
    path = ~/.config/gitsetu/personal.gitconfig
[gitsetu:managed:end]
```

### Stage 2: Profile-Specific Overrides (`~/.config/gitsetu/*.gitconfig`)

When an `includeIf` rule triggers, Git merges the specific profile configuration. This is where GitSetu injects the specific email and the dynamic SSH Command.

```ini
[user]
    name = Work Name
    email = work@company.com
[core]
    # The SSH Interceptor
    sshCommand = ssh -F ~/.ssh/config -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_work
```

### Stage 3: The Cloning Intercept

Because `includeIf` triggers as soon as the local `.git` folder is created, the intercept happens *before* Git initiates the SSH connection to pull the remote files.

1. `git clone git@github.com:company/repo.git` inside `~/dev/work`.
2. Git creates `~/dev/work/repo/.git`.
3. Git evaluates `~/.gitconfig`. The path matches `gitdir:~/dev/work/`.
4. Git loads `~/.config/gitsetu/work.gitconfig`.
5. Git attempts to connect to `github.com` to fetch the repo, but now respects the overridden `core.sshCommand`.
6. SSH executes using the specific `id_ed25519_work` identity.

---

## 4. Non-Goals

To maintain its extreme focus and reliability, GitSetu explicitly rejects the following features:
- **OAuth / SSO Flows:** GitSetu brokers Personal Access Tokens (PATs) via the native OS keychain, but does not implement OAuth, SSO, or browser-based authentication flows.
- **Git Wrapping:** It does not alias or intercept standard Git commands (beyond the native hooks).
- **Dotfiles Management:** It strictly isolates its scope to Git and SSH identity configuration.
- **Daemonization:** It is an execution script, not a background process.
