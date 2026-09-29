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

# Setup asks for a provider credential before Git supplies a repository path.
# Keep that record in a reserved, canonical tuple scope instead of overloading
# the empty URL path.  The credential broker tries an exact Git path first and
# consults this scope only as a profile-and-host-isolated compatibility fallback.
_KEYCHAIN_SETUP_PAT_SCOPE="gitsetu:setup-pat:v1"

keychain_setup_pat_scope() {
    printf '%s' "$_KEYCHAIN_SETUP_PAT_SCOPE"
}

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

    # Byte-exact, and independent of bash's printf. Walking the value one
    # character at a time and converting each with printf '%d' is broken on
    # bash 3.2 for any byte >= 0x80: the value comes back as a 64-bit integer,
    # so "%02x" -- a minimum width, not a maximum -- emits the full sixteen hex
    # digits of that integer and the stored credential is corrupted rather than
    # rejected. This is reachable, not theoretical: repository paths are allowed
    # to contain UTF-8, and credential_path is one of the encoded fields. od
    # reads the bytes directly and yields exactly two hex digits per byte on
    # every supported bash, which is the same byte-exact approach the registry
    # escaper uses.
    if [[ -z "$value" ]]; then
        KEYCHAIN_HEX_DECODED=""
        return 0
    fi

    local encoded
    encoded=$(printf '%s' "$value" | od -A n -v -t x1 2>/dev/null | tr -d ' \r\n') || encoded=""
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

_KEYCHAIN_NTFS_IDENTITY_INITIALIZED=0
_KEYCHAIN_NTFS_CURRENT_USER=""
_KEYCHAIN_NTFS_CURRENT_ACCOUNT=""
_KEYCHAIN_NTFS_CURRENT_SID=""
_KEYCHAIN_NTFS_CURRENT_UID=""
_KEYCHAIN_NTFS_CURRENT_COMPUTER=""

_keychain_ntfs_initialize_identity() {
    local whoami_cmd="" current_account="" current_sid="" current_computer=""
    [[ "${KEYCHAIN_NTFS_IDENTITY_INITIALIZED:-0}" -eq 1 ]] && return 0

    KEYCHAIN_NTFS_CURRENT_USER=$(id -un 2>/dev/null || true)
    [[ -n "$KEYCHAIN_NTFS_CURRENT_USER" ]] || KEYCHAIN_NTFS_CURRENT_USER=${USER:-}
    KEYCHAIN_NTFS_CURRENT_UID=$(id -u 2>/dev/null || true)
    if command -v hostname >/dev/null 2>&1; then
        current_computer=$(hostname 2>/dev/null | head -n 1) || current_computer=""
        current_computer="${current_computer%$'\r'}"
    fi
    if command -v whoami.exe >/dev/null 2>&1; then
        whoami_cmd="whoami.exe"
    elif command -v whoami >/dev/null 2>&1; then
        whoami_cmd="whoami"
    fi
    if [[ -n "$whoami_cmd" ]]; then
        current_account=$("$whoami_cmd" 2>/dev/null | head -n 1) || current_account=""
        current_account="${current_account%$'\r'}"
        if command -v whoami.exe >/dev/null 2>&1; then
            current_sid=$(whoami.exe /user /fo csv /nh 2>/dev/null |
                sed -n 's/.*"\(S-[0-9][0-9-]*\)".*/\1/p' | head -n 1) || current_sid=""
        fi
    fi
    KEYCHAIN_NTFS_CURRENT_ACCOUNT="$current_account"
    KEYCHAIN_NTFS_CURRENT_SID="$current_sid"
    KEYCHAIN_NTFS_CURRENT_COMPUTER="$current_computer"
    KEYCHAIN_NTFS_IDENTITY_INITIALIZED=1
    [[ -n "$KEYCHAIN_NTFS_CURRENT_USER" ]]
}

_keychain_ntfs_warn_once() {
    if [[ "${KEYCHAIN_NTFS_WARNING_EMITTED:-0}" != "1" ]]; then
        _keychain_print_warning "Git Bash/NTFS does not expose POSIX mode bits; using verified current-user ownership and a restrictive Windows DACL (no plaintext mode relaxation on POSIX)."
        KEYCHAIN_NTFS_WARNING_EMITTED=1
    fi
}

_keychain_ntfs_lower() {
    if declare -F _gitsetu_lower >/dev/null 2>&1; then
        _gitsetu_lower "$1"
    else
        printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
    fi
}

_keychain_ntfs_principal_is_current_user() {
    local principal="${1-}"
    local current_sid="${KEYCHAIN_NTFS_CURRENT_SID:-}"
    local current_account="${KEYCHAIN_NTFS_CURRENT_ACCOUNT:-}"
    local current_user="${KEYCHAIN_NTFS_CURRENT_USER:-}"
    local current_computer="${KEYCHAIN_NTFS_CURRENT_COMPUTER:-}"
    local normalized principal_normalized

    principal_normalized=$(_keychain_ntfs_lower "$principal")
    if [[ -n "$current_sid" ]]; then
        current_sid=$(_keychain_ntfs_lower "$current_sid")
        [[ "$principal_normalized" != "$current_sid" ]] || return 0
    fi
    if [[ -n "$current_account" ]]; then
        current_account=$(_keychain_ntfs_lower "$current_account")
        [[ "$principal_normalized" != "$current_account" ]] || return 0
    fi
    normalized=$(_keychain_ntfs_lower "$current_user")
    if [[ -n "$normalized" && "$principal_normalized" == "$normalized" ]]; then
        return 0
    fi
    if [[ -n "$current_computer" && -n "$normalized" ]]; then
        current_computer=$(_keychain_ntfs_lower "$current_computer")
        [[ "$principal_normalized" == "${current_computer}\\${normalized}" ]]
    else
        return 1
    fi
}

# Parse icacls' human-readable DACL.  It is not sufficient for the command to
# exit successfully: empty/unknown output and ACEs for broad or untrusted
# principals are rejected.  Known SYSTEM/Administrators ACEs are accepted only
# in addition to an explicit full-control ACE for the current account.
_keychain_ntfs_acl_is_restrictive() {
    local acl_output="${1-}"
    local current_user="${KEYCHAIN_NTFS_CURRENT_USER:-}"
    local line trimmed principal rights normalized
    local ace_count=0 current_full_control=0
    local first_line=1

    [[ -n "$current_user" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -n "$trimmed" ]] || continue
        case "$trimmed" in
            'Successfully processed '*|'Successfully processed'*) continue ;;
        esac
        [[ "$trimmed" == *:* ]] || {
            [[ "$first_line" -eq 1 ]] || return 1
            first_line=0
            continue
        }
        # icacls commonly prefixes the first ACE with the inspected path:
        #   C:\\path BUILTIN\\Administrators:(F)
        principal="${trimmed%:*}"
        rights="${trimmed##*:}"
        if [[ "$rights" != \(*\)* ]]; then
            [[ "$first_line" -eq 1 ]] || return 1
            first_line=0
            continue
        fi
        if [[ "$first_line" -eq 1 ]]; then
            case "$principal" in
                /*|[A-Za-z]:*|\\*)
                    # icacls prefixes only the first ACE with the inspected
                    # path. Preserve the two-word NT AUTHORITY principal;
                    # a generic last-space strip would turn it into
                    # AUTHORITY\\SYSTEM and reject valid real-world output.
                    if [[ "$principal" == *" NT AUTHORITY\\"* ]]; then
                        principal="NT AUTHORITY\\${principal##*\\}"
                    elif [[ "$principal" == *" BUILTIN\\"* ]]; then
                        principal="BUILTIN\\${principal##*\\}"
                    else
                        principal="${principal##*[[:space:]]}"
                    fi
                    ;;
            esac
        fi
        first_line=0
        principal="${principal#"${principal%%[![:space:]]*}"}"
        principal="${principal%"${principal##*[![:space:]]}"}"
        [[ -n "$principal" && "$principal" != *[[:cntrl:]]* ]] || return 1
        [[ "$rights" != *[[:cntrl:]]* ]] || return 1
        [[ "$rights" =~ ^\([A-Z0-9()]+\)$ ]] || return 1
        ace_count=$((ace_count + 1))
        normalized=$(_keychain_ntfs_lower "$principal")
        if _keychain_ntfs_principal_is_current_user "$principal"; then
            case "$rights" in
                *"(F)"*) current_full_control=1 ;;
            esac
        else
            case "$normalized" in
                's-1-5-18'|'nt authority\system'|'builtin\administrators'|'s-1-5-32-544') ;;
                *) return 1 ;;
            esac
        fi
    done <<< "$acl_output"

    [[ "$first_line" -eq 0 && "$ace_count" -gt 0 && "$current_full_control" -eq 1 ]]
}

# Verify ownership plus explicit DACL evidence without treating an NTFS mode-bit
# approximation as a POSIX permission check.  ACL command failure, missing ACE
# evidence, and permissive/unknown ACEs all fail closed.
_keychain_ntfs_private_semantics() {
    local path="$1" owner="" current_user owner_uid="" current_uid acl_cmd=""
    local acl_path="$path" acl_output=""

    _keychain_ntfs_initialize_identity || return 1
    current_user="$KEYCHAIN_NTFS_CURRENT_USER"
    current_uid="$KEYCHAIN_NTFS_CURRENT_UID"
    acl_cmd=$(_keychain_ntfs_acl_command) || return 1
    if _keychain_is_ntfs && command -v cygpath >/dev/null 2>&1; then
        acl_path=$(cygpath -w "$path" 2>/dev/null) || return 1
    fi
    acl_output=$("$acl_cmd" "$acl_path" 2>/dev/null) || return 1

    owner=$(stat -c '%U' "$path" 2>/dev/null) || owner=$(stat -f '%Su' "$path" 2>/dev/null) || owner=""
    if [[ -n "$owner" && -n "$current_user" && "$owner" != "$current_user" ]]; then
        return 1
    fi
    owner_uid=$(stat -c '%u' "$path" 2>/dev/null) || owner_uid=""
    if [[ -n "$owner_uid" && -n "$current_uid" && "$owner_uid" != "$current_uid" ]]; then
        return 1
    fi

    _keychain_ntfs_acl_is_restrictive "$acl_output" || return 1

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
    # NTFS apply_private_mode already performed the stricter DACL/owner check.
    # POSIX still needs the independent exact mode/owner validation here.
    if ! _keychain_is_ntfs; then
        _keychain_assert_private_directory "$tokens_dir" || {
            _keychain_print_error "Refusing plaintext credential fallback without private ownership/mode on directory: $tokens_dir"
            return 1
        }
    fi
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

# Plaintext store/erase are read-modify-write operations.  Serialize every
# explicit file-backend mutation across independent CLI processes with one
# private directory beside the exact token path.  Native backends are untouched.
_KEYCHAIN_PLAINTEXT_LOCK_PATH=""
_KEYCHAIN_PLAINTEXT_LOCK_TOKEN=""
_KEYCHAIN_PLAINTEXT_LOCK_DEPTH=0

_keychain_plaintext_lock_owner() {
    local lock_path="$1" owner=""
    if [[ -f "$lock_path/owner" && ! -L "$lock_path/owner" ]]; then
        IFS= read -r owner < "$lock_path/owner" 2>/dev/null || true
        owner="${owner%$'\r'}"
    fi
    printf '%s' "$owner"
}

_keychain_plaintext_lock_current_owner() {
    local lock_path="$1"
    printf '%s|%s' "$$" "${KEYCHAIN_PLAINTEXT_LOCK_TOKEN:-}"
}

_keychain_plaintext_lock_token() {
    local token=""
    if declare -F _gitsetu_new_lock_token >/dev/null 2>&1; then
        token=$(_gitsetu_new_lock_token 2>/dev/null) || token=""
    fi
    if [[ -z "$token" && -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        token=$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \r\n') || token=""
    fi
    if [[ -z "$token" ]] && command -v cksum >/dev/null 2>&1; then
        token=$(printf '%s-%s-%s' "$$" "$RANDOM" "$RANDOM" | cksum 2>/dev/null | tr -d ' ') || token=""
        token="${token}$(printf '%s-%s' "$RANDOM" "$RANDOM" | cksum 2>/dev/null | tr -d ' ')"
    fi
    [[ "$token" =~ ^[0-9a-fA-F]{16,}$ ]] || return 1
    printf '%s' "$token"
}

_keychain_acquire_plaintext_mutation_lock() {
    local tokens_file="$1" lock_path="${1}.mutation.lock"
    local token owner retries timeout=60 sleep_duration=0.1

    _keychain_assert_no_symlink_components "$lock_path" || {
        _keychain_print_error "Refusing redirected plaintext credential lock path: $lock_path"
        return 1
    }
    if [[ "${KEYCHAIN_PLAINTEXT_LOCK_DEPTH:-0}" -gt 0 ]]; then
        owner=$(_keychain_plaintext_lock_owner "$lock_path")
        if [[ "$KEYCHAIN_PLAINTEXT_LOCK_PATH" == "$lock_path" && "$owner" == "$(_keychain_plaintext_lock_current_owner "$lock_path")" ]]; then
            KEYCHAIN_PLAINTEXT_LOCK_DEPTH=$((KEYCHAIN_PLAINTEXT_LOCK_DEPTH + 1))
            return 0
        fi
        _keychain_print_error "Cannot acquire a second plaintext credential mutation lock."
        return 1
    fi
    if [[ -n "${GITSETU_LOCK_TIMEOUT:-}" ]]; then
        if [[ ! "${GITSETU_LOCK_TIMEOUT}" =~ ^[1-9][0-9]*$ || "${#GITSETU_LOCK_TIMEOUT}" -gt 4 || "${GITSETU_LOCK_TIMEOUT}" -gt 3600 ]]; then
            _keychain_print_error "GITSETU_LOCK_TIMEOUT must be an integer from 1 to 3600."
            return 1
        fi
        timeout="${GITSETU_LOCK_TIMEOUT}"
    fi
    if [[ "${GITSETU_TEST:-0}" == "1" ]]; then
        retries=$((timeout * 50))
        sleep_duration=0.02
    else
        retries=$((timeout * 10))
    fi
    token=$(_keychain_plaintext_lock_token) || {
        _keychain_print_error "Cannot generate plaintext credential lock ownership token."
        return 1
    }

    while ! (umask 077; mkdir "$lock_path") 2>/dev/null; do
        if [[ -L "$lock_path" || ( -e "$lock_path" && ! -d "$lock_path" ) ]]; then
            _keychain_print_error "Refusing redirected plaintext credential lock path: $lock_path"
            return 1
        fi
        retries=$((retries - 1))
        if [[ "$retries" -le 0 ]]; then
            _keychain_print_error "Timed out waiting for plaintext credential mutation lock: $lock_path"
            return 1
        fi
        sleep "$sleep_duration"
    done

    if ! _keychain_apply_private_mode "$lock_path" 700 ||
       ! printf '%s|%s\n' "$$" "$token" > "$lock_path/owner" 2>/dev/null; then
        rm -f "$lock_path/owner" 2>/dev/null || true
        rmdir "$lock_path" 2>/dev/null || true
        _keychain_print_error "Cannot initialize plaintext credential mutation lock: $lock_path"
        return 1
    fi
    KEYCHAIN_PLAINTEXT_LOCK_PATH="$lock_path"
    KEYCHAIN_PLAINTEXT_LOCK_TOKEN="$token"
    KEYCHAIN_PLAINTEXT_LOCK_DEPTH=1
    return 0
}

_keychain_release_plaintext_mutation_lock() {
    local lock_path="${KEYCHAIN_PLAINTEXT_LOCK_PATH:-}"
    local owner releasing_dir moved_owner

    if [[ "${KEYCHAIN_PLAINTEXT_LOCK_DEPTH:-0}" -le 0 ]]; then
        return 0
    fi
    if [[ -z "$lock_path" ]]; then
        _keychain_print_error "Plaintext credential lock ownership is unavailable."
        return 1
    fi
    if [[ "${KEYCHAIN_PLAINTEXT_LOCK_DEPTH}" -gt 1 ]]; then
        KEYCHAIN_PLAINTEXT_LOCK_DEPTH=$((KEYCHAIN_PLAINTEXT_LOCK_DEPTH - 1))
        return 0
    fi
    if [[ ! -d "$lock_path" || -L "$lock_path" ]]; then
        _keychain_print_error "Refusing to release missing or redirected plaintext credential lock: $lock_path"
        return 1
    fi
    owner=$(_keychain_plaintext_lock_owner "$lock_path")
    if [[ "$owner" != "$(_keychain_plaintext_lock_current_owner "$lock_path")" ]]; then
        _keychain_print_error "Plaintext credential lock ownership changed; refusing release."
        return 1
    fi

    releasing_dir="${lock_path}.releasing.$$.$RANDOM"
    if ! mv "$lock_path" "$releasing_dir" 2>/dev/null; then
        _keychain_print_error "Failed to atomically release plaintext credential lock: $lock_path"
        return 1
    fi
    moved_owner=$(_keychain_plaintext_lock_owner "$releasing_dir")
    if [[ "$moved_owner" != "$owner" ]]; then
        if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
            mv "$releasing_dir" "$lock_path" 2>/dev/null || true
        fi
        _keychain_print_error "Plaintext credential lock changed during release; retained it for recovery."
        return 1
    fi
    if ! rm -f "$releasing_dir/owner" 2>/dev/null || ! rmdir "$releasing_dir" 2>/dev/null; then
        if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
            mv "$releasing_dir" "$lock_path" 2>/dev/null || true
        fi
        _keychain_print_error "Failed to remove plaintext credential lock metadata."
        return 1
    fi

    KEYCHAIN_PLAINTEXT_LOCK_DEPTH=0
    KEYCHAIN_PLAINTEXT_LOCK_PATH=""
    KEYCHAIN_PLAINTEXT_LOCK_TOKEN=""
    return 0
}

# Deterministic test-only rendezvous used to prove that the second process is
# outside the mutation critical section. It has no effect outside GITSETU_TEST.
_keychain_test_plaintext_mutation_barrier() {
    local barrier_dir="${GITSETU_TEST_CREDENTIAL_BARRIER_DIR:-}"
    local marker="" attempts=0

    [[ "${GITSETU_TEST:-0}" == "1" && -n "$barrier_dir" ]] || return 0
    [[ -d "$barrier_dir" && ! -L "$barrier_dir" ]] || {
        _keychain_print_error "Invalid plaintext credential test barrier directory."
        return 1
    }
    _keychain_assert_no_symlink_components "$barrier_dir" || return 1
    marker="${barrier_dir}/entered.$$.$RANDOM"
    (umask 077; : > "$marker") || return 1
    while [[ ! -e "$barrier_dir/release" ]]; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -ge 250 ]]; then
            rm -f "$marker" 2>/dev/null || true
            _keychain_print_error "Timed out at plaintext credential mutation test barrier."
            return 1
        fi
        sleep 0.02
    done
    rm -f "$marker" 2>/dev/null || return 1
    return 0
}

_keychain_plaintext_store() {
    _keychain_init_constants
    local profile="$1" host="$2" credential_path="$3" record="$4"
    local mutation_status=0

    _keychain_prepare_plaintext_dir || return 1
    _keychain_warn_plaintext "$KEYCHAIN_TOKENS_FILE"
    _keychain_acquire_plaintext_mutation_lock "$KEYCHAIN_TOKENS_FILE" || return 1
    _keychain_assert_private_directory "${KEYCHAIN_TOKENS_FILE%/*}" || mutation_status=1
    if [[ "$mutation_status" -eq 0 ]]; then
        _keychain_test_plaintext_mutation_barrier || mutation_status=$?
    fi
    if [[ "$mutation_status" -eq 0 ]]; then
        _keychain_plaintext_store_locked "$profile" "$host" "$credential_path" "$record" || mutation_status=$?
    fi
    _keychain_release_plaintext_mutation_lock || return 1
    return "$mutation_status"
}

_keychain_plaintext_store_locked() {
    _keychain_init_constants
    local profile="$1" host="$2" credential_path="$3" record="$4"
    local line match_status wrote_match=0

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
    local mutation_status=0

    _keychain_prepare_plaintext_dir || return 1
    _keychain_warn_plaintext "$KEYCHAIN_TOKENS_FILE"
    _keychain_acquire_plaintext_mutation_lock "$KEYCHAIN_TOKENS_FILE" || return 1
    _keychain_assert_private_directory "${KEYCHAIN_TOKENS_FILE%/*}" || mutation_status=1
    if [[ "$mutation_status" -eq 0 ]]; then
        _keychain_test_plaintext_mutation_barrier || mutation_status=$?
    fi
    if [[ "$mutation_status" -eq 0 ]]; then
        _keychain_plaintext_erase_locked "$profile" "$host" "$credential_path" || mutation_status=$?
    fi
    _keychain_release_plaintext_mutation_lock || return 1
    return "$mutation_status"
}

_keychain_plaintext_erase_locked() {
    _keychain_init_constants
    local profile="$1" host="$2" credential_path="$3"
    local line match_status matches=0

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

# Credential-helper compatibility lookup. Exact path tuples always win.  A
# normal miss may use only the setup PAT in the same profile and protocol host,
# so a credential from one mapped account can never satisfy another account or
# provider request.  Backend failures are not converted into fallback misses.
keychain_get_with_setup_fallback() {
    local profile="${1-}" host="${2-}" credential_path="${3-${GITSETU_CREDENTIAL_PATH:-}}"
    local setup_scope="$_KEYCHAIN_SETUP_PAT_SCOPE"
    local output="" status=0

    output=$(keychain_get "$profile" "$host" "$credential_path") || status=$?
    if [[ "$status" -eq 0 ]]; then
        [[ -n "$output" ]] && printf '%s\n' "$output"
        return 0
    fi
    [[ "$status" -eq 1 && "$credential_path" != "$setup_scope" ]] || return "$status"
    keychain_get "$profile" "$host" "$setup_scope"
}

# Erase the same tuple selected by the compatibility lookup. Probe the exact
# record first so erasing a repository-specific credential does not also erase
# the setup PAT; when the exact tuple is absent, erase the setup fallback.
keychain_erase_with_setup_fallback() {
    local profile="${1-}" host="${2-}" credential_path="${3-${GITSETU_CREDENTIAL_PATH:-}}"
    local setup_scope="$_KEYCHAIN_SETUP_PAT_SCOPE"
    local status=0

    [[ "$credential_path" != "$setup_scope" ]] || {
        keychain_erase "$profile" "$host" "$credential_path"
        return $?
    }
    keychain_get "$profile" "$host" "$credential_path" >/dev/null || status=$?
    case "$status" in
        0) keychain_erase "$profile" "$host" "$credential_path" ;;
        1) keychain_erase "$profile" "$host" "$setup_scope" ;;
        *) return "$status" ;;
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
