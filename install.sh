#!/usr/bin/env bash
# GitSetu pinned release installer.
#
# This development checkout intentionally has no public v1.1.0 artifact. A
# future release must ship install.sh and release.env together from one verified
# tag. Mutable branch installers and raw main execution are not supported.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEVELOPMENT=0

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

for argument in "$@"; do
    case "$argument" in
        --local-development) LOCAL_DEVELOPMENT=1 ;;
        --help|-h)
            printf 'Usage: install.sh [--local-development]\n'
            printf '  --local-development  build a clean reviewed checkout; never downloads a release\n'
            exit 0
            ;;
        *) error "Unknown option: $argument" ;;
    esac
done

load_release_config() {
    local config="" candidate key value
    for candidate in "$SCRIPT_DIR/release.env" "$SCRIPT_DIR/packaging/release.env"; do
        if [[ -f "$candidate" && ! -L "$candidate" ]]; then
            config="$candidate"
            break
        fi
    done
    [[ -n "$config" ]] || error "Pinned release metadata was not found beside install.sh. Download a versioned release archive; do not pipe a mutable branch script."

    GITSETU_RELEASE_STATE=""
    GITSETU_RELEASE_VERSION=""
    GITSETU_RELEASE_TAG=""
    GITSETU_RELEASE_COMMIT=""
    GITSETU_ARTIFACT_URL=""
    GITSETU_ARTIFACT_SHA256=""
    GITSETU_ARTIFACT_SIZE=""
    GITSETU_SIGNATURE_URL=""
    GITSETU_SIGNATURE_BUNDLE_URL=""
    GITSETU_CERTIFICATE_IDENTITY=""
    GITSETU_CERTIFICATE_OIDC_ISSUER=""
    seen_keys="|"

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            GITSETU_RELEASE_STATE|GITSETU_RELEASE_VERSION|GITSETU_RELEASE_TAG|GITSETU_RELEASE_COMMIT|\
            GITSETU_ARTIFACT_URL|GITSETU_ARTIFACT_SHA256|GITSETU_ARTIFACT_SIZE|GITSETU_SIGNATURE_URL|\
            GITSETU_SIGNATURE_BUNDLE_URL|GITSETU_CERTIFICATE_IDENTITY|GITSETU_CERTIFICATE_OIDC_ISSUER|\
            GITSETU_WINDOWS_ZIP_URL|GITSETU_WINDOWS_ZIP_SHA256|GITSETU_WINDOWS_ZIP_SIZE|\
            GITSETU_WINDOWS_SIGNATURE_URL|GITSETU_WINDOWS_SIGNATURE_BUNDLE_URL) ;;
            *) error "Unexpected key in GitSetu release metadata: $key" ;;
        esac
        if [[ "$value" == *[[:space:]]* || "$value" == *\\* ]]; then
            error "Unsafe value for $key in GitSetu release metadata"
        fi
        case "$seen_keys" in
            *"|$key|"*) error "Duplicate key in GitSetu release metadata: $key" ;;
        esac
        seen_keys="${seen_keys}${key}|"
        case "$key" in
            GITSETU_RELEASE_STATE) GITSETU_RELEASE_STATE="$value" ;;
            GITSETU_RELEASE_VERSION) GITSETU_RELEASE_VERSION="$value" ;;
            GITSETU_RELEASE_TAG) GITSETU_RELEASE_TAG="$value" ;;
            GITSETU_RELEASE_COMMIT) GITSETU_RELEASE_COMMIT="$value" ;;
            GITSETU_ARTIFACT_URL) GITSETU_ARTIFACT_URL="$value" ;;
            GITSETU_ARTIFACT_SHA256) GITSETU_ARTIFACT_SHA256="$value" ;;
            GITSETU_ARTIFACT_SIZE) GITSETU_ARTIFACT_SIZE="$value" ;;
            GITSETU_SIGNATURE_URL) GITSETU_SIGNATURE_URL="$value" ;;
            GITSETU_SIGNATURE_BUNDLE_URL) GITSETU_SIGNATURE_BUNDLE_URL="$value" ;;
            GITSETU_CERTIFICATE_IDENTITY) GITSETU_CERTIFICATE_IDENTITY="$value" ;;
            GITSETU_CERTIFICATE_OIDC_ISSUER) GITSETU_CERTIFICATE_OIDC_ISSUER="$value" ;;
            GITSETU_WINDOWS_*) : ;;
        esac
    done < "$config"

    [[ "$GITSETU_RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Invalid GitSetu release version metadata"
    [[ -n "$GITSETU_CERTIFICATE_OIDC_ISSUER" ]] || error "GitSetu signature issuer metadata is missing"
}

load_release_config

[[ -n "${HOME:-}" && "$HOME" == /* ]] || error "HOME must be set to an absolute path"
[[ "$HOME" != *$'\n'* && "$HOME" != *$'\r'* && "$HOME" != *$'\t'* ]] || error "HOME contains control characters"

if is_test_mode; then
    INSTALL_ROOT="${GITSETU_INSTALL_DIR:-$HOME/.local/share/gitsetu}"
    BIN_DIR="${GITSETU_TEST_BIN_DIR:-$HOME/.local/bin}"
    ARTIFACT_FILE="${GITSETU_TEST_ARTIFACT:-}"
    EXPECTED_SHA256="${GITSETU_TEST_ARTIFACT_SHA256:-}"
else
    DATA_BASE="${XDG_DATA_HOME:-$HOME/.local/share}"
    [[ "$DATA_BASE" == /* ]] || error "XDG_DATA_HOME must be an absolute path"
    INSTALL_ROOT="$DATA_BASE/gitsetu"
    BIN_DIR="$HOME/.local/bin"
    ARTIFACT_FILE=""
    EXPECTED_SHA256=""

    if [[ "$GITSETU_RELEASE_STATE" == "development" ]]; then
        if [[ "$LOCAL_DEVELOPMENT" -eq 1 || ( -e "$SCRIPT_DIR/.git" && -f "$SCRIPT_DIR/gitsetu" && -f "$SCRIPT_DIR/scripts/bundle.sh" ) ]]; then
            LOCAL_DEVELOPMENT=1
        else
            error "GitSetu v${GITSETU_RELEASE_VERSION} is in development. Use --local-development from a clean reviewed checkout; no public artifact exists."
        fi
    elif [[ "$GITSETU_RELEASE_STATE" == "released" ]]; then
        [[ "$LOCAL_DEVELOPMENT" -eq 0 ]] || error "--local-development is valid only while the release state is development"
        [[ "$GITSETU_RELEASE_TAG" == "v${GITSETU_RELEASE_VERSION}" ]] || error "Release tag and version do not match"
        [[ "$GITSETU_RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || error "Release commit pin is missing or invalid"
        [[ "$GITSETU_ARTIFACT_URL" == "https://github.com/bhaskarjha-dev/gitsetu/releases/download/${GITSETU_RELEASE_TAG}/"* ]] || error "Artifact URL is not pinned to the immutable GitSetu release"
        [[ "$GITSETU_SIGNATURE_URL" == "${GITSETU_ARTIFACT_URL%/*}/"* && "$GITSETU_SIGNATURE_BUNDLE_URL" == "${GITSETU_ARTIFACT_URL%/*}/"* ]] || error "Signature URLs are not pinned beside the artifact"
        [[ "$GITSETU_CERTIFICATE_IDENTITY" == https://github.com/bhaskarjha-dev/gitsetu/* ]] || error "Signature certificate identity is outside the GitSetu repository"
        ARTIFACT_FILE="$GITSETU_ARTIFACT_URL"
        EXPECTED_SHA256="$GITSETU_ARTIFACT_SHA256"
        EXPECTED_SIZE="$GITSETU_ARTIFACT_SIZE"
    else
        error "Unsupported GitSetu release state: $GITSETU_RELEASE_STATE"
    fi
fi

[[ "$INSTALL_ROOT" == /* && "$BIN_DIR" == /* ]] || error "Installation paths must be absolute"
[[ "$INSTALL_ROOT" != "/" && "$BIN_DIR" != "/" && "$INSTALL_ROOT" != "$HOME" && "$BIN_DIR" != "$HOME" ]] || error "Refusing a root or home-directory installation target"
[[ "$INSTALL_ROOT" != *$'\n'* && "$INSTALL_ROOT" != *$'\r'* && "$INSTALL_ROOT" != *$'\t'* ]] || error "Installation path contains control characters"
[[ "$BIN_DIR" != *$'\n'* && "$BIN_DIR" != *$'\r'* && "$BIN_DIR" != *$'\t'* ]] || error "Binary path contains control characters"

if [[ "$LOCAL_DEVELOPMENT" -eq 0 ]]; then
    [[ -n "$ARTIFACT_FILE" ]] || error "No verified GitSetu artifact is available"
    [[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || error "A valid SHA-256 artifact pin is required"
    if ! is_test_mode; then
        [[ -n "${EXPECTED_SIZE:-}" ]] || error "An exact artifact byte size is required"
    fi
fi

find_trusted_tool() {
    local name="$1" candidate
    shift
    if is_test_mode && [[ -n "${GITSETU_TEST_TRUSTED_TOOL:-}" ]]; then
        candidate="$GITSETU_TEST_TRUSTED_TOOL"
        if [[ "$candidate" == /* && -x "$candidate" && ! -L "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    for candidate in "$@"; do
        if [[ -x "$candidate" && ! -L "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

HASH_TOOL="$(find_trusted_tool sha256 /usr/bin/sha256sum /bin/sha256sum /usr/bin/shasum /bin/shasum /usr/local/bin/sha256sum)" || error "No trusted SHA-256 implementation was found"
DOWNLOADER=""
COSIGN_TOOL=""
GIT_TOOL=""
if [[ "$LOCAL_DEVELOPMENT" -eq 1 ]]; then
    GIT_TOOL="$(find_trusted_tool git /usr/bin/git /bin/git /mingw64/bin/git /usr/local/bin/git)" || error "A trusted Git executable is required for local-development mode"
elif ! is_test_mode; then
    DOWNLOADER="$(find_trusted_tool downloader /usr/bin/curl /bin/curl /usr/local/bin/curl /usr/bin/wget /bin/wget)" || error "No trusted HTTPS downloader was found"
    COSIGN_TOOL="$(find_trusted_tool cosign /usr/local/bin/cosign /usr/bin/cosign /bin/cosign)" || error "A trusted cosign executable is required"
fi

hash_file() {
    local file="$1" output
    output="$("$HASH_TOOL" "$file" 2>/dev/null)" || return 1
    case "$HASH_TOOL" in
        *sha256sum) printf '%s\n' "${output%% *}" ;;
        *) printf '%s\n' "$(printf '%s\n' "$output" | awk '{print $1}')" ;;
    esac
}

verify_file() {
    local file="$1" expected="$2" actual
    [[ -f "$file" && ! -L "$file" ]] || return 1
    actual="$(hash_file "$file")" || return 1
    [[ "$actual" == "$expected" ]]
}

download_file() {
    local url="$1" output="$2"
    case "$DOWNLOADER" in
        *curl)
            "$DOWNLOADER" --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-redirs 3 --output "$output" "$url"
            ;;
        *wget)
            "$DOWNLOADER" --https-only --secure-protocol=TLSv1_2 --max-redirect=3 --output-document="$output" "$url"
            ;;
    esac
}

# Refuse symlink/reparse-style redirection in every existing path component.
assert_no_symlink_components() {
    local path="$1" current
    current="$path"
    while [[ -n "$current" && "$current" != "/" ]]; do
        [[ ! -L "$current" ]] || error "Symbolic-link path component is not allowed: $current"
        current="$(dirname "$current")"
    done
}

if [[ "$LOCAL_DEVELOPMENT" -eq 1 ]]; then
    checkout_root="$(GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 "$GIT_TOOL" -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || error "--local-development must be run from a Git checkout"
    checkout_root="$(cd -P "$checkout_root" && pwd)"
    [[ "$checkout_root" == "$SCRIPT_DIR" ]] || error "Installer is not at the root of the reviewed Git checkout"
    checkout_status="$(GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 "$GIT_TOOL" -C "$SCRIPT_DIR" status --porcelain=v1 --untracked-files=all)"
    [[ -z "$checkout_status" ]] || error "Local-development installation refuses a dirty Git checkout"
    [[ -f "$SCRIPT_DIR/scripts/bundle.sh" ]] || error "Local-development bundler is missing"
fi

assert_no_symlink_components "$INSTALL_ROOT"
assert_no_symlink_components "$BIN_DIR"
ROOT_PREEXISTED=0
INSTALL_COMPLETE=0
if [[ -e "$INSTALL_ROOT" ]]; then
    ROOT_PREEXISTED=1
    [[ -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || error "Installation root is not a real directory: $INSTALL_ROOT"
    [[ -f "$INSTALL_ROOT/install.marker" && ! -L "$INSTALL_ROOT/install.marker" ]] || error "Refusing to replace an unmarked directory: $INSTALL_ROOT"
    [[ ! -e "$INSTALL_ROOT/.git" ]] || error "Refusing to modify a Git checkout at $INSTALL_ROOT"
fi

mkdir -p "$INSTALL_ROOT/releases" || error "Could not create the versioned installation root"
chmod 700 "$INSTALL_ROOT" "$INSTALL_ROOT/releases" || error "Could not secure the installation root"
mkdir -p "$BIN_DIR" || error "Could not create the executable directory"
chmod 700 "$BIN_DIR" || error "Could not secure the executable directory"

DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-install.XXXXXX")" || error "Could not create a private download directory"
STAGE_DIR=""
cleanup() {
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
    rm -rf -- "$DOWNLOAD_DIR"
    if [[ "$ROOT_PREEXISTED" -eq 0 && "$INSTALL_COMPLETE" -eq 0 && -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]]; then
        rm -rf -- "$INSTALL_ROOT"
    fi
}
trap cleanup EXIT HUP INT TERM

if [[ "$LOCAL_DEVELOPMENT" -eq 1 ]]; then
    "$BASH" "$SCRIPT_DIR/scripts/bundle.sh" "$DOWNLOAD_DIR/gitsetu" >/dev/null || error "Local-development bundle build failed"
    [[ -f "$DOWNLOAD_DIR/gitsetu" && ! -L "$DOWNLOAD_DIR/gitsetu" ]] || error "Local-development bundler did not produce a regular executable"
    EXPECTED_SHA256="$(hash_file "$DOWNLOAD_DIR/gitsetu")" || error "Could not hash the local-development bundle"
    EXPECTED_SIZE="$(wc -c < "$DOWNLOAD_DIR/gitsetu" | tr -d '[:space:]')"
elif is_test_mode; then
    [[ -f "$ARTIFACT_FILE" && ! -L "$ARTIFACT_FILE" ]] || error "Test artifact must be a regular, non-symlink file"
    cp "$ARTIFACT_FILE" "$DOWNLOAD_DIR/gitsetu"
    ACTUAL_SIZE="$(wc -c < "$ARTIFACT_FILE" | tr -d '[:space:]')"
    EXPECTED_SIZE="$ACTUAL_SIZE"
else
    download_file "$GITSETU_ARTIFACT_URL" "$DOWNLOAD_DIR/gitsetu" || error "Pinned GitSetu artifact download failed"
    download_file "$GITSETU_SIGNATURE_URL" "$DOWNLOAD_DIR/gitsetu.sig" || error "Release signature download failed"
    download_file "$GITSETU_SIGNATURE_BUNDLE_URL" "$DOWNLOAD_DIR/gitsetu.sigstore.json" || error "Release signature bundle download failed"
fi

verify_file "$DOWNLOAD_DIR/gitsetu" "$EXPECTED_SHA256" || error "GitSetu artifact SHA-256 verification failed"
ACTUAL_SIZE="$(wc -c < "$DOWNLOAD_DIR/gitsetu" | tr -d '[:space:]')"
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] || error "GitSetu artifact size does not match release metadata"

if [[ "$LOCAL_DEVELOPMENT" -eq 0 ]] && ! is_test_mode; then
    "$COSIGN_TOOL" verify-blob \
        --certificate-identity "$GITSETU_CERTIFICATE_IDENTITY" \
        --certificate-oidc-issuer "$GITSETU_CERTIFICATE_OIDC_ISSUER" \
        --signature "$DOWNLOAD_DIR/gitsetu.sig" \
        --bundle "$DOWNLOAD_DIR/gitsetu.sigstore.json" \
        "$DOWNLOAD_DIR/gitsetu" >/dev/null 2>&1 || error "GitSetu artifact signature verification failed"
fi

version_output="$("$BASH" "$DOWNLOAD_DIR/gitsetu" --version 2>&1)" || error "The verified GitSetu artifact failed its version self-check"
[[ "$version_output" == *"gitsetu v${GITSETU_RELEASE_VERSION}"* ]] || error "Verified artifact version does not match release metadata"

HASH_PREFIX="$(printf '%s' "$EXPECTED_SHA256" | cut -c1-16)"
RELEASE_ID="${GITSETU_RELEASE_VERSION}-${HASH_PREFIX}"
RELEASE_DIR="$INSTALL_ROOT/releases/$RELEASE_ID"
STAGE_DIR="$(mktemp -d "$INSTALL_ROOT/releases/.stage.XXXXXX")" || error "Could not create a private release staging directory"
cp "$DOWNLOAD_DIR/gitsetu" "$STAGE_DIR/gitsetu"
chmod 500 "$STAGE_DIR/gitsetu"
printf 'format=1\nversion=%s\nartifact_sha256=%s\n' "$GITSETU_RELEASE_VERSION" "$EXPECTED_SHA256" > "$STAGE_DIR/release.marker"
chmod 400 "$STAGE_DIR/release.marker"

if [[ -e "$RELEASE_DIR" ]]; then
    [[ -d "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] || error "Versioned release path is not a real directory"
    verify_file "$RELEASE_DIR/gitsetu" "$EXPECTED_SHA256" || error "Existing versioned installation failed integrity verification"
    rm -rf -- "$STAGE_DIR"
    STAGE_DIR=""
else
    mv "$STAGE_DIR" "$RELEASE_DIR" || error "Could not publish the versioned release directory"
    STAGE_DIR=""
fi

if [[ -L "$INSTALL_ROOT/current" ]]; then
    error "Refusing a symbolic-link current pointer"
elif [[ -f "$INSTALL_ROOT/current" ]]; then
    current_pointer=""
    IFS= read -r current_pointer < "$INSTALL_ROOT/current" || error "Could not read the current release pointer"
    [[ "$current_pointer" == releases/* && "$current_pointer" != *"/../"* && "$current_pointer" != *"/.."* ]] || error "Current release pointer is out of root"
fi
POINTER_TMP="$(mktemp "$INSTALL_ROOT/.current.XXXXXX")" || error "Could not create a private pointer file"
printf 'releases/%s\n' "$RELEASE_ID" > "$POINTER_TMP"
chmod 400 "$POINTER_TMP"
mv -f "$POINTER_TMP" "$INSTALL_ROOT/current" || error "Could not atomically switch the current release pointer"

MARKER_TMP="$(mktemp "$INSTALL_ROOT/.install-marker.XXXXXX")" || error "Could not create the installation marker"
printf 'format=1\nversion=%s\nartifact_sha256=%s\nrelease_id=%s\n' \
    "$GITSETU_RELEASE_VERSION" "$EXPECTED_SHA256" "$RELEASE_ID" > "$MARKER_TMP"
chmod 400 "$MARKER_TMP"
mv -f "$MARKER_TMP" "$INSTALL_ROOT/install.marker" || error "Could not publish the installation marker"

install_wrapper() {
    local name="$1"
    local wrapper="$BIN_DIR/$name" wrapper_tmp="" current_target=""
    if [[ -L "$wrapper" ]]; then
        current_target="$(readlink "$wrapper")"
        [[ "$current_target" == "$INSTALL_ROOT/"* ]] || error "Refusing to replace an unrelated symbolic link: $wrapper"
    elif [[ -e "$wrapper" ]]; then
        [[ -f "$wrapper" && ! -L "$wrapper" ]] || error "Refusing to replace a non-file executable: $wrapper"
        grep -q '^# gitsetu-managed-installation v1$' "$wrapper" || error "Refusing to replace an unmanaged executable: $wrapper"
    fi
    wrapper_tmp="$(mktemp "$BIN_DIR/.gitsetu-wrapper.XXXXXX")" || error "Could not create a private executable wrapper"
    {
        printf '%s\n' '#!/usr/bin/env bash' '# gitsetu-managed-installation v1' 'set -euo pipefail'
        printf 'INSTALL_ROOT=%q\n' "$INSTALL_ROOT"
        cat <<'WRAPPER'
if [[ ! -d "$INSTALL_ROOT" || -L "$INSTALL_ROOT" || -L "$INSTALL_ROOT/current" ]]; then
    printf 'Error: GitSetu installation pointer is invalid.\n' >&2
    exit 1
fi
IFS= read -r RELEASE_DIR < "$INSTALL_ROOT/current" || exit 1
case "$RELEASE_DIR" in
    releases/*) ;;
    *) printf 'Error: GitSetu release pointer is out of root.\n' >&2; exit 1 ;;
esac
case "$RELEASE_DIR" in
    *"/../"*|*/..|*"//"*) printf 'Error: GitSetu release pointer is unsafe.\n' >&2; exit 1 ;;
esac
TARGET="$INSTALL_ROOT/$RELEASE_DIR/gitsetu"
[[ -f "$TARGET" && ! -L "$TARGET" ]] || { printf 'Error: GitSetu release artifact is missing.\n' >&2; exit 1; }
exec "$TARGET" "$@"
WRAPPER
    } > "$wrapper_tmp"
    chmod 500 "$wrapper_tmp"
    mv -f "$wrapper_tmp" "$wrapper" || error "Could not publish executable wrapper: $wrapper"
}

install_wrapper gitsetu
install_wrapper git-setu
INSTALL_COMPLETE=1

if [[ "$LOCAL_DEVELOPMENT" -eq 1 ]]; then
    info "GitSetu v${GITSETU_RELEASE_VERSION} local-development build installed at $INSTALL_ROOT"
    info "This build is not a public release and was not downloaded from a remote."
else
    info "GitSetu v${GITSETU_RELEASE_VERSION} installed at $INSTALL_ROOT"
fi
info "Active aliases: gitsetu, git-setu"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) info "Add $BIN_DIR to PATH before running gitsetu." ;;
esac
