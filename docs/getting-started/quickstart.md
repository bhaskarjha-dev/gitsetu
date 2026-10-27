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
1. Generate an Ed25519 SSH keypair specific to this profile.
2. Inject a managed `Include` directive into your `~/.ssh/config`.
3. Create a managed block in your `~/.gitconfig` using the `includeIf` conditional.
4. Automatically create the workspace directory (`mkdir -p`) if it does not already exist.

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
If you clone repositories using HTTPS instead of SSH, Git routes your authentication requests to your system's native credential helper (Git Credential Manager, Apple Keychain, or Linux Secret Service):

1. **Profile Username Binding:**
   During `gitsetu setup` or profile creation, specify your HTTPS provider username. GitSetu writes `credential.<provider>.username` into the profile configuration:
   ```ini
   [credential "https://github.com"]
       username = YOUR_USERNAME
   ```
2. **First Push / Authentication:**
   On your first `git push` or `git fetch` within the profile workspace, Git automatically invokes your operating system's native credential helper, pre-populating `YOUR_USERNAME`. Supply your Personal Access Token (PAT) when prompted; the native keychain securely stores it for future commands.

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

GitSetu generates Git's conditional configuration, so Git evaluates the active identity when you run commands in a managed directory. There is no background daemon; review `gitsetu status` when you need to inspect the selected profile.

```text
$ cd ~/work/my-api && git commit -m "fix: auth bug"
Author: Aditya Kumar <dev@company.com> ← correct, automatically
```

> [!TIP]
> **Global fallback:** A configured global profile can provide an identity for otherwise unmapped paths. The pre-commit guard itself treats repositories outside all managed profiles as unmanaged and fails open for its identity check, while malformed managed state fails closed. Keep Git's own `useConfigOnly` behavior in mind when diagnosing a blocked commit.
