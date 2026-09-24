#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked functions invoked dynamically or via subshells
# tests/test_firewall_fallback.sh — Corporate Firewall & Port 443 Fallback Suite
# Verifies end-to-end network resilience when port 22 is blocked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

# ------------------------------------------------------------------------------
# Test 1: Standard port 22 success does not set GITSETU_PORT443_NEEDED
# ------------------------------------------------------------------------------
test_standard_port22_no_fallback() {
    export GITSETU_PORT443_NEEDED=0
    local dummy_key="$TEST_HOME/.ssh/id_test"
    mkdir -p "$TEST_HOME/.ssh"
    touch "$dummy_key"

    local output rc=0
    output=$(
        ssh() {
            echo "Hi user! You've successfully authenticated."
            return 1
        }
        GITSETU_TEST_SSH_VERIFY=1 verify_ssh_handshake "$dummy_key" "github.com" 2>&1
    ) || rc=$?

    assert_equals "0" "$rc" "handshake exits 0" || return 1
    assert_contains "$output" "(port 22;" "verified on port 22" || return 1
    assert_equals "0" "${GITSETU_PORT443_NEEDED:-0}" "port 443 flag remains 0" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: Port 22 blocked + Port 443 open sets GITSETU_PORT443_NEEDED=1
# ------------------------------------------------------------------------------
test_port443_fallback_triggered() {
    export GITSETU_PORT443_NEEDED=0
    export GITSETU_ALLOW_SSH_PORT443=1
    local dummy_key="$TEST_HOME/.ssh/id_corp"
    mkdir -p "$TEST_HOME/.ssh"
    touch "$dummy_key"

    local output rc=0
    # Run in current shell environment to capture exported variable
    ssh() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == "443" ]]; then
                echo "Hi user! You've successfully authenticated."
                return 1
            fi
        done
        return 255 # port 22 blocked
    }
    GITSETU_TEST_SSH_VERIFY=1 verify_ssh_handshake "$dummy_key" "github.com" >/dev/null 2>&1 || rc=$?
    unset -f ssh
    unset GITSETU_ALLOW_SSH_PORT443

    assert_equals "0" "$rc" "handshake fallback exits 0" || return 1
    assert_equals "1" "${GITSETU_PORT443_NEEDED:-0}" "port 443 flag exported as 1" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: Non-GitHub hosts do not attempt GitHub Port 443 fallback
# ------------------------------------------------------------------------------
test_nongithub_no_port443_fallback() {
    export GITSETU_PORT443_NEEDED=0
    local dummy_key="$TEST_HOME/.ssh/id_gl"
    mkdir -p "$TEST_HOME/.ssh"
    touch "$dummy_key"

    local output rc=0
    output=$(
        ssh() {
            # All ports fail
            return 255
        }
        GITSETU_TEST_SSH_VERIFY=1 verify_ssh_handshake "$dummy_key" "gitlab.com" 2>&1
    ) || rc=$?

    assert_equals "1" "$rc" "returns 1 when gitlab connection fails" || return 1
    assert_contains "$output" "SSH verification for gitlab.com failed" "reports non-fatal failure" || return 1
    assert_equals "0" "${GITSETU_PORT443_NEEDED:-0}" "does not trigger port 443 flag for gitlab" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: write_ssh_config emits Port 443 block when flag is set
# ------------------------------------------------------------------------------
test_write_ssh_config_with_port443() {
    export GITSETU_PORT443_NEEDED=1
    PROFILE_COUNT=1
    PROFILE_LABELS[0]="corp"
    PROFILE_PROVIDERS[0]="github.com"
    PROFILE_KEYS[0]="$HOME/.ssh/id_ed25519_corp"

    write_ssh_config
    local isolated_config="$GITSETU_PROFILES_DIR/ssh_config"

    assert_file_exists "$isolated_config" "isolated ssh config created" || return 1
    assert_file_contains "$isolated_config" "HostName ssh.github.com" "contains ssh.github.com" || return 1
    assert_file_contains "$isolated_config" "Port 443" "contains Port 443" || return 1
    assert_file_contains "$isolated_config" "IdentityFile ~/.ssh/id_ed25519_corp" "contains correct key" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: Reverting GITSETU_PORT443_NEEDED restores clean port 22 config
# ------------------------------------------------------------------------------
test_write_ssh_config_reversion_to_port22() {
    export GITSETU_PORT443_NEEDED=0
    PROFILE_COUNT=1
    PROFILE_LABELS[0]="corp"
    PROFILE_PROVIDERS[0]="github.com"
    PROFILE_KEYS[0]="$HOME/.ssh/id_ed25519_corp"

    write_ssh_config
    local isolated_config="$GITSETU_PROFILES_DIR/ssh_config"

    assert_file_exists "$isolated_config" "isolated ssh config created" || return 1
    assert_file_contains "$isolated_config" "HostName github.com" "restored standard HostName" || return 1
    assert_file_not_contains "$isolated_config" "Port 443" "Port 443 cleaned up" || return 1
    assert_file_not_contains "$isolated_config" "ssh.github.com" "ssh.github.com cleaned up" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_firewall_fallback.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "standard port 22 does not trigger fallback" test_standard_port22_no_fallback
run_test "port 22 timeout triggers port 443 fallback and sets flag" test_port443_fallback_triggered
run_test "non-GitHub hosts do not attempt port 443 fallback" test_nongithub_no_port443_fallback
run_test "write_ssh_config emits Port 443 block when flag is set" test_write_ssh_config_with_port443
run_test "reverting flag cleanly restores port 22 configuration" test_write_ssh_config_reversion_to_port22
print_results "Firewall Fallback tests"
