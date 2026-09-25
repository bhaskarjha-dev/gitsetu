# Contributing to GitSetu

**The uncompromising guidelines and structural constraints required for submitting codebase modifications.**

GitSetu is designed as a portable, zero-dependency configuration compiler. Maintaining this architectural posture requires careful language boundaries, explicit platform behavior, and POSIX execution principles.

If you are proposing codebase updates, new diagnostic scanners, or platform integrations, please carefully review the following strict guard rails before submitting pull requests.

---

## 1. Zero-Dependency Core, Explicit Toolchain Boundaries
The GitSetu shell core must remain usable offline on supported systems. Networked operations, such as provider verification or updates, must be explicit and separately reviewed.
- **No new CLI runtime dependency:** Do not introduce a language runtime or package dependency into the Bash CLI itself. Packaging, tests, and release preparation may use pinned Node.js, PowerShell, Git for Windows, or other platform tools.
- **Minimal shell toolchain:** The runtime relies on `bash`, `git`, `ssh-keygen`, and core standard UNIX binaries (`grep`, `sed`, `awk`).

## 2. Bash 3.2 Compatibility Constraints
Because GitSetu must remain fully executable natively on legacy macOS endpoints, the entire codebase strictly targets **Bash 3.2**.
- **No Associative Arrays:** You may not utilize modern Bash 4.0+ features like `declare -A` associative structures.
- **POSIX Array Simulation:** Manage data matrices using standard indexed arrays and bounded iterators.
- **POSIX Subshell Offsets:** Minimize expensive `$(command)` `fork()` execution boundaries where possible. Utilize rapid internal variable pattern substitutions instead (`${var//search/replace}`).

## 3. Strict Concurrency Integrity
GitSetu is designed to support parallel headless CI/CD runners. All persistent filesystem mutations **must** remain atomic or fail closed where the platform permits.
- **Zero Inline File Overwrites:** Never utilize blind regex replacers (e.g., `sed -i`) natively against global target configurations. This creates catastrophic mid-write destruction windows during sudden SIGTERM events.
- **TMPDIR Swapping:** Always direct block modifications to heavily randomized temporary execution paths (`$TMPDIR/..._$$_${RANDOM}`), finalize validation, and subsequently apply them against primary targets utilizing single-cycle atomic `mv` replacements.

## 4. The Telemetry Boundary
We maintain a ruthless **Zero Telemetry** security posture.
Do not introduce integrations, analytics tracking, environment scanners, or crash-reporting dependencies that execute outbound background network requests. The repository codebase must remain perfectly verifiable and completely auditable.

---

## PR Submission Workflow

1. Fork the target `bhaskarjha-dev/gitsetu` repository.
2. Ensure your execution branch successfully passes local diagnostic boundaries (`gitsetu doctor` and verification testing paths).
3. **Testing Standards:** Run all automated regression tests before submitting PRs (`make test` or `bash tests/run_all.sh`). Every required suite must pass; any skipped capability must be reported explicitly and justified rather than counted as green.
4. **Documentation Consistency:** Run `npm run docs` (or `make docs`) and update user-facing documentation whenever commands, release state, security boundaries, or supported platforms change.
5. **Windows Testing Guidance:** Any changes affecting Windows paths, credentials, or shells should be verified directly in Git Bash and, when the experimental harness is current for the change, in an isolated Windows Sandbox run. Treat a Sandbox run with no terminal status as inconclusive; the harness is not a release qualification gate while its legacy fixtures are being reconciled.
6. **Code Style & Linting:** Run `make lint` for the files enumerated by the Makefile. It does not currently lint every `lib/*.sh` or Sandbox script, so run ShellCheck explicitly for any additional shell files you change.
7. If introducing logic updates impacting standard core modules, explicitly test compilation output against cross-platform environments (e.g., native macOS Terminal vs Git Bash vs WSL).
8. Outline your proposed updates clearly within the PR description block, specifically detailing your testing environments, test results, and confirmation of Bash 3.2 adherence.
