#!/usr/bin/env bash
# lib/ui.sh — Terminal formatting, colors, symbols, and interactive prompts
#
# Respects NO_COLOR (https://no-color.org/) and non-TTY environments.
# Bash 3.2 compatible: no ${var,,}, uses printf for output.

# ------------------------------------------------------------------------------
# Color setup
# Disabled automatically if NO_COLOR is set or stderr is not a terminal.
# We check stderr (-t 2) because all gitsetu output goes to >&2.
# ------------------------------------------------------------------------------
setup_colors() {
    if [[ -z "${NO_COLOR:-}" ]] && [[ -t 2 ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        DIM='\033[2m'
        BOLD='\033[1m'
        RESET='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        CYAN=''
        DIM=''
        BOLD=''
        RESET=''
    fi
}

# Initialize colors on source
setup_colors

# ------------------------------------------------------------------------------
# Unicode symbols (with ASCII fallback for terminals that don't support UTF-8)
# ------------------------------------------------------------------------------
SYM_CHECK="✓"
SYM_CROSS="✗"
SYM_WARN="⚠"
SYM_INFO="i"
SYM_ARROW="→"
# shellcheck disable=SC2034  # Available for future subcommands
SYM_BULLET="•"

# ------------------------------------------------------------------------------
# Output functions
# All output goes to stderr to keep stdout clean for piping/scripting.
# ------------------------------------------------------------------------------

# Print the startup header with version
print_header() {
    printf >&2 '\n'
    printf >&2 '  %b╔══════════════════════════════════════╗%b\n' "$BOLD" "$RESET"
    printf >&2 '  %b║%b  %bgitsetu%b v%s%b                       ║%b\n' "$BOLD" "$RESET" "$CYAN$BOLD" "$RESET" "$GITSETU_VERSION" "$BOLD" "$RESET"
    printf >&2 '  %b║  One command. All identities.       ║%b\n' "$BOLD" "$RESET"
    printf >&2 '  %b╚══════════════════════════════════════╝%b\n' "$BOLD" "$RESET"
    printf >&2 '\n'
}

# Section divider: ─── Title ───
print_section() {
    local title="$1"
    printf >&2 '\n  %b─── %s ───%b\n\n' "$BOLD" "$title" "$RESET"
}

# Step indicator: → message
print_step() {
    printf >&2 '  %b%s%b %s\n' "$CYAN" "$SYM_ARROW" "$RESET" "$1"
}

# Success: ✔ message (green)
print_success() {
    printf >&2 '  %b%s%b %s\n' "$GREEN" "$SYM_CHECK" "$RESET" "$1"
}

# Warning: ⚠ message (yellow)
print_warning() {
    printf >&2 '  %b%s%b %s\n' "$YELLOW" "$SYM_WARN" "$RESET" "$1"
}

# Error: ✖ message (red)
print_error() {
    printf >&2 '  %b%s%b %s\n' "$RED" "$SYM_CROSS" "$RESET" "$1"
}

# Info: ℹ message (blue)
print_info() {
    printf >&2 '  %b%s%b %s\n' "$BLUE" "$SYM_INFO" "$RESET" "$1"
}

# Print a public key in a formatted box for easy copying
# Usage: print_key_box "pro" "user@email.com" "/path/to/key.pub"
print_key_box() {
    local label="$1"
    local email="$2"
    local pubkey_path="$3"

    if [[ ! -f "$pubkey_path" ]]; then
        print_error "Key file not found: $pubkey_path"
        return 1
    fi

    local key_content
    key_content=$(cat "$pubkey_path")

    printf >&2 '\n'
    printf >&2 '  %b┌─ %s (%s) ─────────────────────┐%b\n' "$BOLD" "$label" "$email" "$RESET"
    printf >&2 '  %b│%b %s\n' "$DIM" "$RESET" "$key_content"
    printf >&2 '  %b└──────────────────────────────────────────┘%b\n' "$DIM" "$RESET"
    
    # Opportunistic Clipboard
    if copy_to_clipboard "$key_content"; then
        printf >&2 '  %b%s%b %bCOPIED TO CLIPBOARD!%b Add it here: %bhttps://github.com/settings/ssh/new%b\n' "$GREEN" "✓" "$RESET" "$BOLD" "$RESET" "$CYAN" "$RESET"
    else
        printf >&2 '  %b%s%b Copy and add at: %bhttps://github.com/settings/ssh/new%b\n' "$BLUE" "$SYM_INFO" "$RESET" "$BOLD" "$RESET"
    fi
    printf >&2 '\n'
}

# ------------------------------------------------------------------------------
# Prompt functions
#
# All prompts read from /dev/tty to work correctly even when stdin is piped.
# All use `read -r` (no backslash interpretation) for safety.
# Bash 3.2 compatible.
# ------------------------------------------------------------------------------

# Ask with optional default. Result in $REPLY.
# Usage: ask "Your name" "Bhaskar Jha"
ask() {
    local prompt="$1"
    local default="${2:-}"

    if [[ -n "$default" ]]; then
        printf >&2 '  %b[?]%b %s %b[%s]%b: ' "$CYAN" "$RESET" "$prompt" "$DIM" "$default" "$RESET"
    else
        printf >&2 '  %b[?]%b %s: ' "$CYAN" "$RESET" "$prompt"
    fi

    if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
        REPLY="$default"
    else
        read -r REPLY </dev/tty || true
        # Trim leading and trailing whitespace
        REPLY=$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -z "$REPLY" ]] && [[ -n "$default" ]]; then
            REPLY="$default"
        fi
    fi
}

# Ask for a password/token without echoing to the screen. Result in $REPLY.
# Usage: ask_password "Enter PAT token"
ask_password() {
    local prompt="$1"
    REPLY=""
    
    printf >&2 '  %b[?]%b %s: ' "$CYAN" "$RESET" "$prompt"
    
    if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
        return 0
    fi
    
    # Disable echo
    stty -echo 2>/dev/null || true
    read -r REPLY </dev/tty || true
    # Re-enable echo
    stty echo 2>/dev/null || true
    printf >&2 '\n'
    # Trim leading and trailing whitespace
    REPLY=$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
}

# Ask and loop until non-empty response. Result in $REPLY.
# Usage: ask_required "Your email"
ask_required() {
    local prompt="$1"
    REPLY=""

    if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
        print_error "Interactive prompt failed in CI/non-TTY environment: $prompt"
        exit 1
    fi

    while [[ -z "$REPLY" ]]; do
        printf >&2 '  %b[?]%b %s %b(required)%b: ' "$CYAN" "$RESET" "$prompt" "$DIM" "$RESET"
        read -r REPLY </dev/tty || true
        # Trim leading and trailing whitespace
        REPLY=$(printf '%s' "$REPLY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        if [[ -z "$REPLY" ]]; then
            print_warning "This field is required."
        fi
    done
}

# Yes/no confirmation. Returns 0 for yes, 1 for no.
# Usage: if confirm "Continue?" "y"; then ...
confirm() {
    local prompt="$1"
    local default="${2:-y}"  # "y" or "n"

    local hint
    if [[ "$default" == "y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    printf >&2 '  %b[?]%b %s %b[%s]%b: ' "$CYAN" "$RESET" "$prompt" "$DIM" "$hint" "$RESET"
    
    if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
        REPLY="$default"
    else
        read -r REPLY </dev/tty || true
    fi

    # Empty reply → use default
    if [[ -z "$REPLY" ]]; then
        REPLY="$default"
    fi

    # Normalize to lowercase (bash 3.2 compatible)
    REPLY=$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')

    case "$REPLY" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# Choose from a list of options. Result in $REPLY (the chosen value).
# Usage: ask_choice "What to do" "skip" "overwrite" "rename"
ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local valid=0

    printf >&2 '  %b[?]%b %s:\n' "$CYAN" "$RESET" "$prompt"

    local i
    for (( i=0; i<count; i++ )); do
        printf >&2 '    %b%d)%b %s\n' "$CYAN" "$((i + 1))" "$RESET" "${options[$i]}"
    done

    if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
        print_error "Interactive prompt failed in CI/non-TTY environment: $prompt"
        exit 1
    fi

    while [[ "$valid" -eq 0 ]]; do
        printf >&2 '  Choice %b(1-%d)%b: ' "$DIM" "$count" "$RESET"
        read -r REPLY </dev/tty || true

        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -ge 1 ]] && [[ "$REPLY" -le "$count" ]]; then
            REPLY="${options[$((REPLY - 1))]}"
            valid=1
        else
            print_warning "Please enter a number between 1 and $count."
        fi
    done
}
