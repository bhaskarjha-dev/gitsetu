#!/usr/bin/env bash
# shellcheck disable=SC2034  # Test state vars are consumed by sourced library functions
# tests/test_teardown.sh — Tests for lib/teardown.sh
set -euo pipefail

# Find the test directory and gitsetu root
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITSETU_ROOT="$(dirname "$TEST_DIR")"

# Source test helpers
source "$TEST_DIR/helpers.sh"

# Source gitsetu modules needed for testing
source "$GITSETU_ROOT/lib/core.sh"
source "$GITSETU_ROOT/lib/platform.sh"
source "$GITSETU_ROOT/lib/ui.sh"
source "$GITSETU_ROOT/lib/backup.sh"
source "$GITSETU_ROOT/lib/ssh.sh"
source "$GITSETU_ROOT/lib/gitconfig.sh"
source "$GITSETU_ROOT/lib/guard.sh"
source "$GITSETU_ROOT/lib/teardown.sh"

detect_os

# ------------------------------------------------------------------------------
# Test Setup
# ------------------------------------------------------------------------------

setup() {
    setup_test_home
    
    # Pre-populate state to simulate a successful setup
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Global Name" "Pro Name")
    PROFILE_EMAILS=("global@example.com" "pro@example.com")
    PROFILE_DIRS=("" "$HOME/pro")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
    PROFILE_COUNT=2

    # Ensure profile paths
    mkdir -p "$HOME/pro"

    # Simulate user having existing gitconfig
    printf '[alias]\n    st = status\n' > "$HOME/.gitconfig"
    
    # Simulate user having existing ssh config
    mkdir -p "$HOME/.ssh"
    printf 'Host my-server\n    HostName 10.0.0.1\n' > "$HOME/.ssh/config"

    # Run the setup logic
    ensure_dirs
    write_global_gitconfig >/dev/null 2>&1
    write_profile_gitconfig "pro" "Pro Name" "pro@example.com" >/dev/null 2>&1
    write_ssh_config >/dev/null 2>&1
    write_profiles_conf >/dev/null 2>&1
    
    # Create fake keys to test key retention
    touch "$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_global.pub"
    touch "$HOME/.ssh/id_ed25519_pro" "$HOME/.ssh/id_ed25519_pro.pub"
    
    # Install guard hook
    install_guard >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------

test_teardown_removes_gitconfig_block() {
    setup
    
    assert_file_contains "$HOME/.gitconfig" "[gitsetu:managed:start]"
    
    teardown_gitconfig >/dev/null 2>&1
    
    assert_file_not_contains "$HOME/.gitconfig" "[gitsetu:managed:start]"
    assert_file_contains "$HOME/.gitconfig" "st = status"
}

test_teardown_removes_sshconfig_blocks() {
    setup
    
    assert_file_contains "$HOME/.ssh/config" "Include $GITSETU_PROFILES_DIR/ssh_config"
    
    teardown_sshconfig >/dev/null 2>&1
    
    assert_file_not_contains "$HOME/.ssh/config" "Include $GITSETU_PROFILES_DIR/ssh_config"
    assert_file_contains "$HOME/.ssh/config" "Host my-server"
}

test_teardown_removes_config_dir() {
    setup
    
    assert_dir_exists "$GITSETU_CONFIG_DIR"
    
    teardown_config_dir >/dev/null 2>&1
    
    # assert_dir_not_exists doesn't exist in helpers, so manually check and return 1 if dir still exists
    if [[ -d "$GITSETU_CONFIG_DIR" ]]; then
        printf '    FAIL: Config dir should be removed\n'
        return 1
    fi
}

test_teardown_uninstalls_guard() {
    setup
    
    assert_file_exists "$GITSETU_HOOKS_DIR/pre-commit"
    
    uninstall_guard >/dev/null 2>&1
    
    if [[ -f "$GITSETU_HOOKS_DIR/pre-commit" ]]; then
        printf '    FAIL: Guard hook should be removed\n'
        return 1
    fi
    
    local hooks_path
    hooks_path=$(git config --global core.hooksPath 2>/dev/null || echo "")
    assert_equals "" "$hooks_path" "core.hooksPath should be unset"
}

test_teardown_keeps_ssh_keys() {
    setup
    
    assert_file_exists "$HOME/.ssh/id_ed25519_global"
    
    teardown_all >/dev/null 2>&1
    
    assert_file_exists "$HOME/.ssh/id_ed25519_global"
    assert_file_exists "$HOME/.ssh/id_ed25519_pro"
}

test_teardown_deep_strips_local_configs() {
    setup
    
    # 1. Create a mapped dummy repo (should be stripped)
    local mapped_repo="$HOME/pro/mapped-repo"
    mkdir -p "$mapped_repo"
    git init "$mapped_repo" >/dev/null 2>&1
    git config -f "$mapped_repo/.git/config" user.name "Pro Name"
    git config -f "$mapped_repo/.git/config" user.email "pro@example.com"
    
    # 2. Create another repo in the mapped dir, but with CUSTOM identity (should NOT be stripped)
    local unmapped_repo="$HOME/pro/custom-repo"
    mkdir -p "$unmapped_repo"
    git init "$unmapped_repo" >/dev/null 2>&1
    git config -f "$unmapped_repo/.git/config" user.name "Custom Name"
    git config -f "$unmapped_repo/.git/config" user.email "custom@example.com"
    
    # Run deep teardown
    teardown_all "1" >/dev/null 2>&1
    
    # Assert mapped repo was stripped
    local mapped_email
    mapped_email=$(git config -f "$mapped_repo/.git/config" user.email 2>/dev/null || echo "")
    assert_equals "" "$mapped_email" "Mapped repo should have email stripped"
    
    # Assert unmapped repo is untouched
    local unmapped_email
    unmapped_email=$(git config -f "$unmapped_repo/.git/config" user.email 2>/dev/null || echo "")
    assert_equals "custom@example.com" "$unmapped_email" "Custom repo identity should remain untouched"
}

test_teardown_dos_prevention() {
    # Test that teardown_deep refuses to traverse / or $HOME
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    echo "dos::$HOME:github.com:0:" > "$GITSETU_PROFILES_CONF"
    
    local output
    output=$(teardown_deep 2>&1 || true)
    
    assert_contains "$output" "Skipping deep cleanup for '$HOME' to prevent Denial of Service traversal" "blocks $HOME traversal" || return 1
}

# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

run_test "teardown_gitconfig removes managed block but keeps user content" test_teardown_removes_gitconfig_block
run_test "teardown_sshconfig removes managed blocks but keeps user content" test_teardown_removes_sshconfig_blocks
run_test "teardown_config_dir completely removes ~/.config/gitsetu" test_teardown_removes_config_dir
run_test "uninstall_guard removes hook and unsets core.hooksPath" test_teardown_uninstalls_guard
run_test "teardown_all leaves generated SSH keys intact for safety" test_teardown_keeps_ssh_keys
run_test "teardown_deep selectively strips matched local repo identities" test_teardown_deep_strips_local_configs
run_test "teardown_deep prevents root/home filesystem DoS" test_teardown_dos_prevention

print_results "Teardown tests"
