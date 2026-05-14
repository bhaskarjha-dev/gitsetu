# Troubleshooting GitSetu

GitSetu is designed to be self-healing, but Git environments can be uniquely complex. This guide helps you diagnose and resolve common identity and SSH issues.

---

## ⚡ Quick Diagnostics

Before digging into specifics, run GitSetu's built-in diagnostic tools. These instantly surface 90% of misconfigurations.

### 1. Check Active Status
Navigate to the repository you are having trouble with and run:
```bash
gitsetu status
```
This will tell you exactly which identity Git is using for the current directory and the specific SSH key it will attempt to use.

### 2. Verify Infrastructure
Run the full verification suite to ensure your keys, configs, and permissions are perfectly aligned:
```bash
gitsetu verify
```

### 3. Run Diagnostics
For deeper checks (registry integrity, SSH agent, managed block drift):
```bash
gitsetu doctor
```

---

## 🔑 SSH Connectivity Issues

> [!WARNING]
> If Git prompts you for a password or says `Permission denied (publickey)`, your SSH key is either not loaded, not registered with GitHub, or Git is using the wrong key.

### "Permission denied (publickey)"

This almost always means your public key hasn't been uploaded to GitHub/GitLab.

1. **Copy your public key:** `cat ~/.ssh/id_ed25519_‹label›.pub`
2. **Add it to GitHub:** Navigate to [GitHub SSH Settings](https://github.com/settings/ssh/new) and paste the key.
3. **Verify Connection:** Use the testing alias to verify GitHub recognizes the key:
   ```bash
   ssh -T git@github-‹label›
   # Expected: Hi username! You've successfully authenticated...
   ```

### "Key already exists" on GitHub

> [!IMPORTANT]
> GitHub strictly enforces a 1-to-1 mapping: Each SSH public key can only be attached to **ONE** GitHub account. 

If you see this error, you are trying to add a key to your `work` account that is already attached to your `personal` account. You must generate a unique key for each account (which `gitsetu setup` handles automatically).

### "Could not resolve hostname github-pro"

> [!NOTE]
> GitSetu generates host aliases (like `github-pro`) **purely for testing connectivity**. You do NOT need to use them when cloning repositories.

If you are running an `ssh -T` test and get this error, check your configuration:
1. Ensure `~/.ssh/config` exists and contains `Include ~/.config/gitsetu/ssh_config` at the top.
2. Verify that `~/.config/gitsetu/ssh_config` exists and contains the `Host github-pro` alias.
3. If anything is missing, simply run `gitsetu setup` again. GitSetu is fully idempotent and will safely repair the files.

---

## ⚙️ Git Configuration Issues

### The `includeIf` Rule is Not Triggering

If you `cd` into a profile directory but Git still uses your global identity, the `includeIf` rule failed to activate.

> [!TIP]
> Run `git config --show-origin --get-all core.sshCommand` to see exactly where Git is loading your SSH configuration from.

**Common Causes:**
1. **Trailing Slash:** The path in `~/.gitconfig` must end with a trailing slash (e.g., `gitdir:~/dev/pro/`). GitSetu handles this automatically.
2. **Missing `.git` Directory:** `includeIf` only triggers if the current folder is a Git repository, OR if you are actively cloning a repository into it.
3. **Dubious Ownership (VirtualBox/WSL):** Git actively blocks `includeIf` execution if the directory is owned by a different user (common in shared mounts). GitSetu automatically mitigates this using `safe.directory` rules. If you manually moved folders, run `gitsetu setup` again to update the safe directories.

### Identity Guard Hook Triggered

```text
⚠ gitsetu: Identity mismatch detected!
  Expected: work@company.com (profile: work)
  Actual:   personal@gmail.com
```

This is GitSetu protecting you! The pre-commit hook detected that you are about to commit code using an email address that does not match the profile configured for this directory.

**How to Fix:**
1. You may be in the wrong directory.
2. If you want to bypass the hook for a specific commit, run:
   ```bash
   git commit --no-verify
   ```

---

## 🗑️ Resetting Everything (The Nuclear Option)

If your Git or SSH environment is completely corrupted, the safest route is to wipe the slate clean and start over.

1. **Safely remove all GitSetu configurations:**
   ```bash
   gitsetu teardown
   ```
   *(This cleanly removes GitSetu from `~/.gitconfig` and `~/.ssh/config` without touching your custom settings. It leaves your SSH keys safely on disk so you aren't locked out of GitHub).*

2. **Re-run the setup:**
   ```bash
   gitsetu setup
   ```
   When prompted about existing keys, select `skip (keep current)` to immediately restore your access without needing to upload new keys to GitHub.
