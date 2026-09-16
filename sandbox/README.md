# GitSetu Windows Sandbox Test Harness

This directory provides an isolated, disposable **Windows Sandbox** test harness to verify GitSetu on Windows without modifying the host machine.

## Files

- **`launch_sandbox.ps1`**: Native PowerShell launcher with environment auto-detection, dynamic `.wsb` sandbox definition generation, and execution policy bypass.
- **`launch_sandbox.bat`**: Windows batch wrapper for `launch_sandbox.ps1`.
- **`bootstrap.ps1`**: Automated 8-dimension test harness running upon Sandbox login.
- **`live_test.sh`**: Real multi-profile end-to-end simulation (creates profiles, initializes repos, runs commits, tests identity switching).
- **`comprehensive_audit.sh`**: 31-phase zero-trust empirical audit script running ~110 checks across all CLI commands, security hardening, concurrency locking, CRLF self-healing, backup/restore round-trips, edge cases, and packaging channels.

## Usage

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\sandbox\launch_sandbox.ps1
```

Or double-click `launch_sandbox.bat` from Windows Explorer / Command Prompt:

```cmd
.\sandbox\launch_sandbox.bat
```
