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

## HTTPS Credential Brokering in WSL

The primary operational complexity introduced by headless WSL containers centers around mapping HTTPS Personal Access Tokens (PATs) securely. GitSetu's native WSL backend uses the Secret Service through `secret-tool`; it does not automatically turn a WSL installation into a native Windows GCM client.

### Explicit plaintext fallback
When a headless WSL instance has no D-Bus Secret Service, native credential operations fail by default. A user can explicitly select the zero-dependency file backend:

```bash
GITSETU_CREDENTIAL_BACKEND=file gitsetu credential store
```

The resulting `~/.config/gitsetu/.tokens` file is plaintext, with a `0700` directory and `0600` file. It is permission-restricted but not encrypted and cannot protect a token from malware or another process running as the same user.

### Microsoft Git Credential Manager (GCM) Interoperability
If your environment separately configures Microsoft's cross-platform [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager) to proxy WSL Git operations into a native Windows Credential Store, review that helper policy separately. GitSetu's WSL native mode is `secret-tool`; its Windows broker uses a namespaced synthetic GCM target and is not equivalent to automatically configuring `credential.helper = manager` inside WSL.

> [!WARNING]
> **GCM Identity Collisions:** Standard GCM pipelines may not partition tokens bound to identical overlapping hostnames. GitSetu's namespaced helper is the supported way to keep profile records separate; do not assume a generic GCM query can provide that isolation.
