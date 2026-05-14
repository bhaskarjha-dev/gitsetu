# CLI Command Reference

GitSetu provides a focused suite of commands to manage your profiles, credentials, and configuration health.

## `gitsetu setup`
The interactive wizard used to provision new profiles.
- Prompts for Profile Label, Name, Email, and Directory.
- Prompts for SSH Key generation (ED25519 or FIDO2).
- Safely injects the managed block into `~/.gitconfig` and `~/.ssh/config`.

## `gitsetu status`
Displays a clean, tabulated overview of all registered profiles, highlighting which profile is currently active based on your current working directory.

## `gitsetu auth <profile>`
Securely prompts you to enter a GitHub/GitLab Personal Access Token (PAT) for a specific profile and stores it in the OS Keychain using the `gitsetu:<profile>:hostname` namespace.

## `gitsetu doctor`
A comprehensive diagnostic tool that instantly scans your environment for "drift" or misconfigurations.
- Verifies global `~/.gitconfig` syntax and managed blocks.
- Verifies `~/.ssh/config` syntax.
- Verifies SSH Agent connectivity and keys.
- Scans local repositories for conflicting `user.email` overrides.

## `gitsetu prompt`
A hyper-optimized command designed exclusively for `$PS1` or Starship shell prompt integration. It returns the active profile label in `< 2ms` without spawning unnecessary subshells.

## `gitsetu backup`
Compresses your GitSetu configuration and SSH private keys into a timestamped, OpenSSL AES-256 encrypted vault.

## `gitsetu restore <file>`
Decrypts a GitSetu vault and securely reconstructs your entire identity infrastructure on a new machine.

## `gitsetu update`
Triggers the native auto-updater. It fetches the latest stable release from GitHub over HTTPS, verifies integrity, and performs an atomic binary swap.

## `gitsetu install-guard` / `gitsetu remove-guard`
Manages the global pre-commit Identity Guard hook in `core.hooksPath` to protect against dual-state identity leaks.

## `gitsetu teardown`
A destructive command that completely purges all GitSetu configurations, profiles, and managed blocks from your system, cleanly restoring your Git environment to its original state.
