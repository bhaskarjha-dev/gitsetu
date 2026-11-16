# Installation

GitSetu is a Bash 3.2-compatible CLI with native Git and OpenSSH integration. The installed program needs no Node.js, Python or Go; Node.js is needed only for the npm package and for building from a checkout. Optional credential stores and OpenSSL are detected explicitly; a feature that needs one fails clearly when it is unavailable.

> [!IMPORTANT]
> GitSetu v1.1.0 is distributed through GitHub Releases and npm.

---

## 1. Release Installer (Linux, macOS, WSL, Git Bash)

```bash
curl -fsSL https://github.com/bhaskarjha-dev/gitsetu/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
```

The installer downloads the release's single-file `gitsetu`, checks its SHA-256 and size against the values pinned in the installer, and installs it under `~/.local/share/gitsetu`, with the `gitsetu` and `git-setu` commands in `~/.local/bin`. It needs Bash, `curl` or `wget`, and `sha256sum` or `shasum`. When the GitHub CLI is installed and logged in, it also verifies the release's build attestation. To read the installer first, download `install.sh` from the release, review it, and run `bash install.sh`.

> [!IMPORTANT]
> **Windows prerequisite:** GitSetu requires [Git for Windows](https://git-scm.com/download/win), which provides `git.exe` and `bash.exe`.

---

## 2. npm (All Platforms)

Requires Node.js 18 or later:

```bash
npm install -g gitsetu
```

Or run a command without installing:

```bash
npx gitsetu status
```

---

## 3. Windows: PowerShell and CMD

To use `gitsetu` from PowerShell and CMD, install from a checkout of the release tag:

```powershell
git clone https://github.com/bhaskarjha-dev/gitsetu
cd gitsetu
git checkout v1.1.0
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> [!TIP]
> The PowerShell installer builds the native launcher, creates `gitsetu.cmd` shims and can add `%LOCALAPPDATA%\gitsetu\bin` to the user `PATH`. It does not execute an unreviewed remote script through `irm | iex`.

---

## 4. From Source

From a clean checkout on Linux, macOS or Git Bash:

```bash
bash install.sh
export PATH="$HOME/.local/bin:$PATH"
```

This builds the single-file bundle with `scripts/bundle.sh` and installs it, so it needs Node.js 18 or later. The installer refuses a checkout with uncommitted changes.

---

## 5. Standalone Bundle

GitSetu can be compiled into a standalone, single-file executable containing all core modules:

```bash
make dist
./dist/gitsetu --version
```

Each [GitHub Release](https://github.com/bhaskarjha-dev/gitsetu/releases) also publishes this bundle as `gitsetu`, with `SHA256SUMS`.

---

## Post-Installation First Steps

Once installed, verify that GitSetu is available:
```bash
gitsetu --version
# Outputs: gitsetu v1.1.0
```

### Automated Setup
Apply the detected identity blueprint without interactive input in non-TTY use:
```bash
gitsetu setup --auto
```

This is an apply mode, not a review-only proposal. In a TTY it can still ask about guard installation or an explicit FIDO2 fallback; use interactive `gitsetu setup` when review is required.

### Interactive Dashboard Setup
Review and tweak your identities visually:
```bash
gitsetu setup
# Or use the native Git alias:
git setu setup
```

---

## Upgrading

To upgrade GitSetu, download the latest release installer or update via npm:

```bash
# Via GitHub Release installer:
curl -fsSL https://github.com/bhaskarjha-dev/gitsetu/releases/latest/download/install.sh | bash

# Or via npm:
npm install -g gitsetu@latest
```

---

## Complete Uninstallation

Because GitSetu integrates cleanly into your global `~/.gitconfig` and OpenSSH configuration files, **always run teardown first** before deleting files:

```bash
gitsetu teardown --deep
```

### Removing Binaries & Files

Use the uninstaller from the same release or checkout you installed from:

- **Release installer (macOS, Linux, WSL, Git Bash):** download `uninstall.sh` from the release, then run it:
  ```bash
  curl -fsSLO https://github.com/bhaskarjha-dev/gitsetu/releases/latest/download/uninstall.sh
  bash uninstall.sh
  ```
- **Checkout install:** run `bash uninstall.sh` from the checkout.
- **Windows (PowerShell), from the checkout you installed from:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  ```
- **npm:** `npm uninstall -g gitsetu`.
