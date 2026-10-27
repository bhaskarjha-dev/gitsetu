# Credential Architecture & Platform Delegation

In GitSetu v1.1.0, HTTPS credential management is intentionally delegated to Git's native credential-helper ecosystem (Git Credential Manager, `git-credential-osxkeychain`, and `git-credential-libsecret`) via standardized per-profile configuration, rather than maintaining a custom intermediary broker.

## Native Delegation via Per-Profile Username Routing

Git natively routes credentials using its `credential.https://<host>.username` configuration mechanism. When Git encounters an authenticated HTTPS request, it queries the system's authoritative credential helper with both the hostname and the profile-specific username.

Each managed profile configuration (`~/.config/gitsetu/profiles/<label>.gitconfig`) defines the profile's provider username:

```ini
[credential "https://github.com"]
    username = dev-user
```

When invoking operations inside a repository mapped to this profile:
1. Git's `includeIf` mechanism activates the profile's configuration.
2. Git supplies the configured username (`dev-user`) to the system credential helper (e.g. Git Credential Manager on Windows, Apple Keychain on macOS, or Secret Service on Linux).
3. The platform credential manager retrieves the isolated token associated with `dev-user@github.com`.

This zero-custom-broker design eliminates plaintext token leaks, respects OS keychain security policies, and avoids breaking on Git 2.46+ extended credential protocol attributes.

## Legacy Compatibility Shim (`gitsetu credential`)

For backwards compatibility with installations upgrading from v1.0.0 (where global `credential.helper = gitsetu credential` may have been installed), the CLI retains an inert compatibility shim:

```bash
gitsetu credential <get|store|erase>
```

When invoked:
- Standard input is drained to `/dev/null`.
- The command exits cleanly with status code `0`.
- Stale `helper = ... gitsetu credential` lines do not cause fatal Git errors.
- `gitsetu doctor` detects any remaining GitSetu helper lines outside the managed block, and `gitsetu doctor --repair` removes them.
