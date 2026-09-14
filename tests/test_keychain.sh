#!/usr/bin/env bash
# tests/test_keychain.sh — Unit tests for lib/keychain.sh file-fallback paths
#
# Tests the local file-based credential storage (.tokens) which is used
# when OS-native keychains (macOS security / Linux secret-tool) are unavailable.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

# Force OS to unknown so all tests use the file fallback
GITSETU_OS="unknown"

# Helper: sets up a clean test environment with the config dir
_keychain_setup() {
    setup_test_home
    source_gitsetu_libs
    GITSETU_OS="unknown"
    # keychain_store expects the config dir to exist (ensure_dirs creates it in production)
    mkdir -p "$HOME/.config/gitsetu"
}

# ==============================================================================
# Store and retrieve
# ==============================================================================
test_keychain_store_and_get() {
    _keychain_setup

    keychain_store "work" "github.com" "myuser" "secret123"

    local output
    output=$(keychain_get "work" "github.com")

    assert_contains "$output" "username=myuser" "username returned" &&
    assert_contains "$output" "password=secret123" "password returned"
}

# ==============================================================================
# Store overwrites existing entry
# ==============================================================================
test_keychain_store_overwrites() {
    _keychain_setup

    keychain_store "work" "github.com" "myuser" "old_pass"
    keychain_store "work" "github.com" "myuser" "new_pass"

    local output
    output=$(keychain_get "work" "github.com")

    assert_contains "$output" "password=new_pass" "new password returned" &&
    assert_not_contains "$output" "old_pass" "old password gone"

    # Verify only one entry in file
    local count
    count=$(grep -c "gitsetu:work:github.com" "$HOME/.config/gitsetu/.tokens" 2>/dev/null || echo "0")
    assert_equals "1" "$count" "only one entry in tokens file"
}

# ==============================================================================
# Get returns empty for nonexistent entry
# ==============================================================================
test_keychain_get_nonexistent() {
    _keychain_setup

    local result=0
    keychain_get "nonexistent" "github.com" || result=$?

    assert_equals 1 "$result" "returns 1 for missing entry"
}

# ==============================================================================
# Erase removes entry
# ==============================================================================
test_keychain_erase() {
    _keychain_setup

    keychain_store "work" "github.com" "myuser" "secret123"
    keychain_erase "work" "github.com"

    local result=0
    keychain_get "work" "github.com" || result=$?

    assert_equals 1 "$result" "returns 1 after erase"
}

# ==============================================================================
# Multiple profiles isolated
# ==============================================================================
test_keychain_profile_isolation() {
    _keychain_setup

    keychain_store "work" "github.com" "workuser" "workpass"
    keychain_store "personal" "github.com" "personaluser" "personalpass"

    local work_out personal_out
    work_out=$(keychain_get "work" "github.com")
    personal_out=$(keychain_get "personal" "github.com")

    assert_contains "$work_out" "username=workuser" "work user correct" &&
    assert_contains "$work_out" "password=workpass" "work pass correct" &&
    assert_contains "$personal_out" "username=personaluser" "personal user correct" &&
    assert_contains "$personal_out" "password=personalpass" "personal pass correct"
}

# ==============================================================================
# Erase one profile doesn't affect another
# ==============================================================================
test_keychain_erase_isolation() {
    _keychain_setup

    keychain_store "work" "github.com" "wuser" "wpass"
    keychain_store "oss" "github.com" "ouser" "opass"

    keychain_erase "work" "github.com"

    local result=0
    keychain_get "work" "github.com" || result=$?
    assert_equals 1 "$result" "work entry gone" || return 1

    local oss_out
    oss_out=$(keychain_get "oss" "github.com")
    assert_contains "$oss_out" "username=ouser" "oss entry still exists"
}

# ==============================================================================
# Tokens file permissions
# ==============================================================================
test_keychain_file_permissions() {
    _keychain_setup

    keychain_store "work" "github.com" "user" "pass"

    local tokens_file="$HOME/.config/gitsetu/.tokens"
    assert_file_exists "$tokens_file" "tokens file created" || return 1

    # Skip numeric assertion on filesystems that ignore chmod (CI containers, VM mounts)
    can_chmod_600 || return 0

    local perms
    perms=$(stat -c '%a' "$tokens_file" 2>/dev/null || stat -f '%Lp' "$tokens_file" 2>/dev/null || echo "???")
    assert_equals "600" "$perms" "tokens file has 600 permissions"
}

# ==============================================================================
# Verify permissions from inception (umask 077 even if chmod is mocked)
# ==============================================================================
test_keychain_tokens_permissions_from_inception() {
    _keychain_setup
    local tokens_file="$HOME/.config/gitsetu/.tokens"
    rm -f "$tokens_file"

    # Execute in a subshell where chmod is mocked to a no-op and umask is permissive (0000)
    (
        chmod() {
            echo "CHMOD_CALLED:$*" >> "$HOME/.chmod_calls"
            return 0
        }
        chmod "$tokens_file" >/dev/null 2>&1 || true
        export -f chmod 2>/dev/null || true
        umask 0000

        keychain_store "prod" "github.com" "deploy_user" "secret_token_123"
    )

    assert_file_exists "$tokens_file" "tokens file created" || return 1

    # On POSIX systems, verify file mode is 600 despite chmod being a no-op
    if can_chmod_600; then
        local perms
        perms=$(stat -c '%a' "$tokens_file" 2>/dev/null || stat -f '%Lp' "$tokens_file" 2>/dev/null || echo "???")
        assert_equals "600" "$perms" "tokens file is born with 600 perms (umask 077 enforced at inception)" || return 1
    fi

    # Verify content is intact
    local output
    output=$(keychain_get "prod" "github.com")
    assert_contains "$output" "password=secret_token_123" "credential stored properly"
}

# ==============================================================================
# Verify permissions maintained after keychain_erase
# ==============================================================================
test_keychain_erase_maintains_600_permissions() {
    _keychain_setup
    local tokens_file="$HOME/.config/gitsetu/.tokens"

    # Store two credentials
    keychain_store "profile1" "github.com" "user1" "pass1"
    keychain_store "profile2" "github.com" "user2" "pass2"

    # Erase profile1
    keychain_erase "profile1" "github.com"

    assert_file_exists "$tokens_file" "tokens file still exists after partial erase" || return 1

    # Verify profile1 is gone, profile2 remains
    local result=0
    keychain_get "profile1" "github.com" || result=$?
    assert_equals 1 "$result" "profile1 erased" || return 1

    local p2_out
    p2_out=$(keychain_get "profile2" "github.com")
    assert_contains "$p2_out" "password=pass2" "profile2 retained" || return 1

    # Check permissions on POSIX
    if can_chmod_600; then
        local perms
        perms=$(stat -c '%a' "$tokens_file" 2>/dev/null || stat -f '%Lp' "$tokens_file" 2>/dev/null || echo "???")
        assert_equals "600" "$perms" "tokens file retains 600 permissions after keychain_erase" || return 1
    fi
}

# ==============================================================================
# Verify no predictable temp files in /tmp
# ==============================================================================
test_keychain_no_tmp_predictable_files() {
    _keychain_setup
    local initial_tmp_count
    initial_tmp_count=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "*gitsetu_tokens_*" 2>/dev/null | wc -l)

    keychain_store "work" "github.com" "user" "token"
    keychain_erase "work" "github.com"

    local final_tmp_count
    final_tmp_count=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "*gitsetu_tokens_*" 2>/dev/null | wc -l)

    assert_equals "$initial_tmp_count" "$final_tmp_count" "no predictable tokens temp files created in /tmp"
}

# ==============================================================================
# Run
# ==============================================================================
printf '\n%btest_keychain.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "store and retrieve credential" test_keychain_store_and_get
run_test "store overwrites existing entry" test_keychain_store_overwrites
run_test "get nonexistent returns error" test_keychain_get_nonexistent
run_test "erase removes credential" test_keychain_erase
run_test "profiles are isolated" test_keychain_profile_isolation
run_test "erase one doesn't affect another" test_keychain_erase_isolation
run_test "tokens file has 600 permissions" test_keychain_file_permissions
run_test "tokens file permissions from inception" test_keychain_tokens_permissions_from_inception
run_test "erase maintains 600 permissions" test_keychain_erase_maintains_600_permissions
run_test "no predictable tokens temp files in /tmp" test_keychain_no_tmp_predictable_files
print_results "Keychain tests"
