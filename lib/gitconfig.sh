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
        if declare -F is_canonical_path >/dev/null 2>&1; then
            is_canonical_path "$dir" || return 1
        else
            normalized=$(_gitconfig_normalize_path "$dir") || return 1
            [[ "$normalized" == "$dir" ]] || return 1
        fi
    done
}

# ------------------------------------------------------------------------------
# Global managed block
# ------------------------------------------------------------------------------

# Usage: block=$(build_global_gitconfig_head_block)
build_global_gitconfig_head_block() {
    _gitconfig_collect_routes || return 1
    cat <<EOF
${GITSETU_MANAGED_HEAD_START}
# Generated by gitsetu v${GITSETU_VERSION}; managed head source
# Fallback identity and baseline constraints live here so user rules override them.
[user]
    useConfigOnly = true
EOF

    if [[ "$GITCONFIG_GLOBAL_COUNT" -eq 1 ]]; then
        local global_path
        global_path=$(_gitconfig_normalize_path "$GITSETU_PROFILES_DIR/${GITCONFIG_GLOBAL_LABEL}.gitconfig")
        cat <<EOF

[include]
    path = $(_gitconfig_quote_double_value "$global_path")
EOF
    fi

    printf '\n%s\n' "$GITSETU_MANAGED_HEAD_END"
}

# Usage: block=$(build_global_gitconfig_tail_block)
build_global_gitconfig_tail_block() {
    local gitdir_kw
    gitdir_kw=$(get_gitdir_keyword) || return 1
    _gitconfig_collect_routes || return 1

    cat <<EOF
${GITSETU_MANAGED_START}
# Generated by gitsetu v${GITSETU_VERSION}; managed routes
# Profile includeIf rules live at the bottom so GitSetu profile routes take precedence.
EOF

    local i label dir escaped_dir path
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
EOF
    done

    # FUT-01: remote URL routing if remote files exist
    local remotes_dir="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/remotes"
    if [[ -d "$remotes_dir" ]]; then
        local rem_file rem_label rem_pat
        for rem_file in "$remotes_dir"/*.remotes; do
            [[ -f "$rem_file" ]] || continue
            rem_label=$(basename "$rem_file" .remotes)
            path=$(_gitconfig_normalize_path "$GITSETU_PROFILES_DIR/${rem_label}.gitconfig")
            while IFS= read -r rem_pat || [[ -n "$rem_pat" ]]; do
                rem_pat=$(printf '%s' "$rem_pat" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                [[ -n "$rem_pat" && "$rem_pat" != \#* ]] || continue
                cat <<EOF

[includeIf "hasconfig:remote.*.url:${rem_pat}"]
    path = $(_gitconfig_quote_double_value "$path")
EOF
            done < "$rem_file"
        done
    fi

    printf '\n%s\n' "$GITSETU_MANAGED_END"
}

# Compatibility wrapper returning full combined managed text
build_global_gitconfig_block() {
    local head tail
    head=$(build_global_gitconfig_head_block) || return 1
    tail=$(build_global_gitconfig_tail_block) || return 1
    printf '%s\n\n%s\n' "$head" "$tail"
}

_gitconfig_validate_managed_markers() {
    local path="$1"
    local head_starts=0 head_ends=0 tail_starts=0 tail_ends=0
    local head_start_line=0 head_end_line=0 tail_start_line=0 tail_end_line=0

    head_starts=$(grep -Fxc "$GITSETU_MANAGED_HEAD_START" "$path" 2>/dev/null || true)
    head_ends=$(grep -Fxc "$GITSETU_MANAGED_HEAD_END" "$path" 2>/dev/null || true)
    tail_starts=$(grep -Fxc "$GITSETU_MANAGED_START" "$path" 2>/dev/null || true)
    tail_ends=$(grep -Fxc "$GITSETU_MANAGED_END" "$path" 2>/dev/null || true)

    if [[ "$head_starts" -eq 0 && "$head_ends" -eq 0 && "$tail_starts" -eq 0 && "$tail_ends" -eq 0 ]]; then
        return 1
    fi

    if [[ "$head_starts" -ne "$head_ends" || "$head_starts" -gt 1 ]]; then
        print_error "Malformed or duplicate gitsetu managed head markers in $path; refusing to guess."
        return 2
    fi
    if [[ "$head_starts" -eq 1 ]]; then
        head_start_line=$(grep -Fnx "$GITSETU_MANAGED_HEAD_START" "$path" | head -n1 | cut -d: -f1)
        head_end_line=$(grep -Fnx "$GITSETU_MANAGED_HEAD_END" "$path" | head -n1 | cut -d: -f1)
        if [[ "$head_start_line" -ge "$head_end_line" ]]; then
            print_error "Reversed gitsetu managed head markers in $path; refusing to rewrite."
            return 2
        fi
    fi

    if [[ "$tail_starts" -ne "$tail_ends" || "$tail_starts" -gt 1 ]]; then
        print_error "Malformed or duplicate gitsetu managed markers in $path; refusing to guess."
        return 2
    fi
    if [[ "$tail_starts" -eq 1 ]]; then
        tail_start_line=$(grep -Fnx "$GITSETU_MANAGED_START" "$path" | head -n1 | cut -d: -f1)
        tail_end_line=$(grep -Fnx "$GITSETU_MANAGED_END" "$path" | head -n1 | cut -d: -f1)
        if [[ "$tail_start_line" -ge "$tail_end_line" ]]; then
            print_error "Reversed gitsetu managed markers in $path; refusing to rewrite."
            return 2
        fi
    fi

    if [[ "$head_starts" -eq 1 && "$tail_starts" -eq 1 ]]; then
        if [[ "$head_end_line" -ge "$tail_start_line" ]]; then
            print_error "Overlapping or reversed gitsetu managed blocks in $path; refusing to rewrite."
            return 2
        fi
    fi

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

_gitconfig_list_kept_user_routes() {
    local target="$1"
    [[ -f "$target" ]] || return 0

    local unmanaged
    unmanaged=$(
        HEAD_START="$GITSETU_MANAGED_HEAD_START" \
        HEAD_END="$GITSETU_MANAGED_HEAD_END" \
        TAIL_START="$GITSETU_MANAGED_START" \
        TAIL_END="$GITSETU_MANAGED_END" \
        awk '
            $0 == ENVIRON["HEAD_START"] { in_head=1; next }
            in_head && $0 == ENVIRON["HEAD_END"] { in_head=0; next }
            $0 == ENVIRON["TAIL_START"] { in_tail=1; next }
            in_tail && $0 == ENVIRON["TAIL_END"] { in_tail=0; next }
            !in_head && !in_tail { print }
        ' "$target"
    )

    local cur_dir="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[includeIf[[:space:]]+\"gitdir:([^\"]+)\"\] ]]; then
            cur_dir="${BASH_REMATCH[1]}"
        elif [[ -n "$cur_dir" && "$line" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*) ]]; then
            local p="${BASH_REMATCH[1]}"
            p="${p%\"}"
            p="${p#\"}"
            print_info "kept: ${cur_dir} -> ${p}"
            local i
            for (( i=0; i<${#GITCONFIG_ROUTE_DIRS[@]}; i++ )); do
                local pdir="${GITCONFIG_ROUTE_DIRS[$i]}"
                local plabel="${GITCONFIG_ROUTE_LABELS[$i]}"
                local norm_cd="${cur_dir%/}"
                local norm_pd="${pdir%/}"
                norm_cd="${norm_cd#~}"
                norm_pd="${norm_pd#"$HOME"}"
                if [[ "$norm_cd" == "$norm_pd" || "$cur_dir" == "$pdir" ]]; then
                    print_warning "${cur_dir}: your rule and profile '${plabel}' both apply; the GitSetu profile wins."
                fi
            done
            cur_dir=""
        fi
    done <<< "$unmanaged"
}

# Replace managed blocks: Head block at line 1, Tail block at bottom.
# User content outside the markers is preserved in the middle.
write_global_gitconfig() {
    local gitconfig="$HOME/.gitconfig" target head_block tail_block marker_status
    local unmanaged_content=""

    _gitconfig_validate_persisted_paths || {
        print_error "Strict v2 Git configuration requires canonical, non-traversing profile directories."
        return 1
    }
    _gitconfig_collect_routes || return 1
    head_block=$(build_global_gitconfig_head_block) || return 1
    tail_block=$(build_global_gitconfig_tail_block) || return 1
    target=$(_gitconfig_resolve_symlink_target "$gitconfig") || {
        print_error "Cannot resolve ~/.gitconfig symlink target."
        return 1
    }

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would update: $gitconfig"
        local line
        while IFS= read -r line; do printf >&2 '    %s\n' "$line"; done <<< "$head_block"
        while IFS= read -r line; do printf >&2 '    %s\n' "$line"; done <<< "$tail_block"
        return 0
    fi

    if [[ -f "$target" ]]; then
        if command -v git >/dev/null 2>&1; then
            if ! git config --file "$target" --list >/dev/null 2>&1; then
                print_error "Existing $gitconfig is malformed; refusing to overwrite."
                return 1
            fi
        fi
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

    if [[ -f "$target" ]]; then
        unmanaged_content=$(
            HEAD_START="$GITSETU_MANAGED_HEAD_START" \
            HEAD_END="$GITSETU_MANAGED_HEAD_END" \
            TAIL_START="$GITSETU_MANAGED_START" \
            TAIL_END="$GITSETU_MANAGED_END" \
            awk '
                $0 == ENVIRON["HEAD_START"] { in_head=1; next }
                in_head && $0 == ENVIRON["HEAD_END"] { in_head=0; next }
                $0 == ENVIRON["TAIL_START"] { in_tail=1; next }
                in_tail && $0 == ENVIRON["TAIL_END"] { in_tail=0; next }
                !in_head && !in_tail { print }
            ' "$target"
        )
    fi

    local trimmed_user_content=""
    if [[ -n "$unmanaged_content" ]]; then
        trimmed_user_content=$(printf '%s\n' "$unmanaged_content" | awk '
            NF { seen=1 }
            seen { lines[NR]=$0; last_non_blank=NR }
            END { for(i=1; i<=last_non_blank; i++) print lines[i] }
        ')
    fi

    {
        printf '%s\n' "$head_block"
        if [[ -n "$trimmed_user_content" ]]; then
            printf '\n%s\n' "$trimmed_user_content"
        fi
        printf '\n%s\n' "$tail_block"
    } > "$GITCONFIG_TMP"

    chmod 600 "$GITCONFIG_TMP" 2>/dev/null || return 1
    if [[ -f "$target" ]]; then backup_file "$target" || return 1; fi
    mv -f "$GITCONFIG_TMP" "$target" || return 1
    chmod 600 "$target" 2>/dev/null || return 1

    print_success "Updated managed blocks in: $gitconfig"

    _gitconfig_list_kept_user_routes "$target"
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

[tag]
    gpgsign = true
EOF
    else
        cat <<EOF

[commit]
    gpgsign = false

[tag]
    gpgsign = false
EOF
    fi

    local is_default_key=0
    case "$(basename "$key_path")" in
        id_rsa|id_ecdsa|id_ecdsa_sk|id_ed25519|id_ed25519_sk)
            is_default_key=1
            ;;
    esac

    local emit_ssh_cmd=0
    if [[ "$label" != "global" || "$is_default_key" -eq 0 ]]; then
        emit_ssh_cmd=1
    fi

    local emit_hooks_path=0
    local hooks_dir_enabled="${GITSETU_HOOKS_DIR:-${GITSETU_CONFIG_DIR:-${HOME}/.config/gitsetu}/hooks}/enabled"
    if [[ "$label" != "global" && -f "$hooks_dir_enabled" ]]; then
        emit_hooks_path=1
    fi

    if [[ "$emit_ssh_cmd" -eq 1 || "$emit_hooks_path" -eq 1 ]]; then
        printf '\n[core]\n'
        if [[ "$emit_ssh_cmd" -eq 1 ]]; then
            printf '    sshCommand = %s\n' "$(_gitconfig_quote_if_needed "$GITCONFIG_SSH_COMMAND")"
        fi
        if [[ "$emit_hooks_path" -eq 1 ]]; then
            local hooks_dir_path="${GITSETU_HOOKS_DIR:-${GITSETU_CONFIG_DIR:-${HOME}/.config/gitsetu}/hooks}"
            hooks_dir_path=$(normalize_path "$hooks_dir_path") || hooks_dir_path="${GITSETU_HOOKS_DIR:-${HOME}/.config/gitsetu/hooks}"
            printf '    hooksPath = %s\n' "$(_gitconfig_quote_if_needed "$hooks_dir_path")"
        fi
    fi

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
