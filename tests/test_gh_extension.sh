#!/usr/bin/env bash
# shellcheck disable=SC2015  # Test assertion idiom: pass/fail helpers return zero/nonzero explicitly.
# GitHub CLI extension wrapper contract tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/packaging/gh-extension/gh-gitsetu"
ALIAS="$ROOT/packaging/gh-extension/gh-setu"
passed=0
failed=0
pass() { printf '  [PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  [FAIL] %s\n' "$1" >&2; failed=$((failed + 1)); }

[[ -f "$EXT" && -x "$EXT" ]] && pass "gh-gitsetu is an executable file" || fail "gh-gitsetu executable"
[[ -f "$ALIAS" && -x "$ALIAS" ]] && pass "gh-setu is an executable file" || fail "gh-setu executable"
bash -n "$EXT" && bash -n "$ALIAS" && pass "extension scripts pass Bash syntax" || fail "extension syntax"
if diff -u <(tail -n +3 "$EXT") <(tail -n +3 "$ALIAS") >/dev/null; then
    pass "gh setu uses the same verified extension implementation"
else
    fail "gh setu implementation drift"
fi

version_output="$("$EXT" --version 2>&1)" || version_rc=$?
version_rc=${version_rc:-0}
if [[ "$version_rc" -eq 0 ]] && printf '%s' "$version_output" | grep -q 'gitsetu v1.1.0'; then
    pass "checkout extension delegates to the physical checkout"
else
    fail "checkout version delegation: $version_output"
fi
help_output="$("$EXT" --help 2>&1)" || help_rc=$?
help_rc=${help_rc:-0}
if [[ "$help_rc" -eq 0 ]] && printf '%s' "$help_output" | grep -q 'USAGE'; then
    pass "extension forwards help arguments"
else
    fail "extension help forwarding"
fi

if "$EXT" definitely-not-a-command >/dev/null 2>&1; then
    fail "extension forwards a failing status"
else
    pass "extension forwards a failing status"
fi

alias_output="$("$ALIAS" --version 2>&1)" || alias_rc=$?
alias_rc=${alias_rc:-0}
if [[ "$alias_rc" -eq 0 ]] && printf '%s' "$alias_output" | grep -q 'gitsetu v1.1.0'; then
    pass "gh setu alias delegates to the physical checkout"
else
    fail "gh setu alias: $alias_output"
fi

if grep -Eq 'command -v gitsetu|exec gitsetu|GITSETU_BASH' "$EXT" "$ALIAS"; then
    fail "extension PATH delegation guard"
else
    pass "extension has no arbitrary installed-command delegation"
fi

printf 'GitHub extension tests: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
