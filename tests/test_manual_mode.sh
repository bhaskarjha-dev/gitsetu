#!/usr/bin/env bash
# tests/test_manual_mode.sh — Tests for directory-less profile policy and SSH aliases
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$TEST_DIR/helpers.sh"
source_gitsetu_libs
detect_os

setup() {
    local mode="${1:-empty}"
    setup_test_home
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs || return 1

    PROFILE_LABELS=("global" "manual")
    PROFILE_NAMES=("Global Name" "Manual Name")
    PROFILE_EMAILS=("global@example.com" "manual@example.com")
    if [[ "$mode" == "routed" ]]; then
        mkdir -p "$HOME/manual"
        PROFILE_DIRS=("" "$HOME/manual")
    else
        PROFILE_DIRS=("" "")
    fi
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_manual")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
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

test_manual_mode_rejects_ambiguous_empty_profile() {
    setup empty
    # Only the mandatory global profile may have an empty directory. A second
    # empty profile would make the top-level fallback ambiguous, so the strict
    # v2 writer must refuse rather than silently creating a broad identity.
    assert_file_not_exists "$HOME/.gitconfig" "directory-less non-global profile must be rejected"
    assert_file_not_exists "$GITSETU_PROFILES_CONF" "ambiguous v2 registry must not be written"
}

test_manual_mode_creates_ssh_alias() {
    setup routed
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-manual"
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "IdentityFile ~/.ssh/id_ed25519_manual"
}

run_test "Manual Mode rejects ambiguous directory-less profiles" test_manual_mode_rejects_ambiguous_empty_profile
run_test "directory-backed profile still creates SSH aliases" test_manual_mode_creates_ssh_alias

print_results "Manual Mode Tests"
