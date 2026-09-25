#!/usr/bin/env bash
# tests/test_completion.sh — Tests for completion.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home
source_gitsetu_libs

# Mock the bash complete function while retaining inspectable bindings.
complete() {
    return 0
}

COMPLETION_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/completion.sh"

write_completion_registry() {
    local global_key work_key work_dir
    global_key=$(normalize_path "$HOME/.ssh/id_ed25519_global")
    work_key=$(normalize_path "$HOME/.ssh/id_ed25519_work")
    work_dir=$(normalize_path "$HOME/work")
    PROFILE_COUNT=2
    PROFILE_LABELS=(global work)
    PROFILE_NAMES=("Global User" "Work User")
    PROFILE_EMAILS=(global@example.com work@example.com)
    PROFILE_DIRS=("" "$work_dir")
    PROFILE_PROVIDERS=(github.com github.com)
    PROFILE_SIGNS=(0 0)
    PROFILE_KEYS=("$global_key" "$work_key")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
    mkdir -p "$GITSETU_PROFILES_DIR"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$global_key" ""
        test_v2_registry_line work "$work_dir" "github.com" "0" "$work_key" ""
    } > "$GITSETU_PROFILES_CONF"
}

test_completion_sources_idempotently() {
    # shellcheck disable=SC1090
    source "$COMPLETION_SCRIPT"
    local marker="sentinel"
    _gitsetu_test_marker="$marker"
    # shellcheck disable=SC1090
    source "$COMPLETION_SCRIPT"
    assert_equals "sentinel" "${_gitsetu_test_marker:-}" "repeated sourcing preserves shell state" || return 1
    declare -F _gitsetu >/dev/null
}

test_completion_top_level_commands() {
    # shellcheck disable=SC1090
    source "$COMPLETION_SCRIPT"
    COMP_WORDS=(gitsetu "")
    COMP_CWORD=1
    _gitsetu
    local reply="${COMPREPLY[*]}"
    assert_contains "$reply" "init" "supported setup alias is completed" || return 1
    assert_contains "$reply" "profile" "profile command is completed" || return 1
    assert_contains "$reply" "doctor" "doctor command is completed" || return 1
}

test_completion_profile_actions_and_labels() {
    write_completion_registry
    # shellcheck disable=SC1090
    source "$COMPLETION_SCRIPT"

    COMP_WORDS=(gitsetu profile "")
    COMP_CWORD=2
    _gitsetu
    local actions="${COMPREPLY[*]}"
    assert_contains "$actions" "add" "profile add action is completed" || return 1
    assert_contains "$actions" "edit" "profile edit action is completed" || return 1
    assert_contains "$actions" "remove" "profile remove action is completed" || return 1
    assert_not_contains "$actions" "work" "profile actions are not mixed with labels" || return 1

    COMP_WORDS=(gitsetu profile remove "")
    COMP_CWORD=3
    _gitsetu
    local label_words="${COMPREPLY[*]}"
    assert_contains "$label_words" "work" "profile remove completes v2 labels" || return 1
    assert_not_contains "$label_words" "--force" "profile remove does not advertise unsupported force" || return 1
}

test_completion_legacy_registry_not_offered() {
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    printf 'work:work@example.com:%s:github.com:0::\n' "$HOME/work" > "$GITSETU_PROFILES_CONF"
    # shellcheck disable=SC1090
    source "$COMPLETION_SCRIPT"
    COMP_WORDS=(gitsetu run "")
    COMP_CWORD=2
    _gitsetu
    assert_not_contains "${COMPREPLY[*]}" "work" "legacy labels are never offered" || return 1
}

printf '\n%btest_completion.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "completion sources repeatedly without resetting shell state" test_completion_sources_idempotently
run_test "completion offers supported top-level commands" test_completion_top_level_commands
run_test "profile completion separates actions and v2 labels" test_completion_profile_actions_and_labels
run_test "completion rejects legacy registry labels" test_completion_legacy_registry_not_offered
print_results "Completion tests"
