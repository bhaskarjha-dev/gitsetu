#!/usr/bin/env bash
# tests/test_aur.sh — Tests Arch Linux AUR package definition (PKGBUILD & .SRCINFO)
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

echo "=== Running tests/test_aur.sh ==="

AUR_DIR="$REPO_DIR/packaging/aur"
PKGBUILD="$AUR_DIR/PKGBUILD"
SRCINFO="$AUR_DIR/.SRCINFO"

# 1. Existence
if [ -f "$PKGBUILD" ] && [ -f "$SRCINFO" ]; then
    pass "PKGBUILD and .SRCINFO files exist"
else
    fail "aur files" "PKGBUILD or .SRCINFO missing"
fi

# 2. Syntax check with bash -n
if bash -n "$PKGBUILD"; then
    pass "PKGBUILD passes bash syntax validation (bash -n)"
else
    fail "PKGBUILD syntax" "syntax error in PKGBUILD"
fi

# 3. Validate metadata
pkgname=$(grep "^pkgname=" "$PKGBUILD" | cut -d= -f2)
pkgver=$(grep "^pkgver=" "$PKGBUILD" | cut -d= -f2)
pkgrel=$(grep "^pkgrel=" "$PKGBUILD" | cut -d= -f2)

if [ "$pkgname" = "gitsetu" ] && [ "$pkgver" = "1.0.0" ] && [ "$pkgrel" = "1" ]; then
    pass "PKGBUILD package metadata valid (gitsetu v1.0.0-1)"
else
    fail "PKGBUILD metadata" "name=$pkgname, ver=$pkgver, rel=$pkgrel"
fi

# 4. Check dependencies in PKGBUILD
if grep -q "bash>=4.0" "$PKGBUILD" && grep -q "'git'" "$PKGBUILD" && grep -q "'openssh'" "$PKGBUILD"; then
    pass "PKGBUILD declares required runtime dependencies (bash, git, openssh)"
else
    fail "PKGBUILD depends" "missing required dependency declarations"
fi

# 5. Check .SRCINFO parity
src_name=$(grep "pkgname = " "$SRCINFO" | awk '{print $3}')
src_ver=$(grep "pkgver = " "$SRCINFO" | awk '{print $3}')
src_rel=$(grep "pkgrel = " "$SRCINFO" | awk '{print $3}')

if [ "$src_name" = "$pkgname" ] && [ "$src_ver" = "$pkgver" ] && [ "$src_rel" = "$pkgrel" ]; then
    pass ".SRCINFO is synchronized with PKGBUILD"
else
    fail ".SRCINFO parity" "mismatch with PKGBUILD ($src_name vs $pkgname, $src_ver vs $pkgver)"
fi

# 6. Check installation commands
if grep -q "usr/bin/gitsetu" "$PKGBUILD" && grep -q "usr/share/\$pkgname/lib" "$PKGBUILD"; then
    pass "PKGBUILD correctly installs binary wrapper and libraries"
else
    fail "PKGBUILD installation" "missing binary or library installation targets"
fi

echo ""
echo "AUR tests: $passed passed, $failed failed, $((passed + failed)) total"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
