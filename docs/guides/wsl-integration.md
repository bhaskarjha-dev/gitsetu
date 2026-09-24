# WSL Integration

**Seamless identity and file-path harmonization across Windows Subsystem for Linux environments.**

Because GitSetu is compiled strictly utilizing pure, POSIX-compliant Bash 3.2, it achieves absolute native execution compatibility across all Windows Subsystem for Linux (WSL) environments (Ubuntu, Debian, Alpine, etc.). The tool requires zero Windows-specific `.exe` dependencies, operating entirely decoupled from standard host virtualization layers.

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

Because GitSetu compiles paths directly into Git's native `includeIf` conditional boundaries, Git interprets the Linux-structured paths seamlessly during runtime evaluation. Execution matches reliably whether target repositories exist on isolated WSL root drives or explicitly mounted back across to primary Windows `C:\` bounds.

---

## HTTPS Credential Brokering in WSL

The primary operational complexity introduced by headless WSL containers centers around mapping HTTPS Personal Access Tokens (PATs) securely, as standard Linux secret layers (e.g., `secret-tool`) typically remain unavailable in CLI-only runtimes.

### Explicit plaintext fallback
When a headless WSL instance has no D-Bus Secret Service, native credential operations fail by default. A user can explicitly select the zero-dependency file backend:

```bash
GITSETU_CREDENTIAL_BACKEND=file gitsetu credential store
```

The resulting `~/.config/gitsetu/.tokens` file is plaintext, with a `0700` directory and `0600` file. It is permission-restricted but not encrypted and cannot protect a token from malware or another process running as the same user.

### Microsoft Git Credential Manager (GCM) Interoperability
If your local environment utilizes Microsoft's cross-platform [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager) to securely proxy WSL Git operations back into your native Windows Credential Store, GitSetu respects the configuration gracefully.

> [!WARNING]
> **GCM Identity Collisions:** Standard GCM pipelines may not partition tokens bound to identical overlapping hostnames. GitSetu's namespaced helper is the supported way to keep profile records separate; do not assume a generic GCM query can provide that isolation.
