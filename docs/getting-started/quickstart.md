# Quickstart

Get your Git identities routed automatically in **four simple steps**.

---

## 1. Provision your Identities

Run the interactive setup wizard. It will ask for your profile name, email, and the root directory for this identity.

```bash
gitsetu setup
```

*Example: Create profile "work" with `dev@company.com` and `~/work`.*
*Example: Create profile "personal" with `me@gmail.com` and `~/personal`.*

The wizard will automatically:
1. Generate an ED25519 SSH keypair specific to this profile.
2. Inject a Zero-Trust `Include` directive into your `~/.ssh/config`.
3. Create a managed block in your `~/.gitconfig` using the `includeIf` conditional.

---

## 2. Authenticate with your Provider

GitSetu has created your keys and configurations, but your Git provider (GitHub, GitLab) doesn't know about them yet. **Choose your authentication method below:**

### If you clone using SSH (`git@github.com:...`)
You **must** upload your newly generated public key to your provider, otherwise Git will throw a `Permission denied (publickey)` error when you try to clone.

1. Output your new public key to the terminal:
   ```bash
   cat ~/.ssh/id_ed25519_<profile>.pub
   ```
   *(Replace `<profile>` with the name you used in Step 1, e.g., `id_ed25519_work.pub`)*
2. Copy the entire output string and paste it into your [GitHub SSH Settings](https://github.com/settings/ssh/new).

### If you clone using HTTPS (`https://github.com/...`)
If you rely on Personal Access Tokens (PATs) instead of SSH keys, you must securely bind your token to your profile so you aren't prompted for a password on every push.

1. Bind your token using the Credential Broker:
   ```bash
   gitsetu auth <profile>
   ```
   *(e.g., `gitsetu auth work`)*
2. Paste your PAT when prompted (it will not echo to the screen). GitSetu securely encrypts it into your OS keychain.

---

## 3. Verify the State

Before starting work, verify that GitSetu has successfully provisioned your profiles and the infrastructure is sound.

```bash
$ gitsetu status
  work       dev@company.com    ~/work      ✓ active
  personal   me@gmail.com       ~/personal
  freelance  ak@freelance.io    ~/clients
```

---

## 4. The Magic: Just `cd` and work

GitSetu does the rest. It natively intercepts directory changes and switches your Git email, SSH key, and Credentials completely transparently. **You do not need to run any commands when switching projects.**

```text
$ cd ~/work/my-api && git commit -m "fix: auth bug"
Author: Aditya Kumar <dev@company.com> ← correct, automatically
```

> [!TIP]
> **Global Fallback:** By default, GitSetu enforces `useConfigOnly = true` — commits outside a mapped directory are blocked to prevent identity leakage. Want a catch-all? Set one profile's directory to `~/` and it becomes the global fallback.
