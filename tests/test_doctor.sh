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
    assert_contains "$output" "ERROR: Registry missing" "detects missing required registry" || return 1
    assert_contains "$output" "~/.gitconfig: ERROR" "detects missing gitconfig state" || return 1
    assert_contains "$output" "gitsetu doctor --repair" "suggests repair when issues found" || return 1
}

test_doctor_success_state() {
    # Build a genuinely healthy strict-v2 state. An empty registry is not a
    # healthy fixture: required identity/key checks must remain strict.
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519_global"
    test_v2_profile_config global "Global User" "global@example.com"
    local global_key
    global_key=$(normalize_path "$HOME/.ssh/id_ed25519_global")
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$global_key" ""
    } > "$GITSETU_PROFILES_CONF"
    load_profiles || return 1
    write_global_gitconfig >/dev/null 2>&1 || return 1
    write_ssh_config >/dev/null 2>&1 || return 1

    local output
    output=$(run_doctor 2>&1 || true)

    assert_contains "$output" "Registry: OK" "registry ok" || return 1
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.gitconfig: OK" "gitconfig ok" || return 1
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.ssh/config: OK" "ssh config ok" || return 1
    assert_contains "$output" "All required offline diagnostics passed" "healthy diagnostics report success" || return 1
    assert_not_contains "$output" "gitsetu doctor --repair" "does not suggest repair when clean" || return 1
}

printf '\n%btest_doctor.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "doctor detects missing registry" test_doctor_detects_missing_registry
run_test "doctor detects missing ssh agent" test_doctor_detects_missing_ssh_agent
run_test "doctor detects missing managed blocks" test_doctor_detects_missing_managed_blocks
run_test "doctor reports OK for clean state" test_doctor_success_state
print_results "Doctor tests"
