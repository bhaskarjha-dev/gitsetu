#!/usr/bin/env bash
# lib/doctor.sh — GitSetu Diagnostics Module
#
# Analyzes the current environment to help users troubleshoot Git identity issues.

# ------------------------------------------------------------------------------
# run_doctor — Execute system diagnostics
# ------------------------------------------------------------------------------
run_doctor() {
    print_section "GitSetu Diagnostics (Doctor)"

    # 1. Determine active profile based on PWD
    local current_dir="$PWD"
    if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "mingw"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]]; then
        current_dir=$(pwd -W 2>/dev/null || echo "$current_dir")
    fi
    current_dir="$(normalize_path "$current_dir")"
    local active_profile="global"
    local active_dir="[Global Fallback]"

    local is_ci=0
    case "${GITSETU_OS:-${OSTYPE:-}}" in
        gitbash|macos|msys*|mingw*|cygwin*|darwin*) is_ci=1 ;;
        *)
            local u
            u=$(uname -s 2>/dev/null || true)
            case "$u" in
                MSYS*|MINGW*|CYGWIN*|Darwin*) is_ci=1 ;;
            esac
            ;;
    esac
    
    local i
    # Iterate backwards so more specific (later) profiles win
    for (( i=PROFILE_COUNT-1; i>=1; i-- )); do
        local dir="${PROFILE_DIRS[$i]}"
        local check_pwd="$current_dir"
        local check_dir="$dir"
        if [[ "$is_ci" -eq 1 ]]; then
            check_pwd=$(printf '%s' "$check_pwd" | tr '[:upper:]' '[:lower:]')
            check_dir=$(printf '%s' "$check_dir" | tr '[:upper:]' '[:lower:]')
        fi
        if [[ -n "$dir" ]] && { [[ "$check_pwd/" == "$check_dir/"* ]] || [[ "$check_pwd" == "$check_dir" ]]; }; then
            active_profile="${PROFILE_LABELS[$i]}"
            active_dir="$dir"
            break
        fi
    done

    printf >&2 "  %bDirectory Match:%b\n" "$BOLD" "$RESET"
    printf >&2 "    Current PWD: %s\n" "$current_dir"
    printf >&2 "    Active Profile: %b%s%b\n" "$GREEN" "$active_profile" "$RESET"
    if [[ "$active_profile" != "global" ]]; then
        printf >&2 "    Matched Rule: %s\n" "$active_dir"
    else
        printf >&2 "    Matched Rule: No profile directory matched, falling back to global.\n"
    fi
    printf >&2 "\n"

    # 2. Check Git resolution
    printf >&2 "  %bGit Identity Resolution:%b\n" "$BOLD" "$RESET"
    
    local resolved_name
    local resolved_email
    local resolved_key

    if command -v git >/dev/null 2>&1; then
        resolved_name=$(git config user.name 2>/dev/null || echo "(Not Configured)")
        resolved_email=$(git config user.email 2>/dev/null || echo "(Not Configured)")
        resolved_key=$(git config core.sshCommand 2>/dev/null | awk -F '-i ' '{print $2}' | awk '{print $1}' || echo "(Not Configured)")
        
        printf >&2 "    Resolved Name: %s\n" "$resolved_name"
        printf >&2 "    Resolved Email: %s\n" "$resolved_email"
        printf >&2 "    Resolved Key: %s\n" "$resolved_key"
    else
        printf >&2 "    %bGit is not installed or not in PATH!%b\n" "$RED" "$RESET"
    fi
    printf >&2 "\n"

    # 3. Check SSH Agent Status
    printf >&2 "  %bSSH Agent Status:%b\n" "$BOLD" "$RESET"
    
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        printf >&2 "    %bWARNING: SSH_AUTH_SOCK is not set. The ssh-agent is not running!%b\n" "$YELLOW" "$RESET"
        printf >&2 "    Run: eval \"\$(ssh-agent -s)\"\n"
    else
        printf >&2 "    Status: Running (Socket: %s)\n" "$SSH_AUTH_SOCK"
        
        local loaded_keys
        loaded_keys=$(ssh-add -l 2>/dev/null || true)
        
        if [[ "$loaded_keys" == *"The agent has no identities"* ]] || [[ -z "$loaded_keys" ]]; then
            printf >&2 "    Loaded Keys: %bNone!%b\n" "$YELLOW" "$RESET"
            printf >&2 "    Run: ssh-add ~/.ssh/id_ed25519_%s\n" "$active_profile"
        else
            printf >&2 "    Loaded Keys:\n"
            printf '%s\n' "$loaded_keys" | while read -r line; do
                printf >&2 "      - %s\n" "$line"
            done
        fi
    fi
    
    printf >&2 "\n"
    
    # 4. Check Config Integrity
    printf >&2 "  %bGitSetu Integrity:%b\n" "$BOLD" "$RESET"
    if [[ ! -f "$GITSETU_PROFILES_CONF" ]]; then
        printf >&2 "    %bERROR: Registry missing at %s%b\n" "$RED" "$GITSETU_PROFILES_CONF" "$RESET"
    else
        printf >&2 "    Registry: OK\n"
    fi
    
    if grep -qF "${GITSETU_MANAGED_START}" "$HOME/.gitconfig" 2>/dev/null; then
        printf >&2 "    ~/.gitconfig: OK (Managed blocks present)\n"
    else
        printf >&2 "    ~/.gitconfig: %bWARNING (Managed blocks missing)%b\n" "$YELLOW" "$RESET"
    fi

    local include_directive="Include ~/.config/gitsetu/profiles/ssh_config"
    if grep -qF "$include_directive" "$HOME/.ssh/config" 2>/dev/null || grep -qF "Include $GITSETU_PROFILES_DIR/ssh_config" "$HOME/.ssh/config" 2>/dev/null; then
        printf >&2 "    ~/.ssh/config: OK (Include directive present)\n"
    else
        printf >&2 "    ~/.ssh/config: %bWARNING (Include directive missing)%b\n" "$YELLOW" "$RESET"
    fi
    
    printf >&2 "\n"
}
