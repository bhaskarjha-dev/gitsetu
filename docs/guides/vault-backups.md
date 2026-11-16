# Vault Backups & Restoration

GitSetu can export its managed configuration and private SSH keys as a private, authenticated vault for moving a setup between machines.

> [!IMPORTANT]
> Vaults created by the current implementation use the v2 authenticated format. The old unauthenticated/CBC format is rejected. There is no migration or legacy mode; create a new v2 vault from the current state.

## What is included

A vault is built from an explicit allowlist of GitSetu-managed state:

- the strict v2 `profiles.conf` registry;
- generated profile `*.gitconfig` files;
- the generated `profiles/ssh_config` file, when present;
- the generated `hooks/pre-commit` file, when the guard is installed;
- registered, validated SSH private/public key pairs; and
- the legacy `.tokens` file, when present from an earlier installation.

The vault does **not** copy the user's global `~/.gitconfig` or
`~/.ssh/config`; restore regenerates those managed views after validating the
payload. It also does not export credentials held only in macOS Keychain,
Linux Secret Service, or Windows Git Credential Manager. Re-authenticate those
native credentials on the target machine. A backup refuses nonportable key
paths outside the managed `~/.ssh` root rather than silently collecting an
arbitrary file.

Keep the vault password separate from the vault and store the resulting file
on protected offline or encrypted storage.

## Create a vault

```bash
gitsetu backup
```

GitSetu creates the archive in a private temporary directory, authenticates and
encrypts it, and installs the final file atomically in the current working
directory. The command asks for a new password twice and requires at least 12
characters. Passwords are not written to a sidecar file or passed to OpenSSL in
command-line arguments. An existing output path is not overwritten.

For scripts, `GITSETU_VAULT_PASSWORD` supplies the password instead of the
prompt, for both `backup` and `restore`; `backup` still requires at least 12
characters. Environment variables are visible to other processes of the same
user, so GitSetu unsets the variable as soon as it has read it. Prefer the
prompt when you can.

With no `out_file` argument, the output name is:

```text
gitsetu_vault_YYYYMMDD_HHMMSS.gitsetu-v2.vault
```

> [!CAUTION]
> There is no recovery path for a lost or incorrect vault password. Verify
> that the password manager entry is correct before deleting the source
> machine.

## Restore a vault

Run the installed GitSetu CLI on the target machine; restore does not require a
pre-existing profile registry:

```bash
gitsetu restore /path/to/gitsetu_vault_YYYYMMDD_HHMMSS.gitsetu-v2.vault
```

Restore follows a fail-closed sequence:

1. Parse and authenticate the v2 envelope before changing live state.
2. Decrypt into private staging, then reject tampering, truncation, unsafe
   archive members, unexpected file types, invalid manifests, non-v2
   registries, and nonportable paths.
3. Acquire the mutation lock, snapshot the current state, and commit the
   registry, managed files, and key destinations transactionally.
4. Regenerate the global Git and SSH views; roll back the transaction if a
   required step fails.

A validation or authentication failure leaves the previous state untouched. A
failure during the commit is rolled back when possible. If rollback itself is
incomplete, GitSetu leaves a private transaction directory containing a
`RECOVERY_REQUIRED` marker and reports its path for manual review. It does not
create a pre-restore vault/password sidecar in the caller's working directory.

### When the target already has GitSetu state

If keys, profiles or `--remote` routes on the target differ from the vault,
`restore` asks before replacing them, and the default answer is no. Without a
terminal (scripts, CI, agents) it cancels with exit status 3 and changes
nothing. Pass `--force` to replace them without asking:

```bash
gitsetu restore /path/to/gitsetu_vault_YYYYMMDD_HHMMSS.gitsetu-v2.vault --force
```

A restore keeps the files it replaced (the managed Git and SSH configuration,
the keys and the profile registry) in a private folder,
`~/.config/gitsetu/backups/restore-<timestamp>/`, or under `$XDG_CONFIG_HOME`
when it is set. With `--force`, it prints that folder's path.

### Profile folders and keys

Profile folders inside the source machine's home move to the same place under
the target's home. Folders outside it (a second drive such as `D:\code`,
`/Volumes/...` or `/data/...`) keep their absolute path. Keys must live under
`~/.ssh`; `backup` refuses a key outside it.

## Format and compatibility

The v2 envelope contains a version marker, KDF parameters, random salts/IV
material, ciphertext, and an authentication tag over the complete envelope and
ciphertext. The implementation uses the OpenSSL primitives available on
supported systems and separates encryption and authentication keys. Unsupported
or older vault formats are rejected rather than silently accepted.

The profile registry inside a vault is also versioned and strictly escaped. A
vault that carries an old colon-delimited registry is rejected.

On Git for Windows, the npm launcher canonicalizes equivalent MSYS (`/c/...`)
and Windows (`C:/...`) representations of `HOME`, `XDG_CONFIG_HOME`, and
managed state paths before creating or restoring a vault. The default managed
state remains under the user's `.config/gitsetu` (or an explicit
`XDG_CONFIG_HOME`), not the `%LOCALAPPDATA%` installation directory. The
manifest records a single canonical source home; see "Profile folders and keys"
for how paths inside and outside it are restored.
