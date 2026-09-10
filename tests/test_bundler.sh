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

# 2. Check standalone flag is embedded
if grep -q "GITSETU_STANDALONE=1" "$BUNDLE_FILE"; then
    pass "dist/gitsetu embeds GITSETU_STANDALONE=1 banner"
else
    fail "standalone flag" "GITSETU_STANDALONE not defined in bundle"
fi

# 3. Test standalone execution in isolated directory (NO lib/ directory present)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-bundle-test.XXXXXX")
cp "$BUNDLE_FILE" "$TEST_TMP/gitsetu"
chmod +x "$TEST_TMP/gitsetu"

cd "$TEST_TMP"

# Verify lib does NOT exist in current directory
if [ -d "$TEST_TMP/lib" ]; then
    fail "isolation" "lib/ unexpectedly present in sandbox"
fi

# Test --version in isolation
ver_out=$("$TEST_TMP/gitsetu" --version 2>/dev/null || echo "")
if [[ "$ver_out" == *"gitsetu v1.0.0"* ]]; then
    pass "standalone bundle runs --version without lib/ directory"
else
    fail "standalone --version" "output was '$ver_out'"
fi

# Test --help in isolation
help_out=$("$TEST_TMP/gitsetu" --help 2>&1 || true)
if echo "$help_out" | grep -q "USAGE"; then
    pass "standalone bundle renders --help without lib/ directory"
else
    fail "standalone --help" "failed to render USAGE header"
fi

# Test status in isolation
if "$TEST_TMP/gitsetu" status >/dev/null 2>&1; then
    pass "standalone bundle executes status command in isolation"
else
    fail "standalone status" "status failed in isolation"
fi

# Test verify in isolation
if "$TEST_TMP/gitsetu" verify >/dev/null 2>&1 || true; then
    pass "standalone bundle executes verify command in isolation"
fi

# Cleanup
cd "$REPO_DIR"
rm -rf "$TEST_TMP"

echo ""
echo "Bundler tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
