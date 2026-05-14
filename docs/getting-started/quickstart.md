# Quickstart

Get your Git identities routed automatically in three simple steps.

## 1. Add your identities

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

## 2. Check your setup

Verify that GitSetu has successfully provisioned your profiles.

```bash
$ gitsetu status
  work       dev@company.com    ~/work      ✓ active
  personal   me@gmail.com       ~/personal
  freelance  ak@freelance.io    ~/clients
```

## 3. Just `cd` and work

GitSetu does the rest. It natively intercepts directory changes and switches your Git email, SSH key, and Credentials completely transparently.

```text
$ cd ~/work/my-api && git commit -m "fix: auth bug"
Author: Aditya Kumar <dev@company.com> ← correct, automatically
```

> [!TIP]
> **Global Fallback:** By default, GitSetu enforces `useConfigOnly = true` — commits outside a mapped directory are blocked to prevent identity leakage. Want a catch-all? Set one profile's directory to `~/` and it becomes the global fallback.
