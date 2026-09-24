#!/usr/bin/env bash
# lib/gitconfig.sh — Git identity routing and configuration generation
#
# Generated values are escaped as Git INI values, profile shell commands are
# quoted as POSIX arguments, and conditional includes are emitted shallowest-path
# first. Git reads every matching includeIf in declaration order and the last
# scalar value wins, so the most-specific nested profile is emitted last. The
# gitdir prefix also covers linked-worktree GIT_DIR values stored below a managed
# repository's .git/worktrees directory.
#
# The profile registry is v2-only. This module delegates persistence to the v2
# registry writer supplied by core; it deliberately has no v1 parser or migration
# path.
#
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# Encoding, path, and deterministic routing helpers
# ------------------------------------------------------------------------------

_gitconfig_reject_multiline() {
    local label="$1" value="$2"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        print_error "$label cannot contain CR or LF."
        return 1
    fi
    if declare -f _gitsetu_reject_ascii_controls >/dev/null 2>&1 &&
       ! _gitsetu_reject_ascii_controls "$label" "$value"; then
        print_error "$label cannot contain ASCII control bytes."
        return 1
    fi
}

_gitconfig_normalize_path() {
    local path="$1"
    if declare -f normalize_path >/dev/null 2>&1; then
        normalize_path "$path"
    else
        printf '%s' "${path//\\//}"
    fi
}

_gitconfig_escape_double() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

_gitconfig_quote_double_value() {
    printf '"%s"' "$(_gitconfig_escape_double "$1")"
}

_gitconfig_quote_if_needed() {
    local value="$1"
    if [[ -z "$value" || "$value" == [[:space:]]* || "$value" == *[[:space:]] ||
          "$value" == *\\* || "$value" == *\"* || "$value" == *'#'* || "$value" == *';'* ]]; then
        printf '"%s"' "$(_gitconfig_escape_double "$value")"
    else
        printf '%s' "$value"
    fi
}

_gitconfig_portable_key_path() {
    local path="$1"
    if [[ "$path" == "$HOME" ]]; then
        printf '~'
    elif [[ "$path" == "$HOME/"* ]]; then
        printf '~/%s' "${path#"$HOME"/}"
    else
        printf '%s' "$path"
    fi
}

_gitconfig_normalize_key_path() {
    local path="${1-}"
    _gitconfig_reject_multiline "SSH key path" "$path" || return 1
    [[ -n "$path" ]] || return 1
    if [[ "$path" != "~" && "$path" != "~/"* && "$path" != /* && "$path" != [a-zA-Z]:/* ]]; then
        path="$PWD/$path"
    fi
    _gitconfig_normalize_path "$path"
}

# Return one shell word using the portable POSIX single-quote representation.
_gitconfig_shell_quote() {
    local value="$1"
    value="${value//\'/\'\\\'\'}"
    printf "'%s'" "$value"
}

_gitconfig_build_ssh_command() {
    local key_path="$1"
    local portable quoted
    portable=$(_gitconfig_portable_key_path "$key_path") || return 1
    quoted=$(_gitconfig_shell_quote "$portable") || return 1
    GITCONFIG_SSH_COMMAND="ssh -o IdentitiesOnly=yes -i ${quoted}"
}

_gitconfig_valid_provider() {
    local provider="$1"
    [[ "$provider" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?$ ]]
}

_gitconfig_resolve_symlink_target() {
    local path="$1" dir target hops=0
    while [[ -L "$path" ]]; do
        hops=$((hops + 1))
        [[ "$hops" -le 40 ]] || return 1
        target=$(readlink "$path" 2>/dev/null) || return 1
        if [[ "$target" == /* || "$target" == [a-zA-Z]:/* ]]; then
            path="$target"
        else
            dir=$(dirname "$path")
            path="$dir/$target"
        fi
        path=$(_gitconfig_normalize_path "$path") || return 1
    done
    printf '%s' "$path"
}

_gitconfig_byte_length() {
    local value="$1"
    local LC_ALL=C
    printf '%s' "${#value}"
}

# Populate sorted route arrays. A duplicate directory is ambiguous and rejected
# rather than depending on registry order.
_gitconfig_collect_routes() {
    local count="${PROFILE_COUNT:-0}" i j label dir normalized compare
    local sort_had_lc=0 sort_old_lc=""
    local -a labels=() dirs=() lengths=()
    GITCONFIG_GLOBAL_LABEL=""
    GITCONFIG_GLOBAL_COUNT=0

    for (( i=0; i<count; i++ )); do
        if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_DIRS[$i]+x} ]]; then
            print_error "Strict v2 routing requires label and directory fields at index $i."
            return 1
        fi
        label="${PROFILE_LABELS[$i]}"
        dir="${PROFILE_DIRS[$i]}"
        if declare -f validate_label >/dev/null 2>&1; then
            validate_label "$label" || {
                print_error "Invalid profile label in routing table: $label"
                return 1
            }
        elif [[ ! "$label" =~ ^[a-z][a-z0-9-]*$ ]]; then
            print_error "Invalid profile label in routing table: $label"
            return 1
        fi
        _gitconfig_reject_multiline "Profile directory" "$dir" || return 1
        # The mandatory global profile is the one intentional empty directory;
        # represent it explicitly as the root route. Every non-empty directory
        # still has to pass canonical path normalization unchanged.
        if [[ -z "$dir" ]]; then
            [[ "$label" == "global" ]] || {
                print_error "Only the global v2 profile may have an empty directory: $label"
                return 1
            }
            normalized="/"
        else
            normalized=$(_gitconfig_normalize_path "$dir") || return 1
            [[ -n "$normalized" ]] || return 1
        fi
        if [[ "$normalized" == "/" ]]; then
            GITCONFIG_GLOBAL_COUNT=$((GITCONFIG_GLOBAL_COUNT + 1))
            [[ "$GITCONFIG_GLOBAL_COUNT" -eq 1 ]] || {
                print_error "More than one global profile has an empty/root directory."
                return 1
            }
            GITCONFIG_GLOBAL_LABEL="$label"
            continue
        fi
        while [[ ${#normalized} -gt 1 && "$normalized" == */ ]]; do normalized="${normalized%/}"; done
        for (( j=0; j<${#labels[@]}; j++ )); do
            compare="${dirs[$j]}"
            local normalized_compare="$normalized" path_compare="$compare"
            if [[ "${GITSETU_OS:-}" == "gitbash" || "${GITSETU_OS:-}" == "macos" ]]; then
                normalized_compare=$(printf '%s' "$normalized_compare" | tr '[:upper:]' '[:lower:]')
                path_compare=$(printf '%s' "$path_compare" | tr '[:upper:]' '[:lower:]')
            fi
            if [[ "$normalized_compare" == "$path_compare" ]]; then
                print_error "Profiles '$label' and '${labels[$j]}' route the same directory: $dir"
                return 1
            fi
        done
        labels+=("$label")
        dirs+=("$normalized")
        lengths+=("$(_gitconfig_byte_length "$normalized")")
    done

    # Selection sort: shortest path first, then normalized path, then label.
    # Every matching includeIf is read; last scalar value wins in Git. Use the
    # C locale only for ordering, after canonicalization has run in a UTF-8
    # locale, so output remains byte-deterministic without rejecting UTF-8.
    if [[ -n "${LC_ALL+x}" ]]; then
        sort_had_lc=1
        sort_old_lc="$LC_ALL"
    fi
    LC_ALL=C
    for (( i=0; i<${#labels[@]}-1; i++ )); do
        j=$((i + 1))
        while (( j < ${#labels[@]} )); do
            if [[ "${lengths[$j]}" -lt "${lengths[$i]}" ]] ||
               { [[ "${lengths[$j]}" -eq "${lengths[$i]}" ]] && [[ "${dirs[$j]}" < "${dirs[$i]}" || "${dirs[$j]}" == "${dirs[$i]}" && "${labels[$j]}" < "${labels[$i]}" ]]; }; then
                compare="${labels[i]}"; labels[i]="${labels[j]}"; labels[j]="$compare"
                compare="${dirs[i]}"; dirs[i]="${dirs[j]}"; dirs[j]="$compare"
                compare="${lengths[i]}"; lengths[i]="${lengths[j]}"; lengths[j]="$compare"
            fi
            j=$((j + 1))
        done
    done
    if [[ "$sort_had_lc" -eq 1 ]]; then
        LC_ALL="$sort_old_lc"
    else
        unset LC_ALL
    fi
    GITCONFIG_ROUTE_LABELS=("${labels[@]+"${labels[@]}"}")
    GITCONFIG_ROUTE_DIRS=("${dirs[@]+"${dirs[@]}"}")
    GITCONFIG_ROUTE_LENGTHS=("${lengths[@]+"${lengths[@]}"}")
}

# ------------------------------------------------------------------------------
# Existing credential-helper policy
# ------------------------------------------------------------------------------

_gitconfig_expected_helper() {
    local origin_file="${BASH_SOURCE[0]}" origin_dir candidate executable quoted
    origin_dir=$(cd "$(dirname "$origin_file")" 2>/dev/null && pwd -P) || return 1
    if [[ "$(basename "$origin_file")" == "gitconfig.sh" ]]; then
        candidate=$(dirname "$origin_dir")
    else
        candidate="$origin_dir"
    fi
    # GITSETU_DIR/GITSETU_SCRIPT_DIR are not trust anchors. The executable must
    # be the regular file in the canonical checkout that supplied this module.
    executable="$candidate/gitsetu"
    if [[ ! -f "$executable" || -L "$executable" ]]; then
        if [[ -f "$candidate/gitsetu.exe" && ! -L "$candidate/gitsetu.exe" ]]; then
            executable="$candidate/gitsetu.exe"
        else
            return 1
        fi
    fi
    GITCONFIG_CANONICAL_EXE="$executable"
    quoted=$(_gitconfig_shell_quote "$executable") || return 1
    GITCONFIG_HELPER_VALUE="!${quoted} credential"
}

_gitconfig_value_is_generated_helper() {
    local value="$1" expected=""
    _gitconfig_expected_helper || return 1
    expected="$GITCONFIG_HELPER_VALUE"
    [[ "$value" == "$expected" || "$value" == "${GITCONFIG_CANONICAL_EXE:-} credential" ]]
}

# Return 0 when an explicit user/system helper policy exists, 1 when none does,
# and 2 when an existing configuration cannot be inspected safely.
_gitconfig_user_credential_helper_exists() {
    local gitconfig="$HOME/.gitconfig" target tmp status value line
    target=$(_gitconfig_resolve_symlink_target "$gitconfig") || return 2

    # A direct global helper outside GitSetu's managed block is authoritative.
    if [[ -f "$target" ]]; then
        tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/gitsetu-helper-policy.XXXXXX" 2>/dev/null) || return 2
        if [[ -n "${GITSETU_CLEANUP_FILES+x}" ]]; then GITSETU_CLEANUP_FILES+=("$tmp"); fi
        awk -v start="$GITSETU_MANAGED_START" -v end="$GITSETU_MANAGED_END" '
            $0 == start { managed=1; next }
            $0 == end { managed=0; next }
            !managed { print }
        ' "$target" > "$tmp"
        if ! git config --file "$tmp" --list >/dev/null 2>&1; then
            rm -f "$tmp"
            return 2
        fi
        status=0
        value=$(git config --file "$tmp" --get-all credential.helper 2>/dev/null) || status=$?
        if [[ "$status" -gt 1 ]]; then
            rm -f "$tmp"
            return 2
        fi
        if [[ "$status" -eq 0 ]]; then
            rm -f "$tmp"
            return 0
        fi
        status=0
        value=$(git config --file "$tmp" --get-regexp '^credential\..*\.helper$' 2>/dev/null) || status=$?
        rm -f "$tmp"
        if [[ "$status" -gt 1 ]]; then return 2; fi
    fi

    # A system-level policy must not be shadowed by GitSetu.
    status=0
    git config --system --get-all credential.helper >/dev/null 2>&1 || status=$?
    [[ "$status" -gt 1 ]] && return 2
    [[ "$status" -eq 0 ]] && return 0

    # Includes can contribute to global config. Count only values not emitted by
    # our managed block; any distinct value is a user policy. Capture the query
    # status rather than silently treating an inspection error as "no policy".
    local global_output global_status=0
    global_output=$(git config --global --show-origin --get-all credential.helper 2>/dev/null) || global_status=$?
    [[ "$global_status" -le 1 ]] || return 2
    while IFS= read -r line || [[ -n "$line" ]]; do
        value="${line#*$'\t'}"
        if [[ -n "$value" ]] && ! _gitconfig_value_is_generated_helper "$value"; then
            return 0
        fi
    done <<< "$global_output"
    return 1
}

_gitconfig_validate_persisted_paths() {
    local count="${PROFILE_COUNT:-0}" i label dir normalized
    local have_validator=0
    if declare -f validate_profile_directory >/dev/null 2>&1; then
        have_validator=1
    fi
    for (( i=0; i<count; i++ )); do
        if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_DIRS[$i]+x} ]]; then
            return 1
        fi
        label="${PROFILE_LABELS[$i]}"
        dir="${PROFILE_DIRS[$i]}"
        if [[ "$have_validator" -eq 1 ]]; then
            if [[ "$label" == "global" ]]; then
                validate_profile_directory "$dir" 1 || return 1
            else
                validate_profile_directory "$dir" 0 || return 1
            fi
            continue
        fi
        # Direct module users may not have loaded validate.sh. Keep the
        # persistence boundary strict without making the whole writer fail.
        if [[ "$label" == "global" && -z "$dir" ]]; then
            continue
        fi
        [[ -n "$dir" && ( "$dir" == /* || "$dir" =~ ^[A-Za-z]:/ ) ]] || return 1
        case "$dir" in
            *\\*|*//*|../*|*/../*|*/..|*/./*|*/.) return 1 ;;
        esac
        normalized=$(_gitconfig_normalize_path "$dir") || return 1
        [[ "$normalized" == "$dir" ]] || return 1
    done
}

# ------------------------------------------------------------------------------
# Global managed block
# ------------------------------------------------------------------------------

# Usage: block=$(build_global_gitconfig_block)
build_global_gitconfig_block() {
    local gitdir_kw helper_policy_status=1
    gitdir_kw=$(get_gitdir_keyword) || return 1
    _gitconfig_collect_routes || return 1
    helper_policy_status=0
    _gitconfig_user_credential_helper_exists || helper_policy_status=$?
    [[ "$helper_policy_status" -le 1 ]] || {
        print_error "Cannot safely inspect the existing credential.helper policy."
        return 1
    }

    cat <<EOF
${GITSETU_MANAGED_START}
# Generated by gitsetu v${GITSETU_VERSION}; managed source
# Do not edit between managed markers; gitsetu owns and replaces this block.
# Everything outside these markers is preserved.

[user]
    useConfigOnly = true

[init]
    defaultBranch = main
EOF

    if [[ "$GITCONFIG_GLOBAL_COUNT" -eq 1 ]]; then
        local global_path
        global_path=$(_gitconfig_normalize_path "$GITSETU_PROFILES_DIR/${GITCONFIG_GLOBAL_LABEL}.gitconfig")
        cat <<EOF

[include]
    path = $(_gitconfig_quote_double_value "$global_path")
EOF
    fi

    # If the user already selected a helper, preserve that complete policy and
    # add none. Otherwise select the exact profile broker on every platform;
    # the broker chooses the native backend (including GCM on Git Bash). This
    # keeps the helper executable bound to the validated canonical checkout and
    # never silently substitutes a plaintext or platform-default helper.
    if [[ "$helper_policy_status" -eq 1 ]]; then
        _gitconfig_expected_helper || return 1
        cat <<EOF

[credential]
    helper = $(_gitconfig_quote_if_needed "$GITCONFIG_HELPER_VALUE")
EOF
    fi

    local i label dir escaped_dir path safe_root
    for (( i=0; i<${#GITCONFIG_ROUTE_LABELS[@]}; i++ )); do
        dir="${GITCONFIG_ROUTE_DIRS[$i]}"
        if [[ "$dir" != */ ]]; then dir="${dir}/"; fi
        escaped_dir=$(_gitconfig_escape_double "$dir")
        label="${GITCONFIG_ROUTE_LABELS[$i]}"
        path=$(_gitconfig_normalize_path "$GITSETU_PROFILES_DIR/${label}.gitconfig")

        if [[ "$i" -eq 0 ]]; then
            cat <<EOF

# Shallowest paths first: every matching includeIf is read and the last scalar
# value wins, so nested most-specific profiles are emitted last. A managed
# repository's linked-worktree gitdirs live below .git/worktrees and retain this route.
EOF
        fi
        cat <<EOF

[includeIf "${gitdir_kw}${escaped_dir}"]
    path = $(_gitconfig_quote_double_value "$path")

[safe]
    directory = $(_gitconfig_quote_double_value "${dir%/}")
    directory = $(_gitconfig_quote_double_value "${dir}*")
EOF
    done

    printf '\n%s\n' "$GITSETU_MANAGED_END"
}

_gitconfig_validate_managed_markers() {
    local path="$1" starts=0 ends=0 start_line=0 end_line=0
    starts=$(grep -Fxc "$GITSETU_MANAGED_START" "$path" 2>/dev/null || true)
    ends=$(grep -Fxc "$GITSETU_MANAGED_END" "$path" 2>/dev/null || true)
    if [[ "$starts" -eq 0 && "$ends" -eq 0 ]]; then return 1; fi
    [[ "$starts" -eq 1 && "$ends" -eq 1 ]] || {
        print_error "Malformed or duplicate gitsetu managed markers in $path; refusing to guess."
        return 2
    }
    start_line=$(grep -Fnx "$GITSETU_MANAGED_START" "$path" | head -n1 | cut -d: -f1)
    end_line=$(grep -Fnx "$GITSETU_MANAGED_END" "$path" | head -n1 | cut -d: -f1)
    [[ "$start_line" -lt "$end_line" ]] || {
        print_error "Reversed gitsetu managed markers in $path; refusing to rewrite."
        return 2
    }
    return 0
}

_gitconfig_new_private_temp() {
    local target="$1" directory
    directory=$(dirname "$target")
    GITCONFIG_TMP=$(umask 077; mktemp "${target}.tmp.XXXXXX" 2>/dev/null) || return 1
    chmod 600 "$GITCONFIG_TMP" 2>/dev/null || {
        rm -f "$GITCONFIG_TMP"
        return 1
    }
    if [[ -n "${GITSETU_CLEANUP_FILES+x}" ]]; then GITSETU_CLEANUP_FILES+=("$GITCONFIG_TMP"); fi
}

# Replace only one well-formed managed block; append when no block exists.
# User content outside the markers is never parsed or rewritten.
write_global_gitconfig() {
    local gitconfig="$HOME/.gitconfig" target managed_block marker_status

    _gitconfig_validate_persisted_paths || {
        print_error "Strict v2 Git configuration requires canonical, non-traversing profile directories."
        return 1
    }
    _gitconfig_collect_routes || return 1
    managed_block=$(build_global_gitconfig_block) || return 1
    target=$(_gitconfig_resolve_symlink_target "$gitconfig") || {
        print_error "Cannot resolve ~/.gitconfig symlink target."
        return 1
    }

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would update: $gitconfig"
        local line
        while IFS= read -r line; do printf >&2 '    %s\n' "$line"; done <<< "$managed_block"
        return 0
    fi

    if [[ -f "$target" ]]; then
        _gitconfig_validate_managed_markers "$target"
        marker_status=$?
        [[ "$marker_status" -ne 2 ]] || return 1
    else
        marker_status=1
    fi

    _gitconfig_new_private_temp "$target" || {
        print_error "Cannot create temporary ~/.gitconfig."
        return 1
    }
    if [[ -f "$target" && "$marker_status" -eq 0 ]]; then
        MANAGED_BLOCK="$managed_block" \
        GITSETU_MANAGED_START="$GITSETU_MANAGED_START" \
        GITSETU_MANAGED_END="$GITSETU_MANAGED_END" \
        awk '
            $0 == ENVIRON["GITSETU_MANAGED_START"] { in_block=1; print ENVIRON["MANAGED_BLOCK"]; next }
            in_block && $0 == ENVIRON["GITSETU_MANAGED_END"] { in_block=0; next }
            !in_block { print }
        ' "$target" > "$GITCONFIG_TMP"
        print_success "Updated managed block in: $gitconfig"
    elif [[ -f "$target" ]]; then
        cat "$target" > "$GITCONFIG_TMP" || return 1
        printf '\n%s\n' "$managed_block" >> "$GITCONFIG_TMP" || return 1
        print_success "Appended managed block to: $gitconfig"
    else
        printf '%s\n' "$managed_block" > "$GITCONFIG_TMP"
        print_success "Created: $gitconfig"
    fi
    unset MANAGED_BLOCK
    chmod 600 "$GITCONFIG_TMP" 2>/dev/null || return 1
    if [[ -f "$target" ]]; then backup_file "$target" || return 1; fi
    mv -f "$GITCONFIG_TMP" "$target" || return 1
    chmod 600 "$target" 2>/dev/null || return 1
}

# ------------------------------------------------------------------------------
# Per-profile Git configuration
# ------------------------------------------------------------------------------

# Usage: build_profile_gitconfig label name email sign key [provider] [provider_user]
build_profile_gitconfig() {
    local label="$1" name="$2" email="$3" sign_commits="${4:-0}" key_path="${5:-$HOME/.ssh/id_ed25519_$1}"
    local provider="${6:-}" provider_user="${7:-}"
    local portable_key signing_key escaped_provider

    _gitconfig_reject_multiline "Profile label" "$label" || return 1
    _gitconfig_reject_multiline "Git user name" "$name" || return 1
    _gitconfig_reject_multiline "Git user email" "$email" || return 1
    [[ -n "$name" && -n "$email" ]] || {
        print_error "Profile '$label' requires a non-empty name and email."
        return 1
    }
    if declare -f validate_label >/dev/null 2>&1; then
        validate_label "$label" || {
            print_error "Invalid profile label: $label"
            return 1
        }
    fi
    if declare -f validate_user_name >/dev/null 2>&1; then
        validate_user_name "$name" || {
            print_error "Invalid Git user name for profile '$label'."
            return 1
        }
    fi
    if declare -f validate_email >/dev/null 2>&1; then
        validate_email "$email" || {
            print_error "Invalid Git user email for profile '$label'."
            return 1
        }
    fi
    if declare -f validate_sign_flag >/dev/null 2>&1; then
        validate_sign_flag "$sign_commits" || {
            print_error "Invalid sign_commits flag for profile '$label'."
            return 1
        }
    else
        [[ "$sign_commits" == "0" || "$sign_commits" == "1" ]] || {
            print_error "Invalid sign_commits flag for profile '$label'."
            return 1
        }
    fi
    key_path=$(_gitconfig_normalize_key_path "$key_path") || return 1
    portable_key=$(_gitconfig_portable_key_path "$key_path") || return 1
    _gitconfig_build_ssh_command "$key_path" || return 1

    if [[ -n "$provider" || -n "$provider_user" ]]; then
        [[ -n "$provider" ]] || {
            print_error "Credential username requires a provider for profile '$label'."
            return 1
        }
        _gitconfig_reject_multiline "Credential provider" "$provider" || return 1
        _gitconfig_reject_multiline "Credential username" "$provider_user" || return 1
        if declare -f validate_provider >/dev/null 2>&1; then
            validate_provider "$provider" || {
                print_error "Invalid credential provider for profile '$label': $provider"
                return 1
            }
        else
            _gitconfig_valid_provider "$provider" || {
                print_error "Invalid credential provider for profile '$label': $provider"
                return 1
            }
        fi
        if declare -f validate_provider_user >/dev/null 2>&1; then
            validate_provider_user "$provider_user" || {
                print_error "Invalid credential username for profile '$label'."
                return 1
            }
        fi
    fi

    cat <<EOF
${GITSETU_MANAGED_START} Profile: ${label}
# Generated by gitsetu v${GITSETU_VERSION}; managed source
# Auto-included for the managed profile '${label}'. Do not edit.

[user]
    name = $(_gitconfig_quote_if_needed "$name")
    email = $(_gitconfig_quote_if_needed "$email")
EOF

    if [[ "$sign_commits" == "1" ]]; then
        signing_key="${portable_key}.pub"
        cat <<EOF
    signingkey = $(_gitconfig_quote_if_needed "$signing_key")

[gpg]
    format = ssh

[commit]
    gpgsign = true
EOF
    fi

    cat <<EOF

[core]
    sshCommand = $(_gitconfig_quote_if_needed "$GITCONFIG_SSH_COMMAND")
EOF

    if [[ -n "$provider" && -n "$provider_user" ]]; then
        escaped_provider=$(_gitconfig_escape_double "https://${provider}")
        cat <<EOF

[credential "${escaped_provider}"]
    username = $(_gitconfig_quote_if_needed "$provider_user")
EOF
    fi

    printf '\n%s Profile: %s\n' "$GITSETU_MANAGED_END" "$label"
}

write_profile_gitconfig() {
    local label="$1" name="$2" email="$3" sign_commits="${4:-0}"
    local key_path="${5:-$HOME/.ssh/id_ed25519_$1}" provider="${6:-}" provider_user="${7:-}"
    local profile_path="$GITSETU_PROFILES_DIR/${label}.gitconfig" content

    if [[ -L "$profile_path" ]]; then
        print_error "Refusing to replace symlinked profile config: $profile_path"
        return 1
    fi
    content=$(build_profile_gitconfig "$label" "$name" "$email" "$sign_commits" "$key_path" "$provider" "$provider_user") || return 1
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would create: $profile_path"
        return 0
    fi
    ensure_dirs || return 1
    _gitconfig_new_private_temp "$profile_path" || {
        print_error "Cannot create temporary profile config."
        return 1
    }
    printf '%s\n' "$content" > "$GITCONFIG_TMP" || return 1
    chmod 600 "$GITCONFIG_TMP" 2>/dev/null || return 1
    mv -f "$GITCONFIG_TMP" "$profile_path" || return 1
    chmod 600 "$profile_path" 2>/dev/null || return 1
    print_success "Created profile config: $profile_path"
}

# ------------------------------------------------------------------------------
# v2 registry persistence adapter
# ------------------------------------------------------------------------------

# Core owns the structured v2 schema and atomic writer. Kept as a narrow adapter
# for existing setup call sites; it never writes or reads a v1 colon record.
write_profiles_conf() {
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would create: $GITSETU_PROFILES_CONF"
        return 0
    fi
    if ! declare -f write_profiles_registry >/dev/null 2>&1; then
        print_error "The structured v2 profile registry writer is unavailable; refusing to write a legacy profiles.conf."
        return 1
    fi

    # Validate every v2 field before creating any payload. Defaults belong only
    # to explicit new-profile input, never to persisted v2 profile state.
    local count="${PROFILE_COUNT:-0}" i label name email sign key provider user directory
    for (( i=0; i<count; i++ )); do
        if [[ ! ${PROFILE_LABELS[$i]+x} || ! ${PROFILE_NAMES[$i]+x} || ! ${PROFILE_EMAILS[$i]+x} ||
              ! ${PROFILE_DIRS[$i]+x} || ! ${PROFILE_PROVIDERS[$i]+x} || ! ${PROFILE_SIGNS[$i]+x} ||
              ! ${PROFILE_KEYS[$i]+x} || ! ${PROFILE_USERS[$i]+x} ]]; then
            print_error "Strict v2 registry requires all profile arrays at index $i; no defaults are assumed."
            return 1
        fi
        label="${PROFILE_LABELS[$i]}"
        name="${PROFILE_NAMES[$i]}"
        email="${PROFILE_EMAILS[$i]}"
        directory="${PROFILE_DIRS[$i]}"
        provider="${PROFILE_PROVIDERS[$i]}"
        sign="${PROFILE_SIGNS[$i]}"
        key="${PROFILE_KEYS[$i]}"
        user="${PROFILE_USERS[$i]}"
        [[ -n "$provider" && -n "$key" ]] || {
            print_error "Strict v2 registry has an empty provider or key_path for '$label'."
            return 1
        }
        if declare -f validate_profile_record >/dev/null 2>&1; then
            validate_profile_record "$label" "$directory" "$provider" "$sign" "$key" "$user" || {
                print_error "Strict v2 registry validation failed for '$label'."
                return 1
            }
        else
            print_error "Strict v2 registry validators are unavailable."
            return 1
        fi
        if declare -f validate_user_name >/dev/null 2>&1 && declare -f validate_email >/dev/null 2>&1; then
            if ! validate_user_name "$name" || ! validate_email "$email"; then
                print_error "Strict v2 profile identity is invalid for '$label'."
                return 1
            fi
        fi
    done

    ensure_dirs || return 1

    # v2 identities have one source of truth: the generated profile gitconfig.
    # Compile every payload before exposing the registry that references it.
    for (( i=0; i<count; i++ )); do
        label="${PROFILE_LABELS[$i]}"
        name="${PROFILE_NAMES[$i]}"
        email="${PROFILE_EMAILS[$i]}"
        sign="${PROFILE_SIGNS[$i]}"
        key="${PROFILE_KEYS[$i]}"
        provider="${PROFILE_PROVIDERS[$i]}"
        user="${PROFILE_USERS[$i]}"
        write_profile_gitconfig "$label" "$name" "$email" "$sign" "$key" "$provider" "$user" || return 1
    done

    write_profiles_registry "$GITSETU_PROFILES_CONF" || return 1
    print_success "Created v2 profile registry: $GITSETU_PROFILES_CONF"

    # Prune only generated profile payloads no longer represented in memory.
    local pfile plabel j found
    for pfile in "$GITSETU_PROFILES_DIR"/*.gitconfig; do
        [[ -f "$pfile" ]] || continue
        plabel=$(basename "$pfile" .gitconfig)
        found=0
        for (( j=0; j<${PROFILE_COUNT:-0}; j++ )); do
            if [[ "${PROFILE_LABELS[$j]}" == "$plabel" ]]; then
                found=1
                break
            fi
        done
        [[ "$found" -eq 1 ]] || rm -f "$pfile"
    done
}
