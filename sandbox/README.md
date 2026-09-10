# GitSetu Windows Sandbox Test Harness

This directory provides an isolated, disposable **Windows Sandbox** test harness to verify GitSetu on Windows without modifying the host machine.

## Files

- **`launch_sandbox.bat`**: Single-click batch script to launch Windows Sandbox.
- **`gitsetu_test.wsb`**: Windows Sandbox definition mapping the repository source and Git for Windows read-only.
- **`bootstrap.ps1`**: Automated initialization script that runs upon Sandbox login.
- **`live_test.sh`**: Real multi-profile end-to-end simulation (creates profiles, initializes repos, runs commits, tests identity switching).

## Usage

Double-click `launch_sandbox.bat` or run:

```cmd
.\sandbox\launch_sandbox.bat
```
