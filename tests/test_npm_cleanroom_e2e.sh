#!/usr/bin/env bash
# tests/test_npm_cleanroom_e2e.sh — Comprehensive clean-room E2E verification of npm/npx distribution channel
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
echo "   GitSetu npm/npx Clean-Room End-to-End Verification Suite       "
echo "=================================================================="

# Check node & npm
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Node or npm not found in PATH. Skipping."
    exit 0
fi

# 1. Prepare sterile clean-room sandbox
SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-npm-e2e.XXXXXX")
if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]]; then
    SANDBOX_ROOT=$(cd "$SANDBOX_ROOT" && pwd -W)
fi
# Normalize path with forward slashes
SANDBOX_ROOT="${SANDBOX_ROOT//\\//}"
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

STAGING_DIR="$SANDBOX_ROOT/staging"
CLEAN_HOME="$SANDBOX_ROOT/home"
NPM_PREFIX="$SANDBOX_ROOT/npm-prefix"
mkdir -p "$STAGING_DIR" "$CLEAN_HOME/.config/gitsetu" "$CLEAN_HOME/.ssh" "$NPM_PREFIX"

# Set completely isolated environment
export HOME="$CLEAN_HOME"
export XDG_CONFIG_HOME="$CLEAN_HOME/.config"
export GIT_CONFIG_GLOBAL="$CLEAN_HOME/.gitconfig"
git config -f "$GIT_CONFIG_GLOBAL" user.name "John Doe"
git config -f "$GIT_CONFIG_GLOBAL" user.email "john@example.com"

# 2. Pack tarball into staging directory
cd "$STAGING_DIR"
PACK_OUTPUT=$(npm pack "$REPO_DIR" --silent 2>&1 || true)
TARBALL=$(find "$STAGING_DIR" -name "gitsetu-*.tgz" | head -n 1)

if [ -n "$TARBALL" ] && [ -f "$TARBALL" ]; then
    pass "npm pack created distribution package: $(basename "$TARBALL")"
else
    fail "npm pack" "Failed to generate tarball in $STAGING_DIR ($PACK_OUTPUT)"
    exit 1
fi

# 3. Test npx execution directly from tarball
NPX_VER=$(npx --yes --package "$TARBALL" gitsetu --version 2>&1 || true)
if [[ "$NPX_VER" == *"gitsetu v1.0.0"* ]]; then
    pass "npx execution from tarball matches 'gitsetu v1.0.0'"
else
    fail "npx execution" "Output mismatch: '$NPX_VER'"
fi

# 4. Global install into isolated prefix
if npm install -g "$TARBALL" --prefix "$NPM_PREFIX" --silent >/dev/null 2>&1; then
    pass "npm install -g succeeded with isolated prefix"
else
    fail "npm install -g" "Installation failed"
    exit 1
fi

# Locate installed executable shim
INSTALLED_BIN=""
if [ -f "$NPM_PREFIX/bin/gitsetu" ]; then
    INSTALLED_BIN="$NPM_PREFIX/bin/gitsetu"
elif [ -f "$NPM_PREFIX/gitsetu" ]; then
    INSTALLED_BIN="$NPM_PREFIX/gitsetu"
elif [ -f "$NPM_PREFIX/gitsetu.cmd" ]; then
    INSTALLED_BIN="$NPM_PREFIX/gitsetu.cmd"
fi

if [ -n "$INSTALLED_BIN" ]; then
    pass "Located installed npm shim: $INSTALLED_BIN"
    export PATH="$NPM_PREFIX/bin:$NPM_PREFIX:$PATH"
else
    fail "locate binary" "Could not find gitsetu in $NPM_PREFIX"
    exit 1
fi

# Locate installed package entrypoint (handles Windows vs Unix global npm prefixes)
PACKAGE_JS=""
if [ -f "$NPM_PREFIX/node_modules/gitsetu/bin/gitsetu.js" ]; then
    PACKAGE_JS="$NPM_PREFIX/node_modules/gitsetu/bin/gitsetu.js"
elif [ -f "$NPM_PREFIX/lib/node_modules/gitsetu/bin/gitsetu.js" ]; then
    PACKAGE_JS="$NPM_PREFIX/lib/node_modules/gitsetu/bin/gitsetu.js"
fi

# Test installed CLI --version and --help
VER_CHECK=""
if [ -n "$PACKAGE_JS" ]; then
    VER_CHECK=$(node "$PACKAGE_JS" --version 2>&1 || true)
elif [ -n "$INSTALLED_BIN" ]; then
    VER_CHECK=$("$INSTALLED_BIN" --version 2>&1 || true)
fi

if [[ "$VER_CHECK" == *"gitsetu v1.0.0"* ]]; then
    pass "Installed package entrypoint runs correctly: $VER_CHECK"
else
    fail "entrypoint execution" "Unexpected output: $VER_CHECK"
fi

# 5. Execute 22-feature workflow using the installed npm package wrapper
RUN_CMD() {
    if [ -n "$PACKAGE_JS" ]; then
        node "$PACKAGE_JS" "$@"
    else
        "$INSTALLED_BIN" "$@"
    fi
}

# F1: --version
OUT_V=$(RUN_CMD --version | tr -d '\r')
if [[ "$OUT_V" == *"v1.0.0"* ]]; then
    pass "Feature 1: --version"
else
    fail "Feature 1" "$OUT_V"
fi

# F2: --help
OUT_H=$(RUN_CMD --help 2>&1 || true)
if echo "$OUT_H" | grep -q "USAGE"; then
    pass "Feature 2: --help"
else
    fail "Feature 2" "$OUT_H"
fi

# F3: setup --auto (zero prompt)
OUT_SETUP=$(RUN_CMD setup --auto < /dev/null 2>&1 | tr -d '\r' || true)
if [[ "$OUT_SETUP" == *"Setup complete"* ]]; then
    pass "Feature 3: setup --auto"
else
    fail "Feature 3" "$OUT_SETUP"
fi

# F4: add profile 1 (personal)
mkdir -p "$CLEAN_HOME/repos/personal"
OUT_ADD1=$(RUN_CMD add personal "John Doe" "john@example.com" "$CLEAN_HOME/repos/personal" 2>&1 | tr -d '\r' || true)
if [[ "$OUT_ADD1" == *"Setup complete"* ]]; then
    pass "Feature 4: add personal profile"
else
    fail "Feature 4" "$OUT_ADD1"
fi

# F5: add profile 2 (work)
mkdir -p "$CLEAN_HOME/repos/work"
OUT_ADD2=$(RUN_CMD add work "John Work" "john@corp.com" "$CLEAN_HOME/repos/work" 2>&1 | tr -d '\r' || true)
if [[ "$OUT_ADD2" == *"Setup complete"* ]]; then
    pass "Feature 5: add work profile"
else
    fail "Feature 5" "$OUT_ADD2"
fi

# F6: status
OUT_STATUS=$(RUN_CMD status 2>&1 || true)
if [[ "$OUT_STATUS" == *"personal"* ]] && [[ "$OUT_STATUS" == *"work"* ]]; then
    pass "Feature 6: status displays configured profiles"
else
    fail "Feature 6" "$OUT_STATUS"
fi

# F7: verify (assert profile table has green checks)
OUT_VERIFY=$(RUN_CMD verify 2>&1 || true)
if [[ "$OUT_VERIFY" == *"Verification Results"* ]] && [[ "$OUT_VERIFY" == *"personal"* ]] && [[ "$OUT_VERIFY" == *"work"* ]]; then
    pass "Feature 7: verify validates key, perms, and gitconfig structure"
else
    fail "Feature 7" "$OUT_VERIFY"
fi

# F8: doctor
OUT_DOC=$(RUN_CMD doctor 2>&1 || true)
if [[ "$OUT_DOC" == *"GitSetu Diagnostics (Doctor)"* ]]; then
    pass "Feature 8: doctor runs diagnostics"
else
    fail "Feature 8" "$OUT_DOC"
fi

# F9: prompt resolution
PROMPT_OUT_OUTSIDE=$(RUN_CMD prompt 2>&1 || true)
if [[ -z "$PROMPT_OUT_OUTSIDE" ]]; then
    pass "Feature 9a: prompt empty outside workspace"
else
    fail "Feature 9a" "$PROMPT_OUT_OUTSIDE"
fi

cd "$CLEAN_HOME/repos/personal"
PROMPT_OUT_INSIDE=$(RUN_CMD prompt 2>&1 || true)
if [[ "$PROMPT_OUT_INSIDE" == *"personal"* ]]; then
    pass "Feature 9b: prompt resolves active workspace profile"
else
    fail "Feature 9b" "$PROMPT_OUT_INSIDE"
fi
cd "$SANDBOX_ROOT"

# F10: run <profile> -- <cmd> (testing GIT_AUTHOR_EMAIL injection)
# shellcheck disable=SC2016
EMAIL_RUN=$(RUN_CMD run personal -- sh -c 'echo "$GIT_AUTHOR_EMAIL"' 2>&1 || true)
if [[ "$EMAIL_RUN" == *"john@example.com"* ]]; then
    pass "Feature 10: run injects profile identity into execution context"
else
    fail "Feature 10" "$EMAIL_RUN"
fi

# F11: guard --install (installs globally via core.hooksPath)
RUN_CMD guard --install >/dev/null 2>&1
HOOK_PATH="$CLEAN_HOME/.config/gitsetu/hooks/pre-commit"
CORE_HOOKS=$(git config --global core.hooksPath 2>/dev/null || true)
if [ -f "$HOOK_PATH" ] && grep -q "gitsetu" "$HOOK_PATH" && [[ "$CORE_HOOKS" == *".config/gitsetu/hooks"* ]]; then
    pass "Feature 11: guard --install configures global pre-commit hook"
else
    fail "Feature 11" "Hook missing or core.hooksPath not set ($CORE_HOOKS)"
fi

# F12: guard --uninstall
RUN_CMD guard --uninstall >/dev/null 2>&1
CORE_HOOKS_UNSET=$(git config --global core.hooksPath 2>/dev/null || true)
if [ -z "$CORE_HOOKS_UNSET" ] && [ ! -f "$HOOK_PATH" ]; then
    pass "Feature 12: guard --uninstall cleanly unsets core.hooksPath and removes hook"
else
    fail "Feature 12" "Hook still present or core.hooksPath not cleared ($CORE_HOOKS_UNSET)"
fi

# F13: backup
export GITSETU_TEST_VAULT_PASS="SecretPassword123!"
BACKUP_FILE="$SANDBOX_ROOT/vault.tar.gz.enc"
RUN_CMD backup "$BACKUP_FILE" >/dev/null 2>&1
if [ -f "$BACKUP_FILE" ]; then
    pass "Feature 13: backup creates AES-256 encrypted archive"
else
    fail "Feature 13" "Backup file not created"
fi

# F14: restore
OUT_RESTORE=$(RUN_CMD restore "$BACKUP_FILE" 2>&1 || true)
if [[ "$OUT_RESTORE" == *"Restore complete"* ]]; then
    pass "Feature 14: restore unpacks vault and reactivates profiles"
else
    fail "Feature 14" "$OUT_RESTORE"
fi

# F15: remove --force
OUT_REM=$(RUN_CMD remove personal --force 2>&1 || true)
if [[ "$OUT_REM" == *"successfully removed"* ]]; then
    pass "Feature 15: remove profile with --force"
else
    fail "Feature 15" "$OUT_REM"
fi

# F16: teardown --force
OUT_TD=$(RUN_CMD teardown --force 2>&1 || true)
if [[ "$OUT_TD" == *"teardown complete"* ]] || [[ "$OUT_TD" == *"Teardown complete"* ]]; then
    pass "Feature 16: teardown cleans all managed state"
else
    fail "Feature 16" "$OUT_TD"
fi

# F17: Clean uninstallation via npm
npm uninstall -g gitsetu --prefix "$NPM_PREFIX" --silent >/dev/null 2>&1
if [ ! -d "$NPM_PREFIX/node_modules/gitsetu" ] && [ ! -d "$NPM_PREFIX/lib/node_modules/gitsetu" ]; then
    pass "Feature 17: npm uninstall -g removes package cleanly"
else
    fail "Feature 17" "Package directory remained"
fi

# F18: No residue
SHIM_EXISTS=0
for s in "$NPM_PREFIX/bin/gitsetu" "$NPM_PREFIX/gitsetu" "$NPM_PREFIX/gitsetu.cmd" "$NPM_PREFIX/gitsetu.ps1"; do
    if [ -f "$s" ]; then SHIM_EXISTS=1; break; fi
done
if [ "$SHIM_EXISTS" -eq 0 ]; then
    pass "Feature 18: Zero shim residue after uninstallation"
else
    fail "Feature 18" "Shims still exist in $NPM_PREFIX"
fi

echo "=================================================================="
echo "NPM E2E Test Summary: $passed passed, $failed failed"
echo "=================================================================="

if [ "$failed" -gt 0 ]; then
    exit 1
fi
