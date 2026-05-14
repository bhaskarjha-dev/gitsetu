# ADR 0001: The Dual-Strategy SSH Routing Architecture

## Status
**Accepted** (May 2026)

## Context
GitSetu operates on a core philosophy of zero external dependencies. A critical component of its architecture is routing Git traffic through the correct SSH identity. 

There was significant debate regarding whether to rely exclusively on Git's native `core.sshCommand` (via `includeIf`) or to continue mutating the OS-level `~/.ssh/config` file to provide host aliases (e.g., `github-pro`). Theoretical audits suggested that `core.sshCommand` was sufficient and that the `~/.ssh/config` strategy was a "brittle legacy" approach.

Extensive terminal simulations were conducted to test Git's internal evaluation of `includeIf` during the `git clone` lifecycle and, critically, how external package managers interact with Git subprocesses.

## Decision
We will **permanently retain the dual-strategy architecture** (using both `core.sshCommand` and `~/.ssh/config` aliases).

### 1. Why `core.sshCommand` alone is insufficient
When external package managers (such as `go get`, `npm`, `cargo`, or `terraform init`) fetch private dependencies, they frequently spawn a `git clone` subprocess that targets a **global cache directory** (e.g., `~/.go/pkg/mod/...` or `~/.npm/...`).
Because the target directory of the clone falls *outside* the developer's mapped local workspace (e.g., `~/work/`), Git's `includeIf "gitdir:~/work/"` directive silently fails. The `core.sshCommand` is dropped, authentication defaults to the generic SSH key, and the package manager abruptly fails.

### 2. The Necessity of `~/.ssh/config`
Because Git cannot dynamically route identities for external cache directories based purely on the `pwd` of the parent process, the only mathematically sound solution is OS-level network routing.
By providing `~/.ssh/config` aliases (e.g., `Host github-pro`), developers have a definitive manual escape hatch. They can configure their package managers (e.g., via `url.insteadOf` or direct aliases) or manually clone repositories into unmapped directories while explicitly enforcing the correct identity.

## Consequences
*   **For Developers:** Future contributors and AI agents are strictly forbidden from attempting to "refactor" or remove the `~/.ssh/config` alias generation under the mistaken belief that Git's `includeIf` is a monolithic solution.
*   **For Architecture:** The complexity of maintaining two separate routing layers is accepted as a permanent, necessary cost of doing business in a flawed multi-tenant Git ecosystem.
