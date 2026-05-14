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

## Foundation: Completed in v1.0.0

The following architectural hardening milestones established our enterprise baseline, backed by 165+ automated test vectors:
- **Zero-Trust Identity Guard**: Hard pre-commit intercepts preventing dual-state leaks.
- **Single Source of Truth (SSOT)**: Dynamic resolution via isolated `.gitconfig` files without registry polling.
- **Unified Global Lifecycle**: Complete signal trapping (`EXIT/SIGINT/SIGTERM`) ensuring zero lock leaks.
- **POSIX Concurrency Hardening**: Atomic `mv` operations eliminating Time-of-Check to Time-of-Use race conditions.
- **Bash 3.2 Array Panic Prevention**: Native C-style POSIX loop structures replacing fragile subshell bounds.
- **Path Injection Prevention**: Strict newline sanitization preventing INI boundary corruption.
- **Encrypted State Export**: AES-256 OpenSSL vault packaging.

---

## Phase 1: Distribution & Trust

**Goal:** Eliminate all adoption friction by ensuring GitSetu is seamlessly discoverable, installable, and trusted across all target platforms.

- **Native Package Management:** Launch official channels for `Homebrew` (macOS), `apt` PPA (Linux), and the `AUR`.
- **Authoritative Web Presence:** Overhaul `gitsetu.bhaskarjha.dev` to present enterprise-grade documentation (Active).
- **Windows PowerShell Integration:** Ship a robust initialization wrapper supporting native PowerShell environments to expand the addressable audience beyond Git Bash constraints.
- **Sponsorship & Governance:** Establish a formal Technical Steering Committee and define strict open-source contribution guidelines to guarantee long-term operational sustainability.

## Phase 2: Parity & Ecosystem UX

**Goal:** Introduce modern UX interaction paradigms and cross-tool integration points expected from premium developer workflows.

- **Fuzzy Profile Switching (`fzf`):** Implement interactive, ultra-fast `fzf`-powered runtime profile selection capabilities.
- **Native VS Code Integration:** Publish a premier VS Code extension to surface the active identity directly within the editor status bar, halting commits visually within the GUI if identities misalign.
- **GPG Key Auto-Wiring:** Extend the core Identity Routing Engine to automatically generate, map, and enforce `user.signingKey` and `commit.gpgsign` targets on a per-profile basis.
- **Machine-Readable API (`--json`):** Expose all diagnostic and structural `status` queries via structured JSON payloads to empower community extensions.

## Phase 3: The Enterprise Moat

**Goal:** Build asynchronous defensive capabilities no competitor is architecturally positioned to match.

- **Automated Key Rotation Engine:** Implement scheduled, automated cryptographic key replacement workflows (`gitsetu rotate --every 90d`). The engine will natively rotate underlying signatures and swap SSH configuration hooks completely transparently.
- **Headless CI/CD Mode:** Release a dedicated GitHub Action / GitLab CI runtime flag (`gitsetu ci-init`) that natively provisions ephemeral, tightly-scoped identity contexts on temporary CI runners, automatically tearing them down on execution exit.
- **Pre-Push Secret Scanning:** Expand the existing Identity Guard hook structure to actively scan outbound staged diffs for accidental Personal Access Token or SSH private key injections.
- **Append-Only Audit Log:** Establish a tamper-evident, locally written compliance log (`~/.local/share/gitsetu/audit.log`) tracking all identity switches and cryptographic generation events.

## Phase 4: Vision Completion

**Goal:** Achieve total ecosystem saturation and enterprise deployment scale.

- **Cross-Platform Native Wrapper:** Develop a lightweight, compiled proxy (`gitsetu-bin`) to manage the core Bash libraries, enabling native Windows execution and distribution via `winget`.
- **JetBrains Plugin Suite:** Mirror the VS Code extension capabilities seamlessly into IntelliJ, PyCharm, and GoLand IDE ecosystems.
- **Team-Level Cloud Synchronization:** Deploy an opt-in, highly encrypted cloud vault bridging service to allow instant machine-to-machine state provisioning (excluding private keys).

---

## Achieving 100/100

A tool that successfully obliterates an entire category of security friction is not merely the tool with the most raw features. It is the tool that lives silently on every machine, integrates seamlessly within every manager, and guards every repository implicitly.

GitSetu's trajectory shifts it from an **identity profile switcher** directly into the **Foundational Security Layer** for modern developer operations.

---

## ❌ Out of Scope / Rejected 

To maintain its extreme focus and zero-dependency reliability, GitSetu explicitly rejects the following features from the roadmap indefinitely:

- **Historical Commit Sanitizer (`gitsetu sanitize`):** Users frequently request the ability to rewrite Git history to remove leaked personal emails. **Rejected.** Rewriting history natively in pure Bash 3.2 is wildly dangerous, highly complex, and risks catastrophic repository corruption. We defer this entirely to the official Python-based `git-filter-repo` tool.
