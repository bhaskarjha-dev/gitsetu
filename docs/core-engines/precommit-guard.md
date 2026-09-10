# Pre-Commit Identity Guard Engine

**Fail-closed verification interceptor stopping wrong-author commits from hitting your repository history.**

While directory-scoped configuration routing acts as an incredibly reliable dynamic baseline, multi-state configuration drift remains a real vulnerability. 

If a developer runs manual one-off override commands inside a local project folder (e.g., `git config user.email "personal@example.com"`), Git's native precedence engine prioritizes local repository flags over global profile rules. To prevent these localized state overrides from leaking unauthorized identities into public commit history, GitSetu deploys an uncompromising final boundary: the **Identity Guard Engine**.

---

## Fail-Closed Intercept Flow

During initial installation or execution of the `gitsetu guard --install` subcommand, GitSetu maps a high-speed verification interceptor directly into your global Git configuration bounds (`core.hooksPath`).

```
[ Developer executes: git commit -m "feat: core module" ]
                           │
                           ▼
          [ Pre-Commit Hook Interception ]
                           │
                           ▼
  [ Rapid lookup of expected profile state for path ]
                           │
                           ▼
  [ Compares expected profile email vs actual email ]
                           │
             ┌─────────────┴─────────────┐
             ▼                           ▼
       [ MATCHES ]                 [ DIVERGES ]
             │                           │
             ▼                           ▼
     [ Commit Succeeds ]       [ INSTANT FATAL ABORT ]
```

### The Terminal Experience
When configuration divergence is intercepted, execution aborts instantly with high-visibility diagnostic output:

```text
$ git commit -m "wip: core patch"
[GitSetu Guard] BLOCKING COMMIT! Identity mismatch detected.
Expected Email: dev@company.com (Target Profile: 'work')
Active Runtime Email: personal@example.com (Source: local .git/config override)

Action Required: Run 'gitsetu doctor' or strip local config overrides.
```

---

## Ecosystem Virtualization Integration

Deploying global `core.hooksPath` directives frequently breaks localized team development tooling. 

GitSetu's intercept engine is architected to act as a **transparent pass-through proxy**. After verifying active identity boundaries successfully, the hook automatically identifies and triggers project-level execution hooks (e.g., `husky`, `lefthook`, or `pre-commit` runners), guaranteeing localized linting and testing pipelines run completely uninhibited.

---

## High-Performance Execution & Invariants

Because commit validation occurs inline multiple times a day, execution overhead must remain minimal. 

The Identity Guard is compiled purely in native, un-subshell-dependent **Bash 3.2**. By directly scanning internal configuration parameters without spinning up sub-processes or external interpreters, total evaluation completes in **`< 2 milliseconds`**, rendering the security verification entirely invisible during normal workflows.

### Longest-Prefix Match Routing
If multiple managed profile directories nest within each other (e.g., `~/work/` and `~/work/client-project/`), the guard uses a longest-prefix match algorithm to identify the deepest matching directory boundary. Commits inside `~/work/client-project/` are strictly enforced against the client profile email rather than the parent work profile.

### Case-Insensitive Directory Matching
On Windows and macOS, filesystems are case-insensitive. The guard automatically applies case normalization to both the current repository path and the configured profile workspace paths before prefix evaluation, ensuring commits aren't erroneously blocked due to casing differences (`C:/Work` vs `c:/work`).

### Dynamic Profile Email Resolution
To eliminate configuration drift if a user manually edits `~/.config/gitsetu/profiles/<label>.gitconfig` after setup, the guard dynamically re-reads the active `user.email` from the profile's `.gitconfig` file at commit time. This ensures the guard always validates against the live configuration rather than relying on stale registry cache values.

---

## Lifecycle Commands

Supervise the guard deployment natively via targeted subcommands:

```bash
# Natively mounts the global validation boundary
gitsetu guard --install

# Disables global interception cleanly
gitsetu guard --uninstall
```
