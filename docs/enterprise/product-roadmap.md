# Product Roadmap (2026 Vision)

**Charting the trajectory from 82/100 to an unassailable 100/100 Enterprise Identity Platform.**

Our mission is to make identity leakage structurally impossible. GitSetu currently holds an industry-leading position for zero-dependency identity orchestration, yet significant expansion opportunities exist within the enterprise, CI/CD, and deeper IDE integration layers.

This research-driven roadmap synthesizes competitive analysis, developer pain-point research, and macro identity security trends to chart the complete path forward over the next 18 months.

---

## The Strategic Baseline

Based on exhaustive ecosystem analysis (May 2026), GitSetu maintains a composite feature/safety score of **82/100**, acting as the most comprehensive identity manager for macOS and Linux engineers.

However, the industry landscape reveals escalating threat vectors:
- **64% of credentials** leaked in 2022 remained actively valid four years later due to stagnant key rotation practices.
- **Non-Human Identities (NHI)** in CI/CD environments now outnumber human identities **144:1**, representing the primary target for credential compromise.

Our target is a flawless **100/100**. A developer using GitSetu should never have to manually manage key generation, rotation, identity switching, or pipeline authentication ever again. The bridge must become entirely invisible.

---

## Foundation: Completed in the v1.1.0 Release-Candidate Baseline

The following architectural hardening milestones establish the current local release-candidate baseline. They are backed by automated regression, adversarial, packaging, and platform checks; an isolated Windows Sandbox run is environment-dependent, and a run without a terminal status is inconclusive rather than a product pass:
- **Zero-Trust Identity Guard**: Hard pre-commit intercepts preventing dual-state leaks with longest-prefix directory matching, Windows/macOS case-insensitivity, and dynamic email re-reading.
- **Single Source of Truth (SSOT)**: Dynamic resolution via isolated `.gitconfig` files without registry polling.
- **Native Windows PowerShell Distribution**: Provides local-candidate `install.ps1` & `uninstall.ps1` installers, automated Command Prompt (`gitsetu.cmd`) and PowerShell (`gitsetu.ps1`) shims in `%LOCALAPPDATA%\gitsetu\bin`, and User `PATH` environment management.
- **Package Formula Definitions**: Maintains withheld Homebrew and Scoop templates for a future intentional publication; neither is a current public package.
- **Headless & Dotfiles Automation**: Scriptable, non-interactive profile provisioning via `gitsetu add` and `gitsetu profile add` backed by POSIX directory concurrency locking (`profiles.lock`).
- **Automated Workspace Provisioning**: Auto-creates missing workspace directories (`mkdir -p`) upon profile registration, with clean unmounting and pruning on profile deletion.
- **Multi-Profile Persistence & Re-hydration**: Preserves and re-hydrates existing profiles across multiple `gitsetu setup` runs.
- **Safe SSH Space Quoting**: Double-quotes key paths with spaces in `core.sshCommand` and `GIT_SSH_COMMAND`.
- **SSH Commit Signing**: Full native support for SSH-based cryptographic commit signatures (`gpg.format = ssh`, `commit.gpgsign = true`).
- **Cross-Platform Normalization**: Native Windows drive path conversion (`pwd -W`), case-insensitive path comparisons on Windows and macOS.
- **Unified Global Lifecycle**: Complete signal trapping (`EXIT/SIGINT/SIGTERM`) ensuring zero lock leaks.
- **POSIX Concurrency Hardening**: Atomic `mv` operations eliminating Time-of-Check to Time-of-Use race conditions.
- **Bash 3.2 Array Panic Prevention**: Native C-style POSIX loop structures replacing fragile subshell bounds.
- **Path Injection Prevention**: Strict newline sanitization preventing INI boundary corruption.
- **Authenticated State Export**: Versioned authenticated v2 vault packaging (`gitsetu backup` / `gitsetu restore`) with staging, tamper checks, and rollback. Older vault formats are rejected.
- **Empirical Sandbox Verification**: Windows Sandbox is an optional environment check. Record the tested revision and terminal status; a run with no terminal status is inconclusive, not a product pass.

---

## Phase 1: Zero-Friction Onboarding & Universal Distribution

> **Release-candidate preparation:** v1.1.0 has passed the local verification
> gates and is publication-ready. Publication remains gated until the intentional
> release workflow publishes pinned artifacts and manifests. None of the
> package-manager or extension commands below are available before that gate.

**Goal:** Eliminate all adoption friction by ensuring GitSetu is instantly discoverable, installable, and trusted across all developer environments without requiring git clones or elevated permissions.

- **Single-File Bundled Binary (`gitsetu-standalone` / `bash scripts/bundle.sh`):**
  - Maintain the deterministic build step that inlines all `lib/*.sh` modules into a single, self-contained executable script.
  - Allows direct download without cloning the git repository:
    ```bash
    # Download a verified, immutable release artifact and verify its checksum/signature first.
    ```
- **Homebrew Tap & Core Ingestion:** Launch the official `bhaskarjha-dev/homebrew-tap` repository and initiate submission to `homebrew/core` after an intentional release.
- **Dedicated Community Package Managers:**
  - **Windows Scoop:** Publish `packaging/scoop/gitsetu.json` to official Scoop buckets (Main / Extras).
  - **Microsoft Winget:** Submit the official `BhaskarJha.GitSetu` manifest to Microsoft's `winget-pkgs` repository after the release metadata is pinned.
  - **Arch Linux AUR:** Publish an official `PKGBUILD` only after the release source and digest are pinned.
  - **Nix / Nixpkgs Flake:** Maintain a pinned `flake.nix` in the repository root for reproducible, zero-dependency NixOS execution from a reviewed checkout.
  - **npm / npx Wrapper:** Publish a thin npm binary wrapper (`npx gitsetu setup` / `npm i -g gitsetu`) for JavaScript and fullstack web developers.
- **GitHub CLI Extensions (`gh gitsetu` / `gh setu`):** Publish separate `gh-gitsetu` and `gh-setu` extension repositories, allowing developers working inside GitHub CLI workflows to run either command natively.
- **Smart Zero-Prompt Auto-Discovery (`gitsetu setup --auto`):** Expand the discovery engine in `lib/discovery.sh` into an instant, non-interactive one-shot setup command that auto-detects existing Git identities, SSH keys, and workspace folders (`~/work`, `~/personal`), applying a recommended zero-trust configuration in under 1 second.
- **Sponsorship & Governance:** Establish a formal Technical Steering Committee and define open-source contribution guidelines to guarantee long-term operational sustainability.

---

## Phase 2: Parity & Ecosystem UX

**Goal:** Introduce modern UX interaction paradigms, visual tools, and cross-tool integration points expected from premium developer workflows.

- **Web Config Visualizer & Generator:** Deploy an interactive browser-based profile designer on `gitsetu.bhaskarjha.dev` that provides live previews of generated `.gitconfig` and OpenSSH directives, outputting customized 1-line installation commands.
- **Fuzzy Profile Switching (`fzf`):** Implement interactive, ultra-fast `fzf`-powered runtime profile selection (`gitsetu switch`).
- **Native VS Code Extension:** Publish an official VS Code extension to surface the active profile directly within the editor status bar, halting commits visually within the GUI if identities misalign.
- **PGP / GPG Key Auto-Wiring:** Extend commit signing capabilities beyond native SSH to automatically wire classical PGP / GPG key targets on a per-profile basis.
- **Machine-Readable API (`--json`):** Expose all diagnostic and structural queries (`gitsetu status --json`, `gitsetu doctor --json`) via structured JSON payloads to empower community tooling and editor plugins.

---

## Phase 3: The Enterprise Moat

**Goal:** Build asynchronous defensive capabilities no competitor is architecturally positioned to match.

- **Automated Key Rotation Engine:** Implement scheduled, automated cryptographic key replacement workflows (`gitsetu rotate --every 90d`). The engine will natively rotate underlying signatures and swap OpenSSH configuration hooks completely transparently.
- **Headless CI/CD Mode:** Release a dedicated GitHub Action / GitLab CI runtime flag (`gitsetu ci-init`) that natively provisions ephemeral, tightly-scoped identity contexts on temporary CI runners, automatically tearing them down on execution exit.
- **Pre-Push Secret Scanning:** Expand the existing Identity Guard hook structure to actively scan outbound staged diffs for accidental Personal Access Token or SSH private key injections.
- **Append-Only Audit Log:** Establish a tamper-evident, locally written compliance log (`~/.local/share/gitsetu/audit.log`) tracking all identity switches and cryptographic generation events.

---

## Phase 4: Vision Completion (100/100)

**Goal:** Achieve total ecosystem saturation and enterprise deployment scale.

- **Cross-Platform Native Wrapper:** Develop a lightweight, compiled proxy (`gitsetu-bin`) to manage the core Bash libraries, enabling native Windows execution and direct binary distribution via winget/scoop.
- **JetBrains Plugin Suite:** Mirror the VS Code extension capabilities seamlessly into IntelliJ, PyCharm, WebStorm, and GoLand IDE ecosystems.
- **Team-Level Cloud Synchronization:** Deploy an opt-in, highly encrypted cloud vault bridging service to allow instant machine-to-machine state provisioning (excluding private keys).

---

## Achieving 100/100

A tool that successfully obliterates an entire category of security friction is not merely the tool with the most raw features. It is the tool that lives silently on every machine, integrates seamlessly within every manager, and guards every repository implicitly.

GitSetu's trajectory shifts it from an **identity profile switcher** directly into the **Foundational Security Layer** for modern developer operations.

---

## ❌ Out of Scope / Rejected 

To maintain its extreme focus and zero-dependency reliability, GitSetu explicitly rejects the following features from the roadmap indefinitely:

- **Historical Commit Sanitizer (`gitsetu sanitize`):** Users frequently request the ability to rewrite Git history to remove leaked personal emails. **Rejected.** Rewriting history natively in pure Bash 3.2 is wildly dangerous, highly complex, and risks catastrophic repository corruption. We defer this entirely to the official Python-based `git-filter-repo` tool.
