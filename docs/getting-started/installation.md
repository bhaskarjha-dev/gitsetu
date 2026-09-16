# Installation

GitSetu is designed to be as lightweight and accessible as possible. It runs natively across macOS, Linux, and Windows with zero external runtimes (no Node.js, Python, or Go required for shell installations). On Windows, the only prerequisite is **Git for Windows**.

---

## 1. Quick Onboarding (Zero-Dependency Shell Installers)

### macOS & Linux (POSIX Bash)
Run in your standard terminal (Terminal, iTerm2, Alacritty, Kitty):
```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.sh | bash
# Or via custom domain:
# curl -sL https://gitsetu.bhaskarjha.dev/install | bash
```

### Windows (Native PowerShell)
Open **PowerShell**, **Windows Terminal**, or **Command Prompt** and run:
```powershell
irm https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.ps1 | iex
# Or via custom domain:
# irm https://gitsetu.bhaskarjha.dev/install.ps1 | iex
```

> [!IMPORTANT]
> **Windows Prerequisite:** GitSetu requires **Git for Windows** (which provides standard `git.exe` and `bash.exe`).
> If you do not have Git installed yet, run:
> ```powershell
> winget install Git.Git
> ```
> or download from [git-scm.com/download/win](https://git-scm.com/download/win).

> [!TIP]
> **Zero Friction on Windows:** The PowerShell installer automatically configures native `gitsetu.cmd` and `gitsetu.ps1` command shims and adds `%LOCALAPPDATA%\gitsetu\bin` directly to your Windows User `PATH`. You can run `gitsetu` or `git setu` immediately in PowerShell, Command Prompt, or VS Code without opening Git Bash!

### Windows (via Git Bash)
If you prefer working exclusively inside Git Bash:
```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.sh | bash
```

---

## 2. Package Managers & Ecosystem Wrappers

### Node.js — npm & npx
Run instantly without global installation, or install globally across any OS:
```bash
# Instant one-shot setup (no installation needed)
npx gitsetu setup --auto

# Or global install
npm install -g gitsetu
```

### Windows — Microsoft WinGet
Install via the official Windows Package Manager:
```powershell
# Official Microsoft Package Identifier (Publisher.PackageName)
winget install BhaskarJha.GitSetu

# Or once indexed in local manifests:
winget install GitSetu
```

> [!NOTE]
> `BhaskarJha.GitSetu` is the canonical, collision-proof Package Identifier in Microsoft's official `winget-pkgs` repository.

### Windows — Scoop
Install via Scoop bucket:
```powershell
scoop bucket add gitsetu https://github.com/bhaskarjha-dev/scoop-gitsetu
scoop install gitsetu
```

### macOS & Linux — Homebrew
Install via Homebrew tap:
```bash
brew tap bhaskarjha-dev/tap
brew install gitsetu
```

### Arch Linux — AUR
Install via your preferred AUR helper:
```bash
yay -S gitsetu
# or
paru -S gitsetu
```

### Nix & NixOS — Nix Flake
Execute or install hermetically via Nix Flakes:
```bash
# Run directly without polluting system state
nix run github:bhaskarjha-dev/gitsetu -- setup --auto

# Or install to your user environment
nix profile install github:bhaskarjha-dev/gitsetu
```

### GitHub CLI Extension
Integrate directly into `gh` CLI:
```bash
gh extension install bhaskarjha-dev/gh-gitsetu
gh gitsetu setup
```

---

## 3. Standalone Monolith (Direct Curl)

If you need a single, zero-dependency executable without cloning the repository or downloading extra folders:

```bash
mkdir -p ~/.local/bin
curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/dist/gitsetu -o ~/.local/bin/gitsetu
chmod +x ~/.local/bin/gitsetu
```

---

## 4. Manual Installation (From Source)

If your machine is behind an air-gapped firewall:

```bash
# 1. Clone the repository
git clone https://github.com/bhaskarjha-dev/gitsetu.git ~/.local/share/gitsetu

# 2. Symlink or copy the binary
mkdir -p ~/.local/bin
ln -sf ~/.local/share/gitsetu/gitsetu ~/.local/bin/gitsetu
ln -sf ~/.local/share/gitsetu/gitsetu ~/.local/bin/git-setu

# 3. Ensure ~/.local/bin is in your PATH
export PATH="$HOME/.local/bin:$PATH"
```

---

## Post-Installation First Steps

Once installed, verify that GitSetu is available:
```bash
gitsetu --version
# Outputs: gitsetu v1.0.0
```

### Instant 1-Second Setup
Bootstrap all detected identities without prompts:
```bash
gitsetu setup --auto
```

### Interactive Dashboard Setup
Review and tweak your identities visually:
```bash
gitsetu setup
# Or use the native Git alias:
git setu setup
```

---

## Testing in Windows Sandbox

If you are on Windows and want to test GitSetu safely in an isolated, disposable virtual machine without touching your personal configuration, clone the repository and launch the sandbox harness:
```cmd
.\sandbox\launch_sandbox.bat
```

---

## Upgrading

GitSetu includes an atomic self-updater:
```bash
gitsetu update
```

Or upgrade through your package manager:
```bash
npm update -g gitsetu         # npm
winget upgrade BhaskarJha.GitSetu # WinGet
scoop update gitsetu          # Scoop
brew upgrade gitsetu          # Homebrew
yay -Syu gitsetu              # Arch AUR
```

---

## Complete Uninstallation

Because GitSetu integrates cleanly into your global `~/.gitconfig` and OpenSSH configuration files, **always run teardown first** before deleting files:

```bash
gitsetu teardown --deep
```

### Removing Binaries & Files

- **macOS / Linux:**
  ```bash
  curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/uninstall.sh | bash
  ```
- **Windows (PowerShell):**
  ```powershell
  irm https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/uninstall.ps1 | iex
  ```
- **npm:**
  ```bash
  npm uninstall -g gitsetu
  ```
- **WinGet:**
  ```powershell
  winget uninstall BhaskarJha.GitSetu
  ```
- **Homebrew:**
  ```bash
  brew uninstall gitsetu
  ```
- **Scoop:**
  ```powershell
  scoop uninstall gitsetu
  ```
- **GitHub CLI:**
  ```bash
  gh extension remove gh-gitsetu
  ```
