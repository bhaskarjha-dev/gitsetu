---
name: gitsetu
description: Enforces Git identity safety, multi-account routing, and SSH key management using GitSetu. Use whenever performing git operations, commits, pushes, clones, or troubleshooting authentication.
---

# GitSetu AI Agent Skill

You may be operating on a workstation where GitSetu manages some Git and SSH identities. Verify the active profile and managed state before relying on it.

## The 4 Golden Directives for AI Agents

1. **Verify Identity Before Committing**:
   - Before executing `git commit` in any repository, verify the active identity:
     ```bash
     gitsetu status
     # or inspect git config user.email
     ```
   - Ensure the resolved email matches the intended workspace (e.g., corporate email for work repos, personal email for personal repos).

2. **Guard Respect (Opt-In)**:
   - When explicitly installed, GitSetu's `guard` pre-commit hook is active for repositories classified as managed.
   - If your commit halts with an `[Identity mismatch detected!]` warning, do not bypass it with `git commit --no-verify` or `-n`; investigate the effective identity and correct the managed state.
   - The guard is client-side: a local `core.hooksPath`, `--no-verify`, direct writes, and history rewrites can bypass it.

3. **Explicit Identity Execution**:
   - `gitsetu run <profile> -- <command>` exports Git identity variables and `GIT_SSH_COMMAND` for the child process. It does not change directory, select a profile-specific credential helper, or alter persistent Git configuration; run it from the intended workspace and verify the resulting context.

4. **Network Diagnostics**:
   - If `git push` or `ssh -T` hangs or fails, inspect the effective Git/SSH configuration with `gitsetu doctor` and `gitsetu verify`; these are primarily offline diagnostics and do not test provider connectivity. Use an explicit SSH test or provider tooling for network diagnosis, and review Port 443/host-key consent settings separately.
