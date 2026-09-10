# SSH Orchestrator Engine

**Automated multi-key generation, native agent pre-loading, and zero-trust configuration isolation.**

Managing multiple SSH keys manually is highly error-prone. Standard workflows require generating distinct keys using specific CLI arguments, tracking permissions, and manually modifying host blocks in your global `~/.ssh/config` file.

GitSetu completely automates this lifecycle, bridging robust cryptographic security with absolute layout isolation.

---

## 1. Automated Key Bootstrapping

During profile creation (`gitsetu setup`), GitSetu queries if you require distinct SSH credentials for the workspace. It natively supports two primary cryptographic paths:

### ED25519 Software Signatures
Generates highly secure, modern software keys using optimal cryptographic curves:
```bash
ssh-keygen -t ed25519 -C "profile-identifier" -f ~/.ssh/id_ed25519_<label> -N ""
```

### Hardware Keys (FIDO2 / YubiKey)
Bootstraps highly tamper-resistant resident keys backed by hardware tokens:
```bash
ssh-keygen -t ed25519-sk -O resident -C "profile-identifier" -f ~/.ssh/id_ed25519_sk_<label>
```
*(For a complete breakdown of hardware key workflows, consult the [Hardware Keys Guide](../guides/hardware-keys.md)).*

---

## 2. The OpenSSH `Include` Pivot & Safe Quoting

Historically, utilities modified `~/.ssh/config` files inline using search-and-replace scripts. This design pattern introduces catastrophic risk, frequently corrupting user configurations during unexpected exit events.

GitSetu resolves this by leveraging OpenSSH 7.3+'s native **`Include` directive** to enforce a zero-trust network boundary.

### Stage 1: The Initial Hook Injection
GitSetu inspects your global config once. It prepends a single line to the top of your file:
```ini
Include ~/.config/gitsetu/profiles/ssh_config
```

### Stage 2: Sandboxed Orchestration
All customized host targets, host mapping blocks, and explicit key links are fully sandboxed inside GitSetu's localized state directory:

```ini
# ~/.config/gitsetu/profiles/ssh_config (Fully Automated)
Host github.com-work
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_work
    IdentitiesOnly yes
```

This ensures your primary SSH configuration remains completely untouched, allowing clean profile teardowns and safe multi-environment usage.

### Safe SSH Key Path Quoting
When SSH key paths contain spaces (e.g. `C:/Users/First Last/.ssh/...` or `~/My Keys/id_ed25519`), OpenSSH CLI commands can suffer from argument splitting. GitSetu automatically wraps key paths in escaped double-quotes within `core.sshCommand = ssh -i "..."` and when exporting `GIT_SSH_COMMAND="ssh -i \"...\""` in `gitsetu run`, preventing command parsing errors across all platforms.

---

## 3. Agent Virtualization, Platform Permissions & Dual Routing

Loading multiple keys concurrently often saturates remote authentication boundaries, returning `Too many authentication failures` errors during handshake negotiations.

GitSetu's compiler natively intercepts and resolves these session blocks:
- **`IdentitiesOnly = yes`:** Hardcoded into every generated target file to prevent OpenSSH from blindly presenting unmapped keys cached in the global agent socket.
- **Keychain Injection:** Automates passphrase pre-loading on macOS (`UseKeychain yes`) and Linux agents to optimize daily workflows seamlessly.
- **Windows NTFS Permission Tolerance:** Under POSIX systems, OpenSSH mandates strict `0600` permissions on private keys. Under Git Bash on Windows NTFS filesystems, POSIX permissions default to `644`. GitSetu's diagnostic and verification engines natively recognize this environment, tolerating `644` without producing false-positive permission warnings.
- **Dual Routing Architecture (ADR-0001):** Combines directory-scoped `core.sshCommand` with `~/.ssh/config` host aliases (`github.com-<label>`), ensuring seamless compatibility both inside mapped workspaces and for external dependency package manager clones (`go get`, `npm`, `cargo`) outside mapped folders.
