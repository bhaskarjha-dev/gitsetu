#!/usr/bin/env bash
# Detached release-manifest contract tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_ROOT="$ROOT"
if command -v cygpath >/dev/null 2>&1 && [[ "${OSTYPE:-}" == cygwin* || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* ]]; then
    NODE_ROOT="$(cygpath -w "$ROOT")"
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-release-manifest.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM
ASSETS="$TMP_ROOT/assets"
mkdir -p "$ASSETS"
for file in \
    gitsetu-1.1.0-source.tar.gz \
    gitsetu-standalone \
    gitsetu-windows-x64.zip \
    gitsetu.exe \
    gitsetu-1.1.0.tgz \
    install.sh \
    install.ps1 \
    gitsetu-package-manifests.tar.gz \
    release.env; do
    printf 'fixture:%s\n' "$file" > "$ASSETS/$file"
done

SOURCE_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TAG_COMMIT="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
MANIFEST="$TMP_ROOT/release-manifest.json"
node "$NODE_ROOT/packaging/release-manifest.js" create \
    --directory "$ASSETS" \
    --output "$MANIFEST" \
    --tag v1.1.0 \
    --source-commit "$SOURCE_COMMIT" \
    --tag-commit "$TAG_COMMIT" \
    --created-at 2026-09-25T00:00:00Z \
    --skip-git true >/dev/null
node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$MANIFEST" \
    --directory "$ASSETS" \
    --tag v1.1.0 \
    --source-commit "$SOURCE_COMMIT" \
    --tag-commit "$TAG_COMMIT" \
    --skip-git true >/dev/null

REAL_SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD^)"
REAL_TAG_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
RELATIONSHIP_MANIFEST="$TMP_ROOT/relationship-release-manifest.json"
node "$NODE_ROOT/packaging/release-manifest.js" create \
    --directory "$ASSETS" \
    --output "$RELATIONSHIP_MANIFEST" \
    --tag v1.1.0 \
    --source-commit "$REAL_SOURCE_COMMIT" \
    --tag-commit "$REAL_TAG_COMMIT" \
    --phase core \
    --created-at 2026-09-25T00:00:00Z >/dev/null
node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$RELATIONSHIP_MANIFEST" \
    --directory "$ASSETS" \
    --phase core >/dev/null

CORE_MANIFEST="$TMP_ROOT/core-release-manifest.json"
node "$NODE_ROOT/packaging/release-manifest.js" create \
    --directory "$ASSETS" \
    --output "$CORE_MANIFEST" \
    --tag v1.1.0 \
    --source-commit "$SOURCE_COMMIT" \
    --tag-commit "$TAG_COMMIT" \
    --phase core \
    --created-at 2026-09-25T00:00:00Z \
    --skip-git true >/dev/null
node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$CORE_MANIFEST" \
    --directory "$ASSETS" \
    --phase core \
    --tag v1.1.0 \
    --skip-git true >/dev/null
if node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$CORE_MANIFEST" \
    --directory "$ASSETS" \
    --phase all \
    --skip-git true >/dev/null 2>&1; then
    printf 'core manifest was accepted as a complete manifest\n' >&2
    exit 1
fi

printf 'tamper' >> "$ASSETS/gitsetu-standalone"
if node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$MANIFEST" \
    --directory "$ASSETS" \
    --skip-git true >/dev/null 2>&1; then
    printf 'manifest verification accepted tampered bytes\n' >&2
    exit 1
fi

WORKFLOW="$ROOT/.github/workflows/release-provenance.yml"
if grep -Fq 'release.commit' "$WORKFLOW"; then
    printf 'preparation workflow still depends on embedded release.commit\n' >&2
    exit 1
fi
if grep -Eq 'npm[[:space:]]+publish|gh[[:space:]]+release[[:space:]]+create' "$WORKFLOW"; then
    printf 'preparation workflow still contains a publication action\n' >&2
    exit 1
fi
if ! grep -Fq 'GITSETU_BUNDLE_SOURCE_COMMIT' "$ROOT/scripts/bundle.sh"; then
    printf 'bundle source-commit override is missing\n' >&2
    exit 1
fi
if ! grep -Fq 'merge-base' "$ROOT/packaging/release-manifest.js"; then
    printf 'source/tag ancestry validation is missing\n' >&2
    exit 1
fi

printf 'release manifest contract: PASS\n'
