#!/usr/bin/env bash
# lib/setup.sh — Interactive Blueprint Dashboard for GitSetu
#
# Replaces the linear wizard with a fast "Review & Apply" TUI menu.

# ------------------------------------------------------------------------------
# render_blueprint_dashboard
# ------------------------------------------------------------------------------
render_blueprint_dashboard() {
    clear || printf '\033c'
    
    printf >&2 '\n  %b╔══════════════════════════════════════╗%b\n' "$BOLD" "$RESET"
    printf >&2 '  %b║  GitSetu Setup Blueprint              ║%b\n' "$BOLD" "$RESET"
    printf >&2 '  %b╚══════════════════════════════════════╝%b\n\n' "$BOLD" "$RESET"

    if [[ "$PROFILE_COUNT" -eq 0 ]]; then
        printf >&2 '  No profiles configured.\n\n'
    fi

    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local label="${PROFILE_LABELS[i]}"
        local name="${PROFILE_NAMES[i]}"
        local email="${PROFILE_EMAILS[i]}"
        local dir="${PROFILE_DIRS[i]}"
        local key="${PROFILE_KEYS[i]}"
        
        local key_status="(Will Generate)"
        if [[ -f "$key" ]]; then
            key_status="${GREEN}(Found Existing!)${RESET}"
        elif [[ "$key" == *"_sk_"* ]]; then
            key_status="(Will Generate FIDO2)"
        fi
        
        local display_name="${name:-(Not Configured)}"
        local display_email="${email:-(Not Configured)}"
        local display_dir="${dir:-[Global Fallback]}"
        
        local incomplete_tag=""
        if [[ -z "$name" ]] || [[ -z "$email" ]]; then
            incomplete_tag=" ${YELLOW}[${SYM_WARN} Incomplete]${RESET}"
        fi

        printf >&2 '  %b%s) [%s]%b%b %s <%s>\n' "$BOLD" "$((i+1))" "$label" "$RESET" "$incomplete_tag" "$display_name" "$display_email"
        printf >&2 '     Key: %s %b\n' "$key" "$key_status"
        printf >&2 '     Dir: %s\n\n' "$display_dir"
    done

    printf >&2 '  ──────────────────────────────────────────────────────────\n'
    printf >&2 '  [A]dd Profile | [E]dit Profile | [R]emove | [S]ecurity \n'
    printf >&2 '  [H]elp        | [Q]uit         | [ENTER] Apply\n\n'
}

# ------------------------------------------------------------------------------
# preset_guided_onboarding — 3-Path guided on-ramp for first-time interactive setup
# ------------------------------------------------------------------------------
preset_guided_onboarding() {
    if ! command -v git >/dev/null 2>&1; then
        print_error "Git is not installed or not in PATH."
        return 1
    fi

    while true; do
        clear || printf '\033c'
        printf >&2 '\n  %b╔══════════════════════════════════════╗%b\n' "$BOLD" "$RESET"
        printf >&2 '  %b║  Welcome to GitSetu!                 ║%b\n' "$BOLD" "$RESET"
        printf >&2 '  %b╚══════════════════════════════════════╝%b\n\n' "$BOLD" "$RESET"

        printf >&2 '  How would you like to set up?\n\n'
        printf >&2 '  %b1) Single Identity%b  — one account for everything\n' "$BOLD" "$RESET"
        printf >&2 '  %b2) Dual Identity%b    — separate work & personal\n' "$BOLD" "$RESET"
        printf >&2 '  %b3) Custom Setup%b     — full manual control\n\n' "$BOLD" "$RESET"

        local choice=""
        if ! read -r -p "  Select [1-3] (default: 1): " choice; then
            print_info "Setup cancelled."
            return 0
        fi
        choice="${choice:-1}"

        case "$choice" in
            1)
                discover_global_git_identity
                local def_name="${DISCOVERED_GLOBAL_NAME:-}"
                if [[ -z "$def_name" ]]; then
                    def_name="${USER:-$(whoami 2>/dev/null || echo "GitSetu User")}"
                fi
                local def_email="${DISCOVERED_GLOBAL_EMAIL:-}"

                printf >&2 '\n  %b─── Single Account Setup ───%b\n\n' "$BOLD" "$RESET"

                local name=""
                if [[ -n "$def_name" ]]; then
                    read -r -p "  Name [$def_name]: " name || true
                    name="${name:-$def_name}"
                else
                    read -r -p "  Name: " name || true
                    name="${name:-GitSetu User}"
                fi

                local email=""
                if [[ -n "$def_email" ]]; then
                    read -r -p "  Email [$def_email]: " email || true
                    email="${email:-$def_email}"
                fi

                while [[ -z "$email" ]] || ! validate_email "$email"; do
                    if [[ -n "$email" ]] && ! validate_email "$email"; then
                        print_error "Invalid email address: '$email'."
                    fi
                    read -r -p "  Email: " email || true
                done

                local global_key
                global_key=$(discover_ssh_key_for_label "global")

                # shellcheck disable=SC2034
                PROFILE_COUNT=1
                # shellcheck disable=SC2034
                PROFILE_LABELS[0]="global"
                # shellcheck disable=SC2034
                PROFILE_NAMES[0]="$name"
                # shellcheck disable=SC2034
                PROFILE_EMAILS[0]="$email"
                # shellcheck disable=SC2034
                PROFILE_DIRS[0]=""
                # shellcheck disable=SC2034
                PROFILE_PROVIDERS[0]="github.com"
                # shellcheck disable=SC2034
                PROFILE_SIGNS[0]="0"
                # shellcheck disable=SC2034
                PROFILE_KEYS[0]="${global_key:-$HOME/.ssh/id_ed25519_global}"
                # shellcheck disable=SC2034
                PROFILE_USERS[0]=""
                # shellcheck disable=SC2034
                PROFILE_PATS[0]=""

                execute_blueprint
                return 0
                ;;
            2)
                discover_global_git_identity
                local def_name="${DISCOVERED_GLOBAL_NAME:-}"
                if [[ -z "$def_name" ]]; then
                    def_name="${USER:-$(whoami 2>/dev/null || echo "GitSetu User")}"
                fi
                local def_personal_email="${DISCOVERED_GLOBAL_EMAIL:-}"

                local def_work_dir
                def_work_dir=$(discover_workspace_dir "work")
                def_work_dir="${def_work_dir:-$HOME/work}"

                printf >&2 '\n  %b─── Setting Up Dual Identity ───%b\n\n' "$BOLD" "$RESET"

                local name=""
                if [[ -n "$def_name" ]]; then
                    read -r -p "  Name [$def_name]: " name || true
                    name="${name:-$def_name}"
                else
                    read -r -p "  Name: " name || true
                    name="${name:-GitSetu User}"
                fi

                local personal_email=""
                if [[ -n "$def_personal_email" ]]; then
                    read -r -p "  Personal Email [$def_personal_email]: " personal_email || true
                    personal_email="${personal_email:-$def_personal_email}"
                fi

                while [[ -z "$personal_email" ]] || ! validate_email "$personal_email"; do
                    if [[ -n "$personal_email" ]] && ! validate_email "$personal_email"; then
                        print_error "Invalid email address: '$personal_email'."
                    fi
                    read -r -p "  Personal Email: " personal_email || true
                done

                local work_email=""
                read -r -p "  Work Email: " work_email || true
                while [[ -z "$work_email" ]] || ! validate_email "$work_email"; do
                    if [[ -n "$work_email" ]] && ! validate_email "$work_email"; then
                        print_error "Invalid email address: '$work_email'."
                    fi
                    read -r -p "  Work Email: " work_email || true
                done

                local disp_work_dir="$def_work_dir"
                if [[ "$disp_work_dir" == "$HOME/"* ]]; then
                    disp_work_dir="~/${disp_work_dir#"$HOME"/}"
                elif [[ "$disp_work_dir" == "$HOME" ]]; then
                    disp_work_dir="~"
                fi

                local work_dir=""
                read -r -p "  Work directory [$disp_work_dir]: " work_dir || true
                work_dir="${work_dir:-$def_work_dir}"
                work_dir=$(normalize_path "$work_dir")

                local def_personal_dir
                def_personal_dir=$(discover_workspace_dir "personal")
                local personal_dir="${def_personal_dir:-$HOME/personal}"
                personal_dir=$(normalize_path "$personal_dir")

                local global_key
                global_key=$(discover_ssh_key_for_label "global")
                local work_key
                work_key=$(discover_ssh_key_for_label "work")
                local personal_key
                personal_key=$(discover_ssh_key_for_label "personal")

                # shellcheck disable=SC2034
                PROFILE_COUNT=3

                # Profile 0: global fallback (personal identity)
                # shellcheck disable=SC2034
                PROFILE_LABELS[0]="global"
                # shellcheck disable=SC2034
                PROFILE_NAMES[0]="$name"
                # shellcheck disable=SC2034
                PROFILE_EMAILS[0]="$personal_email"
                # shellcheck disable=SC2034
                PROFILE_DIRS[0]=""
                # shellcheck disable=SC2034
                PROFILE_PROVIDERS[0]="github.com"
                # shellcheck disable=SC2034
                PROFILE_SIGNS[0]="0"
                # shellcheck disable=SC2034
                PROFILE_KEYS[0]="${global_key:-$HOME/.ssh/id_ed25519_global}"
                # shellcheck disable=SC2034
                PROFILE_USERS[0]=""
                # shellcheck disable=SC2034
                PROFILE_PATS[0]=""

                # Profile 1: work
                # shellcheck disable=SC2034
                PROFILE_LABELS[1]="work"
                # shellcheck disable=SC2034
                PROFILE_NAMES[1]="$name"
                # shellcheck disable=SC2034
                PROFILE_EMAILS[1]="$work_email"
                # shellcheck disable=SC2034
                PROFILE_DIRS[1]="$work_dir"
                # shellcheck disable=SC2034
                PROFILE_PROVIDERS[1]="github.com"
                # shellcheck disable=SC2034
                PROFILE_SIGNS[1]="0"
                # shellcheck disable=SC2034
                PROFILE_KEYS[1]="${work_key:-$HOME/.ssh/id_ed25519_work}"
                # shellcheck disable=SC2034
                PROFILE_USERS[1]=""
                # shellcheck disable=SC2034
                PROFILE_PATS[1]=""

                # Profile 2: personal
                # shellcheck disable=SC2034
                PROFILE_LABELS[2]="personal"
                # shellcheck disable=SC2034
                PROFILE_NAMES[2]="$name"
                # shellcheck disable=SC2034
                PROFILE_EMAILS[2]="$personal_email"
                # shellcheck disable=SC2034
                PROFILE_DIRS[2]="$personal_dir"
                # shellcheck disable=SC2034
                PROFILE_PROVIDERS[2]="github.com"
                # shellcheck disable=SC2034
                PROFILE_SIGNS[2]="0"
                # shellcheck disable=SC2034
                PROFILE_KEYS[2]="${personal_key:-$HOME/.ssh/id_ed25519_personal}"
                # shellcheck disable=SC2034
                PROFILE_USERS[2]=""
                # shellcheck disable=SC2034
                PROFILE_PATS[2]=""

                execute_blueprint
                return 0
                ;;
            3)
                if [[ "${GITSETU_IN_WIZARD:-0}" -eq 1 ]]; then
                    return 0
                else
                    GITSETU_SKIP_ON_RAMP=1 interactive_setup_wizard
                    return $?
                fi
                ;;
            "q"|"Q"|"quit"|"exit")
                print_info "Setup cancelled."
                exit 0
                ;;
            *)
                print_error "Invalid selection: '$choice'. Please choose 1, 2, or 3."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# prompt_edit_profile
# ------------------------------------------------------------------------------
prompt_edit_profile() {
    local i="$1"
    local label="${PROFILE_LABELS[i]}"
    
    printf >&2 '\n  ─── Editing Profile: %b%s%b ───\n' "$BOLD" "$label" "$RESET"
    
    # Name
    ask "Full Name" "${PROFILE_NAMES[i]}"
    if [[ -n "$REPLY" ]]; then PROFILE_NAMES[i]="$REPLY"; fi
    
    # Email
    ask "Email Address" "${PROFILE_EMAILS[i]}"
    if [[ -n "$REPLY" ]]; then PROFILE_EMAILS[i]="$REPLY"; fi
    
    # Directory (skip for global)
    if [[ "$i" -ne 0 ]]; then
        ask "Directory (e.g. ~/work)" "${PROFILE_DIRS[i]}"
        if [[ -n "$REPLY" ]]; then PROFILE_DIRS[i]=$(normalize_path "$REPLY"); fi
    fi
    
    # Key
    local def_key="${PROFILE_KEYS[i]}"
    if confirm "Use a FIDO2 / YubiKey hardware key for this profile?" "n"; then
        if [[ "$def_key" != *"_sk_"* ]]; then
            def_key="${def_key/id_ed25519/id_ed25519_sk}"
        fi
    else
        def_key="${def_key/_sk_/}"
    fi
    ask "SSH Key Path" "$def_key"
    if [[ -n "$REPLY" ]]; then PROFILE_KEYS[i]=$(normalize_path "$REPLY"); fi

    # HTTPS PAT Integration
    ask "Provider Username (e.g. GitHub handle, for HTTPS cloning)" "${PROFILE_USERS[i]:-}"
    if [[ -n "$REPLY" ]]; then 
        PROFILE_USERS[i]="$REPLY"
        if confirm "Would you like to store a Personal Access Token (PAT) for this profile now?" "n"; then
            ask_password "Enter PAT token"
            if [[ -n "$REPLY" ]]; then
                PROFILE_PATS[i]="$REPLY"
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# prompt_add_profile
# ------------------------------------------------------------------------------
prompt_add_profile() {
    printf >&2 '\n  ─── Adding New Profile ───\n'
    
    ask_required "Profile Label (e.g. oss, client)"
    local label
    label=$(to_lower "$REPLY")
    
    while ! validate_label "$label" || array_contains "$label" "${PROFILE_LABELS[@]+"${PROFILE_LABELS[@]}"}"; do
        print_warning "Invalid or duplicate label."
        ask_required "Profile Label"
        label=$(to_lower "$REPLY")
    done
    
    PROFILE_LABELS[PROFILE_COUNT]="$label"
    
    # Default name to global
    local def_name="${PROFILE_NAMES[0]}"
    ask "Full Name" "$def_name"
    PROFILE_NAMES[PROFILE_COUNT]="$REPLY"
    
    ask "Email Address" ""
    PROFILE_EMAILS[PROFILE_COUNT]="$REPLY"
    
    local def_dir="$HOME/$label"
    ask "Directory" "$def_dir"
    PROFILE_DIRS[PROFILE_COUNT]=$(normalize_path "$REPLY")
    
    local def_key="$HOME/.ssh/id_ed25519_${label}"
    if confirm "Use a FIDO2 / YubiKey hardware key for this profile?" "n"; then
        def_key="$HOME/.ssh/id_ed25519_sk_${label}"
    fi
    ask "SSH Key Path" "$def_key"
    PROFILE_KEYS[PROFILE_COUNT]=$(normalize_path "$REPLY")
    
    PROFILE_PROVIDERS[PROFILE_COUNT]="github.com"
    PROFILE_SIGNS[PROFILE_COUNT]="${GITSETU_DEFAULT_SIGN:-0}"

    ask "Provider Username (e.g. GitHub handle, for HTTPS cloning)" ""
    PROFILE_USERS[PROFILE_COUNT]="$REPLY"
    PROFILE_PATS[PROFILE_COUNT]=""
    if [[ -n "$REPLY" ]]; then
        if confirm "Would you like to store a Personal Access Token (PAT) for this profile now?" "n"; then
            ask_password "Enter PAT token"
            if [[ -n "$REPLY" ]]; then
                PROFILE_PATS[PROFILE_COUNT]="$REPLY"
            fi
        fi
    fi

    PROFILE_COUNT=$((PROFILE_COUNT + 1))
}

# ------------------------------------------------------------------------------
# prompt_security
# ------------------------------------------------------------------------------
prompt_security() {
    printf >&2 '\n  ─── Global Security Settings ───\n'
    
    if confirm "Enable Native SSH Commit Signing for all generated profiles?" "n"; then
        GITSETU_DEFAULT_SIGN=1
        local i
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            PROFILE_SIGNS[i]=1
        done
    else
        GITSETU_DEFAULT_SIGN=0
        local i
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            PROFILE_SIGNS[i]=0
        done
    fi
    
    if confirm "Protect newly generated keys with a Passphrase?" "n"; then
        GITSETU_USE_PASSPHRASE=1
    else
        # shellcheck disable=SC2034  # consumed by generate_ssh_key() via dynamic scoping
        GITSETU_USE_PASSPHRASE=0
    fi
}

# ------------------------------------------------------------------------------
# ensure_workspace_dirs — Create profile workspace directories if missing
# ------------------------------------------------------------------------------
ensure_workspace_dirs() {
    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local dir="${PROFILE_DIRS[i]}"
        local label="${PROFILE_LABELS[i]}"
        if [[ -n "$dir" && "$dir" != "$HOME" ]]; then
            if [[ ! -d "$dir" ]]; then
                if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
                    print_info "[DRY RUN] Would create workspace directory: $dir"
                else
                    if mkdir -p "$dir" 2>/dev/null; then
                        print_success "Created workspace directory for '$label': $dir"
                    else
                        print_warning "Could not create workspace directory: $dir"
                    fi
                fi
            fi
        fi
    done
}

# ------------------------------------------------------------------------------
# Concurrency Locking Mechanism
# Implements atomic directory locking on $GITSETU_LOCK_DIR with PID liveness
# verification, stale lock recovery, 60s timeout handling, re-entrancy depth
# tracking, and explicit release.
# ------------------------------------------------------------------------------
# shellcheck disable=SC2120
acquire_lock() {
    local target_lock="${1:-${GITSETU_LOCK_DIR:-${GITSETU_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu}/profiles.lock}}"
    local config_dir
    config_dir=$(dirname "$target_lock")
    local max_retries=600  # 600 * 0.1s = 60 seconds max wait
    if [[ -n "${GITSETU_LOCK_TIMEOUT:-}" ]]; then
        if [[ "${GITSETU_TEST:-0}" -eq 1 ]]; then
            max_retries=$(( GITSETU_LOCK_TIMEOUT * 50 ))
        else
            max_retries=$(( GITSETU_LOCK_TIMEOUT * 10 ))
        fi
        [[ "$max_retries" -lt 1 ]] && max_retries=1
    fi
    local retry=0
    local no_pid_count=0
    local dead_pid_count=0

    # Re-entrancy: If current process already holds the lock, increment depth
    if [[ "${GITSETU_LOCK_DEPTH:-0}" -gt 0 ]]; then
        GITSETU_LOCK_DEPTH=$((GITSETU_LOCK_DEPTH + 1))
        return 0
    fi

    # Ensure parent config directory exists before attempting mkdir
    mkdir -p "$config_dir" 2>/dev/null || true

    while ! mkdir "$target_lock" 2>/dev/null; do
        local lock_pid=""
        if [[ -f "$target_lock/pid" ]]; then
            lock_pid=$(cat "$target_lock/pid" 2>/dev/null || echo "")
            lock_pid="${lock_pid%$'\r'}"
        fi

        # If current process already owns lock on disk, increment depth
        if [[ -n "$lock_pid" ]] && [[ "$lock_pid" == "$$" ]]; then
            GITSETU_LOCK_DEPTH=$((GITSETU_LOCK_DEPTH + 1))
            return 0
        fi

        # Case 1: Holding process is dead (stale lock recovery)
        # Require 3 consecutive confirmations to avoid transient false-positives
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            dead_pid_count=$((dead_pid_count + 1))
            if [[ "$dead_pid_count" -ge 3 ]]; then
                if mv "$target_lock" "${target_lock}.stale.$$" 2>/dev/null; then
                    rm -rf "${target_lock}.stale.$$" 2>/dev/null || true
                    dead_pid_count=0
                    continue
                fi
            fi
        else
            dead_pid_count=0
        fi

        # Case 2: PID file missing or empty (process died before writing PID)
        if [[ -z "$lock_pid" ]]; then
            no_pid_count=$((no_pid_count + 1))
            if [[ "$no_pid_count" -ge 50 ]]; then
                if mv "$target_lock" "${target_lock}.stale.$$" 2>/dev/null; then
                    rm -rf "${target_lock}.stale.$$" 2>/dev/null || true
                    no_pid_count=0
                    continue
                fi
            fi
        else
            no_pid_count=0
        fi

        # Case 3: 60-second timeout recovery for abandoned locks
        local lock_time=""
        if [[ -f "$target_lock/timestamp" ]]; then
            lock_time=$(cat "$target_lock/timestamp" 2>/dev/null || echo "")
            lock_time="${lock_time%$'\r'}"
        fi
        if [[ -z "$lock_time" ]]; then
            lock_time=$(stat -c '%Y' "$target_lock" 2>/dev/null || stat -f '%m' "$target_lock" 2>/dev/null || echo "")
            lock_time="${lock_time%$'\r'}"
        fi
        local now
        now=$(date +%s 2>/dev/null || echo "")
        if [[ -n "$lock_time" ]] && [[ -n "$now" ]] && [[ "$now" =~ ^[0-9]+$ ]] && [[ "$lock_time" =~ ^[0-9]+$ ]]; then
            local age=$((now - lock_time))
            if [[ "$age" -ge 60 ]]; then
                if mv "$target_lock" "${target_lock}.stale.$$" 2>/dev/null; then
                    rm -rf "${target_lock}.stale.$$" 2>/dev/null || true
                    continue
                fi
            fi
        fi

        retry=$((retry + 1))
        if [[ "$retry" -ge "$max_retries" ]]; then
            print_error "Failed to acquire lock for profiles.conf after timeout. Is another gitsetu process running?"
            return 1
        fi
        local sleep_dur=0.1
        if [[ "${GITSETU_TEST:-0}" -eq 1 ]]; then
            sleep_dur=0.02
        fi
        sleep "$sleep_dur"
    done

    # Lock acquired: atomically write PID (via temp file rename) and creation timestamp
    echo "$$" > "$target_lock/pid.tmp.$$" 2>/dev/null || echo "$$" > "$target_lock/pid"
    mv -f "$target_lock/pid.tmp.$$" "$target_lock/pid" 2>/dev/null || true
    date +%s > "$target_lock/timestamp" 2>/dev/null || true
    GITSETU_LOCK_DEPTH=1
    GITSETU_CLEANUP_DIRS+=("$target_lock")
    return 0
}

# shellcheck disable=SC2120
release_lock() {
    local target_lock="${1:-${GITSETU_LOCK_DIR:-${GITSETU_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu}/profiles.lock}}"

    # If current process does not hold the lock, do nothing
    if [[ "${GITSETU_LOCK_DEPTH:-0}" -le 0 ]]; then
        return 0
    fi

    if [[ "$GITSETU_LOCK_DEPTH" -gt 1 ]]; then
        GITSETU_LOCK_DEPTH=$((GITSETU_LOCK_DEPTH - 1))
        return 0
    fi
    GITSETU_LOCK_DEPTH=0

    if [[ -d "$target_lock" ]]; then
        local lock_pid=""
        if [[ -f "$target_lock/pid" ]]; then
            lock_pid=$(cat "$target_lock/pid" 2>/dev/null || echo "")
            lock_pid="${lock_pid%$'\r'}"
        fi
        # Only release if current process strictly owns the lock on disk
        if [[ "$lock_pid" == "$$" ]]; then
            # Atomic release: rename lock dir away so competing processes can immediately acquire
            local releasing_dir="${target_lock}.rel.$$"
            if mv "$target_lock" "$releasing_dir" 2>/dev/null; then
                rm -rf "$releasing_dir" 2>/dev/null || true
            else
                rm -f "$target_lock/pid" "$target_lock/timestamp" 2>/dev/null || true
                rmdir "$target_lock" 2>/dev/null || true
            fi
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# render_setup_summary — Displays post-setup completion summary (T2.5)
# ------------------------------------------------------------------------------
render_setup_summary() {
    print_section "Setup Complete"
    print_success "Setup complete! You're ready to go."
    printf >&2 '\n'

    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]] && declare -f load_profiles >/dev/null 2>&1; then
        load_profiles 2>/dev/null || true
    fi

    printf >&2 '  %bProfiles:%b\n' "$BOLD" "$RESET"
    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local label="${PROFILE_LABELS[i]}"
        local email="${PROFILE_EMAILS[i]}"
        local dir="${PROFILE_DIRS[i]:-}"
        local key_path="${PROFILE_KEYS[i]:-$HOME/.ssh/id_ed25519_${label}}"

        local dir_display="[Global]"
        if [[ -n "$dir" && "$dir" != "$HOME" ]]; then
            if [[ "$dir" == "$HOME/"* ]]; then
                dir_display="~/${dir#"$HOME"/}"
            elif [[ "$dir" == "$HOME" ]]; then
                dir_display="~"
            else
                dir_display="$dir"
            fi
        fi

        local key_status="${RED}${SYM_CROSS}${RESET}"
        if [[ -f "$key_path" ]]; then
            key_status="${GREEN}${SYM_CHECK}${RESET}"
        fi

        printf >&2 '    %-12s %-26s %-18s Key: %b\n' "[$label]" "$email" "$dir_display" "$key_status"
    done
    printf >&2 '\n'

    local guard_status="${DIM}Inactive${RESET}"
    if [[ -f "$GITSETU_HOOKS_DIR/pre-commit" ]]; then
        guard_status="${GREEN}Active${RESET}"
    fi
    printf >&2 '  %bGuard:%b %b\n\n' "$BOLD" "$RESET" "$guard_status"

    printf >&2 '  %bQuick Reference:%b\n' "$BOLD" "$RESET"
    printf >&2 '    %bgitsetu status%b    — check active identity\n' "$CYAN" "$RESET"
    printf >&2 '    %bgitsetu doctor%b    — diagnose issues\n' "$CYAN" "$RESET"
    printf >&2 '    %bgitsetu backup%b    — encrypted migration vault\n\n' "$CYAN" "$RESET"
}

# ------------------------------------------------------------------------------
# execute_blueprint
# ------------------------------------------------------------------------------
execute_blueprint() {
    acquire_lock || return 1

    clear || printf '\033c'
    print_section "Executing Setup Blueprint"
    
    ensure_dirs
    ensure_workspace_dirs

    # 1. Generate SSH keys
    print_section "Generating SSH Keys"
    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local key_path="${PROFILE_KEYS[i]}"
        
        if [[ -f "$key_path" ]]; then
            print_info "Using existing key: $key_path"
            continue
        fi
        
        generate_ssh_key "${PROFILE_LABELS[i]}" "${PROFILE_EMAILS[i]}" "$key_path"
        # shellcheck disable=SC2181
        if [[ $? -ne 0 ]] && [[ "$key_path" == *"_sk_"* ]]; then
            print_warning "FIDO2 Hardware Key generation failed."
            if confirm "Fallback to standard software SSH key for '${PROFILE_LABELS[i]}'?" "y"; then
                key_path="$HOME/.ssh/id_ed25519_${PROFILE_LABELS[i]}"
                PROFILE_KEYS[i]="$key_path"
                generate_ssh_key "${PROFILE_LABELS[i]}" "${PROFILE_EMAILS[i]}" "$key_path"
            else
                print_error "Setup aborted due to FIDO2 key generation failure."
                release_lock
                exit 1
            fi
        fi
    done

    # 1.5 Store PATs in Keychain
    local has_pats=0
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ -n "${PROFILE_PATS[$i]:-}" ]] && [[ -n "${PROFILE_USERS[$i]:-}" ]]; then
            has_pats=1
            break
        fi
    done
    if [[ "$has_pats" -eq 1 ]]; then
        print_section "Storing Credentials in Keychain"
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            if [[ -n "${PROFILE_PATS[$i]:-}" ]] && [[ -n "${PROFILE_USERS[$i]:-}" ]]; then
                local provider="${PROFILE_PROVIDERS[$i]:-github.com}"
                if keychain_store "${PROFILE_LABELS[i]}" "$provider" "${PROFILE_USERS[i]}" "${PROFILE_PATS[i]}"; then
                    print_success "Stored PAT for ${PROFILE_USERS[i]}@${provider}"
                else
                    print_error "Failed to store PAT for ${PROFILE_USERS[i]}@${provider}"
                fi
                # Erase PAT from memory after storing
                PROFILE_PATS[i]=""
            fi
        done
    fi

    # 2. Write global gitconfig
    print_section "Writing Git Configuration"
    write_global_gitconfig

    # 3. Write SSH config
    print_section "Updating SSH Configuration"
    write_ssh_config

    # 4. Write profiles registry
    write_profiles_conf

    # 5. Display public keys
    display_public_keys
    
    # 6. SSH agent key registration (T2.1)
    auto_register_ssh_keys
    printf >&2 '\n'

    # 6.5 Live SSH handshake verification with Port 443 fallback (T2.3)
    if [[ -z "${GITSETU_TEST:-}" || -n "${GITSETU_TEST_SSH_VERIFY:-}" || -n "${GITSETU_TEST_SSH:-}" ]]; then
        print_section "SSH Verification"
        local v_key_path v_provider
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            v_key_path="${PROFILE_KEYS[i]:-$HOME/.ssh/id_ed25519_${PROFILE_LABELS[i]}}"
            v_provider="${PROFILE_PROVIDERS[i]:-github.com}"
            verify_ssh_handshake "$v_key_path" "$v_provider" || true
        done
        printf >&2 '\n'

        if [[ "${GITSETU_PORT443_NEEDED:-0}" -eq 1 ]]; then
            print_info "Regenerating SSH configuration with Port 443 corporate fallback..."
            write_ssh_config
        fi
    fi

    # 7. Guard activation prompt (T2.4)
    if [[ ! -f "$GITSETU_HOOKS_DIR/pre-commit" ]] && [[ -z "${GITSETU_TEST:-}" ]]; then
        if confirm "Enable pre-commit identity guard (prevents wrong-email commits)?" "y"; then
            install_guard
        fi
    fi

    # 8. Post-setup completion summary (T2.5)
    render_setup_summary

    release_lock
}

# ------------------------------------------------------------------------------
# auto_setup_runner — Zero-prompt autonomous onboarding pipeline
# ------------------------------------------------------------------------------
auto_setup_runner() {
    load_profiles
    if [[ "$PROFILE_COUNT" -eq 0 ]]; then
        generate_initial_blueprint
    fi

    local default_name="${PROFILE_NAMES[0]:-}"
    local default_email="${PROFILE_EMAILS[0]:-}"

    if [[ -z "$default_email" ]]; then
        print_error "Auto-discovery could not detect a global Git email in ~/.gitconfig or ~/.ssh/."
        print_error "Please configure your email first via: git config --global user.email you@example.com"
        print_error "Or run interactive setup: gitsetu setup"
        return 1
    fi

    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ -z "${PROFILE_NAMES[i]}" ]]; then
            PROFILE_NAMES[i]="${default_name:-GitSetu User}"
        fi
        if [[ -z "${PROFILE_EMAILS[i]}" ]]; then
            PROFILE_EMAILS[i]="$default_email"
        fi
    done

    print_section "Zero-Prompt Auto-Discovery Blueprint"
    printf >&2 "  Discovered and configured %b%d%b profile(s):\n\n" "$BOLD" "$PROFILE_COUNT" "$RESET"

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local label="${PROFILE_LABELS[i]}"
        local name="${PROFILE_NAMES[i]}"
        local email="${PROFILE_EMAILS[i]}"
        local dir="${PROFILE_DIRS[i]:-[Global Fallback]}"
        local key="${PROFILE_KEYS[i]}"

        printf >&2 "  %b[%s]%b %s <%s>\n" "$BOLD" "$label" "$RESET" "$name" "$email"
        printf >&2 "     Dir: %s\n" "$dir"
        printf >&2 "     Key: %s\n\n" "$key"
    done

    execute_blueprint
}

# ------------------------------------------------------------------------------
# interactive_setup_wizard
# ------------------------------------------------------------------------------
interactive_setup_wizard() {
    # Bootstrap initial state if empty
    load_profiles
    if [[ "$PROFILE_COUNT" -eq 0 ]]; then
        generate_initial_blueprint
    fi

    # Check if fresh install: no profiles.conf or only unconfigured [global]
    if [[ "${GITSETU_SKIP_ON_RAMP:-0}" -ne 1 ]]; then
        local is_fresh=0
        if [[ ! -f "$GITSETU_PROFILES_CONF" ]]; then
            is_fresh=1
        elif [[ "$PROFILE_COUNT" -eq 0 ]]; then
            is_fresh=1
        elif [[ "$PROFILE_COUNT" -eq 1 ]] && [[ "${PROFILE_LABELS[0]}" == "global" ]] && [[ -z "${PROFILE_EMAILS[0]}" ]]; then
            is_fresh=1
        fi

        if [[ "$is_fresh" -eq 1 ]]; then
            local GITSETU_IN_WIZARD=1
            preset_guided_onboarding
            # If preset was applied, profiles now exist and are configured
            if [[ -f "$GITSETU_PROFILES_CONF" ]] && [[ "$PROFILE_COUNT" -gt 0 ]]; then
                if [[ "$PROFILE_COUNT" -gt 1 ]] || [[ -n "${PROFILE_EMAILS[0]}" ]]; then
                    return 0
                fi
            fi
            # If Option 3 was chosen, fall through to dashboard loop
        fi
    fi

    while true; do
        render_blueprint_dashboard
        
        local choice=""
        if ! read -r -p "[?] Select an option, or press ENTER to Apply: " choice; then
            print_info "Setup aborted."
            exit 0
        fi
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        
        case "$choice" in
            "")
                # Validate before applying
                local valid=1
                local i
                for (( i=0; i<PROFILE_COUNT; i++ )); do
                    if [[ -z "${PROFILE_NAMES[i]}" ]] || [[ -z "${PROFILE_EMAILS[i]}" ]]; then
                        print_warning "Profile '${PROFILE_LABELS[i]}' is incomplete. Please configure name and email:"
                        prompt_edit_profile "$i"
                        valid=0
                        break
                    fi
                done
                if [[ "$valid" -eq 1 ]]; then
                    execute_blueprint
                    break
                fi
                ;;
            "A")
                prompt_add_profile
                ;;
            "E")
                if [[ "$PROFILE_COUNT" -eq 1 ]]; then
                    prompt_edit_profile 0
                else
                    read -r -p "Enter profile number to edit (1-$PROFILE_COUNT): " idx
                    if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "$PROFILE_COUNT" ]]; then
                        prompt_edit_profile $((idx - 1))
                    fi
                fi
                ;;
            "R")
                read -r -p "Enter profile number to remove: " idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 2 ]] && [[ "$idx" -le "$PROFILE_COUNT" ]]; then
                    # Use safe array removal to preserve empty strings
                    local rem_idx=$((idx - 1))
                    remove_profile_at_index "$rem_idx"
                else
                    print_warning "Cannot remove default profile or invalid index."
                    sleep 1
                fi
                ;;
            "S")
                prompt_security
                ;;
            "Q"|"QUIT"|"EXIT")
                print_info "Setup aborted."
                exit 0
                ;;
            "H"|"HELP")
                clear || printf '\033c'
                printf >&2 '\n  %b─── GitSetu Setup Help ───%b\n\n' "$BOLD" "$RESET"
                printf >&2 '  GitSetu auto-discovers your SSH keys and Git configurations.\n'
                printf >&2 '  If the proposed Blueprint looks correct, simply press %bENTER%b to apply.\n\n' "$BOLD" "$RESET"
                printf >&2 '  %b[A]dd%b       : Manually add a new profile (e.g. client, oss).\n' "$BOLD" "$RESET"
                printf >&2 '  %b[E]dit%b      : Modify a profile. Select its number to change Name, Email, or Key.\n' "$BOLD" "$RESET"
                printf >&2 '  %b[R]emove%b    : Delete a profile from the Blueprint.\n' "$BOLD" "$RESET"
                printf >&2 '  %b[S]ecurity%b  : Configure advanced options like FIDO2 Hardware keys, Commit Signing,\n' "$BOLD" "$RESET"
                printf >&2 '                and SSH Passphrases.\n\n'
                printf >&2 '  Press ENTER to return to the Dashboard.\n'
                read -r
                ;;
            *)
                # If they typed a number, edit that profile
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$PROFILE_COUNT" ]]; then
                    prompt_edit_profile $((choice - 1))
                fi
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# cmd_add — Syntactic sugar for 'profile add' using positional arguments
# Usage: gitsetu add <label> "<name>" <email> <dir>
# ------------------------------------------------------------------------------
cmd_add() {
    local label="${1:-}"
    local name="${2:-}"
    local email="${3:-}"
    local dir="${4:-}"

    if [[ -z "$label" ]] || [[ -z "$name" ]] || [[ -z "$email" ]] || [[ -z "$dir" ]]; then
        print_error "Usage: gitsetu add <label> \"<name>\" <email> <dir>"
        printf >&2 "Example: gitsetu add personal \"Aditya Kumar\" aditya@gmail.com ~/personal\n"
        exit 1
    fi

    label=$(to_lower "$label")
    # Pass it to the underlying profile router
    cmd_profile add "$label" --name="$name" --email="$email" --dir="$dir"
}

# ------------------------------------------------------------------------------
# cmd_profile — Headless router for adding/removing profiles
# Usage: gitsetu profile add <label> --email="..."
# ------------------------------------------------------------------------------
cmd_profile() {
    local action="$1"
    shift
    local label="$1"
    shift

    if [[ -z "$action" ]] || [[ -z "$label" ]]; then
        print_error "Usage: gitsetu profile add|remove <label> [flags...]"
        exit 1
    fi
    label=$(to_lower "$label")

    acquire_lock || exit 1

    load_profiles
    if [[ "$PROFILE_COUNT" -eq 0 ]]; then
        generate_initial_blueprint
    fi

    case "$action" in
        add|edit)
            # Find if it exists
            local idx=-1
            local i
            for (( i=0; i<PROFILE_COUNT; i++ )); do
                if [[ "${PROFILE_LABELS[i]}" == "$label" ]]; then
                    idx=$i
                    break
                fi
            done

            if [[ "$idx" -eq -1 ]] && [[ "$action" == "edit" ]]; then
                print_error "Profile '$label' not found."
                release_lock
                exit 1
            fi

            if [[ "$idx" -eq -1 ]]; then
                if ! validate_label "$label"; then
                    print_error "Invalid profile label: '$label'."
                    release_lock
                    exit 1
                fi
                idx=$PROFILE_COUNT
                PROFILE_COUNT=$((PROFILE_COUNT + 1))
                PROFILE_LABELS[idx]="$label"
                PROFILE_NAMES[idx]="${PROFILE_NAMES[0]}" # default to global name
                PROFILE_EMAILS[idx]=""
                PROFILE_DIRS[idx]="$HOME/$label"
                PROFILE_PROVIDERS[idx]="github.com"
                PROFILE_SIGNS[idx]="${GITSETU_DEFAULT_SIGN:-0}"
                PROFILE_KEYS[idx]="$HOME/.ssh/id_ed25519_${label}"
                PROFILE_USERS[idx]=""
                PROFILE_PATS[idx]=""
            fi

            # Parse flags
            while [[ $# -gt 0 ]]; do
                # shellcheck disable=SC2034  # PROFILE_* arrays consumed by write_profiles_conf()
                case "$1" in
                    --name=*) PROFILE_NAMES[idx]="${1#*=}" ;;
                    --email=*) PROFILE_EMAILS[idx]="${1#*=}" ;;
                    --dir=*) PROFILE_DIRS[idx]=$(normalize_path "${1#*=}") ;;
                    --provider=*) PROFILE_PROVIDERS[idx]="${1#*=}" ;;
                    --key=*) PROFILE_KEYS[idx]=$(normalize_path "${1#*=}") ;;
                    --fido2) PROFILE_KEYS[idx]="$HOME/.ssh/id_ed25519_sk_${label}" ;;
                    --sign) PROFILE_SIGNS[idx]="1" ;;
                    --no-sign) PROFILE_SIGNS[idx]="0" ;;
                    *)
                        print_error "Unknown flag: $1"
                        release_lock
                        exit 1
                        ;;
                esac
                shift
            done

            # Validation
            if [[ -z "${PROFILE_EMAILS[idx]}" ]]; then
                if [[ -t 1 ]]; then
                    ask_required "Email Address for $label"
                    PROFILE_EMAILS[idx]="$REPLY"
                else
                    print_error "--email is required in headless mode."
                    release_lock
                    exit 1
                fi
            fi

            if ! validate_email "${PROFILE_EMAILS[idx]}"; then
                print_error "Invalid email address: '${PROFILE_EMAILS[idx]}'."
                release_lock
                exit 1
            fi

            execute_blueprint
            ;;
        remove)
            local idx=-1
            local i
            for (( i=0; i<PROFILE_COUNT; i++ )); do
                if [[ "${PROFILE_LABELS[i]}" == "$label" ]]; then
                    idx=$i
                    break
                fi
            done
            if [[ "$idx" -eq -1 ]]; then
                print_error "Profile '$label' not found."
                release_lock
                exit 1
            fi
            if [[ "$idx" -eq 0 ]]; then
                print_error "Cannot remove the global/default profile."
                release_lock
                exit 1
            fi

            rm -f "$GITSETU_PROFILES_DIR/${label}.gitconfig"

            # Use safe array removal to preserve empty strings
            remove_profile_at_index "$idx"

            execute_blueprint
            ;;
        *)
            print_error "Unknown profile action: $action"
            release_lock
            exit 1
            ;;
    esac
    release_lock
}
