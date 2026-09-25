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

2. **Zero Identity Leaks (Never Bypass Guard)**:
   - When installed, GitSetu's `guard` pre-commit hook is active for managed repositories.
   - If your commit halts with an `[Identity mismatch detected!]` warning:
     **STRICTLY FORBIDDEN:** DO NOT attempt to bypass this security check using `git commit --no-verify` or `-n`.
   - Instead, investigate using `gitsetu status`. If you are working across boundary directories, execute the commit using the ephemeral runner:
     ```bash
     gitsetu run <correct_profile> -- git commit -m "..."
     ```

3. **Ephemeral Identity Execution**:
   - When executing automated release tasks, cross-repo dependency updates, or one-off operations in arbitrary folders (e.g. `/tmp/`), always wrap execution:
     ```bash
     gitsetu run <profile> -- <command>
     ```

4. **Autonomous Self-Healing on Push Failures**:
   - If `git push` or `ssh -T` hangs or fails with `Permission denied` or `Connection timed out`:
     Run `gitsetu doctor` to diagnose broken agent sockets, missing keys, or Port 22 corporate firewall blocks.
     Follow the remediation advice provided by doctor.
