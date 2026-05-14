# Vault Backups & Restoration

**Bare-metal state extraction via OpenSSL encrypted archival bounds.**

Software developers cycle hardware instances regularly. Provisioning completely new cryptographic identity materials across entirely new OS bounds and subsequently registering those newly generated public keys across disparate upstream Git hosting providers can introduce hours of critical downtime.

GitSetu resolves this operational friction natively by providing high-speed encrypted vault extraction tools to migrate your complete structural state securely between machines.

---

## Vault Compilation (Backup)

To generate an atomic, portable extraction payload of your current configuration baseline, trigger the explicit backup command:

```bash
gitsetu backup
```

### Extracted Architecture Scope
The internal snapshot utility perfectly bundles the following active path domains:
- **Master Registry Maps:** Core configuration indexing (`~/.config/gitsetu/profiles.conf`).
- **Profile Layout Directives:** All dynamically mapped individual configuration override bounds (`~/.config/gitsetu/profiles/*.gitconfig`).
- **Zero-Trust Host Directives:** The active OpenSSH network translation paths (`~/.config/gitsetu/ssh/*`).
- **Private Cryptographic Keys:** All actively generated native software key bounds linked exclusively to existing GitSetu profile environments (`~/.ssh/id_*`).

### OpenSSL AES-256 Cryptography
Because the generated compressed target payload natively includes highly sensitive cryptographic private key components, GitSetu mandates strict encryption protocols. 

The backup routine natively leverages standard `openssl` binaries accessible on your runtime OS, encrypting the compiled target `tar` payload synchronously utilizing robust **AES-256-CBC** cryptographic blocks keyed heavily via standard `-pbkdf2` derivation loops.

> [!CAUTION]
> **Data Loss Warning:** During the initial execution phase, GitSetu securely prompts you to declare a master encryption password string. If you forget or lose this precise passphrase, your encrypted target vault file remains mathematically irretrievable. The structural data inside the vault cannot be extracted.

Upon successful completion, execution terminates cleanly yielding a highly portable encoded archive block named structurally as `gitsetu_backup_YYYYMMDD_HHMMSS.tar.gz.enc`. Store this block heavily isolated inside protected password managers, heavily constrained cloud bounds, or offline cold storage keys.

---

## Architecture Reconstruction (Restore)

After migrating your terminal execution environments to new bare-metal targets or initializing fresh OS bounds, simply initialize GitSetu strictly via the baseline [Installation](../getting-started/installation.md) pathway first.

Instead of calling the standard interactive setup wizard, explicitly execute the targeted payload reconstruction subcommand passing your target encrypted vault file payload:

```bash
gitsetu restore /path/to/gitsetu_backup_YYYYMMDD_HHMMSS.tar.gz.enc
```

### The Reconstruction Process
Execution requires providing your pre-declared encryption passphrase string inline. 
Upon successful decryption validation, GitSetu dynamically decomposes the `tar` payload structure into memory, accurately translating key path attributes directly into the local target `~/.ssh/` filesystem structure using aggressively constrained file permissions. The internal compiler reconstructs your global `~/.gitconfig` conditional routing mappings and injects the baseline OpenSSH `Include` directive flawlessly.

The entire environment reconstruction operation completes seamlessly in single-digit seconds, fully re-establishing your multi-profile capability pipeline instantaneously.
