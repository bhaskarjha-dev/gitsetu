# How GitSetu Compares

GitSetu is one of several ways to run more than one Git identity on a machine. This page explains its approach and the trade-offs, so you can choose. It makes no claims about other tools' current features; check their own documentation.

---

## The Approaches

| Approach | How it works | Trade-off |
| :--- | :--- | :--- |
| **Hand-written configuration** | `includeIf "gitdir:…"` blocks in `~/.gitconfig` and `Host` aliases in `~/.ssh/config` | Full control and nothing to install; every new identity, key and folder is manual, and mistakes are silent |
| **Switch on demand** | A tool rewrites the global identity or SSH key when you run a command | A simple model, but the active identity follows the last command, not the folder you're in |
| **Shell hooks and environment loaders** (for example `direnv`) | Variables such as `GIT_AUTHOR_EMAIL` or `GIT_SSH_COMMAND` change when you `cd` | General purpose; works where the hook runs, so IDEs and GUI clients need their own integration |
| **Generated native configuration** (GitSetu) | Writes `includeIf` routes, per-profile Git files and an included SSH config once, then exits | Git and OpenSSH do the routing everywhere, IDEs included; behavior follows Git's and OpenSSH's own rules |

---

## What GitSetu Does

- **Directory and remote routing:** per-profile `includeIf "gitdir:…"` routes, plus `includeIf "hasconfig:remote.*.url:…"` routes for `--remote` patterns (Git 2.36 or later).
- **One SSH key per profile:** a generated Ed25519 or FIDO2 key, or an existing key you choose, pinned with `IdentitiesOnly`. GitSetu doesn't add profile keys to the SSH agent.
- **Your configuration stays yours:** GitSetu writes only its own files and marked blocks, so your own `includeIf` rules, `Host` aliases, hooks and signing settings keep working.
- **Opt-in guard:** `gitsetu guard --install` blocks commits with the wrong identity in managed repositories, and still runs the repository's own `.git/hooks` and a global `core.hooksPath` you set earlier. It is a client-side check, not a boundary: a repository-level `core.hooksPath`, `--no-verify` and history rewrites bypass it, and it fails open on its own errors.
- **Authenticated backup vault:** `gitsetu backup` and `gitsetu restore` move managed state and keys between machines. Credentials held in your OS keychain or Git Credential Manager aren't exported.
- **Diagnostics for people and agents:** `gitsetu doctor` (with `--repair` for GitSetu's own managed blocks), `verify`, `explain`, `audit` for existing history, and `status --json` for scripts.
- **Platforms:** Linux, macOS (Bash 3.2), WSL, and Windows through Git Bash, PowerShell and CMD.

---

## When Another Approach Fits Better

- You have one identity, or two that never share a machine folder: hand-written `includeIf` blocks are enough.
- You need enforcement on the server side, such as rejecting pushes with the wrong email: use your Git host's rules. GitSetu's guard runs on your machine.
- You keep keys only in an SSH agent such as 1Password or Secretive: GitSetu v1.1.0 pins a key file per profile. Agent-held keys are planned for v1.2.0.

---

## Other Tools

These projects solve related problems in other ways. Check each project's current documentation before you compare: [git-ego](https://github.com/bgreenwell/git-ego), [gitch](https://github.com/orzazade/gitch), [karn](https://github.com/prydonius/karn), [gguser](https://github.com/withshubh/gguser) and [direnv](https://direnv.net/).
