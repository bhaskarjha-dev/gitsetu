---
name: gitsetu
description: Enforces Git identity safety, multi-account routing, and SSH key management using GitSetu. Activate when command -v gitsetu succeeds or when the user mentions GitSetu.
---

# GitSetu AI Agent Skill

You are operating in an environment where GitSetu manages Git identities, SSH key routing, and commit safety.

## Provisioning Identities Without Prompts (Scriptable)

To provision a profile autonomously without interactive TTY prompts:
1. Ensure a global fallback identity is configured (`git config --global user.name` and `user.email`).
2. Run headless provisioning:
   ```bash
   gitsetu add <label> "<name>" <email> <dir> --no-guard </dev/null
   # or with remote routing:
   gitsetu profile add <label> --name="<name>" --email="<email>" --dir="<dir>" --remote="<pattern>" --no-guard </dev/null
   ```
3. Verification: Command exits 0, and in any repo inside `<dir>`:
   ```bash
   git -C <dir>/<repo> config user.email
   ```
   equals the provisioned `<email>`.

**Human Steps Required**:
- **SSH Key Upload**: Upload the generated public key (`~/.ssh/id_ed25519_<label>.pub`) to GitHub/GitLab settings.
- **Guard Activation Consent**: The pre-commit identity guard is opt-in per profile. Activate explicitly with `gitsetu guard --install`.

## Core Directives for AI Agents

1. **Verify Identity Before Committing**:
   - Check the effective identity for the current directory:
     ```bash
     gitsetu prompt
     # or inspect effective git config
     git config user.email
     ```
   - Ensure the resolved email matches the intended workspace (corporate for work, personal for personal).

2. **Diagnose Identity Routing Origins**:
   - Trace the exact file and scope defining any identity setting:
     ```bash
     gitsetu explain [path]
     ```
   - Displays the effective values for `user.name`, `user.email`, `core.sshCommand`, and `core.hooksPath` alongside their source files.

3. **Guard Enforcement (`GitSetu Guard: BLOCKING COMMIT`)**:
   - When the guard is enabled and detects an email mismatch, it blocks the commit with:
     `GitSetu Guard: BLOCKING COMMIT`
   - **Do NOT bypass** with `git commit --no-verify` or `-n`. Investigate why the author email differs from the matched profile with `gitsetu explain` and correct the configuration.

4. **Explicit Identity Execution**:
   - To run a single command under a specific profile identity:
     ```bash
     gitsetu run <profile> -- <command>
     ```
   - This sets `GIT_AUTHOR_*`, `GIT_COMMITTER_*`, and `GIT_SSH_COMMAND` with `-o IdentitiesOnly=yes` for the duration of the command.

5. **Diagnostic Verification**:
   - Run `gitsetu status` (or `gitsetu status --porcelain` for machine-readable output).
   - Run `gitsetu verify` for offline verification, or `GITSETU_VERIFY_NETWORK=1 gitsetu verify` to test SSH network connectivity.
