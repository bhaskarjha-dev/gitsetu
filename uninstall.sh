#!/usr/bin/env bash
# GitSetu uninstaller. Recursive deletion is allowed only for an exact,
# marker-verified installation root.
set -euo pipefail
umask 077

error() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf '%s\n' "$1"
}

is_test_mode() {
    [[ "${GITSETU_TEST_MODE:-}" == "1" ]]
}

FORCE=0
TEARDOWN=0
for arg in "$@"; do
    case "$arg" in
        --force|-f|--yes|-y) FORCE=1 ;;
        --teardown) TEARDOWN=1 ;;
        --help|-h)
            printf 'Usage: uninstall.sh [--force] [--teardown]\n'
            printf '  --force      authorize removal in a non-interactive session\n'
            printf '  --teardown   run "gitsetu teardown --deep --force" before removal\n'
            exit 0
            ;;
        *) error "Unknown option: $arg" ;;
    esac
done

[[ -n "${HOME:-}" && "$HOME" == /* ]] || error "HOME must be set to an absolute path"
if is_test_mode; then
    INSTALL_ROOT="${GITSETU_INSTALL_DIR:-$HOME/.local/share/gitsetu}"
    BIN_DIR="${GITSETU_TEST_BIN_DIR:-$HOME/.local/bin}"
else
    DATA_BASE="${XDG_DATA_HOME:-$HOME/.local/share}"
    [[ "$DATA_BASE" == /* ]] || error "XDG_DATA_HOME must be an absolute path"
    INSTALL_ROOT="$DATA_BASE/gitsetu"
    BIN_DIR="$HOME/.local/bin"
fi

[[ "$INSTALL_ROOT" == /* && "$INSTALL_ROOT" != "/" && "$INSTALL_ROOT" != "$HOME" ]] || error "Refusing an unsafe installation root"
[[ "$BIN_DIR" == /* && "$BIN_DIR" != "/" && "$BIN_DIR" != "$HOME" ]] || error "Refusing an unsafe executable directory"
[[ "$INSTALL_ROOT" != *$'\n'* && "$INSTALL_ROOT" != *$'\r'* && "$INSTALL_ROOT" != *$'\t'* ]] || error "Installation path contains control characters"

assert_no_symlink_components() {
    local path="$1" current="$1"
    while [[ -n "$current" && "$current" != "/" ]]; do
        [[ ! -L "$current" ]] || error "Refusing a symbolic-link path component: $current"
        current="$(dirname "$current")"
    done
}

assert_no_symlink_components "$INSTALL_ROOT"
assert_no_symlink_components "$BIN_DIR"

if [[ ! -e "$INSTALL_ROOT" ]]; then
    info "GitSetu is not installed at $INSTALL_ROOT; nothing to remove."
    exit 0
fi

[[ -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || error "Installation root is not a real directory"
MARKER="$INSTALL_ROOT/install.marker"
[[ -f "$MARKER" && ! -L "$MARKER" ]] || error "Refusing to remove an unmarked directory: $INSTALL_ROOT"

MARKER_FORMAT=""
MARKER_VERSION=""
MARKER_SHA256=""
MARKER_RELEASE_ID=""
marker_lines=0
while IFS='=' read -r key value || [[ -n "$key" ]]; do
    marker_lines=$((marker_lines + 1))
    case "$key" in
        format) MARKER_FORMAT="$value" ;;
        version) MARKER_VERSION="$value" ;;
        artifact_sha256) MARKER_SHA256="$value" ;;
        release_id) MARKER_RELEASE_ID="$value" ;;
        *) error "Unexpected installation marker key: $key" ;;
    esac
done < "$MARKER"
[[ "$marker_lines" -eq 4 ]] || error "Installation marker is incomplete"
[[ "$MARKER_FORMAT" == "1" ]] || error "Unsupported installation marker format"
[[ "$MARKER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Installation marker version is invalid"
[[ "$MARKER_SHA256" =~ ^[0-9a-f]{64}$ ]] || error "Installation marker digest is invalid"
[[ "$MARKER_RELEASE_ID" == "${MARKER_VERSION}-${MARKER_SHA256:0:16}" ]] || error "Installation marker release ID is inconsistent"

CURRENT_FILE="$INSTALL_ROOT/current"
[[ -f "$CURRENT_FILE" && ! -L "$CURRENT_FILE" ]] || error "Current release pointer is missing or is a symbolic link"
CURRENT_RELEASE=""
IFS= read -r CURRENT_RELEASE < "$CURRENT_FILE" || error "Could not read the current release pointer"
[[ "$CURRENT_RELEASE" == "releases/$MARKER_RELEASE_ID" ]] || error "Current release pointer does not match the installation marker"
RELEASE_DIR="$INSTALL_ROOT/$CURRENT_RELEASE"
[[ -d "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] || error "Current release directory is missing or redirected"
[[ -f "$RELEASE_DIR/gitsetu" && ! -L "$RELEASE_DIR/gitsetu" ]] || error "Current GitSetu executable is missing or redirected"

info "GitSetu v$MARKER_VERSION is installed at $INSTALL_ROOT"
info "Generated SSH keys and Git identity configuration are preserved by default."
if [[ "$TEARDOWN" -eq 1 ]]; then
    info "Running explicit managed-state teardown..."
    "$RELEASE_DIR/gitsetu" teardown --deep --force || error "Managed-state teardown failed; installation was not removed"
fi

if [[ "$FORCE" -ne 1 ]]; then
    if [[ -t 0 ]]; then
        printf 'Remove the GitSetu executables and versioned installation? [y/N] '
        read -r response || response=""
    elif [[ -r /dev/tty ]]; then
        printf 'Remove the GitSetu executables and versioned installation? [y/N] '
        read -r response < /dev/tty || response=""
    else
        error "Non-interactive uninstall requires --force (or --yes)."
    fi
    [[ "$response" =~ ^[Yy]$ ]] || { info "Uninstallation aborted."; exit 0; }
fi

status=0
remove_managed_wrapper() {
    local wrapper="$BIN_DIR/$1" target=""
    if [[ -L "$wrapper" ]]; then
        target="$(readlink "$wrapper")"
        if [[ "$target" == "$INSTALL_ROOT/"* ]]; then
            rm -f -- "$wrapper" || status=1
        else
            printf 'Error: refusing unrelated symbolic link: %s\n' "$wrapper" >&2
            status=1
        fi
    elif [[ -e "$wrapper" ]]; then
        if [[ -f "$wrapper" && ! -L "$wrapper" ]] && grep -q '^# gitsetu-managed-installation v1$' "$wrapper"; then
            rm -f -- "$wrapper" || status=1
        else
            printf 'Error: refusing unmanaged executable: %s\n' "$wrapper" >&2
            status=1
        fi
    fi
}

remove_managed_wrapper gitsetu
remove_managed_wrapper git-setu
[[ "$status" -eq 0 ]] || error "One or more GitSetu wrappers could not be removed; installation was preserved."

rm -rf -- "$INSTALL_ROOT" || error "Could not completely remove $INSTALL_ROOT"
info "GitSetu was removed successfully."
