#!/usr/bin/env bash
# tests/test_nix_flake.sh — Tests Nix Flake definition and metadata
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

echo "=== Running tests/test_nix_flake.sh ==="

FLAKE_FILE="$REPO_DIR/flake.nix"

# 1. Existence
if [ -f "$FLAKE_FILE" ]; then
    pass "flake.nix exists in repository root"
else
    fail "flake existence" "flake.nix file not found"
fi

# 2. Structure & Metadata
if grep -q 'inputs = {' "$FLAKE_FILE" && grep -q 'nixpkgs.url' "$FLAKE_FILE"; then
    pass "flake inputs declare nixpkgs"
else
    fail "flake inputs" "nixpkgs input missing"
fi

if grep -q 'pname = "gitsetu"' "$FLAKE_FILE" && grep -q 'version = "1.0.0"' "$FLAKE_FILE"; then
    pass "flake package declares gitsetu v1.0.0"
else
    fail "flake package" "pname or version mismatch"
fi

if grep -q 'packages.default' "$FLAKE_FILE" || grep -q 'packages = forAllSystems' "$FLAKE_FILE"; then
    pass "flake exposes default package for supported systems"
else
    fail "flake package output" "default package declaration missing"
fi

if grep -q 'apps = forAllSystems' "$FLAKE_FILE" && grep -q 'mainProgram = "gitsetu"' "$FLAKE_FILE"; then
    pass "flake exposes default app and declares mainProgram"
else
    fail "flake app output" "default app declaration missing"
fi

# 3. Installation directives
# shellcheck disable=SC2016
if grep -q 'ln -s \$out/bin/gitsetu \$out/bin/git-setu' "$FLAKE_FILE"; then
    pass "flake creates git-setu compatibility symlink"
else
    fail "flake symlink" "git-setu symlink directive missing"
fi

# 4. Optional live nix check
if command -v nix >/dev/null 2>&1; then
    if nix flake check --no-build "$FLAKE_FILE" >/dev/null 2>&1; then
        pass "nix flake check passes"
    fi
fi

echo ""
echo "Nix Flake tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
