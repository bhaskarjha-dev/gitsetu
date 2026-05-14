# Installation

GitSetu is designed to be as lightweight as possible. It runs natively on your system using pure POSIX Bash, requiring absolutely zero external dependencies like Node.js, Python, or Go.

## Prerequisites

GitSetu runs on any Unix-like system.
- **macOS**
- **Linux** (Ubuntu, Debian, Arch, Fedora, etc.)
- **Windows** (via Git Bash or WSL)

The only strict requirements are:
- `bash` (3.2 or higher — natively installed on almost every system)
- `git`
- `curl` (for the installation script)
- `ssh-keygen` (for SSH key generation, part of OpenSSH)

## Install Script

The easiest way to install GitSetu is via the automated bootstrap script.

```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-com/gitsetu/main/install.sh | bash
```

### What does the script do?
1. Clones the GitSetu repository to `~/.local/share/gitsetu`.
2. Creates a global symlink at `/usr/local/bin/git-setu` (or `~/.local/bin/git-setu` if running without sudo).
3. Allows you to run the CLI as either `gitsetu` or `git setu` directly from your terminal.

## Upgrading

GitSetu includes a native, atomic auto-updater. To upgrade to the latest version, simply run:

```bash
gitsetu update
```

This will safely fetch the latest release from GitHub over HTTPS, verify integrity, and atomically swap the binaries without leaving orphaned files.

---

## Uninstalling GitSetu

Because GitSetu is deeply integrated into your `~/.gitconfig` and OpenSSH configuration files, you should **never** simply delete the executable binary. Doing so will leave broken `includeIf` and `Include` references in your global configurations.

To completely and safely uninstall GitSetu, use the native teardown command:

```bash
gitsetu teardown
```

**What does teardown do?**
1. Safely removes all GitSetu managed blocks from `~/.gitconfig` and `~/.ssh/config`.
2. Leaves your generated SSH keys (`~/.ssh/id_*`) safely on disk so you don't lose access to GitHub.
3. Completely deletes the `~/.config/gitsetu` application data directory.
4. Instructs you on how to remove the final binary from your path.
