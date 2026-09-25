# GitSetu test layers

The test suite is organized so that a clean source-tree run, the generated
standalone bundle, Windows packaging, and the legacy Sandbox harness do not
make the same claim.

## Layers

1. **Hermetic unit and state tests** — `tests/test_*.sh` and `tests/helpers.sh`
   isolate HOME, Git configuration, XDG roots, runtime locks, and command
   shims. They cover validators, v2 registry state, vault transactions,
   credentials, routing, SSH policy, guard behavior, teardown, and failure
   paths.
2. **CLI contract tests** — `test_cli_contract.sh` exercises every top-level
   dispatch branch, aliases, arity, negative arguments, and exit codes.
3. **Integration tests** — installer, npm clean-room, concurrency, CRLF,
   discovery, backup/restore, and Git/OpenSSH tests use real local tools but
   never contact a provider unless a test explicitly opts in.
4. **Artifact tests** — `test_bundle_path.sh` runs the selected generated
   standalone artifact, not merely the source checkout. Build and provenance
   checks are separate from behavioral tests.
5. **Windows tests** — PowerShell installer, launcher, shim, and dispatch tests
   run on Windows. Unsupported PowerShell is reported as `SKIP`, never PASS.
6. **Sandbox harness** — `sandbox/` is a legacy/experimental Windows Sandbox
   smoke/reproduction layer. It is not a release qualification gate. Its
   static contract suite checks provenance, run scoping, network policy, and
   non-green result wording.

## Running

```bash
bash tests/run_all.sh
bash tests/run_all.sh --list-suites
bash tests/run_all.sh --suite cli_contract
bash tests/run_all.sh --bundle ./dist/gitsetu
```

On Windows, use Git Bash for the shell suites. A live Scoop run is opt-in:

```powershell
bash tests/run_all.sh --include-live-windows --require-powershell
```

## What remains environment-dependent

Real macOS Keychain, Linux Secret Service, Windows GCM/DPAPI, FIDO2 hardware,
corporate firewalls, DNS/TLS/SSH endpoints, Windows ACL/reparse behavior,
PowerToys/UI rendering, and protected publication services require native
runners or controlled external environments. Hermetic shims verify the
command contract; they do not replace those platform checks.

A passing test row is valid only for the named source commit, test selection,
platform, and environment recorded by the runner. Missing capabilities,
skips, timeouts, and Sandbox policy blocks remain visible statuses.
