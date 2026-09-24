#!/usr/bin/env bash
# Build the deterministic standalone GitSetu bundle and its integrity manifest.
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
OUTPUT_FILE="${1:-$REPO_DIR/dist/gitsetu}"
case "$OUTPUT_FILE" in
    /*) ;;
    *) OUTPUT_FILE="$PWD/$OUTPUT_FILE" ;;
esac
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$(cd -P "$OUTPUT_DIR" && pwd)/$(basename "$OUTPUT_FILE")"
MANIFEST_FILE="${2:-$OUTPUT_FILE.manifest.json}"
[[ ! -L "$OUTPUT_FILE" && ! -L "$MANIFEST_FILE" ]] || { printf 'Error: bundle output paths must not be symbolic links.\n' >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
    printf 'Error: Node.js is required only to build and verify release metadata.\n' >&2
    exit 1
fi
node_path() {
    local value="$1"
    if command -v cygpath >/dev/null 2>&1 && [[ "${OSTYPE:-}" == cygwin* || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* ]]; then
        cygpath -w "$value"
    else
        printf '%s\n' "$value"
    fi
}
NODE_RELEASE_JS="$(node_path "$REPO_DIR/packaging/release.js")"
NODE_RELEASE_JSON="$(node_path "$REPO_DIR/packaging/release.json")"
node "$NODE_RELEASE_JS" validate-source >/dev/null
GITSETU_VERSION="$(node -e "const fs=require('fs');const m=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(m.version)" "$NODE_RELEASE_JSON")"
GITSETU_RELEASE_STATE="$(node -e "const fs=require('fs');const m=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(m.release.state)" "$NODE_RELEASE_JSON")"

SOURCE_COMMIT="unavailable"
SOURCE_DIRTY="unavailable"
if command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [[ -z "$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
        SOURCE_DIRTY="clean"
    else
        SOURCE_DIRTY="dirty"
    fi
fi

MODULES=(
    lib/core.sh
    lib/platform.sh
    lib/ui.sh
    lib/validate.sh
    lib/backup.sh
    lib/ssh.sh
    lib/gitconfig.sh
    lib/guard.sh
    lib/doctor.sh
    lib/verify.sh
    lib/teardown.sh
    lib/discovery.sh
    lib/setup.sh
    lib/keychain.sh
    lib/completion.sh
)

for module in "${MODULES[@]}"; do
    [[ -f "$REPO_DIR/$module" ]] || { printf 'Error: required bundle module is missing: %s\n' "$module" >&2; exit 1; }
done

TEMP_BUNDLE="$(mktemp "$OUTPUT_DIR/.gitsetu-bundle.XXXXXX")"
TEMP_MANIFEST="$(mktemp "$OUTPUT_DIR/.gitsetu-manifest.XXXXXX")"
TEMP_CLEAN_BUNDLE=""
cleanup() {
    rm -f -- "$TEMP_BUNDLE" "$TEMP_MANIFEST"
    [[ -z "$TEMP_CLEAN_BUNDLE" ]] || rm -f -- "$TEMP_CLEAN_BUNDLE"
}
trap cleanup EXIT HUP INT TERM

awk '/# Source all library modules/{exit} {print}' "$REPO_DIR/gitsetu" > "$TEMP_BUNDLE"
cat >> "$TEMP_BUNDLE" <<EOF

# ==============================================================================
# GitSetu Standalone Monolith Bundle
# Version: $GITSETU_VERSION
# Release state: $GITSETU_RELEASE_STATE
# Development builds are not public release artifacts.
# Zero-dependency, single-file distribution.
# https://github.com/bhaskarjha-dev/gitsetu
# ==============================================================================
export GITSETU_STANDALONE=1

EOF

module_index=0
for module in "${MODULES[@]}"; do
    module_index=$((module_index + 1))
    module_function="_gitsetu_bundle_module_${module_index}"
    {
        printf '%s\n' '# ------------------------------------------------------------------------------'
        printf '# Inlined Module: %s\n' "$module"
        printf '%s\n' '# ------------------------------------------------------------------------------'
        printf '%s() {\n' "$module_function"
        sed '1{/^#!/d;}' "$REPO_DIR/$module"
        printf '\n}\n%s\nunset -f %s\n\n' "$module_function" "$module_function"
    } >> "$TEMP_BUNDLE"
done

awk '/# Unified Global Cleanup Architecture/{found=1} found{print}' "$REPO_DIR/gitsetu" >> "$TEMP_BUNDLE"

# Normalize generated whitespace so the bundle never carries trailing spaces
# from an inlined module or a CRLF-contaminated working tree.
TEMP_CLEAN_BUNDLE="$(mktemp "$OUTPUT_DIR/.gitsetu-bundle-clean.XXXXXX")"
sed 's/[[:space:]]*$//' "$TEMP_BUNDLE" > "$TEMP_CLEAN_BUNDLE"
mv -f "$TEMP_CLEAN_BUNDLE" "$TEMP_BUNDLE"
TEMP_CLEAN_BUNDLE=""

# The source is required to be LF by .gitattributes. Reject CR corruption rather
# than silently changing bytes during a release build.
if LC_ALL=C grep "$(printf '\r')" "$TEMP_BUNDLE" >/dev/null 2>&1; then
    printf 'Error: bundle source contains CR bytes; normalize tracked source to LF.\n' >&2
    exit 1
fi
chmod 755 "$TEMP_BUNDLE"
"$BASH" -n "$TEMP_BUNDLE"
mv -f "$TEMP_BUNDLE" "$OUTPUT_FILE"

node "$NODE_RELEASE_JS" write-bundle-manifest \
    "$(node_path "$OUTPUT_FILE")" "$(node_path "$TEMP_MANIFEST")" "$SOURCE_COMMIT" "$SOURCE_DIRTY" "${MODULES[@]}" >/dev/null
mv -f "$TEMP_MANIFEST" "$MANIFEST_FILE"
chmod 644 "$MANIFEST_FILE"
node "$NODE_RELEASE_JS" verify-bundle "$(node_path "$OUTPUT_FILE")" "$(node_path "$MANIFEST_FILE")" >/dev/null

BUNDLE_SIZE="$(wc -c < "$OUTPUT_FILE" | tr -d '[:space:]')"
printf 'Successfully bundled: %s (%s bytes)\n' "$OUTPUT_FILE" "$BUNDLE_SIZE"
printf 'Bundle manifest: %s\n' "$MANIFEST_FILE"
