#!/usr/bin/env bash
# tests/test_installer.sh — Regression tests for the distribution pipeline
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_installation_pipeline() {
    # 1. Create a safe sandbox home directory
    local sandbox_home
    sandbox_home=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu_test_install_XXXXXX")
    
    # 2. Point to the local repo so we don't hit the network for tests
    local local_repo
    local_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    
    # 3. Override HOME and REPO_URL
    export HOME="$sandbox_home"
    export GITSETU_REPO_URL="$local_repo"
    
    # 3.5 Configure safe.directory for the sandbox to allow local cloning
    git config --global --add safe.directory "$local_repo"
    git config --global --add safe.directory "$local_repo/.git"
    
    # 4. Test Installation
    bash "$local_repo/install.sh" >/dev/null 2>&1
    assert_equals 0 $? "install.sh runs successfully" || return 1
    
    # Verify clone exists
    if [[ ! -d "$sandbox_home/.local/share/gitsetu" ]]; then
        echo "Failed: share directory was not created."
        rm -rf "$sandbox_home"
        return 1
    fi
    
    # Verify executable exists (checking -x instead of -L as MSYS2 may copy instead of symlink)
    if [[ ! -x "$sandbox_home/.local/bin/gitsetu" ]]; then
        echo "Failed: executable was not linked/copied to bin directory."
        rm -rf "$sandbox_home"
        return 1
    fi
    
    # 5. Verify Execution
    local version_output
    version_output=$("$sandbox_home/.local/bin/gitsetu" --version)
    if [[ "$version_output" != *"gitsetu v"* ]]; then
        echo "Failed: installed executable did not run properly. Output: $version_output"
        rm -rf "$sandbox_home"
        return 1
    fi
    
    # 6. Test Idempotent Update
    bash "$local_repo/install.sh" >/dev/null 2>&1
    assert_equals 0 $? "install.sh updates idempotently" || return 1
    
    # 7. Test Uninstallation
    # Accept the 'Are you sure?' prompt with 'y'
    echo "y" | bash "$local_repo/uninstall.sh" >/dev/null 2>&1
    assert_equals 0 $? "uninstall.sh runs successfully" || return 1
    
    # Verify removal
    if [[ -d "$sandbox_home/.local/share/gitsetu" ]]; then
        echo "Failed: share directory was not removed by uninstall.sh."
        rm -rf "$sandbox_home"
        return 1
    fi
    
    if [[ -e "$sandbox_home/.local/bin/gitsetu" ]]; then
        echo "Failed: symlink was not removed by uninstall.sh."
        rm -rf "$sandbox_home"
        return 1
    fi
    
    rm -rf "$sandbox_home"
    return 0
}

test_windows_powershell_installer_pipeline() {
    # Skip if not on Windows / MSYS / Cygwin
    if [[ "${OSTYPE:-}" != "msys"* ]] && [[ "${OSTYPE:-}" != "cygwin"* ]] && [[ "${OSTYPE:-}" != "win"* ]]; then
        return 0
    fi
    if ! command -v powershell.exe >/dev/null 2>&1; then
        return 0
    fi
    
    local sandbox_appdata
    sandbox_appdata=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu_ps_test_XXXXXX")
    local win_sandbox_appdata
    win_sandbox_appdata=$(cd "$sandbox_appdata" && { pwd -W 2>/dev/null || pwd; })
    
    local local_repo
    local_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })
    
    # 1. Run install.ps1 with isolated LOCALAPPDATA
    LOCALAPPDATA="$win_sandbox_appdata" GITSETU_REPO_URL="$local_repo" GITSETU_TEST="true" \
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$local_repo/install.ps1" >/dev/null 2>&1
    assert_equals 0 $? "install.ps1 runs successfully" || { rm -rf "$sandbox_appdata"; return 1; }
    
    # 2. Verify files created
    if [[ ! -d "$sandbox_appdata/gitsetu/share" ]]; then
        echo "Failed: %LOCALAPPDATA%/gitsetu/share not found"
        rm -rf "$sandbox_appdata"; return 1
    fi
    if [[ ! -f "$sandbox_appdata/gitsetu/bin/gitsetu.cmd" ]]; then
        echo "Failed: gitsetu.cmd not found in bin"
        rm -rf "$sandbox_appdata"; return 1
    fi
    if [[ ! -f "$sandbox_appdata/gitsetu/bin/gitsetu.ps1" ]]; then
        echo "Failed: gitsetu.ps1 not found in bin"
        rm -rf "$sandbox_appdata"; return 1
    fi
    
    # 3. Verify execution via cmd.exe
    local cmd_out
    cmd_out=$(MSYS2_ARG_CONV_EXCL="*" cmd.exe /c "$win_sandbox_appdata/gitsetu/bin/gitsetu.cmd" --version 2>&1 || true)
    if [[ "$cmd_out" != *"gitsetu v1.0.0"* ]]; then
        echo "Failed: gitsetu.cmd --version output: $cmd_out"
        rm -rf "$sandbox_appdata"; return 1
    fi
    
    # 4. Verify execution via powershell.exe
    local ps_out
    ps_out=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win_sandbox_appdata/gitsetu/bin/gitsetu.ps1" --version 2>&1 || true)
    if [[ "$ps_out" != *"gitsetu v1.0.0"* ]]; then
        echo "Failed: gitsetu.ps1 --version output: $ps_out"
        rm -rf "$sandbox_appdata"; return 1
    fi
    
    # 5. Test uninstaller
    LOCALAPPDATA="$win_sandbox_appdata" GITSETU_TEST="true" CI="true" \
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$local_repo/uninstall.ps1" -Force >/dev/null 2>&1
    assert_equals 0 $? "uninstall.ps1 runs successfully" || { rm -rf "$sandbox_appdata"; return 1; }
    
    if [[ -d "$sandbox_appdata/gitsetu" ]]; then
        echo "Failed: %LOCALAPPDATA%/gitsetu was not removed by uninstall.ps1"
        rm -rf "$sandbox_appdata"; return 1
    fi
    
    rm -rf "$sandbox_appdata"
    return 0
}

printf '\n%btest_installer.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "POSIX Bash Installation/Uninstallation Pipeline" test_installation_pipeline
run_test "Windows PowerShell Installation/Uninstallation Pipeline" test_windows_powershell_installer_pipeline
print_results "Installer pipeline tests"
