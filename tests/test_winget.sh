#!/usr/bin/env bash
# shellcheck disable=SC2015  # Test assertion idiom: pass/fail helpers return zero/nonzero explicitly.
# WinGet template and native-launcher policy tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT/packaging/templates/winget"
passed=0
failed=0
pass() { printf '  [PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  [FAIL] %s\n' "$1" >&2; failed=$((failed + 1)); }

[[ ! -e "$ROOT/packaging/winget/manifests" ]] && pass "unreleased WinGet manifests are withheld" || fail "active WinGet manifest"
for file in BhaskarJha.GitSetu.yaml.in BhaskarJha.GitSetu.installer.yaml.in BhaskarJha.GitSetu.locale.en-US.yaml.in; do
    [[ -f "$TEMPLATE_DIR/$file" ]] || fail "WinGet template $file"
done
pass "WinGet multi-file templates exist"
grep -q 'PackageIdentifier: BhaskarJha.GitSetu' "$TEMPLATE_DIR/BhaskarJha.GitSetu.yaml.in" && pass "canonical package identifier retained" || fail "WinGet identifier"
grep -q '{{WINDOWS_ZIP_URL}}' "$TEMPLATE_DIR/BhaskarJha.GitSetu.installer.yaml.in" && grep -q '{{WINDOWS_ZIP_SHA256}}' "$TEMPLATE_DIR/BhaskarJha.GitSetu.installer.yaml.in" && pass "WinGet URL and digest are release-rendered" || fail "WinGet release tokens"
grep -q '^  - git-setu' "$TEMPLATE_DIR/BhaskarJha.GitSetu.installer.yaml.in" && pass "WinGet declares git-setu alias" || fail "WinGet alias"
if grep -R -F '24a29b06a35d1b152b31fd42002ac382561c2a7296de3bdc0d10e8a3e35bc123' "$TEMPLATE_DIR" >/dev/null 2>&1; then
    fail "WinGet stale digest"
else
    pass "WinGet templates contain no stale digest"
fi

CS="$ROOT/packaging/windows/gitsetu.cs"
grep -q 'AppendQuotedArgument' "$CS" && grep -q 'backslashes \* 2' "$CS" && pass "native launcher contains tested Windows quoting logic" || fail "native launcher quoting"
if grep -Eq 'GITSETU_BASH|where\.exe|git --exec-path|Arguments = sb' "$CS"; then
    fail "native launcher untrusted discovery or manual argv construction"
else
    pass "native launcher has no arbitrary PATH/GITSETU_BASH discovery"
fi
grep -q 'FileAttributes.ReparsePoint' "$CS" && grep -q 'GetAccessRules' "$CS" && pass "native launcher validates reparse points and ACLs" || fail "native launcher trust checks"
grep -q 'Normalize-CompilerOutput' "$ROOT/packaging/windows/build_launcher.ps1" && pass "Windows build normalizes compiler nondeterminism" || fail "Windows deterministic build"

printf 'WinGet tests: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
