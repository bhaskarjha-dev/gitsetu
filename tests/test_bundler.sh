#!/usr/bin/env bash
# tests/test_bundler.sh — Tests standalone single-file monolith bundler
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

echo "=== Running tests/test_bundler.sh ==="

# 1. Execute bundler
cd "$REPO_DIR"
if bash "$REPO_DIR/scripts/bundle.sh" >/dev/null 2>&1; then
    pass "scripts/bundle.sh compiles cleanly"
else
    fail "scripts/bundle.sh" "bundler failed to execute"
fi

BUNDLE_FILE="$REPO_DIR/dist/gitsetu"
if [ -f "$BUNDLE_FILE" ] && [ -s "$BUNDLE_FILE" ]; then
    pass "dist/gitsetu output artifact exists and is non-empty"
else
    fail "bundle output" "dist/gitsetu missing or empty"
fi

# 2. Verify the generated integrity manifest
BUNDLE_MANIFEST="$REPO_DIR/dist/gitsetu.manifest.json"
if node "$REPO_DIR/packaging/release.js" verify-bundle "$BUNDLE_FILE" "$BUNDLE_MANIFEST" >/dev/null 2>&1; then
    pass "bundle manifest verifies exact bundle and module digests"
else
    fail "bundle manifest" "release.js rejected the generated bundle"
fi
if grep -q 'lib/completion.sh' "$BUNDLE_MANIFEST"; then
    pass "bundle manifest declares completion metadata"
else
    fail "bundle manifest modules" "lib/completion.sh is not declared"
fi

# packaging/release.env is compared byte-for-byte against generated content by
# release.js validate-source. Without an explicit LF attribute, a Windows
# checkout (core.autocrlf=true) rewrites it to CRLF and the comparison fails even
# though the committed file is current. Assert the attribute, not the worktree.
if git -C "$REPO_DIR" check-attr eol -- packaging/release.env 2>/dev/null | grep -q 'eol: lf'; then
    pass "release.env is pinned to LF so byte-exact validation is checkout-stable"
else
    fail "release.env line endings" "packaging/release.env needs an explicit eol=lf attribute in .gitattributes"
fi

# 3. Check standalone flag is embedded
if grep -q "Release state: development" "$BUNDLE_FILE"; then
    pass "bundle banner marks the non-public development release state"
else
    fail "bundle release state" "development marker is missing"
fi
if grep -q "GITSETU_STANDALONE=1" "$BUNDLE_FILE"; then
    pass "dist/gitsetu embeds GITSETU_STANDALONE=1 banner"
else
    fail "standalone flag" "GITSETU_STANDALONE not defined in bundle"
fi

# 3. Test standalone execution in isolated directory (NO lib/ directory present)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-bundle-test.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT HUP INT TERM
mkdir -p "$TEST_TMP/home/.config" "$TEST_TMP/home/.ssh"
cp "$BUNDLE_FILE" "$TEST_TMP/gitsetu"
chmod +x "$TEST_TMP/gitsetu"
run_isolated_bundle() (
    unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GITSETU_DIR
    export HOME="$TEST_TMP/home"
    export XDG_CONFIG_HOME="$TEST_TMP/home/.config"
    export GIT_CONFIG_GLOBAL="$TEST_TMP/home/.gitconfig"
    cd "$TEST_TMP"
    bash "$TEST_TMP/gitsetu" "$@"
)

# Verify lib does NOT exist in current directory
if [ -d "$TEST_TMP/lib" ]; then
    fail "isolation" "lib/ unexpectedly present in sandbox"
fi

# Test --version in isolation
ver_out=""
ver_rc=0
ver_out=$(run_isolated_bundle --version 2>/dev/null) || ver_rc=$?
if [[ "$ver_rc" -eq 0 && "$ver_out" == *"gitsetu v1.1.0"* ]]; then
    pass "standalone bundle runs --version without lib/ directory"
else
    fail "standalone --version" "exit=$ver_rc output was '$ver_out'"
fi

# Test --help in isolation
help_out=""
help_rc=0
help_out=$(run_isolated_bundle --help 2>&1) || help_rc=$?
if [[ "$help_rc" -eq 0 ]] && printf '%s\n' "$help_out" | grep -q "USAGE"; then
    pass "standalone bundle renders --help without lib/ directory"
else
    fail "standalone --help" "exit=$help_rc output was '$help_out'"
fi

# Test status in isolation
if run_isolated_bundle status >/dev/null 2>&1; then
    pass "standalone bundle executes status command in isolation"
else
    fail "standalone status" "status failed in isolation"
fi

# A fresh isolated home has no profiles, so verify must fail closed rather
# than being silently converted into a pass.
verify_out=""
verify_rc=0
verify_out=$(run_isolated_bundle verify 2>&1) || verify_rc=$?
if [[ "$verify_rc" -ne 0 ]] && printf '%s\n' "$verify_out" | grep -q "profiles configured"; then
    pass "standalone bundle reports an unconfigured verify state"
else
    fail "standalone verify" "expected a non-zero unconfigured result; exit=$verify_rc output='$verify_out'"
fi

# Cleanup
cd "$REPO_DIR"
rm -rf "$TEST_TMP"

echo ""
echo "Bundler tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
