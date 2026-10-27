# WSL Integration

**Identity and file-path routing across Windows Subsystem for Linux environments.**

Because GitSetu's core is written for POSIX Bash 3.2, it is designed to work across supported WSL distributions (Ubuntu, Debian, Alpine, and others). Platform-specific credential tools, path mounts, and OpenSSH behavior still require normal host review.

---

## Installation Pathways

Inside WSL, use a reviewed checkout or a verified release artifact. Do not pipe a mutable remote URL into the shell:

```bash
bash install.sh
```

---

## Cross-Boundary File Harmonization

When generating isolated identity profiles inside WSL environments, developers frequently bridge Linux operational boundaries into native Windows disk mounts.

### Path Evaluation Mechanics
Always supply absolute Linux path strings targeting your target repositories (e.g., `~/projects/work` or `/mnt/c/Users/Name/work`).

When profiles are configured with absolute Linux paths, Git evaluates the corresponding `includeIf` rules. Repositories on WSL root drives and mounted Windows paths should be tested separately because Git and OpenSSH resolve the two environments differently.

---

## HTTPS Credential Routing in WSL

When operating inside WSL, HTTPS authentication is delegated to Git's native credential routing using per-profile `credential.https://<host>.username` directives.

### Microsoft Git Credential Manager (GCM) Interoperability
In WSL environments, the recommended pattern is configuring Git to route credentials to the Windows host's Git Credential Manager executable:

```bash
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"
```

GitSetu injects `credential.https://<host>.username` into each profile's configuration (`~/.config/gitsetu/profiles/<label>.gitconfig`). When Git queries GCM via the helper bridge, GCM partitions credentials by both hostname and the specific profile username, ensuring seamless multi-account isolation across WSL and Windows.

Alternatively, headless Linux WSL environments without Windows GCM access can configure standard Linux credential helpers (such as `libsecret` or `cache`).
