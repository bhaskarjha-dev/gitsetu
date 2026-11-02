# Installation

GitSetu is a Bash 3.2-compatible CLI with native Git and OpenSSH integration. It does not require Node.js, Python, or Go for the shell implementation. Optional credential stores and OpenSSL are detected explicitly; a feature that needs one fails clearly when it is unavailable.

> [!IMPORTANT]
> GitSetu v1.1.0 is officially distributed via GitHub Releases and npm. For air-gapped or developer environments, install directly from a reviewed source checkout.

---

## 1. Quick Onboarding (Reviewed Checkout)

### macOS & Linux (POSIX Bash)
From a reviewed checkout, run:
```bash
bash install.sh
```

### Windows (Native PowerShell)
From a reviewed checkout, run:
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

> [!IMPORTANT]
> **Windows prerequisite:** GitSetu requires [Git for Windows](https://git-scm.com/download/win), which provides `git.exe` and `bash.exe`.

> [!TIP]
> The PowerShell installer creates native `gitsetu.cmd` shims and can add `%LOCALAPPDATA%\gitsetu\bin` to the user `PATH`. It does not execute an unreviewed remote script through `irm | iex`.

### Windows (via Git Bash)
From the same reviewed checkout:
```bash
bash install.sh
```

---

## 2. Package Managers & Ecosystem Wrappers

### Node.js — npm & npx

Install GitSetu globally via npm:

```bash
npm install -g gitsetu
```

Or execute commands directly via npx without manual installation:

```bash
npx gitsetu status
```

---

## 3. Standalone Monolith Bundle

GitSetu can be compiled into a standalone, single-file executable containing all core modules:

```bash
make dist
./dist/gitsetu --version
```

Official standalone binaries are published on [GitHub Releases](https://github.com/bhaskarjha-dev/gitsetu/releases).

---

## 4. Manual Installation (From Source Checkout)

From a cloned GitSetu repository:

```bash
bash install.sh
export PATH="$HOME/.local/bin:$PATH"
```

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

Use the reviewed uninstaller from the same installed release or checkout. Do not pipe a mutable remote URL into a shell.

- **macOS / Linux:**
  ```bash
  bash uninstall.sh
  ```
- **Windows (PowerShell):**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  ```
- **npm:** no public development package is installed; remove only a local tarball install with `npm uninstall -g gitsetu` if you created one.
- **WinGet:** no public development manifest is installed.
- **Homebrew:** no public development formula is installed.
- **Scoop:** no public development manifest is installed.
- **GitHub CLI:** remove only an extension you explicitly installed; the development checkout wrappers require no global extension removal.
