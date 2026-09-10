#!/usr/bin/env bash
# scripts/bundle.sh — Compiles GitSetu and all library modules into a standalone single-file binary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"
OUTPUT_FILE="${1:-$DIST_DIR/gitsetu}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Bundling GitSetu standalone monolith..."

BUILD_TIMESTAMP=$(git -C "$REPO_DIR" log -1 --format="%cI" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d")
COMMIT_HASH=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "release")

TEMP_BUNDLE=$(mktemp "${TMPDIR:-/tmp}/gitsetu-bundle.XXXXXX")

# 1. Base entry point (preamble, CRLF self-healing, path resolution, prompt engine)
awk '/# Source all library modules/{exit} {print}' "$REPO_DIR/gitsetu" > "$TEMP_BUNDLE"

# 2. Standalone monolith declaration banner
cat <<EOF >> "$TEMP_BUNDLE"

# ==============================================================================
# GitSetu Standalone Monolith Bundle
# Version: 1.0.0
# Zero-dependency, single-file distribution for direct curl execution.
# https://github.com/bhaskarjha-dev/gitsetu
# ==============================================================================
export GITSETU_STANDALONE=1

EOF

# 3. Topologically ordered library modules
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
)

for mod in "${MODULES[@]}"; do
    mod_path="$REPO_DIR/$mod"
    if [ ! -f "$mod_path" ]; then
        echo "Error: Required library module $mod does not exist!" >&2
        rm -f "$TEMP_BUNDLE"
        exit 1
    fi
    echo "# ------------------------------------------------------------------------------" >> "$TEMP_BUNDLE"
    echo "# Inlined Module: $mod" >> "$TEMP_BUNDLE"
    echo "# ------------------------------------------------------------------------------" >> "$TEMP_BUNDLE"
    # Strip shebang if present on first line
    sed '1{/^#!/d;}' "$mod_path" >> "$TEMP_BUNDLE"
    echo "" >> "$TEMP_BUNDLE"
done

# 4. Trailing entry logic (cleanup handlers, subcommands, argument router, main dispatch)
awk '/# Unified Global Cleanup Architecture/{found=1} found{print}' "$REPO_DIR/gitsetu" >> "$TEMP_BUNDLE"

# 5. Sanitize line endings and apply executable permissions
tr -d '\r' < "$TEMP_BUNDLE" > "$OUTPUT_FILE"
rm -f "$TEMP_BUNDLE"
chmod +x "$OUTPUT_FILE"

BUNDLE_SIZE=$(wc -c < "$OUTPUT_FILE" 2>/dev/null || echo 0)
echo "Successfully bundled: $OUTPUT_FILE ($((BUNDLE_SIZE / 1024)) KB)"
