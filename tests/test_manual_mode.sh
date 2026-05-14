#!/usr/bin/env bash
# tests/test_manual_mode.sh — Tests for directory-less profiles
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$TEST_DIR/helpers.sh"
source_gitsetu_libs
detect_os

setup() {
    setup_test_home
    
    PROFILE_LABELS=("global" "manual")
    PROFILE_NAMES=("Global Name" "Manual Name")
    PROFILE_EMAILS=("global@example.com" "manual@example.com")
    PROFILE_DIRS=("" "")  # Both empty!
    PROFILE_COUNT=2

    ensure_dirs
    write_global_gitconfig >/dev/null 2>&1
    write_profile_gitconfig "manual" "Manual Name" "manual@example.com" >/dev/null 2>&1
    write_ssh_config >/dev/null 2>&1
    write_profiles_conf >/dev/null 2>&1
    
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_global"
    touch "$HOME/.ssh/id_ed25519_manual"
    chmod 600 "$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_manual"
}

test_manual_mode_skips_includeif() {
    setup
    assert_file_not_contains "$HOME/.gitconfig" "includeIf"
    assert_file_not_contains "$HOME/.gitconfig" "safe"
}

test_manual_mode_creates_ssh_alias() {
    setup
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-manual"
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "IdentityFile ${HOME}/.ssh/id_ed25519_manual"
}

run_test "Manual Mode skips includeIf generation" test_manual_mode_skips_includeif
run_test "Manual Mode still creates SSH aliases" test_manual_mode_creates_ssh_alias

print_results "Manual Mode Tests"
