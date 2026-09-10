#!/usr/bin/env bash
# tests/test_npm_wrapper.sh — Tests npm/npx packaging wrapper
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

echo "=== Running tests/test_npm_wrapper.sh ==="

# Check Node.js and npm availability
if ! command -v node >/dev/null 2>&1; then
    echo "Node.js not installed in PATH. Skipping npm wrapper tests."
    exit 0
fi

# 1. Validate package.json fields
cd "$REPO_DIR"
if [ ! -f "package.json" ]; then
    fail "package.json" "package.json file missing"
else
    pkg_name=$(node -e "console.log(require('./package.json').name)")
    pkg_version=$(node -e "console.log(require('./package.json').version)")
    pkg_bin_gitsetu=$(node -e "console.log(require('./package.json').bin.gitsetu)")
    pkg_bin_git_setu=$(node -e "console.log(require('./package.json').bin['git-setu'])")

    if [ "$pkg_name" = "gitsetu" ] && [ "$pkg_version" = "1.0.0" ] && [ "$pkg_bin_gitsetu" = "./bin/gitsetu.js" ] && [ "$pkg_bin_git_setu" = "./bin/gitsetu.js" ]; then
        pass "package.json schema & metadata valid"
    else
        fail "package.json schema" "name=$pkg_name, ver=$pkg_version, bin=$pkg_bin_gitsetu"
    fi
fi

# 2. Test node bin/gitsetu.js --version
ver_out=$(node "$REPO_DIR/bin/gitsetu.js" --version 2>/dev/null || echo "")
if [[ "$ver_out" == *"gitsetu v1.0.0"* ]]; then
    pass "node bin/gitsetu.js --version output matches v1.0.0"
else
    fail "node bin/gitsetu.js --version" "output was '$ver_out'"
fi

# 3. Test node bin/gitsetu.js --help
if node "$REPO_DIR/bin/gitsetu.js" --help 2>&1 | grep -q "USAGE"; then
    pass "node bin/gitsetu.js --help renders help menu"
else
    fail "node bin/gitsetu.js --help" "failed to render USAGE header"
fi

# 4. Test exit code forwarding for unknown command
set +e
node "$REPO_DIR/bin/gitsetu.js" non-existent-command-xyz >/dev/null 2>&1
exit_code=$?
set -e
if [ "$exit_code" -ne 0 ]; then
    pass "node bin/gitsetu.js forwards non-zero exit code on failure"
else
    fail "exit code forwarding" "expected non-zero exit code but got $exit_code"
fi

# 5. Test npm pack and extracted execution in isolated sandbox
if command -v npm >/dev/null 2>&1; then
    TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-npm-test.XXXXXX")
    cd "$TEST_TMP"

    # Pack repo into tarball
    pack_tgz=$(npm pack "$REPO_DIR" --silent 2>/dev/null || echo "")
    if [ -n "$pack_tgz" ] && [ -f "$pack_tgz" ]; then
        pass "npm pack generates distribution tarball ($pack_tgz)"

        # Extract tarball into isolated sandbox
        mkdir -p extracted
        tar -xzf "$pack_tgz" -C extracted

        # Execute extracted bin/gitsetu.js in isolation
        ext_ver=$(node extracted/package/bin/gitsetu.js --version 2>/dev/null || echo "")
        if [[ "$ext_ver" == *"gitsetu v1.0.0"* ]]; then
            pass "extracted npm package executes independently"
        else
            fail "extracted npm package" "failed to run --version in isolation (output: '$ext_ver')"
        fi
    else
        fail "npm pack" "failed to produce tarball"
    fi

    # Cleanup sandbox
    rm -rf "$TEST_TMP"
fi

echo ""
echo "NPM wrapper tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
