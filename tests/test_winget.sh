#!/usr/bin/env bash
# tests/test_winget.sh — Tests Windows Package Manager (WinGet) manifests and native launcher
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

passed=0
failed=0

pass() {
    printf "  \033[32m✔\033[0m %s\n" "$1"
    passed=$((passed + 1))
}

fail() {
    printf "  \033[31m✖\033[0m %s: %s\n" "$1" "$2"
    failed=$((failed + 1))
}

echo "=== Running tests/test_winget.sh ==="

MANIFEST_DIR="$REPO_DIR/packaging/winget/manifests/b/BhaskarJha/GitSetu/1.0.0"
VER_FILE="$MANIFEST_DIR/BhaskarJha.GitSetu.yaml"
LOC_FILE="$MANIFEST_DIR/BhaskarJha.GitSetu.locale.en-US.yaml"
INS_FILE="$MANIFEST_DIR/BhaskarJha.GitSetu.installer.yaml"

# 1. Verify manifest existence
if [ -f "$VER_FILE" ] && [ -f "$LOC_FILE" ] && [ -f "$INS_FILE" ]; then
    pass "WinGet multi-file manifest files exist"
else
    fail "manifest existence" "one or more WinGet manifest files are missing"
fi

# 2. Check PackageIdentifier and PackageVersion consistency
id_ver=$(grep "^PackageIdentifier:" "$VER_FILE" | awk '{print $2}')
id_loc=$(grep "^PackageIdentifier:" "$LOC_FILE" | awk '{print $2}')
id_ins=$(grep "^PackageIdentifier:" "$INS_FILE" | awk '{print $2}')

v_ver=$(grep "^PackageVersion:" "$VER_FILE" | awk '{print $2}')
v_loc=$(grep "^PackageVersion:" "$LOC_FILE" | awk '{print $2}')
v_ins=$(grep "^PackageVersion:" "$INS_FILE" | awk '{print $2}')

if [ "$id_ver" = "BhaskarJha.GitSetu" ] && [ "$id_loc" = "BhaskarJha.GitSetu" ] && [ "$id_ins" = "BhaskarJha.GitSetu" ]; then
    pass "PackageIdentifier一致 (BhaskarJha.GitSetu)"
else
    fail "PackageIdentifier" "mismatch across manifest files ($id_ver / $id_loc / $id_ins)"
fi

if [ "$v_ver" = "1.0.0" ] && [ "$v_loc" = "1.0.0" ] && [ "$v_ins" = "1.0.0" ]; then
    pass "PackageVersion consistency (1.0.0)"
else
    fail "PackageVersion" "mismatch across manifest files ($v_ver / $v_loc / $v_ins)"
fi

# 3. Test winget validate if running in an environment with winget
if command -v winget.exe >/dev/null 2>&1 || command -v winget >/dev/null 2>&1; then
    WINGET_BIN="winget"
    if command -v winget.exe >/dev/null 2>&1; then
        WINGET_BIN="winget.exe"
    fi

    # Convert path for Windows
    WIN_DIR="$MANIFEST_DIR"
    if command -v cygpath >/dev/null 2>&1; then
        WIN_DIR=$(cygpath -w "$MANIFEST_DIR")
    fi

    val_out=$("$WINGET_BIN" validate --manifest "$WIN_DIR" 2>&1 || echo "failed")
    if echo "$val_out" | grep -qi "validation succeeded"; then
        pass "winget validate passes official Microsoft manifest schema"
    else
        fail "winget validate" "$val_out"
    fi
else
    pass "winget validate (skipped: winget not installed on host)"
fi

# 4. Verify Windows C# launcher source
CS_FILE="$REPO_DIR/packaging/windows/gitsetu.cs"
if [ -f "$CS_FILE" ] && grep -q "GitSetuLauncher" "$CS_FILE"; then
    pass "packaging/windows/gitsetu.cs source exists"
else
    fail "launcher source" "gitsetu.cs missing or invalid"
fi

# 5. Check launcher compilation if on Windows
if command -v powershell.exe >/dev/null 2>&1 && [ -f "$REPO_DIR/packaging/windows/build_launcher.ps1" ]; then
    TMP_OUT=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-launcher-test.XXXXXX")
    WIN_OUT="$TMP_OUT"
    if command -v cygpath >/dev/null 2>&1; then
        WIN_OUT=$(cygpath -w "$TMP_OUT")
    fi

    if powershell.exe -ExecutionPolicy Bypass -File "$REPO_DIR/packaging/windows/build_launcher.ps1" -OutDir "$WIN_OUT" >/dev/null 2>&1; then
        if [ -f "$TMP_OUT/gitsetu.exe" ]; then
            pass "native Windows launcher compiles cleanly via build_launcher.ps1"
        else
            fail "launcher compilation" "gitsetu.exe not generated in output directory"
        fi
    else
        fail "launcher compilation" "powershell execution failed"
    fi
    rm -rf "$TMP_OUT"
fi

echo ""
echo "WinGet tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
