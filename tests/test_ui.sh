#!/usr/bin/env bash
# shellcheck disable=SC2329  # Prompt/Terminal helpers are replaced in subshell probes.
# tests/test_ui.sh — Prompt state, terminal restoration, and display escaping
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home
source_gitsetu_libs

test_escape_terminal_text_is_inert() {
    local value
    value=$(escape_terminal_text $'safe\033[31mred\177')
    assert_equals 'safe\e[31mred\177' "$value" "control bytes become visible text" || return 1
    [[ "$value" != *$'\033'* ]] || return 1
}

test_print_functions_escape_control_bytes() {
    local output
    output=$(print_error $'bad\033]0;title\007input' 2>&1)
    assert_contains "$output" '\e]0;title\ainput' "print_error neutralizes terminal controls" || return 1
    [[ "$output" != *$'\033'* ]] || return 1
}

test_noninteractive_prompts_clear_stale_reply() {
    REPLY="stale"
    CI=1
    ask "Name" "default-name"
    assert_equals "default-name" "$REPLY" "noninteractive ask clears stale REPLY and uses default" || return 1

    REPLY="stale"
    local status=0 refusal=""
    # Capture the refusal instead of letting it reach the log: ask_required
    # correctly reports a non-TTY refusal on stderr, and an unprompted error
    # line in a CI log reads like a real failure. Redirect rather than use $( )
    # because ask_required assigns REPLY, which must survive in this shell.
    refusal=$(umask 077 && mktemp "${TMPDIR:-/tmp}/gitsetu-ui-refusal.XXXXXX") || return 1
    ask_required "Email" 2>"$refusal" || status=$?
    assert_equals "1" "$status" "required prompt fails in noninteractive mode" || {
        rm -f "$refusal"
        return 1
    }
    assert_equals "" "$REPLY" "failed required prompt leaves no stale REPLY" || {
        rm -f "$refusal"
        return 1
    }
    assert_file_contains "$refusal" "CI/non-TTY" \
        "refused prompt explains the noninteractive cause" || {
        rm -f "$refusal"
        return 1
    }
    rm -f "$refusal"
}

test_choice_prompt_eof_returns_without_spinning() {
    local output status=0
    output=$(
        _ui_tty_available() { return 0; }
        _ui_read_reply() { return 1; }
        ask_choice "Choose" "one" "two" 2>&1
    ) || status=$?
    assert_equals "1" "$status" "choice prompt returns failure on EOF" || return 1
    assert_contains "$output" "Input cancelled" "choice prompt reports cancellation" || return 1
}

test_password_preserves_whitespace_and_restores_termios() {
    unset CI
    local output
    output=$(
        _ui_tty_available() { return 0; }
        _ui_stty_save() {
            printf '%s\n' 'mock-termios-state'
        }
        _ui_stty_disable_echo() { return 0; }
        _ui_stty_restore() { return 0; }
        _ui_read_reply() {
            REPLY='  secret with spaces  '
            return 0
        }
        ask_password "Password" 2>/dev/null
        printf 'VALUE=<%s>\n' "$REPLY"
    )
    assert_contains "$output" "VALUE=<  secret with spaces  >" "password whitespace is preserved" || return 1
    assert_equals "0" "$GITSETU_TTY_STATE_ACTIVE" "terminal state is marked restored" || return 1
}

test_confirmation_defaults_are_explicit() {
    CI=1
    REPLY="stale"
    local yes_status=0 no_status=0
    confirm "Continue?" "y" || yes_status=$?
    assert_equals "0" "$yes_status" "confirmation uses explicit yes default" || return 1
    assert_equals "yes" "$REPLY" "confirmation normalizes its result" || return 1

    confirm "Continue?" "n" || no_status=$?
    assert_equals "1" "$no_status" "confirmation uses explicit no default" || return 1
    assert_equals "no" "$REPLY" "negative confirmation remains negative" || return 1
}

printf '\n%btest_ui.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "terminal controls are escaped to inert text" test_escape_terminal_text_is_inert
run_test "UI output functions sanitize hostile messages" test_print_functions_escape_control_bytes
run_test "noninteractive prompts clear stale REPLY" test_noninteractive_prompts_clear_stale_reply
run_test "choice prompt handles EOF without spinning" test_choice_prompt_eof_returns_without_spinning
run_test "password entry preserves whitespace and restores termios" test_password_preserves_whitespace_and_restores_termios
run_test "confirmation defaults are deterministic" test_confirmation_defaults_are_explicit
print_results "UI tests"
