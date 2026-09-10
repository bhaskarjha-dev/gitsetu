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
        
        printf >&2 '  %b%s) [%s]%b %s <%s>\n' "$BOLD" "$((i+1))" "$label" "$RESET" "$display_name" "$display_email"
        printf >&2 '     Key: %s %b\n' "$key" "$key_status"
        printf >&2 '     Dir: %s\n\n' "$display_dir"
    done

    printf >&2 '  ──────────────────────────────────────────────────────────\n'
    printf >&2 '  [A]dd Profile | [E]dit Profile | [R]emove | [S]ecurity \n'
    printf >&2 '  [H]elp        | [Q]uit         | [ENTER] Apply\n\n'
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
# execute_blueprint
# ------------------------------------------------------------------------------
execute_blueprint() {
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
    
    # SSH agent advice
    print_section "SSH Agent Setup"
    get_ssh_agent_advice
    printf >&2 '\n'

    print_success "Setup complete! You're ready to go."
    printf >&2 '\n'
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

    while true; do
        render_blueprint_dashboard
        
        read -r -p "[?] Select an option, or press ENTER to Apply: " choice
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        
        case "$choice" in
            "")
                # Validate before applying
                local valid=1
                local i
                for (( i=0; i<PROFILE_COUNT; i++ )); do
                    if [[ -z "${PROFILE_NAMES[i]}" ]] || [[ -z "${PROFILE_EMAILS[i]}" ]]; then
                        print_error "Profile '${PROFILE_LABELS[i]}' is missing a name or email!"
                        valid=0
                        sleep 2
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
                read -r -p "Enter profile number to edit (1-$PROFILE_COUNT): " idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "$PROFILE_COUNT" ]]; then
                    prompt_edit_profile $((idx - 1))
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

    # Acquire POSIX directory lock for headless read-modify-write safety
    local lock_dir="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu/profiles.lock"
    local max_retries=300
    local retry=0
    local no_pid_count=0
    
    # Ensure config directory exists before locking
    mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu"
    
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [[ -f "$lock_dir/pid" ]]; then
            no_pid_count=0
            local lock_pid
            lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                # The process holding the lock is dead. Stale lock!
                # Use atomic mv to prevent TOCTOU race conditions where multiple processes try to delete and acquire
                if mv "$lock_dir" "${lock_dir}.stale.$$" 2>/dev/null; then
                    rm -rf "${lock_dir}.stale.$$"
                    continue # Immediately retry acquiring (only the process that successfully mv'd gets here without sleep)
                fi
            fi
        else
            # Phantom deadlock prover: the lock dir exists but has no PID file.
            # This can happen legitimately for a microsecond while a healthy process
            # is between mkdir and echo $$. Only reap after 50 consecutive observations
            # (each separated by the 0.1s retry sleep) to definitively prove it's dead.
            no_pid_count=$((no_pid_count + 1))
            if [[ "$no_pid_count" -ge 50 ]]; then
                if mv "$lock_dir" "${lock_dir}.stale.$$" 2>/dev/null; then
                    rm -rf "${lock_dir}.stale.$$"
                    no_pid_count=0
                    continue
                fi
            fi
        fi
        
        retry=$((retry+1))
        if [[ "$retry" -ge "$max_retries" ]]; then
            print_error "Failed to acquire lock for profiles.conf. Is another gitsetu process running?"
            exit 1
        fi
        sleep 0.1
    done

    # Lock acquired. Write PID and register for cleanup.
    echo $$ > "$lock_dir/pid"
    GITSETU_CLEANUP_DIRS+=("$lock_dir")

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
                exit 1
            fi

            if [[ "$idx" -eq -1 ]]; then
                if ! validate_label "$label"; then
                    print_error "Invalid profile label: '$label'."
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
                    exit 1
                fi
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
                exit 1
            fi
            if [[ "$idx" -eq 0 ]]; then
                print_error "Cannot remove the global/default profile."
                exit 1
            fi

            rm -f "$GITSETU_PROFILES_DIR/${label}.gitconfig"

            # Use safe array removal to preserve empty strings
            remove_profile_at_index "$idx"

            execute_blueprint
            ;;
        *)
            print_error "Unknown profile action: $action"
            exit 1
            ;;
    esac
}
