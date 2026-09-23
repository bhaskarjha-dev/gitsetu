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
    cat << 'EOF' > "$GITSETU_PROFILES_DIR/work.gitconfig"
[user]
    name = Work User
    email = work@corp.com
EOF
    cat << 'EOF' > "$GITSETU_PROFILES_DIR/personal.gitconfig"
[user]
    name = Personal User
    email = personal@me.dev
EOF

    # Create dummy private/public keys
    ssh-keygen -t ed25519 -C "work@corp.com" -f "$HOME/.ssh/id_ed25519_work" -N "" -q
    ssh-keygen -t ed25519 -C "personal@me.dev" -f "$HOME/.ssh/id_ed25519_personal" -N "" -q

    # Set up profile registry
    cat << EOF > "$GITSETU_PROFILES_CONF"
work::$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:
personal::$HOME/personal:github.com:0:$HOME/.ssh/id_ed25519_personal:
EOF

    load_profiles
    write_global_gitconfig
    write_ssh_config
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
print_results "Doctor Repair tests"
