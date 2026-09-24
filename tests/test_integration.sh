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

# Keep an end-to-end child from turning this suite into an unbounded hang when
# a product command waits for input or a broken helper.  GNU timeout is used
# when available; the fallback is portable Bash and preserves the child status.
run_integration_with_timeout() {
    local seconds="$1"
    shift
    local command_pid watchdog_pid command_status=0 watchdog_status=0

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
        return $?
    fi

    "$@" &
    command_pid=$!
    (
        sleep "$seconds"
        if kill -0 "$command_pid" 2>/dev/null; then
            kill -TERM "$command_pid" 2>/dev/null
            sleep 1
            if kill -0 "$command_pid" 2>/dev/null; then
                kill -KILL "$command_pid" 2>/dev/null
            fi
        fi
    ) &
    watchdog_pid=$!
    wait "$command_pid" || command_status=$?
    if kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -TERM "$watchdog_pid" 2>/dev/null
    fi
    if wait "$watchdog_pid" 2>/dev/null; then
        :
    else
        watchdog_status=$?
        [[ "$watchdog_status" -eq 143 || "$watchdog_status" -eq 137 ]] || return "$watchdog_status"
    fi
    if [[ "$command_status" -eq 143 || "$command_status" -eq 137 ]]; then
        return 124
    fi
    return "$command_status"
}

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
    ensure_dirs 2>/dev/null || return 1
    if ! generate_ssh_key "global" "global@test.com" "$HOME/.ssh/id_ed25519_global" 2>/dev/null; then
        printf '    FAIL: could not create the global SSH fixture key\n'
        return 1
    fi
    if ! generate_ssh_key "pro" "pro@test.com" "$HOME/.ssh/id_ed25519_pro" 2>/dev/null; then
        printf '    FAIL: could not create the pro SSH fixture key\n'
        return 1
    fi
    write_profile_gitconfig "pro" "Test Pro" "pro@test.com" "0" "$HOME/.ssh/id_ed25519_pro" 2>/dev/null || return 1
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
    local profile_config="$GITSETU_PROFILES_DIR/pro.gitconfig"
    assert_file_exists "$profile_config" "pro profile exists" || return 1
    assert_file_contains "$profile_config" "email = pro@test.com" "pro has email" || return 1

    # Do not assert a platform-specific rendering (`~/...` versus an absolute
    # path, quoting, or slash style).  Ask Git for the effective value and
    # verify the identity-file basename and option are present.
    local ssh_command
    if ! ssh_command=$(git config --file "$profile_config" --get core.sshCommand); then
        printf '    FAIL: Git could not read the profile core.sshCommand value\n'
        return 1
    fi
    assert_contains "$ssh_command" "-i" "pro uses an identity-file option" || return 1
    assert_contains "$ssh_command" "id_ed25519_pro" "pro sshCommand references its key"
}

test_integration_ssh_config_created() {
    assert_file_exists "$HOME/.ssh/config" "ssh config exists" &&
    assert_file_contains "$HOME/.ssh/config" "Include ~/.config/gitsetu/profiles/ssh_config" "has include directive" &&
    assert_file_exists "$GITSETU_PROFILES_DIR/ssh_config" "isolated ssh config exists" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-global" "has global host" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-pro" "has pro host" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "IdentitiesOnly yes" "has IdentitiesOnly"
}

test_integration_profiles_conf_created() {
    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf exists" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "# gitsetu-registry-v2" "strict v2 header exists" || return 1
    load_profiles
    assert_equals "2" "$PROFILE_COUNT" "v2 registry loads both profiles"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global v2 record exists"
    assert_equals "pro" "${PROFILE_LABELS[1]}" "pro v2 record exists"
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
    ssh_host_count=$(grep -c "Include ~/.config/gitsetu/profiles/ssh_config" "$HOME/.ssh/config")
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
    # The preceding setup cases already created a valid strict v2 state.  Reuse
    # it instead of regenerating keys and repeatedly traversing the Windows
    # reparse-point checks; this case is about the run boundary, not setup.
    if ! load_profiles; then
        printf '    FAIL: integration fixture registry could not be loaded\n'
        return 1
    fi

    local output
    local gitsetu_script
    gitsetu_script="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_script="${gitsetu_script%$'\r'}"

    # Run gitsetu with a bounded child so a broken product command fails the
    # test instead of hanging the whole suite.
    local raw_output run_status=0
    raw_output=$(run_integration_with_timeout 30 bash "$gitsetu_script" run pro -- env 2>&1) || run_status=$?
    assert_equals "0" "$run_status" "gitsetu run exits successfully" || return 1

    if ! output=$(printf '%s\n' "$raw_output" | grep '^GIT_AUTHOR_EMAIL='); then
        output=""
    fi

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

test_integration_execute_blueprint_noninteractive_summary() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    setup_two_profiles

    local output
    output=$(execute_blueprint 2>&1 || true)

    assert_contains "$output" "Setup Complete" "summary header rendered" || return 1
    assert_contains "$output" "Setup complete! You're ready to go." "summary success message" || return 1
    assert_contains "$output" "Quick Reference" "quick reference rendered" || return 1
    assert_contains "$output" "gitsetu status" "quick reference status command" || return 1
    assert_contains "$output" "gitsetu doctor" "quick reference doctor command" || return 1
}

# --- Run ---

printf '\n%btest_integration.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "SSH keys created for both profiles" test_integration_ssh_keys_created
run_test "global gitconfig created with defaults" test_integration_gitconfig_created
run_test "includeIf has correct path" test_integration_includeif_correct
run_test "profile gitconfig created" test_integration_profile_config_created
run_test "SSH config has host aliases" test_integration_ssh_config_created
run_test "strict v2 profiles.conf registry created" test_integration_profiles_conf_created
run_test "global gitconfig is parseable by git" test_integration_gitconfig_parseable
run_test "profile gitconfig is parseable by git" test_integration_profile_gitconfig_parseable
run_test "re-run is idempotent (no duplicates)" test_integration_idempotent_rerun
run_test "backups are created during re-run" test_integration_backup_created
run_test "gitsetu run exports correctly" test_integration_gitsetu_run
run_test "identity preservation on headless reload" test_identity_preservation_on_reload
run_test "execute_blueprint non-interactive completion summary" test_integration_execute_blueprint_noninteractive_summary
print_results "Integration tests"
