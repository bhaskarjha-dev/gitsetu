#!/usr/bin/env bash
# shellcheck disable=SC2034  # Test state vars are consumed by sourced library functions
# tests/test_integration.sh — Full end-to-end integration test
#
# Simulates a complete gitsetu setup with 2 profiles in an isolated temp HOME.
# Does NOT require network access (skips SSH connectivity tests).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs
detect_os

# --- Integration tests ---

# Simulate a full 2-profile setup
setup_two_profiles() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test Global" "Test Pro")
    PROFILE_EMAILS=("global@test.com" "pro@test.com")
    PROFILE_DIRS=("" "$HOME/dev/pro")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_pro")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
    PROFILE_COUNT=2

    # Create the profile directory
    mkdir -p "$HOME/dev/pro"

    # Execute all setup steps
    ensure_dirs 2>/dev/null
    generate_ssh_key "global" "global@test.com" "$HOME/.ssh/id_ed25519_global" 2>/dev/null || true
    generate_ssh_key "pro" "pro@test.com" "$HOME/.ssh/id_ed25519_pro" 2>/dev/null || true
    write_profile_gitconfig "pro" "Test Pro" "pro@test.com" "0" "$HOME/.ssh/id_ed25519_pro" 2>/dev/null
    write_global_gitconfig 2>/dev/null
    write_ssh_config 2>/dev/null
    write_profiles_conf 2>/dev/null
}

test_integration_ssh_keys_created() {
    setup_two_profiles

    assert_file_exists "$HOME/.ssh/id_ed25519_global" "global private key" &&
    assert_file_exists "$HOME/.ssh/id_ed25519_global.pub" "global public key" &&
    assert_file_exists "$HOME/.ssh/id_ed25519_pro" "pro private key" &&
    assert_file_exists "$HOME/.ssh/id_ed25519_pro.pub" "pro public key"
}

test_integration_gitconfig_created() {
    assert_file_exists "$HOME/.gitconfig" "global gitconfig exists" &&
    assert_file_contains "$HOME/.gitconfig" "useConfigOnly = true" "has useConfigOnly"
}

test_integration_includeif_correct() {
    local keyword
    keyword=$(get_gitdir_keyword)

    assert_file_contains "$HOME/.gitconfig" \
        "[includeIf \"${keyword}${HOME}/dev/pro/\"]" \
        "has includeIf for pro dir"
}

test_integration_profile_config_created() {
    assert_file_exists "$GITSETU_PROFILES_DIR/pro.gitconfig" "pro profile exists" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/pro.gitconfig" "email = pro@test.com" "pro has email" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/pro.gitconfig" "sshCommand = ssh -i ${HOME}/.ssh/id_ed25519_pro" "pro has sshCommand"
}

test_integration_ssh_config_created() {
    assert_file_exists "$HOME/.ssh/config" "ssh config exists" &&
    assert_file_contains "$HOME/.ssh/config" "Include $GITSETU_PROFILES_DIR/ssh_config" "has include directive" &&
    assert_file_exists "$GITSETU_PROFILES_DIR/ssh_config" "isolated ssh config exists" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-global" "has global host" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-pro" "has pro host" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "IdentitiesOnly yes" "has IdentitiesOnly"
}

test_integration_profiles_conf_created() {
    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf exists" &&
    assert_file_contains "$GITSETU_PROFILES_CONF" "global:::" "global entry" &&
    assert_file_contains "$GITSETU_PROFILES_CONF" "pro::$HOME/dev/pro" "pro entry"
}

test_integration_gitconfig_parseable() {
    # Use git config --file to verify the generated config is valid
    local result
    result=$(git config --file "$HOME/.gitconfig" user.useConfigOnly 2>/dev/null || echo "PARSE_ERROR")
    assert_equals "true" "$result" "git can parse useConfigOnly"
}

test_integration_profile_gitconfig_parseable() {
    local result
    result=$(git config --file "$GITSETU_PROFILES_DIR/pro.gitconfig" user.email 2>/dev/null || echo "PARSE_ERROR")
    assert_equals "pro@test.com" "$result" "git can parse profile email"
}

test_integration_idempotent_rerun() {
    # Run setup again
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test Global" "Test Pro")
    PROFILE_EMAILS=("global@test.com" "pro@test.com")
    PROFILE_DIRS=("" "$HOME/dev/pro")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
    PROFILE_COUNT=2

    write_global_gitconfig 2>/dev/null
    write_ssh_config 2>/dev/null

    # Check no duplicates
    local gitconfig_markers
    gitconfig_markers=$(grep -c "\[gitsetu:managed:start\]" "$HOME/.gitconfig")
    assert_equals "1" "$gitconfig_markers" "gitconfig has exactly 1 managed block" || return 1

    local ssh_host_count
    ssh_host_count=$(grep -c "Include $GITSETU_PROFILES_DIR/ssh_config" "$HOME/.ssh/config")
    assert_equals "1" "$ssh_host_count" "ssh config has exactly 1 Include directive"
}

test_integration_backup_created() {
    # Backups should have been created during the re-run
    local backup_count
    backup_count=$(find "$GITSETU_BACKUP_DIR" -name "*.bak" 2>/dev/null | wc -l)

    if [[ "$backup_count" -ge 1 ]]; then
        return 0
    fi

    printf '    FAIL: No backups found in %s\n' "$GITSETU_BACKUP_DIR"
    return 1
}

test_integration_gitsetu_run() {
    # Clean up to avoid interactive prompts on existing keys
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    setup_two_profiles

    # Execute gitsetu run in a subshell, verify it exports the right email
    local output
    local gitsetu_script
    gitsetu_script="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_script="${gitsetu_script%$'\r'}"
    
    # Run gitsetu and capture output, ignoring failures due to set -e
    local raw_output
    raw_output=$(bash "$gitsetu_script" run pro -- env 2>&1 || true)
    
    output=$(echo "$raw_output" | grep "^GIT_AUTHOR_EMAIL=" || true)
    
    if [[ "$output" != "GIT_AUTHOR_EMAIL=pro@test.com" ]]; then
        echo "RAW OUTPUT WAS: $raw_output"
    fi
    assert_equals "GIT_AUTHOR_EMAIL=pro@test.com" "$output" "gitsetu run exports correct environment variable"

}

test_identity_preservation_on_reload() {
    # Test that loading profiles does not overwrite custom names with global fallback
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    setup_two_profiles

    # Modify pro.gitconfig to have a distinct custom name
    git config -f "$GITSETU_PROFILES_DIR/pro.gitconfig" user.name "Custom Pro Name"

    # Call load_profiles (simulating a headless load)
    load_profiles

    # Check if PROFILE_NAMES populated correctly
    local i
    local found_name=""
    for i in $(seq 0 $((PROFILE_COUNT - 1))); do
        if [[ "${PROFILE_LABELS[$i]}" == "pro" ]]; then
            found_name="${PROFILE_NAMES[$i]}"
        fi
    done

    assert_equals "Custom Pro Name" "$found_name" "custom name is preserved in memory"

    # Simulate execute_blueprint rewriting configs
    write_profile_gitconfig "pro" "$found_name" "pro@test.com" "0" "$HOME/.ssh/id_ed25519_pro" 2>/dev/null
    
    local final_name
    final_name=$(git config -f "$GITSETU_PROFILES_DIR/pro.gitconfig" user.name)
    assert_equals "Custom Pro Name" "$final_name" "custom name is preserved on disk after rewrite"
}

# --- Run ---

printf '\n%btest_integration.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "SSH keys created for both profiles" test_integration_ssh_keys_created
run_test "global gitconfig created with defaults" test_integration_gitconfig_created
run_test "includeIf has correct path" test_integration_includeif_correct
run_test "profile gitconfig created" test_integration_profile_config_created
run_test "SSH config has host aliases" test_integration_ssh_config_created
run_test "profiles.conf registry created" test_integration_profiles_conf_created
run_test "global gitconfig is parseable by git" test_integration_gitconfig_parseable
run_test "profile gitconfig is parseable by git" test_integration_profile_gitconfig_parseable
run_test "re-run is idempotent (no duplicates)" test_integration_idempotent_rerun
run_test "backups are created during re-run" test_integration_backup_created
run_test "gitsetu run exports correctly" test_integration_gitsetu_run
run_test "identity preservation on headless reload" test_identity_preservation_on_reload
print_results "Integration tests"
