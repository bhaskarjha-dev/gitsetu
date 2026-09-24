#!/usr/bin/env bash
# lib/setup.sh — Interactive Blueprint Dashboard for GitSetu
#
# Replaces the linear wizard with a fast "Review & Apply" TUI menu.

# ------------------------------------------------------------------------------
# Configure a stable lock outside the removable configuration tree
# ------------------------------------------------------------------------------
_gitsetu_configure_lock_path() {
    local force="${2:-0}"
    local configured_default="${GITSETU_CONFIG_DIR%/}/profiles.lock"
    local core_default="${GITSETU_DEFAULT_LOCK_DIR:-}"
    local current="${GITSETU_LOCK_DIR:-}"
    local state_base="" candidate=""

    # A caller-provided non-default path is an explicit integration choice and
    # is still subject to absolute/control-character validation below.  The
    # core's safe state default is not an explicit override.
    if [[ "$force" != "1" && -n "$current" && "$current" != "$configured_default" && "$current" != "$core_default" ]]; then
        candidate="$current"
    elif [[ "${GITSETU_TEST:-0}" -eq 1 ]]; then
        state_base="${GITSETU_TEST_RUNTIME_DIR:-$HOME/.gitsetu-test-runtime}"
        candidate="${state_base%/}/profiles.lock"
    elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
        state_base="$XDG_STATE_HOME"
        candidate="${state_base%/}/gitsetu/profiles.lock"
    elif [[ "${GITSETU_OS:-}" == "gitbash" && -n "${LOCALAPPDATA:-}" ]]; then
        state_base="$LOCALAPPDATA"
        candidate="${state_base%/}/gitsetu/profiles.lock"
    else
        candidate="$HOME/.local/state/gitsetu/profiles.lock"
    fi

    [[ -n "$candidate" && "$candidate" != *[[:cntrl:]]* ]] || return 1
    case "$candidate" in
        /*|[A-Za-z]:/*) ;;
        *) return 1 ;;
    esac
    if declare -F normalize_path >/dev/null 2>&1; then
        local normalized
        normalized=$(normalize_path "$candidate") || return 1
        candidate="$normalized"
    fi
    GITSETU_LOCK_DIR="$candidate"
    return 0
}

# Resolve lazily in acquire_lock so test harnesses and embedders can finish
# assigning HOME/XDG variables after sourcing the libraries.
GITSETU_LOCK_RUNTIME_CONFIGURED=0

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

                execute_blueprint || return 1
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

                execute_blueprint || return 1
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
#
# The lock is an atomically-created private directory.  Ownership is represented
# by a high-entropy token as well as a PID.  A PID by itself is not sufficient:
# it can be reused, and a cleanup handler in another shell can observe the same
# numeric PID.  process_start is an additional best-effort process identity on
# platforms that expose it.
#
# A live, fully-identified owner is never evicted merely because its timestamp
# is old.  That prevents a long backup/restore from being stolen underneath the
# owner.  Dead owners are confirmed repeatedly before atomic reaping.
# Incomplete lock directories are not treated as valid ownership records; they
# may only be reaped after a bounded grace period.
# ------------------------------------------------------------------------------
GITSETU_LOCK_PATH=""
GITSETU_LOCK_TOKEN=""
GITSETU_LOCK_PROCESS_START=""

_gitsetu_lock_process_start() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    local stat_line=""
    if [[ -r "/proc/$pid/stat" ]]; then
        stat_line=$(cat "/proc/$pid/stat" 2>/dev/null || true)
        # The executable name is parenthesized and may itself contain spaces.
        # The start-time field is field 22 overall, or field 20 after the final
        # closing parenthesis in /proc/<pid>/stat.
        if [[ "$stat_line" == *") "* ]]; then
            local stat_fields=()
            local stat_tail="${stat_line##*) }"
            IFS=' ' read -r -a stat_fields <<< "$stat_tail"
            if [[ ${#stat_fields[@]} -ge 20 ]]; then
                printf '%s' "${stat_fields[19]}"
                return 0
            fi
        fi
    fi

    # ps/lstart is portable across the Unix variants supported by GitSetu.  It
    # is intentionally a stable process-start description, not a wall clock.
    if command -v ps >/dev/null 2>&1; then
        local ps_start=""
        ps_start=$(ps -p "$pid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -n "$ps_start" ]]; then
            printf '%s' "$ps_start"
            return 0
        fi
    fi
    return 1
}

_gitsetu_new_lock_token() {
    local token=""
    if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        token=$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \r\n' | head -c 64)
    fi
    if [[ -z "$token" ]]; then
        # This fallback is for unusual embedded systems without /dev/urandom.
        # It remains collision-resistant by combining several changing values.
        token="$(printf '%s' "$$-${RANDOM}-${RANDOM}-$(date +%s 2>/dev/null || printf 0)" | cksum 2>/dev/null | tr -d ' ')"
        token="${token}$(printf '%s' "$RANDOM-$RANDOM" | cksum 2>/dev/null | tr -d ' ')"
    fi
    [[ "$token" =~ ^[0-9a-fA-F]{32,}$ ]] || return 1
    printf '%s' "$token"
}

_gitsetu_lock_read_value() {
    local lock_dir="$1"
    local field="$2"
    local value=""
    if [[ -f "$lock_dir/$field" && ! -L "$lock_dir/$field" ]]; then
        IFS= read -r value < "$lock_dir/$field" 2>/dev/null || true
        value="${value%$'\r'}"
    fi
    printf '%s' "$value"
}

_gitsetu_lock_on_disk_owned_by_current_process() {
    local target_lock="$1"
    local disk_pid disk_token held_token
    disk_pid=$(_gitsetu_lock_read_value "$target_lock" pid)
    disk_token=$(_gitsetu_lock_read_value "$target_lock" token)
    held_token="${GITSETU_LOCK_TOKEN:-}"
    [[ "$disk_pid" == "$$" && -n "$held_token" && "$disk_token" == "$held_token" ]]
}

_gitsetu_lock_path_mtime() {
    local path="$1" value=""
    [[ -e "$path" && ! -L "$path" ]] || return 1
    value=$(stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null || printf '')
    value="${value//[[:space:]]/}"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$value"
}

_gitsetu_lock_age_seconds() {
    local target_lock="$1"
    local lock_time now marker
    lock_time=$(_gitsetu_lock_read_value "$target_lock" timestamp)
    if [[ ! "$lock_time" =~ ^[0-9]+$ ]]; then
        # An incomplete lock may have no timestamp.  Prefer the directory mtime;
        # if the platform cannot stat the directory, use the oldest available
        # ownership-marker mtime rather than allowing the lock to live forever.
        lock_time=$(_gitsetu_lock_path_mtime "$target_lock" || printf '')
        if [[ ! "$lock_time" =~ ^[0-9]+$ ]]; then
            for marker in pid token process_start; do
                if [[ -e "$target_lock/$marker" && ! -L "$target_lock/$marker" ]]; then
                    lock_time=$(_gitsetu_lock_path_mtime "$target_lock/$marker" || printf '')
                    [[ "$lock_time" =~ ^[0-9]+$ ]] && break
                fi
            done
        fi
    fi
    now=$(date +%s 2>/dev/null || printf '')
    [[ "$lock_time" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
    local age=$((now - lock_time))
    [[ "$age" -ge 0 ]] || age=0
    printf '%s' "$age"
}

_gitsetu_lock_marker_signature() {
    local lock_dir="$1" marker digest size
    [[ -d "$lock_dir" && ! -L "$lock_dir" && -O "$lock_dir" ]] || return 1
    for marker in pid token process_start timestamp; do
        if [[ -L "$lock_dir/$marker" ]]; then
            return 1
        fi
        if [[ -f "$lock_dir/$marker" ]]; then
            digest=$(sha256sum "$lock_dir/$marker" 2>/dev/null | awk '{print $1}' || true)
            if [[ -z "$digest" ]]; then
                digest=$(cksum "$lock_dir/$marker" 2>/dev/null | awk '{print $1 ":" $2}' || true)
            fi
            size=$(wc -c < "$lock_dir/$marker" 2>/dev/null | tr -d '[:space:]' || printf '')
            [[ -n "$digest" && "$size" =~ ^[0-9]+$ ]] || return 1
            printf '%s=%s:%s\n' "$marker" "$size" "$digest"
        elif [[ -e "$lock_dir/$marker" ]]; then
            return 1
        else
            printf '%s=<absent>\n' "$marker"
        fi
    done
    return 0
}

# Atomically move a stale directory aside, then verify that the directory moved
# is the exact owner record observed before the rename.  A mismatched record is
# put back when possible and is never deleted.
_gitsetu_lock_reap_if_unchanged() {
    local target_lock="$1"
    local observed_token="${2:-}"
    local observed_signature="${3:-}"
    local stale_dir="${target_lock}.stale.$$.$RANDOM"
    local moved_token moved_signature

    [[ -d "$target_lock" && ! -L "$target_lock" && -O "$target_lock" ]] || return 1
    if [[ -z "$observed_signature" ]]; then
        observed_signature=$(_gitsetu_lock_marker_signature "$target_lock" 2>/dev/null) || return 1
    fi
    mv "$target_lock" "$stale_dir" 2>/dev/null || return 1
    if [[ ! -d "$stale_dir" || -L "$stale_dir" ]]; then
        return 1
    fi
    moved_signature=$(_gitsetu_lock_marker_signature "$stale_dir" 2>/dev/null) || {
        if [[ ! -e "$target_lock" && ! -L "$target_lock" ]]; then
            mv "$stale_dir" "$target_lock" 2>/dev/null || true
        fi
        return 1
    }
    moved_token=$(_gitsetu_lock_read_value "$stale_dir" token)

    if [[ -n "$observed_token" && "$moved_token" != "$observed_token" ]]; then
        if [[ ! -e "$target_lock" && ! -L "$target_lock" ]]; then
            mv "$stale_dir" "$target_lock" 2>/dev/null || true
        fi
        return 1
    fi
    if [[ -z "$observed_token" && -n "$moved_token" ]]; then
        if [[ ! -e "$target_lock" && ! -L "$target_lock" ]]; then
            mv "$stale_dir" "$target_lock" 2>/dev/null || true
        fi
        return 1
    fi
    if [[ "$moved_signature" != "$observed_signature" ]]; then
        if [[ ! -e "$target_lock" && ! -L "$target_lock" ]]; then
            mv "$stale_dir" "$target_lock" 2>/dev/null || true
        fi
        return 1
    fi

    rm -rf "$stale_dir" 2>/dev/null || true
    return 0
}

_gitsetu_lock_parent_is_safe() {
    local parent="$1" current="$1" up canonical
    [[ -n "$parent" && "$parent" != *[[:cntrl:]]* ]] || return 1
    case "$parent" in /*|[A-Za-z]:/*) ;; *) return 1 ;; esac
    canonical=$(normalize_path "$parent") || return 1
    [[ "$canonical" == "$parent" ]] || return 1
    while [[ -n "$current" && "$current" != "/" && ! "$current" =~ ^[A-Za-z]:/$ ]]; do
        if [[ -e "$current" || -L "$current" ]]; then
            [[ -d "$current" && ! -L "$current" && -O "$current" ]] || return 1
            if declare -F _gitsetu_is_reparse_point >/dev/null 2>&1 &&
               _gitsetu_is_reparse_point "$current"; then
                return 1
            fi
        fi
        if [[ "$current" =~ ^[A-Za-z]:$ ]]; then
            break
        fi
        up=$(dirname "$current") || return 1
        [[ "$up" != "$current" ]] || return 1
        current="$up"
    done
    return 0
}

# shellcheck disable=SC2120
acquire_lock() {
    local target_lock="${1:-}"
    if [[ -z "$target_lock" && ( "${GITSETU_LOCK_RUNTIME_CONFIGURED:-0}" -ne 1 || "${GITSETU_TEST:-0}" -eq 1 ) ]]; then
        local configure_force=0
        [[ "${GITSETU_TEST:-0}" -eq 1 ]] && configure_force=1
        _gitsetu_configure_lock_path 0 "$configure_force" || {
            print_error "Could not configure a safe absolute runtime lock path."
            return 1
        }
        GITSETU_LOCK_RUNTIME_CONFIGURED=1
    fi
    if [[ -z "$target_lock" ]]; then
        target_lock="${GITSETU_LOCK_DIR:-}"
    fi
    [[ -n "$target_lock" ]] || return 1
    target_lock="${target_lock%/}"
    [[ -n "$target_lock" && "$target_lock" != *[[:cntrl:]] ]] || return 1

    local max_retries=600  # 600 * 0.1s = 60 seconds by default
    if [[ -n "${GITSETU_LOCK_TIMEOUT:-}" ]]; then
        if [[ ! "${GITSETU_LOCK_TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${GITSETU_LOCK_TIMEOUT}" -lt 1 ]] || [[ "${GITSETU_LOCK_TIMEOUT}" -gt 3600 ]]; then
            print_error "GITSETU_LOCK_TIMEOUT must be an integer from 1 to 3600."
            return 1
        fi
        if [[ "${GITSETU_TEST:-0}" -eq 1 ]]; then
            max_retries=$((GITSETU_LOCK_TIMEOUT * 50))
        else
            max_retries=$((GITSETU_LOCK_TIMEOUT * 10))
        fi
    fi

    # Re-entrancy applies only to the exact lock already held by this shell.
    # Silently treating a different path as re-entrancy would let a caller mutate
    # another resource while release_lock still tracks only one owner token.
    if [[ "${GITSETU_LOCK_DEPTH:-0}" -gt 0 ]]; then
        if [[ -n "${GITSETU_LOCK_PATH:-}" && "$target_lock" == "$GITSETU_LOCK_PATH" ]] && \
           _gitsetu_lock_on_disk_owned_by_current_process "$target_lock"; then
            GITSETU_LOCK_DEPTH=$((GITSETU_LOCK_DEPTH + 1))
            return 0
        fi
        print_error "Cannot acquire a second lock while $GITSETU_LOCK_PATH is held by this process."
        return 1
    fi

    local config_dir
    config_dir=$(dirname "$target_lock")
    _gitsetu_lock_parent_is_safe "$config_dir" || {
        print_error "Refusing redirected or non-canonical lock parent: $config_dir"
        return 1
    }
    (umask 077 && mkdir -p "$config_dir") 2>/dev/null || {
        print_error "Failed to create lock parent directory: $config_dir"
        return 1
    }
    _gitsetu_lock_parent_is_safe "$config_dir" || {
        print_error "Lock parent became redirected or non-canonical: $config_dir"
        return 1
    }
    chmod 700 "$config_dir" 2>/dev/null || {
        print_error "Failed to restrict lock parent directory: $config_dir"
        return 1
    }

    local retry=0
    local dead_pid_count=0
    local incomplete_count=0
    local test_mode=0
    [[ "${GITSETU_TEST:-0}" -eq 1 ]] && test_mode=1

    while ! (umask 077 && mkdir "$target_lock") 2>/dev/null; do
        # Never follow or remove a symlink posing as the lock directory.
        if [[ -L "$target_lock" ]]; then
            print_error "Refusing unsafe lock path (symbolic link): $target_lock"
            return 1
        fi

        local lock_pid lock_token lock_start recorded_start now_start observed_signature=""
        lock_pid=$(_gitsetu_lock_read_value "$target_lock" pid)
        lock_token=$(_gitsetu_lock_read_value "$target_lock" token)
        lock_start=$(_gitsetu_lock_read_value "$target_lock" process_start)

        # A fully identified, live owner is authoritative regardless of age.
        if [[ "$lock_pid" =~ ^[0-9]+$ && -n "$lock_token" ]]; then
            local owner_alive=0
            if kill -0 "$lock_pid" 2>/dev/null; then
                owner_alive=1
            fi
            if [[ "$owner_alive" -eq 1 ]]; then
                if [[ -n "$lock_start" ]]; then
                    now_start=$(_gitsetu_lock_process_start "$lock_pid" || printf '')
                    if [[ -n "$now_start" && "$now_start" != "$lock_start" ]]; then
                        owner_alive=0
                    fi
                fi
            fi

            if [[ "$owner_alive" -eq 1 ]]; then
                dead_pid_count=0
                incomplete_count=0
            else
                dead_pid_count=$((dead_pid_count + 1))
                incomplete_count=0
                # Require repeated observations so PID startup/exit races do not
                # cause another live owner to be reaped.
                if [[ "$dead_pid_count" -ge 3 ]]; then
                    observed_signature=$(_gitsetu_lock_marker_signature "$target_lock" 2>/dev/null || printf '')
                    if [[ -n "$observed_signature" ]] &&
                       _gitsetu_lock_reap_if_unchanged "$target_lock" "$lock_token" "$observed_signature"; then
                        dead_pid_count=0
                        continue
                    fi
                fi
            fi
        else
            dead_pid_count=0
            incomplete_count=$((incomplete_count + 1))
            local required_incomplete=250
            [[ "$test_mode" -eq 1 ]] && required_incomplete=5
            if [[ "$incomplete_count" -ge "$required_incomplete" ]]; then
                local lock_age=""
                lock_age=$(_gitsetu_lock_age_seconds "$target_lock" || printf '')
                if [[ -n "$lock_age" && "$lock_age" -ge 60 ]]; then
                    observed_signature=$(_gitsetu_lock_marker_signature "$target_lock" 2>/dev/null || printf '')
                    if [[ -n "$observed_signature" ]] &&
                       _gitsetu_lock_reap_if_unchanged "$target_lock" "$lock_token" "$observed_signature"; then
                        incomplete_count=0
                        continue
                    fi
                fi
            fi
        fi

        retry=$((retry + 1))
        if [[ "$retry" -ge "$max_retries" ]]; then
            print_error "Failed to acquire lock $target_lock after timeout. Is another gitsetu process running?"
            return 1
        fi
        local sleep_dur=0.1
        [[ "$test_mode" -eq 1 ]] && sleep_dur=0.02
        sleep "$sleep_dur"
    done

    local new_token process_start
    new_token=$(_gitsetu_new_lock_token) || {
        rmdir "$target_lock" 2>/dev/null || true
        print_error "Failed to generate lock ownership token."
        return 1
    }
    process_start=$(_gitsetu_lock_process_start "$$" || printf '')

    # The mkdir is the ownership gate.  Populate identity files before exposing
    # the lock to API callers; contenders treat incomplete records as invalid.
    if ! (umask 077
          printf '%s\n' "$$" > "$target_lock/pid" &&
          printf '%s\n' "$new_token" > "$target_lock/token" &&
          printf '%s\n' "$process_start" > "$target_lock/process_start" &&
          date +%s > "$target_lock/timestamp") ||
       ! chmod 700 "$target_lock" 2>/dev/null; then
        rm -f "$target_lock/pid" "$target_lock/token" "$target_lock/process_start" "$target_lock/timestamp" 2>/dev/null || true
        rmdir "$target_lock" 2>/dev/null || true
        print_error "Failed to initialize lock ownership metadata."
        return 1
    fi

    GITSETU_LOCK_PATH="$target_lock"
    GITSETU_LOCK_TOKEN="$new_token"
    GITSETU_LOCK_PROCESS_START="$process_start"
    GITSETU_LOCK_DEPTH=1
    return 0
}

# shellcheck disable=SC2120
release_lock() {
    local target_lock="${1:-${GITSETU_LOCK_PATH:-${GITSETU_LOCK_DIR:-}}}"
    target_lock="${target_lock%/}"

    if [[ "${GITSETU_LOCK_DEPTH:-0}" -le 0 ]]; then
        return 0
    fi
    if [[ -z "${GITSETU_LOCK_PATH:-}" || "$target_lock" != "$GITSETU_LOCK_PATH" ]]; then
        print_error "Refusing to release $target_lock; this process owns ${GITSETU_LOCK_PATH:-no lock}."
        return 1
    fi

    if [[ "$GITSETU_LOCK_DEPTH" -gt 1 ]]; then
        GITSETU_LOCK_DEPTH=$((GITSETU_LOCK_DEPTH - 1))
        return 0
    fi

    local disk_pid disk_token releasing_dir
    disk_pid=$(_gitsetu_lock_read_value "$target_lock" pid)
    disk_token=$(_gitsetu_lock_read_value "$target_lock" token)
    if [[ -d "$target_lock" && ! -L "$target_lock" && "$disk_pid" == "$$" && -n "${GITSETU_LOCK_TOKEN:-}" && "$disk_token" == "$GITSETU_LOCK_TOKEN" ]]; then
        releasing_dir="${target_lock}.rel.$$.$RANDOM"
        if mv "$target_lock" "$releasing_dir" 2>/dev/null; then
            # Re-verify the renamed directory before deleting it.  This avoids a
            # path-replacement race turning release into deletion of a new owner.
            local moved_pid moved_token
            moved_pid=$(_gitsetu_lock_read_value "$releasing_dir" pid)
            moved_token=$(_gitsetu_lock_read_value "$releasing_dir" token)
            if [[ "$moved_pid" == "$$" && "$moved_token" == "$GITSETU_LOCK_TOKEN" ]]; then
                rm -rf "$releasing_dir" 2>/dev/null || true
            fi
        fi
    fi

    GITSETU_LOCK_DEPTH=0
    GITSETU_LOCK_PATH=""
    GITSETU_LOCK_TOKEN=""
    GITSETU_LOCK_PROCESS_START=""
    return 0
}

# ------------------------------------------------------------------------------
# Registry entrypoint guard
# ------------------------------------------------------------------------------
_setup_load_registry_for_entrypoint() {
    if [[ ! -e "$GITSETU_PROFILES_CONF" && ! -L "$GITSETU_PROFILES_CONF" ]]; then
        load_profiles || {
            print_error "Could not initialize an empty profile state."
            return 1
        }
        return 0
    fi
    if ! load_profiles; then
        print_error "Profile registry validation failed; no changes were made."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# render_setup_summary — Displays post-setup completion summary (T2.5)
# ------------------------------------------------------------------------------
render_setup_summary() {
    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        _setup_load_registry_for_entrypoint || return 1
    fi

    print_section "Setup Complete"
    print_success "Setup complete! You're ready to go."
    printf >&2 '\n'

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
    printf >&2 '    %bgitsetu backup%b    — authenticated encrypted backup\n\n' "$CYAN" "$RESET"
}

# ------------------------------------------------------------------------------
# execute_blueprint transaction helpers
# ------------------------------------------------------------------------------
_setup_prepare_transaction_parent() {
    local parent="${GITSETU_CONFIG_DIR%/}"
    parent=$(dirname "$parent") || return 1
    [[ -n "$parent" && "$parent" != *[[:cntrl:]]* ]] || return 1
    case "$parent" in
        /*|[A-Za-z]:/*) ;;
        *) return 1 ;;
    esac

    # Validate all existing ancestors before creating a missing config parent;
    # never let mktemp follow a symlink/reparse point.
    _gitsetu_lock_parent_is_safe "$parent" || return 1
    (umask 077 && mkdir -p "$parent") 2>/dev/null || return 1
    _gitsetu_lock_parent_is_safe "$parent" || return 1
    chmod 700 "$parent" 2>/dev/null || return 1
    if declare -F _gitsetu_private_directory >/dev/null 2>&1; then
        _gitsetu_private_directory "$parent" || return 1
    fi
    return 0
}

_SETUP_TRANSACTION_DIR=""
_SETUP_CREATED_KEYS=()
_SETUP_STORED_CREDENTIAL_LABELS=()
_SETUP_STORED_CREDENTIAL_PROVIDERS=()

_setup_snapshot_regular_or_tree() {
    local source_path="$1" snapshot_path="$2"
    if [[ -e "$source_path" || -L "$source_path" ]]; then
        [[ -O "$source_path" ]] || return 1
        if declare -F _gitsetu_is_reparse_point >/dev/null 2>&1 &&
           _gitsetu_is_reparse_point "$source_path"; then
            return 1
        fi
    fi
    if [[ -f "$source_path" && ! -L "$source_path" ]]; then
        cp -p "$source_path" "$snapshot_path" 2>/dev/null || return 1
        printf 'present\n' > "${snapshot_path}.state" || return 1
        return 0
    fi
    if [[ -d "$source_path" && ! -L "$source_path" ]]; then
        cp -pR "$source_path" "$snapshot_path" 2>/dev/null || return 1
        printf 'present\n' > "${snapshot_path}.state" || return 1
        return 0
    fi
    [[ ! -e "$source_path" && ! -L "$source_path" ]] || return 1
    printf 'absent\n' > "${snapshot_path}.state" || return 1
}

_setup_snapshot_target() {
    local txn="$1" name="$2" source_path="$3"
    _setup_snapshot_regular_or_tree "$source_path" "$txn/snapshots/$name"
}

_setup_restore_target() {
    local txn="$1" name="$2" destination="$3"
    local state="$txn/snapshots/$name.state"
    [[ -f "$state" ]] || return 1
    # A replacement symlink/reparse point is not owned state.  Refuse rollback
    # rather than deleting anything at that path or following it.
    if [[ -L "$destination" ]]; then
        return 1
    fi
    if [[ -d "$destination" ]]; then
        rm -rf "$destination" 2>/dev/null || return 1
    else
        rm -f "$destination" 2>/dev/null || return 1
    fi
    if grep -q '^present$' "$state" 2>/dev/null; then
        if [[ -d "$txn/snapshots/$name" && ! -L "$txn/snapshots/$name" ]]; then
            cp -pR "$txn/snapshots/$name" "$destination" 2>/dev/null || return 1
        elif [[ -f "$txn/snapshots/$name" && ! -L "$txn/snapshots/$name" ]]; then
            cp -p "$txn/snapshots/$name" "$destination" 2>/dev/null || return 1
        else
            return 1
        fi
    fi
    return 0
}

_setup_begin_transaction() {
    _SETUP_TRANSACTION_DIR=""
    _SETUP_CREATED_KEYS=()
    _SETUP_STORED_CREDENTIAL_LABELS=()
    _SETUP_STORED_CREDENTIAL_PROVIDERS=()
    [[ "${GITSETU_DRY_RUN:-0}" -eq 0 ]] || return 0

    local parent txn
    _setup_prepare_transaction_parent || return 1
    parent=$(dirname "${GITSETU_CONFIG_DIR%/}") || return 1
    txn=$(umask 077 && mktemp -d "$parent/.gitsetu-setup.XXXXXX" 2>/dev/null) || return 1
    chmod 700 "$txn" 2>/dev/null || { rm -rf "$txn" 2>/dev/null || true; return 1; }
    (umask 077 && mkdir -p "$txn/snapshots") 2>/dev/null || {
        rm -rf "$txn" 2>/dev/null || true
        return 1
    }
    _SETUP_TRANSACTION_DIR="$txn"

    _setup_snapshot_target "$txn" profiles-conf "$GITSETU_PROFILES_CONF" || return 1
    _setup_snapshot_target "$txn" profiles-dir "$GITSETU_PROFILES_DIR" || return 1
    _setup_snapshot_target "$txn" hooks-dir "$GITSETU_HOOKS_DIR" || return 1
    _setup_snapshot_target "$txn" tokens "$GITSETU_CONFIG_DIR/.tokens" || return 1
    _setup_snapshot_target "$txn" gitconfig "$HOME/.gitconfig" || return 1
    _setup_snapshot_target "$txn" sshconfig "$HOME/.ssh/config" || return 1
    return 0
}

delete_managed_key_after_confirmation() {
    local key_path="${1:-}"
    _setup_validate_managed_key_destination "$key_path" || return 1
    if ! confirm "Delete SSH key '$key_path' and its public key permanently?" "n"; then
        print_info "Key kept."
        return 0
    fi
    # Recheck immediately after the prompt: a replacement/reparse point invalidates
    # the user's confirmation and must never be removed.
    _setup_validate_managed_key_destination || return 1
    rm -f "$key_path" "${key_path}.pub" || return 1
}

_setup_validate_managed_key_destination() {
    local key_path="${1:-}" managed_root current
    validate_key_path "$key_path" || return 1
    managed_root=$(normalize_path "$HOME/.ssh") || return 1
    case "$key_path" in "$managed_root"/*) ;; *) return 1 ;; esac
    if [[ -L "$key_path" || -L "${key_path}.pub" ]]; then
        return 1
    fi
    if [[ -e "$key_path" && ! -f "$key_path" ]]; then return 1; fi
    if [[ -e "${key_path}.pub" && ! -f "${key_path}.pub" ]]; then return 1; fi
    current="${key_path%/*}"
    while [[ -n "$current" && "$current" != "." && ! "$current" =~ ^[A-Za-z]:/$ ]]; do
        [[ ! -L "$current" ]] || return 1
        [[ "$current" == "$managed_root" ]] && return 0
        local parent
        parent=$(dirname "$current") || return 1
        [[ "$parent" != "$current" ]] || return 1
        current="$parent"
    done
    return 1
}

_setup_remove_created_key_safely() {
    local key_path="$1" managed_root current
    validate_key_path "$key_path" || return 1
    managed_root=$(normalize_path "$HOME/.ssh") || return 1
    case "$key_path" in
        "$managed_root"/*) ;;
        *) return 1 ;;
    esac
    [[ ! -L "$key_path" ]] || return 1
    current="${key_path%/*}"
    while [[ -n "$current" && "$current" != "." && ! "$current" =~ ^[A-Za-z]:/$ ]]; do
        [[ ! -L "$current" ]] || return 1
        [[ "$current" == "$managed_root" ]] && break
        local parent
        parent=$(dirname "$current") || return 1
        [[ "$parent" != "$current" ]] || return 1
        current="$parent"
    done
    rm -f "$key_path" "${key_path}.pub" 2>/dev/null || return 1
}

_setup_rollback_transaction() {
    local txn="${_SETUP_TRANSACTION_DIR:-}" i failed=0
    # Remove credentials stored during this attempt before restoring files.
    for (( i=${#_SETUP_STORED_CREDENTIAL_LABELS[@]}-1; i>=0; i-- )); do
        if declare -F keychain_erase >/dev/null 2>&1; then
            keychain_erase "${_SETUP_STORED_CREDENTIAL_LABELS[$i]}" \
                "${_SETUP_STORED_CREDENTIAL_PROVIDERS[$i]}" >/dev/null 2>&1 || failed=1
        fi
    done
    _SETUP_STORED_CREDENTIAL_LABELS=()
    _SETUP_STORED_CREDENTIAL_PROVIDERS=()

    for (( i=${#_SETUP_CREATED_KEYS[@]}-1; i>=0; i-- )); do
        _setup_remove_created_key_safely "${_SETUP_CREATED_KEYS[$i]}" || failed=1
    done
    _SETUP_CREATED_KEYS=()

    if [[ -n "$txn" && -d "$txn" ]]; then
        _setup_restore_target "$txn" profiles-conf "$GITSETU_PROFILES_CONF" || failed=1
        _setup_restore_target "$txn" profiles-dir "$GITSETU_PROFILES_DIR" || failed=1
        _setup_restore_target "$txn" hooks-dir "$GITSETU_HOOKS_DIR" || failed=1
        _setup_restore_target "$txn" tokens "$GITSETU_CONFIG_DIR/.tokens" || failed=1
        _setup_restore_target "$txn" gitconfig "$HOME/.gitconfig" || failed=1
        _setup_restore_target "$txn" sshconfig "$HOME/.ssh/config" || failed=1
        if [[ "$failed" -eq 0 ]]; then
            if rm -rf "$txn" 2>/dev/null; then
                _SETUP_TRANSACTION_DIR=""
            else
                failed=1
            fi
        fi
    else
        _SETUP_TRANSACTION_DIR=""
    fi
    return "$failed"
}

_setup_blueprint_abort() {
    local message="$1"
    print_error "$message"
    if ! _setup_rollback_transaction; then
        print_error "Setup rollback was incomplete. Recovery snapshots remain in $_SETUP_TRANSACTION_DIR."
    fi
    release_lock || true
    return 1
}

remove_profile_transaction() {
    local label="${1:-}" acquired=0 i idx=-1
    validate_label "$label" || return 1
    acquire_lock || return 1
    acquired=1
    if ! _setup_load_registry_for_entrypoint; then
        release_lock || true
        return 1
    fi
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ "${PROFILE_LABELS[$i]}" == "$label" ]]; then idx="$i"; break; fi
    done
    if [[ "$idx" == "0" ]] || ! validate_array_index "$idx" "$PROFILE_COUNT"; then
        print_error "The global profile cannot be removed and the profile must exist."
        release_lock || true
        return 1
    fi
    if ! _setup_begin_transaction; then
        _setup_blueprint_abort "Could not initialize the profile-removal transaction."
        return 1
    fi
    if ! remove_profile_at_index "$idx"; then
        _setup_blueprint_abort "Could not stage profile removal."
        return 1
    fi
    if ! write_profiles_conf ||
       ! write_global_gitconfig ||
       ! write_ssh_config; then
        _setup_blueprint_abort "Profile removal could not regenerate all state; rolling back."
        return 1
    fi
    if [[ -n "$_SETUP_TRANSACTION_DIR" ]]; then
        rm -rf "$_SETUP_TRANSACTION_DIR" 2>/dev/null || true
        _SETUP_TRANSACTION_DIR=""
    fi
    release_lock || return 1
    print_success "Profile '$label' successfully removed."
    return 0
}

# ------------------------------------------------------------------------------
# execute_blueprint
# ------------------------------------------------------------------------------
execute_blueprint() {
    acquire_lock || return 1

    if [[ -t 2 ]]; then
        clear || printf '\033c'
    else
        printf '\033c'
    fi
    print_section "Executing Setup Blueprint"

    if ! _setup_begin_transaction; then
        _setup_blueprint_abort "Could not initialize the setup transaction."
        return 1
    fi
    if ! ensure_dirs; then
        _setup_blueprint_abort "Could not create GitSetu state directories."
        return 1
    fi
    if ! ensure_workspace_dirs; then
        _setup_blueprint_abort "Could not prepare profile workspace directories."
        return 1
    fi

    # 1. Generate SSH keys
    print_section "Generating SSH Keys"
    local i key_path fallback_path
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        key_path="${PROFILE_KEYS[i]}"

        if [[ -f "$key_path" && ! -L "$key_path" ]]; then
            print_info "Using existing key: $key_path"
            continue
        fi
        if [[ -e "$key_path" || -L "$key_path" ]]; then
            _setup_blueprint_abort "Key path is not a regular file: $key_path"
            return 1
        fi
        _SETUP_CREATED_KEYS+=("$key_path")

        if ! generate_ssh_key "${PROFILE_LABELS[i]}" "${PROFILE_EMAILS[i]}" "$key_path"; then
            if [[ "$key_path" != *"_sk_"* ]]; then
                _setup_blueprint_abort "SSH key generation failed for profile '${PROFILE_LABELS[i]}'."
                return 1
            fi
            print_warning "FIDO2 hardware key generation failed for '${PROFILE_LABELS[i]}'."
            if ! confirm "Fallback to a software SSH key for '${PROFILE_LABELS[i]}'?" "n"; then
                _setup_blueprint_abort "Setup aborted at the explicit FIDO2 fallback prompt."
                return 1
            fi
            fallback_path="$HOME/.ssh/id_ed25519_${PROFILE_LABELS[i]}"
            if [[ ! -e "$fallback_path" && ! -L "$fallback_path" ]]; then
                _SETUP_CREATED_KEYS+=("$fallback_path")
            fi
            if ! generate_ssh_key "${PROFILE_LABELS[i]}" "${PROFILE_EMAILS[i]}" "$fallback_path"; then
                _setup_blueprint_abort "Software SSH key fallback failed for profile '${PROFILE_LABELS[i]}'."
                return 1
            fi
            PROFILE_KEYS[i]="$fallback_path"
            key_path="$fallback_path"
        fi
        if [[ "${GITSETU_DRY_RUN:-0}" -ne 1 ]] && [[ ! -f "$key_path" || -L "$key_path" ]]; then
            _setup_blueprint_abort "SSH key generation did not produce a regular key: $key_path"
            return 1
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
                if ! keychain_store "${PROFILE_LABELS[i]}" "$provider" "${PROFILE_USERS[i]}" "${PROFILE_PATS[i]}"; then
                    PROFILE_PATS[i]=""
                    _setup_blueprint_abort "Failed to store PAT for ${PROFILE_USERS[i]}@${provider}."
                    return 1
                fi
                _SETUP_STORED_CREDENTIAL_LABELS+=("${PROFILE_LABELS[i]}")
                _SETUP_STORED_CREDENTIAL_PROVIDERS+=("$provider")
                print_success "Stored PAT for ${PROFILE_USERS[i]}@${provider}"
                PROFILE_PATS[i]=""
            fi
        done
    fi

    # 2. Write global gitconfig
    print_section "Writing Git Configuration"
    if ! write_global_gitconfig; then
        _setup_blueprint_abort "Failed to write global Git configuration."
        return 1
    fi

    print_section "Updating SSH Configuration"
    if ! write_ssh_config; then
        _setup_blueprint_abort "Failed to write SSH configuration."
        return 1
    fi

    if ! write_profiles_conf; then
        _setup_blueprint_abort "Failed to write the v2 profile registry."
        return 1
    fi

    if ! display_public_keys; then
        _setup_blueprint_abort "Failed to display generated public keys."
        return 1
    fi
    if ! auto_register_ssh_keys; then
        print_warning "SSH keys were generated, but automatic agent registration did not complete."
    fi
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
            if ! write_ssh_config; then
                _setup_blueprint_abort "Failed to regenerate SSH configuration after Port 443 fallback."
                return 1
            fi
        fi
    fi

    # 7. Guard activation prompt (T2.4)
    if [[ ! -f "$GITSETU_HOOKS_DIR/pre-commit" ]] && [[ -z "${GITSETU_TEST:-}" ]]; then
        if confirm "Enable pre-commit identity guard (prevents wrong-email commits)?" "y" &&
           ! install_guard; then
            _setup_blueprint_abort "Failed to install the pre-commit identity guard."
            return 1
        fi
    fi

    if [[ -n "$_SETUP_TRANSACTION_DIR" ]]; then
        if rm -rf "$_SETUP_TRANSACTION_DIR" 2>/dev/null; then
            _SETUP_TRANSACTION_DIR=""
        else
            print_warning "Could not remove completed setup snapshots: $_SETUP_TRANSACTION_DIR"
            _SETUP_TRANSACTION_DIR=""
        fi
    fi
    if ! release_lock; then
        print_error "Setup state was written, but the runtime lock could not be released cleanly."
        return 1
    fi
    render_setup_summary
}

# ------------------------------------------------------------------------------
# auto_setup_runner — Zero-prompt autonomous onboarding pipeline
# ------------------------------------------------------------------------------
auto_setup_runner() {
    _setup_load_registry_for_entrypoint || return 1
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
    # A missing registry bootstraps; a present invalid registry is fail-closed.
    _setup_load_registry_for_entrypoint || return 1
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
                    if ! execute_blueprint; then
                        return 1
                    fi
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
                    local idx menu_index
                    read -r -p "Enter profile number to edit (1-$PROFILE_COUNT): " idx
                    if validate_positive_integer "$idx"; then
                        menu_index=$(_gitsetu_uint_predecessor "$idx")
                        if validate_array_index "$menu_index" "$PROFILE_COUNT"; then
                            prompt_edit_profile "$menu_index"
                        fi
                    fi
                fi
                ;;
            "R")
                local idx menu_index
                read -r -p "Enter profile number to remove: " idx
                if validate_positive_integer "$idx"; then
                    menu_index=$(_gitsetu_uint_predecessor "$idx")
                    if [[ "$menu_index" != "0" ]] && validate_array_index "$menu_index" "$PROFILE_COUNT"; then
                        remove_profile_at_index "$menu_index"
                    fi
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
                # If they typed a canonical number, edit that profile.
                local choice_index
                if validate_positive_integer "$choice"; then
                    choice_index=$(_gitsetu_uint_predecessor "$choice")
                    if validate_array_index "$choice_index" "$PROFILE_COUNT"; then
                        prompt_edit_profile "$choice_index"
                    fi
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

    _setup_load_registry_for_entrypoint || { release_lock; exit 1; }
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

            if ! execute_blueprint; then
                release_lock || true
                return 1
            fi
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

            if ! remove_profile_transaction "$label"; then
                release_lock || true
                return 1
            fi
            return 0
            ;;
        *)
            print_error "Unknown profile action: $action"
            release_lock
            exit 1
            ;;
    esac
    release_lock
}
