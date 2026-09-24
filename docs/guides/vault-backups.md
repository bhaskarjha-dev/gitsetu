# Vault Backups & Restoration

GitSetu can export its managed configuration and private SSH keys as a private, authenticated vault for moving a setup between machines.

> [!IMPORTANT]
> Vaults created by the current implementation use the v2 authenticated format. The old unauthenticated/CBC format is rejected. There is no migration or legacy mode; create a new v2 vault from the current state.

## What is included

A vault contains only GitSetu-managed state:

- the versioned `profiles.conf` registry;
- generated profile `*.gitconfig` files;
- GitSetu's managed SSH configuration;
- private/public key pairs referenced by the managed profiles.

Files outside those managed roots are not collected. Keep the vault password separate from the vault and store the resulting file on protected offline or encrypted storage.

## Create a vault

```bash
gitsetu backup
```

GitSetu creates the archive in a private temporary directory, authenticates and encrypts it, and installs the final file atomically. The command asks for a new password twice. Passwords are not written to a sidecar file or passed to OpenSSL in command-line arguments.

The output name is similar to:

```text
gitsetu_vault_YYYYMMDD_HHMMSS.tar.gz.enc
```

> [!CAUTION]
> There is no recovery path for a lost or incorrect vault password. Verify that the password manager entry is correct before deleting the source machine.

## Restore a vault

Initialize GitSetu on the target machine, then run:

```bash
gitsetu restore /path/to/gitsetu_vault_YYYYMMDD_HHMMSS.tar.gz.enc
```

Restore follows a fail-closed sequence:

1. Verify the v2 envelope and authentication tag before decrypting state.
2. Reject wrong passwords, tampering, truncated archives, unsafe archive members, and unexpected file types.
3. Extract and validate the complete payload in a private staging directory.
4. Acquire the mutation lock, install the validated state transactionally, and roll back if a required step fails.

No partial restore is treated as a successful restore. A failed operation leaves the previous state recoverable from the pre-restore safety backup and the transaction's cleanup records.

## Format and compatibility

The v2 envelope contains a version marker, KDF parameters, random salts/IV material, ciphertext, and an authentication tag over the complete envelope and ciphertext. The implementation uses the OpenSSL primitives available on supported systems and separates encryption and authentication keys. Unsupported or older vault formats are rejected rather than silently accepted.

The profile registry is also versioned and strictly escaped. Old colon-delimited registries are rejected; there is no compatibility reader or transitional flag.

On Git for Windows, the npm launcher canonicalizes equivalent MSYS (`/c/...`) and Windows (`C:/...`) representations of `HOME`, `XDG_CONFIG_HOME`, and managed state paths before creating or restoring a vault. The manifest still records a single canonical source home, and paths outside the managed home boundary are rejected rather than silently remapped.
