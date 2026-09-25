# Installation

GitSetu is a Bash 3.2-compatible CLI with native Git and OpenSSH integration. It does not require Node.js, Python, or Go for the shell implementation. Optional credential stores and OpenSSL are detected explicitly; a feature that needs one fails clearly when it is unavailable.

> [!IMPORTANT]
> v1.1.0 is a verified, publication-ready release candidate. The canonical release workflow has not yet published the package-manager assets or immutable download. Do not install a mutable `main` URL as if it were a release artifact. Use a reviewed tag, a verified package-manager manifest, or a local candidate checkout and verify its provenance before installation.

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
> The PowerShell installer creates native `gitsetu.cmd` and `gitsetu.ps1` shims and can add `%LOCALAPPDATA%\gitsetu\bin` to the user `PATH`. It does not execute an unreviewed remote script through `irm | iex`.

### Windows (via Git Bash)
From the same reviewed checkout:
```bash
bash install.sh
```

---

## 2. Package Managers & Ecosystem Wrappers

> [!IMPORTANT]
> No public npm, WinGet, Scoop, Homebrew, AUR, Nix, or GitHub CLI package is
> published for the v1.1.0 release candidate. The repository contains withheld
> templates and test fixtures only. Do not treat a mutable branch, registry
> name, or template placeholder as an installable release.

### Node.js — npm & npx

The npm package is private while the release candidate is being prepared. Use
the reviewed checkout installation path instead of a registry command:

```bash
bash install.sh
```

### Windows — Microsoft WinGet

No public WinGet manifest is published. Run `install.ps1` from a reviewed
checkout and verify the resulting local build.

### Windows — Scoop

No public Scoop manifest is published. The checked-in manifest is a
non-installable release template.

### macOS & Linux — Homebrew

No public Homebrew formula is published. The checked-in formula is a
non-installable release template.

### Arch Linux — AUR

No public AUR package is published. The checked-in `PKGBUILD` is a
non-installable release template.

### Nix & NixOS — Nix Flake

The flake is a development checkout definition pinned to an immutable nixpkgs
revision. A local checkout can be evaluated without fetching GitSetu from a
mutable remote:

```bash
nix build .#default
```

### GitHub CLI Extension

The `gh-gitsetu` and `gh-setu` extension repositories are not published yet.
The checked-out wrappers are available for local testing:

```bash
bash packaging/gh-extension/gh-gitsetu --version
bash packaging/gh-extension/gh-setu --version
```

---

## 3. Standalone Bundle

There is currently no public v1.1.0 standalone download. For the verified local
release candidate, build the deterministic bundle from a reviewed checkout:

```bash
bash scripts/bundle.sh
./dist/gitsetu --version
```

The generated `dist/gitsetu` is a publication-ready local artifact, not a public download.
Do not distribute it or use a mutable branch URL as a release trust root.

After an intentional public release, obtain the standalone artifact from the
immutable release URL, verify its checksum and signature, and install it with
your organization's approved process. The release workflow will publish the
exact URL and digest; they are intentionally absent from this candidate.

---

## 4. Manual Installation (From Source)

If your machine is behind an air-gapped firewall:

```bash
# Obtain a reviewed checkout through your organization's approved source
# process. Do not pipe a mutable branch URL into a shell.
printf '%s\n' "Place the reviewed checkout at ~/.local/share/gitsetu"

# Symlink or copy the entrypoint only after reviewing the checkout.
mkdir -p ~/.local/bin
ln -sf ~/.local/share/gitsetu/gitsetu ~/.local/bin/gitsetu
ln -sf ~/.local/share/gitsetu/gitsetu ~/.local/bin/git-setu

# Ensure ~/.local/bin is in your PATH.
export PATH="$HOME/.local/bin:$PATH"
```

---

## Post-Installation First Steps

Once installed, verify that GitSetu is available:
```bash
gitsetu --version
# Outputs the current candidate version and release channel (development until publication)
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

Production updates are disabled while v1.1.0 remains a release candidate. The
core refuses a remote branch fetch or hard reset. For a clean, reviewed local
candidate checkout, verify the development state explicitly:

```bash
gitsetu update --development
```

Package-manager upgrade commands are not available until an intentional
release publishes pinned manifests and artifacts.

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
