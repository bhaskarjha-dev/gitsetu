#!/usr/bin/env bash
# shellcheck disable=SC2034  # Test state vars are consumed by sourced library functions
# tests/test_ssh.sh — Tests for lib/ssh.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs
detect_os

# --- Tests ---

test_ssh_host_block_format() {
    local block
    block=$(build_ssh_host_block "pro" "github.com")

    assert_contains "$block" "Host github-pro" "has Host line" &&
    assert_contains "$block" "HostName github.com" "has HostName" &&
    assert_contains "$block" "IdentityFile ${HOME}/.ssh/id_ed25519_pro" "has IdentityFile" &&
    assert_contains "$block" "IdentitiesOnly yes" "has IdentitiesOnly" &&
    assert_contains "$block" "[gitsetu:managed:start] pro" "has start marker" &&
    assert_contains "$block" "[gitsetu:managed:end] pro" "has end marker"
}

test_ssh_host_block_custom_host() {
    local block
    block=$(build_ssh_host_block "work" "gitlab.com")

    assert_contains "$block" "Host gitlab-work" "has Host with label" &&
    assert_contains "$block" "HostName gitlab.com" "has custom HostName"
}

test_generate_key_creates_files() {
    GITSETU_DRY_RUN=0
    generate_ssh_key "testkey" "test@example.com" 2>/dev/null

    assert_file_exists "$HOME/.ssh/id_ed25519_testkey" "private key created" &&
    assert_file_exists "$HOME/.ssh/id_ed25519_testkey.pub" "public key created"
}

test_generate_key_permissions() {
    # Windows/NTFS doesn't support Unix permissions — chmod 600 is a no-op
    if [[ "$GITSETU_OS" == "gitbash" ]]; then
        return 0  # Skip: permissions not enforceable on Windows
    fi

    # Key should already exist from previous test
    local key_path="$HOME/.ssh/id_ed25519_testkey"

    if [[ -f "$key_path" ]]; then
        local perms
        perms=$(stat -c '%a' "$key_path" 2>/dev/null || stat -f '%Lp' "$key_path" 2>/dev/null)
        assert_equals "600" "$perms" "private key is 600"
    else
        # Generate it
        GITSETU_DRY_RUN=0
        generate_ssh_key "testkey2" "test2@example.com" 2>/dev/null
        local perms
        perms=$(stat -c '%a' "$HOME/.ssh/id_ed25519_testkey2" 2>/dev/null || stat -f '%Lp' "$HOME/.ssh/id_ed25519_testkey2" 2>/dev/null)
        assert_equals "600" "$perms" "private key is 600"
    fi
}

test_generate_key_dry_run() {
    GITSETU_DRY_RUN=1
    generate_ssh_key "drykey" "dry@example.com" 2>/dev/null

    # File should NOT be created in dry run
    if [[ -f "$HOME/.ssh/id_ed25519_drykey" ]]; then
        printf '    FAIL: Key was created during dry run\n'
        return 1
    fi
    return 0
}

test_write_ssh_config_creates_file() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "pro")
    PROFILE_COUNT=2

    write_ssh_config 2>/dev/null

    assert_file_exists "$HOME/.ssh/config" "ssh config created" &&
    assert_file_contains "$HOME/.ssh/config" "Include $GITSETU_PROFILES_DIR/ssh_config" "has include directive" &&
    assert_file_exists "$GITSETU_PROFILES_DIR/ssh_config" "isolated config created" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-global" "has global host" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-pro" "has pro host"
}

test_write_ssh_config_idempotent() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "pro")
    PROFILE_COUNT=2

    write_ssh_config 2>/dev/null
    write_ssh_config 2>/dev/null

    # Count occurrences of "Include" — should be exactly 1
    local count
    count=$(grep -c "Include $GITSETU_PROFILES_DIR/ssh_config" "$HOME/.ssh/config")
    assert_equals "1" "$count" "no duplicate include directives after re-run"
}

test_write_ssh_config_preserves_user_content() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_COUNT=1

    # Add user content first
    printf 'Host my-custom-server\n    HostName 192.168.1.1\n    User admin\n\n' > "$HOME/.ssh/config"

    write_ssh_config 2>/dev/null

    assert_file_contains "$HOME/.ssh/config" "Host my-custom-server" "user content preserved" &&
    assert_file_contains "$HOME/.ssh/config" "Include $GITSETU_PROFILES_DIR/ssh_config" "include directive added"
}

test_generate_key_fido2_fallback() {
    GITSETU_DRY_RUN=0
    local key_path="$HOME/.ssh/id_ed25519_sk_fidotest"
    
    # We pass the _sk_ path, but since we are running headless without a hardware key,
    # the FIDO2 generation will fail ("device not found"), which should trigger our fallback
    # to generate a standard software key instead.
    
    local output
    output=$(generate_ssh_key "fidotest" "fido@example.com" "$key_path" 2>&1 || true)
    
    assert_contains "$output" "Falling back to standard ed25519" "triggers fallback gracefully" || return 1
    assert_file_exists "$key_path" "fallback key was generated at requested path" || return 1
}

# --- Run ---

printf '\n%btest_ssh.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "SSH host block has correct format" test_ssh_host_block_format
run_test "SSH host block uses custom hostname" test_ssh_host_block_custom_host
run_test "generate_ssh_key creates key files" test_generate_key_creates_files
run_test "generated key has 600 permissions" test_generate_key_permissions
run_test "dry run does not create keys" test_generate_key_dry_run
run_test "write_ssh_config creates config file" test_write_ssh_config_creates_file
run_test "write_ssh_config is idempotent" test_write_ssh_config_idempotent
run_test "write_ssh_config preserves user content" test_write_ssh_config_preserves_user_content
run_test "FIDO2 generates fallback software key" test_generate_key_fido2_fallback
print_results "SSH tests"
