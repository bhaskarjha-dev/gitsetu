#!/usr/bin/env bash
# lib/ui.sh — Terminal formatting, colors, symbols, and interactive prompts
#
# Human-facing output is written to stderr so stdout remains safe for the
# credential helper and prompt command. Prompts read the controlling terminal
# and fail cleanly when no readable terminal is available.
# Bash 3.2 compatible: no ${var,,}, mapfile, or associative arrays.

# ------------------------------------------------------------------------------
# Color and terminal-state setup
# ------------------------------------------------------------------------------

GITSETU_SAVED_TTY_STATE=""
GITSETU_TTY_STATE_ACTIVE=0
GITSETU_CURSOR_HIDDEN=0

setup_colors() {
    if [[ -z "${NO_COLOR:-}" && -z "${GITSETU_NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t 2 ]]; then
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

setup_colors

# ------------------------------------------------------------------------------
# Unicode symbols
# ------------------------------------------------------------------------------

SYM_CHECK="✓"
SYM_CROSS="✗"
SYM_WARN="⚠"
SYM_INFO="i"
SYM_ARROW="→"
SYM_BULLET="•"

# ------------------------------------------------------------------------------
# Display safety
# ------------------------------------------------------------------------------

# Convert terminal-control bytes to inert, visible text. Git values, registry
# labels, paths, and key comments are untrusted display data.
escape_terminal_text() {
    local input="${1:-}"
    local output=""
    local char
    local i

    for (( i=0; i<${#input}; i++ )); do
        char="${input:i:1}"
        case "$char" in
            $'\a') output="${output}\\a" ;;
            $'\b') output="${output}\\b" ;;
            $'\t') output="${output}\\t" ;;
            $'\n') output="${output}\\n" ;;
            $'\v') output="${output}\\v" ;;
            $'\f') output="${output}\\f" ;;
            $'\r') output="${output}\\r" ;;
            $'\033') output="${output}\\e" ;;
            $'\177') output="${output}\\177" ;;
            *)
                if [[ "$char" == [[:cntrl:]] ]]; then
                    output="${output}?"
                else
                    output="${output}${char}"
                fi
                ;;
        esac
    done

    printf '%s' "$output"
}

# Descriptive internal alias used by display-oriented callers.
sanitize_display() {
    escape_terminal_text "${1:-}"
}

# ------------------------------------------------------------------------------
# Output functions
# ------------------------------------------------------------------------------

print_header() {
    local version
    version=$(escape_terminal_text "${GITSETU_VERSION:-unknown}")
    printf >&2 '\n'
    printf >&2 '  %b╔══════════════════════════════════════╗%b\n' "$BOLD" "$RESET"
    printf >&2 '  %b║%b  %bgitsetu%b v%s%b                       ║%b\n' \
        "$BOLD" "$RESET" "$CYAN$BOLD" "$RESET" "$version" "$BOLD" "$RESET"
    printf >&2 '  %b║  One command. All identities.       ║%b\n' "$BOLD" "$RESET"
    printf >&2 '  %b╚══════════════════════════════════════╝%b\n' "$BOLD" "$RESET"
    printf >&2 '\n'
}

print_section() {
    local title
    title=$(escape_terminal_text "${1:-}")
    printf >&2 '\n  %b─── %s ───%b\n\n' "$BOLD" "$title" "$RESET"
}

print_step() {
    local message
    message=$(escape_terminal_text "${1:-}")
    printf >&2 '  %b%s%b %s\n' "$CYAN" "$SYM_ARROW" "$RESET" "$message"
}

print_success() {
    local message
    message=$(escape_terminal_text "${1:-}")
    printf >&2 '  %b%s%b %s\n' "$GREEN" "$SYM_CHECK" "$RESET" "$message"
}

print_warning() {
    local message
    message=$(escape_terminal_text "${1:-}")
    printf >&2 '  %b%s%b %s\n' "$YELLOW" "$SYM_WARN" "$RESET" "$message"
}

print_error() {
    local message
    message=$(escape_terminal_text "${1:-}")
    printf >&2 '  %b%s%b %s\n' "$RED" "$SYM_CROSS" "$RESET" "$message"
}

print_info() {
    local message
    message=$(escape_terminal_text "${1:-}")
    printf >&2 '  %b%s%b %s\n' "$BLUE" "$SYM_INFO" "$RESET" "$message"
}

print_key_box() {
    local label="${1:-}"
    local email="${2:-}"
    local pubkey_path="${3:-}"
    local safe_label safe_email key_content

    if [[ ! -f "$pubkey_path" ]]; then
        print_error "Key file not found: $pubkey_path"
        return 1
    fi

    key_content=$(cat "$pubkey_path" 2>/dev/null || true)
    safe_label=$(escape_terminal_text "$label")
    safe_email=$(escape_terminal_text "$email")
    key_content=$(escape_terminal_text "$key_content")

    printf >&2 '\n'
    printf >&2 '  %b┌─ %s (%s) ─────────────────────┐%b\n' \
        "$BOLD" "$safe_label" "$safe_email" "$RESET"
    printf >&2 '  %b│%b %s\n' "$DIM" "$RESET" "$key_content"
    printf >&2 '  %b└──────────────────────────────────────────┘%b\n' "$DIM" "$RESET"

    if copy_to_clipboard "$key_content"; then
        printf >&2 '  %b%s%b %bCOPIED TO CLIPBOARD!%b Add it here: %bhttps://github.com/settings/ssh/new%b\n' \
            "$GREEN" "$SYM_CHECK" "$RESET" "$BOLD" "$RESET" "$CYAN" "$RESET"
    else
        printf >&2 '  %b%s%b Copy and add at: %bhttps://github.com/settings/ssh/new%b\n' \
            "$BLUE" "$SYM_INFO" "$RESET" "$BOLD" "$RESET"
    fi
    printf >&2 '\n'
}

# ------------------------------------------------------------------------------
# Cursor and termios helpers
# ------------------------------------------------------------------------------

ui_hide_cursor() {
    if [[ "$GITSETU_CURSOR_HIDDEN" -eq 0 ]]; then
        printf '\033[?25l' >&2 2>/dev/null || true
        GITSETU_CURSOR_HIDDEN=1
    fi
}

ui_show_cursor() {
    if [[ "$GITSETU_CURSOR_HIDDEN" -eq 1 ]]; then
        printf '\033[?25h' >&2 2>/dev/null || true
        GITSETU_CURSOR_HIDDEN=0
    fi
}

_ui_stty_save() {
    stty -g </dev/tty 2>/dev/null
}

_ui_stty_disable_echo() {
    stty -echo </dev/tty 2>/dev/null
}

_ui_stty_restore() {
    local state="${1:-}"
    [[ -n "$state" ]] || return 1
    stty "$state" </dev/tty 2>/dev/null
}

ui_restore_terminal() {
    if [[ "$GITSETU_TTY_STATE_ACTIVE" -eq 1 && -n "$GITSETU_SAVED_TTY_STATE" ]]; then
        _ui_stty_restore "$GITSETU_SAVED_TTY_STATE" || true
    fi
    GITSETU_TTY_STATE_ACTIVE=0
    GITSETU_SAVED_TTY_STATE=""
    ui_show_cursor
}

# Return success only when a controlling terminal can be opened for both reading
# and termios operations. This intentionally does not trust redirected stdin.
_ui_tty_available() {
    [[ -r /dev/tty && -w /dev/tty ]] || return 1
    ( : </dev/tty ) 2>/dev/null || return 1
}

_ui_clear_reply() {
    REPLY=""
}

_ui_trim_reply() {
    while [[ "$REPLY" == [[:space:]]* ]]; do
        REPLY="${REPLY:1}"
    done
    while [[ "$REPLY" == *[[:space:]] ]]; do
        REPLY="${REPLY:0:${#REPLY}-1}"
    done
}

_ui_read_reply() {
    _ui_clear_reply
    IFS= read -r REPLY </dev/tty
}

# ------------------------------------------------------------------------------
# Prompt functions
# ------------------------------------------------------------------------------

# Ask with an optional default. Result is returned in REPLY.
ask() {
    local prompt="${1:-}"
    local default="${2:-}"
    local safe_prompt safe_default

    _ui_clear_reply
    safe_prompt=$(escape_terminal_text "$prompt")
    safe_default=$(escape_terminal_text "$default")

    if [[ -n "${CI:-}" ]] || ! _ui_tty_available; then
        REPLY="$default"
        return 0
    fi

    if [[ -n "$default" ]]; then
        printf >&2 '  %b[?]%b %s %b[%s]%b: ' \
            "$CYAN" "$RESET" "$safe_prompt" "$DIM" "$safe_default" "$RESET"
    else
        printf >&2 '  %b[?]%b %s: ' "$CYAN" "$RESET" "$safe_prompt"
    fi

    if ! _ui_read_reply; then
        _ui_clear_reply
        print_error "Input cancelled: unable to read from the controlling terminal."
        return 1
    fi

    _ui_trim_reply
    if [[ -z "$REPLY" && -n "$default" ]]; then
        REPLY="$default"
    fi
    return 0
}

# Ask for a secret without echoing it. Password whitespace is preserved.
ask_password() {
    local prompt="${1:-}"
    local safe_prompt
    local saved_state=""

    _ui_clear_reply
    if [[ -n "${CI:-}" ]] || ! _ui_tty_available; then
        print_error "A controlling terminal is required to enter a secret."
        return 1
    fi

    safe_prompt=$(escape_terminal_text "$prompt")
    printf >&2 '  %b[?]%b %s: ' "$CYAN" "$RESET" "$safe_prompt"

    if ! saved_state=$(_ui_stty_save); then
        print_error "Unable to read terminal state; secret entry was cancelled."
        return 1
    fi
    if ! _ui_stty_disable_echo; then
        print_error "Unable to disable terminal echo; secret entry was cancelled."
        return 1
    fi

    GITSETU_SAVED_TTY_STATE="$saved_state"
    GITSETU_TTY_STATE_ACTIVE=1

    local read_status=0
    _ui_read_reply || read_status=$?
    ui_restore_terminal
    printf >&2 '\n'

    if [[ "$read_status" -ne 0 ]]; then
        _ui_clear_reply
        print_error "Secret entry was cancelled because the terminal read failed."
        return 1
    fi
    return 0
}

# Ask until a non-empty response is entered. Result is returned in REPLY.
ask_required() {
    local prompt="${1:-}"
    local safe_prompt

    _ui_clear_reply
    if [[ -n "${CI:-}" ]] || ! _ui_tty_available; then
        print_error "Interactive prompt failed in CI/non-TTY environment: $prompt"
        return 1
    fi

    safe_prompt=$(escape_terminal_text "$prompt")
    while [[ -z "$REPLY" ]]; do
        _ui_clear_reply
        printf >&2 '  %b[?]%b %s %b(required)%b: ' \
            "$CYAN" "$RESET" "$safe_prompt" "$DIM" "$RESET"
        if ! _ui_read_reply; then
            _ui_clear_reply
            print_error "Input cancelled: unable to read from the controlling terminal."
            return 1
        fi
        _ui_trim_reply
        if [[ -z "$REPLY" ]]; then
            print_warning "This field is required."
        fi
    done
    return 0
}

# Yes/no confirmation. Returns 0 for yes, 1 for no, and 2 for invalid config.
confirm() {
    local prompt="${1:-}"
    local default="${2:-y}"
    local safe_prompt hint normalized

    _ui_clear_reply
    case "$default" in
        y|Y) default="y"; hint="Y/n" ;;
        n|N) default="n"; hint="y/N" ;;
        *)
            print_error "Invalid confirmation default: $default"
            return 2
            ;;
    esac

    safe_prompt=$(escape_terminal_text "$prompt")
    printf >&2 '  %b[?]%b %s %b[%s]%b: ' \
        "$CYAN" "$RESET" "$safe_prompt" "$DIM" "$hint" "$RESET"

    if [[ -n "${CI:-}" ]] || ! _ui_tty_available; then
        REPLY="$default"
    elif ! _ui_read_reply; then
        _ui_clear_reply
        print_error "Input cancelled: unable to read from the controlling terminal."
        return 1
    else
        _ui_trim_reply
        [[ -z "$REPLY" ]] && REPLY="$default"
    fi

    normalized="$REPLY"
    case "$normalized" in
        A|a) normalized="a" ;;
        B|b) normalized="b" ;;
        C|c) normalized="c" ;;
        D|d) normalized="d" ;;
        E|e) normalized="e" ;;
        F|f) normalized="f" ;;
        G|g) normalized="g" ;;
        H|h) normalized="h" ;;
        I|i) normalized="i" ;;
        J|j) normalized="j" ;;
        K|k) normalized="k" ;;
        L|l) normalized="l" ;;
        M|m) normalized="m" ;;
        N|n) normalized="n" ;;
        O|o) normalized="o" ;;
        P|p) normalized="p" ;;
        Q|q) normalized="q" ;;
        R|r) normalized="r" ;;
        S|s) normalized="s" ;;
        T|t) normalized="t" ;;
        U|u) normalized="u" ;;
        V|v) normalized="v" ;;
        W|w) normalized="w" ;;
        X|x) normalized="x" ;;
        Y|y) normalized="y" ;;
        Z|z) normalized="z" ;;
    esac

    case "$normalized" in
        y|yes) REPLY="yes"; return 0 ;;
        *) REPLY="no"; return 1 ;;
    esac
}

# Choose from a numbered list. Result is returned in REPLY.
ask_choice() {
    local prompt="${1:-}"
    shift || true
    local options=("$@")
    local count=${#options[@]}
    local safe_prompt option
    local i

    _ui_clear_reply
    if [[ "$count" -lt 1 ]]; then
        print_error "Cannot ask for a choice without options."
        return 1
    fi
    if [[ -n "${CI:-}" ]] || ! _ui_tty_available; then
        print_error "Interactive prompt failed in CI/non-TTY environment: $prompt"
        return 1
    fi

    safe_prompt=$(escape_terminal_text "$prompt")
    printf >&2 '  %b[?]%b %s:\n' "$CYAN" "$RESET" "$safe_prompt"
    for (( i=0; i<count; i++ )); do
        option=$(escape_terminal_text "${options[$i]}")
        printf >&2 '    %b%d)%b %s\n' "$CYAN" "$((i + 1))" "$RESET" "$option"
    done

    while true; do
        _ui_clear_reply
        printf >&2 '  Choice %b(1-%d)%b: ' "$DIM" "$count" "$RESET"
        if ! _ui_read_reply; then
            _ui_clear_reply
            print_error "Input cancelled: unable to read from the controlling terminal."
            return 1
        fi
        _ui_trim_reply

        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -ge 1 ]] && [[ "$REPLY" -le "$count" ]]; then
            REPLY="${options[$((REPLY - 1))]}"
            return 0
        fi
        print_warning "Please enter a number between 1 and $count."
    done
}
