#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables used by sourcing script
# lib/teardown.sh — Safely remove all GitSetu configurations
#
# Removes only GitSetu-owned state, leaves SSH private keys intact, and bounds
# optional deep repository scans by depth, entry count, repository count, and
# wall-clock time. Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# _teardown_managed_markers_valid — Reject ambiguous managed blocks
# ------------------------------------------------------------------------------
_teardown_managed_markers_valid() {
    local source_file="$1"
    awk '
        /\[gitsetu:managed:start\]/ {
            if (inside) { exit 3 }
            inside=1
            next
        }
        /\[gitsetu:managed:end\]/ {
            if (!inside) { exit 4 }
            inside=0
            next
        }
        END {
            if (inside) { exit 5 }
        }
    ' "$source_file"
}

# ------------------------------------------------------------------------------
# _teardown_replace_file — Atomically install a staged configuration file
# ------------------------------------------------------------------------------
_teardown_replace_file() {
    local staged_file="$1"
    local destination="$2"

    [[ -f "$staged_file" && ! -L "$staged_file" ]] || return 1
    if mv "$staged_file" "$destination" 2>/dev/null; then
        chmod 600 "$destination" 2>/dev/null || true
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# teardown_gitconfig — Remove the managed block from ~/.gitconfig
# ------------------------------------------------------------------------------
teardown_gitconfig() {
    local gitconfig="$HOME/.gitconfig"

    if [[ ! -f "$gitconfig" || -L "$gitconfig" ]]; then
        print_info "No regular ~/.gitconfig found, skipping."
        return 0
    fi
    if ! grep -q "\[gitsetu:managed:start\]" "$gitconfig" 2>/dev/null; then
        print_info "No gitsetu managed block found in ~/.gitconfig, skipping."
        return 0
    fi
    if ! _teardown_managed_markers_valid "$gitconfig"; then
        print_error "Refusing to edit ~/.gitconfig: managed block markers are unbalanced."
        return 1
    fi
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would remove managed block from: $gitconfig"
        return 0
    fi

    ensure_dirs || return 1
    backup_file "$gitconfig" || {
        print_error "Could not back up ~/.gitconfig; teardown stopped."
        return 1
    }

    local tmp_file
    tmp_file=$(umask 077 && mktemp "${gitconfig}.tmp.XXXXXX" 2>/dev/null) || {
        print_error "Could not create a private staging file for ~/.gitconfig."
        return 1
    }
    GITSETU_CLEANUP_FILES+=("$tmp_file")

    if ! awk '
        /\[gitsetu:managed:start\]/ { skip=1; next }
        /\[gitsetu:managed:end\]/   { skip=0; next }
        !skip                      { print }
    ' "$gitconfig" > "$tmp_file"; then
        rm -f "$tmp_file"
        print_error "Failed to stage ~/.gitconfig cleanup; original was not changed."
        return 1
    fi

    if ! grep -q '[^[:space:]]' "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        if ! rm -f "$gitconfig"; then
            print_error "Failed to remove empty ~/.gitconfig."
            return 1
        fi
        print_success "Removed ~/.gitconfig (it was empty after cleanup)"
        return 0
    fi

    if ! _teardown_replace_file "$tmp_file" "$gitconfig"; then
        rm -f "$tmp_file"
        print_error "Failed to install cleaned ~/.gitconfig; original was preserved."
        return 1
    fi
    print_success "Removed managed block from: $gitconfig"
}

# ------------------------------------------------------------------------------
# teardown_sshconfig — Remove GitSetu's isolated Include and generated file
# ------------------------------------------------------------------------------
teardown_sshconfig() {
    local ssh_config="$HOME/.ssh/config"
    local isolated_config="$GITSETU_PROFILES_DIR/ssh_config"
    local include_path="$isolated_config"

    if [[ "$isolated_config" == "$HOME/"* ]]; then
        include_path="~/${isolated_config#"$HOME"/}"
    elif [[ "$isolated_config" =~ (\.config/.*)$ ]]; then
        include_path="~/${BASH_REMATCH[1]}"
    fi
    local include_directive="Include ${include_path}"

    if [[ -f "$ssh_config" && ! -L "$ssh_config" ]] && \
       grep -q -F -x "$include_directive" "$ssh_config" 2>/dev/null; then
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would remove Include directive from: $ssh_config"
        else
            ensure_dirs || return 1
            backup_file "$ssh_config" || {
                print_error "Could not back up ~/.ssh/config; teardown stopped."
                return 1
            }

            local tmp_file
            tmp_file=$(umask 077 && mktemp "${ssh_config}.tmp.XXXXXX" 2>/dev/null) || {
                print_error "Could not create a private staging file for ~/.ssh/config."
                return 1
            }
            GITSETU_CLEANUP_FILES+=("$tmp_file")

            local filter_rc=0
            grep -v -F -x "$include_directive" "$ssh_config" > "$tmp_file" || filter_rc=$?
            if [[ "$filter_rc" -gt 1 ]]; then
                rm -f "$tmp_file"
                print_error "Failed to stage ~/.ssh/config cleanup; original was preserved."
                return 1
            fi

            if ! grep -q '[^[:space:]]' "$tmp_file" 2>/dev/null; then
                rm -f "$tmp_file"
                if ! rm -f "$ssh_config"; then
                    print_error "Failed to remove empty ~/.ssh/config."
                    return 1
                fi
                print_success "Removed ~/.ssh/config (it was empty after cleanup)"
            elif ! _teardown_replace_file "$tmp_file" "$ssh_config"; then
                rm -f "$tmp_file"
                print_error "Failed to install cleaned ~/.ssh/config; original was preserved."
                return 1
            else
                print_success "Removed Include directive from: $ssh_config"
            fi
        fi
    elif [[ -f "$ssh_config" && ! -L "$ssh_config" ]]; then
        print_info "No gitsetu Include directive found in ~/.ssh/config, skipping."
    elif [[ -e "$ssh_config" || -L "$ssh_config" ]]; then
        print_warning "Refusing to edit non-regular ~/.ssh/config; leaving it unchanged."
        return 1
    else
        print_info "No ~/.ssh/config found, skipping."
    fi

    if [[ -e "$isolated_config" || -L "$isolated_config" ]]; then
        if [[ ! -f "$isolated_config" || -L "$isolated_config" ]]; then
            print_warning "Refusing to delete non-regular isolated SSH config: $isolated_config"
            return 1
        fi
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would delete isolated config: $isolated_config"
        elif ! rm -f "$isolated_config"; then
            print_error "Failed to delete isolated SSH config: $isolated_config"
            return 1
        else
            print_success "Deleted isolated gitsetu SSH config: $isolated_config"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# teardown_config_dir — Remove only the canonical gitsetu state directory
# ------------------------------------------------------------------------------
teardown_config_dir() {
    local config_dir="${GITSETU_CONFIG_DIR:-}"
    if [[ -z "$config_dir" ]]; then
        print_info "Config directory is unset, skipping."
        return 0
    fi
    if [[ -L "$config_dir" ]] ||
       { declare -F _gitsetu_is_reparse_point >/dev/null 2>&1 && _gitsetu_is_reparse_point "$config_dir"; }; then
        print_error "Refusing redirected config root: $config_dir"
        return 1
    fi
    if [[ ! -e "$config_dir" ]]; then
        print_info "Directory $config_dir not found, skipping."
        return 0
    fi
    [[ -d "$config_dir" && -O "$config_dir" ]] || {
        print_error "Refusing non-directory or unowned config root: $config_dir"
        return 1
    }

    local normalized="${config_dir%/}"
    local config_basename="${normalized##*/}"
    if [[ "$normalized" == "/" || "$normalized" == "$HOME" || \
          "$normalized" =~ ^[A-Za-z]:/$ || "$config_basename" != "gitsetu" ]]; then
        print_error "Refusing unsafe teardown target: ${config_dir}"
        return 1
    fi
    if declare -F canonicalize_path >/dev/null 2>&1; then
        local canonical
        canonical=$(canonicalize_path "$config_dir") || return 1
        [[ "$canonical" == "$config_dir" ]] || {
            print_error "Refusing non-canonical config root: $config_dir"
            return 1
        }
    fi
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would completely remove: $config_dir"
        return 0
    fi

    chmod 700 "$config_dir" 2>/dev/null || true
    if declare -F _gitsetu_remove_private_directory >/dev/null 2>&1; then
        if ! _gitsetu_remove_private_directory "$config_dir"; then
            print_error "Failed to safely remove configuration directory: $config_dir"
            return 1
        fi
    elif ! rm -rf "$config_dir"; then
        print_error "Failed to remove configuration directory: $config_dir"
        return 1
    fi
    print_success "Removed configuration directory: $GITSETU_CONFIG_DIR"
}

# ------------------------------------------------------------------------------
# list_orphaned_keys — Show SSH keys generated by gitsetu
# ------------------------------------------------------------------------------
list_orphaned_keys() {
    local keys=()
    local max_keys=1024
    if [[ -n "${GITSETU_TEARDOWN_MAX_KEYS:-}" && "${GITSETU_TEARDOWN_MAX_KEYS}" =~ ^[0-9]+$ && "${GITSETU_TEARDOWN_MAX_KEYS}" -gt 0 ]]; then
        max_keys="${GITSETU_TEARDOWN_MAX_KEYS}"
    fi

    if [[ -d "$HOME/.ssh" && ! -L "$HOME/.ssh" ]]; then
        local f
        for f in "$HOME/.ssh"/id_ed25519_*; do
            [[ -f "$f" && ! -L "$f" ]] || continue
            [[ "$f" == *.pub || "$f" == *.old.* || "$f" == "$HOME/.ssh/id_ed25519" ]] && continue
            keys+=("$f")
            [[ "${#keys[@]}" -ge "$max_keys" ]] && break
        done
    fi

    if [[ ${#keys[@]} -gt 0 ]]; then
        print_section "Action Required: SSH Keys"
        print_warning "GitSetu has left your SSH keys intact to prevent accidental lockouts."
        print_info "If you no longer need them, remove them from GitHub/GitLab and delete them locally:"
        local key
        for key in "${keys[@]}"; do
            printf >&2 "    rm %s %s.pub\n" "$key" "$key"
        done
        [[ "${#keys[@]}" -ge "$max_keys" ]] && print_warning "Key list truncated at $max_keys entries."
        printf >&2 "\n"
    fi
}

# ------------------------------------------------------------------------------
# Deep cleanup helpers
# ------------------------------------------------------------------------------
_TEARDOWN_REPO_COUNT=0
_TEARDOWN_ENTRY_COUNT=0
_TEARDOWN_MAX_REPOS=1000
_TEARDOWN_MAX_ENTRIES=20000
_TEARDOWN_MAX_DEPTH=12
_TEARDOWN_MAX_SECONDS=30
_TEARDOWN_DEADLINE=0
_TEARDOWN_TRUNCATED=0
_TEARDOWN_PROCESSED_REPOS=()
_TEARDOWN_EMAILS=()
_TEARDOWN_NAMES=()
_TEARDOWN_KEYS=()
_TEARDOWN_SSH_COMMANDS=()

_teardown_repo_already_processed() {
    local candidate="$1"
    local seen
    for seen in "${_TEARDOWN_PROCESSED_REPOS[@]+"${_TEARDOWN_PROCESSED_REPOS[@]}"}"; do
        [[ "$seen" == "$candidate" ]] && return 0
    done
    return 1
}

_teardown_unset_exact_git_value() {
    local repo_conf="$1" key="$2" expected="$3"
    local values value found=0
    values=$(git config -f "$repo_conf" --get-all "$key" 2>/dev/null || true)
    [[ -n "$values" ]] || return 0
    while IFS= read -r value; do
        [[ -n "$value" ]] || continue
        [[ "$value" == "$expected" ]] || return 1
        found=1
    done <<< "$values"
    [[ "$found" -eq 1 ]] || return 0
    git config -f "$repo_conf" --unset-all "$key" 2>/dev/null || return 1
}

_teardown_process_repo_config() {
    local repo_conf="$1"
    local actual_email actual_name actual_key matched=0 i
    [[ -f "$repo_conf" && ! -L "$repo_conf" ]] || return 0

    actual_email=$(git config -f "$repo_conf" --get user.email 2>/dev/null || true)
    actual_name=$(git config -f "$repo_conf" --get user.name 2>/dev/null || true)
    [[ -n "$actual_email" && -n "$actual_name" ]] || return 0
    for (( i=0; i<${#_TEARDOWN_EMAILS[@]}; i++ )); do
        if [[ "$actual_email" == "${_TEARDOWN_EMAILS[$i]}" && \
              "$actual_name" == "${_TEARDOWN_NAMES[$i]}" ]]; then
            matched=1
            break
        fi
    done
    [[ "$matched" -eq 1 ]] || return 0

    _TEARDOWN_PROCESSED_REPOS+=("$repo_conf")
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would strip exact GitSetu identity from: $repo_conf"
        return 0
    fi

    # Refuse partial removal when a key has multiple values and any value differs
    # from the exact generated value.
    _teardown_unset_exact_git_value "$repo_conf" user.email "$actual_email" || return 1
    _teardown_unset_exact_git_value "$repo_conf" user.name "$actual_name" || return 1
    actual_key=$(git config -f "$repo_conf" --get core.sshCommand 2>/dev/null || true)
    if [[ -n "$actual_key" && "$actual_key" == "${_TEARDOWN_SSH_COMMANDS[$i]}" ]]; then
        _teardown_unset_exact_git_value "$repo_conf" core.sshCommand "$actual_key" || return 1
    fi
    print_success "Removed exact local GitSetu overrides from: $repo_conf"
}

# Return 0 complete, 2 a configured bound was reached.
_teardown_scan_directory() {
    local current_dir="$1"
    local current_depth="$2"

    [[ -d "$current_dir" && ! -L "$current_dir" ]] || return 0
    if [[ "$SECONDS" -ge "$_TEARDOWN_DEADLINE" ]]; then
        _TEARDOWN_TRUNCATED=1
        return 2
    fi

    _TEARDOWN_ENTRY_COUNT=$((_TEARDOWN_ENTRY_COUNT + 1))
    if [[ "$_TEARDOWN_ENTRY_COUNT" -gt "$_TEARDOWN_MAX_ENTRIES" ]]; then
        _TEARDOWN_TRUNCATED=1
        return 2
    fi

    local child
    for child in "$current_dir"/* "$current_dir"/.[!.]* "$current_dir"/..?*; do
        [[ -e "$child" || -L "$child" ]] || continue
        [[ -L "$child" ]] && continue
        if [[ "$SECONDS" -ge "$_TEARDOWN_DEADLINE" ]]; then
            _TEARDOWN_TRUNCATED=1
            return 2
        fi

        if [[ -d "$child" ]]; then
            if [[ "${child##*/}" == ".git" ]]; then
                if [[ -f "$child/config" && ! -L "$child/config" ]]; then
                    if ! _teardown_process_repo_config "$child/config"; then
                        return 3
                    fi
                    _TEARDOWN_REPO_COUNT=$((_TEARDOWN_REPO_COUNT + 1))
                    if [[ "$_TEARDOWN_REPO_COUNT" -ge "$_TEARDOWN_MAX_REPOS" ]]; then
                        _TEARDOWN_TRUNCATED=1
                        return 2
                    fi
                fi
            elif [[ "$current_depth" -lt "$_TEARDOWN_MAX_DEPTH" ]]; then
                _teardown_scan_directory "$child" "$((current_depth + 1))"
                local scan_rc=$?
                [[ "$scan_rc" -eq 0 ]] || return "$scan_rc"
            fi
        else
            _TEARDOWN_ENTRY_COUNT=$((_TEARDOWN_ENTRY_COUNT + 1))
            if [[ "$_TEARDOWN_ENTRY_COUNT" -gt "$_TEARDOWN_MAX_ENTRIES" ]]; then
                _TEARDOWN_TRUNCATED=1
                return 2
            fi
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# teardown_deep — Remove local overrides from repositories
# ------------------------------------------------------------------------------
teardown_deep() {
    print_section "Deep Cleanup: Repository Overrides"
    load_profiles 2>/dev/null || {
        print_error "Could not load the v2 profile registry; deep cleanup stopped."
        return 1
    }
    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        print_info "No profiles found. Skipping deep cleanup."
        return 0
    fi

    _TEARDOWN_MAX_REPOS=1000
    _TEARDOWN_MAX_ENTRIES=20000
    _TEARDOWN_MAX_DEPTH=12
    _TEARDOWN_MAX_SECONDS=30
    if [[ -n "${GITSETU_TEARDOWN_MAX_REPOS:-}" && "${GITSETU_TEARDOWN_MAX_REPOS}" =~ ^[0-9]+$ && "${GITSETU_TEARDOWN_MAX_REPOS}" -gt 0 ]]; then
        _TEARDOWN_MAX_REPOS="${GITSETU_TEARDOWN_MAX_REPOS}"
    fi
    if [[ -n "${GITSETU_TEARDOWN_MAX_ENTRIES:-}" && "${GITSETU_TEARDOWN_MAX_ENTRIES}" =~ ^[0-9]+$ && "${GITSETU_TEARDOWN_MAX_ENTRIES}" -gt 0 ]]; then
        _TEARDOWN_MAX_ENTRIES="${GITSETU_TEARDOWN_MAX_ENTRIES}"
    fi
    if [[ -n "${GITSETU_TEARDOWN_MAX_DEPTH:-}" && "${GITSETU_TEARDOWN_MAX_DEPTH}" =~ ^[0-9]+$ && "${GITSETU_TEARDOWN_MAX_DEPTH}" -gt 0 ]]; then
        _TEARDOWN_MAX_DEPTH="${GITSETU_TEARDOWN_MAX_DEPTH}"
    fi
    if [[ -n "${GITSETU_TEARDOWN_TIMEOUT:-}" && "${GITSETU_TEARDOWN_TIMEOUT}" =~ ^[0-9]+$ && "${GITSETU_TEARDOWN_TIMEOUT}" -gt 0 && "${GITSETU_TEARDOWN_TIMEOUT}" -le 3600 ]]; then
        _TEARDOWN_MAX_SECONDS="${GITSETU_TEARDOWN_TIMEOUT}"
    elif [[ -n "${GITSETU_TEARDOWN_TIMEOUT:-}" ]]; then
        print_error "GITSETU_TEARDOWN_TIMEOUT must be an integer from 1 to 3600."
        return 1
    fi

    _TEARDOWN_REPO_COUNT=0
    _TEARDOWN_ENTRY_COUNT=0
    _TEARDOWN_TRUNCATED=0
    _TEARDOWN_PROCESSED_REPOS=()
    _TEARDOWN_EMAILS=()
    _TEARDOWN_NAMES=()
    _TEARDOWN_KEYS=()
    _TEARDOWN_SSH_COMMANDS=()
    local i profile_ssh
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        _TEARDOWN_EMAILS+=("${PROFILE_EMAILS[$i]}")
        _TEARDOWN_NAMES+=("${PROFILE_NAMES[$i]}")
        _TEARDOWN_KEYS+=("${PROFILE_KEYS[$i]}")
        profile_ssh=$(git config -f "$GITSETU_PROFILES_DIR/${PROFILE_LABELS[$i]}.gitconfig" \
            --get core.sshCommand 2>/dev/null || true)
        _TEARDOWN_SSH_COMMANDS+=("$profile_ssh")
    done
    _TEARDOWN_DEADLINE=$((SECONDS + _TEARDOWN_MAX_SECONDS))

    local bounded=0 mutation_failed=0
    local dir normalized
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        dir="${PROFILE_DIRS[$i]}"
        [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || continue
        case "$dir" in
            /|//|"$HOME"|"$HOME/"|"~"|"~/"|[a-zA-Z]:|/[a-zA-Z]:/*)
                print_warning "Skipping deep cleanup for '$dir' to prevent filesystem traversal."
                continue
                ;;
        esac
        normalized=$(normalize_path "$dir")
        case "$normalized" in
            /|"$HOME"|C:/|D:/)
                print_warning "Skipping deep cleanup for '$normalized' to prevent filesystem traversal."
                continue
                ;;
        esac
        _teardown_scan_directory "$dir" 0
        local scan_rc=$?
        if [[ "$scan_rc" -eq 3 ]]; then
            mutation_failed=1
            break
        elif [[ "$scan_rc" -ne 0 ]]; then
            bounded=1
            break
        fi
    done

    if [[ "$_TEARDOWN_REPO_COUNT" -eq 0 && "$bounded" -eq 0 ]]; then
        print_info "No local repository overrides found."
    fi
    if [[ "$mutation_failed" -ne 0 ]]; then
        print_error "Deep cleanup preserved a repository because an exact owned-value removal could not be completed."
        return 1
    fi
    if [[ "$bounded" -ne 0 ]]; then
        print_warning "Deep cleanup reached a safety bound (depth=$_TEARDOWN_MAX_DEPTH entries=$_TEARDOWN_ENTRY_COUNT repositories=$_TEARDOWN_REPO_COUNT seconds=$_TEARDOWN_MAX_SECONDS)."
        print_warning "Configuration was not removed because repository cleanup may be incomplete."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# teardown_all — Main coordinator for teardown
# ------------------------------------------------------------------------------
teardown_all() {
    local deep="${1:-0}"
    local acquired=0
    local failed=0

    print_section "Teardown Process"

    if [[ "${GITSETU_DRY_RUN:-0}" -ne 1 ]] && type acquire_lock >/dev/null 2>&1; then
        acquire_lock || return 1
        acquired=1
    fi

    uninstall_guard || failed=1
    teardown_gitconfig || failed=1
    teardown_sshconfig || failed=1

    if [[ "$deep" == "1" ]]; then
        teardown_deep || failed=1
    fi

    # State removal is last and only occurs after all external configuration was
    # cleaned successfully.  A partial failure leaves the registry available for
    # diagnosis or a retry.
    if [[ "$failed" -eq 0 ]]; then
        teardown_config_dir || failed=1
    else
        print_warning "State directory retained because one or more teardown stages failed."
    fi

    list_orphaned_keys || failed=1
    if [[ "$acquired" -eq 1 ]]; then
        release_lock || failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 0 ]]; then
            print_success "GitSetu teardown complete."
        fi
        return 0
    fi
    print_error "GitSetu teardown completed with errors."
    return 1
}
