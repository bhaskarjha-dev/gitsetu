# GitSetu Packaging & Distribution Specifications

This directory contains package manager manifests, compilation scripts, and formulas for deploying GitSetu across all major developer ecosystems.

## Supported Distribution Channels

### 1. Node.js — npm & npx
- **Manifest:** `package.json`
- **Binary Wrapper:** `bin/gitsetu.js`
- **Usage:**
  ```bash
  # Instant run without global install
  npx gitsetu setup
  # Or global install
  npm install -g gitsetu
  ```

### 2. Standalone Single-File Monolith (`dist/gitsetu`)
- **Compiler:** `scripts/bundle.sh` (`make dist`)
- **Output:** `dist/gitsetu` (170 KB self-contained bash monolith with inlined modules)
- **Direct Curl Usage:**
  ```bash
  curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/dist/gitsetu -o ~/.local/bin/gitsetu && chmod +x ~/.local/bin/gitsetu
  ```

### 3. Windows — Microsoft WinGet (`packaging/winget/`)
- **Manifest Directory:** `packaging/winget/manifests/b/BhaskarJha/GitSetu/1.0.0/`
  - Version: `BhaskarJha.GitSetu.yaml`
  - Installer: `BhaskarJha.GitSetu.installer.yaml`
  - Locale: `BhaskarJha.GitSetu.locale.en-US.yaml`
- **Native Launcher:** `packaging/windows/gitsetu.cs` (compiles via built-in `csc.exe` via `build_launcher.ps1`)
- **Usage:**
  ```powershell
  winget install BhaskarJha.GitSetu
  ```

### 4. Windows — Scoop (`packaging/scoop/gitsetu.json`)
- **Manifest Path:** `packaging/scoop/gitsetu.json`
- **Target Bucket:** `scoop-main` or custom bucket `bhaskarjha-dev/scoop-bucket`
- **Usage:**
  ```powershell
  scoop install gitsetu
  ```

### 5. macOS & Linux — Homebrew (`packaging/homebrew/gitsetu.rb`)
- **Formula Path:** `packaging/homebrew/gitsetu.rb`
- **Target Tap:** `bhaskarjha-dev/homebrew-tap`
- **Usage:**
  ```bash
  brew tap bhaskarjha-dev/tap
  brew install gitsetu
  ```

### 6. Nix & NixOS — Nix Flake (`flake.nix`)
- **Flake Path:** `flake.nix` (repository root)
- **Usage:**
  ```bash
  # Run directly via Nix
  nix run github:bhaskarjha-dev/gitsetu -- setup
  # Install to user profile
  nix profile install github:bhaskarjha-dev/gitsetu
  ```

### 7. Arch Linux — AUR (`packaging/aur/`)
- **Files:** `packaging/aur/PKGBUILD`, `packaging/aur/.SRCINFO`
- **Usage:**
  ```bash
  yay -S gitsetu
  # or
  paru -S gitsetu
  ```

### 8. GitHub CLI Extension (`packaging/gh-extension/`)
- **Shim:** `packaging/gh-extension/gh-gitsetu`
- **Usage:**
  ```bash
  gh extension install bhaskarjha-dev/gh-gitsetu
  gh gitsetu setup
  ```

---

## Direct Zero-Dependency Shell Installers

- **macOS & Linux (POSIX Bash):**
  ```bash
  curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.sh | bash
  # Or via custom domain:
  # curl -sL https://gitsetu.bhaskarjha.dev/install | bash
  ```

- **Windows (PowerShell):**
  ```powershell
  irm https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/install.ps1 | iex
  # Or via custom domain:
  # irm https://gitsetu.bhaskarjha.dev/install.ps1 | iex
  ```
