#!/usr/bin/env bash
# lib/keychain.sh — exact Git credential storage backends
#
# Credential policy (intentional and fail-closed):
#   * The default backend is native-only. A missing or failing native backend
#     never falls back to an unencrypted file.
#   * The zero-dependency file backend is deliberately opt-in. Select it with
#     GITSETU_CREDENTIAL_BACKEND=file (or =plaintext), or with
#     GITSETU_ALLOW_PLAINTEXT=1 when no backend was selected.
#   * The file backend is plaintext. It is accepted only for minimal/headless
#     installations that deliberately choose that trade-off, emits a warning on
#     every operation, and refuses to use a store that is not mode 0600.
#   * Windows Git Credential Manager is a native backend and is never emulated
#     by the plaintext file backend.
#
# The on-disk/native secret format is gitsetu credential record v2. Every field
# is hex encoded so colons, equals signs, whitespace, and Unicode are preserved
# exactly. v1 colon-delimited records are intentionally not read: there is no
# migration or legacy compatibility path.
#
# Bash 3.2 compatible.

_KEYCHAIN_CREDENTIAL_STORE_HEADER="# gitsetu-credential-store-v2"
GITSETU_CREDENTIAL_STORE_HEADER="$_KEYCHAIN_CREDENTIAL_STORE_HEADER"

_keychain_init_constants() {
    # Restore the private constant after test sandboxes clear GITSETU_* values;
    # never honor a caller-supplied header or permit a legacy format alias.
    GITSETU_CREDENTIAL_STORE_HEADER="$_KEYCHAIN_CREDENTIAL_STORE_HEADER"
}

# ------------------------------------------------------------------------------
# Internal encoding helpers
# ------------------------------------------------------------------------------

# Encode one argument as lowercase hexadecimal without depending on base64 flags,
# whose spelling differs between GNU and macOS.
_keychain_hex_encode() {
    local value="${1-}"
    local encoded=""
    local char ordinal
    local had_lc=0
    local old_lc=""

    if [[ -n "${LC_ALL+x}" ]]; then
        had_lc=1
        old_lc="$LC_ALL"
    fi
    LC_ALL=C

    while [[ -n "$value" ]]; do
        char="${value:0:1}"
        value="${value:1}"
        printf -v ordinal '%d' "'$char"
        printf -v char '%02x' "$ordinal"
        encoded="${encoded}${char}"
    done

    if [[ "$had_lc" -eq 1 ]]; then
        LC_ALL="$old_lc"
    else
        unset LC_ALL
    fi
    KEYCHAIN_HEX_DECODED="$encoded"
}

# Decode into KEYCHAIN_HEX_DECODED. Command substitution is deliberately avoided
# so a trailing byte is not lost by the caller.
_keychain_hex_decode() {
    local encoded="${1-}"
    local decoded=""
    local pair char octal code

    KEYCHAIN_HEX_DECODED=""
    [[ $(( ${#encoded} % 2 )) -eq 0 ]] || return 1
    [[ -z "$encoded" || "$encoded" =~ ^[0-9A-Fa-f]+$ ]] || return 1

    while [[ -n "$encoded" ]]; do
        pair="${encoded:0:2}"
        encoded="${encoded:2}"
        code=$((16#$pair))
        printf -v octal '%03o' "$code"
        printf -v char '\\%s' "$octal"
        decoded="${decoded}${char}"
    done
    printf -v KEYCHAIN_HEX_DECODED '%b' "$decoded"
}

_keychain_print_error() {
    if declare -f print_error >/dev/null 2>&1; then
        print_error "$1"
    else
        printf '  ERROR: %s\n' "$1" >&2
    fi
}

_keychain_print_warning() {
    if declare -f print_warning >/dev/null 2>&1; then
        print_warning "$1"
    else
        printf '  WARNING: %s\n' "$1" >&2
    fi
}

_keychain_reject_multiline() {
    local label="$1"
    local value="$2"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        _keychain_print_error "Credential field '$label' cannot contain CR or LF."
        return 1
    fi
}

# Build a v2 record. A dash represents the empty path because Bash whitespace
# field splitting would otherwise collapse adjacent tabs.
_keychain_build_record() {
    local profile="$1"
    local host="$2"
    local credential_path="$3"
    local username="$4"
    local password="$5"
    local profile_hex host_hex path_hex username_hex password_hex path_field

    _keychain_hex_encode "$profile" || return 1
    profile_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$host" || return 1
    host_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$credential_path" || return 1
    path_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$username" || return 1
    username_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$password" || return 1
    password_hex="$KEYCHAIN_HEX_DECODED"

    if [[ -z "$profile_hex" || -z "$host_hex" || -z "$username_hex" || -z "$password_hex" ]]; then
        _keychain_print_error "Profile, host, username, and password are required."
        return 1
    fi
    path_field="$path_hex"
    [[ -z "$path_field" ]] && path_field="-"

    KEYCHAIN_BUILT_RECORD="v2"$'\t'"${profile_hex}"$'\t'"${host_hex}"$'\t'"${path_field}"$'\t'"${username_hex}"$'\t'"${password_hex}"
}

# Parse a v2 record into KEYCHAIN_RECORD_* globals. A path encoded as '-' is the
# canonical empty path. Any other malformed record is rejected.
_keychain_parse_record() {
    local line="${1-}"
    local magic profile_hex host_hex path_hex username_hex password_hex extra

    KEYCHAIN_RECORD_PROFILE=""
    KEYCHAIN_RECORD_HOST=""
    KEYCHAIN_RECORD_PATH=""
    KEYCHAIN_RECORD_USERNAME=""
    KEYCHAIN_RECORD_PASSWORD=""

    [[ "$line" != *$'\r'* && "$line" != *$'\n'* ]] || return 1
    IFS=$'\t' read -r magic profile_hex host_hex path_hex username_hex password_hex extra <<< "$line"
    [[ "$magic" == "v2" && -n "$profile_hex" && -n "$host_hex" && -n "$username_hex" && -n "$password_hex" && -z "${extra:-}" ]] || return 1
    [[ "$path_hex" == "-" || -n "$path_hex" ]] || return 1

    _keychain_hex_decode "$profile_hex" || return 1
    KEYCHAIN_RECORD_PROFILE="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_decode "$host_hex" || return 1
    KEYCHAIN_RECORD_HOST="$KEYCHAIN_HEX_DECODED"
    if [[ "$path_hex" == "-" ]]; then
        KEYCHAIN_RECORD_PATH=""
    else
        _keychain_hex_decode "$path_hex" || return 1
        KEYCHAIN_RECORD_PATH="$KEYCHAIN_HEX_DECODED"
    fi
    _keychain_hex_decode "$username_hex" || return 1
    KEYCHAIN_RECORD_USERNAME="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_decode "$password_hex" || return 1
    KEYCHAIN_RECORD_PASSWORD="$KEYCHAIN_HEX_DECODED"

    _keychain_reject_multiline "profile" "$KEYCHAIN_RECORD_PROFILE" || return 1
    _keychain_reject_multiline "host" "$KEYCHAIN_RECORD_HOST" || return 1
    _keychain_reject_multiline "path" "$KEYCHAIN_RECORD_PATH" || return 1
    _keychain_reject_multiline "username" "$KEYCHAIN_RECORD_USERNAME" || return 1
    _keychain_reject_multiline "password" "$KEYCHAIN_RECORD_PASSWORD" || return 1
}

_keychain_record_matches() {
    local line="$1"
    local profile="$2"
    local host="$3"
    local credential_path="$4"

    _keychain_parse_record "$line" || return 2
    if [[ "$KEYCHAIN_RECORD_PROFILE" == "$profile" &&
          "$KEYCHAIN_RECORD_HOST" == "$host" &&
          "$KEYCHAIN_RECORD_PATH" == "$credential_path" ]]; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Backend selection
# ------------------------------------------------------------------------------

# Values auto/native mean native-only; they never opt in to plaintext.
_keychain_selected_backend() {
    local requested="${GITSETU_CREDENTIAL_BACKEND:-}"

    if [[ -z "$requested" && "${GITSETU_ALLOW_PLAINTEXT:-0}" == "1" ]]; then
        requested="file"
    fi
    [[ -n "$requested" ]] || requested="native"

    case "$requested" in
        native) printf '%s' "native" ;;
        gcm)     printf '%s' "gcm" ;;
        file|plaintext|zero-dependency) printf '%s' "file" ;;
        *)
            _keychain_print_error "Unsupported GITSETU_CREDENTIAL_BACKEND '$requested' (use native, gcm, or file)."
            return 2
            ;;
    esac
}

# Public diagnostic entry point for scripts/wrappers. The normal CLI keeps
# backend selection in the environment so credential stdin remains untouched.
keychain_print_backend_help() {
    printf '%s\n' \
        'Credential backends:' \
        '  default/native - macOS Keychain, Secret Service, or Windows GCM (preferred; no implicit fallback)' \
        '  GITSETU_CREDENTIAL_BACKEND=file - deliberate zero-dependency plaintext mode (mode 0600 required)' \
        'The file mode is unencrypted and warns on every operation; it is not selected automatically.'
}

_keychain_warn_plaintext() {
    local tokens_file="$1"
    _keychain_print_warning "Using the explicit zero-dependency PLAINTEXT credential fallback: $tokens_file"
    _keychain_print_warning "Credential secrets are not encrypted; use a native keychain/GCM unless this trade-off is intentional."
}

# ------------------------------------------------------------------------------
# Native backends
# ------------------------------------------------------------------------------

_keychain_service_name() {
    local profile="$1"
    local host="$2"
    local credential_path="$3"
    local profile_hex host_hex path_hex

    _keychain_hex_encode "$profile" || return 1
    profile_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$host" || return 1
    host_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$credential_path" || return 1
    path_hex="$KEYCHAIN_HEX_DECODED"
    [[ -n "$path_hex" ]] || path_hex="root"

    KEYCHAIN_SERVICE_NAME="gitsetu:credential:v2:${profile_hex}:${host_hex}:${path_hex}"
}

_keychain_macos_store() {
    local service="$1"
    local record="$2"
    command -v security >/dev/null 2>&1 || {
        _keychain_print_error "macOS Keychain is unavailable. To deliberately choose zero-dependency plaintext, set GITSETU_CREDENTIAL_BACKEND=file; no fallback was attempted."
        return 2
    }
    security add-generic-password -U -a gitsetu -s "$service" -w "$record" >/dev/null 2>&1
}

_keychain_macos_get() {
    local service="$1" status=0
    command -v security >/dev/null 2>&1 || return 2
    security find-generic-password -a gitsetu -s "$service" -w 2>/dev/null || status=$?
    if [[ "$status" -eq 44 ]]; then
        return 1
    fi
    return "$status"
}

_keychain_macos_erase() {
    local service="$1" status=0
    command -v security >/dev/null 2>&1 || return 2
    security find-generic-password -a gitsetu -s "$service" >/dev/null 2>&1 || status=$?
    if [[ "$status" -eq 44 ]]; then
        return 0
    fi
    [[ "$status" -eq 0 ]] || return "$status"
    security delete-generic-password -a gitsetu -s "$service" >/dev/null 2>&1
}

_keychain_linux_store() {
    local profile="$1"
    local host="$2"
    local credential_path="$3"
    local record="$4"
    command -v secret-tool >/dev/null 2>&1 || {
        _keychain_print_error "Secret Service (secret-tool) is unavailable. To deliberately choose zero-dependency plaintext, set GITSETU_CREDENTIAL_BACKEND=file; no fallback was attempted."
        return 2
    }
    printf '%s' "$record" | secret-tool store --label="GitSetu credential v2" \
        gitsetu v2 profile "$profile" host "$host" path "$credential_path" >/dev/null 2>&1
}

_keychain_linux_get() {
    local profile="$1"
    local host="$2"
    local credential_path="$3"
    command -v secret-tool >/dev/null 2>&1 || return 2
    secret-tool lookup gitsetu v2 profile "$profile" host "$host" path "$credential_path" 2>/dev/null
}

_keychain_linux_erase() {
    local profile="$1"
    local host="$2"
    local credential_path="$3"
    command -v secret-tool >/dev/null 2>&1 || return 2
    secret-tool clear gitsetu v2 profile "$profile" host "$host" path "$credential_path" >/dev/null 2>&1
}

# GCM has no portable arbitrary-service flag, so the broker gives it a dedicated
# native target per profile and stores the same v2 record as its secret. This is
# still DPAPI/Windows Credential Manager storage, never a plaintext substitute.
_keychain_gcm_command() {
    KEYCHAIN_GCM_COMMAND=()
    if command -v git-credential-manager >/dev/null 2>&1; then
        KEYCHAIN_GCM_COMMAND=(git-credential-manager)
        return 0
    fi
    if command -v git-credential-manager-core >/dev/null 2>&1; then
        KEYCHAIN_GCM_COMMAND=(git-credential-manager-core)
        return 0
    fi
    return 1
}

_keychain_gcm_target() {
    local profile="$1" host="$2" credential_path="$3"
    local profile_hex host_hex path_hex
    _keychain_hex_encode "$profile" || return 1
    profile_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$host" || return 1
    host_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$credential_path" || return 1
    path_hex="$KEYCHAIN_HEX_DECODED"
    [[ -n "$path_hex" ]] || path_hex="root"
    KEYCHAIN_GCM_HOST="gitsetu-${profile_hex}.invalid"
    KEYCHAIN_GCM_USERNAME="credential-v2-${host_hex}-${path_hex}"
}

_keychain_gcm_store() {
    local profile="$1" host="$2" credential_path="$3" record="$4"
    _keychain_gcm_command || {
        _keychain_print_error "Git Credential Manager is unavailable. To deliberately choose zero-dependency plaintext, set GITSETU_CREDENTIAL_BACKEND=file; no fallback was attempted."
        return 2
    }
    _keychain_gcm_target "$profile" "$host" "$credential_path" || return 1
    printf 'protocol=https\nhost=%s\nusername=%s\npassword=%s\n\n' \
        "$KEYCHAIN_GCM_HOST" "$KEYCHAIN_GCM_USERNAME" "$record" |
        GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never "${KEYCHAIN_GCM_COMMAND[@]}" store >/dev/null 2>&1
}

_keychain_gcm_get() {
    local profile="$1" host="$2" credential_path="$3"
    local output="" line password=""
    _keychain_gcm_command || return 2
    _keychain_gcm_target "$profile" "$host" "$credential_path" || return 1
    output=$(printf 'protocol=https\nhost=%s\nusername=%s\n\n' \
        "$KEYCHAIN_GCM_HOST" "$KEYCHAIN_GCM_USERNAME" |
        GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never "${KEYCHAIN_GCM_COMMAND[@]}" get 2>/dev/null) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            password=*) password="${line#password=}" ;;
        esac
    done <<< "$output"
    [[ -n "$password" ]] || return 1
    printf '%s' "$password"
}

_keychain_gcm_erase() {
    local profile="$1" host="$2" credential_path="$3"
    _keychain_gcm_command || return 2
    _keychain_gcm_target "$profile" "$host" "$credential_path" || return 1
    printf 'protocol=https\nhost=%s\nusername=%s\n\n' \
        "$KEYCHAIN_GCM_HOST" "$KEYCHAIN_GCM_USERNAME" |
        GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never "${KEYCHAIN_GCM_COMMAND[@]}" erase >/dev/null 2>&1
}

# The OS name is supplied by the caller-selected platform detector.
# shellcheck disable=SC2195
_keychain_native_store() {
    local backend="$1" profile="$2" host="$3" credential_path="$4" record="$5" service
    if [[ "$backend" == "gcm" ]]; then
        _keychain_gcm_store "$profile" "$host" "$credential_path" "$record"
        return $?
    fi
    case "${GITSETU_OS:-unknown}" in
        macos)
            _keychain_service_name "$profile" "$host" "$credential_path" || return 1
            service="$KEYCHAIN_SERVICE_NAME"
            _keychain_macos_store "$service" "$record"
            ;;
        linux|wsl)
            _keychain_linux_store "$profile" "$host" "$credential_path" "$record"
            ;;
        gitbash)
            _keychain_gcm_store "$profile" "$host" "$credential_path" "$record"
            ;;
        *)
            _keychain_print_error "No native credential backend is available for GITSETU_OS='${GITSETU_OS:-unknown}'. To deliberately choose zero-dependency plaintext, set GITSETU_CREDENTIAL_BACKEND=file; no fallback was attempted."
            return 2
            ;;
    esac
}

# shellcheck disable=SC2195
_keychain_native_get() {
    local backend="$1" profile="$2" host="$3" credential_path="$4" service
    if [[ "$backend" == "gcm" ]]; then
        _keychain_gcm_get "$profile" "$host" "$credential_path"
        return $?
    fi
    case "${GITSETU_OS:-unknown}" in
        macos)
            _keychain_service_name "$profile" "$host" "$credential_path" || return 1
            service="$KEYCHAIN_SERVICE_NAME"
            _keychain_macos_get "$service"
            ;;
        linux|wsl)
            _keychain_linux_get "$profile" "$host" "$credential_path"
            ;;
        gitbash)
            _keychain_gcm_get "$profile" "$host" "$credential_path"
            ;;
        *)
            return 2
            ;;
    esac
}

# shellcheck disable=SC2195
_keychain_native_erase() {
    local backend="$1" profile="$2" host="$3" credential_path="$4" service
    if [[ "$backend" == "gcm" ]]; then
        _keychain_gcm_erase "$profile" "$host" "$credential_path"
        return $?
    fi
    case "${GITSETU_OS:-unknown}" in
        macos)
            _keychain_service_name "$profile" "$host" "$credential_path" || return 1
            service="$KEYCHAIN_SERVICE_NAME"
            _keychain_macos_erase "$service"
            ;;
        linux|wsl)
            _keychain_linux_erase "$profile" "$host" "$credential_path"
            ;;
        gitbash)
            _keychain_gcm_erase "$profile" "$host" "$credential_path"
            ;;
        *)
            return 2
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Explicit zero-dependency plaintext backend
# ------------------------------------------------------------------------------

_keychain_is_ntfs() {
    [[ "${GITSETU_OS:-}" == "gitbash" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ]]
}

_keychain_ntfs_acl_command() {
    if command -v icacls.exe >/dev/null 2>&1; then
        printf '%s' "icacls.exe"
    elif command -v icacls >/dev/null 2>&1; then
        printf '%s' "icacls"
    else
        return 1
    fi
}

_keychain_ntfs_warn_once() {
    if [[ "${KEYCHAIN_NTFS_WARNING_EMITTED:-0}" != "1" ]]; then
        _keychain_print_warning "Git Bash/NTFS does not expose POSIX mode bits; relying on verified current-user ownership and inherited Windows ACL semantics (no plaintext mode relaxation on POSIX)."
        KEYCHAIN_NTFS_WARNING_EMITTED=1
    fi
}

# Verify the strongest ownership/ACL evidence available without treating an
# NTFS mode-bit approximation as a POSIX permission check.
_keychain_ntfs_private_semantics() {
    local path="$1" owner="" current_user owner_uid="" current_uid acl_cmd=""
    local acl_path="$path"
    if _keychain_ntfs_acl_command >/dev/null 2>&1; then
        acl_cmd=$(_keychain_ntfs_acl_command) || return 1
        if _keychain_is_ntfs && command -v cygpath >/dev/null 2>&1; then
            acl_path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
        fi
        "$acl_cmd" "$acl_path" >/dev/null 2>&1 || return 1
    fi
    owner=$(stat -c '%U' "$path" 2>/dev/null) || owner=$(stat -f '%Su' "$path" 2>/dev/null) || owner=""
    current_user=$(id -un 2>/dev/null || true)
    [[ -n "$current_user" ]] || current_user=${USER:-}
    if [[ -n "$owner" && -n "$current_user" && "$owner" != "$current_user" ]]; then
        return 1
    fi
    owner_uid=$(stat -c '%u' "$path" 2>/dev/null) || owner_uid=""
    current_uid=$(id -u 2>/dev/null || true)
    if [[ -n "$owner_uid" && -n "$current_uid" && "$owner_uid" != "$current_uid" ]]; then
        return 1
    fi
    # An unavailable ACL utility is an explicit platform limitation, not a
    # reason to claim POSIX 0600/0700 semantics. Callers may require evidence.
    if [[ "${GITSETU_REQUIRE_NTFS_ACL:-0}" == "1" && -z "$owner" && -z "$owner_uid" && -z "$acl_cmd" ]]; then
        return 1
    fi
    _keychain_ntfs_warn_once
    return 0
}

_keychain_apply_private_mode() {
    local path="$1" mode="$2"
    if _keychain_is_ntfs; then
        chmod "$mode" "$path" 2>/dev/null || true
        _keychain_ntfs_private_semantics "$path"
    else
        chmod "$mode" "$path" 2>/dev/null
    fi
}

_keychain_file_mode() {
    local path="$1" mode=""
    mode=$(stat -c '%a' "$path" 2>/dev/null) || mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1
    printf '%s' "$((8#$mode))"
}

_keychain_is_reparse_point() {
    local path="$1" windows_path
    [[ -L "$path" ]] && return 0
    if [[ "${GITSETU_OS:-}" == "gitbash" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ]] && command -v cygpath >/dev/null 2>&1 && command -v fsutil.exe >/dev/null 2>&1; then
        windows_path=$(cygpath -w "$path" 2>/dev/null) || return 1
        fsutil.exe reparsepoint query "$windows_path" >/dev/null 2>&1 && return 0
    fi
    return 1
}

_keychain_assert_no_symlink_components() {
    local path="${1%/}" rest current component
    [[ -n "$path" ]] || return 1
    case "$path" in
        [A-Za-z]:/*) current="${path%%:*}/"; rest="${path#?:}" ;;
        /*) current="/"; rest="${path#/}" ;;
        *) path="$PWD/$path"; current="/"; rest="${path#/}" ;;
    esac
    while [[ -n "$rest" ]]; do
        component="${rest%%/*}"
        if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
        [[ -n "$component" ]] || continue
        [[ "$component" != "." && "$component" != ".." ]] || return 1
        if [[ "$current" == "/" ]]; then current="/$component"; else current="${current%/}/$component"; fi
        _keychain_is_reparse_point "$current" && return 1
        [[ ! -e "$current" || -d "$current" ]] || return 1
    done
    return 0
}

_keychain_assert_private_directory() {
    local path="$1" mode owner current_user
    _keychain_assert_no_symlink_components "$path" || return 1
    [[ -d "$path" ]] || return 1
    if _keychain_is_ntfs; then
        _keychain_ntfs_private_semantics "$path" || return 1
        return 0
    fi
    mode=$(_keychain_file_mode "$path") || return 1
    [[ "$mode" == "448" ]] || return 1
    owner=$(stat -c '%U' "$path" 2>/dev/null) || owner=$(stat -f '%Su' "$path" 2>/dev/null) || return 1
    current_user=$(id -un 2>/dev/null || true)
    [[ -n "$current_user" ]] || current_user=${USER:-}
    [[ -n "$current_user" && "$owner" == "$current_user" ]]
}

_keychain_assert_private_file() {
    local path="$1" mode=""
    if _keychain_is_reparse_point "$path"; then
        _keychain_print_error "Refusing redirected plaintext credential store: $path"
        return 1
    fi
    [[ -f "$path" ]] || return 1
    if _keychain_is_ntfs; then
        _keychain_ntfs_private_semantics "$path" || {
            _keychain_print_error "Cannot verify NTFS ownership/ACL semantics for plaintext credential store: $path"
            return 1
        }
        return 0
    fi
    mode=$(_keychain_file_mode "$path") || {
        _keychain_print_error "Cannot verify private permissions on plaintext credential store: $path"
        return 1
    }
    if [[ "$mode" != "384" ]]; then
        _keychain_print_error "Refusing plaintext credential store without mode 0600: $path (found $(printf '%03o' "$mode"))"
        return 1
    fi
    local owner current_user
    owner=$(stat -c '%U' "$path" 2>/dev/null) || owner=$(stat -f '%Su' "$path" 2>/dev/null) || {
        _keychain_print_error "Cannot verify ownership of plaintext credential store: $path"
        return 1
    }
    current_user=$(id -un 2>/dev/null || true)
    [[ -n "$current_user" ]] || current_user=${USER:-}
    if [[ -z "$current_user" || "$owner" != "$current_user" ]]; then
        _keychain_print_error "Refusing plaintext credential store not owned by this user: $path"
        return 1
    fi
}

_keychain_prepare_plaintext_dir() {
    local tokens_dir="${GITSETU_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu}"
    _keychain_assert_no_symlink_components "$tokens_dir" || {
        _keychain_print_error "Refusing plaintext credential path with a symlink/reparse component: $tokens_dir"
        return 1
    }
    if [[ ! -d "$tokens_dir" ]]; then
        (umask 077 && mkdir -p "$tokens_dir") || {
            _keychain_print_error "Cannot create private credential directory: $tokens_dir"
            return 1
        }
    fi
    if [[ ! -d "$tokens_dir" ]] || _keychain_is_reparse_point "$tokens_dir"; then
        _keychain_print_error "Credential path is not a private regular directory: $tokens_dir"
        return 1
    fi
    _keychain_apply_private_mode "$tokens_dir" 700 || {
        _keychain_print_error "Cannot enforce private semantics on credential directory: $tokens_dir"
        return 1
    }
    _keychain_assert_private_directory "$tokens_dir" || {
        _keychain_print_error "Refusing plaintext credential fallback without private ownership/mode on directory: $tokens_dir"
        return 1
    }
    KEYCHAIN_TOKENS_FILE="$tokens_dir/.tokens"
}

_keychain_validate_plaintext_store() {
    _keychain_init_constants
    local path="$1"
    local line first=1 found_header=0

    _keychain_assert_private_file "$path" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first" -eq 1 ]]; then
            [[ "$line" == "$GITSETU_CREDENTIAL_STORE_HEADER" ]] || {
                _keychain_print_error "Unrecognized plaintext credential store header; legacy records are not supported: $path"
                return 1
            }
            found_header=1
            first=0
            continue
        fi
        [[ -z "$line" ]] && continue
        _keychain_parse_record "$line" || {
            _keychain_print_error "Malformed v2 credential record in $path"
            return 1
        }
    done < "$path"
    [[ "$first" -eq 0 && "$found_header" -eq 1 ]]
}

_keychain_new_plaintext_temp() {
    local tokens_file="$1"
    KEYCHAIN_TOKENS_TMP=$(umask 077; mktemp "${tokens_file}.tmp.XXXXXX" 2>/dev/null) || return 1
    _keychain_apply_private_mode "$KEYCHAIN_TOKENS_TMP" 600 || {
        rm -f "$KEYCHAIN_TOKENS_TMP"
        return 1
    }
    if [[ -n "${GITSETU_CLEANUP_FILES+x}" ]]; then
        GITSETU_CLEANUP_FILES+=("$KEYCHAIN_TOKENS_TMP")
    fi
}

_keychain_plaintext_store() {
    _keychain_init_constants
    local profile="$1" host="$2" credential_path="$3" record="$4"
    local line match_status wrote_match=0

    _keychain_prepare_plaintext_dir || return 1
    _keychain_warn_plaintext "$KEYCHAIN_TOKENS_FILE"
    if [[ -e "$KEYCHAIN_TOKENS_FILE" || -L "$KEYCHAIN_TOKENS_FILE" ]]; then
        _keychain_validate_plaintext_store "$KEYCHAIN_TOKENS_FILE" || return 1
    fi
    _keychain_new_plaintext_temp "$KEYCHAIN_TOKENS_FILE" || {
        _keychain_print_error "Cannot create a private temporary credential store."
        return 1
    }

    printf '%s\n' "$GITSETU_CREDENTIAL_STORE_HEADER" > "$KEYCHAIN_TOKENS_TMP"
    if [[ -f "$KEYCHAIN_TOKENS_FILE" && ! -L "$KEYCHAIN_TOKENS_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "$GITSETU_CREDENTIAL_STORE_HEADER" ]] && continue
            [[ -z "$line" ]] && continue
            if _keychain_record_matches "$line" "$profile" "$host" "$credential_path"; then
                match_status=0
            else
                match_status=$?
            fi
            if [[ "$match_status" -eq 0 ]]; then
                [[ "$wrote_match" -eq 0 ]] || {
                    _keychain_print_error "Duplicate exact credential records found; refusing ambiguous overwrite."
                    rm -f "$KEYCHAIN_TOKENS_TMP"
                    return 1
                }
                wrote_match=1
                continue
            elif [[ "$match_status" -eq 2 ]]; then
                _keychain_print_error "Malformed v2 credential record; refusing overwrite."
                rm -f "$KEYCHAIN_TOKENS_TMP"
                return 1
            fi
            printf '%s\n' "$line" >> "$KEYCHAIN_TOKENS_TMP"
        done < "$KEYCHAIN_TOKENS_FILE"
    fi
    printf '%s\n' "$record" >> "$KEYCHAIN_TOKENS_TMP"
    _keychain_assert_private_file "$KEYCHAIN_TOKENS_TMP" || {
        rm -f "$KEYCHAIN_TOKENS_TMP"
        return 1
    }
    mv -f "$KEYCHAIN_TOKENS_TMP" "$KEYCHAIN_TOKENS_FILE" || return 1
    _keychain_apply_private_mode "$KEYCHAIN_TOKENS_FILE" 600 || return 1
    return 0
}

_keychain_plaintext_get() {
    _keychain_init_constants
    local profile="$1" host="$2" credential_path="$3"
    local line match_status matches=0

    _keychain_prepare_plaintext_dir || return 1
    _keychain_warn_plaintext "$KEYCHAIN_TOKENS_FILE"
    [[ -f "$KEYCHAIN_TOKENS_FILE" ]] || return 1
    _keychain_validate_plaintext_store "$KEYCHAIN_TOKENS_FILE" || return 2
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$GITSETU_CREDENTIAL_STORE_HEADER" || -z "$line" ]] && continue
        if _keychain_record_matches "$line" "$profile" "$host" "$credential_path"; then
            match_status=0
        else
            match_status=$?
        fi
        if [[ "$match_status" -eq 0 ]]; then
            [[ "$matches" -eq 0 ]] || {
                _keychain_print_error "Duplicate exact credential records found; refusing ambiguous lookup."
                return 2
            }
            matches=1
            KEYCHAIN_FOUND_USERNAME="$KEYCHAIN_RECORD_USERNAME"
            KEYCHAIN_FOUND_PASSWORD="$KEYCHAIN_RECORD_PASSWORD"
        elif [[ "$match_status" -eq 2 ]]; then
            _keychain_print_error "Malformed v2 credential record; refusing lookup."
            return 2
        fi
    done < "$KEYCHAIN_TOKENS_FILE"
    [[ "$matches" -eq 1 ]] || return 1
    printf 'username=%s\npassword=%s\n' "$KEYCHAIN_FOUND_USERNAME" "$KEYCHAIN_FOUND_PASSWORD"
}

_keychain_plaintext_erase() {
    _keychain_init_constants
    local profile="$1" host="$2" credential_path="$3"
    local line match_status matches=0

    _keychain_prepare_plaintext_dir || return 1
    _keychain_warn_plaintext "$KEYCHAIN_TOKENS_FILE"
    [[ -e "$KEYCHAIN_TOKENS_FILE" || -L "$KEYCHAIN_TOKENS_FILE" ]] || return 0
    _keychain_validate_plaintext_store "$KEYCHAIN_TOKENS_FILE" || return 1
    _keychain_new_plaintext_temp "$KEYCHAIN_TOKENS_FILE" || return 1
    printf '%s\n' "$GITSETU_CREDENTIAL_STORE_HEADER" > "$KEYCHAIN_TOKENS_TMP"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$GITSETU_CREDENTIAL_STORE_HEADER" || -z "$line" ]] && continue
        if _keychain_record_matches "$line" "$profile" "$host" "$credential_path"; then
            match_status=0
        else
            match_status=$?
        fi
        if [[ "$match_status" -eq 0 ]]; then
            [[ "$matches" -eq 0 ]] || {
                _keychain_print_error "Duplicate exact credential records found; refusing ambiguous erase."
                rm -f "$KEYCHAIN_TOKENS_TMP"
                return 1
            }
            matches=1
            continue
        elif [[ "$match_status" -eq 2 ]]; then
            _keychain_print_error "Malformed v2 credential record; refusing erase."
            rm -f "$KEYCHAIN_TOKENS_TMP"
            return 1
        fi
        printf '%s\n' "$line" >> "$KEYCHAIN_TOKENS_TMP"
    done < "$KEYCHAIN_TOKENS_FILE"
    _keychain_assert_private_file "$KEYCHAIN_TOKENS_TMP" || {
        rm -f "$KEYCHAIN_TOKENS_TMP"
        return 1
    }
    mv -f "$KEYCHAIN_TOKENS_TMP" "$KEYCHAIN_TOKENS_FILE" || return 1
    _keychain_apply_private_mode "$KEYCHAIN_TOKENS_FILE" 600 || return 1
    return 0
}

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

# Store an exact credential. Optional fifth argument is the URL path used by the
# Git credential protocol; the empty path is distinct from / or /org/repo.
keychain_store() {
    local profile="${1-}" host="${2-}" username="${3-}" password="${4-}"
    local credential_path="${5-${GITSETU_CREDENTIAL_PATH:-}}"
    local backend record

    _keychain_reject_multiline "profile" "$profile" || return 1
    _keychain_reject_multiline "host" "$host" || return 1
    _keychain_reject_multiline "username" "$username" || return 1
    _keychain_reject_multiline "password" "$password" || return 1
    _keychain_reject_multiline "path" "$credential_path" || return 1

    backend=$(_keychain_selected_backend) || return $?
    _keychain_build_record "$profile" "$host" "$credential_path" "$username" "$password" || return 1
    record="$KEYCHAIN_BUILT_RECORD"

    case "$backend" in
        file) _keychain_plaintext_store "$profile" "$host" "$credential_path" "$record" ;;
        *)   _keychain_native_store "$backend" "$profile" "$host" "$credential_path" "$record" ;;
    esac
}

# Retrieve one exact profile/protocol-host/path tuple. Duplicate records are
# rejected rather than resolved by store order.
keychain_get() {
    local profile="${1-}" host="${2-}"
    local credential_path="${3-${GITSETU_CREDENTIAL_PATH:-}}"
    local backend record match_status

    _keychain_reject_multiline "profile" "$profile" || return 1
    _keychain_reject_multiline "host" "$host" || return 1
    _keychain_reject_multiline "path" "$credential_path" || return 1

    backend=$(_keychain_selected_backend) || return $?
    case "$backend" in
        file) _keychain_plaintext_get "$profile" "$host" "$credential_path" ;;
        *)
            local native_status=0
            record=$(_keychain_native_get "$backend" "$profile" "$host" "$credential_path") || native_status=$?
            if [[ "$native_status" -eq 2 ]]; then
                _keychain_print_error "Native credential backend is unavailable. Set GITSETU_CREDENTIAL_BACKEND=file only to deliberately select the warned zero-dependency plaintext mode."
                return 2
            elif [[ "$native_status" -ne 0 ]]; then
                return "$native_status"
            fi
            [[ -n "$record" ]] || return 1
            if _keychain_record_matches "$record" "$profile" "$host" "$credential_path"; then
                match_status=0
            else
                match_status=$?
            fi
            if [[ "$match_status" -ne 0 ]]; then
                _keychain_print_error "Native backend returned a malformed or mismatched credential record."
                return 2
            fi
            printf 'username=%s\npassword=%s\n' "$KEYCHAIN_RECORD_USERNAME" "$KEYCHAIN_RECORD_PASSWORD"
            ;;
    esac
}

# Erase one exact tuple. Missing native/file records are already erased.
keychain_erase() {
    local profile="${1-}" host="${2-}"
    local credential_path="${3-${GITSETU_CREDENTIAL_PATH:-}}"
    local backend

    _keychain_reject_multiline "profile" "$profile" || return 1
    _keychain_reject_multiline "host" "$host" || return 1
    _keychain_reject_multiline "path" "$credential_path" || return 1

    backend=$(_keychain_selected_backend) || return $?
    case "$backend" in
        file) _keychain_plaintext_erase "$profile" "$host" "$credential_path" ;;
        *)   _keychain_native_erase "$backend" "$profile" "$host" "$credential_path" ;;
    esac
}
