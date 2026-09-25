#!/usr/bin/env bash
# lib/backup.sh — Timestamped backups and authenticated state vaults
#
# Vaults created by this file use one format only: GITSETU_VAULT_V2.  No parser
# or alternate acceptance path exists for OpenSSL enc's unauthenticated
# Salted__ container.
#
# Portable v2 construction (Bash 3.2 + OpenSSL 1.0.1-era primitives):
#   * PBKDF2-HMAC-SHA256 derives a random-salt root key.
#   * Independent salts and domain-separated root-key inputs derive encryption
#     and authentication material (Encrypt-then-MAC key separation).
#   * AES-256-CTR provides confidentiality.
#   * HMAC-SHA256 authenticates every v2 parameter and the complete ciphertext
#     before decryption.  The standard two-pass HMAC construction streams the
#     derived key into OpenSSL stdin, so it never appears in process arguments.
#   * Fixed 0600/0700 staging and atomic destination installs prevent partial
#     plaintext archives or ciphertext from becoming visible.
#
# Restore authenticates, type-checks, allowlists, extracts, and validates the
# entire payload before acquiring the mutation lock.  The mutation phase uses a
# rollback transaction for registry state, key destinations, ~/.gitconfig, and
# ~/.ssh/config.
#
# Registry integration boundary:
#   load_profiles <file> from lib/core.sh is the sole parser.  Backup never
#   parses profiles.conf itself.  The loader validates the exact v2 six-field
#   registry and its profile gitconfigs and rejects all other formats.

# ------------------------------------------------------------------------------
# Canonical state path validation
# ------------------------------------------------------------------------------
_vault_path_has_redirect_component() {
    local path="$1" current parent
    current="$path"
    while [[ -n "$current" && "$current" != "/" && ! "$current" =~ ^[A-Za-z]:/$ ]]; do
        if [[ -e "$current" || -L "$current" ]]; then
            if [[ -L "$current" ]]; then return 0; fi
            if declare -F _gitsetu_is_reparse_point >/dev/null 2>&1 &&
               _gitsetu_is_reparse_point "$current"; then return 0; fi
        fi
        if [[ "$current" =~ ^[A-Za-z]:$ ]]; then
            break
        fi
        parent=$(dirname "$current") || return 2
        [[ "$parent" != "$current" ]] || return 2
        current="$parent"
    done
    return 1
}

_vault_validate_canonical_state_path() {
    local path="$1" normalized redirect=0
    [[ -n "$path" && "$path" != *[[:cntrl:]]* ]] || return 1
    case "$path" in /*|[A-Za-z]:/*) ;; *) return 1 ;; esac
    normalized=$(normalize_path "$path") || return 1
    [[ "$normalized" == "$path" ]] || return 1
    _vault_path_has_redirect_component "$path" || redirect=$?
    [[ "$redirect" -eq 1 ]] || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" && -O "$path" ]] || return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# ensure_dirs — Create all required GitSetu directories
# ------------------------------------------------------------------------------
ensure_dirs() {
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        return 0
    fi

    local config="${GITSETU_CONFIG_DIR%/}"
    [[ "$GITSETU_BACKUP_DIR" == "$config/backups" &&
       "$GITSETU_PROFILES_DIR" == "$config/profiles" &&
       "$GITSETU_HOOKS_DIR" == "$config/hooks" ]] || {
        print_error "GitSetu state roots do not match the canonical config directory."
        return 1
    }
    [[ "${config##*/}" == "gitsetu" && "$config" != "/" && ! "$config" =~ ^[A-Za-z]:/$ ]] || {
        print_error "Refusing unsafe GitSetu config root: $config"
        return 1
    }

    local dir
    for dir in "$config" "$GITSETU_BACKUP_DIR" "$GITSETU_PROFILES_DIR" "$GITSETU_HOOKS_DIR"; do
        _vault_validate_canonical_state_path "$dir" || {
            print_error "State path is redirected, non-canonical, or not user-owned: $dir"
            return 1
        }
        if [[ -e "$dir" && ! -d "$dir" ]]; then
            print_error "State path exists but is not a directory: $dir"
            return 1
        fi
        (umask 077 && mkdir -p "$dir") 2>/dev/null || {
            print_error "Failed to create state directory: $dir"
            return 1
        }
        _vault_validate_canonical_state_path "$dir" || {
            print_error "State path became redirected or non-canonical during creation: $dir"
            return 1
        }
        chmod 700 "$dir" 2>/dev/null || {
            print_error "Failed to restrict state directory: $dir"
            return 1
        }
        if declare -F _gitsetu_private_directory >/dev/null 2>&1; then
            _gitsetu_private_directory "$dir" || {
                print_error "State directory is not private: $dir"
                return 1
            }
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# backup_file — Create a private timestamped copy of one regular file
# ------------------------------------------------------------------------------
backup_file() {
    local source_path="${1:-}"
    if [[ $# -ne 1 || -z "$source_path" ]]; then
        return 1
    fi
    if [[ ! -f "$source_path" || -L "$source_path" ]]; then
        return 1
    fi

    ensure_dirs || return 1

    local source_base timestamp backup_path tmp_path counter=1
    source_base=$(basename "$source_path") || return 1
    timestamp=$(date +%Y%m%dT%H%M%S) || return 1
    backup_path="$GITSETU_BACKUP_DIR/${source_base}.${timestamp}.bak"

    while [[ -e "$backup_path" || -L "$backup_path" ]]; do
        backup_path="$GITSETU_BACKUP_DIR/${source_base}.${timestamp}.${counter}.bak"
        counter=$((counter + 1))
        [[ "$counter" -le 10000 ]] || return 1
    done

    tmp_path=$(umask 077 && mktemp "$GITSETU_BACKUP_DIR/.${source_base}.tmp.XXXXXX" 2>/dev/null) || return 1
    if ! cp -p "$source_path" "$tmp_path" 2>/dev/null ||
       ! chmod 600 "$tmp_path" 2>/dev/null ||
       ! mv "$tmp_path" "$backup_path" 2>/dev/null; then
        rm -f "$tmp_path" 2>/dev/null || true
        print_error "Failed to backup: $source_path"
        return 1
    fi

    print_info "Backed up: $source_path → $backup_path"
    return 0
}

# ------------------------------------------------------------------------------
# v2 vault constants and small filesystem helpers
# ------------------------------------------------------------------------------
GITSETU_VAULT_FORMAT="GITSETU_VAULT_V2"
GITSETU_VAULT_KDF="pbkdf2-hmac-sha256-hierarchical-v1"
GITSETU_VAULT_CIPHER="aes-256-ctr"
GITSETU_VAULT_MAC="hmac-sha256"
GITSETU_VAULT_ITERATIONS=600000
GITSETU_VAULT_MAC_SALT="474954534554554d41432d7632" # "GITSETUMAC-v2" prefix
GITSETU_VAULT_MAX_ARCHIVE_BYTES=268435456
GITSETU_VAULT_MAX_MEMBER_BYTES=67108864
GITSETU_VAULT_MAX_MEMBERS=4096

# Test harnesses and embedders may reinitialize their environment after the
# libraries have been sourced.  Reassert immutable vault parameters at each
# public entry point rather than allowing an environment-only override.
_vault_ensure_runtime_constants() {
    GITSETU_VAULT_FORMAT="GITSETU_VAULT_V2"
    GITSETU_VAULT_KDF="pbkdf2-hmac-sha256-hierarchical-v1"
    GITSETU_VAULT_CIPHER="aes-256-ctr"
    GITSETU_VAULT_MAC="hmac-sha256"
    GITSETU_VAULT_ITERATIONS=600000
    GITSETU_VAULT_MAC_SALT="474954534554554d41432d7632"
    GITSETU_VAULT_MAX_ARCHIVE_BYTES=268435456
    GITSETU_VAULT_MAX_MEMBER_BYTES=67108864
    GITSETU_VAULT_MAX_MEMBERS=4096
    if ! declare -p GITSETU_CLEANUP_DIRS >/dev/null 2>&1; then
        GITSETU_CLEANUP_DIRS=()
    fi
    if ! declare -p GITSETU_VAULT_ACTIVE_TRANSACTION >/dev/null 2>&1; then
        GITSETU_VAULT_ACTIVE_TRANSACTION=""
    fi
}

_VAULT_HEADER_CORE=""
_VAULT_KDF_SALT=""
_VAULT_ENC_SALT=""
_VAULT_IV=""
_VAULT_EXPECTED_TAG=""
_VAULT_PAYLOAD_LENGTH=0
_VAULT_HEADER_BYTES=0
_VAULT_ROOT_KEY=""
_VAULT_ACTIVE_TEMP=""
GITSETU_VAULT_ACTIVE_TRANSACTION=""

_vault_file_size() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    local size
    size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]') || return 1
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$size"
}

_vault_private_temp_dir() {
    local template="${1:-}"
    local temp_base="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
    [[ -n "$temp_base" && -d "$temp_base" && ! -L "$temp_base" && -O "$temp_base" ]] || return 1
    [[ -n "$template" && "$template" != *[[:cntrl:]]* && "$template" != */* ]] || return 1

    if declare -F canonicalize_path >/dev/null 2>&1; then
        local canonical_temp
        canonical_temp=$(canonicalize_path "$temp_base") || return 1
        [[ "$canonical_temp" == "$temp_base" ]] || return 1
    fi
    if declare -F _gitsetu_path_has_symlink_component >/dev/null 2>&1; then
        local link_status=0
        _gitsetu_path_has_symlink_component "$temp_base" || link_status=$?
        if [[ "$link_status" -eq 2 && "$temp_base" =~ ^[A-Za-z]:/ ]]; then
            local walk="$temp_base" parent
            while [[ -n "$walk" && ! "$walk" =~ ^[A-Za-z]:/$ ]]; do
                if [[ -e "$walk" || -L "$walk" ]]; then
                    _gitsetu_is_reparse_point "$walk" && return 1
                fi
                parent=$(dirname "$walk") || return 1
                [[ "$parent" != "$walk" ]] || return 1
                walk="$parent"
            done
        elif [[ "$link_status" -ne 1 ]]; then
            return 1
        fi
    fi
    if declare -F _gitsetu_is_reparse_point >/dev/null 2>&1 &&
       _gitsetu_is_reparse_point "$temp_base"; then
        return 1
    fi

    local path
    if declare -F secure_mktemp_dir >/dev/null 2>&1; then
        path=$(secure_mktemp_dir "$temp_base/$template.XXXXXX" 2>/dev/null) || return 1
    else
        path=$(umask 077 && mktemp -d "$temp_base/$template.XXXXXX" 2>/dev/null) || return 1
    fi
    path=${path%$'\r'}
    [[ -d "$path" && ! -L "$path" ]] || return 1
    chmod 700 "$path" 2>/dev/null || {
        rm -rf "$path" 2>/dev/null || true
        return 1
    }
    printf '%s' "$path"
}

_vault_copy_regular() {
    local source_path="$1"
    local destination_path="$2"
    local mode="${3:-600}"

    [[ -f "$source_path" && ! -L "$source_path" && -r "$source_path" ]] || return 1
    [[ "$destination_path" != *[[:cntrl:]] ]] || return 1
    (umask 077 && cp -p "$source_path" "$destination_path") 2>/dev/null || return 1
    chmod "$mode" "$destination_path" 2>/dev/null || {
        rm -f "$destination_path" 2>/dev/null || true
        return 1
    }
}

_vault_copy_file_private() {
    local source_path="$1"
    local destination_path="$2"
    [[ -f "$source_path" && ! -L "$source_path" && -r "$source_path" ]] || return 1
    (umask 077 && cp "$source_path" "$destination_path") 2>/dev/null || return 1
    chmod 600 "$destination_path" 2>/dev/null || return 1
}

# The core registry loader is the integration boundary.  Requiring its v2
# constants and exact header here makes an alternate registry parser impossible
# even if load_profiles is later changed.
_vault_load_registry_v2() {
    local registry_path="$1"
    local profiles_dir="$2"

    if ! declare -F load_profiles >/dev/null 2>&1; then
        print_error "Registry integration is unavailable: load_profiles is required for v2 vaults."
        return 1
    fi
    if [[ "${GITSETU_REGISTRY_VERSION:-}" != "2" || "${GITSETU_REGISTRY_HEADER:-}" != "# gitsetu-registry-v2" ]]; then
        print_error "Registry integration does not expose the required v2 contract."
        return 1
    fi
    if [[ "$registry_path" != "$GITSETU_PROFILES_CONF" ]]; then
        print_error "Refusing non-canonical v2 registry path: $registry_path"
        return 1
    fi
    if [[ ! -f "$registry_path" || -L "$registry_path" ]]; then
        print_error "The v2 profile registry is missing or is not a regular file."
        return 1
    fi

    local saved_profiles_dir="$GITSETU_PROFILES_DIR"
    GITSETU_PROFILES_DIR="$profiles_dir"
    load_profiles "$registry_path"
    local load_rc=$?
    GITSETU_PROFILES_DIR="$saved_profiles_dir"
    if [[ "$load_rc" -ne 0 || "${PROFILE_COUNT:-0}" -lt 1 ]]; then
        print_error "Profile registry validation failed${GITSETU_REGISTRY_ERROR:+: $GITSETU_REGISTRY_ERROR}."
        return 1
    fi
    return 0
}

_vault_validate_bounded_uint() {
    local value="$1" minimum="$2" maximum="$3"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    [[ "$value" -ge "$minimum" && "$value" -le "$maximum" ]]
}

# ------------------------------------------------------------------------------
# get_openssl_args — Canonical v2 KDF arguments (no unauthenticated fallback)
# ------------------------------------------------------------------------------
get_openssl_args() {
    _vault_ensure_runtime_constants
    if ! command -v openssl >/dev/null 2>&1; then
        return 1
    fi
    local help_text
    help_text=$(openssl enc -help 2>&1) || return 1
    [[ "$help_text" == *"-pbkdf2"* && "$help_text" == *"-iter"* ]] || return 1
    printf '%s\n' "-pbkdf2 -iter $GITSETU_VAULT_ITERATIONS"
}

_vault_validate_runtime() {
    command -v openssl >/dev/null 2>&1 || {
        print_error "OpenSSL is required for authenticated v2 vaults."
        return 1
    }
    command -v tar >/dev/null 2>&1 || {
        print_error "tar is required for authenticated v2 vaults."
        return 1
    }
    get_openssl_args >/dev/null || {
        print_error "This OpenSSL lacks PBKDF2 support required by vault v2; refusing an insecure fallback."
        return 1
    }
    openssl dgst -sha256 /dev/null >/dev/null 2>&1 || {
        print_error "This OpenSSL lacks SHA-256 support required by vault v2."
        return 1
    }
}

# ------------------------------------------------------------------------------
# Password acquisition — values remain in shell memory and OpenSSL stdin only
# ------------------------------------------------------------------------------
_vault_password_contains_line_break() {
    local password="$1"
    [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]]
}

_vault_test_password_enabled() {
    [[ "${GITSETU_TEST:-0}" == "1" && "${GITSETU_TEST_VAULT_MODE:-0}" == "1" ]]
}

_vault_read_new_password() {
    local password confirm
    if _vault_test_password_enabled && [[ -n "${GITSETU_TEST_VAULT_PASS:-}" ]]; then
        _VAULT_ROOT_KEY="$GITSETU_TEST_VAULT_PASS"
    else
        ask_password "Enter a strong vault password (minimum 12 characters): "
        password="$REPLY"
        ask_password "Confirm vault password: "
        confirm="$REPLY"
        _VAULT_ROOT_KEY=""
        if [[ "$password" != "$confirm" ]]; then
            print_error "Passwords do not match. Backup aborted."
            return 1
        fi
        if [[ "${#password}" -lt 12 ]]; then
            print_error "Vault password must contain at least 12 characters."
            return 1
        fi
        _VAULT_ROOT_KEY="$password"
    fi

    if [[ -z "$_VAULT_ROOT_KEY" ]] || ! _vault_password_contains_line_break "$_VAULT_ROOT_KEY"; then
        print_error "A non-empty single-line vault password is required."
        _VAULT_ROOT_KEY=""
        return 1
    fi
    [[ "${#_VAULT_ROOT_KEY}" -le 1024 ]] || {
        print_error "Vault password is too long (maximum 1024 characters)."
        _VAULT_ROOT_KEY=""
        return 1
    }
    return 0
}

_vault_read_restore_password() {
    local password
    if _vault_test_password_enabled && [[ -n "${GITSETU_TEST_VAULT_PASS:-}" ]]; then
        password="$GITSETU_TEST_VAULT_PASS"
    else
        ask_password "Enter vault password: "
        password="$REPLY"
    fi
    if [[ -z "$password" ]] || ! _vault_password_contains_line_break "$password" || [[ "${#password}" -gt 1024 ]]; then
        print_error "A non-empty single-line vault password is required."
        return 1
    fi
    _VAULT_ROOT_KEY="$password"
    return 0
}

# ------------------------------------------------------------------------------
# PBKDF2 hierarchy and authenticated tag
# ------------------------------------------------------------------------------
_vault_random_hex() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -ge 16 && "$bytes" -le 64 ]] || return 1
    [[ -r /dev/urandom ]] || return 1
    local value
    value=$(head -c "$bytes" /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \r\n') || return 1
    [[ "$value" =~ ^[0-9a-f]+$ ]] || return 1
    printf '%s' "$value"
}

# OpenSSL enc's portable password KDF consumes an eight-byte -S salt.  The v2
# KDF therefore appends the remaining authenticated random salt bytes to the
# one-line password input.  Across root and encryption derivations this consumes
# the complete 128-bit fields while retaining compatibility with old OpenSSL.
_vault_derive_root_key() {
    local password="$1"
    local kdf_salt="$2"
    local salt_prefix="${kdf_salt:0:16}"
    local salt_suffix="${kdf_salt:16}"
    local derived key_hex

    derived=$(
        printf '%s%s\n' "$password" "$salt_suffix" |
            openssl enc -aes-256-cbc -P -salt -pbkdf2 -iter "$GITSETU_VAULT_ITERATIONS" \
                -S "$salt_prefix" -pass stdin 2>/dev/null
    ) || return 1
    key_hex=$(printf '%s\n' "$derived" | sed -n 's/^key=//p' | head -n 1)
    [[ "$key_hex" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s' "$key_hex"
}

_vault_derive_mac_key() {
    local root_key="$1"
    local derived key_hex
    derived=$(
        printf 'gitsetu-v2-authentication:%s\n' "$root_key" |
            openssl enc -aes-256-cbc -P -salt -pbkdf2 -iter "$GITSETU_VAULT_ITERATIONS" \
                -S "$GITSETU_VAULT_MAC_SALT" -pass stdin 2>/dev/null
    ) || return 1
    key_hex=$(printf '%s\n' "$derived" | sed -n 's/^key=//p' | head -n 1)
    [[ "$key_hex" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s' "$key_hex"
}

# Textbook HMAC-SHA256 (RFC 2104), implemented with OpenSSL SHA-256 so the key
# never needs to appear in process arguments.  The PBKDF2 output is 32 random
# bytes represented as exactly 64 lowercase/uppercase hex characters; those 64
# bytes are a valid HMAC key and exactly fill SHA-256's 64-byte block.
_vault_hmac_pad() {
    local key_hex="$1" pad_octal="$2"
    local char bytecode octal i
    for (( i=0; i<64; i++ )); do
        char="${key_hex:i:1}"
        printf -v bytecode '%d' "'$char" || return 1
        printf -v octal '%03o' "$((bytecode ^ pad_octal))" || return 1
        printf '%b' "\\0${octal}" || return 1
    done
}

_vault_compute_tag() {
    local root_key="$1"
    local header_core="$2"
    local ciphertext="$3"
    local destination_tag="$4"
    local payload_length="${5:-}"
    local mac_key inner_hash

    [[ "$payload_length" =~ ^[0-9]+$ ]] || return 1
    mac_key=$(_vault_derive_mac_key "$root_key") || return 1
    inner_hash="${destination_tag}.inner"
    {
        _vault_hmac_pad "$mac_key" 54
        cat "$header_core"
        # The tag itself cannot cover its own value.  Every other envelope
        # parameter, including the declared payload length and the exact
        # separator framing, is nevertheless authenticated.
        printf 'payload_length=%s\n\nPAYLOAD\n' "$payload_length"
        cat "$ciphertext"
    } | openssl dgst -sha256 -binary > "$inner_hash" 2>/dev/null || {
        rm -f "$inner_hash" 2>/dev/null || true
        return 1
    }
    {
        _vault_hmac_pad "$mac_key" 92
        cat "$inner_hash"
    } | openssl dgst -sha256 -binary > "$destination_tag" 2>/dev/null || {
        rm -f "$inner_hash" 2>/dev/null || true
        return 1
    }
    rm -f "$inner_hash" 2>/dev/null || true

    chmod 600 "$destination_tag" 2>/dev/null || return 1
    [[ $(_vault_file_size "$destination_tag") -eq 32 ]] || return 1
}

_vault_hex_matches_file() {
    local expected_hex="$1"
    local tag_file="$2"
    local actual_hex
    actual_hex=$(od -An -tx1 "$tag_file" 2>/dev/null | tr -d ' \r\n') || return 1
    [[ "$actual_hex" == "$expected_hex" ]]
}

_vault_encrypt_stream() {
    local root_key="$1" enc_salt="$2" iv="$3" input="$4" output="$5"
    local salt_suffix="${enc_salt:16}"
    printf 'gitsetu-v2-encryption:%s:%s\n' "$root_key" "$salt_suffix" |
        openssl enc -aes-256-ctr -salt -pbkdf2 -iter "$GITSETU_VAULT_ITERATIONS" \
            -S "${enc_salt:0:16}" -iv "$iv" -pass stdin \
            -in "$input" -out "$output" 2>/dev/null
}

_vault_decrypt_stream() {
    local root_key="$1" enc_salt="$2" iv="$3" input="$4" output="$5"
    local salt_suffix="${enc_salt:16}"
    printf 'gitsetu-v2-encryption:%s:%s\n' "$root_key" "$salt_suffix" |
        openssl enc -d -aes-256-ctr -salt -pbkdf2 -iter "$GITSETU_VAULT_ITERATIONS" \
            -S "${enc_salt:0:16}" -iv "$iv" -pass stdin \
            -in "$input" -out "$output" 2>/dev/null
}

_vault_write_authenticated_vault() {
    local output_path="$1" plaintext_path="$2" password="$3" work_dir="$4"
    local kdf_salt enc_salt iv root_key ciphertext header_core tag_file payload_length
    local header_tmp

    kdf_salt=$(_vault_random_hex 16) || return 1
    enc_salt=$(_vault_random_hex 16) || return 1
    iv=$(_vault_random_hex 16) || return 1
    root_key=$(_vault_derive_root_key "$password" "$kdf_salt") || return 1

    ciphertext="$work_dir/ciphertext.bin"
    header_core="$work_dir/header.core"
    tag_file="$work_dir/tag.bin"
    header_tmp="$work_dir/header.full"
    _vault_encrypt_stream "$root_key" "$enc_salt" "$iv" "$plaintext_path" "$ciphertext" || return 1

    {
        printf '%s\n' "$GITSETU_VAULT_FORMAT"
        printf 'kdf=%s\n' "$GITSETU_VAULT_KDF"
        printf 'iterations=%s\n' "$GITSETU_VAULT_ITERATIONS"
        printf 'cipher=%s\n' "$GITSETU_VAULT_CIPHER"
        printf 'mac=%s\n' "$GITSETU_VAULT_MAC"
        printf 'kdf_salt=%s\n' "$kdf_salt"
        printf 'encryption_salt=%s\n' "$enc_salt"
        printf 'iv=%s\n' "$iv"
    } > "$header_core" || return 1

    payload_length=$(_vault_file_size "$ciphertext") || return 1
    [[ "$payload_length" -gt 0 ]] || return 1
    _vault_compute_tag "$root_key" "$header_core" "$ciphertext" "$tag_file" "$payload_length" || return 1
    local tag_hex
    tag_hex=$(od -An -tx1 "$tag_file" 2>/dev/null | tr -d ' \r\n') || return 1

    {
        cat "$header_core"
        printf 'tag=%s\n' "$tag_hex"
        printf 'payload_length=%s\n\n' "$payload_length"
    } > "$header_tmp" || return 1

    # output_path is the destination-local, mode-0600 temp created by cmd_backup.
    # Assemble the completed envelope there so the final install is a same-filesystem
    # rename.  Ciphertext and plaintext artifacts never share that directory.
    if ! cat "$header_tmp" "$ciphertext" > "$output_path"; then
        return 1
    fi
    chmod 600 "$output_path" 2>/dev/null || return 1
    _VAULT_ROOT_KEY=""
    root_key=""
    return 0
}

# ------------------------------------------------------------------------------
# Strict v2 envelope parser — runs before password use or state mutation
# ------------------------------------------------------------------------------
_vault_parse_header() {
    local vault_path="$1"
    local magic line2 line3 line4 line5 line6 line7 line8 line9 line10 line11
    local tag_value length_value file_size header_size

    [[ -f "$vault_path" && ! -L "$vault_path" && -r "$vault_path" ]] || return 1
    {
        IFS= read -r magic || true
        IFS= read -r line2 || true
        IFS= read -r line3 || true
        IFS= read -r line4 || true
        IFS= read -r line5 || true
        IFS= read -r line6 || true
        IFS= read -r line7 || true
        IFS= read -r line8 || true
        IFS= read -r line9 || true
        IFS= read -r line10 || true
        IFS= read -r line11 || true
    } < "$vault_path"

    [[ "$magic" == "$GITSETU_VAULT_FORMAT" ]] || return 1
    [[ "$line2" == "kdf=$GITSETU_VAULT_KDF" ]] || return 1
    [[ "$line3" == "iterations=$GITSETU_VAULT_ITERATIONS" ]] || return 1
    [[ "$line4" == "cipher=$GITSETU_VAULT_CIPHER" ]] || return 1
    [[ "$line5" == "mac=$GITSETU_VAULT_MAC" ]] || return 1
    [[ "$line6" =~ ^kdf_salt=[0-9a-f]{32}$ ]] || return 1
    [[ "$line7" =~ ^encryption_salt=[0-9a-f]{32}$ ]] || return 1
    [[ "$line8" =~ ^iv=[0-9a-f]{32}$ ]] || return 1
    [[ "$line9" =~ ^tag=[0-9a-f]{64}$ ]] || return 1
    [[ "$line10" =~ ^payload_length=([0-9]+)$ ]] || return 1
    # The writer emits one empty separator line before binary ciphertext.
    [[ -z "$line11" ]] || return 1

    _VAULT_KDF_SALT="${line6#kdf_salt=}"
    _VAULT_ENC_SALT="${line7#encryption_salt=}"
    _VAULT_IV="${line8#iv=}"
    tag_value="${line9#tag=}"
    length_value="${BASH_REMATCH[1]}"

    _vault_validate_bounded_uint "$length_value" 1 "$GITSETU_VAULT_MAX_ARCHIVE_BYTES" || return 1
    _VAULT_EXPECTED_TAG="$tag_value"
    _VAULT_PAYLOAD_LENGTH="$length_value"

    header_size=$(head -n 11 "$vault_path" 2>/dev/null | wc -c | tr -d '[:space:]') || return 1
    file_size=$(_vault_file_size "$vault_path") || return 1
    _VAULT_HEADER_BYTES="$header_size"
    [[ $((header_size + length_value)) -eq "$file_size" ]] || return 1
    return 0
}

_vault_authenticate_envelope() {
    local vault_path="$1" password="$2" work_dir="$3"
    local root_key material tag_file header_core payload_file

    root_key=$(_vault_derive_root_key "$password" "$_VAULT_KDF_SALT") || return 1
    header_core="$work_dir/envelope.header.core"
    payload_file="$work_dir/envelope.payload"
    tag_file="$work_dir/envelope.tag"
    head -n 8 "$vault_path" > "$header_core" 2>/dev/null || return 1
    tail -c "$_VAULT_PAYLOAD_LENGTH" "$vault_path" > "$payload_file" 2>/dev/null || return 1
    _vault_compute_tag "$root_key" "$header_core" "$payload_file" "$tag_file" "$_VAULT_PAYLOAD_LENGTH" || return 1
    _vault_hex_matches_file "$_VAULT_EXPECTED_TAG" "$tag_file" || return 1
    _VAULT_ROOT_KEY="$root_key"
    root_key=""
    return 0
}

_vault_choose_source_home() {
    local home config config_input config_parent config_home config_home_candidate
    local home_key config_key config_home_key
    local path_key home_ok=1 config_ok=1 mixed_config=0 i

    home=$(normalize_path "$HOME") || return 1
    config_input="${GITSETU_CONFIG_DIR//\\//}"
    config=$(normalize_path "$config_input") || return 1
    home_key=$(_vault_manifest_path_key "$home") || return 1
    # Keep the lexical Windows/MSYS form for mixed-mode selection; normalizing
    # it through a forced WSL/platform shim can otherwise turn C:/ into /tmp.
    config_key=$(_vault_portable_path_key "$config_input") || return 1
    config_parent=$(dirname "$config_input")
    config_home=$(dirname "$config_parent")
    config_home_candidate=$(_vault_portable_path_key "$config_home") || return 1
    config_home_key=$(_vault_portable_path_key "$config_home_candidate") || return 1
    if [[ "$config_key" =~ ^[A-Za-z]:/ && "$home_key" != [A-Za-z]:/* ]]; then
        mixed_config=1
    fi

    # Prefer the actual HOME whenever all managed paths are beneath it. This
    # preserves custom XDG layouts whose config root is outside HOME.
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ -n "${PROFILE_DIRS[$i]:-}" ]]; then
            path_key=$(_vault_manifest_path_key "${PROFILE_DIRS[$i]}") || return 1
            _vault_path_is_within "$path_key" "$home_key" || home_ok=0
            _vault_path_is_within "$path_key" "$config_home_key" || config_ok=0
        fi
        if [[ -n "${PROFILE_KEYS[$i]:-}" ]]; then
            path_key=$(_vault_manifest_path_key "${PROFILE_KEYS[$i]}") || return 1
            _vault_path_is_within "$path_key" "$home_key" || home_ok=0
            _vault_path_is_within "$path_key" "$config_home_key" || config_ok=0
        fi
    done
    if [[ "$mixed_config" -eq 0 && "$home_ok" -eq 1 && -n "$home" && "$home" != "/" ]]; then
        printf '%s' "$home_key"
        return 0
    fi

    # In MSYS/Node mixed mode HOME can be a temporary POSIX spelling while
    # XDG_CONFIG_HOME and managed paths remain canonical C:/... paths. Only
    # choose the config-derived root when it contains the config root and every
    # managed path; arbitrary external paths remain rejected.
    if [[ "$config_ok" -eq 1 ]] && _vault_path_is_within "$config_key" "$config_home_key" &&
       [[ -n "$config_home_candidate" && "$config_home_candidate" != "/" ]]; then
        printf '%s' "$config_home_candidate"
        return 0
    fi

    # If a Windows canonical XDG/config root is paired with a POSIX HOME
    # spelling, the loader may have normalized managed records to the latter.
    # The config root is already registry-validated and user-owned; its
    # dirname/parent is the only safe canonical source-home fallback.
    if [[ "$config_key" =~ ^[A-Za-z]:/ && "$home_key" != "$config_key" &&
          "${config_input##*/}" == "gitsetu" && -d "$config" && ! -L "$config" && -O "$config" &&
          -n "$config_home_candidate" && "$config_home_candidate" != "/" ]]; then
        printf '%s' "$config_home_candidate"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Backup payload construction — only regular files from an explicit allowlist
# ------------------------------------------------------------------------------
_vault_stage_backup_payload() {
    local payload_root="$1"
    local archive_root="$payload_root/gitsetu-v2"
    local state_root="$archive_root/state"
    local profiles_root="$state_root/profiles"
    local hooks_root="$state_root/hooks"
    local keys_root="$archive_root/keys"
    local manifest="$archive_root/manifest"

    (umask 077 && mkdir -p "$profiles_root" "$hooks_root" "$keys_root") 2>/dev/null || return 1
    _vault_copy_regular "$GITSETU_PROFILES_CONF" "$state_root/profiles.conf" 600 || return 1

    local i label source_path public_path private_archive public_archive manifest_home
    local private_count=0 public_count=0
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]}"
        source_path="$GITSETU_PROFILES_DIR/${label}.gitconfig"
        _vault_copy_regular "$source_path" "$profiles_root/${label}.gitconfig" 600 || return 1

        private_archive="$keys_root/$i"
        public_archive="$keys_root/$i.pub"
        source_path="${PROFILE_KEYS[$i]}"
        public_path="${source_path}.pub"
        if [[ -e "$source_path" || -L "$source_path" ]]; then
            _vault_validate_key_destination "$source_path" || {
                print_error "Key path is outside the managed ~/.ssh root and is nonportable: $source_path"
                return 1
            }
            _vault_copy_regular "$source_path" "$private_archive" 600 || return 1
            private_count=$((private_count + 1))
        fi
        if [[ -e "$public_path" || -L "$public_path" ]]; then
            _vault_validate_key_destination "$public_path" || {
                print_error "Public-key path is outside the managed ~/.ssh root and is nonportable: $public_path"
                return 1
            }
            _vault_copy_regular "$public_path" "$public_archive" 644 || return 1
            public_count=$((public_count + 1))
        fi
    done

    if [[ "$private_count" -eq 0 && "$public_count" -eq 0 ]]; then
        print_error "No registered SSH key files were found to back up."
        return 1
    fi

    if [[ -f "$GITSETU_PROFILES_DIR/ssh_config" ]]; then
        _vault_copy_regular "$GITSETU_PROFILES_DIR/ssh_config" "$profiles_root/ssh_config" 600 || return 1
    fi
    if [[ -f "$GITSETU_HOOKS_DIR/pre-commit" ]]; then
        _vault_copy_regular "$GITSETU_HOOKS_DIR/pre-commit" "$hooks_root/pre-commit" 700 || return 1
    fi
    if [[ -f "$GITSETU_CONFIG_DIR/.tokens" ]]; then
        _vault_copy_regular "$GITSETU_CONFIG_DIR/.tokens" "$state_root/.tokens" 600 || return 1
    fi

    manifest_home=$(_vault_choose_source_home) || return 1
    [[ "$manifest_home" != *[[:cntrl:]]* ]] || return 1
    {
        printf 'format=2\n'
        printf 'profiles=%s\n' "$PROFILE_COUNT"
        printf 'source_home=%s\n' "$manifest_home"
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            printf 'profile.%s.config=state/profiles/%s.gitconfig\n' "$i" "${PROFILE_LABELS[$i]}"
            if [[ -f "$keys_root/$i" ]]; then
                printf 'profile.%s.key=keys/%s\n' "$i" "$i"
            else
                printf 'profile.%s.key=none\n' "$i"
            fi
            if [[ -f "$keys_root/$i.pub" ]]; then
                printf 'profile.%s.public=keys/%s.pub\n' "$i" "$i"
            else
                printf 'profile.%s.public=none\n' "$i"
            fi
        done
    } > "$manifest" || return 1
    chmod 600 "$manifest" 2>/dev/null || return 1
    return 0
}

# ------------------------------------------------------------------------------
# Archive validation — names, entry types, sizes, duplicates, and allowlist
# ------------------------------------------------------------------------------
_vault_archive_member_broad_allowed() {
    local member="$1"
    case "$member" in
        gitsetu-v2|gitsetu-v2/|\
        gitsetu-v2/state|gitsetu-v2/state/|\
        gitsetu-v2/state/profiles|gitsetu-v2/state/profiles/|\
        gitsetu-v2/state/hooks|gitsetu-v2/state/hooks/|\
        gitsetu-v2/keys|gitsetu-v2/keys/|\
        gitsetu-v2/manifest|gitsetu-v2/state/profiles.conf|\
        gitsetu-v2/state/.tokens|gitsetu-v2/state/profiles/ssh_config|\
        gitsetu-v2/state/hooks/pre-commit) return 0 ;;
        gitsetu-v2/state/profiles/*.gitconfig)
            local profile_name="${member#gitsetu-v2/state/profiles/}"
            [[ "$profile_name" =~ ^[a-z][a-z0-9-]*\.gitconfig$ ]] || return 1
            [[ "$profile_name" != *.gitconfig.gitconfig ]] || return 1
            return 0
            ;;
        gitsetu-v2/keys/*)
            local key_name="${member#gitsetu-v2/keys/}"
            [[ "$key_name" =~ ^[0-9]+(\.pub)?$ ]] || return 1
            return 0
            ;;
    esac
    return 1
}

_vault_validate_archive_listing() {
    local archive_path="$1" private_dir="$2"
    local names_list="$private_dir/tar.names"
    local verbose_list="$private_dir/tar.verbose"
    local archive_size member normalized seen type permissions owner member_size remainder
    local name_count verbose_count=0 line_no=0
    _VAULT_SEEN_MEMBERS=()

    archive_size=$(_vault_file_size "$archive_path") || return 1
    [[ "$archive_size" -le "$GITSETU_VAULT_MAX_ARCHIVE_BYTES" ]] || return 1
    tar -tzf "$archive_path" > "$names_list" 2>/dev/null || return 1
    tar -tvzf "$archive_path" > "$verbose_list" 2>/dev/null || return 1
    name_count=$(wc -l < "$names_list" | tr -d '[:space:]') || return 1
    _vault_validate_bounded_uint "$name_count" 1 "$GITSETU_VAULT_MAX_MEMBERS" || return 1
    verbose_count=$(wc -l < "$verbose_list" | tr -d '[:space:]') || return 1
    [[ "$name_count" -eq "$verbose_count" ]] || return 1

    local root_seen=0 state_seen=0 profiles_seen=0 keys_seen=0
    while IFS= read -r member || [[ -n "$member" ]]; do
        member=${member%$'\r'}
        [[ -n "$member" && "$member" != *[[:cntrl:]]* && "$member" != *\\* ]] || return 1
        case "$member" in
            /*|[A-Za-z]:/*) return 1 ;;
            *../*|*/..|..) return 1 ;;
        esac
        normalized="${member%/}"
        if _vault_archive_member_broad_allowed "$normalized"; then :; else return 1; fi
        seen="$normalized"
        local prior
        for prior in "${_VAULT_SEEN_MEMBERS[@]+"${_VAULT_SEEN_MEMBERS[@]}"}"; do
            [[ "$prior" != "$seen" ]] || return 1
        done
        _VAULT_SEEN_MEMBERS+=("$seen")
        case "$normalized" in
            gitsetu-v2) root_seen=1 ;;
            gitsetu-v2/state) state_seen=1 ;;
            gitsetu-v2/state/profiles) profiles_seen=1 ;;
            gitsetu-v2/keys) keys_seen=1 ;;
        esac
    done < "$names_list"

    [[ "$root_seen" -eq 1 && "$state_seen" -eq 1 && "$profiles_seen" -eq 1 && "$keys_seen" -eq 1 ]] || return 1

    while IFS= read -r line_no || [[ -n "$line_no" ]]; do
        line_no=${line_no%$'\r'}
        [[ -n "$line_no" ]] || return 1
        type="${line_no:0:1}"
        [[ "$type" == "-" || "$type" == "d" ]] || return 1
        IFS=' ' read -r permissions owner member_size remainder <<< "$line_no"
        [[ "$type" == "d" || "$member_size" =~ ^[0-9]+$ ]] || return 1
        if [[ "$type" == "-" ]]; then
            _vault_validate_bounded_uint "$member_size" 0 "$GITSETU_VAULT_MAX_MEMBER_BYTES" || return 1
        fi
    done < "$verbose_list"
    return 0
}

# ------------------------------------------------------------------------------
# Restore manifest validation
# ------------------------------------------------------------------------------
_VAULT_MANIFEST_COUNT=0
_VAULT_MANIFEST_SOURCE_HOME=""
_VAULT_MANIFEST_CONFIGS=()
_VAULT_MANIFEST_KEYS=()
_VAULT_MANIFEST_PUBLICS=()
_VAULT_MANIFEST_SSH=0
_VAULT_MANIFEST_HOOK=0
_VAULT_MANIFEST_TOKENS=0
_VAULT_ALLOWED_MEMBERS=()
_VAULT_RESTORE_KEY_SOURCES=()
_VAULT_RESTORE_PUB_SOURCES=()
_VAULT_RESTORE_KEY_TARGETS=()

_vault_allowed_member() {
    local candidate="$1" allowed
    for allowed in "${_VAULT_ALLOWED_MEMBERS[@]+"${_VAULT_ALLOWED_MEMBERS[@]}"}"; do
        [[ "$candidate" == "$allowed" ]] && return 0
    done
    return 1
}

_vault_validate_manifest_source_home() {
    local raw_home="$1" source_home current parent normalized link_status=0
    [[ -n "$raw_home" && "$raw_home" != *[[:cntrl:]]* ]] || return 1
    source_home="${raw_home//\\//}"
    [[ "$source_home" != *"/" || "$source_home" =~ ^[A-Za-z]:/$ ]] || return 1
    source_home="${source_home%/}"
    case "$source_home" in
        /|//|//?*|[A-Za-z]:/) return 1 ;;
    esac
    case "/$source_home/" in
        *"/../"*|*"/./"*) return 1 ;;
    esac
    case "$source_home" in
        *//*) return 1 ;;
    esac
    normalized=$(normalize_path "$source_home") || return 1
    if [[ "$normalized" != "$source_home" ]]; then
        # MSYS may serialize the same Windows drive as /C:/... while the
        # loader reports C:/....  Permit only that drive-form equivalence; a
        # symlink/reparse or a different absolute path remains rejected below.
        case "$source_home" in
            /[A-Za-z]/*|[A-Za-z]:/*) ;;
            *) return 1 ;;
        esac
    fi

    current="$source_home"
    while [[ -n "$current" && "$current" != "/" && ! "$current" =~ ^[A-Za-z]:/$ ]]; do
        if [[ -e "$current" || -L "$current" ]]; then
            if [[ ! -d "$current" || -L "$current" ]]; then
                return 1
            fi
            if declare -F _gitsetu_is_reparse_point >/dev/null 2>&1; then
                _gitsetu_is_reparse_point "$current" && return 1
            fi
        fi
        if [[ "$current" =~ ^[A-Za-z]:$ ]]; then
            break
        fi
        parent=$(dirname "$current") || return 1
        [[ "$parent" != "$current" ]] || return 1
        current="$parent"
    done
    if [[ -e "$source_home" && ! -O "$source_home" ]]; then
        return 1
    fi
    return "$link_status"
}

_vault_read_manifest() {
    local manifest="$1" line_count line expected
    [[ -f "$manifest" && ! -L "$manifest" && -r "$manifest" ]] || return 1

    IFS= read -r line < "$manifest" || return 1
    [[ "$line" == "format=2" ]] || return 1
    IFS= read -r line < <(sed -n '2p' "$manifest") || return 1
    [[ "$line" =~ ^profiles=([0-9]+)$ ]] || return 1
    _VAULT_MANIFEST_COUNT="${BASH_REMATCH[1]}"
    _vault_validate_bounded_uint "$_VAULT_MANIFEST_COUNT" 1 "${GITSETU_REGISTRY_MAX_PROFILES:-1024}" || return 1
    line=$(sed -n '3p' "$manifest") || return 1
    [[ "$line" == source_home=* ]] || return 1
    _VAULT_MANIFEST_SOURCE_HOME="${line#source_home=}"
    [[ -n "$_VAULT_MANIFEST_SOURCE_HOME" && "$_VAULT_MANIFEST_SOURCE_HOME" != *[[:cntrl:]]* ]] || return 1
    _vault_validate_manifest_source_home "$_VAULT_MANIFEST_SOURCE_HOME" || return 1
    _VAULT_MANIFEST_SOURCE_HOME=$(normalize_path "$_VAULT_MANIFEST_SOURCE_HOME") || return 1
    line_count=$(wc -l < "$manifest" | tr -d '[:space:]') || return 1
    # Three fixed header lines plus exactly config/key/public records per profile.
    [[ "$line_count" -eq $((3 + _VAULT_MANIFEST_COUNT * 3)) ]] || return 1

    _VAULT_MANIFEST_CONFIGS=()
    _VAULT_MANIFEST_KEYS=()
    _VAULT_MANIFEST_PUBLICS=()
    local line_number=3 i
    for (( i=0; i<_VAULT_MANIFEST_COUNT; i++ )); do
        line_number=$((line_number + 1))
        line=$(sed -n "${line_number}p" "$manifest") || return 1
        [[ "$line" =~ ^profile\.([0-9]+)\.config=state/profiles/([a-z][a-z0-9-]*)\.gitconfig$ ]] || return 1
        [[ "${BASH_REMATCH[1]}" == "$i" ]] || return 1
        expected="state/profiles/${BASH_REMATCH[2]}.gitconfig"
        _VAULT_MANIFEST_CONFIGS+=("$expected")

        line_number=$((line_number + 1))
        line=$(sed -n "${line_number}p" "$manifest") || return 1
        if [[ "$line" == "profile.$i.key=none" ]]; then
            _VAULT_MANIFEST_KEYS+=("")
        elif [[ "$line" =~ ^profile\.([0-9]+)\.key=keys/([0-9]+)$ && "${BASH_REMATCH[1]}" == "$i" && "${BASH_REMATCH[2]}" == "$i" ]]; then
            _VAULT_MANIFEST_KEYS+=("keys/$i")
        else
            return 1
        fi

        line_number=$((line_number + 1))
        line=$(sed -n "${line_number}p" "$manifest") || return 1
        if [[ "$line" == "profile.$i.public=none" ]]; then
            _VAULT_MANIFEST_PUBLICS+=("")
        elif [[ "$line" =~ ^profile\.([0-9]+)\.public=keys/([0-9]+)\.pub$ && "${BASH_REMATCH[1]}" == "$i" && "${BASH_REMATCH[2]}" == "$i" ]]; then
            _VAULT_MANIFEST_PUBLICS+=("keys/$i.pub")
        else
            return 1
        fi
    done

    if [[ -f "$(dirname "$manifest")/state/profiles/ssh_config" ]]; then
        _VAULT_MANIFEST_SSH=1
    fi
    if [[ -f "$(dirname "$manifest")/state/hooks/pre-commit" ]]; then
        _VAULT_MANIFEST_HOOK=1
    fi
    if [[ -f "$(dirname "$manifest")/state/.tokens" ]]; then
        _VAULT_MANIFEST_TOKENS=1
    fi
    return 0
}

_vault_validate_extracted_tree() {
    local extract_root="$1"
    local archive_root="$extract_root/gitsetu-v2"
    local member normalized i
    local names_list="$extract_root/.extracted.names"

    _vault_read_manifest "$archive_root/manifest" || return 1
    [[ "$_VAULT_MANIFEST_COUNT" -eq "$PROFILE_COUNT" ]] || return 1
    _VAULT_ALLOWED_MEMBERS=("gitsetu-v2/manifest" "gitsetu-v2/state/profiles.conf")
    local value
    for value in "${_VAULT_MANIFEST_CONFIGS[@]}"; do
        _VAULT_ALLOWED_MEMBERS+=("gitsetu-v2/$value")
    done
    for value in "${_VAULT_MANIFEST_KEYS[@]}"; do
        [[ -n "$value" ]] && _VAULT_ALLOWED_MEMBERS+=("gitsetu-v2/$value")
    done
    for value in "${_VAULT_MANIFEST_PUBLICS[@]}"; do
        [[ -n "$value" ]] && _VAULT_ALLOWED_MEMBERS+=("gitsetu-v2/$value")
    done
    [[ "$_VAULT_MANIFEST_SSH" -eq 0 ]] || _VAULT_ALLOWED_MEMBERS+=("gitsetu-v2/state/profiles/ssh_config")
    [[ "$_VAULT_MANIFEST_HOOK" -eq 0 ]] || _VAULT_ALLOWED_MEMBERS+=("gitsetu-v2/state/hooks/pre-commit")
    [[ "$_VAULT_MANIFEST_TOKENS" -eq 0 ]] || _VAULT_ALLOWED_MEMBERS+=("gitsetu-v2/state/.tokens")

    (cd "$extract_root" && find . -type f -print 2>/dev/null | sed 's#^\./##') > "$names_list" || return 1
    while IFS= read -r member || [[ -n "$member" ]]; do
        [[ "$member" == .extracted.names ]] && continue
        [[ "$member" == "$extract_root/.extracted.names" ]] && continue
        _vault_allowed_member "$member" || return 1
    done < "$names_list"
    rm -f "$names_list" 2>/dev/null || true

    [[ -f "$archive_root/state/profiles.conf" && ! -L "$archive_root/state/profiles.conf" ]] || return 1
    for (( i=0; i<_VAULT_MANIFEST_COUNT; i++ )); do
        [[ "${_VAULT_MANIFEST_CONFIGS[$i]}" == "state/profiles/${PROFILE_LABELS[$i]}.gitconfig" ]] || return 1
        [[ -f "$archive_root/${_VAULT_MANIFEST_CONFIGS[$i]}" && ! -L "$archive_root/${_VAULT_MANIFEST_CONFIGS[$i]}" ]] || return 1
        if [[ -n "${_VAULT_MANIFEST_KEYS[$i]}" ]]; then
            [[ -f "$archive_root/${_VAULT_MANIFEST_KEYS[$i]}" && ! -L "$archive_root/${_VAULT_MANIFEST_KEYS[$i]}" ]] || return 1
        fi
        if [[ -n "${_VAULT_MANIFEST_PUBLICS[$i]}" ]]; then
            [[ -f "$archive_root/${_VAULT_MANIFEST_PUBLICS[$i]}" && ! -L "$archive_root/${_VAULT_MANIFEST_PUBLICS[$i]}" ]] || return 1
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# Portable HOME mapping
# ------------------------------------------------------------------------------
_vault_manifest_path_key() {
    local normalized
    normalized=$(normalize_path "$1") || return 1
    _vault_portable_path_key "$normalized"
}

_vault_path_is_within() {
    local path_key="$1" root_key="$2"
    [[ "$path_key" == "$root_key" || "$path_key" == "$root_key/"* ]]
}

_vault_portable_path_key() {
    local path="${1:-}" drive converted os_name="${GITSETU_OS:-}"
    path="${path//\\//}"
    path="${path%/}"
    if [[ -z "$os_name" && ( "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ) ]]; then
        os_name="gitbash"
    fi
    if [[ ( "$os_name" == "gitbash" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ) ]] &&
       command -v cygpath >/dev/null 2>&1; then
        converted=$(cygpath -m "$path" 2>/dev/null || printf '')
        if [[ "$converted" =~ ^[A-Za-z]:/ ]]; then
            path="$converted"
        fi
    fi
    case "$path" in
        /mnt/[A-Za-z]/*)
            drive=$(printf '%s' "${path:5:1}" | tr '[:lower:]' '[:upper:]')
            path="${drive}:${path:6}"
            ;;
        /mnt/[A-Za-z])
            drive=$(printf '%s' "${path:5:1}" | tr '[:lower:]' '[:upper:]')
            path="$drive:/"
            ;;
        /[A-Za-z]/*)
            drive=$(printf '%s' "${path:1:1}" | tr '[:lower:]' '[:upper:]')
            path="${drive}:${path:2}"
            ;;
        /[A-Za-z])
            drive=$(printf '%s' "${path:1:1}" | tr '[:lower:]' '[:upper:]')
            path="$drive:/"
            ;;
        [A-Za-z]:/*|[A-Za-z]:)
            drive=$(printf '%s' "${path:0:1}" | tr '[:lower:]' '[:upper:]')
            path="${drive}${path:1}"
            ;;
    esac
    printf '%s' "$path"
}

_vault_map_home_bound_path() {
    local source_path="$1" source_home="$2" relative source_norm home_norm source_key home_key
    source_norm=$(normalize_path "$source_path") || return 1
    home_norm=$(normalize_path "$source_home") || return 1
    source_key=$(_vault_portable_path_key "$source_norm") || return 1
    home_key=$(_vault_portable_path_key "$home_norm") || return 1
    case "$source_key" in
        "$home_key") printf '%s' "$HOME" ;;
        "$home_key"/*)
            relative="${source_key#"$home_key"/}"
            [[ -n "$relative" && "$relative" != *[[:cntrl:]]* ]] || return 1
            case "$relative" in ..|../*|*/../*|*/..) return 1 ;; esac
            printf '%s/%s' "${HOME%/}" "$relative"
            ;;
        *) return 1 ;;
    esac
}

_vault_write_private_staged_registry() {
    local profiles_dir="${1%/}" state_dir archive_dir registry tmp_file
    [[ "$profiles_dir" == */state/profiles && ! -L "$profiles_dir" && -d "$profiles_dir" && -O "$profiles_dir" ]] || return 1
    state_dir="${profiles_dir%/profiles}"
    archive_dir="${state_dir%/state}"
    [[ "${archive_dir##*/}" == "gitsetu-v2" && -d "$archive_dir" && ! -L "$archive_dir" && -O "$archive_dir" ]] || return 1
    if declare -F _gitsetu_is_reparse_point >/dev/null 2>&1; then
        _gitsetu_is_reparse_point "$profiles_dir" && return 1
        _gitsetu_is_reparse_point "$state_dir" && return 1
        _gitsetu_is_reparse_point "$archive_dir" && return 1
    fi
    registry="$state_dir/profiles.conf"
    [[ ! -e "$registry" || ( -f "$registry" && ! -L "$registry" && -O "$registry" ) ]] || return 1

    local count="${PROFILE_COUNT:-0}" i j label directory provider sign key user
    local encoded_label encoded_directory encoded_provider encoded_sign encoded_key encoded_user
    local encoded_labels=() encoded_directories=() encoded_providers=()
    local encoded_signs=() encoded_keys=() encoded_users=()
    validate_bounded_uint "$count" 1 "${GITSETU_REGISTRY_MAX_PROFILES:-1024}" || return 1
    [[ ${#PROFILE_LABELS[@]} -eq "$count" && ${#PROFILE_NAMES[@]} -eq "$count" && \
       ${#PROFILE_EMAILS[@]} -eq "$count" && ${#PROFILE_DIRS[@]} -eq "$count" && \
       ${#PROFILE_PROVIDERS[@]} -eq "$count" && ${#PROFILE_SIGNS[@]} -eq "$count" && \
       ${#PROFILE_KEYS[@]} -eq "$count" && ${#PROFILE_USERS[@]} -eq "$count" ]] || return 1
    [[ "${PROFILE_LABELS[0]}" == "global" ]] || return 1
    for (( i=0; i<count; i++ )); do
        label="${PROFILE_LABELS[$i]}"; directory="${PROFILE_DIRS[$i]}"
        provider="${PROFILE_PROVIDERS[$i]}"; sign="${PROFILE_SIGNS[$i]}"
        key="${PROFILE_KEYS[$i]}"; user="${PROFILE_USERS[$i]}"
        validate_profile_record "$label" "$directory" "$provider" "$sign" "$key" "$user" || return 1
        for (( j=0; j<i; j++ )); do
            [[ "$label" != "${PROFILE_LABELS[$j]}" ]] || return 1
        done
    done
    for (( i=0; i<count; i++ )); do
        encoded_label=$(escape_registry_field "${PROFILE_LABELS[$i]}") || return 1
        encoded_directory=$(escape_registry_field "${PROFILE_DIRS[$i]}") || return 1
        encoded_provider=$(escape_registry_field "${PROFILE_PROVIDERS[$i]}") || return 1
        encoded_sign=$(escape_registry_field "${PROFILE_SIGNS[$i]}") || return 1
        encoded_key=$(escape_registry_field "${PROFILE_KEYS[$i]}") || return 1
        encoded_user=$(escape_registry_field "${PROFILE_USERS[$i]}") || return 1
        encoded_labels+=("$encoded_label")
        encoded_directories+=("$encoded_directory")
        encoded_providers+=("$encoded_provider")
        encoded_signs+=("$encoded_sign")
        encoded_keys+=("$encoded_key")
        encoded_users+=("$encoded_user")
    done

    tmp_file=$(umask 077 && mktemp "$state_dir/.profiles.conf.XXXXXX" 2>/dev/null) || return 1
    if ! {
        printf '%s\n' "$GITSETU_REGISTRY_HEADER"
        for (( i=0; i<count; i++ )); do
            printf '%s:%s:%s:%s:%s:%s\n' \
                "${encoded_labels[$i]}" "${encoded_directories[$i]}" "${encoded_providers[$i]}" \
                "${encoded_signs[$i]}" "${encoded_keys[$i]}" "${encoded_users[$i]}"
        done
    } > "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    if ! chmod 600 "$tmp_file" 2>/dev/null || ! mv -f "$tmp_file" "$registry" 2>/dev/null; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    return 0
}

_vault_rewrite_staged_registry_for_target() {
    local archive_root="$1"
    local source_home="${_VAULT_MANIFEST_SOURCE_HOME%/}"
    local source_home_canonical source_home_key source_ssh_canonical source_ssh_key
    local i old_key old_key_canonical old_key_key profile_dir_canonical profile_dir_key relative mapped_key mapped_dir provider provider_user profile_content temp_profile
    local saved_profiles_dir="$GITSETU_PROFILES_DIR"

    [[ -n "$source_home" ]] || return 1
    source_home_canonical=$(normalize_path "$source_home") || return 1
    source_home_key=$(_vault_portable_path_key "$source_home_canonical") || return 1
    source_ssh_canonical=$(normalize_path "$source_home_canonical/.ssh") || return 1
    source_ssh_key=$(_vault_portable_path_key "$source_ssh_canonical") || return 1
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        old_key="${PROFILE_KEYS[$i]}"
        old_key_canonical=$(normalize_path "$old_key") || return 1
        old_key_key=$(_vault_portable_path_key "$old_key_canonical") || return 1
        case "$old_key_key" in
            "$source_ssh_key"/*) ;;
            *)
                print_error "Vault contains a nonportable key path outside the source ~/.ssh root: $old_key"
                return 1
                ;;
        esac
        relative="${old_key_key#"$source_ssh_key"/}"
        [[ -n "$relative" && "$relative" != *[[:cntrl:]]* ]] || return 1
        case "$relative" in ..|../*|*/../*|*/..) return 1 ;; esac
        mapped_key="${HOME%/}/.ssh/${relative}"
        mapped_key=$(normalize_path "$mapped_key") || return 1
        _vault_validate_key_destination "$mapped_key" || {
            print_error "Mapped key destination is outside the target ~/.ssh root: $mapped_key"
            return 1
        }
        PROFILE_KEYS[i]="$mapped_key"

        if [[ -n "${PROFILE_DIRS[$i]}" ]]; then
            profile_dir_canonical=$(normalize_path "${PROFILE_DIRS[$i]}") || return 1
            profile_dir_key=$(_vault_portable_path_key "$profile_dir_canonical") || return 1
            if [[ "$profile_dir_key" != "$source_home_key" && "$profile_dir_key" != "$source_home_key/"* ]]; then
                print_error "Vault contains a nonportable external profile directory: ${PROFILE_DIRS[$i]}"
                return 1
            fi
            mapped_dir=$(_vault_map_home_bound_path "$profile_dir_canonical" "$source_home_canonical") || return 1
            mapped_dir=$(normalize_path "$mapped_dir") || return 1
            PROFILE_DIRS[i]="$mapped_dir"
        fi
    done

    GITSETU_PROFILES_DIR="$archive_root/state/profiles"
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        provider="${PROFILE_PROVIDERS[$i]}"
        provider_user="${PROFILE_USERS[$i]:-}"
        profile_content=$(build_profile_gitconfig "${PROFILE_LABELS[$i]}" "${PROFILE_NAMES[$i]}" \
            "${PROFILE_EMAILS[$i]}" "${PROFILE_SIGNS[$i]}" "${PROFILE_KEYS[$i]}") || {
                GITSETU_PROFILES_DIR="$saved_profiles_dir"
                return 1
            }
        temp_profile=$(umask 077 && mktemp "$GITSETU_PROFILES_DIR/.${PROFILE_LABELS[$i]}.gitconfig.XXXXXX" 2>/dev/null) || {
            GITSETU_PROFILES_DIR="$saved_profiles_dir"
            return 1
        }
        if ! printf '%s\n' "$profile_content" > "$temp_profile" ||
           ! chmod 600 "$temp_profile" 2>/dev/null ||
           ! mv -f "$temp_profile" "$GITSETU_PROFILES_DIR/${PROFILE_LABELS[$i]}.gitconfig" 2>/dev/null; then
            rm -f "$temp_profile" 2>/dev/null || true
            GITSETU_PROFILES_DIR="$saved_profiles_dir"
            return 1
        fi
    done
    if ! _vault_write_private_staged_registry "$archive_root/state/profiles" ||
       ! load_profiles "$archive_root/state/profiles.conf"; then
        GITSETU_PROFILES_DIR="$saved_profiles_dir"
        return 1
    fi
    GITSETU_PROFILES_DIR="$saved_profiles_dir"
    return 0
}

# ------------------------------------------------------------------------------
# Destination key safety and duplicate detection
# ------------------------------------------------------------------------------
_vault_validate_key_destination() {
    local key_path="$1" normalized current managed_ssh_root key_key root_key
    [[ -n "$key_path" && "$key_path" != *[[:cntrl:]]* ]] || return 1
    normalized=$(normalize_path "$key_path") || return 1
    [[ "$normalized" == "$key_path" ]] || return 1
    managed_ssh_root=$(normalize_path "$HOME/.ssh") || return 1
    key_key=$(_vault_portable_path_key "$key_path") || return 1
    root_key=$(_vault_portable_path_key "$managed_ssh_root") || return 1
    case "$key_key" in
        "$root_key"/*) ;;
        *) return 1 ;;
    esac
    case "$key_path" in
        /|C:/|D:/|"$HOME"|"$GITSETU_CONFIG_DIR"|"$GITSETU_CONFIG_DIR/") return 1 ;;
    esac

    current="${key_path%/*}"
    [[ "$current" != "$key_path" ]] || return 1
    while [[ -n "$current" && "$current" != "." && ! "$current" =~ ^[a-zA-Z]:/$ ]]; do
        if [[ -L "$current" ]]; then
            return 1
        fi
        if [[ -d "$current" ]]; then
            [[ -w "$current" ]] || return 1
            return 0
        fi
        local parent
        parent=$(dirname "$current") || return 1
        [[ "$parent" != "$current" ]] || return 1
        current="$parent"
    done
    [[ -d "$current" && -w "$current" && ! -L "$current" ]]
}

_vault_validate_restore_keys() {
    local archive_root="$1"
    local i mapping source target destination destination_key prior
    local private_rel public_rel
    local -a restore_destination_keys=()
    _VAULT_RESTORE_KEY_SOURCES=()
    _VAULT_RESTORE_PUB_SOURCES=()
    _VAULT_RESTORE_KEY_TARGETS=()

    for (( i=0; i<_VAULT_MANIFEST_COUNT; i++ )); do
        target="${PROFILE_KEYS[$i]}"
        _VAULT_RESTORE_KEY_TARGETS+=("$target")
        private_rel="${_VAULT_MANIFEST_KEYS[$i]}"
        public_rel="${_VAULT_MANIFEST_PUBLICS[$i]}"
        if [[ -n "$private_rel" ]]; then
            source="$archive_root/$private_rel"
            _VAULT_RESTORE_KEY_SOURCES+=("$source")
        else
            _VAULT_RESTORE_KEY_SOURCES+=("")
        fi
        if [[ -n "$public_rel" ]]; then
            _VAULT_RESTORE_PUB_SOURCES+=("$archive_root/$public_rel")
        else
            _VAULT_RESTORE_PUB_SOURCES+=("")
        fi

        # Every profile contributes a private and a public destination.  Compare
        # their portable identities before any transaction is created: content
        # equality cannot make overlapping writes safe, and a private path may
        # also collide with another profile's automatically derived ".pub" path.
        for mapping in private public; do
            if [[ "$mapping" == "private" ]]; then
                destination="$target"
            else
                destination="$target.pub"
            fi
            _vault_validate_key_destination "$destination" || return 1
            destination_key=$(_vault_manifest_path_key "$destination") || return 1
            for (( prior=0; prior<${#restore_destination_keys[@]}; prior++ )); do
                if [[ "${restore_destination_keys[$prior]}" == "$destination_key" ]]; then
                    print_error "Vault contains a duplicate key restore destination: $destination"
                    return 1
                fi
            done
            restore_destination_keys+=("$destination_key")
        done

        if [[ -e "$target" || -L "$target" ]]; then
            [[ -f "$target" && ! -L "$target" ]] || return 1
        fi
        if [[ -e "$target.pub" || -L "$target.pub" ]]; then
            [[ -f "$target.pub" && ! -L "$target.pub" ]] || return 1
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# cmd_backup — Full state encrypted backup
# ------------------------------------------------------------------------------
cmd_backup() {
    _vault_ensure_runtime_constants
    local out_file="${1:-}"
    if [[ $# -gt 1 ]]; then
        print_error "Usage: gitsetu backup [out_file]"
        return 1
    fi
    case "$out_file" in
        -*) print_error "Unknown backup option: $out_file"; return 1 ;;
    esac
    _vault_validate_runtime || return 1
    if [[ ! -f "$GITSETU_PROFILES_CONF" || -L "$GITSETU_PROFILES_CONF" ]]; then
        print_error "No valid v2 GitSetu state found to backup."
        return 1
    fi

    if [[ -z "$out_file" ]]; then
        out_file="gitsetu_vault_$(date +%Y%m%d_%H%M%S).gitsetu-v2.vault"
    fi
    [[ "$out_file" != *[[:cntrl:]]* && "$out_file" != *\\* ]] || {
        print_error "Vault output path contains unsafe characters."
        return 1
    }

    local out_dir out_base
    out_dir=$(dirname "$out_file") || return 1
    out_base=$(basename "$out_file") || return 1
    local out_redirect=0
    if [[ "$out_dir" != "." ]]; then
        _vault_path_has_redirect_component "$out_dir" || out_redirect=$?
        [[ "$out_redirect" -eq 1 ]] || {
            print_error "Refusing redirected vault output directory: $out_dir"
            return 1
        }
    fi
    if [[ "$out_dir" == "." ]]; then
        out_dir=$(pwd -P) || return 1
    else
        out_dir=$(cd "$out_dir" 2>/dev/null && pwd -P) || return 1
    fi
    [[ -d "$out_dir" && -O "$out_dir" && -n "$out_base" && "$out_base" != "." && "$out_base" != ".." ]] || {
        print_error "Vault output directory does not exist: $out_dir"
        return 1
    }
    out_file="$out_dir/$out_base"
    if [[ -e "$out_file" || -L "$out_file" ]]; then
        print_error "Refusing to overwrite existing vault: $out_file"
        return 1
    fi

    local acquired=0
    if type acquire_lock >/dev/null 2>&1; then
        acquire_lock || return 1
        acquired=1
    fi

    if ! _vault_load_registry_v2 "$GITSETU_PROFILES_CONF" "$GITSETU_PROFILES_DIR"; then
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi

    local temp_dir payload_root archive_path output_tmp vault_rc=1
    temp_dir=$(_vault_private_temp_dir "gitsetu-vault-backup") || {
        print_error "Could not create private backup staging directory."
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    }
    GITSETU_CLEANUP_DIRS+=("$temp_dir")
    _VAULT_ACTIVE_TEMP="$temp_dir"
    payload_root="$temp_dir/payload"
    archive_path="$temp_dir/payload.tar.gz"
    (umask 077 && mkdir -p "$payload_root" "$temp_dir/list") 2>/dev/null || {
        print_error "Could not initialize private backup staging."
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    }

    if ! _vault_stage_backup_payload "$payload_root"; then
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi
    if ! (umask 077 && tar -czf "$archive_path" -C "$payload_root" gitsetu-v2) 2>/dev/null; then
        print_error "Failed to create the authenticated vault payload."
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi
    if ! _vault_validate_archive_listing "$archive_path" "$temp_dir/list"; then
        print_error "Internal vault payload failed archive safety validation."
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi

    printf >&2 "  %bLocking Vault%b\n" "$BOLD" "$RESET"
    if ! _vault_read_new_password; then
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi

    output_tmp=$(umask 077 && mktemp "$out_dir/.${out_base}.tmp.XXXXXX" 2>/dev/null) || {
        print_error "Could not create a private output file in $out_dir."
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    }
    if ! _vault_write_authenticated_vault "$output_tmp" "$archive_path" "$_VAULT_ROOT_KEY" "$temp_dir"; then
        rm -f "$output_tmp" 2>/dev/null || true
        print_error "Authenticated vault encryption failed."
        _VAULT_ROOT_KEY=""
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi
    _VAULT_ROOT_KEY=""
    if [[ -e "$out_file" || -L "$out_file" ]]; then
        rm -f "$output_tmp" 2>/dev/null || true
        print_error "Vault destination appeared during backup; refusing to overwrite it."
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi
    if ! mv "$output_tmp" "$out_file" 2>/dev/null; then
        rm -f "$output_tmp" 2>/dev/null || true
        print_error "Could not atomically install vault: $out_file"
        _VAULT_ACTIVE_TEMP=""
        rm -rf "$temp_dir" 2>/dev/null || true
        [[ "$acquired" -eq 1 ]] && release_lock
        return 1
    fi
    chmod 600 "$out_file" 2>/dev/null || true
    print_success "Authenticated v2 vault created successfully: $out_file"
    vault_rc=0
    _VAULT_ACTIVE_TEMP=""
    rm -rf "$temp_dir" 2>/dev/null || true
    [[ "$acquired" -eq 1 ]] && release_lock
    return "$vault_rc"
}

# ------------------------------------------------------------------------------
# Restore transaction
# ------------------------------------------------------------------------------
_VAULT_TXN_KEY_DESTINATIONS=()
_VAULT_TXN_KEY_SOURCES=()
_VAULT_TXN_KEY_MODES=()
_VAULT_TXN_KEY_OLD=()
_VAULT_TXN_KEY_ACTIVE=()
_VAULT_TXN_STATE_DIR=""

_vault_transaction_is_safe() {
    local txn="${1:-}"
    [[ -n "$txn" && -d "$txn" && ! -L "$txn" && -O "$txn" && "$txn" != *[[:cntrl:]]* ]] || return 1
    _vault_validate_canonical_state_path "$txn" || return 1
}

_vault_write_recovery_marker() {
    local txn="${1:-}" state="${2:-active}" marker tmp
    _vault_transaction_is_safe "$txn" || return 1
    marker="$txn/RECOVERY_REQUIRED"
    tmp="$txn/.RECOVERY_REQUIRED.tmp.$$"
    if [[ "$state" != "active" && "$state" != "rollback-incomplete" ]]; then
        state="active"
    fi
    (umask 077 && printf '%s\n' \
        "state=$state" \
        "This private directory contains the restore transaction and snapshots." \
        "Do not delete it until recovery is complete." > "$tmp" &&
        chmod 600 "$tmp" 2>/dev/null &&
        mv -f "$tmp" "$marker" 2>/dev/null) || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    return 0
}

_vault_prepare_transaction() {
    local transaction_dir="$1" extracted_root="$2" archive_root="$3"
    (umask 077 && mkdir -p "$transaction_dir/new-state" "$transaction_dir/old-state" \
        "$transaction_dir/old-global" "$transaction_dir/old-keys") || return 1
    chmod 700 "$transaction_dir" "$transaction_dir/new-state" "$transaction_dir/old-state" \
        "$transaction_dir/old-global" "$transaction_dir/old-keys" 2>/dev/null || return 1

    _vault_copy_regular "$archive_root/state/profiles.conf" "$transaction_dir/new-state/profiles.conf" 600 || return 1
    (umask 077 && mkdir -p "$transaction_dir/new-state/profiles" "$transaction_dir/new-state/hooks") || return 1
    local i
    for (( i=0; i<_VAULT_MANIFEST_COUNT; i++ )); do
        _vault_copy_regular "$archive_root/${_VAULT_MANIFEST_CONFIGS[$i]}" \
            "$transaction_dir/new-state/profiles/${PROFILE_LABELS[$i]}.gitconfig" 600 || return 1
    done
    if [[ "$_VAULT_MANIFEST_SSH" -eq 1 ]]; then
        _vault_copy_regular "$archive_root/state/profiles/ssh_config" \
            "$transaction_dir/new-state/profiles/ssh_config" 600 || return 1
    fi
    if [[ "$_VAULT_MANIFEST_HOOK" -eq 1 ]]; then
        _vault_copy_regular "$archive_root/state/hooks/pre-commit" \
            "$transaction_dir/new-state/hooks/pre-commit" 700 || return 1
    fi
    if [[ "$_VAULT_MANIFEST_TOKENS" -eq 1 ]]; then
        _vault_copy_regular "$archive_root/state/.tokens" \
            "$transaction_dir/new-state/.tokens" 600 || return 1
    fi
    (umask 077 && mkdir -p "$transaction_dir/new-state/backups") || return 1
    return 0
}

_vault_snapshot_globals() {
    local txn="$1" gitconfig="$HOME/.gitconfig" sshconfig="$HOME/.ssh/config"
    (umask 077 && mkdir -p "$txn/old-global") 2>/dev/null || return 1
    if [[ -e "$gitconfig" || -L "$gitconfig" ]]; then
        [[ -f "$gitconfig" && ! -L "$gitconfig" ]] || return 1
        _vault_copy_regular "$gitconfig" "$txn/old-global/gitconfig" 600 || return 1
        printf 'present\n' > "$txn/old-global/gitconfig.state" || return 1
    else
        printf 'absent\n' > "$txn/old-global/gitconfig.state" || return 1
    fi
    if [[ -e "$sshconfig" || -L "$sshconfig" ]]; then
        [[ -f "$sshconfig" && ! -L "$sshconfig" ]] || return 1
        _vault_copy_regular "$sshconfig" "$txn/old-global/sshconfig" 600 || return 1
        printf 'present\n' > "$txn/old-global/sshconfig.state" || return 1
    else
        printf 'absent\n' > "$txn/old-global/sshconfig.state" || return 1
    fi
    return 0
}

_vault_move_state_side() {
    local txn="$1" name="$2" source="$3" destination="$4"
    if [[ -e "$source" || -L "$source" ]]; then
        if [[ "$name" == "profiles" || "$name" == "hooks" ]]; then
            [[ -d "$source" && ! -L "$source" ]] || return 1
        else
            [[ -f "$source" && ! -L "$source" ]] || return 1
        fi
        if ! mv "$source" "$destination" 2>/dev/null; then
            return 1
        fi
        printf 'present\n' > "$txn/old-state/$name.state" || return 1
    else
        printf 'absent\n' > "$txn/old-state/$name.state" || return 1
    fi
    return 0
}

_vault_state_path() {
    case "$1" in
        profiles.conf) printf '%s' "$GITSETU_PROFILES_CONF" ;;
        profiles) printf '%s' "$GITSETU_PROFILES_DIR" ;;
        hooks) printf '%s' "$GITSETU_HOOKS_DIR" ;;
        .tokens) printf '%s' "$GITSETU_CONFIG_DIR/.tokens" ;;
    esac
}

_vault_commit_state() {
    local txn="$1" name current old new
    for name in profiles.conf profiles hooks .tokens; do
        current=$(_vault_state_path "$name") || return 1
        old="$txn/old-state/$name"
        new="$txn/new-state/$name"
        _vault_move_state_side "$txn" "$name" "$current" "$old" || return 1
        if [[ -e "$new" || -L "$new" ]]; then
            if [[ "$name" == "profiles" || "$name" == "hooks" ]]; then
                [[ -d "$new" && ! -L "$new" ]] || return 1
            else
                [[ -f "$new" && ! -L "$new" ]] || return 1
            fi
            if ! mv "$new" "$current" 2>/dev/null; then
                return 1
            fi
        fi
    done
    return 0
}

_vault_prepare_key_transaction() {
    local txn="$1" i destination source mode old old_state active
    _VAULT_TXN_KEY_DESTINATIONS=()
    _VAULT_TXN_KEY_SOURCES=()
    _VAULT_TXN_KEY_MODES=()
    _VAULT_TXN_KEY_OLD=()
    _VAULT_TXN_KEY_ACTIVE=()
    local combined_count=$((_VAULT_MANIFEST_COUNT * 2))
    for (( i=0; i<combined_count; i++ )); do
        if [[ "$i" -lt "$_VAULT_MANIFEST_COUNT" ]]; then
            destination="${_VAULT_RESTORE_KEY_TARGETS[$i]}"
            source="${_VAULT_RESTORE_KEY_SOURCES[$i]}"
            mode=600
        else
            local key_i=$((i - _VAULT_MANIFEST_COUNT))
            destination="${_VAULT_RESTORE_KEY_TARGETS[$key_i]}.pub"
            source="${_VAULT_RESTORE_PUB_SOURCES[$key_i]}"
            mode=644
        fi
        old="$txn/old-keys/$i"
        _VAULT_TXN_KEY_DESTINATIONS+=("$destination")
        _VAULT_TXN_KEY_SOURCES+=("$source")
        _VAULT_TXN_KEY_MODES+=("$mode")
        _VAULT_TXN_KEY_OLD+=("$old")
        if [[ -z "$source" ]]; then
            _VAULT_TXN_KEY_ACTIVE+=(0)
            continue
        fi
        _vault_validate_key_destination "$destination" || return 1
        if [[ -e "$destination" || -L "$destination" ]]; then
            [[ -f "$destination" && ! -L "$destination" ]] || return 1
            _vault_copy_regular "$destination" "$old" "$mode" || return 1
            old_state="present"
        else
            old_state="absent"
        fi
        printf '%s\n' "$old_state" > "$txn/old-keys/$i.state" || return 1
        _VAULT_TXN_KEY_ACTIVE+=(1)
        active=1
    done
    return 0
}

_vault_install_key_transaction() {
    local i count destination source mode parent temp_destination
    count=${#_VAULT_TXN_KEY_DESTINATIONS[@]}
    for (( i=0; i<count; i++ )); do
        destination="${_VAULT_TXN_KEY_DESTINATIONS[$i]}"
        source="${_VAULT_TXN_KEY_SOURCES[$i]}"
        mode="${_VAULT_TXN_KEY_MODES[$i]}"
        [[ -n "$source" ]] || continue
        _vault_validate_key_destination "$destination" || return 1
        parent=$(dirname "$destination") || return 1
        if [[ ! -d "$parent" ]]; then
            (umask 077 && mkdir -p "$parent") 2>/dev/null || return 1
        fi
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
        temp_destination="${destination}.gitsetu-restore.$$.$i"
        rm -f "$temp_destination" 2>/dev/null || true
        if ! _vault_copy_file_private "$source" "$temp_destination"; then
            return 1
        fi
        chmod "$mode" "$temp_destination" 2>/dev/null || {
            rm -f "$temp_destination" 2>/dev/null || true
            return 1
        }
        if ! mv -f "$temp_destination" "$destination" 2>/dev/null; then
            rm -f "$temp_destination" 2>/dev/null || true
            return 1
        fi
    done
    return 0
}

_vault_restore_global_file() {
    local txn="$1" which="$2" destination source state
    if [[ "$which" == "gitconfig" ]]; then
        destination="$HOME/.gitconfig"
        source="$txn/old-global/gitconfig"
        state="$txn/old-global/gitconfig.state"
    else
        destination="$HOME/.ssh/config"
        source="$txn/old-global/sshconfig"
        state="$txn/old-global/sshconfig.state"
    fi

    # A state file is written after the snapshot copy.  If that write failed,
    # the private old-global file is still authoritative and must be restored.
    if [[ -f "$state" ]]; then
        if grep -q '^present$' "$state" 2>/dev/null; then
            [[ -f "$source" && ! -L "$source" ]] || return 1
        elif grep -q '^absent$' "$state" 2>/dev/null; then
            [[ ! -e "$source" && ! -L "$source" ]] || return 1
        else
            return 1
        fi
    elif [[ -e "$source" || -L "$source" ]]; then
        [[ -f "$source" && ! -L "$source" ]] || return 1
    else
        return 0
    fi
    if [[ -L "$destination" ]]; then
        return 1
    fi
    if [[ -f "$state" ]] && grep -q '^present$' "$state" 2>/dev/null; then
        _vault_copy_regular "$source" "$destination" 600 || return 1
    else
        rm -f "$destination" 2>/dev/null || true
    fi
    return 0
}

_vault_rollback_transaction() {
    local txn="${1:-}" failed=0 name current old_state
    _vault_transaction_is_safe "$txn" || return 1
    _VAULT_TXN_STATE_DIR="$txn"

    local i count
    count=${#_VAULT_TXN_KEY_DESTINATIONS[@]}
    for (( i=count-1; i>=0; i-- )); do
        [[ "${_VAULT_TXN_KEY_ACTIVE[$i]:-0}" -eq 1 ]] || continue
        current="${_VAULT_TXN_KEY_DESTINATIONS[$i]}"
        local old_key="${_VAULT_TXN_KEY_OLD[$i]}"
        local key_state="$txn/old-keys/$i.state"
        if [[ -f "$key_state" ]]; then
            if grep -q '^present$' "$key_state" 2>/dev/null; then
                [[ -f "$old_key" && ! -L "$old_key" ]] || { failed=1; continue; }
            elif ! grep -q '^absent$' "$key_state" 2>/dev/null; then
                failed=1
                continue
            fi
        elif [[ -e "$old_key" || -L "$old_key" ]]; then
            [[ -f "$old_key" && ! -L "$old_key" ]] || { failed=1; continue; }
        else
            failed=1
            continue
        fi
        if [[ -L "$current" ]]; then
            failed=1
            continue
        fi
        rm -f "$current" 2>/dev/null || failed=1
        if [[ -f "$old_key" && ! -L "$old_key" ]]; then
            _vault_copy_regular "$old_key" "$current" "${_VAULT_TXN_KEY_MODES[$i]}" || failed=1
        fi
    done

    for name in .tokens hooks profiles profiles.conf; do
        current=$(_vault_state_path "$name") || { failed=1; continue; }
        local old_path="$txn/old-state/$name"
        old_state="$txn/old-state/$name.state"
        if [[ -f "$old_state" ]]; then
            if grep -q '^present$' "$old_state" 2>/dev/null; then
                if [[ "$name" == "profiles" || "$name" == "hooks" ]]; then
                    [[ -d "$old_path" && ! -L "$old_path" ]] || { failed=1; continue; }
                else
                    [[ -f "$old_path" && ! -L "$old_path" ]] || { failed=1; continue; }
                fi
            elif ! grep -q '^absent$' "$old_state" 2>/dev/null; then
                failed=1
                continue
            fi
        elif [[ -e "$old_path" || -L "$old_path" ]]; then
            if [[ "$name" == "profiles" || "$name" == "hooks" ]]; then
                [[ -d "$old_path" && ! -L "$old_path" ]] || { failed=1; continue; }
            else
                [[ -f "$old_path" && ! -L "$old_path" ]] || { failed=1; continue; }
            fi
        else
            # No snapshot was recorded; this state was not touched.
            continue
        fi
        if [[ -L "$current" ]]; then
            failed=1
            continue
        fi
        if [[ "$name" == "profiles" || "$name" == "hooks" ]]; then
            rm -rf "$current" 2>/dev/null || failed=1
        else
            rm -f "$current" 2>/dev/null || failed=1
        fi
        if [[ -e "$old_path" || -L "$old_path" ]]; then
            mv "$old_path" "$current" 2>/dev/null || failed=1
        fi
    done
    _vault_restore_global_file "$txn" gitconfig || failed=1
    _vault_restore_global_file "$txn" sshconfig || failed=1
    return "$failed"
}

_vault_regenerate_restored_state() {
    local had_hook="$1"
    load_profiles "$GITSETU_PROFILES_CONF" || return 1
    write_global_gitconfig || return 1

    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        write_profile_gitconfig "${PROFILE_LABELS[$i]}" "${PROFILE_NAMES[$i]}" \
            "${PROFILE_EMAILS[$i]}" "${PROFILE_SIGNS[$i]}" "${PROFILE_KEYS[$i]}" \
            "${PROFILE_PROVIDERS[$i]}" "${PROFILE_USERS[$i]:-}" || return 1
    done
    write_ssh_config || return 1

    if [[ "$had_hook" -eq 1 ]] && type install_guard >/dev/null 2>&1; then
        install_guard || return 1
    else
        local hooks_path
        hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)
        hooks_path="${hooks_path//\\//}"
        local target="${GITSETU_HOOKS_DIR//\\//}"
        if [[ "$hooks_path" == "$target" ]]; then
            git config --global --unset-all core.hooksPath 2>/dev/null || true
        fi
    fi
    chmod 700 "$GITSETU_HOOKS_DIR" 2>/dev/null || true
    [[ -f "$GITSETU_HOOKS_DIR/pre-commit" ]] && chmod 700 "$GITSETU_HOOKS_DIR/pre-commit" 2>/dev/null || true
    chmod 700 "$GITSETU_PROFILES_DIR" 2>/dev/null || true
    chmod 600 "$GITSETU_PROFILES_CONF" 2>/dev/null || true
    return 0
}

_vault_signal_handler() {
    local txn="${GITSETU_VAULT_ACTIVE_TRANSACTION:-}" rollback_failed=0
    if [[ -n "$txn" && -d "$txn" ]]; then
        if _vault_rollback_transaction "$txn"; then
            rm -rf "$txn" 2>/dev/null || true
        else
            _vault_write_recovery_marker "$txn" "rollback-incomplete" || true
            print_error "Restore interrupted; automatic rollback was incomplete."
            print_error "Private recovery snapshot remains at: $txn"
            rollback_failed=1
        fi
    fi
    [[ -n "${_VAULT_ACTIVE_TEMP:-}" ]] && rm -rf "$_VAULT_ACTIVE_TEMP" 2>/dev/null || true
    type release_lock >/dev/null 2>&1 && release_lock >/dev/null 2>&1 || true
    if [[ "$rollback_failed" -eq 0 ]]; then
        print_error "Restore interrupted; the previous state was rolled back."
    fi
    exit 130
}

_vault_restore_discard_staging() {
    local temp_dir="${1:-}" acquired="${2:-0}"
    _VAULT_ROOT_KEY=""
    _VAULT_ACTIVE_TEMP=""
    [[ -z "$temp_dir" ]] || rm -rf "$temp_dir" 2>/dev/null || true
    if [[ "$acquired" -eq 1 ]] && type release_lock >/dev/null 2>&1; then
        release_lock || true
    fi
}

_vault_finalize_committed_restore() {
    local txn="${1:-}" temp_dir="${2:-}" acquired="${3:-0}"
    local cleanup_failed=0

    # From this point onward the live state is committed.  Clear the rollback
    # target before cleanup so a cleanup error can never be mistaken for a
    # pre-commit failure and trigger restoration of stale snapshots.
    GITSETU_VAULT_ACTIVE_TRANSACTION=""

    if ! rm -rf "$txn" 2>/dev/null || [[ -e "$txn" || -L "$txn" ]]; then
        print_error "Could not remove private restore transaction data: $txn"
        cleanup_failed=1
    fi
    if [[ "$acquired" -eq 1 ]] && ! release_lock; then
        print_error "Could not release the state lock after committed restore."
        cleanup_failed=1
    fi
    _VAULT_ROOT_KEY=""
    _VAULT_ACTIVE_TEMP=""
    if ! rm -rf "$temp_dir" 2>/dev/null || [[ -e "$temp_dir" || -L "$temp_dir" ]]; then
        print_error "Could not remove private restore staging data: $temp_dir"
        cleanup_failed=1
    fi

    if [[ "$cleanup_failed" -ne 0 ]]; then
        print_error "Authenticated v2 vault restored successfully, but post-commit cleanup failed."
        print_error "The committed restore state was not rolled back."
        return 1
    fi
    print_success "Authenticated v2 vault restored successfully."
    return 0
}

_vault_restore_abort_transaction() {
    local txn="${1:-}" temp_dir="${2:-}" acquired="${3:-0}"
    local rollback_ok=0
    if [[ -n "$txn" && -d "$txn" && ! -L "$txn" ]] && _vault_rollback_transaction "$txn"; then
        rm -rf "$txn" 2>/dev/null || true
        print_warning "Restore failed; the previous state was restored."
    else
        if [[ -n "$txn" && -d "$txn" && ! -L "$txn" ]]; then
            _vault_write_recovery_marker "$txn" "rollback-incomplete" || true
        fi
        if [[ -n "$txn" ]]; then
            print_error "Restore failed and automatic rollback was incomplete. Private recovery data remains at: $txn"
        else
            print_error "Restore failed before a private recovery snapshot was created."
        fi
        rollback_ok=1
    fi
    GITSETU_VAULT_ACTIVE_TRANSACTION=""
    _vault_restore_discard_staging "$temp_dir" "$acquired"
    return "$rollback_ok"
}

# ------------------------------------------------------------------------------
# cmd_restore — Authenticate, prevalidate, then transactionally restore
# ------------------------------------------------------------------------------
cmd_restore() {
    _vault_ensure_runtime_constants
    local in_file="${1:-}"
    if [[ $# -ne 1 || -z "$in_file" ]]; then
        print_error "Usage: gitsetu restore <vault_file>"
        return 1
    fi
    case "$in_file" in
        -*) print_error "Unknown restore option: $in_file"; return 1 ;;
    esac
    _vault_validate_runtime || return 1
    if [[ ! -f "$in_file" || -L "$in_file" || ! -r "$in_file" ]]; then
        print_error "Vault file is missing, unreadable, or not a regular file: $in_file"
        return 1
    fi

    local temp_dir snapshot archive_payload archive_root extract_dir acquired=0
    temp_dir=$(_vault_private_temp_dir "gitsetu-vault-restore") || {
        print_error "Could not create private restore staging directory."
        return 1
    }
    GITSETU_CLEANUP_DIRS+=("$temp_dir")
    _VAULT_ACTIVE_TEMP="$temp_dir"
    snapshot="$temp_dir/vault.input"
    archive_payload="$temp_dir/payload.tar.gz"
    archive_root="$temp_dir/extracted/gitsetu-v2"
    extract_dir="$temp_dir/extracted"

    if ! (umask 077 && mkdir -p "$extract_dir" "$temp_dir/list") 2>/dev/null; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Could not initialize private restore staging."
        return 1
    fi
    if ! _vault_copy_file_private "$in_file" "$snapshot"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Could not stage the vault in private storage."
        return 1
    fi
    if ! _vault_parse_header "$snapshot"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Unsupported, malformed, truncated, or non-v2 vault."
        return 1
    fi

    printf >&2 "  %bUnlocking Vault%b\n" "$BOLD" "$RESET"
    if ! _vault_read_restore_password; then
        _vault_restore_discard_staging "$temp_dir" 0
        return 1
    fi
    if ! _vault_authenticate_envelope "$snapshot" "$_VAULT_ROOT_KEY" "$temp_dir"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault authentication failed: wrong password, tampering, or corruption."
        return 1
    fi
    if ! _vault_decrypt_stream "$_VAULT_ROOT_KEY" "$_VAULT_ENC_SALT" "$_VAULT_IV" \
        "$temp_dir/envelope.payload" "$archive_payload"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Authenticated vault could not be decrypted."
        return 1
    fi
    _VAULT_ROOT_KEY=""

    if ! _vault_validate_archive_listing "$archive_payload" "$temp_dir/list"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault payload contains an unsupported archive type, unsafe path, duplicate member, or oversized entry."
        return 1
    fi
    if ! tar -xzf "$archive_payload" -C "$extract_dir" --no-same-owner --no-same-permissions 2>/dev/null; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault payload extraction failed."
        return 1
    fi

    # The authenticated manifest declares the source HOME.  Parse it before the
    # v2 registry loader, then map all managed SSH paths into the target HOME.
    if ! _vault_read_manifest "$archive_root/manifest"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault manifest is malformed or uses an unsupported source-home policy."
        return 1
    fi
    local saved_profiles_dir="$GITSETU_PROFILES_DIR"
    GITSETU_PROFILES_DIR="$archive_root/state/profiles"
    if ! load_profiles "$archive_root/state/profiles.conf"; then
        GITSETU_PROFILES_DIR="$saved_profiles_dir"
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Restored profile registry is not a valid v2 registry."
        return 1
    fi
    GITSETU_PROFILES_DIR="$saved_profiles_dir"
    if ! _vault_rewrite_staged_registry_for_target "$archive_root"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault contains nonportable managed paths; restore was refused."
        return 1
    fi
    if ! _vault_validate_extracted_tree "$extract_dir"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault payload manifest or file allowlist validation failed."
        return 1
    fi
    if ! _vault_validate_restore_keys "$archive_root"; then
        _vault_restore_discard_staging "$temp_dir" 0
        print_error "Vault key destinations are unsafe, duplicate, non-regular, or inconsistent."
        return 1
    fi

    if type acquire_lock >/dev/null 2>&1; then
        if ! acquire_lock; then
            _vault_restore_discard_staging "$temp_dir" 0
            print_error "Could not acquire the state mutation lock."
            return 1
        fi
        acquired=1
    fi

    local config_parent transaction_dir parent_redirect=0
    config_parent=$(dirname "$GITSETU_CONFIG_DIR") || {
        _vault_restore_discard_staging "$temp_dir" "$acquired"
        return 1
    }
    [[ -d "$config_parent" && -O "$config_parent" ]] || {
        _vault_restore_discard_staging "$temp_dir" "$acquired"
        print_error "Restore parent is not a user-owned directory: $config_parent"
        return 1
    }
    _vault_path_has_redirect_component "$config_parent" || parent_redirect=$?
    if [[ "$parent_redirect" -ne 1 ]]; then
        _vault_restore_discard_staging "$temp_dir" "$acquired"
        print_error "Restore parent is redirected or non-canonical: $config_parent"
        return 1
    fi
    transaction_dir=$(umask 077 && mktemp -d "$config_parent/.gitsetu-restore.XXXXXX" 2>/dev/null) || {
        _vault_restore_discard_staging "$temp_dir" "$acquired"
        print_error "Could not create a private restore transaction directory."
        return 1
    }
    chmod 700 "$transaction_dir" 2>/dev/null || {
        rm -rf "$transaction_dir" 2>/dev/null || true
        _vault_restore_discard_staging "$temp_dir" "$acquired"
        print_error "Could not secure the restore transaction directory."
        return 1
    }
    if ! _vault_write_recovery_marker "$transaction_dir" "active"; then
        rm -rf "$transaction_dir" 2>/dev/null || true
        _vault_restore_discard_staging "$temp_dir" "$acquired"
        print_error "Could not initialize restore recovery metadata."
        return 1
    fi
    GITSETU_VAULT_ACTIVE_TRANSACTION="$transaction_dir"

    if [[ -e "$GITSETU_CONFIG_DIR" && ! -d "$GITSETU_CONFIG_DIR" ]]; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Refusing to restore over non-directory config path: $GITSETU_CONFIG_DIR"
        return 1
    fi
    if [[ "$GITSETU_CONFIG_DIR" == "/" || "$GITSETU_CONFIG_DIR" == "$HOME" ]]; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Refusing unsafe config restore target: $GITSETU_CONFIG_DIR"
        return 1
    fi
    if ! (umask 077 && mkdir -p "$GITSETU_CONFIG_DIR") 2>/dev/null; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        return 1
    fi
    if ! _vault_snapshot_globals "$transaction_dir"; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Could not snapshot global configuration for rollback."
        return 1
    fi
    if ! _vault_prepare_transaction "$transaction_dir" "$extract_dir" "$archive_root"; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Could not prepare restored state for transaction."
        return 1
    fi
    if ! _vault_prepare_key_transaction "$transaction_dir"; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Could not prepare key replacements for transaction."
        return 1
    fi
    if ! _vault_commit_state "$transaction_dir"; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Could not commit restored registry state."
        return 1
    fi
    if ! _vault_install_key_transaction; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Could not commit restored key files."
        return 1
    fi
    if ! _vault_regenerate_restored_state "$_VAULT_MANIFEST_HOOK"; then
        _vault_restore_abort_transaction "$transaction_dir" "$temp_dir" "$acquired"
        print_error "Could not regenerate global Git/SSH state; rolling back."
        return 1
    fi

    _vault_finalize_committed_restore "$transaction_dir" "$temp_dir" "$acquired"
}
