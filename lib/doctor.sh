#!/usr/bin/env bash
# lib/doctor.sh — Required offline diagnostics and serialized repair
# Bash 3.2 compatible.

_doctor_safe_display() {
    if declare -f escape_terminal_text >/dev/null 2>&1; then
        escape_terminal_text "${1:-}"
    else
        printf '%s' "${1:-}"
    fi
}

_doctor_count_marker() {
    local file="${1:-}"
    local marker="${2:-}"
    local count
    [[ -f "$file" ]] || {
        printf '0'
        return 0
    }
    count=$(grep -F -c "$marker" "$file" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s' "$count"
}

_doctor_canonical_dir() {
    local raw="${1:-}"
    local normalized
    [[ -n "$raw" ]] || return 1
    normalized=$(normalize_path "$raw" 2>/dev/null || true)
    [[ -d "$normalized" ]] || {
        printf '%s' "$normalized"
        return 0
    }
    (cd -P -- "$normalized" 2>/dev/null && pwd -P) || printf '%s' "$normalized"
}

_doctor_profile_email() {
    local label="${1:-}"
    local config_file="$GITSETU_PROFILES_DIR/${label}.gitconfig"
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 1
    git config --file "$config_file" user.email 2>/dev/null || true
}

_doctor_ssh_include_present() {
    local ssh_config="$HOME/.ssh/config"
    [[ -f "$ssh_config" ]] || return 1
    grep -qF 'Include ~/.config/gitsetu/profiles/ssh_config' "$ssh_config" 2>/dev/null || \
        grep -qF "Include $GITSETU_PROFILES_DIR/ssh_config" "$ssh_config" 2>/dev/null || \
        grep -qF "Include \"$GITSETU_PROFILES_DIR/ssh_config\"" "$ssh_config" 2>/dev/null
}

# Parse the effective OpenSSH configuration without opening a network
# connection. A file that cannot be parsed is repair state, not a healthy
# configuration merely because it contains the managed Include line.
_doctor_ssh_config_valid() {
    local ssh_config="$HOME/.ssh/config"
    local mode
    [[ -d "$HOME/.ssh" && ! -L "$HOME/.ssh" && -O "$HOME/.ssh" ]] || return 1
    [[ -f "$ssh_config" && ! -L "$ssh_config" && -O "$ssh_config" ]] || return 1
    if declare -f _ssh_assert_private_directory >/dev/null 2>&1; then
        _ssh_assert_private_directory "$HOME/.ssh" || return 1
    fi
    mode=$(stat -c '%a' "$ssh_config" 2>/dev/null || stat -f '%Lp' "$ssh_config" 2>/dev/null || true)
    [[ "$mode" == "600" ]] || {
        case "${GITSETU_OS:-}:${OSTYPE:-}" in
            gitbash:*|cygwin:*|msys:*|mingw:*) [[ "$mode" == "644" ]] || return 1 ;;
            *) return 1 ;;
        esac
    }
    local isolated="$GITSETU_PROFILES_DIR/ssh_config"
    if [[ -e "$isolated" || -L "$isolated" ]]; then
        [[ -f "$isolated" && ! -L "$isolated" && -O "$isolated" ]] || return 1
        mode=$(stat -c '%a' "$isolated" 2>/dev/null || stat -f '%Lp' "$isolated" 2>/dev/null || true)
        [[ "$mode" == "600" ]] || {
            case "${GITSETU_OS:-}:${OSTYPE:-}" in
                gitbash:*|cygwin:*|msys:*|mingw:*) [[ "$mode" == "644" ]] || return 1 ;;
                *) return 1 ;;
            esac
        }
    fi
    command -v ssh >/dev/null 2>&1 || return 1
    ssh -G -F "$ssh_config" -o BatchMode=yes github.com >/dev/null 2>&1
}

_doctor_active_profile() {
    local current_raw="${1:-}"
    local current lower_current
    local i dir candidate lower_candidate
    local matched_label="global" matched_dir="[Global Fallback]" longest=0
    local case_insensitive=0

    current=$(_doctor_canonical_dir "$current_raw")
    case "${GITSETU_OS:-${OSTYPE:-}}" in
        gitbash|macos|msys*|mingw*|cygwin*|darwin*) case_insensitive=1 ;;
    esac
    lower_current=$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')

    for (( i=1; i<PROFILE_COUNT; i++ )); do
        dir="${PROFILE_DIRS[$i]:-}"
        [[ -n "$dir" ]] || continue
        candidate=$(_doctor_canonical_dir "$dir")
        lower_candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
        if [[ "$candidate" == "$dir" && ( "$current/" == "$candidate/"* || "$current" == "$candidate" ) ]] || \
           [[ "$case_insensitive" -eq 1 && ( "$lower_current/" == "$lower_candidate/"* || "$lower_current" == "$lower_candidate" ) ]]; then
            if [[ "${#candidate}" -gt "$longest" ]]; then
                longest=${#candidate}
                matched_label="${PROFILE_LABELS[$i]:-}"
                matched_dir="$candidate"
            fi
        fi
    done

    ACTIVE_DOCTOR_PROFILE="$matched_label"
    ACTIVE_DOCTOR_DIR="$matched_dir"
}

# ------------------------------------------------------------------------------
# run_doctor — required offline checks determine the exit status
# ------------------------------------------------------------------------------

run_doctor() {
    if [[ -z "${GITSETU_OS:-}" ]] && declare -f detect_os >/dev/null 2>&1; then
        local detect_status=0
        detect_os || detect_status=$?
        if [[ "$detect_status" -ne 0 ]]; then
            print_error "Unable to detect the host platform; diagnostics cannot continue."
            return "$detect_status"
        fi
    fi
    print_section "GitSetu Diagnostics (Doctor)"

    local issues_found=0
    local current_dir current_display active_profile expected_email actual_email
    local loaded_keys="" loaded_count=0 key_path fp
    local i label

    current_dir=$(pwd -P 2>/dev/null || printf '%s' "$PWD")
    _doctor_active_profile "$current_dir"
    active_profile="$ACTIVE_DOCTOR_PROFILE"
    current_display=$(_doctor_safe_display "$current_dir")

    printf >&2 "  %bDirectory Context:%b\n" "$BOLD" "$RESET"
    printf >&2 "    Current PWD: %s\n" "$current_display"
    printf >&2 "    Active Profile: %b%s%b\n" "$GREEN" "$(_doctor_safe_display "$active_profile")" "$RESET"
    if [[ "$active_profile" == "global" ]]; then
        printf >&2 "    Matched Rule: No mapped profile directory; using global fallback.\n"
    else
        printf >&2 "    Matched Rule: %s\n" "$(_doctor_safe_display "$ACTIVE_DOCTOR_DIR")"
    fi
    printf >&2 '\n'

    printf >&2 "  %bGuard Policy:%b\n" "$BOLD" "$RESET"
    printf >&2 "    Unmanaged repositories: fail-open (GitSetu does not enforce an identity).\n"
    printf >&2 "    Managed repositories: fail-closed when the expected identity is unresolved or differs.\n"
    printf >&2 "    Opt out explicitly with: gitsetu guard --uninstall\n\n"

    printf >&2 "  %bGit Identity Resolution:%b\n" "$BOLD" "$RESET"
    if command -v git >/dev/null 2>&1; then
        actual_email=$(git config user.email 2>/dev/null || true)
        [[ -n "$actual_email" ]] || actual_email="(Not Configured)"
        printf >&2 "    Configured Email: %s\n" "$(_doctor_safe_display "$actual_email")"

        if [[ "$active_profile" != "global" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            expected_email=$(_doctor_profile_email "$active_profile" 2>/dev/null || true)
            if [[ -z "$expected_email" ]]; then
                printf >&2 "    %bERROR: Managed profile '%s' has no resolvable expected email.%b\n" \
                    "$RED" "$(_doctor_safe_display "$active_profile")" "$RESET"
                issues_found=1
            elif [[ "$actual_email" != "$expected_email" ]]; then
                printf >&2 "    %bERROR: Effective repository email differs from the managed profile.%b\n" "$RED" "$RESET"
                issues_found=1
            else
                print_success "Managed repository resolves to the expected profile."
            fi
        fi
    else
        printf >&2 "    %bERROR: Git is not installed or not in PATH.%b\n" "$RED" "$RESET"
        issues_found=1
    fi
    printf >&2 '\n'

    printf >&2 "  %bSSH Agent (informational):%b\n" "$BOLD" "$RESET"
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        printf >&2 "    %bWARNING: SSH_AUTH_SOCK is not set; commits can still use configured keys.%b\n" "$YELLOW" "$RESET"
    elif ! command -v ssh-add >/dev/null 2>&1; then
        printf >&2 "    %bWARNING: ssh-add is unavailable.%b\n" "$YELLOW" "$RESET"
    else
        loaded_keys=$(ssh-add -l 2>/dev/null || true)
        if [[ -z "$loaded_keys" ]]; then
            loaded_count=0
            printf >&2 "    %bWARNING: The agent reports no loaded identities.%b\n" "$YELLOW" "$RESET"
        else
            while IFS= read -r line; do
                [[ -n "$line" ]] && loaded_count=$((loaded_count + 1))
            done <<< "$loaded_keys"
            printf >&2 "    Loaded identities: %s\n" "$loaded_count"
        fi
    fi
    printf >&2 '\n'

    printf >&2 "  %bRequired Configuration Integrity:%b\n" "$BOLD" "$RESET"
    if [[ -z "${HOME:-}" ]]; then
        printf >&2 "    %bERROR: HOME is not set.%b\n" "$RED" "$RESET"
        issues_found=1
    else
        if [[ -L "$GITSETU_PROFILES_CONF" || ! -f "$GITSETU_PROFILES_CONF" ]]; then
            printf >&2 "    %bERROR: Registry missing or unsafe at %s%b\n" \
                "$RED" "$(_doctor_safe_display "$GITSETU_PROFILES_CONF")" "$RESET"
            issues_found=1
        elif [[ "$(head -n 1 "$GITSETU_PROFILES_CONF" 2>/dev/null || true)" != "# gitsetu-registry-v2" ]]; then
            printf >&2 "    %bERROR: Registry header is missing or unsupported.%b\n" "$RED" "$RESET"
            issues_found=1
        elif [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
            printf >&2 "    %bERROR: Registry contains no complete profiles.%b\n" "$RED" "$RESET"
            issues_found=1
        else
            printf >&2 "    Registry: OK (%s profile(s))\n" "$PROFILE_COUNT"
        fi

        if [[ -L "$HOME/.gitconfig" || ! -f "$HOME/.gitconfig" ]]; then
            printf >&2 "    ~/.gitconfig: %bERROR (missing or unsafe)%b\n" "$RED" "$RESET"
            issues_found=1
        else
            local start_count end_count
            start_count=$(_doctor_count_marker "$HOME/.gitconfig" "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}")
            end_count=$(_doctor_count_marker "$HOME/.gitconfig" "${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}")
            if [[ "$start_count" == "1" && "$end_count" == "1" ]]; then
                printf >&2 "    ~/.gitconfig: OK (one complete managed block)\n"
            else
                printf >&2 "    ~/.gitconfig: %bERROR (managed markers missing or duplicated)%b\n" "$RED" "$RESET"
                issues_found=1
            fi
        fi

        if [[ -L "$HOME/.ssh" || -L "$HOME/.ssh/config" || ! -f "$HOME/.ssh/config" ]] || \
           ! _doctor_ssh_include_present || ! _doctor_ssh_config_valid; then
            printf >&2 "    ~/.ssh/config: %bERROR (GitSetu include missing or unsafe)%b\n" "$RED" "$RESET"
            issues_found=1
        elif [[ -L "$GITSETU_PROFILES_DIR" || -L "$GITSETU_PROFILES_DIR/ssh_config" || ! -f "$GITSETU_PROFILES_DIR/ssh_config" ]]; then
            printf >&2 "    ~/.ssh/config: %bERROR (included GitSetu config missing)%b\n" "$RED" "$RESET"
            issues_found=1
        else
            printf >&2 "    ~/.ssh/config: OK (GitSetu include present)\n"
        fi

        for (( i=0; i<PROFILE_COUNT; i++ )); do
            label="${PROFILE_LABELS[$i]:-}"
            expected_email=$(_doctor_profile_email "$label" 2>/dev/null || true)
            if [[ -z "$expected_email" ]]; then
                printf >&2 "    %bERROR: Profile '%s' has no resolvable expected email.%b\n" \
                    "$RED" "$(_doctor_safe_display "$label")" "$RESET"
                issues_found=1
            fi
        done
    fi
    printf >&2 '\n'

    printf >&2 "  %bGit Configuration Validation:%b\n" "$BOLD" "$RESET"
    if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        if declare -f verify_git_config >/dev/null 2>&1; then
            if verify_git_config; then
                printf >&2 "    Profile configs and effective identities: OK\n"
            else
                printf >&2 "    %bERROR: Profile config or effective identity validation failed.%b\n" "$RED" "$RESET"
                issues_found=1
            fi
        else
            printf >&2 "    %bERROR: Required Git configuration validator is unavailable.%b\n" "$RED" "$RESET"
            issues_found=1
        fi
    else
        printf >&2 "    %bSKIP: No profiles; Git identity cannot be verified.%b\n" "$YELLOW" "$RESET"
    fi
    printf >&2 '\n'

    printf >&2 "  %bSSH Key Validation:%b\n" "$BOLD" "$RESET"
    if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        if declare -f verify_ssh_keys >/dev/null 2>&1; then
            if verify_ssh_keys; then
                printf >&2 "    SSH keys: OK\n"
            else
                printf >&2 "    %bERROR: One or more SSH keys are missing, unsafe, or invalid.%b\n" "$RED" "$RESET"
                issues_found=1
            fi
        else
            printf >&2 "    %bERROR: Required SSH key validator is unavailable.%b\n" "$RED" "$RESET"
            issues_found=1
        fi
    else
        printf >&2 "    %bSKIP: No profiles; SSH keys cannot be verified.%b\n" "$YELLOW" "$RESET"
    fi
    printf >&2 '\n'

    if [[ "$issues_found" -ne 0 ]]; then
        print_info "Required checks failed. Repair with: gitsetu doctor --repair"
        printf >&2 '\n'
        return 1
    fi

    print_success "All required offline diagnostics passed."
    return 0
}

# ------------------------------------------------------------------------------
# Doctor repair rollback helpers
# ------------------------------------------------------------------------------
_doctor_snapshot_file() {
    local target="${1:-}"
    local backup mode parent
    [[ -n "$target" ]] || return 1
    parent="${target%/*}"
    [[ "$parent" =~ ^[A-Za-z]:$ ]] && parent="${parent}/"
    if [[ -e "$parent" || -L "$parent" ]]; then
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
    fi
    if [[ -L "$target" ]]; then
        return 1
    fi
    if [[ -e "$target" ]]; then
        [[ -f "$target" && ! -L "$target" && -O "$target" ]] || return 1
        mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)
        backup=$(umask 077; mktemp "${target}.rollback.XXXXXX" 2>/dev/null) || return 1
        cp -p "$target" "$backup" 2>/dev/null || {
            rm -f "$backup" 2>/dev/null || true
            return 1
        }
        chmod 600 "$backup" 2>/dev/null || {
            rm -f "$backup" 2>/dev/null || true
            return 1
        }
        GITSETU_CLEANUP_FILES+=("$backup")
        doctor_rollback_paths+=("$backup")
        doctor_rollback_targets+=("$target")
        doctor_rollback_exists+=(1)
        doctor_rollback_modes+=("$mode")
    else
        doctor_rollback_paths+=("")
        doctor_rollback_targets+=("$target")
        doctor_rollback_exists+=(0)
        doctor_rollback_modes+=("")
    fi
    return 0
}

_doctor_rollback_files() {
    local i
    for (( i=${#doctor_rollback_targets[@]}-1; i>=0; i-- )); do
        if [[ "${doctor_rollback_exists[$i]}" == "1" ]]; then
            mv -f "${doctor_rollback_paths[$i]}" "${doctor_rollback_targets[$i]}" 2>/dev/null || return 1
            if [[ -n "${doctor_rollback_modes[$i]:-}" ]]; then
                chmod "${doctor_rollback_modes[$i]}" "${doctor_rollback_targets[$i]}" 2>/dev/null || return 1
            fi
        else
            rm -f "${doctor_rollback_targets[$i]}" 2>/dev/null || return 1
        fi
    done
    return 0
}

_doctor_discard_rollbacks() {
    local path
    for path in ${doctor_rollback_paths[@]+"${doctor_rollback_paths[@]}"}; do
        [[ -n "$path" ]] && rm -f "$path" 2>/dev/null || true
    done
    doctor_rollback_paths=()
    doctor_rollback_targets=()
    doctor_rollback_exists=()
    doctor_rollback_modes=()
}

# ------------------------------------------------------------------------------
# run_doctor_repair
# ------------------------------------------------------------------------------

run_doctor_repair() {
    print_section "GitSetu Repair (Doctor)"

    if [[ -z "${HOME:-}" || -L "$GITSETU_PROFILES_CONF" || ! -f "$GITSETU_PROFILES_CONF" ]]; then
        print_error "GitSetu has not been configured yet (profiles.conf not found at $GITSETU_PROFILES_CONF). Run 'gitsetu setup' first."
        return 1
    fi
    if [[ "$(head -n 1 "$GITSETU_PROFILES_CONF" 2>/dev/null || true)" != "# gitsetu-registry-v2" ]]; then
        print_error "The profile registry header is missing or unsupported; refusing repair."
        return 1
    fi

    if declare -f load_profiles >/dev/null 2>&1; then
        local registry_status=0
        load_profiles || registry_status=$?
        if [[ "$registry_status" -ne 0 ]]; then
            return "$registry_status"
        fi
    fi
    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        print_error "The registry contains no complete profiles; repair cannot infer an identity."
        return 1
    fi
    if [[ -z "${GITSETU_OS:-}" ]] && declare -f detect_os >/dev/null 2>&1; then
        local detect_status=0
        detect_os || detect_status=$?
        if [[ "$detect_status" -ne 0 ]]; then
            print_error "Unable to detect the host platform; repair was not started."
            return "$detect_status"
        fi
    fi

    local i label expected
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        expected=$(_doctor_profile_email "$label" 2>/dev/null || true)
        if [[ -z "$expected" ]]; then
            print_error "Cannot repair managed profile '$label': expected identity is unresolved. Run setup/profile edit first."
            return 1
        fi
    done

    local gitconfig_needs_repair=0
    local ssh_needs_repair=0
    local ssh_agent_needs_repair=0
    local planned=0 failed=0
    local start_count end_count

    if [[ -L "$HOME/.gitconfig" || ! -f "$HOME/.gitconfig" ]]; then
        gitconfig_needs_repair=1
    else
        start_count=$(_doctor_count_marker "$HOME/.gitconfig" "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}")
        end_count=$(_doctor_count_marker "$HOME/.gitconfig" "${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}")
        [[ "$start_count" == "1" && "$end_count" == "1" ]] || gitconfig_needs_repair=1
    fi

    if [[ -L "$HOME/.ssh" || -L "$HOME/.ssh/config" || ! -f "$HOME/.ssh/config" ]] || \
       ! _doctor_ssh_include_present || ! _doctor_ssh_config_valid || \
       [[ -L "$GITSETU_PROFILES_DIR" || -L "$GITSETU_PROFILES_DIR/ssh_config" || ! -f "$GITSETU_PROFILES_DIR/ssh_config" ]]; then
        ssh_needs_repair=1
    fi

    if [[ -n "${SSH_AUTH_SOCK:-}" ]] && command -v ssh-add >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
        local agent_status=0
        local agent_keys=""
        ssh-add -l >/dev/null 2>&1 || agent_status=$?
        if [[ "$agent_status" -eq 0 ]]; then
            agent_keys=$(ssh-add -l 2>/dev/null || true)
        fi
        if [[ "$agent_status" -ne 2 ]]; then
            local kp fp
            for (( i=0; i<PROFILE_COUNT; i++ )); do
                kp="${PROFILE_KEYS[$i]-}"
                [[ -n "$kp" && -f "$kp" && ! -L "$kp" ]] || continue
                fp=$(_verify_key_fingerprint "$kp" 2>/dev/null || true)
                if [[ -n "$fp" ]] && { [[ -z "$agent_keys" ]] || ! printf '%s\n' "$agent_keys" | grep -qF "$fp"; }; then
                    ssh_agent_needs_repair=1
                    break
                fi
            done
        fi
    fi

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        [[ "$gitconfig_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would restore managed blocks in ~/.gitconfig."
        [[ "$ssh_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would restore SSH configuration and Include directive."
        [[ "$ssh_agent_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would register missing profile keys with ssh-agent."
        planned=$((gitconfig_needs_repair + ssh_needs_repair + ssh_agent_needs_repair))
        if [[ "$planned" -eq 0 ]]; then
            print_info "Nothing to repair. All required configuration is intact."
        else
            print_info "[DRY RUN] Dry run complete. $planned issue(s) would be repaired; no lock or file was changed."
        fi
        return 0
    fi

    if [[ "$gitconfig_needs_repair" -eq 0 && "$ssh_needs_repair" -eq 0 && "$ssh_agent_needs_repair" -eq 0 ]]; then
        print_info "Nothing to repair. All required configuration and managed blocks are intact."
        return 0
    fi

    if ! declare -f acquire_lock >/dev/null 2>&1 || ! acquire_lock; then
        print_error "Could not acquire the GitSetu mutation lock; repair was not started."
        return 1
    fi
    local lock_held=1
    local doctor_rollback_paths=()
    local doctor_rollback_targets=()
    local doctor_rollback_exists=()
    local doctor_rollback_modes=()

    if [[ "$gitconfig_needs_repair" -eq 1 ]] && ! _doctor_snapshot_file "$HOME/.gitconfig"; then
        print_error "Unable to create a rollback snapshot for ~/.gitconfig; repair was not started."
        release_lock || true
        return 1
    fi
    if [[ "$ssh_needs_repair" -eq 1 ]]; then
        if ! _doctor_snapshot_file "$HOME/.ssh/config" || ! _doctor_snapshot_file "$GITSETU_PROFILES_DIR/ssh_config"; then
            print_error "Unable to create SSH rollback snapshots; repair was not started."
            _doctor_discard_rollbacks
            release_lock || true
            return 1
        fi
    fi

    if [[ "$gitconfig_needs_repair" -eq 1 ]]; then
        print_step "Repairing ~/.gitconfig managed blocks..."
        if write_global_gitconfig; then
            print_success "Restored managed blocks in ~/.gitconfig"
        else
            print_error "Failed to restore managed blocks in ~/.gitconfig"
            failed=1
        fi
    fi

    if [[ "$failed" -eq 0 && "$ssh_needs_repair" -eq 1 ]]; then
        print_step "Repairing SSH configuration and Include directive..."
        if write_ssh_config; then
            print_success "Restored SSH configuration in ~/.ssh/config"
        else
            print_error "Failed to restore SSH configuration"
            failed=1
        fi
    fi

    if [[ "$failed" -eq 0 && "$ssh_agent_needs_repair" -eq 1 ]]; then
        print_step "Registering profile SSH keys with ssh-agent..."
        if auto_register_ssh_keys; then
            :
        else
            print_error "Failed to register one or more profile SSH keys"
            failed=1
        fi
    fi

    if [[ "$failed" -ne 0 ]]; then
        if ! _doctor_rollback_files; then
            print_error "Rollback could not fully restore the pre-repair configuration."
        else
            print_warning "Repair changes were rolled back after a failed validation/write."
        fi
    else
        _doctor_discard_rollbacks
    fi

    if [[ "$lock_held" -eq 1 ]]; then
        release_lock || failed=1
        lock_held=0
    fi

    if [[ "$failed" -ne 0 ]]; then
        print_error "Repair completed with errors; no success is being reported."
        return 1
    fi

    print_success "Repair complete. Required configuration was regenerated successfully."
    return 0
}
