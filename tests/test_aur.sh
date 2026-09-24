#!/usr/bin/env bash
# shellcheck disable=SC2015  # Test assertion idiom: pass/fail helpers return zero/nonzero explicitly.
# AUR template/policy tests. No unreleased package definition is active.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGBUILD_TEMPLATE="$ROOT/packaging/templates/aur/PKGBUILD.in"
SRCINFO_TEMPLATE="$ROOT/packaging/templates/aur/.SRCINFO.in"
passed=0
failed=0
pass() { printf '  [PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  [FAIL] %s\n' "$1" >&2; failed=$((failed + 1)); }

[[ -f "$PKGBUILD_TEMPLATE" && -f "$SRCINFO_TEMPLATE" ]] && pass "AUR templates exist" || fail "AUR templates"
[[ ! -e "$ROOT/packaging/aur/PKGBUILD" && ! -e "$ROOT/packaging/aur/.SRCINFO" ]] && pass "unreleased AUR manifests are withheld" || fail "active AUR manifest"
grep -q '^depends=.*bash' "$PKGBUILD_TEMPLATE" && pass "AUR preserves Bash 3.2 support" || fail "AUR Bash policy"
if grep -q "bash>=4" "$PKGBUILD_TEMPLATE"; then fail "AUR stale Bash floor"; else pass "AUR has no stale Bash 4 floor"; fi
for dependency in git openssh openssl coreutils; do
    grep -q "'$dependency'" "$PKGBUILD_TEMPLATE" || fail "AUR dependency $dependency"
done
grep -q 'usr/bin/gitsetu' "$PKGBUILD_TEMPLATE" && grep -q 'git-setu' "$PKGBUILD_TEMPLATE" && pass "AUR template declares both command aliases" || fail "AUR aliases"
grep -q 'lib/completion.sh' "$PKGBUILD_TEMPLATE" && pass "AUR template packages completion metadata" || fail "AUR completion"
grep -q '{{SOURCE_SHA256}}' "$PKGBUILD_TEMPLATE" && grep -q '{{SOURCE_SHA256}}' "$SRCINFO_TEMPLATE" && pass "AUR source digest comes only from release rendering" || fail "AUR digest token"
if grep -R -E 'af0a75748e5c55a71bf8007daff4966b56db6fab0ce3d201ed06e5737f9a28a5|24a29b06a35d1b152b31fd42002ac382561c2a7296de3bdc0d10e8a3e35bc123' "$ROOT/packaging/templates" >/dev/null 2>&1; then
    fail "AUR stale release digest"
else
    pass "AUR templates contain no stale release digest"
fi

printf 'AUR tests: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
