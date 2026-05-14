# Contributing to GitSetu

**The uncompromising guidelines and structural constraints required for submitting codebase modifications.**

GitSetu is deliberately engineered to act as a deeply reliable, extremely portable Zero-Dependency bootstrapping compiler. Maintaining this architectural posture requires absolute adherence to strict language boundaries and POSIX execution principles.

If you are proposing codebase updates, new diagnostic scanners, or platform integrations, please carefully review the following strict guard rails before submitting pull requests.

---

## 1. Absolute Zero-Dependency Tolerance
GitSetu must successfully execute across legacy host systems completely offline.
- **No Interpreted Binaries:** Do not introduce integrations that require Go runtimes, Python interpreters, Node.js packages, or Rust compilers to resolve correctly.
- **Minimal Toolchains:** Rely strictly on `bash`, `git`, `ssh-keygen`, and core standard UNIX binaries (`grep`, `sed`, `awk`).

## 2. Bash 3.2 Compatibility Constraints
Because GitSetu must remain fully executable natively on legacy macOS endpoints, the entire codebase strictly targets **Bash 3.2**.
- **No Associative Arrays:** You may not utilize modern Bash 4.0+ features like `declare -A` associative structures.
- **POSIX Array Simulation:** Manage data matrices using standard indexed arrays and bounded iterators.
- **POSIX Subshell Offsets:** Minimize expensive `$(command)` `fork()` execution boundaries where possible. Utilize rapid internal variable pattern substitutions instead (`${var//search/replace}`).

## 3. Strict Concurrency Integrity
GitSetu executes in parallel headless CI/CD runners seamlessly. All persistent filesystem mutations **must** remain perfectly atomic.
- **Zero Inline File Overwrites:** Never utilize blind regex replacers (e.g., `sed -i`) natively against global target configurations. This creates catastrophic mid-write destruction windows during sudden SIGTERM events.
- **TMPDIR Swapping:** Always direct block modifications to heavily randomized temporary execution paths (`$TMPDIR/..._$$_${RANDOM}`), finalize validation, and subsequently apply them against primary targets utilizing single-cycle atomic `mv` replacements.

## 4. The Telemetry Boundary
We maintain a ruthless **Zero Telemetry** security posture.
Do not introduce integrations, analytics tracking, environment scanners, or crash-reporting dependencies that execute outbound background network requests. The repository codebase must remain perfectly verifiable and completely auditable.

---

## PR Submission Workflow

1. Fork the target `bhaskarjha-com/gitsetu` repository.
2. Ensure your execution branch successfully passes local diagnostic boundaries (`gitsetu doctor` and verification testing paths).
3. If introducing logic updates impacting standard core modules, explicitly test compilation output against cross-platform environments (e.g., native macOS Terminal vs Git Bash vs WSL).
4. Outline your proposed updates clearly within the PR description block, specifically detailing your testing environments and confirmation of Bash 3.2 adherence.
