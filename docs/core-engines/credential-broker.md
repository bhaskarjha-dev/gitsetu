# Credential Broker Engine

GitSetu provides a per-profile credential helper for HTTPS Personal Access Tokens (PATs). The lower-level keychain API namespaces records by profile, host, and optional path; the normal CLI currently resolves the active profile and host but does not parse Git's `path=` field.

## Why native stores need namespacing

Git sends a credential request such as:

```text
protocol=https
host=github.com
```

A native keychain queried only by `github.com` may return a personal token when a company repository expects a different one. GitSetu's lower-level API can include an optional credential path in its record key, but the normal `gitsetu credential` command currently leaves that path empty unless `GITSETU_CREDENTIAL_PATH` is supplied. Use the lower-level API or an explicit path when repository-level separation is required.

## Managed Git configuration

A managed profile can contain a scoped helper entry equivalent to:

```ini
[credential]
    helper = gitsetu credential
```

The helper reads Git's credential protocol from standard input, resolves the active profile from the working directory, and returns a matching record. It never scans or prints unrelated native keychain entries. GitSetu installs this helper only when no distinct user/system credential-helper policy is already configured; an existing helper remains authoritative.

Native backends are preferred:

- macOS Keychain (`security`);
- Windows Git Credential Manager;
- Linux Secret Service (`secret-tool`).

## Token lifecycle

Interactive setup and the standard Git credential protocol can store a token:

```bash
printf 'protocol=https\nhost=github.com\nusername=dev\npassword=PAT_TOKEN\n\n' \
  | gitsetu credential store
```

The `get` and `erase` actions use the same profile/host/path namespace at the keychain API boundary. The CLI path is empty unless explicitly supplied as described above. Records are versioned and fields are encoded so delimiters, whitespace, and Unicode values cannot be confused with record structure.

## Explicit zero-dependency fallback

Minimal Linux systems and containers may not provide a keychain daemon. GitSetu supports a deliberately selected plaintext backend for those environments:

```bash
GITSETU_CREDENTIAL_BACKEND=file gitsetu credential store
```

The file backend writes `~/.config/gitsetu/.tokens` with mode `0600` in a directory with mode `0700`, rejects symlinks and unsafe permissions, and warns on every use. It is **plaintext**, not encrypted storage, and is not enabled as a silent native-store fallback. Anyone who can read the file as the same operating-system user can recover the token.

If no native backend is available and the explicit file backend was not selected, credential operations fail with instructions for choosing one. Do not describe the plaintext file as an encrypted vault or as protected by the OS keychain.
