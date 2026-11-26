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

# Verify render_release.sh prerelease tag, manifest sync, RC uninstall, and old-gh fallback
RC_OUT="$SANDBOX/rel-rc"
bash "$ROOT/scripts/render_release.sh" v1.1.0-rc.1 "https://example.invalid/v1.1.0-rc.1" "$RC_OUT" >/dev/null
grep -Fq "# Release state: released" "$RC_OUT/gitsetu"
if grep -Fq "# Development builds are not public release artifacts." "$RC_OUT/gitsetu"; then
    echo "Found unexpected development banner in release bundle" >&2
    exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
    RC_HASH="$(sha256sum "$RC_OUT/gitsetu" | cut -d' ' -f1)"
else
    RC_HASH="$(shasum -a 256 "$RC_OUT/gitsetu" | cut -d' ' -f1)"
fi
grep -Fq "\"version\": \"1.1.0-rc.1\"" "$RC_OUT/gitsetu.manifest.json"
grep -Fq "\"releaseState\": \"released\"" "$RC_OUT/gitsetu.manifest.json"
grep -Fq "\"bundleSha256\": \"$RC_HASH\"" "$RC_OUT/gitsetu.manifest.json"

OLD_GH_BIN="$SANDBOX/old-gh-bin"
mkdir -p "$OLD_GH_BIN"
cat > "$OLD_GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"attestation verify --help"* ]]; then
    echo 'unknown command "attestation" for "gh"' >&2
    exit 1
fi
exit 1
EOF
chmod +x "$OLD_GH_BIN/gh"

RC_INSTALL_ROOT="$SANDBOX/rc-install"
HOME="$SANDBOX/home" PATH="$OLD_GH_BIN:$PATH" GITSETU_TEST_MODE=1 \
    GITSETU_TEST_ARTIFACT="$RC_OUT/gitsetu" GITSETU_TEST_ARTIFACT_SHA256="$RC_HASH" \
    GITSETU_INSTALL_DIR="$RC_INSTALL_ROOT" GITSETU_TEST_BIN_DIR="$RC_INSTALL_ROOT/bin" \
    bash "$RC_OUT/install.sh" >/dev/null 2>&1
grep -Fq "version=1.1.0-rc.1" "$RC_INSTALL_ROOT/install.marker"
"$RC_INSTALL_ROOT/bin/gitsetu" --version | grep -Fq '1.1.0-rc.1'
HOME="$SANDBOX/home" GITSETU_TEST_MODE=1 GITSETU_INSTALL_DIR="$RC_INSTALL_ROOT" \
    GITSETU_TEST_BIN_DIR="$RC_INSTALL_ROOT/bin" bash "$RC_OUT/uninstall.sh" --force >/dev/null
[[ ! -e "$RC_INSTALL_ROOT" ]]

printf 'POSIX installer E2E: PASS\n'
