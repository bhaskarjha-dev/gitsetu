# GitSetu Windows Sandbox Test Harness

This directory provides an isolated, disposable **Windows Sandbox** test harness to verify GitSetu on Windows without modifying the host machine.

## Files

- **`launch_sandbox.ps1`**: Native PowerShell launcher with environment auto-detection, dynamic `.wsb` sandbox definition generation, and execution policy bypass.
- **`launch_sandbox.bat`**: Windows batch wrapper for `launch_sandbox.ps1`.
- **`bootstrap.ps1`**: Automated multi-dimension test harness running upon Sandbox login. It distinguishes product failures from environment policy blocks and never counts a blocked native launcher as a pass.
- **`live_test.sh`**: Real multi-profile end-to-end simulation (creates profiles, initializes repos, runs commits, tests identity switching).
- **`comprehensive_audit.sh`**: 31-phase zero-trust empirical audit script running ~110 checks across all CLI commands, security hardening, concurrency locking, CRLF self-healing, backup/restore round-trips, edge cases, and packaging channels.

## Usage

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\sandbox\launch_sandbox.ps1
# Optional: write results to a disposable, unique directory.
powershell -ExecutionPolicy Bypass -File .\sandbox\launch_sandbox.ps1 -ResultsDir C:\Temp\gitsetu-sandbox-results
```

Or double-click `launch_sandbox.bat` from Windows Explorer / Command Prompt:

```cmd
.\sandbox\launch_sandbox.bat
```

The results directory contains `status.txt`:

- `COMPLETED_SUCCESS`: all sandbox checks passed.
- `COMPLETED_ENVIRONMENT_BLOCK`: all non-launcher checks passed, but Windows Application Control blocked execution of the generated unsigned native launcher; this is not a product pass.
- `COMPLETED_FAILURE`: one or more checks failed.
- No terminal status (for example, the host closes the VM during a run): treat
  the result as **inconclusive**, never as a pass or product failure.

Each launcher invocation creates a unique `.wsb` configuration, so repeated or
parallel disposable runs cannot silently reuse an older Sandbox session.
