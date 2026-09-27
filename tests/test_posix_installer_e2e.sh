#!/usr/bin/env bash
# Focused POSIX installer E2E using a controlled, hash-pinned local artifact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)/gitsetu-posix-e2e.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT HUP INT TERM
INSTALL_ROOT="$SANDBOX/install"
ARTIFACT="$SANDBOX/gitsetu"
mkdir -p "$SANDBOX/home"

bash "$ROOT/scripts/bundle.sh" "$ARTIFACT" >/dev/null
if command -v sha256sum >/dev/null 2>&1; then
    HASH="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
else
    HASH="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
fi

install_local() {
    HOME="$SANDBOX/home" GITSETU_TEST_MODE=1 \
        GITSETU_TEST_ARTIFACT="$ARTIFACT" GITSETU_TEST_ARTIFACT_SHA256="$HASH" \
        GITSETU_INSTALL_DIR="$INSTALL_ROOT" GITSETU_TEST_BIN_DIR="$INSTALL_ROOT/bin" \
        bash "$ROOT/install.sh"
}

OUTPUT="$(install_local 2>&1)"
printf '%s\n' "$OUTPUT"
[[ -f "$INSTALL_ROOT/install.marker" && -f "$INSTALL_ROOT/current" ]]
[[ -x "$INSTALL_ROOT/bin/gitsetu" && -x "$INSTALL_ROOT/bin/git-setu" ]]
"$INSTALL_ROOT/bin/gitsetu" --version | grep -F 'gitsetu v1.1.0'
"$INSTALL_ROOT/bin/git-setu" --version | grep -F 'gitsetu v1.1.0'

install_local >/dev/null
HOME="$SANDBOX/home" GITSETU_TEST_MODE=1 GITSETU_INSTALL_DIR="$INSTALL_ROOT" \
    GITSETU_TEST_BIN_DIR="$INSTALL_ROOT/bin" bash "$ROOT/uninstall.sh" --force >/dev/null
[[ ! -e "$INSTALL_ROOT" ]]

printf 'POSIX installer E2E: PASS\n'
