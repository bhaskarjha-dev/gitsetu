#!/usr/bin/env bash
# lib/verify.sh — Offline identity verification and opt-in connectivity tests
# Bash 3.2 compatible.

_verify_has_control_chars() {
    local value="${1:-}"
    if declare -f _gitsetu_contains_ascii_control >/dev/null 2>&1; then
        _gitsetu_contains_ascii_control "$value"
        return $?
    fi
    [[ "$value" == *$'\r'* || "$value" == *$'\n'* || "$value" == *$'\t'* || "$value" == *[[:cntrl:]]* ]]
}

_verify_runtime_key_safe() {
    local key_path="${1:-}"
    local key_parent canonical owner current_user
    [[ -n "$key_path" ]] || return 1
    if declare -f _gitsetu_reject_ascii_controls >/dev/null 2>&1; then
        _gitsetu_reject_ascii_controls "SSH key path" "$key_path" || return 1
    else
        [[ ! "$key_path" =~ [[:cntrl:]] ]] || return 1
    fi
    case "$key_path" in
        /*|[A-Za-z]:/*) ;;
        *) return 1 ;;
    esac
    case "$key_path" in
        *\\*|*//*|*/../*|*/./*) return 1 ;;
    esac
    [[ -f "$key_path" && ! -L "$key_path" && -O "$key_path" ]] || return 1
    if [[ "$key_path" =~ ^[A-Za-z]:/ ]]; then
        key_parent=$(cd -P -- "$(dirname "$key_path")" 2>/dev/null && (pwd -W 2>/dev/null || pwd -P)) || return 1
    else
        key_parent=$(cd -P -- "$(dirname "$key_path")" 2>/dev/null && pwd -P) || return 1
    fi
    canonical="${key_parent%/}/${key_path##*/}"
    [[ "$key_path" == "$canonical" ]] || return 1
    [[ -d "$key_parent" && ! -L "$key_parent" ]] || return 1
    if declare -f _ssh_assert_no_symlink_components >/dev/null 2>&1; then
        _ssh_assert_no_symlink_components "$key_parent" || return 1
    fi
    if declare -f _ssh_assert_private_directory >/dev/null 2>&1; then
        _ssh_assert_private_directory "$key_parent" || return 1
    fi
    if command -v stat >/dev/null 2>&1 && command -v id >/dev/null 2>&1; then
        owner=$(stat -c '%U' "$key_path" 2>/dev/null || stat -f '%Su' "$key_path" 2>/dev/null || true)
        current_user=$(id -un 2>/dev/null || true)
        [[ -z "$owner" || -z "$current_user" || "$owner" == "$current_user" ]] || return 1
    fi
    return 0
}

_verify_stat_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf '???'
}

_verify_stat_fstype() {
    stat -f -c '%T' "$1" 2>/dev/null || stat -f '%T' "$1" 2>/dev/null || printf ''
}

_verify_is_supported_ntfs() {
    local path="${1:-}"
    local fs_type
    fs_type=$(_verify_stat_fstype "$path")
    if [[ -z "$fs_type" || "$fs_type" == UNKNOWN* ]]; then
        fs_type=$(df -PT "$path" 2>/dev/null | awk 'NR == 2 { print $2 }')
    fi
    fs_type=$(printf '%s' "$fs_type" | tr '[:upper:]' '[:lower:]')
    case "${OSTYPE:-}:$fs_type" in
        cygwin:*ntfs|msys:*ntfs|mingw:*ntfs|cygwin:*msfs|msys:*msfs|mingw:*msfs) return 0 ;;
    esac
    case "$fs_type" in
        msfs|ntfs|ntfs3|ntfs-3g|fuseblk|drvfs) return 0 ;;
        *) return 1 ;;
    esac
}

_verify_key_fingerprint() {
    local key_file="${1:-}"
    ssh-keygen -lf "$key_file" 2>/dev/null | awk 'NR == 1 { print $2 }'
}

_verify_extract_email_from_ident() {
    local ident="${1:-}"
    local email
    [[ "$ident" == *"<"*"> "* ]] || return 1
    email="${ident##*<}"
    email="${email%%>*}"
    printf '%s\n' "$email"
}

_verify_first_repo_under() {
    local root="${1:-}"
    local marker repo

    [[ -d "$root" ]] || return 1
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        repo=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
        [[ -n "$repo" ]] || return 1
        printf '%s\n' "$repo"
        return 0
    fi

    while IFS= read -r -d '' marker; do
        repo="${marker%/.git}"
        [[ -n "$repo" ]] || continue
        printf '%s\n' "$repo"
        return 0
    done < <(find "$root" -maxdepth 3 -name .git -print0 2>/dev/null)
    return 1
}

# ------------------------------------------------------------------------------
# verify_ssh_keys
# ------------------------------------------------------------------------------

verify_ssh_keys() {
    local issues=0
    local i label key_path pub_path perms private_fp public_fp

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        print_error "ssh-keygen is unavailable; SSH key correspondence cannot be verified."
        return 1
    fi

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        key_path="${PROFILE_KEYS[$i]-}"
        if [[ -z "$key_path" ]] || ! _verify_runtime_key_safe "$key_path"; then
            print_error "Profile '$label': key field is missing, non-canonical, or unsafe: ${key_path:-<empty>}"
            issues=$((issues + 1))
            continue
        fi
        pub_path="${key_path}.pub"
        _verify_has_control_chars "$key_path" && {
            print_error "Profile '$label': key path contains control characters."
            issues=$((issues + 1))
            continue
        }
        if [[ -L "$pub_path" || ! -f "$pub_path" || ! -O "$pub_path" ]]; then
            print_error "Missing or unsafe public key: $pub_path"
            issues=$((issues + 1))
            continue
        fi

        perms=$(_verify_stat_mode "$key_path")
        if [[ "$perms" == "600" ]] || { [[ "$perms" == "644" ]] && _verify_is_supported_ntfs "$key_path"; }; then
            :
        else
            print_warning "Incorrect permissions on $key_path: $perms (should be 600)"
            issues=$((issues + 1))
        fi

        private_fp=$(_verify_key_fingerprint "$key_path")
        public_fp=$(_verify_key_fingerprint "$pub_path")
        if [[ -z "$private_fp" || -z "$public_fp" ]]; then
            print_error "Profile '$label': private/public key could not be parsed."
            issues=$((issues + 1))
        elif [[ "$private_fp" != "$public_fp" ]]; then
            print_error "Profile '$label': private/public key fingerprints do not match."
            issues=$((issues + 1))
        fi
    done

    [[ "$issues" -eq 0 ]]
}

# ------------------------------------------------------------------------------
# verify_git_config
# ------------------------------------------------------------------------------

verify_git_config() {
    local issues=0
    local i label profile_path expected actual dir repo
    local author_ident committer_ident author_email committer_email

    if ! command -v git >/dev/null 2>&1; then
        print_error "Git is unavailable; configuration cannot be verified."
        return 1
    fi
    if ! load_profiles; then
        print_error "Profile registry is invalid, incomplete, or uses an unsupported format."
        return 1
    fi
    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        print_error "Profile registry contains no profiles."
        return 1
    fi

    if [[ -z "${HOME:-}" || -L "$HOME/.gitconfig" || ! -f "$HOME/.gitconfig" ]]; then
        print_error "Global gitconfig missing or unsafe: $HOME/.gitconfig"
        return 1
    fi
    if ! git config --file "$HOME/.gitconfig" --list >/dev/null 2>&1; then
        print_error "Global gitconfig contains invalid syntax: $HOME/.gitconfig"
        issues=$((issues + 1))
    fi

    local start_count end_count
    start_count=$(grep -F -c "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}" "$HOME/.gitconfig" 2>/dev/null || printf '0')
    end_count=$(grep -F -c "${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}" "$HOME/.gitconfig" 2>/dev/null || printf '0')
    if [[ "$start_count" != "1" || "$end_count" != "1" ]]; then
        print_error "Global gitconfig must contain exactly one complete GitSetu managed block."
        issues=$((issues + 1))
    fi

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        expected="${PROFILE_EMAILS[$i]:-}"
        profile_path="$GITSETU_PROFILES_DIR/${label}.gitconfig"

        if [[ -z "$label" || -z "$expected" ]]; then
            print_error "Profile '$label': registry is missing its label or expected email."
            issues=$((issues + 1))
            continue
        fi
        if declare -f validate_profile_record >/dev/null 2>&1 && \
           ! validate_profile_record "$label" "${PROFILE_DIRS[$i]:-}" "${PROFILE_PROVIDERS[$i]:-}" \
               "${PROFILE_SIGNS[$i]:-}" "${PROFILE_KEYS[$i]:-}" "${PROFILE_USERS[$i]:-}"; then
            print_error "Profile '$label': registry fields failed strict v2 validation."
            issues=$((issues + 1))
            continue
        fi
        if declare -f validate_email >/dev/null 2>&1 && ! validate_email "$expected"; then
            print_error "Profile '$label': expected email is invalid: $expected"
            issues=$((issues + 1))
            continue
        fi
        if [[ -L "$profile_path" || ! -f "$profile_path" ]]; then
            print_error "Missing or unsafe profile config: $profile_path"
            issues=$((issues + 1))
            continue
        fi
        if ! git config --file "$profile_path" --list >/dev/null 2>&1; then
            print_error "Profile '$label': config contains invalid syntax: $profile_path"
            issues=$((issues + 1))
            continue
        fi

        actual=$(git config --file "$profile_path" user.email 2>/dev/null || true)
        if [[ -z "$actual" ]]; then
            print_error "Profile '$label': user.email is not set in $profile_path"
            issues=$((issues + 1))
        elif [[ "$actual" != "$expected" ]]; then
            print_error "Profile '$label': expected '$expected', got '$actual' in $profile_path"
            issues=$((issues + 1))
        fi
    done

    # Validate effective identity in real repositories, including environment
    # overrides that take precedence over Git configuration.
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        expected="${PROFILE_EMAILS[$i]:-}"
        dir="${PROFILE_DIRS[$i]:-}"
        [[ -n "$dir" ]] || continue
        repo=$(_verify_first_repo_under "$dir" 2>/dev/null || true)
        [[ -n "$repo" ]] || continue

        if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
            author_email="$GIT_AUTHOR_EMAIL"
        else
            author_ident=$(git -C "$repo" var GIT_AUTHOR_IDENT 2>/dev/null || true)
            author_email=$(_verify_extract_email_from_ident "$author_ident" 2>/dev/null || true)
        fi
        if [[ -n "${GIT_COMMITTER_EMAIL:-}" ]]; then
            committer_email="$GIT_COMMITTER_EMAIL"
        else
            committer_ident=$(git -C "$repo" var GIT_COMMITTER_IDENT 2>/dev/null || true)
            committer_email=$(_verify_extract_email_from_ident "$committer_ident" 2>/dev/null || true)
        fi

        if [[ -z "$author_email" || -z "$committer_email" ]]; then
            print_error "Profile '$label': effective author/committer identity is unresolved in $repo"
            issues=$((issues + 1))
            continue
        fi
        if [[ "$author_email" != "$expected" || "$committer_email" != "$expected" ]]; then
            print_error "Profile '$label': effective identity mismatch in $repo (author='$author_email', committer='$committer_email')"
            issues=$((issues + 1))
        else
            print_success "Profile '$label': effective identity correct in $repo"
        fi
    done

    [[ "$issues" -eq 0 ]]
}

# ------------------------------------------------------------------------------
# verify_ssh_connectivity — explicit opt-in network check
# ------------------------------------------------------------------------------

verify_ssh_connectivity() {
    if [[ "${GITSETU_DRY_RUN:-0}" == "1" ]]; then
        print_info "SKIPPED: dry-run connectivity verification makes no network or known_hosts changes."
        return 1
    fi

    local failed=0
    local i label provider prefix host tmp_out pid rc output tmp_base

    if ! command -v ssh >/dev/null 2>&1; then
        print_error "ssh is unavailable; connectivity cannot be tested."
        return 1
    fi

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        provider="${PROFILE_PROVIDERS[$i]:-github.com}"
        prefix=$(printf '%s' "$provider" | cut -d'.' -f1)
        host="${prefix}-${label}"

        tmp_out=""
        for tmp_base in /tmp /var/tmp; do
            [[ -d "$tmp_base" && -w "$tmp_base" && ! -L "$tmp_base" ]] || continue
            tmp_out=$(umask 077; mktemp "${tmp_base%/}/gitsetu-verify.XXXXXX" 2>/dev/null || true)
            [[ -n "$tmp_out" && -f "$tmp_out" && ! -L "$tmp_out" && -O "$tmp_out" ]] || {
                rm -f "$tmp_out" 2>/dev/null || true
                tmp_out=""
                continue
            }
            chmod 600 "$tmp_out" 2>/dev/null || {
                rm -f "$tmp_out" 2>/dev/null || true
                tmp_out=""
                continue
            }
            break
        done
        [[ -n "$tmp_out" ]] || {
            print_error "Unable to create a private connectivity-test output file."
            return 1
        }
        if [[ -n "${GITSETU_CLEANUP_FILES+x}" ]]; then
            GITSETU_CLEANUP_FILES+=("$tmp_out")
        fi

        local strict_mode="yes"
        if ! ssh-keygen -F "$host" >/dev/null 2>&1; then
            if [[ "${GITSETU_ALLOW_SSH_HOST_KEY:-0}" != "1" && "${GITSETU_SSH_ACCEPT_NEW_HOST:-0}" != "1" ]]; then
                printf >&2 '  %s%s first-use host key for %s is not trusted; connection refused.%b\n' \
                    "$YELLOW" "$SYM_WARN" "$host" "$RESET"
                printf >&2 '    No SSH connection was attempted. Set GITSETU_ALLOW_SSH_HOST_KEY=1 to approve this first use explicitly.\n'
                rm -f "$tmp_out"
                return 1
            fi
            strict_mode="accept-new"
            printf >&2 '  %sExplicitly approved first-use host key for %s.%s\n' "$DIM" "$host" "$RESET"
        fi

        printf >&2 '  Testing SSH: %s ... ' "$host"
        ssh -T -o ConnectTimeout=5 -o "StrictHostKeyChecking=${strict_mode}" -o LogLevel=ERROR \
            "git@${host}" >"$tmp_out" 2>&1 &
        pid=$!
        rc=0
        wait "$pid" || rc=$?
        output=$(cat "$tmp_out" 2>/dev/null || true)
        rm -f "$tmp_out"

        if printf '%s' "$output" | grep -qi 'successfully authenticated\|logged in as\|welcome to'; then
            printf >&2 '%b%s authenticated%b\n' "$GREEN" "$SYM_CHECK" "$RESET"
        elif printf '%s' "$output" | grep -qi 'permission denied'; then
            printf >&2 '%b%s key not added to %s%b\n' "$YELLOW" "$SYM_WARN" "$provider" "$RESET"
            failed=1
        elif printf '%s' "$output" | grep -qi 'could not resolve\|connection refused\|timed out\|connection reset'; then
            printf >&2 '%b%s connection failed (exit %s)%b\n' "$RED" "$SYM_CROSS" "$rc" "$RESET"
            failed=1
        else
            printf >&2 '%b%s unknown response (exit %s)%b\n' "$DIM" "$SYM_INFO" "$rc" "$RESET"
            failed=1
        fi
    done

    [[ "$failed" -eq 0 ]]
}

# ------------------------------------------------------------------------------
# verify_all
# ------------------------------------------------------------------------------

verify_all() {
    print_section "Verification Results"

    local issues=0
    local i label email key_path perms safe_label safe_email
    local key_status perm_status config_status

    printf >&2 '  %-12s %-30s %-10s %-10s %-12s\n' \
        "Profile" "Email" "SSH Key" "Perms" "Config"
    printf >&2 '  %-12s %-30s %-10s %-10s %-12s\n' \
        "-------" "-----" "-------" "-----" "------"

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        email="${PROFILE_EMAILS[$i]:-}"
        key_path="${PROFILE_KEYS[$i]-}"

        if _verify_runtime_key_safe "$key_path" && [[ -f "${key_path}.pub" && ! -L "${key_path}.pub" && -O "${key_path}.pub" ]]; then
            key_status="${GREEN}${SYM_CHECK}${RESET}"
        else
            key_status="${RED}${SYM_CROSS}${RESET}"
        fi

        if [[ -f "$key_path" ]]; then
            perms=$(_verify_stat_mode "$key_path")
            if [[ "$perms" == "600" ]] || { [[ "$perms" == "644" ]] && _verify_is_supported_ntfs "$key_path"; }; then
                perm_status="${GREEN}${SYM_CHECK}${RESET}"
            else
                perm_status="${YELLOW}${SYM_WARN} ${perms}${RESET}"
            fi
        else
            perm_status="${DIM}-${RESET}"
        fi

        if [[ -f "$GITSETU_PROFILES_DIR/${label}.gitconfig" && ! -L "$GITSETU_PROFILES_DIR/${label}.gitconfig" ]]; then
            config_status="${GREEN}${SYM_CHECK}${RESET}"
        else
            config_status="${RED}${SYM_CROSS}${RESET}"
        fi

        safe_label=$(escape_terminal_text "$label")
        safe_email=$(escape_terminal_text "$email")
        printf >&2 "  %-12s %-30s %b     %b     %b\n" \
            "$safe_label" "$safe_email" "$key_status" "$perm_status" "$config_status"
    done
    printf >&2 '\n'

    print_section "Required Offline Validation"
    if verify_ssh_keys; then
        print_success "SSH key files, permissions, and key pairs are valid."
    else
        print_error "SSH key validation failed."
        issues=$((issues + 1))
    fi
    if verify_git_config; then
        print_success "Git configuration and effective identities are valid."
    else
        print_error "Git configuration validation failed."
        issues=$((issues + 1))
    fi

    print_section "Network Verification"
    if [[ "${GITSETU_DRY_RUN:-0}" == "1" ]]; then
        print_info "SKIPPED: dry-run verification performs no network or known_hosts changes."
    elif [[ "${GITSETU_VERIFY_NETWORK:-0}" == "1" ]]; then
        if verify_ssh_connectivity; then
            print_success "SSH connectivity checks passed."
        else
            print_error "One or more SSH connectivity checks failed."
            issues=$((issues + 1))
        fi
    else
        print_info "SKIPPED: network checks are opt-in. Set GITSETU_VERIFY_NETWORK=1 to run them."
    fi

    printf >&2 '\n'
    if [[ "$issues" -eq 0 ]]; then
        print_success "All required offline checks passed!"
    else
        print_warning "$issues required validation group(s) failed. See above for details."
    fi

    [[ "$issues" -eq 0 ]]
}
