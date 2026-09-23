#!/usr/bin/env bash
# tests/test_cli.sh — CLI argument parsing tests for gitsetu entrypoint
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

# We need the absolute path to the executable (tests may cd elsewhere)
GITSETU_EXE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

test_cli_no_args_shows_help() {
    local output
    output=$(bash "$GITSETU_EXE" 2>&1 || true)
    assert_contains "$output" "One command. All identities. Every machine." "shows brief usage tagline" || return 1
    assert_contains "$output" "Usage: gitsetu setup" "no args prints usage" || return 1
    assert_contains "$output" "gitsetu v1.1.0" "shows version string in brief usage" || return 1
}

test_cli_invalid_command() {
    local output
    output=$(bash "$GITSETU_EXE" fakecmd 2>&1 || true)
    assert_contains "$output" "Unknown command" "catches invalid command" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" fakecmd || return 1
}

test_cli_add_missing_args() {
    local output
    output=$(bash "$GITSETU_EXE" add 2>&1 || true)
    assert_contains "$output" "Usage: gitsetu add" "catches missing args" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" add || return 1
}

test_cli_add_invalid_label() {
    local output
    output=$(bash "$GITSETU_EXE" add "bad label" "Name" "email@test.com" "$HOME/dir" 2>&1 || true)
    assert_contains "$output" "Invalid profile label" "catches invalid label format" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" add "bad label" "Name" "email@test.com" "$HOME/dir" || return 1
}

test_cli_remove_invalid_arg() {
    local output
    output=$(bash "$GITSETU_EXE" remove 2>&1 || true)
    assert_contains "$output" "Usage: gitsetu remove" "catches missing arg for remove" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" remove || return 1
}

test_cli_help_flag() {
    local output
    output=$(bash "$GITSETU_EXE" --help 2>&1 || true)
    assert_contains "$output" "USAGE" "prints help" || return 1
    assert_exit_code 0 bash "$GITSETU_EXE" --help || return 1
}

test_cli_array_loop_crash_prevention() {
    # Test that list doesn't crash when profiles.conf is completely empty (0 profiles)
    mkdir -p "$HOME/.config/gitsetu"
    touch "$HOME/.config/gitsetu/profiles.conf"
    local output
    output=$(bash "$GITSETU_EXE" list 2>&1 || true)
    assert_not_contains "$output" "bad array subscript" "survives 0 profile state without array subscript crash" || return 1
}

test_cli_7field_profile_parsing() {
    # Regression test: profiles.conf has 7 fields (provider_user is the 7th).
    # Before the fix, 6-field IFS readers merged provider_user into key_path,
    # corrupting SSH paths when HTTPS credentials were configured.
    mkdir -p "$HOME/.config/gitsetu" "$HOME/.ssh" "$HOME/work/repo"
    touch "$HOME/.ssh/id_ed25519_work"
    cat > "$HOME/.config/gitsetu/profiles.conf" <<EOF
work:work@corp.com:$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:myghuser
EOF
    # cd at function scope so bash inherits the real working directory
    cd "$HOME/work/repo"
    local output
    output=$(bash "$GITSETU_EXE" prompt 2>/dev/null)
    assert_equals "work" "$output" "prompt returns clean label with 7-field profiles.conf" || return 1
}

printf '\n%btest_cli.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "no arguments shows help" test_cli_no_args_shows_help
run_test "invalid command caught" test_cli_invalid_command
run_test "add with missing args caught" test_cli_add_missing_args
run_test "add with invalid label caught" test_cli_add_invalid_label
run_test "remove with missing args caught" test_cli_remove_invalid_arg
run_test "--help prints menu and exits 0" test_cli_help_flag
run_test "empty registry array loop safety" test_cli_array_loop_crash_prevention
run_test "7-field profiles.conf parsing" test_cli_7field_profile_parsing
print_results "CLI tests"
