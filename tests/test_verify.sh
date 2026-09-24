#!/usr/bin/env bash
# shellcheck disable=SC2329  # SSH is replaced in isolated connectivity probes.
# tests/test_verify.sh — Real key/config/effective-identity verification tests
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home
source_gitsetu_libs

setup_verify_state() {
    setup_test_home
    source_gitsetu_libs
    GITSETU_DRY_RUN=0
    unset CI SSH_AUTH_SOCK GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL GITSETU_VERIFY_NETWORK GITSETU_ALLOW_SSH_HOST_KEY GITSETU_SSH_ACCEPT_NEW_HOST

    mkdir -p "$HOME/work/repo" "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519_global"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519_work"

    local global_key work_key work_dir
    global_key=$(normalize_path "$HOME/.ssh/id_ed25519_global")
    work_key=$(normalize_path "$HOME/.ssh/id_ed25519_work")
    work_dir=$(normalize_path "$HOME/work")
    PROFILE_COUNT=2
    PROFILE_LABELS=(global work)
    PROFILE_NAMES=("Global User" "Work User")
    PROFILE_EMAILS=(global@example.com work@example.com)
    PROFILE_DIRS=("" "$work_dir")
    PROFILE_PROVIDERS=(github.com github.com)
    PROFILE_SIGNS=(0 0)
    PROFILE_KEYS=("$global_key" "$work_key")
    PROFILE_USERS=(globaluser workuser)
    PROFILE_PATS=("" "")

    ensure_dirs
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$global_key" ""
        test_v2_registry_line work "$work_dir" "github.com" "0" "$work_key" ""
    } > "$GITSETU_PROFILES_CONF"
    write_global_gitconfig
    git -C "$HOME/work/repo" init --quiet
    git -C "$HOME/work/repo" config user.name "Work User"
    git -C "$HOME/work/repo" config user.email work@example.com
}

test_verify_ssh_keys_all_ok() {
    if ! can_chmod_600; then
        skip_test "verify_ssh_keys: all keys OK" "filesystem does not expose/enforce POSIX modes"
        return 0
    fi
    setup_verify_state
    local status=0
    verify_ssh_keys >/dev/null 2>&1 || status=$?
    assert_equals "0" "$status" "matching key pairs with supported permissions pass" || return 1
}

test_verify_ssh_keys_missing_pair() {
    setup_verify_state
    rm -f "$HOME/.ssh/id_ed25519_work.pub"
    local status=0
    verify_ssh_keys >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "missing public key fails validation" || return 1
}

test_verify_ssh_keys_rejects_mismatched_pair() {
    setup_verify_state
    printf '%s\n' 'not a valid OpenSSH public key' > "$HOME/.ssh/id_ed25519_work.pub"
    local status=0
    verify_ssh_keys >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "mismatched public/private fingerprints fail" || return 1
}

test_verify_ssh_keys_wrong_permissions() {
    if ! can_chmod_600; then
        skip_test "verify_ssh_keys: wrong permissions" "filesystem does not expose/enforce POSIX modes"
        return 0
    fi
    setup_verify_state
    chmod 644 "$HOME/.ssh/id_ed25519_work"
    local status=0
    verify_ssh_keys >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "broad private-key permissions fail on POSIX filesystems" || return 1
}

test_verify_external_approved_key_path() {
    if ! can_chmod_600; then
        skip_test "verify_ssh_keys: validated external key path" "filesystem does not expose/enforce POSIX modes"
        return 0
    fi
    setup_verify_state
    local external_dir="$TEST_HOME/external-keys"
    mkdir -p "$external_dir"
    if ! chmod 700 "$external_dir" 2>/dev/null; then
        printf '    FAIL: could not secure the external key directory\n'
        return 1
    fi
    cp "$HOME/.ssh/id_ed25519_work" "$external_dir/identity" || return 1
    cp "$HOME/.ssh/id_ed25519_work.pub" "$external_dir/identity.pub" || return 1
    if ! chmod 600 "$external_dir/identity" 2>/dev/null; then
        printf '    FAIL: could not secure the external key fixture\n'
        return 1
    fi
    PROFILE_KEYS[1]="$external_dir/identity"
    local status=0
    verify_ssh_keys >/dev/null 2>&1 || status=$?
    assert_equals "0" "$status" "validated external key path is accepted consistently" || return 1
}

test_verify_missing_key_field_fails() {
    setup_verify_state
    PROFILE_KEYS[1]=""
    local status=0
    verify_ssh_keys >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "missing v2 key field never falls back to a default path" || return 1
}

test_verify_git_config_missing_global() {
    setup_verify_state
    rm -f "$HOME/.gitconfig"
    local status=0
    verify_git_config >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "missing global gitconfig fails" || return 1
}

test_verify_git_config_detects_profile_mismatch() {
    setup_verify_state
    git config -f "$GITSETU_PROFILES_DIR/work.gitconfig" user.email wrong@example.com
    local status=0
    verify_git_config >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "profile config email mismatch fails" || return 1
}

test_verify_git_config_checks_effective_identity() {
    setup_verify_state
    local status=0
    GIT_AUTHOR_EMAIL=attacker@example.com \
        GIT_COMMITTER_EMAIL=work@example.com \
        verify_git_config >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "effective author override mismatch fails" || return 1
}

test_verify_git_config_all_ok() {
    setup_verify_state
    local status=0
    verify_git_config >/dev/null 2>&1 || status=$?
    assert_equals "0" "$status" "complete v2 configuration passes" || return 1
}

test_verify_all_stderr_only_and_offline() {
    if ! can_chmod_600; then
        skip_test "verify_all: required validators and offline network separation" "filesystem does not expose/enforce POSIX modes"
        return 0
    fi
    setup_verify_state
    local stdout_output status=0
    stdout_output=$(verify_all 2>"$TEST_HOME/verify.stderr") || status=$?
    assert_equals "" "$stdout_output" "verify_all produces zero stdout" || return 1
    assert_equals "0" "$status" "valid state passes required offline checks" || return 1
    assert_file_contains "$TEST_HOME/verify.stderr" "SKIPPED: network checks are opt-in" "network checks are visibly separate" || return 1
}

test_connectivity_refuses_untrusted_first_use() {
    setup_verify_state
    rm -f "$HOME/.ssh/known_hosts" "$TEST_HOME/ssh-ran"
    local output status=0
    output=$(
        ssh() {
            : > "$TEST_HOME/ssh-ran"
            printf '%s\n' 'Welcome!'
        }
        verify_ssh_connectivity 2>&1
    ) || status=$?
    assert_equals "1" "$status" "unknown host key is refused by default" || return 1
    assert_contains "$output" "No SSH connection was attempted" "first-use consent requirement is visible" || return 1
    assert_file_not_exists "$TEST_HOME/ssh-ran" "SSH is not attempted without first-use approval" || return 1
    assert_file_not_exists "$HOME/.ssh/known_hosts" "refused first use does not mutate known_hosts" || return 1
}

test_connectivity_explicit_consent_and_dry_run() {
    setup_verify_state
    rm -f "$HOME/.ssh/known_hosts" "$TEST_HOME/ssh-ran"
    local output status=0
    output=$(
        ssh() {
            : > "$TEST_HOME/ssh-ran"
            printf '%s\n' 'Welcome to GitHub!'
        }
        GITSETU_ALLOW_SSH_HOST_KEY=1 verify_ssh_connectivity 2>&1
    ) || status=$?
    assert_equals "0" "$status" "explicit first-use consent permits connectivity check" || return 1
    assert_contains "$output" "Explicitly approved first-use host key" "approval is visible" || return 1
    assert_file_exists "$TEST_HOME/ssh-ran" "approved connectivity check invokes SSH" || return 1

    rm -f "$TEST_HOME/ssh-ran"
    status=0
    output=$(
        ssh() { : > "$TEST_HOME/ssh-ran"; }
        GITSETU_DRY_RUN=1 GITSETU_ALLOW_SSH_HOST_KEY=1 verify_ssh_connectivity 2>&1
    ) || status=$?
    assert_equals "1" "$status" "dry-run connectivity check returns skipped status" || return 1
    assert_file_not_exists "$TEST_HOME/ssh-ran" "dry-run never invokes SSH" || return 1
}

printf '\n%btest_verify.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "verify_ssh_keys: matching key pairs pass" test_verify_ssh_keys_all_ok
run_test "verify_ssh_keys: missing public key fails" test_verify_ssh_keys_missing_pair
run_test "verify_ssh_keys: mismatched key pair fails" test_verify_ssh_keys_rejects_mismatched_pair
run_test "verify_ssh_keys: broad POSIX permissions fail" test_verify_ssh_keys_wrong_permissions
run_test "verify_ssh_keys: validated external key path is accepted" test_verify_external_approved_key_path
run_test "verify_ssh_keys: missing key field fails without defaulting" test_verify_missing_key_field_fails
run_test "verify_git_config: missing global config fails" test_verify_git_config_missing_global
run_test "verify_git_config: profile mismatch fails" test_verify_git_config_detects_profile_mismatch
run_test "verify_git_config: effective author override fails" test_verify_git_config_checks_effective_identity
run_test "verify_git_config: complete v2 config passes" test_verify_git_config_all_ok
run_test "verify_all: required validators run and network stays separate" test_verify_all_stderr_only_and_offline
run_test "connectivity: unknown host key is refused by default" test_connectivity_refuses_untrusted_first_use
run_test "connectivity: explicit first-use consent and dry-run behavior" test_connectivity_explicit_consent_and_dry_run
print_results "Verify tests"
