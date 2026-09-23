#!/usr/bin/env bash
# tests/test_completion.sh — Tests for completion.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

# Mock the bash complete function
complete() {
    true
}
export -f complete

test_completion_sources() {
    local script
    script="$(dirname "${BASH_SOURCE[0]}")/../lib/completion.sh"
    # Sourcing it should not fail
    # shellcheck disable=SC1090
    source "$script"
    # Function _gitsetu should be defined
    if ! declare -F _gitsetu >/dev/null; then
        echo "_gitsetu function not found after sourcing"
        return 1
    fi
    return 0
}

test_completion_doctor_repair() {
    local script
    script="$(dirname "${BASH_SOURCE[0]}")/../lib/completion.sh"
    # shellcheck disable=SC1090
    source "$script"

    COMP_WORDS=("gitsetu" "doctor" "")
    COMP_CWORD=2
    _gitsetu
    local reply_str="${COMPREPLY[*]}"
    assert_contains "$reply_str" "--repair" "doctor completions include --repair" || return 1
    assert_contains "$reply_str" "--dry-run" "doctor completions include --dry-run" || return 1
}

printf '\n%btest_completion.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "completion script sources cleanly" test_completion_sources
run_test "completion includes doctor --repair and --dry-run" test_completion_doctor_repair
print_results "Completion tests"

