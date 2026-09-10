#!/usr/bin/env bash
# tests/test_verify.sh — Unit tests for lib/verify.sh
#
# Tests SSH key verification, git config verification, and the summary table.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

# ==============================================================================
# verify_ssh_keys — all keys present and correct
# ==============================================================================
test_verify_ssh_keys_all_ok() {
    setup_test_home
    source_gitsetu_libs
    GITSETU_DRY_RUN=0

    # Skip on filesystems that ignore chmod (CI containers, VM mounts)
    can_chmod_600 || return 0

    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_work"
    chmod 600 "$HOME/.ssh/id_ed25519_work"
    touch "$HOME/.ssh/id_ed25519_work.pub"

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_work")

    local issues=0
    verify_ssh_keys 2>/dev/null || issues=$?

    assert_equals 0 "$issues" "no issues when key exists with 600 perms"
}

# ==============================================================================
# verify_ssh_keys — missing private key
# ==============================================================================
test_verify_ssh_keys_missing_private() {
    setup_test_home
    source_gitsetu_libs

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_work")

    # Don't create the key
    local issues=0
    verify_ssh_keys 2>/dev/null || issues=$?

    if [[ "$issues" -gt 0 ]]; then
        return 0
    fi
    printf '    FAIL: expected issues for missing key\n'
    return 1
}

# ==============================================================================
# verify_ssh_keys — missing public key
# ==============================================================================
test_verify_ssh_keys_missing_public() {
    setup_test_home
    source_gitsetu_libs

    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_work"
    chmod 600 "$HOME/.ssh/id_ed25519_work"
    # Don't create .pub

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_work")

    local issues=0
    verify_ssh_keys 2>/dev/null || issues=$?

    if [[ "$issues" -gt 0 ]]; then
        return 0
    fi
    printf '    FAIL: expected issues for missing public key\n'
    return 1
}

# ==============================================================================
# verify_ssh_keys — wrong permissions
# ==============================================================================
test_verify_ssh_keys_wrong_perms() {
    setup_test_home
    source_gitsetu_libs

    # Skip on filesystems that ignore chmod (NTFS emulation, VM mounts)
    can_chmod_600 || return 0

    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_work"
    chmod 644 "$HOME/.ssh/id_ed25519_work"
    touch "$HOME/.ssh/id_ed25519_work.pub"

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_work")

    local issues=0
    verify_ssh_keys 2>/dev/null || issues=$?

    if [[ "$issues" -gt 0 ]]; then
        return 0
    fi
    printf '    FAIL: expected issues for wrong permissions (644)\n'
    return 1
}

# ==============================================================================
# verify_git_config — detects missing global gitconfig
# ==============================================================================
test_verify_git_config_no_global() {
    setup_test_home
    source_gitsetu_libs

    PROFILE_COUNT=0

    local result=0
    verify_git_config 2>/dev/null || result=$?

    if [[ "$result" -gt 0 ]]; then
        return 0
    fi
    printf '    FAIL: expected failure for missing ~/.gitconfig\n'
    return 1
}

# ==============================================================================
# verify_git_config — detects missing profile config
# ==============================================================================
test_verify_git_config_missing_profile() {
    setup_test_home
    source_gitsetu_libs

    # Create global config
    touch "$HOME/.gitconfig"

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_EMAILS=("work@test.com")
    PROFILE_DIRS=("")

    local issues=0
    verify_git_config 2>/dev/null || issues=$?

    if [[ "$issues" -gt 0 ]]; then
        return 0
    fi
    printf '    FAIL: expected issues for missing profile config\n'
    return 1
}

# ==============================================================================
# verify_git_config — all good
# ==============================================================================
test_verify_git_config_all_ok() {
    setup_test_home
    source_gitsetu_libs

    touch "$HOME/.gitconfig"
    mkdir -p "$GITSETU_PROFILES_DIR"
    cat > "$GITSETU_PROFILES_DIR/work.gitconfig" <<EOF
[user]
    name = Test
    email = work@test.com
EOF

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_EMAILS=("work@test.com")
    PROFILE_DIRS=("")

    local issues=0
    verify_git_config 2>/dev/null || issues=$?

    assert_equals 0 "$issues" "no issues when profile config exists"
}

# ==============================================================================
# verify_all — outputs exclusively to stderr
# ==============================================================================
test_verify_all_stderr_only() {
    setup_test_home
    source_gitsetu_libs

    # Skip on filesystems that ignore chmod (verify_ssh_keys checks perms)
    can_chmod_600 || return 0

    mkdir -p "$HOME/.ssh" "$GITSETU_PROFILES_DIR"
    touch "$HOME/.gitconfig"

    # Create a minimal profile
    touch "$HOME/.ssh/id_ed25519_work"
    chmod 600 "$HOME/.ssh/id_ed25519_work"
    touch "$HOME/.ssh/id_ed25519_work.pub"
    cat > "$GITSETU_PROFILES_DIR/work.gitconfig" <<EOF
[user]
    name = Test
    email = work@test.com
EOF

    PROFILE_COUNT=1
    PROFILE_LABELS=("work")
    PROFILE_EMAILS=("work@test.com")
    PROFILE_DIRS=("")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_work")
    PROFILE_PROVIDERS=("github.com")

    # Capture stdout only — it should be empty
    local stdout_output
    stdout_output=$(verify_all 2>/dev/null) || true

    assert_equals "" "$stdout_output" "verify_all produces zero stdout"
}

# ==============================================================================
# Run
# ==============================================================================
printf '\n%btest_verify.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "verify_ssh_keys: all keys OK" test_verify_ssh_keys_all_ok
run_test "verify_ssh_keys: missing private key" test_verify_ssh_keys_missing_private
run_test "verify_ssh_keys: missing public key" test_verify_ssh_keys_missing_public
run_test "verify_ssh_keys: wrong permissions" test_verify_ssh_keys_wrong_perms
run_test "verify_git_config: missing global" test_verify_git_config_no_global
run_test "verify_git_config: missing profile config" test_verify_git_config_missing_profile
run_test "verify_git_config: all OK" test_verify_git_config_all_ok
run_test "verify_all: stderr only" test_verify_all_stderr_only
print_results "Verify tests"
