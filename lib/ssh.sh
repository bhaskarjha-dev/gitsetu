#!/usr/bin/env bash
# lib/ssh.sh — SSH key generation and ~/.ssh/config management
#
# Generates Ed25519 keys per profile and creates host alias blocks
# in ~/.ssh/config for the clone workflow.
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# Path and OpenSSH syntax helpers
# ------------------------------------------------------------------------------

_ssh_reject_multiline() {
    local label="$1" value="$2"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        if declare -f print_error >/dev/null 2>&1; then
            print_error "$label cannot contain CR or LF."
        else
            printf '  ERROR: %s cannot contain CR or LF.\n' "$label" >&2
        fi
        return 1
    fi
}

# Expand a user-supplied key path exactly once. Relative paths are resolved
# against the invoking directory, never the repository/profile registry later.
_ssh_normalize_key_path() {
    local key_path="${1-}"
    _ssh_reject_multiline "SSH key path" "$key_path" || return 1
    [[ -n "$key_path" ]] || return 1

    if [[ "$key_path" != "~" && "$key_path" != "~/"* && "$key_path" != /* && "$key_path" != [a-zA-Z]:/* ]]; then
        key_path="$PWD/$key_path"
    fi
    if declare -f normalize_path >/dev/null 2>&1; then
        normalize_path "$key_path"
    else
        printf '%s' "${key_path//\\//}"
    fi
}

# Prefer a home-relative path only when the path really is below $HOME. An
# arbitrary external path that merely contains ".ssh" must remain absolute.
_ssh_portable_path() {
    local path="$1"
    if [[ "$path" == "$HOME" ]]; then
        printf '~'
    elif [[ "$path" == "$HOME/"* ]]; then
        printf '~/%s' "${path#"$HOME"/}"
    else
        printf '%s' "$path"
    fi
}

# Quote one OpenSSH config argument. Percent is escaped because OpenSSH expands
# % tokens in IdentityFile; backslashes and quotes are escaped before wrapping.
_ssh_quote_token() {
    local value="$1"
    if [[ "$value" != *[[:space:]\\\"%#]* ]]; then
        printf '%s' "$value"
        return 0
    fi
    value="${value//%/%%}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

_ssh_valid_host_token() {
    local value="$1"
    # Host/provider values are DNS names, IPv4/IPv6 literals, or the fixed
    # ssh.github.com fallback. Shell metacharacters are rejected rather than
    # interpreted as configuration.
    [[ "$value" =~ ^[A-Za-z0-9._:%-]+$ ]]
}

# Reject symlink/reparse-like components before following a path for mkdir,
# chmod, or file replacement. Existing regular-file components are also errors.
_ssh_is_ntfs() {
    [[ "${GITSETU_OS:-}" == "gitbash" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ]]
}

# Git Bash's fsutil.exe is a Win32 process. Cache only bounded, per-process
# observations of existing path components. Final mutation targets are checked
# uncached immediately before replacement, while cheap symlink checks remain
# active on every cache hit; a cached reparse result always remains fail-closed.
_SSH_REPARSE_CACHE_PATHS=()
_SSH_REPARSE_CACHE_RESULTS=()
_SSH_REPARSE_CACHE_SIZE=0

_ssh_reparse_cache_limit() {
    local limit="${GITSETU_SSH_REPARSE_CACHE_MAX:-256}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=256
    (( limit < 1 )) && limit=1
    (( limit > 1024 )) && limit=1024
    printf '%s' "$limit"
}

_ssh_reparse_cache_reset() {
    _SSH_REPARSE_CACHE_PATHS=()
    _SSH_REPARSE_CACHE_RESULTS=()
    _SSH_REPARSE_CACHE_SIZE=0
}

_ssh_reparse_cache_lookup() {
    local context="${GITSETU_OS:-unknown}:${OSTYPE:-}"
    local key="$context|${1//\\//}" i
    for (( i=0; i<${#_SSH_REPARSE_CACHE_PATHS[@]}; i++ )); do
        if [[ "${_SSH_REPARSE_CACHE_PATHS[$i]}" == "$key" ]]; then
            if [[ "${_SSH_REPARSE_CACHE_RESULTS[$i]}" == "0" ]]; then
                _SSH_REPARSE_CACHE_STATUS=0
                return 0
            fi
            # A POSIX symlink can appear without a filesystem helper call;
            # honor that cheap check before reusing an ordinary observation.
            if [[ -L "$1" ]]; then
                _SSH_REPARSE_CACHE_STATUS=0
                return 0
            fi
            _SSH_REPARSE_CACHE_STATUS=1
            return 0
        fi
    done
    return 1
}

_ssh_reparse_cache_store() {
    local context="${GITSETU_OS:-unknown}:${OSTYPE:-}"
    local key="$context|${1//\\//}" result="$2" limit
    local i

    for (( i=0; i<${#_SSH_REPARSE_CACHE_PATHS[@]}; i++ )); do
        if [[ "${_SSH_REPARSE_CACHE_PATHS[$i]}" == "$key" ]]; then
            _SSH_REPARSE_CACHE_RESULTS[i]="$result"
            return 0
        fi
    done

    limit=$(_ssh_reparse_cache_limit)
    if (( ${#_SSH_REPARSE_CACHE_PATHS[@]} >= limit )); then
        _SSH_REPARSE_CACHE_PATHS=("${_SSH_REPARSE_CACHE_PATHS[@]:1}")
        _SSH_REPARSE_CACHE_RESULTS=("${_SSH_REPARSE_CACHE_RESULTS[@]:1}")
    fi
    _SSH_REPARSE_CACHE_PATHS+=("$key")
    _SSH_REPARSE_CACHE_RESULTS+=("$result")
    _SSH_REPARSE_CACHE_SIZE=${#_SSH_REPARSE_CACHE_PATHS[@]}
}

_ssh_reparse_probe_cached() {
    local path="$1" status
    if ! _ssh_is_ntfs || ! command -v cygpath >/dev/null 2>&1 || ! command -v fsutil.exe >/dev/null 2>&1; then
        _ssh_is_reparse_point "$path"
        return $?
    fi
    if _ssh_reparse_cache_lookup "$path"; then
        return "$_SSH_REPARSE_CACHE_STATUS"
    fi
    _ssh_is_reparse_point "$path"
    status=$?
    if [[ "$status" -eq 0 || "$status" -eq 1 ]]; then
        _ssh_reparse_cache_store "$path" "$status"
    fi
    return "$status"
}

_ssh_is_reparse_point() {
    local path="$1" windows_path status
    [[ -L "$path" ]] && return 0
    if _ssh_is_ntfs && command -v cygpath >/dev/null 2>&1 && command -v fsutil.exe >/dev/null 2>&1; then
        # Do not ask fsutil about a path that does not exist yet. For an
        # existing path, distinguish "ordinary path" (1) from an
        # indeterminate ACL/device error (2) so callers can fail closed.
        [[ -e "$path" ]] || return 1
        windows_path=$(cygpath -w "$path" 2>/dev/null) || return 2
        if fsutil.exe reparsepoint query "$windows_path" >/dev/null 2>&1; then
            return 0
        else
            status=$?
        fi
        [[ "$status" -eq 1 ]] && return 1
        return 2
    fi
    return 1
}

_ssh_assert_no_symlink_components() {
    local path="${1%/}" rest current component
    local allow_final_file=0
    local revalidate_final=0
    local revalidate_all=0
    if [[ $# -ge 2 ]]; then
        allow_final_file="$2"
    fi
    if [[ $# -ge 3 ]]; then
        revalidate_final="$3"
    elif [[ "$allow_final_file" == "1" ]]; then
        revalidate_final=1
    fi
    if [[ $# -ge 4 ]]; then
        revalidate_all="$4"
    fi
    [[ -n "$path" ]] || return 1
    case "$path" in
        [A-Za-z]:/*)
            current="${path%%:*}/"
            rest="${path#?:}"
            ;;
        /*)
            current="/"
            rest="${path#/}"
            ;;
        *)
            path="$PWD/$path"
            current="/"
            rest="${path#/}"
            ;;
    esac
    while [[ -n "$rest" ]]; do
        local is_final=0 redirect_status=0
        component="${rest%%/*}"
        if [[ "$rest" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
            is_final=1
        fi
        [[ -n "$component" ]] || continue
        [[ "$component" != "." && "$component" != ".." ]] || return 1
        if [[ "$current" == "/" ]]; then
            current="/$component"
        else
            current="${current%/}/$component"
        fi
        if [[ "$revalidate_all" == "1" || ( "$is_final" -eq 1 && "$revalidate_final" == "1" ) ]]; then
            if _ssh_is_reparse_point "$current"; then
                return 1
            else
                redirect_status=$?
            fi
        else
            if _ssh_reparse_probe_cached "$current"; then
                return 1
            else
                redirect_status=$?
            fi
        fi
        [[ "$redirect_status" -ne 2 ]] || return 1
        if [[ "$allow_final_file" == "1" && "$current" == "$path" && -f "$current" ]]; then
            continue
        fi
        [[ ! -e "$current" || -d "$current" ]] || return 1
    done
    return 0
}

_ssh_assert_private_directory() {
    local path="$1" mode owner current_user
    _ssh_assert_no_symlink_components "$path" || return 1
    [[ -d "$path" ]] || return 1

    if ! command -v stat >/dev/null 2>&1; then
        _ssh_is_ntfs && return 0
        return 1
    fi
    owner=$(stat -c '%U' "$path" 2>/dev/null) || owner=$(stat -f '%Su' "$path" 2>/dev/null) || return 1
    current_user=$(id -un 2>/dev/null || true)
    [[ -n "$current_user" ]] || current_user=${USER:-}
    [[ -n "$current_user" && "$owner" == "$current_user" ]] || return 1
    mode=$(stat -c '%a' "$path" 2>/dev/null) || mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return 1
    if ! _ssh_is_ntfs; then
        [[ "$mode" == "700" || "$mode" == "0700" ]] || return 1
    fi
    return 0
}

# Compare two config paths after slash/tilde normalization. This is used only
# to identify the one Include owned by GitSetu, not to migrate old formats.
_ssh_paths_equal() {
    local left="${1-}" right="${2-}"
    left="${left//\\//}"
    right="${right//\\//}"
    if [[ "$left" == "~/"* ]]; then
        left="$HOME/${left:2}"
    elif [[ "$left" == "~" ]]; then
        left="$HOME"
    fi
    if [[ "$right" == "~/"* ]]; then
        right="$HOME/${right:2}"
    elif [[ "$right" == "~" ]]; then
        right="$HOME"
    fi
    while [[ ${#left} -gt 1 && "$left" == */ ]]; do left="${left%/}"; done
    while [[ ${#right} -gt 1 && "$right" == */ ]]; do right="${right%/}"; done
    [[ "$left" == "$right" ]]
}

# ------------------------------------------------------------------------------
# generate_ssh_key — Generate an Ed25519 SSH key pair for a profile
#
# Creates: $HOME/.ssh/id_ed25519_<label> (private) and .pub (public)
# If key exists: prompts user to skip, rename old, or overwrite.
#
# Usage: generate_ssh_key "pro" "user@example.com"
# Returns: 0 on success/skip, 1 on failure
# ------------------------------------------------------------------------------
generate_ssh_key() {
    local label="$1"
    local email="$2"
    local key_path="${3:-$HOME/.ssh/id_ed25519_${label}}"
    key_path=$(_ssh_normalize_key_path "$key_path") || return 1

    if [[ -z "$key_path" || "$key_path" == "$HOME/.ssh/" ]]; then
        print_error "Invalid SSH key path for '$label'."
        return 1
    fi

    if ! _ssh_assert_no_symlink_components "$key_path" 1; then
        print_error "Refusing SSH key path that is redirected or has an indeterminate reparse component: $key_path"
        return 1
    fi
    if ! _ssh_assert_no_symlink_components "$HOME/.ssh"; then
        print_error "Refusing SSH setup because ~/.ssh contains a symlink/reparse component."
        return 1
    fi

    # Warn if ~/.ssh is on a shared mount
    if is_shared_mount "$HOME/.ssh" 2>/dev/null; then
        # shellcheck disable=SC2088  # Tilde is in a display string, not a path
        print_warning "~/.ssh appears to be on a shared folder (VirtualBox/VMware)."
        print_warning "SSH keys require strict permissions (600) which shared folders cannot enforce."
        print_info "Consider storing keys on the native filesystem instead."
    fi

    # Create ~/.ssh if it doesn't exist
    if [[ ! -d "$HOME/.ssh" ]]; then
        (umask 077 && mkdir -p "$HOME/.ssh") || {
            print_error "Failed to create ~/.ssh."
            return 1
        }
        print_step "Created ~/.ssh directory"
    fi
    chmod 700 "$HOME/.ssh" 2>/dev/null || {
        print_error "Failed to enforce mode 0700 on ~/.ssh."
        return 1
    }
    _ssh_assert_private_directory "$HOME/.ssh" || {
        print_error "Refusing SSH setup: ~/.ssh is not a private directory owned by this user."
        return 1
    }

    local key_parent
    key_parent=$(dirname "$key_path")
    _ssh_assert_no_symlink_components "$key_parent" || {
        print_error "Refusing SSH key directory with a symlink/reparse component: $key_parent"
        return 1
    }
    if [[ ! -d "$key_parent" ]]; then
        (umask 077 && mkdir -p "$key_parent") || {
            print_error "Failed to create SSH key directory: $key_parent"
            return 1
        }
    fi
    if [[ "$key_parent" == "$HOME/.ssh" || "$key_parent" == "$HOME/.ssh/"* ]]; then
        chmod 700 "$key_parent" 2>/dev/null || {
            print_error "Failed to enforce mode 0700 on SSH key directory: $key_parent"
            return 1
        }
    fi
    _ssh_assert_private_directory "$key_parent" || {
        print_error "Refusing SSH key directory without private ownership/mode: $key_parent"
        return 1
    }

    # Check if key already exists
    if [[ -f "$key_path" ]]; then
        print_warning "SSH key already exists: $key_path"

        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would prompt for action on existing key"
            return 0
        fi

        if [[ "${GITSETU_AUTO_MODE:-0}" -eq 1 ]]; then
            print_info "Auto-mode: keeping existing key for '$label'"
            return 0
        fi

        ask_choice "What to do with existing key?" "skip (keep current)" "rename old key" "overwrite"

        case "$REPLY" in
            "skip (keep current)")
                print_info "Keeping existing key for '$label'"
                return 0
                ;;
            "rename old key")
                local timestamp
                timestamp=$(date +%Y%m%dT%H%M%S)
                mv "$key_path" "${key_path}.old.${timestamp}"
                mv "${key_path}.pub" "${key_path}.pub.old.${timestamp}" 2>/dev/null || true
                print_info "Renamed old key to ${key_path}.old.${timestamp}"
                ;;
            "overwrite")
                print_info "Overwriting existing key for '$label'"
                ;;
        esac
    fi

    # Dry run: just show what would happen
    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would generate: $key_path"
        print_info "[DRY RUN] ssh-keygen -t ed25519 -C \"$email\" -f \"$key_path\" -N \"\""
        return 0
    fi

    # Revalidate the final key target immediately before ssh-keygen can create
    # or replace it; component observations may safely come from the cache.
    if ! _ssh_assert_no_symlink_components "$key_path" 1 1 1; then
        print_error "Refusing redirected SSH key target immediately before generation."
        return 1
    fi

    # Generate the key
    print_step "Generating SSH key for '$label'..."

    # Check if FIDO2 hardware key was requested based on filename convention
    local key_type="ed25519"
    local -a fido_args=()
    if [[ "$key_path" == *"_sk_"* ]]; then
        key_type="ed25519-sk"
        fido_args=(-O resident -O verify-required)
        print_info "Hardware Security Key detected. Please TOUCH YOUR YUBIKEY when prompted."
    fi

    local status=0
    if [[ "${GITSETU_USE_PASSPHRASE:-0}" -eq 1 ]]; then
        # Prompt for a passphrase. Status is captured inside `if` so callers
        # running under `set -e` receive a controlled return, not an exit.
        if ssh-keygen -t "$key_type" ${fido_args[@]+"${fido_args[@]}"} -C "$email" -f "$key_path"; then
            status=0
        else
            status=$?
        fi
    elif [[ "$key_type" == "ed25519-sk" ]]; then
        if ssh-keygen -t "$key_type" ${fido_args[@]+"${fido_args[@]}"} -C "$email" -f "$key_path" -N ""; then
            status=0
        else
            status=$?
        fi
    else
        if ssh-keygen -t "$key_type" -C "$email" -f "$key_path" -N "" -q; then
            status=0
        else
            status=$?
        fi
    fi

    # A requested FIDO2 key is never silently downgraded to a software key.
    # Setup has no implicit consent channel, so enrollment failure is terminal.
    if [[ "$status" -ne 0 && "$key_type" == "ed25519-sk" ]]; then
        rm -f "$key_path" "${key_path}.pub" 2>/dev/null || true
        print_error "Hardware SSH key enrollment failed for '$label' (missing device or unsupported libfido2)."
        print_info "No software-key fallback was attempted. Connect the requested hardware key or explicitly choose a software key path."
        return 1
    fi

    if [[ "$status" -eq 0 ]]; then
        if ! chmod 600 "$key_path" 2>/dev/null; then
            print_error "Failed to enforce mode 0600 on private SSH key: $key_path"
            return 1
        fi
        chmod 644 "${key_path}.pub" 2>/dev/null || true
        print_success "Created: $key_path"
        return 0
    else
        rm -f "$key_path" "${key_path}.pub" 2>/dev/null || true
        print_error "Failed to generate SSH key for '$label'"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# build_ssh_host_block — Generate a single Host block for ~/.ssh/config
#
# Usage: block=$(build_ssh_host_block "pro" "github.com")
# Output: formatted Host block with managed markers
# ------------------------------------------------------------------------------
build_ssh_host_block() {
    local label="$1"
    local hostname="${2:-github.com}"
    local key_path="${3:-$HOME/.ssh/id_ed25519_${label}}"

    _ssh_reject_multiline "SSH profile label" "$label" || return 1
    _ssh_reject_multiline "SSH hostname" "$hostname" || return 1
    _ssh_valid_host_token "$label" || {
        print_error "Invalid SSH profile label for host configuration: $label"
        return 1
    }
    _ssh_valid_host_token "$hostname" || {
        print_error "Invalid SSH hostname: $hostname"
        return 1
    }
    key_path=$(_ssh_normalize_key_path "$key_path") || return 1

    local portable_key
    portable_key=$(_ssh_portable_path "$key_path")
    local quoted_key
    quoted_key=$(_ssh_quote_token "$portable_key")

    # Extract the main part of the domain (e.g., gitlab.com -> gitlab) for the alias prefix
    local prefix
    prefix=${hostname%%.*}

    # Port 443 routing is an explicit GitHub.com endpoint policy, not a
    # substring match. Deceptive hosts such as github.com.evil must retain
    # their literal HostName and never be redirected to ssh.github.com.
    if [[ "${GITSETU_PORT443_NEEDED:-0}" -eq 1 ]] && [[ "$hostname" == "github.com" ]]; then
        cat <<EOF
Host ${prefix}-${label}
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ${quoted_key}
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
    else
        cat <<EOF
Host ${prefix}-${label}
    HostName ${hostname}
    User git
    IdentityFile ${quoted_key}
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
    fi

    if [[ "${GITSETU_OS:-}" == "macos" || "${OSTYPE:-}" == "darwin"* ]]; then
        echo "    UseKeychain yes"
    fi
}

# ------------------------------------------------------------------------------
# write_ssh_config — Update ~/.ssh/config with gitsetu-managed host blocks
#
# All generated aliases remain in one private file. The user's config is only
# changed by prepending one exact Include and atomically relocating prior exact
# copies of that Include. No inline/legacy SSH block migration is performed.
# Usage: write_ssh_config
# ------------------------------------------------------------------------------
write_ssh_config() {
    local ssh_config="$HOME/.ssh/config"
    local isolated_config="$GITSETU_PROFILES_DIR/ssh_config"
    local isolated_normalized="$isolated_config"
    if declare -f normalize_path >/dev/null 2>&1; then
        isolated_normalized=$(normalize_path "$isolated_config")
    else
        isolated_normalized="${isolated_config//\\//}"
    fi
    local include_path
    include_path=$(_ssh_portable_path "$isolated_normalized")
    local include_arg
    include_arg=$(_ssh_quote_token "$include_path")
    local include_directive="Include ${include_arg}"

    if ! _ssh_assert_no_symlink_components "$ssh_config" 1; then
        print_error "Refusing to replace redirected SSH config or an indeterminate reparse path: $ssh_config"
        return 1
    fi
    if ! _ssh_assert_no_symlink_components "$isolated_normalized" 1; then
        print_error "Refusing to replace redirected GitSetu SSH config or an indeterminate reparse path: $isolated_normalized"
        return 1
    fi

    # Dry run
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would prepend to: $ssh_config"
        print_info "          $include_directive"
        print_info "[DRY RUN] Would write host aliases to: $isolated_normalized"
        return 0
    fi

    if [[ ! -d "$HOME/.ssh" ]]; then
        _ssh_assert_no_symlink_components "$HOME/.ssh" || {
            print_error "Refusing SSH config: ~/.ssh contains a symlink/reparse component."
            return 1
        }
        (umask 077 && mkdir -p "$HOME/.ssh") || {
            print_error "Failed to create ~/.ssh."
            return 1
        }
    fi
    chmod 700 "$HOME/.ssh" 2>/dev/null || {
        print_error "Failed to enforce mode 0700 on ~/.ssh."
        return 1
    }
    _ssh_assert_private_directory "$HOME/.ssh" || {
        print_error "Refusing SSH config: ~/.ssh is not private and owned by this user."
        return 1
    }
    _ssh_assert_no_symlink_components "$GITSETU_PROFILES_DIR" || {
        print_error "Refusing SSH config: profiles directory contains a symlink/reparse component."
        return 1
    }
    if [[ ! -d "$GITSETU_PROFILES_DIR" ]]; then
        (umask 077 && mkdir -p "$GITSETU_PROFILES_DIR") || {
            print_error "Failed to create profiles directory: $GITSETU_PROFILES_DIR"
            return 1
        }
    fi
    chmod 700 "$GITSETU_PROFILES_DIR" 2>/dev/null || {
        print_error "Failed to enforce mode 0700 on profiles directory."
        return 1
    }
    _ssh_assert_private_directory "$GITSETU_PROFILES_DIR" || {
        print_error "Refusing SSH config: profiles directory is not private and owned by this user."
        return 1
    }

    # Compile the complete generated file privately, then atomically install it.
    local isolated_tmp
    isolated_tmp=$(umask 077; mktemp "${isolated_normalized}.tmp.XXXXXX") || {
        print_error "Failed to create temporary GitSetu SSH config."
        return 1
    }
    if [[ -n "${GITSETU_CLEANUP_FILES+x}" ]]; then
        GITSETU_CLEANUP_FILES+=("$isolated_tmp")
    fi
    printf '# Generated by gitsetu v%s; managed source\n' "${GITSETU_VERSION:-unknown}" > "$isolated_tmp"
    printf '%s\n' '# Do not edit this file directly. It is overwritten by gitsetu.' >> "$isolated_tmp"

    local i label provider key_path
    for (( i=0; i<${PROFILE_COUNT:-0}; i++ )); do
        if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_PROVIDERS[$i]+x} || ! ${PROFILE_KEYS[$i]+x} ]]; then
            rm -f "$isolated_tmp"
            print_error "Strict v2 SSH config requires label, provider, and key_path for every profile."
            return 1
        fi
        label="${PROFILE_LABELS[$i]}"
        provider="${PROFILE_PROVIDERS[$i]}"
        key_path="${PROFILE_KEYS[$i]}"
        [[ -n "$provider" && -n "$key_path" ]] || {
            rm -f "$isolated_tmp"
            print_error "Strict v2 SSH config has an empty provider or key_path for '$label'."
            return 1
        }
        if declare -f validate_provider >/dev/null 2>&1; then
            validate_provider "$provider" || {
                rm -f "$isolated_tmp"
                print_error "Strict v2 SSH config has an invalid provider for '$label'."
                return 1
            }
        fi
        if declare -f validate_key_path >/dev/null 2>&1; then
            validate_key_path "$key_path" || {
                rm -f "$isolated_tmp"
                print_error "Strict v2 SSH config has an invalid key_path for '$label'."
                return 1
            }
        fi
        printf '\n' >> "$isolated_tmp"
        if ! build_ssh_host_block "$label" "$provider" "$key_path" >> "$isolated_tmp"; then
            rm -f "$isolated_tmp"
            print_error "Failed to compile SSH host configuration for '$label'."
            return 1
        fi
    done
    chmod 600 "$isolated_tmp" 2>/dev/null || {
        rm -f "$isolated_tmp"
        print_error "Failed to enforce mode 0600 on generated SSH config."
        return 1
    }
    if ! _ssh_assert_no_symlink_components "$isolated_normalized" 1 1 1; then
        rm -f "$isolated_tmp"
        print_error "Refusing redirected SSH config target immediately before replacement."
        return 1
    fi
    mv -f "$isolated_tmp" "$isolated_normalized" || return 1

    # Always rebuild the small top-of-file shim. This guarantees exactly one
    # Include while preserving every unrelated line byte-for-byte.
    local config_tmp
    config_tmp=$(umask 077; mktemp "${ssh_config}.tmp.XXXXXX") || {
        print_error "Failed to create temporary SSH config."
        return 1
    }
    if [[ -n "${GITSETU_CLEANUP_FILES+x}" ]]; then
        GITSETU_CLEANUP_FILES+=("$config_tmp")
    fi
    printf '%s\n' "$include_directive" > "$config_tmp"
    if [[ -f "$ssh_config" ]]; then
        awk -v portable="$include_path" -v absolute="$isolated_normalized" '
            {
                original = $0
                line = original
                sub(/^[[:space:]]+/, "", line)
                if (line !~ /^Include[[:space:]]+/) { print original; next }
                argument = line
                sub(/^Include[[:space:]]+/, "", argument)
                sub(/[[:space:]]+$/, "", argument)
                if (substr(argument, 1, 1) == "\"" && substr(argument, length(argument), 1) == "\"") {
                    argument = substr(argument, 2, length(argument) - 2)
                }
                if (argument == portable || argument == absolute) next
                print original
            }
        ' "$ssh_config" >> "$config_tmp"
    fi
    chmod 600 "$config_tmp" 2>/dev/null || {
        rm -f "$config_tmp"
        print_error "Failed to enforce mode 0600 on SSH config."
        return 1
    }

    if [[ -f "$ssh_config" ]]; then
        backup_file "$ssh_config" || {
            rm -f "$config_tmp"
            return 1
        }
    fi
    if ! _ssh_assert_no_symlink_components "$ssh_config" 1 1 1; then
        rm -f "$config_tmp"
        print_error "Refusing redirected SSH config target immediately before replacement."
        return 1
    fi
    mv -f "$config_tmp" "$ssh_config" || return 1
    chmod 600 "$ssh_config" 2>/dev/null || return 1
    print_success "Updated SSH config: $ssh_config"
}

# ------------------------------------------------------------------------------
# try_gh_key_upload — Upload an SSH public key to GitHub via gh CLI
#
# Locked Constraint: Scope discipline — only interacts with currently authenticated
# account via `gh api user -q .login`. No multi-account detection, no auth switch.
#
# Usage: try_gh_key_upload "work" "/path/to/key.pub"
# Returns: 0 on success or already registered, 1 on failure / skipped / declined
# ------------------------------------------------------------------------------
try_gh_key_upload() {
    local label="$1"
    local pubkey_path="$2"

    # a) Check if gh is installed
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi

    # Validate key file existence
    if [[ ! -f "$pubkey_path" ]]; then
        return 1
    fi

    # b) Dry-run boundary: do not contact GitHub or disclose an account login.
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would upload '$label' key to GitHub (account lookup and upload skipped)"
        return 0
    fi

    # c) Get login username
    local login
    login=$(gh api user -q .login 2>/dev/null || true)
    login="${login%$'\r'}"
    if [[ -z "$login" ]]; then
        return 1
    fi

    # d) If non-TTY or GITSETU_TEST is set, do NOT prompt interactively — skip or return 1 (unless mock is testing it)
    if [[ -n "${GITSETU_TEST:-}" ]]; then
        local is_mock=0
        if [[ -n "${GITSETU_TEST_GH:-}" || -n "${GITSETU_TEST_GH_MOCK:-}" ]]; then
            is_mock=1
        elif [[ "$(type -t gh 2>/dev/null)" == "function" ]]; then
            is_mock=1
        elif [[ -n "${TEST_HOME:-}" && "$(command -v gh 2>/dev/null)" == *"$TEST_HOME"* ]]; then
            is_mock=1
        fi
        if [[ "$is_mock" -eq 0 ]]; then
            return 1
        fi
    elif [[ ! -t 0 ]]; then
        return 1
    fi

    # e) Display: GitHub CLI: logged in as @$login
    printf >&2 '  GitHub CLI: logged in as @%s\n' "$login"

    # f) Confirm: confirm "Upload '$label' key to GitHub (@$login)?" "y"
    # If user declines, return 1
    if [[ -n "${GITSETU_TEST:-}" ]]; then
        if [[ "${GITSETU_TEST_DECLINE:-0}" -eq 1 ]]; then
            return 1
        fi
    else
        if ! confirm "Upload '$label' key to GitHub (@$login)?" "y"; then
            return 1
        fi
    fi

    # g) Run upload
    local hostname_str
    hostname_str=$(hostname 2>/dev/null || echo "workstation")
    hostname_str="${hostname_str%$'\r'}"
    local upload_out
    local exit_code=0
    upload_out=$(gh ssh-key add "$pubkey_path" --title "GitSetu ($label - $hostname_str)" 2>&1) || exit_code=$?

    # h) If exit_code == 0:
    if [[ "$exit_code" -eq 0 ]]; then
        print_success "Key successfully added to GitHub!"
        return 0
    fi

    # i) If output matches "already in use" or "key is already in use":
    local lower_out
    lower_out=$(printf '%s' "$upload_out" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_out" == *"already in use"* ]]; then
        print_info "Key already registered on GitHub."
        return 0
    fi

    # j) Any other error:
    print_warning "Failed to upload key via GitHub CLI: $upload_out"
    return 1
}

# ------------------------------------------------------------------------------
# display_public_keys — Show all public keys with copy instructions
#
# Displays each key in a formatted box with the GitHub settings URL.
# Usage: display_public_keys
# ------------------------------------------------------------------------------
display_public_keys() {
    print_section "Public Keys — Add These to GitHub/GitLab"

    local i
    for (( i=0; i<${PROFILE_COUNT:-0}; i++ )); do
        if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_EMAILS[$i]+x} || ! ${PROFILE_PROVIDERS[$i]+x} || ! ${PROFILE_KEYS[$i]+x} ]]; then
            print_error "Strict v2 public-key display requires label, email, provider, and key_path."
            return 1
        fi
        local label="${PROFILE_LABELS[$i]}"
        local email="${PROFILE_EMAILS[$i]}"
        local provider="${PROFILE_PROVIDERS[$i]}"
        local pubkey="${PROFILE_KEYS[$i]}.pub"
        [[ -n "$provider" && -n "$pubkey" ]] || {
            print_error "Strict v2 public-key display has an empty provider or key_path."
            return 1
        }

        if [[ -f "$pubkey" ]]; then
            print_key_box "$label" "$email" "$pubkey"
            if [[ "$provider" == *"github"* ]]; then
                if ! try_gh_key_upload "$label" "$pubkey"; then
                    print_info "To add key manually, copy the key above and add at: https://github.com/settings/ssh/new"
                fi
            fi
        else
            print_warning "Key not found for '$label': $pubkey"
        fi
    done

    print_section "The Magical Clone"
    printf >&2 "  %bYou no longer need special host aliases to clone!%b\n\n" "$BOLD" "$RESET"
    printf >&2 "  Simply %bcd%b into your profile's directory and run:\n" "$CYAN" "$RESET"
    printf >&2 "    git clone git@github.com:username/repo.git\n\n"
    printf >&2 "  %bGitSetu will automatically intercept and use the correct SSH key!%b\n" "$BOLD" "$RESET"
}

# ------------------------------------------------------------------------------
# auto_register_ssh_keys — Automatically register profile SSH keys with ssh-agent
#
# Non-fatal: checks socket liveness, skips already loaded keys, and adds keys
# with macOS keychain persistence or standard ssh-add.
# Usage: auto_register_ssh_keys [key_path...]
# ------------------------------------------------------------------------------
auto_register_ssh_keys() {
    # Resolve registry validity before checking the agent. A malformed managed
    # state must not be reported as a harmless "agent unavailable" condition.
    if [[ "$#" -eq 0 && -e "${GITSETU_PROFILES_CONF:-}" || "$#" -eq 0 && -L "${GITSETU_PROFILES_CONF:-}" ]]; then
        if ! declare -f load_profiles >/dev/null 2>&1; then
            print_error "SSH agent registration cannot validate the existing v2 profile registry."
            return 2
        fi
        local preflight_status=0
        load_profiles || preflight_status=$?
        if [[ "$preflight_status" -ne 0 ]]; then
            print_error "SSH agent registration refused: the existing v2 profile registry is invalid."
            return 2
        fi
        if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
            print_error "SSH agent registration refused: the v2 profile registry contains no profiles."
            return 2
        fi
    fi

    print_section "SSH Agent Key Registration"

    # a) Check if SSH_AUTH_SOCK is set.
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        print_info "SSH agent not running (SSH_AUTH_SOCK not set)."
        print_info "To start ssh-agent, run: eval \$(ssh-agent -s)"
        return 0
    fi

    # b) Socket liveness test: run `ssh-add -l >/dev/null 2>&1`. Exit code 2 means dead socket.
    local agent_status=0
    ssh-add -l >/dev/null 2>&1 || agent_status=$?
    if [[ "$agent_status" -eq 2 ]]; then
        print_warning "SSH agent socket not responding ($SSH_AUTH_SOCK)"
        print_info "To restart ssh-agent, run: eval \$(ssh-agent -s)"
        return 0
    fi

    # Loaded keys list for fingerprint deduplication (exit code 0 means identities present)
    local loaded_keys=""
    if [[ "$agent_status" -eq 0 ]]; then
        loaded_keys=$(ssh-add -l 2>/dev/null || true)
    fi

    # c) Determine keys to register
    local -a keys_to_process=()
    if [[ "$#" -gt 0 ]]; then
        keys_to_process=("$@")
    elif [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        local i
        for (( i=0; i<${PROFILE_COUNT:-0}; i++ )); do
            if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_KEYS[$i]+x} || -z "${PROFILE_KEYS[$i]}" ]]; then
                print_error "Strict v2 SSH agent registration requires a key_path for every profile."
                return 2
            fi
            keys_to_process+=("${PROFILE_KEYS[$i]}")
        done
    elif [[ -e "${GITSETU_PROFILES_CONF:-}" || -L "${GITSETU_PROFILES_CONF:-}" ]]; then
        # Registry presence is a scope boundary. Invalid or empty v2 state is not
        # permission to widen the operation to every key in ~/.ssh.
        if ! declare -f load_profiles >/dev/null 2>&1; then
            print_error "SSH agent registration cannot validate the existing v2 profile registry."
            return 2
        fi
        local load_status=0
        load_profiles || load_status=$?
        if [[ "$load_status" -ne 0 ]]; then
            print_error "SSH agent registration refused: the existing v2 profile registry is invalid."
            print_info "Run 'gitsetu doctor'; no unconfigured ~/.ssh key discovery was attempted."
            return 2
        fi
        if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
            print_error "SSH agent registration refused: the v2 profile registry contains no profiles."
            print_info "No unconfigured ~/.ssh key discovery was attempted while a registry exists."
            return 2
        fi
        local i
        for (( i=0; i<${PROFILE_COUNT:-0}; i++ )); do
            if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_KEYS[$i]+x} || -z "${PROFILE_KEYS[$i]}" ]]; then
                print_error "Strict v2 SSH agent registration requires a key_path for every profile."
                return 2
            fi
            keys_to_process+=("${PROFILE_KEYS[$i]}")
        done
    else
        # Genuinely unconfigured: broad discovery is allowed only when no v2
        # registry file exists at all.
        local found_key
        for found_key in "$HOME/.ssh"/id_ed25519_*; do
            if [[ -f "$found_key" && "$found_key" != *.pub && "$found_key" != *.old* ]]; then
                keys_to_process+=("$found_key")
            fi
        done
    fi

    # Deduplicate candidate key paths. Bash 3.2, the interpreter macOS still
    # ships, raises "unbound variable" when an empty array is value-expanded
    # under set -u. Both loops therefore iterate behind an explicit count check,
    # because either array is legitimately empty on the first pass.
    local -a unique_keys=()
    local kp
    local process_count=${#keys_to_process[@]}
    if [[ "$process_count" -gt 0 ]]; then
        for kp in "${keys_to_process[@]}"; do
            [[ -z "$kp" ]] && continue
            local seen=0
            local u
            local unique_count=${#unique_keys[@]}
            if [[ "$unique_count" -gt 0 ]]; then
                for u in "${unique_keys[@]}"; do
                    if [[ "$u" == "$kp" ]]; then
                        seen=1
                        break
                    fi
                done
            fi
            if [[ "$seen" -eq 0 ]]; then
                unique_keys+=("$kp")
            fi
        done
    fi

    if [[ "${#unique_keys[@]}" -eq 0 ]]; then
        print_info "No profile SSH keys found to register."
        return 0
    fi

    local registered_count=0
    local already_loaded_count=0

    for kp in "${unique_keys[@]}"; do
        if [[ ! -f "$kp" ]]; then
            continue
        fi

        # Check if key is already loaded in agent (compare fingerprint)
        local key_fp=""
        key_fp=$(ssh-keygen -lf "$kp" 2>/dev/null | awk '{print $2}')
        if [[ -n "$key_fp" && -n "$loaded_keys" ]]; then
            if printf '%s\n' "$loaded_keys" | grep -q -F "$key_fp"; then
                already_loaded_count=$((already_loaded_count + 1))
                print_info "Key already loaded in SSH agent: $kp"
                continue
            fi
        fi

        # Dry run check: suppress ssh-add invocation
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would register with SSH agent: $kp"
            registered_count=$((registered_count + 1))
            continue
        fi

        # Registration attempt (macOS keychain support or standard)
        local add_status=0
        if [[ "${GITSETU_OS:-}" == "macos" || "${OSTYPE:-}" == "darwin"* ]]; then
            ssh-add --apple-use-keychain "$kp" 2>/dev/null || ssh-add "$kp" 2>/dev/null || add_status=$?
        else
            ssh-add "$kp" 2>/dev/null || add_status=$?
        fi

        if [[ "$add_status" -eq 0 ]]; then
            registered_count=$((registered_count + 1))
            print_success "Registered with SSH agent: $kp"
            if [[ -n "$key_fp" ]]; then
                loaded_keys=$(printf '%s\n%s' "$loaded_keys" "$key_fp")
            fi
        else
            print_warning "Could not auto-register $kp (may require passphrase or hardware key)"
            print_info "To add manually: ssh-add $kp"
        fi
    done

    if [[ "$registered_count" -gt 0 ]]; then
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would register ${registered_count} key(s) with SSH agent"
        else
            print_success "Registered ${registered_count} key(s) with SSH agent"
        fi
    fi
    if [[ "$already_loaded_count" -gt 0 ]]; then
        print_info "${already_loaded_count} key(s) already loaded in SSH agent"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# verify_ssh_handshake — Verify SSH connectivity without implicit trust changes
#
# Default verification uses StrictHostKeyChecking=yes and UpdateHostkeys=no, so
# it cannot add or replace known_hosts entries. First-use trust requires
# GITSETU_ALLOW_SSH_HOST_KEY=1. GitHub's port 443 route is never tried unless
# GITSETU_ALLOW_SSH_PORT443=1 is set explicitly.
#
# Usage: verify_ssh_handshake "/path/to/key" "github.com"
# Returns: 0 on success or deliberate skip, 1 on verification failure
# ------------------------------------------------------------------------------
verify_ssh_handshake() {
    local key_path="$1"
    local provider="${2:-github.com}"
    local host="$provider"
    local host_key_mode="yes"

    _ssh_reject_multiline "SSH key path" "$key_path" || return 1
    _ssh_reject_multiline "SSH provider" "$provider" || return 1
    _ssh_valid_host_token "$provider" || {
        print_error "Invalid SSH provider/host for handshake: $provider"
        return 1
    }
    key_path=$(_ssh_normalize_key_path "$key_path") || return 1
    if [[ ! -f "$key_path" ]]; then
        return 0
    fi
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would verify SSH connectivity without changing known_hosts: $provider"
        return 0
    fi
    if [[ "${GITSETU_ALLOW_SSH_HOST_KEY:-0}" == "1" ]]; then
        host_key_mode="accept-new"
    fi

    # Tests skip all network access unless they explicitly provide a mock.
    if [[ -n "${GITSETU_TEST:-}" ]]; then
        local is_mock=0
        if [[ -n "${GITSETU_TEST_SSH_VERIFY:-}" || -n "${GITSETU_TEST_SSH:-}" ]]; then
            is_mock=1
        elif [[ "$(type -t ssh 2>/dev/null)" == "function" ]]; then
            is_mock=1
        elif [[ -n "${TEST_HOME:-}" && "$(command -v ssh 2>/dev/null)" == *"$TEST_HOME"* ]]; then
            is_mock=1
        fi
        if [[ "$is_mock" -eq 0 ]]; then
            return 0
        fi
    fi

    local out ssh_status=0
    if out=$(ssh -T -i "$key_path" -o IdentitiesOnly=yes -o ConnectTimeout=6 \
        -o "StrictHostKeyChecking=${host_key_mode}" -o UpdateHostkeys=no \
        -o BatchMode=yes "git@$host" 2>&1); then
        ssh_status=0
    else
        ssh_status=$?
    fi
    if [[ "$ssh_status" -eq 0 || "$out" == *"successfully authenticated"* || "$out" == *"Welcome to GitLab"* ]]; then
        print_success "SSH connection verified: $host (port 22; known_hosts trust=${host_key_mode})"
        return 0
    fi

    if [[ "$host" == "github.com" || "$provider" == "github.com" ]]; then
        if [[ "${GITSETU_ALLOW_SSH_PORT443:-0}" != "1" ]]; then
            print_info "GitHub port 443 was not attempted. Set GITSETU_ALLOW_SSH_PORT443=1 to opt in to that route."
        else
            local out443 ssh443_status=0
            if out443=$(ssh -T -i "$key_path" -o IdentitiesOnly=yes -p 443 \
                -o ConnectTimeout=6 -o "StrictHostKeyChecking=${host_key_mode}" \
                -o UpdateHostkeys=no -o BatchMode=yes git@ssh.github.com 2>&1); then
                ssh443_status=0
            else
                ssh443_status=$?
            fi
            if [[ "$ssh443_status" -eq 0 || "$out443" == *"successfully authenticated"* ]]; then
                print_success "SSH connection verified: github.com (explicit port 443 opt-in)"
                export GITSETU_PORT443_NEEDED=1
                return 0
            fi
        fi
    fi

    print_warning "SSH verification for $provider failed (known_hosts was not changed)."
    return 1
}

