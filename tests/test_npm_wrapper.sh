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
    printf '  [SKIP] npm wrapper tests: Node.js is not installed\n'
    exit 77
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

    pkg_private=$(node -e "console.log(require('./package.json').private)")
    pkg_state=$(node -e "console.log(require('./package.json').gitsetuRelease.state)")
    if [ "$pkg_name" = "gitsetu" ] && [ "$pkg_version" = "1.1.0" ] && [ "$pkg_private" = "true" ] && [ "$pkg_state" = "development" ] && [ "$pkg_bin_gitsetu" = "./bin/gitsetu.js" ] && [ "$pkg_bin_git_setu" = "./bin/gitsetu.js" ]; then
        pass "package.json schema & metadata valid"
    else
        fail "package.json schema" "name=$pkg_name, ver=$pkg_version, bin=$pkg_bin_gitsetu"
    fi
fi

if [ -f package-lock.json ] && node -e "const l=require('./package-lock.json'); process.exit(l.lockfileVersion===3 && l.packages[''].version==='1.1.0' ? 0 : 1)"; then
    pass "package-lock.json matches the dependency-free npm package"
else
    fail "package lock" "lockfile missing or stale"
fi
if grep -Eq 'process\.env\.GITSETU_BASH|where\.exe|git.*--exec-path' bin/gitsetu.js; then
    fail "Windows trust" "npm wrapper contains arbitrary Bash discovery"
else
    pass "npm wrapper uses trusted standard Windows discovery"
fi

# 2. Test node bin/gitsetu.js --version
ver_out=$(GITSETU_NPM_TEST_MODE=1 node "$REPO_DIR/bin/gitsetu.js" --version 2>/dev/null || echo "")
if [[ "$ver_out" == *"gitsetu v1.1.0"* ]]; then
    pass "node bin/gitsetu.js --version output matches v1.1.0"
else
    fail "node bin/gitsetu.js --version" "output was '$ver_out'"
fi

# 3. Test node bin/gitsetu.js --help
if GITSETU_NPM_TEST_MODE=1 node "$REPO_DIR/bin/gitsetu.js" --help 2>&1 | grep -q "USAGE"; then
    pass "node bin/gitsetu.js --help renders help menu"
else
    fail "node bin/gitsetu.js --help" "failed to render USAGE header"
fi

# 4. Test exit code forwarding for unknown command
set +e
GITSETU_NPM_TEST_MODE=1 node "$REPO_DIR/bin/gitsetu.js" non-existent-command-xyz >/dev/null 2>&1
exit_code=$?
set -e
if [ "$exit_code" -ne 0 ]; then
    pass "node bin/gitsetu.js forwards non-zero exit code on failure"
else
    fail "exit code forwarding" "expected non-zero exit code but got $exit_code"
fi

# 5. Validate the explicit package-root/runtime contract
CONTRACT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-npm-contract.XXXXXX")
mkdir -p "$CONTRACT_TMP/package/bin" "$CONTRACT_TMP/package/lib"
cp bin/gitsetu.js "$CONTRACT_TMP/package/bin/gitsetu.js"
cp package.json "$CONTRACT_TMP/package/package.json"
cat > "$CONTRACT_TMP/package/gitsetu" <<'CONTRACT_EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' "$GITSETU_RUNTIME_MODE" "$GITSETU_DISTRIBUTION_CHANNEL" "$GITSETU_PACKAGE_ROOT" "$GITSETU_SCRIPT_PATH" "${GITSETU_TEST_BIN-unset}"
CONTRACT_EOF
contract_output=$(cd "$CONTRACT_TMP/package" && GITSETU_TEST_BIN=untrusted node bin/gitsetu.js 2>&1) || contract_rc=$?
contract_rc=${contract_rc:-0}
if [[ "$contract_rc" -eq 0 && "$contract_output" == verified-npm-package\|npm\|*\|*/gitsetu\|unset ]]; then
    pass "npm wrapper passes a validated root/mode/path contract and clears overrides"
else
    fail "npm package contract" "exit=$contract_rc output=$contract_output"
fi

system_drive="${SystemDrive:-${SYSTEMDRIVE:-}}"
system_root="${SystemRoot:-${SYSTEMROOT:-}}"
if [[ -n "$system_drive" && -n "$system_root" ]]; then
    if SYSTEMROOT="$CONTRACT_TMP/fake-Windows" GITSETU_NPM_TEST_MODE=1 node "$REPO_DIR/bin/gitsetu.js" --version >/dev/null 2>&1; then
        fail "Windows system root" "unapproved SystemRoot override was accepted"
    else
        pass "npm wrapper rejects an unapproved Windows system-root override"
    fi
fi

if node -e "const fs=require('fs'),t=process.platform==='win32'?'junction':'dir';fs.symlinkSync('package',process.argv[1],t)" "$CONTRACT_TMP/package-link" 2>/dev/null; then
    if (cd "$CONTRACT_TMP" && node package-link/bin/gitsetu.js >/dev/null 2>&1); then
        fail "npm redirected root" "symlinked package root was accepted"
    else
        pass "npm wrapper rejects a symlinked package-root component"
    fi
else
    printf '  [INFO] package-root link creation unavailable; redirected-root case not exercised\n'
fi

if [[ -e "$REPO_DIR/.git" ]]; then
    if node "$REPO_DIR/bin/gitsetu.js" --version >/dev/null 2>&1; then
        fail "npm checkout rejection" "a Git checkout was accepted as an npm root"
    else
        pass "npm wrapper rejects an untrusted development Git checkout"
    fi
fi

cp package.json "$CONTRACT_TMP/package/package.json"
node -e "const fs=require('fs'),p=process.argv[1],j=require(p);j.bin.gitsetu='./other.js';fs.writeFileSync(p,JSON.stringify(j))" "$CONTRACT_TMP/package/package.json"
if (cd "$CONTRACT_TMP/package" && node bin/gitsetu.js >/dev/null 2>&1); then
    fail "npm manifest identity" "tampered bin alias was accepted"
else
    pass "npm wrapper rejects inconsistent package aliases"
fi
cp package.json "$CONTRACT_TMP/package/package.json"

# The selected target must be a regular file, not a directory.
rm -f "$CONTRACT_TMP/package/gitsetu"
mkdir -p "$CONTRACT_TMP/package/gitsetu"
if (cd "$CONTRACT_TMP/package" && node bin/gitsetu.js >/dev/null 2>&1); then
    fail "npm regular target" "directory target was accepted"
else
    pass "npm wrapper rejects a non-regular package target"
fi
rmdir "$CONTRACT_TMP/package/gitsetu"

# On platforms that permit symlink creation, the final target must be rejected.
printf '#!/usr/bin/env bash\nexit 0\n' > "$CONTRACT_TMP/package/real-gitsetu"
if node -e "require('fs').symlinkSync('real-gitsetu',process.argv[1],'file')" "$CONTRACT_TMP/package/gitsetu" 2>/dev/null; then
    if (cd "$CONTRACT_TMP/package" && node bin/gitsetu.js >/dev/null 2>&1); then
        fail "npm symlink target" "symlink target was accepted"
    else
        pass "npm wrapper rejects a symlink package target"
    fi
else
    printf '  [INFO] symlink creation unavailable; final-link runtime case not exercised\n'
fi
rm -rf -- "$CONTRACT_TMP"

# 6. Test npm pack and extracted execution in isolated sandbox
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
        if [[ "$ext_ver" == *"gitsetu v1.1.0"* ]]; then
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
