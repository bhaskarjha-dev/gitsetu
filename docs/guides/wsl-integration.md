# WSL Integration

Windows Subsystem for Linux (WSL) is fully supported by GitSetu, as WSL provides a true Linux environment (Ubuntu, Debian, etc.). Because GitSetu is written in Pure Bash 3.2, it runs natively inside WSL without any Windows-specific `.exe` dependencies.

## Installation

Inside your WSL terminal, run the standard Linux installation script:

```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-com/gitsetu/main/install.sh | bash
```

## Credential Brokering in WSL

The only complex aspect of using Git in WSL is managing HTTPS Personal Access Tokens (PATs). Linux `secret-tool` is often unavailable or difficult to configure in headless WSL environments.

If you attempt to use `gitsetu auth` in WSL, and `secret-tool` is missing, GitSetu will automatically fall back to storing credentials in a plain-text file (`~/.config/gitsetu/credentials`).

### Recommended: Git Credential Manager Core (GCM)

Microsoft provides the [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager), which bridges WSL Git with the native Windows Credential Manager.

If you have GCM installed, GitSetu respects it globally. However, remember that GCM struggles to differentiate between multiple accounts for the same host (e.g., two GitHub accounts). If you strictly need port 443 HTTPS cloning across multiple identities in WSL, we recommend using GitSetu's built-in file fallback, ensuring your `~/.config/gitsetu/` directory is secured with strict `700` permissions.

## File Systems

When creating profiles, always use the Linux paths inside your WSL environment (e.g., `~/projects/work` or `/mnt/c/Users/Name/work`).

Because GitSetu uses Git's native `includeIf` logic, it seamlessly understands Linux paths, even if they mount back to the Windows C: drive.
