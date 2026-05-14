#!/usr/bin/env bash
# tests/test_doctor.sh — Tests for the diagnostic doctor tool
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

test_doctor_detects_missing_registry() {
    # Delete registry
    rm -f "$GITSETU_PROFILES_CONF"
    
    local output
    output=$(run_doctor 2>&1 || true)
    
    assert_contains "$output" "ERROR: Registry missing" "detects missing registry" || return 1
}

test_doctor_detects_missing_ssh_agent() {
    # Unset SSH_AUTH_SOCK
    local old_sock="${SSH_AUTH_SOCK:-}"
    unset SSH_AUTH_SOCK
    
    local output
    output=$(run_doctor 2>&1 || true)
    
    assert_contains "$output" "WARNING: SSH_AUTH_SOCK is not set" "detects missing ssh agent" || return 1
    
    # Restore
    if [[ -n "$old_sock" ]]; then
        export SSH_AUTH_SOCK="$old_sock"
    fi
}

test_doctor_detects_missing_managed_blocks() {
    # Delete gitconfig
    rm -f "$HOME/.gitconfig" "$HOME/.ssh/config"
    
    local output
    output=$(run_doctor 2>&1 || true)
    
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.gitconfig: " "checks gitconfig" || return 1
    assert_contains "$output" "WARNING (Managed blocks missing)" "detects missing block in gitconfig" || return 1
}

test_doctor_success_state() {
    # Setup a clean environment
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    touch "$GITSETU_PROFILES_CONF"
    
    cat > "$HOME/.gitconfig" <<EOF
${GITSETU_MANAGED_START}
[user]
    useConfigOnly = true
EOF

    mkdir -p "$HOME/.ssh"
    cat > "$HOME/.ssh/config" <<EOF
Include $GITSETU_PROFILES_DIR/ssh_config
Host test
EOF

    local output
    output=$(run_doctor 2>&1 || true)
    
    assert_contains "$output" "Registry: OK" "registry ok" || return 1
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.gitconfig: OK" "gitconfig ok" || return 1
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.ssh/config: OK" "ssh config ok" || return 1
}

printf '\n%btest_doctor.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "doctor detects missing registry" test_doctor_detects_missing_registry
run_test "doctor detects missing ssh agent" test_doctor_detects_missing_ssh_agent
run_test "doctor detects missing managed blocks" test_doctor_detects_missing_managed_blocks
run_test "doctor reports OK for clean state" test_doctor_success_state
print_results "Doctor tests"
