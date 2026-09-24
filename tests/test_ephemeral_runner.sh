#!/usr/bin/env bash
# tests/test_ephemeral_runner.sh — Autonomous Ephemeral / CI Setup Suite
# Verifies zero-prompt onboarding pipeline and auto setup runner
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
# Test 1: auto_setup_runner fails gracefully if no email can be resolved
# ------------------------------------------------------------------------------
test_auto_runner_fails_without_email() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.gitconfig"
    if git config --global --get user.email >/dev/null 2>&1; then
        git config --global --unset user.email || return 1
    fi
    if git config --global --get user.name >/dev/null 2>&1; then
        git config --global --unset user.name || return 1
    fi

    local output rc=0
    output=$(auto_setup_runner 2>&1) || rc=$?

    assert_equals "1" "$rc" "exits 1 when no email available" || return 1
    assert_contains "$output" "Auto-discovery could not detect a global Git email" "emits email required error" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: auto_setup_runner succeeds with discovered global git email
# ------------------------------------------------------------------------------
test_auto_runner_succeeds_with_env_email() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.gitconfig" "$HOME/.ssh"
    git config --global user.name "CI Worker"
    git config --global user.email "ci-agent@enterprise.dev"

    local output rc=0
    output=$(auto_setup_runner 2>&1) || rc=$?

    assert_equals "0" "$rc" "auto_setup_runner exits 0" || return 1
    assert_file_exists "$GITSETU_PROFILES_CONF" "creates profiles.conf" || return 1
    assert_file_exists "$HOME/.gitconfig" "creates .gitconfig" || return 1
    assert_file_contains "$HOME/.gitconfig" "$GITSETU_MANAGED_START" "managed gitconfig created" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: CLI gitsetu setup --auto executes zero-prompt pipeline
# ------------------------------------------------------------------------------
test_cli_setup_auto_execution() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.gitconfig" "$HOME/.ssh"
    git config --global user.name "Build Bot"
    git config --global user.email "automated@build.io"

    local output rc=0
    output=$(bash "$GITSETU_EXE" setup --auto 2>&1) || rc=$?

    assert_equals "0" "$rc" "gitsetu setup --auto exits 0" || return 1
    assert_contains "$output" "Zero-Prompt Auto-Discovery Blueprint" "displays auto banner" || return 1
    assert_contains "$output" "Setup complete!" "displays completion summary" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: auto_setup_runner adopts existing blueprint profiles if present
# ------------------------------------------------------------------------------
test_auto_runner_adopts_existing_blueprint() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.gitconfig" "$HOME/.ssh"
    mkdir -p "$GITSETU_PROFILES_DIR"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Worker" "worker@corp.com"
    test_v2_profile_config personal "Person" "person@me.dev"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" ""
        test_v2_registry_line personal "$HOME/personal" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_personal" ""
    } > "$GITSETU_PROFILES_CONF"

    local output rc=0
    output=$(auto_setup_runner 2>&1) || rc=$?

    assert_equals "0" "$rc" "auto_setup_runner exits 0 on existing blueprint" || return 1
    assert_file_exists "$HOME/.gitconfig" "creates .gitconfig" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-work" "generates work ssh host" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-personal" "generates personal ssh host" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_ephemeral_runner.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "auto_setup_runner fails without discoverable email" test_auto_runner_fails_without_email
run_test "auto_setup_runner succeeds with GITSETU_DEFAULT_EMAIL" test_auto_runner_succeeds_with_env_email
run_test "CLI gitsetu setup --auto executes zero-prompt pipeline" test_cli_setup_auto_execution
run_test "auto_setup_runner adopts existing blueprint profiles" test_auto_runner_adopts_existing_blueprint
print_results "Ephemeral Runner tests"
