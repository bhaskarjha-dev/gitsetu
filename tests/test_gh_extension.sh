#!/usr/bin/env bash
# tests/test_gh_extension.sh — Tests GitHub CLI extension wrapper
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

echo "=== Running tests/test_gh_extension.sh ==="

GH_EXT="$REPO_DIR/packaging/gh-extension/gh-gitsetu"

# 1. Existence & syntax
if [ -f "$GH_EXT" ]; then
    pass "packaging/gh-extension/gh-gitsetu exists"
else
    fail "extension existence" "gh-gitsetu missing"
fi

if bash -n "$GH_EXT"; then
    pass "gh-gitsetu passes bash syntax validation"
else
    fail "syntax" "syntax error in gh-gitsetu"
fi

# 2. Test --version delegation
ver_out=$(bash "$GH_EXT" --version 2>/dev/null || echo "")
if [[ "$ver_out" == *"gitsetu v1.0.0"* ]]; then
    pass "gh-gitsetu --version delegates and returns v1.0.0"
else
    fail "gh-gitsetu --version" "output was '$ver_out'"
fi

# 3. Test --help delegation
help_out=$(bash "$GH_EXT" --help 2>&1 || true)
if echo "$help_out" | grep -q "USAGE"; then
    pass "gh-gitsetu --help delegates and renders help menu"
else
    fail "gh-gitsetu --help" "failed to render USAGE header"
fi

# 4. Test argument forwarding with status command
if bash "$GH_EXT" status >/dev/null 2>&1; then
    pass "gh-gitsetu status forwards subcommand cleanly"
else
    fail "gh-gitsetu status" "subcommand failed to execute"
fi

# 5. Test exit code forwarding for unknown command
set +e
bash "$GH_EXT" unknown-cmd-xyz >/dev/null 2>&1
exit_code=$?
set -e
if [ "$exit_code" -ne 0 ]; then
    pass "gh-gitsetu forwards non-zero exit code on failure"
else
    fail "exit code forwarding" "expected non-zero exit code but got $exit_code"
fi

echo ""
echo "GitHub CLI Extension tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
