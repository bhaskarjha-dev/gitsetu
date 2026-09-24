#!/usr/bin/env bash
# tests/test_status.sh — GitSetu Status Command Suite
# Verifies cmd_status active identity detection, profile registry rendering,
# and explicit guard-policy diagnostics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

GITSETU_EXE="$REPO_DIR/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

# ------------------------------------------------------------------------------
# Test 1: cmd_status displays (not set) when no git identity configured
# ------------------------------------------------------------------------------
test_status_not_set() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.gitconfig"
    if git config --global --get user.name >/dev/null 2>&1; then
        git config --global --unset user.name || return 1
    fi
    if git config --global --get user.email >/dev/null 2>&1; then
        git config --global --unset user.email || return 1
    fi

    local output status=0
    output=$(bash "$GITSETU_EXE" status 2>&1) || status=$?
    assert_equals "0" "$status" "status command exits successfully" || return 1
    assert_contains "$output" "Active Identity" "displays active identity box" || return 1
    assert_contains "$output" "Name:  (not set)" "displays name not set" || return 1
    assert_contains "$output" "Email: (not set)" "displays email not set" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: cmd_status displays active identity when set in repo
# ------------------------------------------------------------------------------
test_status_repo_identity() {
    local repo_dir="$TEST_HOME/repos/my-repo"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name "Alice Dev"
    git -C "$repo_dir" config user.email "alice@company.com"

    local output status=0
    output=$(cd "$repo_dir" && bash "$GITSETU_EXE" status 2>&1) || status=$?
    assert_equals "0" "$status" "status command exits successfully in a repository" || return 1
    assert_contains "$output" "Alice Dev" "displays active repo name" || return 1
    assert_contains "$output" "alice@company.com" "displays active repo email" || return 1
    assert_contains "$output" "SSH:   (default)" "displays default SSH command in git repo" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: cmd_status warns on local core.hooksPath guard subversion
# ------------------------------------------------------------------------------
test_status_reports_local_hooks_override() {
    local repo_dir="$TEST_HOME/repos/subverted-repo"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name "Hacker"
    git -C "$repo_dir" config user.email "hacker@evil.dev"
    git -C "$repo_dir" config --local core.hooksPath ".local-hooks"

    local output status=0
    output=$(cd "$repo_dir" && bash "$GITSETU_EXE" status 2>&1) || status=$?
    assert_equals "0" "$status" "status command exits successfully with a hooks override" || return 1
    assert_contains "$output" "Local core.hooksPath override:" "reports the explicit local hooks override" || return 1
    assert_contains "$output" ".local-hooks" "shows the local hooks path" || return 1
    assert_contains "$output" "Unmanaged repository: fail-open" "reports the unmanaged repository policy" || return 1
    assert_contains "$output" "Local hook policy: this repository override can bypass the global guard." \
        "explains the local guard override" || return 1
    assert_not_contains "$output" "SECURITY WARNING" "does not restore the obsolete blocking banner" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: cmd_status displays configured profiles and active match checkmark
# ------------------------------------------------------------------------------
test_status_displays_profiles_and_active_check() {
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Alice Work" "alice@corp.com"
    test_v2_profile_config personal "Alice Personal" "alice@me.dev"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" ""
        test_v2_registry_line personal "$HOME/personal" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_personal" ""
    } > "$GITSETU_PROFILES_CONF"

    # Test inside work directory
    local work_repo="$TEST_HOME/work/repo1"
    mkdir -p "$work_repo"
    git -C "$work_repo" init -q
    git -C "$work_repo" config user.name "Alice Work"
    git -C "$work_repo" config user.email "alice@corp.com"

    local output status=0
    output=$(cd "$work_repo" && bash "$GITSETU_EXE" status 2>&1) || status=$?
    assert_equals "0" "$status" "status command exits successfully with configured profiles" || return 1
    assert_contains "$output" "Configured Profiles" "displays configured profiles header" || return 1
    assert_contains "$output" "global" "renders the global profile" || return 1
    assert_contains "$output" "global@example.com" "renders the global profile email" || return 1
    assert_contains "$output" "✓ work" "renders active checkmark next to matching work profile" || return 1
    assert_contains "$output" "personal" "renders personal profile" || return 1
    assert_contains "$output" "alice@corp.com" "renders work profile email" || return 1
    assert_contains "$output" "alice@me.dev" "renders personal profile email" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: cmd_status displays the configured global profile outside a repository
# ------------------------------------------------------------------------------
test_status_global_profile_display() {
    test_v2_profile_config global "Solo Dev" "solo@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
    } > "$GITSETU_PROFILES_CONF"

    local output status=0
    output=$(bash "$GITSETU_EXE" status 2>&1) || status=$?
    assert_equals "0" "$status" "status command exits successfully for a global profile" || return 1
    assert_contains "$output" "Configured Profiles" "displays configured profiles" || return 1
    assert_contains "$output" "global" "renders the global profile" || return 1
    assert_contains "$output" "solo@example.com" "renders the global profile email" || return 1
    assert_not_contains "$output" "[Manual Mode]" "does not use the obsolete manual-mode label" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_status.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "cmd_status displays (not set) for unconfigured identity" test_status_not_set
run_test "cmd_status displays active identity when set in repo" test_status_repo_identity
run_test "cmd_status reports local core.hooksPath override policy" test_status_reports_local_hooks_override
run_test "cmd_status displays profiles and active checkmark" test_status_displays_profiles_and_active_check
run_test "cmd_status displays configured global profile" test_status_global_profile_display
print_results "Status tests"
