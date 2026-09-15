#!/usr/bin/env bash
# tests/test_posix_installer_e2e.sh — Comprehensive E2E test for POSIX installer & uninstaller
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

echo "=================================================================="
echo "   GitSetu POSIX Shell Installer & Uninstaller Verification       "
echo "=================================================================="

SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-posix-e2e.XXXXXX")
if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]]; then
    SANDBOX_ROOT=$(cd "$SANDBOX_ROOT" && pwd -W)
fi
SANDBOX_ROOT="${SANDBOX_ROOT//\\//}"
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

INSTALL_DIR="$SANDBOX_ROOT/gitsetu_install"
export HOME="$SANDBOX_ROOT/home"
export GITSETU_INSTALL_DIR="$INSTALL_DIR"
export GITSETU_REPO_URL="$REPO_DIR"
mkdir -p "$HOME"

# Allow local repo cloning in isolated git environment
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

# 1. Run install.sh
INSTALL_OUT=$(bash "$REPO_DIR/install.sh" 2>&1 || true)
if [ -d "$INSTALL_DIR/share/gitsetu" ] && [ -f "$INSTALL_DIR/bin/gitsetu" ]; then
    pass "install.sh provisions share and bin directories"
else
    fail "install.sh" "Files missing: $INSTALL_OUT"
    exit 1
fi

# 2. Verify binary execution
BIN_VER=$("$INSTALL_DIR/bin/gitsetu" --version 2>&1 || true)
if [[ "$BIN_VER" == *"gitsetu v1.0.0"* ]]; then
    pass "Installed binary executes cleanly: $BIN_VER"
else
    fail "binary execution" "Output was '$BIN_VER'"
fi

# 3. Test idempotent re-installation
UPDATE_OUT=$(bash "$REPO_DIR/install.sh" 2>&1 || true)
if [[ "$UPDATE_OUT" == *"Updating existing installation"* ]] || [[ "$UPDATE_OUT" == *"successfully installed"* ]]; then
    pass "install.sh handles idempotent updates seamlessly"
else
    fail "idempotent update" "$UPDATE_OUT"
fi

# 4. Test uninstall.sh with piped confirmation
UNINSTALL_OUT=$(echo "y" | bash "$REPO_DIR/uninstall.sh" 2>&1 || true)
if [[ "$UNINSTALL_OUT" == *"successfully removed"* ]]; then
    pass "uninstall.sh accepts piped confirmation ('echo y | bash uninstall.sh')"
else
    fail "uninstall.sh piped confirmation" "$UNINSTALL_OUT"
fi

# 5. Assert zero residue
if [ ! -d "$INSTALL_DIR/share/gitsetu" ] && [ ! -f "$INSTALL_DIR/bin/gitsetu" ]; then
    pass "Zero residue remains in installation directory"
else
    fail "residue check" "Files remained in $INSTALL_DIR"
fi

echo "=================================================================="
echo "POSIX Installer E2E Summary: $passed passed, $failed failed"
echo "=================================================================="

if [ "$failed" -gt 0 ]; then
    exit 1
fi
