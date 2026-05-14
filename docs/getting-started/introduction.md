# Introduction

**The bridge between your identities and your repositories.**

GitSetu is a complete, zero-dependency pipeline that instantly generates your SSH keys, hardware signatures (FIDO2), and Git configs within a Zero-Trust architecture, then automatically switches them based on your directory. 

One setup. Automatic forever.

## Why GitSetu?

If you work across multiple organizations, freelance clients, or maintain personal open-source projects, you've likely experienced the pain of Git identity management.

| Problem | What happens | GitSetu fix |
|---------|-------------|-------------|
| 🔴 **Wrong author commits** | You push a freelance project and your work email shows up in the log | Directory-scoped `includeIf` auto-switches identity |
| 🔴 **SSH key collisions** | One SSH key for three GitHub accounts — pushes fail silently | Dedicated ED25519 keypair per profile |
| 🔴 **Corporate firewall blocks SSH** | Port 22 blocked — PATs get mixed between accounts, 403 errors | Per-profile credential broker via OS keychain |
| 🔴 **Forgot to switch identity** | Commit lands with the wrong email — can't rewrite public history | Pre-commit guard blocks the commit before it happens |
| 🔴 **Manual global config** | Edit `~/.gitconfig` before every context switch, then forget | One-time setup, automatic forever |
| 🔴 **Tool rot & dependency hell** | Every solution requires Node, Python, or Go. They break when runtimes update. | Pure Bash 3.2. Zero dependencies. Native auto-updater. |

GitSetu provisions a complete Git identity infrastructure from scratch. No manual config editing, no memorizing SSH aliases, no dependencies.
