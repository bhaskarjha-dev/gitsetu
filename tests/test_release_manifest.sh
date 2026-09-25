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

REAL_HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_COMMIT="$REAL_HEAD_COMMIT"
TAG_COMMIT="$REAL_HEAD_COMMIT"
MANIFEST="$TMP_ROOT/release-manifest.json"
node "$NODE_ROOT/packaging/release-manifest.js" create \
    --directory "$ASSETS" \
    --output "$MANIFEST" \
    --tag v1.1.0 \
    --source-commit "$SOURCE_COMMIT" \
    --tag-commit "$TAG_COMMIT" \
    --created-at 2026-09-25T00:00:00Z >/dev/null
node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$MANIFEST" \
    --directory "$ASSETS" \
    --tag v1.1.0 \
    --source-commit "$SOURCE_COMMIT" \
    --tag-commit "$TAG_COMMIT" >/dev/null

RELATIONSHIP_MANIFEST="$TMP_ROOT/relationship-release-manifest.json"
if REAL_SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD^ 2>/dev/null)"; then
    REAL_TAG_COMMIT="$REAL_HEAD_COMMIT"
else
    # Shallow CI checkouts have no parent object; retain a same-commit fixture
    # there while full clones exercise the distinct source/tag relationship.
    REAL_SOURCE_COMMIT="$REAL_HEAD_COMMIT"
    REAL_TAG_COMMIT="$REAL_HEAD_COMMIT"
fi
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
if node "$NODE_ROOT/packaging/release-manifest.js" create \
    --directory "$ASSETS" \
    --output "$TMP_ROOT/invalid-relationship.json" \
    --tag v1.1.0 \
    --source-commit 1111111111111111111111111111111111111111 \
    --tag-commit 2222222222222222222222222222222222222222 \
    --phase core \
    --created-at 2026-09-25T00:00:00Z >/dev/null 2>&1; then
    printf 'non-ancestor source/tag relationship was accepted\n' >&2
    exit 1
fi

CORE_MANIFEST="$TMP_ROOT/core-release-manifest.json"
node "$NODE_ROOT/packaging/release-manifest.js" create \
    --directory "$ASSETS" \
    --output "$CORE_MANIFEST" \
    --tag v1.1.0 \
    --source-commit "$SOURCE_COMMIT" \
    --tag-commit "$TAG_COMMIT" \
    --phase core \
    --created-at 2026-09-25T00:00:00Z >/dev/null
node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$CORE_MANIFEST" \
    --directory "$ASSETS" \
    --phase core \
    --tag v1.1.0 >/dev/null
if node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$CORE_MANIFEST" \
    --directory "$ASSETS" \
    --phase all >/dev/null 2>&1; then
    printf 'core manifest was accepted as a complete manifest\n' >&2
    exit 1
fi

printf 'tamper' >> "$ASSETS/gitsetu-standalone"
if node "$NODE_ROOT/packaging/release-manifest.js" verify \
    --manifest "$MANIFEST" \
    --directory "$ASSETS" >/dev/null 2>&1; then
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
