# WSL Integration

**Seamless identity and file-path harmonization across Windows Subsystem for Linux environments.**

Because GitSetu is compiled strictly utilizing pure, POSIX-compliant Bash 3.2, it achieves absolute native execution compatibility across all Windows Subsystem for Linux (WSL) environments (Ubuntu, Debian, Alpine, etc.). The tool requires zero Windows-specific `.exe` dependencies, operating entirely decoupled from standard host virtualization layers.

---

## Installation Pathways

Inside your WSL terminal execution layer, initialize the standard Linux bootstrapping script exactly as you would on bare-metal hardware:

```bash
curl -sL https://gitsetu.bhaskarjha.dev/install | bash
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

### Native Vault Fallbacks
When you execute the `gitsetu auth` command to secure an active profile token inside a headless WSL instance lacking D-Bus secret integrations, GitSetu dynamically switches execution modes.

It automatically provisions an isolated, restricted permissions payload vault file located directly at `~/.config/gitsetu/credentials`. The directory enforces strict POSIX `700` ownership bounds to guarantee containment.

### Microsoft Git Credential Manager (GCM) Interoperability
If your local environment utilizes Microsoft's cross-platform [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager) to securely proxy WSL Git operations back into your native Windows Credential Store, GitSetu respects the configuration gracefully.

> [!WARNING]
> **GCM Identity Collisions:** Standard GCM pipelines struggle fundamentally to partition tokens bound to identical overlapping base hostnames (e.g., mapping distinct personal and corporate tokens concurrently to `github.com`). If you absolutely require Port 443 HTTPS multi-tenant cloning capabilities, we explicitly recommend utilizing GitSetu's native built-in fallback vault architecture.
