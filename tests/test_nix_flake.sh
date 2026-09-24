#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # Static Nix source assertions intentionally use literal '$out'.
# Nix flake source/dependency/alias policy tests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
passed=0
failed=0
pass() { printf '  [PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  [FAIL] %s\n' "$1" >&2; failed=$((failed + 1)); }

FLAKE="$ROOT/flake.nix"
LOCK="$ROOT/flake.lock"
[[ -f "$FLAKE" && -f "$LOCK" ]] && pass "flake and lock files exist" || fail "flake files"
REV='8825bebf6324e0579d012936eff73379af284b6d'
grep -q "github:NixOS/nixpkgs/$REV" "$FLAKE" && pass "nixpkgs input is commit-pinned" || fail "nixpkgs pin"
grep -q "\"rev\": \"$REV\"" "$LOCK" && pass "flake.lock matches the immutable nixpkgs revision" || fail "flake.lock pin"
if grep -q 'nixpkgs-unstable' "$FLAKE"; then fail "mutable nixpkgs branch"; else pass "no mutable nixpkgs branch"; fi
grep -q 'version = "1.1.0-dev"' "$FLAKE" && grep -q 'upstreamVersion = "1.1.0"' "$FLAKE" && pass "development package version is explicitly prerelease" || fail "development version marker"
grep -q 'releaseState = "development"' "$FLAKE" && grep -q 'publicRelease = false' "$FLAKE" && pass "Nix output is marked non-public development" || fail "Nix release state"
grep -Fq 'ln -s gitsetu $out/bin/git-setu' "$FLAKE" && pass "git-setu alias is generated" || fail "git-setu alias"
for dependency in bash git openssh openssl coreutils; do
    grep -q "            $dependency" "$FLAKE" || fail "runtime dependency $dependency"
done
pass "Nix wrapper declares required runtime tools"
grep -q 'bash_completion\|completion' "$FLAKE" && pass "Nix package includes completion metadata" || fail "Nix completion"

if command -v nix >/dev/null 2>&1; then
    nix flake check --no-build "$FLAKE" >/dev/null
    pass "nix flake check"
else
    printf '  [INFO] optional nix executable unavailable; static flake gate completed\n'
fi
printf 'Nix tests: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
