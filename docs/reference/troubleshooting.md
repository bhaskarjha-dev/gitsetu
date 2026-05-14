# Troubleshooting & Diagnostics

**A comprehensive guide to rapidly surfacing and resolving environmental configuration drift.**

GitSetu is engineered to self-heal and fail-closed natively, but localized Git configurations, OS keychain constraints, and complex virtualization bounds frequently introduce obscure connectivity issues. This reference provides immediate resolution paths for the most common errors.

---

## ⚡ First-Line Defense: Built-in Scanners

Before executing manual log investigation, rely on GitSetu's built-in advanced diagnostic execution paths:

### `gitsetu status`
Instantly surfaces context. Run this inside the broken target repository. It evaluates your current directory path against global `includeIf` matrices and explicitly states which identity Git currently *believes* it should execute under.

### `gitsetu doctor`
The ultimate configuration health scanner. It deeply verifies global `~/.gitconfig` syntax integrity, `~/.ssh/config` block placement, agent availability, and cross-checks local repository state overrides.

---

## 🔑 OpenSSH Authentication Collisions

> [!WARNING]
> If a `git push` or `git fetch` operation hangs or immediately returns **`Permission denied (publickey)`**, your public SSH signature is either missing from your Git hosting provider, or OpenSSH is aggressively returning cached failures.

### Resolution: Unmapped Public Keys
If GitSetu generated a fresh keypair for your target profile, you **must** manually associate the public side of that signature with your upstream provider (GitHub, GitLab, Bitbucket).
1. Output the public signature: `cat ~/.ssh/id_ed25519_<profile>.pub`
2. Navigate to your provider's SSH Settings portal and paste the block exactly.
3. Verify connection manually using the isolated alias: `ssh -T git@github-<profile>`

> [!IMPORTANT]
> **"Key already exists" Error on GitHub:** GitHub strictly enforces a 1-to-1 mapping. Each SSH public key can only be attached to **ONE** GitHub account. If you see this error, you are trying to add a key to your `work` account that is already attached to your `personal` account. You must generate a unique key for each account (which `gitsetu setup` handles automatically).

> [!NOTE]
> **"Could not resolve hostname github-pro":** GitSetu generates host aliases (like `github-pro`) **purely for testing connectivity**. You do NOT need to use them when cloning repositories. You can continue cloning using standard `git@github.com:...` strings.

### Resolution: Agent Saturation ("Too many authentication failures")
If you manually loaded multiple legacy keys into your global `ssh-agent`, target hosts may disconnect after your host attempts to cycle blindly through incorrect signatures.
GitSetu explicitly sets `IdentitiesOnly = yes` in your generated profiles to mitigate this, but if problems persist, restart the SSH agent or use `ssh-add -D` to clear transient caches.

---

## 🛑 Pre-Commit Identity Guard Blocks

```text
[GitSetu Guard] BLOCKING COMMIT! Identity mismatch detected.
Expected Email: dev@company.com (Target Profile: 'work')
Active Runtime Email: personal@example.com
```

The GitSetu Pre-Commit Identity Guard threw a fatal error to intentionally protect your commit history from leaking. 

### Resolution: Local Configuration Overrides
The most common cause of this error is that a developer manually executed `git config user.email` inside the target directory at some point in the past. This places an explicit override block inside the hidden `.git/config` file, overriding GitSetu's conditional routing matrices.

To clear the conflict and allow GitSetu to resume control:
```bash
git config --local --unset user.email
git config --local --unset user.name
```

> [!TIP]
> **Bypassing the Guard:** If you intentionally want to bypass the Identity Guard for a specific, isolated commit without clearing your local overrides, you can utilize Git's native `--no-verify` flag: `git commit -m "wip" --no-verify`.

---

## ⚙️ Path Interception Failures (`includeIf` ignoring directories)

If you navigate into a configured directory and your terminal `$PS1` integration or `gitsetu status` command still reports your global fallback identity, Git is refusing to execute the conditional intercept rule.

### Resolution: Symlinks & Virtualization Bounds
Git is highly pedantic regarding target path strings.
1. **Trailing Slashes:** Ensure the mapped path ends in `/`. GitSetu handles this natively during `setup`.
2. **Mount Point Normalization:** If you are operating inside WSL or virtualized Windows mounts (`/mnt/c/`), ensure you utilized the absolute Linux `/mnt/c/` path structure during `gitsetu setup`, not the abstract Windows path.
3. **Safe Directory Checks:** If your target `.git` repository folder is owned by a different internal OS user (e.g. `root` inside Docker mounts), Git aborts `includeIf` logic instantly. Utilize Git's native safe directory bypass: `git config --global --add safe.directory /path/to/target/repository`.

---

## ☢️ The Nuclear Option: Clean State Teardown

If your environment is irrecoverably corrupted by cross-platform manual file tampering, execute GitSetu's native cleanup utility.

```bash
gitsetu teardown
```

This operation meticulously cleans all GitSetu managed layout boundaries from `~/.gitconfig` and OpenSSH paths safely without modifying your localized aliases, allowing you to execute `gitsetu setup` seamlessly against a fresh baseline.
