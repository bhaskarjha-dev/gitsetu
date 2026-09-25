# Introduction

**The bridge between your identities and your repositories.**

GitSetu is a Bash-based configuration compiler that generates profile-scoped SSH keys, optional FIDO2 credentials, and managed Git configuration, then lets Git and OpenSSH evaluate those settings by directory.

One setup. Native runtime evaluation.

## Why GitSetu?

If you work across multiple organizations, freelance clients, or maintain personal open-source projects, you've likely experienced the pain of Git identity management.

| Problem | What happens | GitSetu fix |
|---------|-------------|-------------|
| 🔴 **Wrong author commits** | You push a freelance project and your work email shows up in the log | Directory-scoped `includeIf` auto-switches identity |
| 🔴 **SSH key collisions** | One SSH key for three GitHub accounts — pushes fail silently | Dedicated ED25519 keypair per profile |
| 🔴 **Corporate firewall blocks SSH** | Port 22 blocked — PATs get mixed between accounts, 403 errors | Profile/host credential routing through the selected native backend, with explicit Port 443 consent when supported |
| 🔴 **Forgot to switch identity** | Commit lands with the wrong email — can't rewrite public history | Pre-commit guard blocks the commit before it happens |
| 🔴 **Manual directory setup** | Missing workspace directory causes routing or clone errors | Auto-creates workspace directories (`mkdir -p`) on registration |
| 🔴 **Manual global config** | Edit `~/.gitconfig` before every context switch, then forget | One-time setup with native evaluation afterward |
| 🔴 **Tool rot & dependency hell** | Every solution requires a runtime that may be unavailable or change unexpectedly. | Pure Bash 3.2 core with explicit optional platform tools and a reviewed update path. |

GitSetu provisions the managed portions of a Git identity setup and reduces routine manual configuration. Review generated changes, provider setup, and third-party configuration before relying on them.
