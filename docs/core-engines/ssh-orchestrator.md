# SSH Orchestrator Engine

**Automated multi-key generation, bounded agent registration, and isolated managed SSH configuration.**

Managing multiple SSH keys manually is highly error-prone. Standard workflows require generating distinct keys using specific CLI arguments, tracking permissions, and manually modifying host blocks in your global `~/.ssh/config` file.

GitSetu automates the managed portions of this lifecycle while leaving unrelated user configuration and explicit hardware/network choices to the operator.

---

## 1. Automated Key Bootstrapping

During profile creation (`gitsetu setup`), GitSetu queries if you require distinct SSH credentials for the workspace. It natively supports two primary cryptographic paths:

### ED25519 Software Signatures
Generates modern software keys using optimal cryptographic curves. The
comment is the profile email, and the default path is
`~/.ssh/id_ed25519_<label>`:
```bash
ssh-keygen -t ed25519 -C "email@example.com" -f ~/.ssh/id_ed25519_<label> -N ""
```

### Hardware Keys (FIDO2 / YubiKey)
Bootstraps resident keys backed by hardware tokens. This example assumes an
empty passphrase; setup prompts for one when passphrase protection is chosen:
```bash
ssh-keygen -t ed25519-sk -O resident -C "email@example.com" -f ~/.ssh/id_ed25519_sk_<label> -N ""
```
*(For a complete breakdown of hardware key workflows, consult the [Hardware Keys Guide](../guides/hardware-keys.md)).*

---

## 2. The OpenSSH `Include` Pivot & Safe Quoting

Historically, utilities modified `~/.ssh/config` files inline using search-and-replace scripts. This design pattern introduces catastrophic risk, frequently corrupting user configurations during unexpected exit events.

GitSetu resolves this by leveraging OpenSSH 7.3+'s native **`Include` directive** to keep GitSetu-managed routing separate from unrelated user host blocks.

### Stage 1: The Initial Hook Injection
GitSetu inspects your global config once. It prepends a single, managed
`Include` line to the top of your file. With the default POSIX XDG location it
looks like this (an explicit `XDG_CONFIG_HOME` changes the path):
```ini
Include ~/.config/gitsetu/profiles/ssh_config
```

### Stage 2: Sandboxed Orchestration
All customized host targets, host mapping blocks, and explicit key links are
stored inside GitSetu's managed state directory. The alias is formed from the
provider's first DNS label plus the profile label, so GitHub's `github.com`
provider produces `github-work`:

```ini
# ~/.config/gitsetu/profiles/ssh_config (generated)
Host github-work
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_work
    IdentitiesOnly yes
    AddKeysToAgent yes
```

The generated file is managed separately; unrelated host blocks remain outside
GitSetu's include. Review OpenSSH's effective configuration because first-use
host-key trust and Port 443 routing require explicit consent.

### Safe SSH Key Path Quoting
When a key path contains spaces, backslashes, quotes, or `%` (for example
`C:/Users/First Last/.ssh/id_ed25519` or `~/My Keys/id_ed25519`), the two
consumers use the appropriate quoting form:

```ini
# Git's generated profile value (the single quotes keep the path one shell word)
sshCommand = "ssh -o IdentitiesOnly=yes -i '~/My Keys/id_ed25519_work'"
```

```bash
# The environment exported by gitsetu run uses the same POSIX single-quote form
GIT_SSH_COMMAND="ssh -i '/home/alice/.ssh/My Keys/id_ed25519_work'"
```

The generated OpenSSH `IdentityFile` value is independently OpenSSH-quoted
(for example, `IdentityFile "~/My Keys/id_ed25519_work"`). This keeps spaces
and special characters from becoming extra shell words; it is not a claim that
an arbitrary unmanaged path is safe to execute.

---

## 3. Agent Virtualization, Platform Permissions & Dual Routing

Loading multiple keys concurrently often saturates remote authentication boundaries, returning `Too many authentication failures` errors during handshake negotiations.

GitSetu's compiler natively intercepts and resolves these session blocks:
- **`IdentitiesOnly yes`:** Hardcoded into every generated target file to prevent OpenSSH from blindly presenting unmapped keys cached in the global agent socket.
- **Keychain Injection:** Automates passphrase pre-loading on macOS (`UseKeychain yes`) and supported Linux agents.
- **Windows NTFS Permission Tolerance:** Under POSIX systems, OpenSSH mandates strict `0600` permissions on private keys. In supported Git Bash/MSYS NTFS contexts, POSIX modes may appear as `644`; GitSetu's diagnostic and verification engines recognize that environment without relaxing the POSIX requirement.
- **Dual Routing Architecture (ADR-0001):** Combines directory-scoped `core.sshCommand` with `~/.ssh/config` host aliases in the form `<provider-first-label>-<profile-label>` (for example, `github-work`), supporting mapped workspaces and explicitly configured external dependency clones (`go get`, `npm`, `cargo`).
