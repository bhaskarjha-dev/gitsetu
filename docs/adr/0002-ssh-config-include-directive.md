# ADR 0002: The OpenSSH `Include` Directive Pivot

## Status
**Accepted** (May 2026)

## Context
As established in ADR 0001, GitSetu must generate OS-level SSH host aliases (`Host github-pro`) to provide a manual fallback for complex dependency cloning workflows. 

Historically, GitSetu implemented this by using inline `awk` commands to rip open the user's global `~/.ssh/config` file, locate specific `[gitsetu:managed:start]` markers, and surgically replace the text blocks. 

This approach was identified as a critical architectural vulnerability (a "ticking time bomb"). Complex user configurations, unexpected formatting, or process interruptions during the atomic `mv` operation posed a massive risk of corrupting the user's global network access configuration. This violated GitSetu's core "Zero-Trust" mandate.

## Decision
We will **migrate SSH alias orchestration exclusively to the OpenSSH `Include` directive.**

1.  GitSetu will cease all inline mutation of `~/.ssh/config` blocks.
2.  All generated aliases will be written to a dedicated, isolated file: `~/.config/gitsetu/ssh_config`.
3.  During setup, GitSetu will perform a one-time check to ensure the directive `Include ~/.config/gitsetu/ssh_config` exists at the **absolute top** of the user's `~/.ssh/config` file.

### Why the Absolute Top?
OpenSSH configuration parsing operates on a **"first-match wins"** rule. If the `Include` directive is placed at the bottom of the file, any generic blocks (e.g., `Host *` or `Host github.com`) defined earlier by the user will lock in their parameter values, causing GitSetu's aliases to be silently overridden. Placing the `Include` directive at the top guarantees precedence while cleanly isolating the tool's footprint.

### Sandbox Validation
Testing confirmed that if the included file (`~/.config/gitsetu/ssh_config`) does not exist (e.g., following a `gitsetu teardown` operation), OpenSSH gracefully and silently ignores the `Include` directive without crashing or terminating the SSH handshake.

## Consequences
*   **For Security:** Complete Zero-Trust isolation is achieved. GitSetu no longer risks corrupting the user's legacy SSH configurations.
*   **For Maintainability:** The Bash script logic in `lib/ssh.sh` becomes drastically simpler, eliminating the need for brittle, multi-line `awk` parsers.
*   **For Compatibility:** The `Include` directive requires OpenSSH 7.3+ (released August 2016). This is deemed an acceptable minimum requirement for modern Git multi-tenant environments.
