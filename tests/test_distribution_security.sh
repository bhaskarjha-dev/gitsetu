#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2016  # Isolated HOME and literal package-template tokens are intentional.
# Distribution policy, installer containment, extension cache, and CI tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_ROOT="$ROOT"
if command -v cygpath >/dev/null 2>&1 && [[ "${OSTYPE:-}" == cygwin* || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* ]]; then
    NODE_ROOT="$(cygpath -w "$ROOT")"
fi
passed=0
failed=0

pass() { printf '  [PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  [FAIL] %s: %s\n' "$1" "$2" >&2; failed=$((failed + 1)); }

TMP_ROOT="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)/gitsetu-distribution-security.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

# H-11: v1.1.0 is intentionally withheld and has no installable package claims.
if node -e "const m=require(process.argv[1]); process.exit(m.release.state==='development'&&m.release.prerelease===true&&m.release.public===false&&Object.keys(m.artifacts).length===0?0:1)" "$NODE_ROOT/packaging/release.json"; then
    pass "v1.1.0 release metadata is explicitly non-public development state"
else
    fail "development release policy" "release.json does not withhold v1.1.0 artifacts"
fi
if node -e "const p=require(process.argv[1]); process.exit(p.private===true&&p.gitsetuRelease.state==='development'?0:1)" "$NODE_ROOT/package.json"; then
    pass "npm metadata is private and development-marked"
else
    fail "npm policy" "package.json is not withheld"
fi
if node "$NODE_ROOT/packaging/release.js" render "$(cygpath -w "$TMP_ROOT/should-not-render" 2>/dev/null || printf '%s' "$TMP_ROOT/should-not-render")" >/dev/null 2>&1; then
    fail "template render gate" "development metadata rendered installable manifests"
else
    pass "development metadata cannot render installable package manifests"
fi
if [[ ! -e "$ROOT/packaging/aur/PKGBUILD" && ! -e "$ROOT/packaging/homebrew/gitsetu.rb" && ! -e "$ROOT/packaging/scoop/gitsetu.json" ]] && { [[ ! -d "$ROOT/packaging/winget/manifests" ]] || [[ -z "$(find "$ROOT/packaging/winget/manifests" -type f -print -quit)" ]]; }; then
    pass "AUR, Homebrew, Scoop, and WinGet release manifests are withheld"
else
    fail "active package manifests" "an unreleased v1.1.0 installable manifest is present"
fi
if ! grep -R -F 'af0a75748e5c55a71bf8007daff4966b56db6fab0ce3d201ed06e5737f9a28a5' "$ROOT/packaging" >/dev/null 2>&1; then
    pass "stale v1.0.0 digest is absent from v1.1 package metadata"
else
    fail "stale digest" "old digest remains under packaging/"
fi

if grep -q 'Shellwords.escape' "$ROOT/packaging/templates/homebrew/gitsetu.rb.in" && grep -q 'git-setu' "$ROOT/packaging/templates/homebrew/gitsetu.rb.in"; then
    pass "Homebrew template uses a safely quoted wrapper and git-setu alias"
else
    fail "Homebrew template" "safe wrapper or command alias is missing"
fi
if grep -q 'GetGitHubReleaseHash' "$ROOT/packaging/templates/scoop/gitsetu.json.in" && grep -q 'v\$version' "$ROOT/packaging/templates/scoop/gitsetu.json.in"; then
    pass "Scoop template derives versioned updates from release metadata"
else
    fail "Scoop template" "autoupdate digest/version policy is missing"
fi

# Mutable upstream execution and hard-reset updater behavior are forbidden.
if grep -E 'origin/main|git reset|raw\.githubusercontent\.com/.*/main|curl[^|]*\|[[:space:]]*bash|irm[^|]*\|[[:space:]]*iex' \
    "$ROOT/install.sh" "$ROOT/install.ps1" "$ROOT/uninstall.sh" "$ROOT/uninstall.ps1" >/dev/null 2>&1; then
    fail "installer trust" "mutable installer/updater behavior remains"
else
    pass "installers contain no mutable branch, reset, or pipe-to-shell path"
fi
if grep -E 'command -v gitsetu|GITSETU_BASH' "$ROOT/packaging/gh-extension/gh-gitsetu" "$ROOT/packaging/gh-extension/gh-setu" >/dev/null 2>&1; then
    fail "extension delegation" "extension delegates through arbitrary PATH"
else
    pass "extension does not delegate through an installed PATH command"
fi

# Workflow actions are pinned, checkout credentials are not persisted, and PR
# workflows cannot reference release secrets.
if node - "$NODE_ROOT/.github/workflows" <<'NODE'
const fs = require('fs');
const path = require('path');
const directory = process.argv[2];
let ok = true;
for (const name of fs.readdirSync(directory).filter((n) => /\.ya?ml$/.test(n))) {
  const text = fs.readFileSync(path.join(directory, name), 'utf8');
  for (const match of text.matchAll(/^\s*uses:\s*([^\s#]+)(?:\s+#.*)?$/gm)) {
    if (!/@[0-9a-f]{40}$/.test(match[1])) { console.error(`unpinned action in ${name}: ${match[1]}`); ok = false; }
  }
  if (/pull_request_target|Invoke-RestMethod[^\n]*get\.scoop\.sh[^\n]*Invoke-Expression/.test(text)) {
    console.error(`unsafe PR/live-installer workflow content in ${name}`); ok = false;
  }
  const checkoutPattern = /- name: Checkout[^\n]*\n\s+uses: actions\/checkout@[0-9a-f]{40}[^\n]*\n(?:\s+with:\n(?:\s{10,}[^\n]+\n)*)?/g;
  for (const match of text.matchAll(checkoutPattern)) {
    if (!/persist-credentials:\s*false/.test(match[0])) { console.error(`checkout credentials persist in ${name}`); ok = false; }
  }
  if (/^on:[\s\S]*?pull_request:/m.test(text) && /secrets\./.test(text)) {
    console.error(`pull_request workflow references secrets in ${name}`); ok = false;
  }
}
process.exit(ok ? 0 : 1);
NODE
then
    pass "workflow actions are pinned and credential containment is explicit"
else
    fail "workflow containment" "see static workflow policy errors above"
fi

# A clean reviewed checkout is the only normal-mode development install path.
FIXTURE="$TMP_ROOT/clean-checkout"
mkdir -p "$FIXTURE"
git -C "$ROOT" archive HEAD | tar -x -C "$FIXTURE"
mkdir -p "$FIXTURE/packaging/gh-extension" "$FIXTURE/scripts"
cp "$ROOT/gitsetu" "$FIXTURE/gitsetu"
rm -rf "${FIXTURE:?}/lib"
cp -R "$ROOT/lib" "$FIXTURE/lib"
cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$FIXTURE/"
cp "$ROOT/scripts/bundle.sh" "$FIXTURE/scripts/"
cp "$ROOT/packaging/release.js" "$ROOT/packaging/release.json" "$ROOT/packaging/release.env" "$FIXTURE/packaging/"
cp "$ROOT/packaging/gh-extension/gh-gitsetu" "$ROOT/packaging/gh-extension/gh-setu" "$FIXTURE/packaging/gh-extension/"
cp "$ROOT/package.json" "$ROOT/package-lock.json" "$ROOT/flake.nix" "$ROOT/flake.lock" "$FIXTURE/"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name 'Distribution Test'
git -C "$FIXTURE" config user.email 'distribution@example.invalid'
git -c core.autocrlf=false -C "$FIXTURE" add .
git -C "$FIXTURE" commit -q -m 'test: clean local development fixture'
mkdir -p "$FIXTURE/home"
run_clean_checkout_install() (
    unset XDG_DATA_HOME GITSETU_TEST_MODE GITSETU_INSTALL_DIR GITSETU_TEST_BIN_DIR
    export HOME="$FIXTURE/home"
    bash "$FIXTURE/install.sh" 2>&1
)
local_output="$(run_clean_checkout_install)" || local_rc=$?
local_rc=${local_rc:-0}
local_version=""
local_version_rc=0
if [[ -x "$FIXTURE/home/.local/bin/gitsetu" ]]; then
    local_version="$("$FIXTURE/home/.local/bin/gitsetu" --version 2>&1)" || local_version_rc=$?
else
    local_version_rc=1
fi
if [[ "$local_rc" -eq 0 && "$local_version_rc" -eq 0 && "$local_version" == *"gitsetu v1.1.0"* && "$local_output" == *"not a public release"* ]]; then
    pass "clean reviewed checkout installs a clearly local-development build"
else
    fail "local-development installer" "install_exit=$local_rc version_exit=$local_version_rc version=$local_version output=$local_output"
fi
printf 'dirty\n' > "$FIXTURE/dirty.txt"
dirty_output="$(unset GITSETU_TEST_MODE GITSETU_TEST_ARTIFACT GITSETU_TEST_ARTIFACT_SHA256 GITSETU_INSTALL_DIR GITSETU_TEST_BIN_DIR; HOME="$FIXTURE/home" XDG_DATA_HOME="$FIXTURE/dirty-data" bash "$FIXTURE/install.sh" --local-development 2>&1)" && dirty_rc=0 || dirty_rc=$?
if [[ "$dirty_rc" -ne 0 ]] && printf '%s' "$dirty_output" | grep -q 'dirty Git checkout' && [[ ! -e "$FIXTURE/dirty-data/gitsetu" ]]; then
    pass "local-development mode refuses a dirty checkout without residue"
else
    fail "dirty local checkout" "exit=$dirty_rc output=$dirty_output"
fi
rm -f "$FIXTURE/dirty.txt"
if [[ -e "$FIXTURE/home/.local/share/gitsetu" ]] && (unset XDG_DATA_HOME; export HOME="$FIXTURE/home"; bash "$FIXTURE/uninstall.sh" --force >/dev/null 2>&1) && [[ ! -e "$FIXTURE/home/.local/share/gitsetu" ]]; then
    pass "marker-verified local-development install uninstalls cleanly"
else
    fail "local-development uninstaller" "verified installation was absent or remained"
fi

# A bad digest and an unmarked victim must both fail without destructive effects.
git -C "$ROOT" show HEAD:dist/gitsetu > "$TMP_ROOT/artifact"
artifact_hash="$(sha256sum "$TMP_ROOT/artifact" | cut -d' ' -f1)"
printf 'x' >> "$TMP_ROOT/artifact"
bad_root="$TMP_ROOT/bad-install"
if HOME="$FIXTURE/home" GITSETU_TEST_MODE=1 GITSETU_INSTALL_DIR="$bad_root" \
    GITSETU_TEST_BIN_DIR="$bad_root/bin" GITSETU_TEST_ARTIFACT="$TMP_ROOT/artifact" \
    GITSETU_TEST_ARTIFACT_SHA256="$artifact_hash" bash "$ROOT/install.sh" >/dev/null 2>&1; then
    fail "installer digest gate" "modified artifact was accepted"
else
    [[ ! -e "$bad_root" ]] || rm -rf -- "$bad_root"
    pass "installer rejects a modified artifact and removes partial root"
fi
mkdir -p "$TMP_ROOT/victim"
printf 'keep' > "$TMP_ROOT/victim/file"
printf 'format=9\n' > "$TMP_ROOT/victim/install.marker"
if HOME="$FIXTURE/home" GITSETU_TEST_MODE=1 GITSETU_INSTALL_DIR="$TMP_ROOT/victim" \
    GITSETU_TEST_BIN_DIR="$TMP_ROOT/victim/bin" bash "$ROOT/uninstall.sh" --force >/dev/null 2>&1; then
    fail "uninstaller marker gate" "unmarked directory was removed"
else
    [[ -f "$TMP_ROOT/victim/file" ]] || fail "victim preservation" "victim file was deleted"
    pass "uninstaller refuses an unmarked victim directory"
fi

# Extension cache: first execution verifies/promotes; every later execution
# rehashes, and a modified cache cannot execute.
EXT_ROOT="$TMP_ROOT/extension-root"
mkdir -p "$EXT_ROOT/packaging/gh-extension"
cp "$ROOT/packaging/gh-extension/gh-gitsetu" "$ROOT/packaging/gh-extension/gh-setu" "$EXT_ROOT/packaging/gh-extension/"
cp "$ROOT/packaging/release.env" "$EXT_ROOT/packaging/"
git -C "$ROOT" show HEAD:dist/gitsetu > "$TMP_ROOT/extension-artifact"
extension_hash="$(sha256sum "$TMP_ROOT/extension-artifact" | cut -d' ' -f1)"
extension_output="$(HOME="$FIXTURE/home" XDG_CACHE_HOME="$TMP_ROOT/extension-cache" GITSETU_TEST_MODE=1 \
    GITSETU_TEST_ARTIFACT="$TMP_ROOT/extension-artifact" GITSETU_TEST_ARTIFACT_SHA256="$extension_hash" \
    bash "$EXT_ROOT/packaging/gh-extension/gh-gitsetu" --version 2>&1)" || extension_rc=$?
extension_rc=${extension_rc:-0}
cache_runner="$TMP_ROOT/extension-cache/gitsetu/extension-v1.1.0/gitsetu"
if [[ "$extension_rc" -eq 0 && -f "$cache_runner" ]] && printf '%s' "$extension_output" | grep -q 'gitsetu v1.1.0'; then
    pass "extension installs a hash-verified private cache artifact"
else
    fail "extension cache install" "exit=$extension_rc output=$extension_output"
fi
chmod 700 "$cache_runner"
printf 'tampered' >> "$cache_runner"
if HOME="$FIXTURE/home" XDG_CACHE_HOME="$TMP_ROOT/extension-cache" GITSETU_TEST_MODE=1 \
    GITSETU_TEST_ARTIFACT="$TMP_ROOT/extension-artifact" GITSETU_TEST_ARTIFACT_SHA256="$extension_hash" \
    bash "$EXT_ROOT/packaging/gh-extension/gh-gitsetu" --version >/dev/null 2>&1; then
    fail "extension cache revalidation" "modified cache was executed"
else
    pass "extension rehashes its cache and rejects a modified artifact"
fi

printf '\nDistribution security tests: %d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
