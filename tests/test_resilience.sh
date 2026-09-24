#!/usr/bin/env bash
# tests/test_resilience.sh — Resilience tests against external corruption
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

test_survives_malformed_gitconfig() {
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs || return 1
    GITSETU_DRY_RUN=0

    PROFILE_COUNT=1
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Test")
    PROFILE_EMAILS=("global@test.com")
    PROFILE_DIRS=("")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_SIGNS=("0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global")
    PROFILE_USERS=("")
    PROFILE_PATS=("")

    # Create a corrupted gitconfig
    cat > "$HOME/.gitconfig" <<'EOF'
[alias]
    co = checkout
    st = status

# This section is missing a closing bracket
[core
    editor = vim

[user]
    name = Old
    email = old@test.com
EOF

    # A malformed external Git config is not safe to rewrite. The writer must
    # fail closed and leave the user's file untouched for manual repair.
    local status=0
    write_global_gitconfig >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "malformed gitconfig must be rejected" || return 1
    assert_file_exists "$HOME/.gitconfig" "gitconfig preserved" || return 1
    assert_file_contains "$HOME/.gitconfig" "co = checkout" "preserves valid data" || return 1
    assert_file_contains "$HOME/.gitconfig" "[core" "preserves malformed data" || return 1
    assert_file_not_contains "$HOME/.gitconfig" "useConfigOnly = true" "does not append state to malformed config" || return 1
}

test_survives_mismatched_managed_markers() {
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs || return 1
    GITSETU_DRY_RUN=0

    PROFILE_COUNT=1
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Test")
    PROFILE_EMAILS=("global@test.com")
    PROFILE_DIRS=("")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_SIGNS=("0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global")
    PROFILE_USERS=("")
    PROFILE_PATS=("")

    # Create a gitconfig with a start marker but no end marker
    cat > "$HOME/.gitconfig" <<EOF
[alias]
    st = status
${GITSETU_MANAGED_START}
[user]
    name = Bad Block
EOF

    local status=0
    write_global_gitconfig >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "mismatched managed markers must be rejected" || return 1
    assert_file_contains "$HOME/.gitconfig" "st = status" "preserves user block" || return 1
    assert_file_contains "$HOME/.gitconfig" "Bad Block" "safely preserves unclosed block to prevent data loss" || return 1
    assert_file_not_contains "$HOME/.gitconfig" "useConfigOnly = true" "does not guess past malformed markers" || return 1
}

printf '\n%btest_resilience.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "survives malformed syntax in ~/.gitconfig" test_survives_malformed_gitconfig
run_test "survives missing managed end marker" test_survives_mismatched_managed_markers
print_results "Resilience tests"
