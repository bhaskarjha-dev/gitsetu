#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked functions invoked dynamically or via subshells
# tests/test_doctor_repair.sh — Doctor Self-Healing & Repair Suite
# Verifies Phase 2 Doctor Repair Mode (Task T2.2)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

GITSETU_EXE="$REPO_DIR/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

# Helper to set up a minimal valid GitSetu configuration
setup_valid_gitsetu_environment() {
    rm -rf "$GITSETU_CONFIG_DIR" "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    mkdir -p "$GITSETU_CONFIG_DIR" "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    
    # Create profile gitconfigs
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@corp.com"
    test_v2_profile_config personal "Personal User" "personal@me.dev"

    # Create and validate every key named by the strict v2 registry,
    # including the mandatory global profile.
    if ! ssh-keygen -t ed25519 -C "global@example.com" \
        -f "$HOME/.ssh/id_ed25519_global" -N "" -q; then
        printf '    FAIL: could not create the global SSH fixture key\n'
        return 1
    fi
    if ! ssh-keygen -t ed25519 -C "work@corp.com" \
        -f "$HOME/.ssh/id_ed25519_work" -N "" -q; then
        printf '    FAIL: could not create the work SSH fixture key\n'
        return 1
    fi
    if ! ssh-keygen -t ed25519 -C "personal@me.dev" \
        -f "$HOME/.ssh/id_ed25519_personal" -N "" -q; then
        printf '    FAIL: could not create the personal SSH fixture key\n'
        return 1
    fi
    local key_path
    for key_path in \
        "$HOME/.ssh/id_ed25519_global" \
        "$HOME/.ssh/id_ed25519_work" \
        "$HOME/.ssh/id_ed25519_personal"; do
        if [[ ! -f "$key_path" || -L "$key_path" ]]; then
            printf '    FAIL: SSH fixture key is missing or redirected: %s\n' "$key_path"
            return 1
        fi
    done

    # Set up a strict v2 profile registry; legacy seven-field rows are never
    # accepted by the product loader.
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" ""
        test_v2_registry_line personal "$HOME/personal" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_personal" ""
    } > "$GITSETU_PROFILES_CONF"

    load_profiles || return 1
    write_global_gitconfig || return 1
    write_ssh_config || return 1
}

# ------------------------------------------------------------------------------
# Test 1: run_doctor_repair returns 1 when GitSetu is unconfigured
# ------------------------------------------------------------------------------
test_repair_unconfigured_fails() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig"

    local output rc=0
    output=$(run_doctor_repair 2>&1) || rc=$?

    assert_equals "1" "$rc" "returns 1 when unconfigured" || return 1
    assert_contains "$output" "GitSetu has not been configured yet" "emits unconfigured guidance" || return 1
    assert_contains "$output" "Run 'gitsetu setup' first" "points to setup wizard" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: run_doctor_repair reports nothing to repair on clean environment
# ------------------------------------------------------------------------------
test_repair_clean_environment() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK # Ensure agent check is not triggered

    local output rc=0
    output=$(run_doctor_repair 2>&1) || rc=$?

    assert_equals "0" "$rc" "returns 0 on clean environment" || return 1
    assert_contains "$output" "Nothing to repair" "reports clean intact configuration" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: run_doctor_repair restores missing managed blocks in ~/.gitconfig
# ------------------------------------------------------------------------------
test_repair_restores_gitconfig_managed_block() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK

    # Corrupt or wipe ~/.gitconfig
    echo "[core]" > "$HOME/.gitconfig"
    echo "    editor = nano" >> "$HOME/.gitconfig"

    assert_file_not_contains "$HOME/.gitconfig" "$GITSETU_MANAGED_START" "managed start missing before repair" || return 1

    local output rc=0
    output=$(run_doctor_repair 2>&1) || rc=$?

    assert_equals "0" "$rc" "returns 0 after repairing gitconfig" || return 1
    assert_contains "$output" "Restored managed blocks in ~/.gitconfig" "reports gitconfig repair" || return 1
    assert_file_contains "$HOME/.gitconfig" "$GITSETU_MANAGED_START" "managed start restored" || return 1
    assert_file_contains "$HOME/.gitconfig" "$GITSETU_MANAGED_END" "managed end restored" || return 1
    assert_file_contains "$HOME/.gitconfig" "editor = nano" "preserves user existing gitconfig settings" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: run_doctor_repair restores missing Include directive in ~/.ssh/config
# ------------------------------------------------------------------------------
test_repair_restores_ssh_include_directive() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK

    # Corrupt ~/.ssh/config by removing the Include directive
    echo "Host my-custom-server" > "$HOME/.ssh/config"
    echo "    HostName 192.168.1.100" >> "$HOME/.ssh/config"

    # Also remove isolated config to verify full rebuild
    rm -f "$GITSETU_PROFILES_DIR/ssh_config"

    local output rc=0
    output=$(run_doctor_repair 2>&1) || rc=$?

    assert_equals "0" "$rc" "returns 0 after repairing ssh config" || return 1
    assert_contains "$output" "Restored SSH configuration in ~/.ssh/config" "reports ssh config repair" || return 1
    assert_file_exists "$GITSETU_PROFILES_DIR/ssh_config" "recreated isolated ssh_config" || return 1
    
    local first_line
    first_line=$(head -n 1 "$HOME/.ssh/config")
    assert_contains "$first_line" "Include" "Include directive is on the first line" || return 1
    assert_file_contains "$HOME/.ssh/config" "Host my-custom-server" "preserves existing ssh config hosts" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: run_doctor_repair registers missing keys in ssh-agent
# ------------------------------------------------------------------------------
test_repair_registers_missing_keys_in_agent() {
    setup_valid_gitsetu_environment
    export SSH_AUTH_SOCK="/tmp/mock_agent_sock"

    local output rc=0
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then
                return 1 # No keys loaded
            fi
            return 0 # Successfully adds key
        }
        run_doctor_repair 2>&1
    ) || rc=$?
    unset SSH_AUTH_SOCK

    assert_equals "0" "$rc" "returns 0 after registering keys" || return 1
    assert_contains "$output" "Registering profile SSH keys with ssh-agent" "triggers agent registration" || return 1
    assert_contains "$output" "Repair complete" "summary shows completed repair" || return 1
}

# ------------------------------------------------------------------------------
# Test 6: CLI dispatch: gitsetu doctor --repair routes to run_doctor_repair
# ------------------------------------------------------------------------------
test_cli_doctor_repair_dispatch() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK

    # Wipe ~/.gitconfig to trigger repair via CLI
    rm -f "$HOME/.gitconfig"

    local output rc=0
    output=$(bash "$GITSETU_EXE" doctor --repair 2>&1) || rc=$?

    assert_equals "0" "$rc" "gitsetu doctor --repair exits 0" || return 1
    assert_contains "$output" "GitSetu Repair (Doctor)" "routes to doctor repair header" || return 1
    assert_contains "$output" "Restored managed blocks in ~/.gitconfig" "executes repair logic" || return 1
}

# ------------------------------------------------------------------------------
# Test 7: CLI dispatch: gitsetu doctor --repair --dry-run makes no filesystem mutations
# ------------------------------------------------------------------------------
test_cli_doctor_repair_dry_run() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK

    # Corrupt ~/.gitconfig
    rm -f "$HOME/.gitconfig"

    local output rc=0
    output=$(bash "$GITSETU_EXE" doctor --repair --dry-run 2>&1) || rc=$?

    assert_equals "0" "$rc" "doctor --repair --dry-run exits 0" || return 1
    assert_contains "$output" "[DRY RUN]" "outputs dry run indicator" || return 1
    assert_contains "$output" "[DRY RUN] Would restore managed blocks in ~/.gitconfig" "emits non-deceptive dry run action" || return 1
    assert_contains "$output" "[DRY RUN] Dry run complete" "emits dry run completion summary" || return 1
    assert_not_contains "$output" "issue(s) resolved" "does not claim issues resolved" || return 1
    if [[ -f "$HOME/.gitconfig" ]]; then
        printf '    FAIL: dry run should not create ~/.gitconfig\n'
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Test 8: run_doctor suggests --repair on issue, omits suggestion on healthy
# ------------------------------------------------------------------------------
test_run_doctor_suggests_repair_on_broken() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK

    # 1. Broken state: ~/.gitconfig missing
    rm -f "$HOME/.gitconfig"
    local broken_out
    broken_out=$(run_doctor 2>&1 || true)
    assert_contains "$broken_out" "gitsetu doctor --repair" "suggests repair when broken" || return 1

    # 2. Healthy state: ~/.gitconfig restored
    write_global_gitconfig
    local healthy_out
    healthy_out=$(run_doctor 2>&1 || true)
    assert_not_contains "$healthy_out" "gitsetu doctor --repair" "omits repair hint when clean" || return 1
}

# ------------------------------------------------------------------------------
# Test 10: corrupt SSH state invokes the SSH writer even when Git is healthy
# ------------------------------------------------------------------------------
test_repair_planner_invokes_ssh_writer_for_corrupt_ssh_state() {
    setup_test_home
    source_gitsetu_libs
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    test_v2_profile_config global "Global User" "global@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
    } > "$GITSETU_PROFILES_CONF"
    printf '%s\n[user]\n    name = Global User\n    email = global@example.com\n%s\n' \
        "$GITSETU_MANAGED_START" "$GITSETU_MANAGED_END" > "$HOME/.gitconfig"
    printf '%s\n' 'Host custom' '    HostName 127.0.0.1' > "$HOME/.ssh/config"
    rm -f "$GITSETU_PROFILES_DIR/ssh_config"
    unset SSH_AUTH_SOCK

    local marker="$TEST_HOME/ssh-writer-called"
    rm -f "$marker"
    local output rc=0
    output=$(
        acquire_lock() { GITSETU_LOCK_DEPTH=1; return 0; }
        release_lock() { GITSETU_LOCK_DEPTH=0; return 0; }
        write_global_gitconfig() { return 0; }
        write_ssh_config() {
            printf 'called\\n' > "$marker"
            mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
            printf '%s\\n' '# generated' > "$GITSETU_PROFILES_DIR/ssh_config"
            printf '%s\\n' 'Include ~/.config/gitsetu/profiles/ssh_config' > "$HOME/.ssh/config"
            return 0
        }
        run_doctor_repair 2>&1
    ) || rc=$?
    assert_equals "0" "$rc" "SSH corruption repair succeeds when the SSH writer is available" || return 1
    assert_file_exists "$marker" "repair planner invokes write_ssh_config for corrupt SSH state" || return 1
    assert_contains "$output" "Repair complete" "SSH repair reports completion" || return 1
    rm -f "$marker"
}

# ------------------------------------------------------------------------------
# Test 9: a failed later writer rolls back earlier config mutations
# ------------------------------------------------------------------------------
test_repair_rolls_back_partial_config_write() {
    setup_valid_gitsetu_environment
    unset SSH_AUTH_SOCK
    local corrupted_ssh
    corrupted_ssh=$'Host intentionally-broken\n    HostName 127.0.0.1'
    printf '%s\n' "$corrupted_ssh" > "$HOME/.ssh/config"
    rm -f "$HOME/.gitconfig" "$GITSETU_PROFILES_DIR/ssh_config"

    local checkout="$TEST_HOME/repair-fault-checkout"
    mkdir -p "$checkout"
    cp "$GITSETU_EXE" "$checkout/gitsetu"
    cp -R "$REPO_DIR/lib" "$checkout/lib"
    printf '\nwrite_ssh_config() { return 17; }\n' >> "$checkout/lib/ssh.sh"

    local output rc=0
    output=$(bash "$checkout/gitsetu" doctor --repair 2>&1) || rc=$?
    assert_equals "1" "$rc" "failed SSH writer makes repair fail" || return 1
    assert_file_not_exists "$HOME/.gitconfig" "Git config mutation is rolled back" || return 1
    local restored_ssh
    restored_ssh=$(cat "$HOME/.ssh/config") || return 1
    assert_equals "$corrupted_ssh" "$restored_ssh" "corrupted SSH config is restored after rollback" || return 1
    assert_file_not_exists "$GITSETU_PROFILES_DIR/ssh_config" "missing isolated SSH state remains absent after rollback" || return 1
    assert_contains "$output" "rolled back" "repair reports rollback" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_doctor_repair.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "doctor --repair unconfigured machine returns 1" test_repair_unconfigured_fails
run_test "doctor --repair clean environment reports nothing to repair" test_repair_clean_environment
run_test "doctor --repair restores missing gitconfig managed blocks" test_repair_restores_gitconfig_managed_block
run_test "doctor --repair restores missing SSH Include and isolated config" test_repair_restores_ssh_include_directive
run_test "doctor --repair registers missing keys in agent" test_repair_registers_missing_keys_in_agent
run_test "CLI gitsetu doctor --repair routes to repair pipeline" test_cli_doctor_repair_dispatch
run_test "CLI gitsetu doctor --repair --dry-run makes 0 mutations" test_cli_doctor_repair_dry_run
run_test "doctor diagnostics footer conditionally suggests --repair" test_run_doctor_suggests_repair_on_broken
run_test "doctor repair rolls back partial config writes" test_repair_rolls_back_partial_config_write
run_test "repair planner invokes SSH writer for corrupt SSH state" test_repair_planner_invokes_ssh_writer_for_corrupt_ssh_state
print_results "Doctor Repair tests"
