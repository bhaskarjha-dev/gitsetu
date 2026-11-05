# ADR 0003: FUT-03 Codebase Consolidation & Architectural Boundaries

## Status
**Accepted (Planned for v1.2.0)** (November 2026)

## Context
Following the extensive security hardening and cross-platform overhaul across the v1.1.0 release cycle, the active product codebase stands at **13,934 lines of shell** across 15 files.

Earlier roadmap sketches proposed shrinking the codebase to "<6,000 LOC" based on the observation that `v1.0.0` was ~4,800 lines of shell. However, forensic analysis reveals that `v1.0.0` was a baseline implementation that lacked production-grade defensive systems:
1. **Authenticated Vault Engine (`lib/backup.sh`):** Expanded from 332 to 2,364 LOC to implement AES-256-CBC + HMAC-SHA256 authenticated encryption, PBKDF2 key derivation via stdin, and multi-layered defense-in-depth against zip-slip traversal, symlink attacks, and duplicate member injection.
2. **Multi-Process Concurrency Locking (`lib/setup.sh`):** Expanded to guarantee atomic directory-gate locking with SHA-256 marker signatures, preventing active process lock theft and race conditions under parallel CI contention.
3. **Cross-Platform Drive Equivalence (`lib/platform.sh`, `lib/core.sh`):** Expanded to ensure Windows drive letters (`C:/`, `D:/`) and MSYS `/c/` paths are cleanly normalized across all configuration parsers.
4. **Pre-Commit Identity Guard (`lib/guard.sh`):** Expanded to 536 LOC for robust multi-repository hook isolation.

Arbitrarily forcing the codebase below 6,000 LOC would require deleting functional security engines. However, rapid audit remediation did introduce genuine technical debt in the form of **defensive duplication, copy-pasted path normalizers, and verbose UI formatting**.

## Decision
We will execute **FUT-03 Core Codebase Consolidation in v1.2.0** following the v1.1.0 release and feature freeze, adhering to four strict architectural invariants.

### 1. Realistic Target: ~2,300 LOC Safe Reduction (Toward ~11,600 LOC)
Consolidation will target genuine duplication across four categorized areas:
- **Category A (Shadow Helpers, ~700 LOC):** Eliminate private wrappers (`_ssh_normalize_key_path`, `_gitconfig_normalize_path`, `_vault_file_size`, `_vault_private_temp_dir`) in favor of centralized primitives in `lib/platform.sh`.
- **Category B (Diagnostic & UI Boilerplate, ~500 LOC):** Consolidate repetitive 10-line terminal assertion blocks in `lib/doctor.sh` and `lib/verify.sh` into a shared assertion helper.
- **Category C (Dual Wizard/Headless Branching, ~550 LOC):** Unify interactive terminal prompt inputs in `lib/setup.sh` so the wizard pre-populates the same options array consumed by headless CLI flags.
- **Category D (Transactional Staging & Rollback, ~550 LOC):** Streamline snapshot creation and rollback restoration routines across `lib/backup.sh` and `lib/setup.sh`.

### 2. Inviolable Architectural Invariants

#### Invariant 1: Preserve All 14 Module File Boundaries
The 14 module boundaries (`lib/core.sh`, `lib/platform.sh`, `lib/ui.sh`, `lib/validate.sh`, `lib/backup.sh`, `lib/ssh.sh`, `lib/gitconfig.sh`, `lib/guard.sh`, `lib/doctor.sh`, `lib/verify.sh`, `lib/teardown.sh`, `lib/discovery.sh`, `lib/setup.sh`, `lib/completion.sh`) are hardcoded in `packaging/release.js` (`BUNDLE_MODULES`), `scripts/bundle.sh` (`MODULES`), and `packaging/windows/build_release_zip.ps1` (`$members`).  
Files must **never be merged or deleted on disk**. All reductions must occur via internal deduplication within existing module files.

#### Invariant 2: Preserve Concurrency & Lock Reaping Safety
The multi-process atomic locking engine in `lib/setup.sh` (`_gitsetu_lock_marker_signature`, atomic `.tmp` staging, and guarded PID recycling checks) was proven necessary during CI concurrency stress testing.  
Locking logic must **never be simplified into a naive `mkdir` check without identity signatures**, which would reintroduce race conditions and registry corruption during parallel mutations.

#### Invariant 3: Preserve Low-Overhead Shell Prompt Independence (`cmd_prompt`)
`cmd_prompt` in `gitsetu` is placed before library module loading to execute in **<2ms inside interactive prompts (`PS1`, `precmd`)** without sourcing 13,000 lines of library code.  
`cmd_prompt` must **never be refactored to depend on sourced library modules**, which would introduce 50–100ms of lag on every terminal keystroke.

#### Invariant 4: Preserve Public Security Symbols
`tests/test_vault_adversarial.sh` directly tests internal function interfaces (`_vault_derive_root_key`, `_vault_derive_mac_key`, `_vault_hmac_pad`, `_vault_file_size`, `_vault_validate_archive_listing`).  
Refactoring in `lib/backup.sh` must preserve these exact symbol signatures and security validation boundaries.

## Consequences
* **For v1.1.0 Release:** Zero disruption to release certification; v1.1.0 ships on schedule with 100% green CI.
* **For v1.2.0 Contributors:** A mathematically grounded roadmap that eliminates ~2,300 lines of dead weight while guaranteeing that security boundaries, packaging scripts, and concurrency safety remain intact.

