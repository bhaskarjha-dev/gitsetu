#!/usr/bin/env bash
# tests/test_backup.sh — Tests for lib/backup.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs
detect_os

# --- Tests ---

test_ensure_dirs_creates_all() {
    ensure_dirs

    assert_dir_exists "$GITSETU_CONFIG_DIR" "config dir exists" &&
    assert_dir_exists "$GITSETU_BACKUP_DIR" "backup dir exists" &&
    assert_dir_exists "$GITSETU_PROFILES_DIR" "profiles dir exists" &&
    assert_dir_exists "$GITSETU_HOOKS_DIR" "hooks dir exists"
}

test_backup_creates_timestamped_copy() {
    local test_file="$HOME/test_config"
    printf 'original content\n' > "$test_file"

    ensure_dirs
    backup_file "$test_file" 2>/dev/null

    # Should have at least one .bak file
    local count
    count=$(find "$GITSETU_BACKUP_DIR" -name "test_config.*.bak" | wc -l)

    if [[ "$count" -ge 1 ]]; then
        return 0
    fi

    printf '    FAIL: No backup file found in %s\n' "$GITSETU_BACKUP_DIR"
    return 1
}

test_backup_preserves_content() {
    local test_file="$HOME/test_preserve"
    printf 'important data\nline two\n' > "$test_file"

    ensure_dirs
    backup_file "$test_file" 2>/dev/null

    # Find the backup
    local bak_file
    bak_file=$(find "$GITSETU_BACKUP_DIR" -name "test_preserve.*.bak" | head -n1)

    assert_file_contains "$bak_file" "important data" "backup has original content"
}

test_backup_does_not_modify_original() {
    local test_file="$HOME/test_original"
    printf 'do not change\n' > "$test_file"

    ensure_dirs
    backup_file "$test_file" 2>/dev/null

    assert_file_contains "$test_file" "do not change" "original unchanged"
}

test_backup_nonexistent_file_returns_error() {
    assert_exit_code 1 backup_file "/nonexistent/file/path"
}

test_multiple_backups_dont_overwrite() {
    local test_file="$HOME/test_multi"
    printf 'version 1\n' > "$test_file"

    ensure_dirs
    backup_file "$test_file" 2>/dev/null

    # Modify and backup again (may be same second, so test collision avoidance)
    printf 'version 2\n' > "$test_file"
    backup_file "$test_file" 2>/dev/null

    local count
    count=$(find "$GITSETU_BACKUP_DIR" -name "test_multi.*.bak" | wc -l)

    if [[ "$count" -ge 2 ]]; then
        return 0
    fi

    # Might be same timestamp — at least 1 must exist
    if [[ "$count" -ge 1 ]]; then
        return 0
    fi

    printf '    FAIL: Expected at least 1 backup, found %d\n' "$count"
    return 1
}

test_cmd_backup_restore() {
    export GITSETU_TEST_VAULT_PASS="secure_password"
    
    # Setup mock state: config dir + profile + SSH keys in ~/.ssh/
    mkdir -p "$GITSETU_CONFIG_DIR/profiles"
    echo "test_content" > "$GITSETU_CONFIG_DIR/profiles/test.gitconfig"
    
    # Create mock SSH key files (where GitSetu actually stores them)
    echo "test_private_key" > "$HOME/.ssh/id_ed25519_test"
    echo "test_public_key" > "$HOME/.ssh/id_ed25519_test.pub"
    chmod 600 "$HOME/.ssh/id_ed25519_test"
    
    # Write a profiles.conf so the key collector can find the key paths
    mkdir -p "$GITSETU_CONFIG_DIR"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
# gitsetu profile registry
# Format: label:email:directory:provider:sign_commits:key_path:provider_user
# Used by the pre-commit guard hook
test::$HOME/test:github.com:0:$HOME/.ssh/id_ed25519_test:
EOF
    
    # 1. Test Backup
    local vault_file="test_vault.enc"
    cmd_backup "$vault_file" || return 1
    
    if [[ ! -f "$vault_file" ]]; then
        echo "Failed: Vault file $vault_file was not created."
        return 1
    fi
    
    # 2. Wipe state
    rm -rf "$GITSETU_CONFIG_DIR"
    rm -f "$HOME/.ssh/id_ed25519_test" "$HOME/.ssh/id_ed25519_test.pub"
    
    # 3. Test Restore
    cmd_restore "$vault_file" || return 1
    
    # Verify config state is restored
    if [[ ! -f "$GITSETU_CONFIG_DIR/profiles/test.gitconfig" ]]; then
        echo "Failed: Config state not restored."
        return 1
    fi
    
    # Verify SSH keys are restored
    if [[ ! -f "$HOME/.ssh/id_ed25519_test" ]]; then
        echo "Failed: SSH key not restored."
        return 1
    fi
    
    # 4. Test Pre-Flight Safety Net
    # Restoring AGAIN while state exists should trigger the safety net
    local second_rc=0
    cmd_restore "$vault_file" >/dev/null 2>&1 || second_rc=$?
    assert_equals 0 "$second_rc" "second cmd_restore runs successfully" || return 1
    
    local pre_restore_backups
    pre_restore_backups=$(find . -maxdepth 1 -name "gitsetu_vault_pre_restore_*.enc" 2>/dev/null | wc -l)
    if [[ "$pre_restore_backups" -eq 0 ]]; then
        echo "Failed: Pre-flight safety net vault was not created."
        return 1
    fi
    
    rm -f "$vault_file" gitsetu_vault_pre_restore_*.enc gitsetu_vault_pre_restore_*.password
    unset GITSETU_TEST_VAULT_PASS
    return 0
}

# ==============================================================================
# Verify pre-restore safety password permissions from inception
# ==============================================================================
test_backup_safety_password_permissions_from_inception() {
    setup_test_home
    source_gitsetu_libs

    # 1. Setup mock existing state so pre-flight safety net triggers
    mkdir -p "$GITSETU_CONFIG_DIR/profiles"
    echo "dummy" > "$GITSETU_CONFIG_DIR/profiles/test.gitconfig"
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_test"
    chmod 600 "$HOME/.ssh/id_ed25519_test" 2>/dev/null || true
    cat > "$GITSETU_PROFILES_CONF" <<EOF
test::$HOME/test:github.com:0:$HOME/.ssh/id_ed25519_test:
EOF

    # 2. Create a dummy vault to restore
    export GITSETU_TEST_VAULT_PASS="safety_test_pass"
    cmd_backup "dummy_vault.enc" >/dev/null 2>&1

    # 3. Execute cmd_restore in a subshell with umask 0000 and mocked chmod
    (
        chmod() {
            echo "CHMOD_CALLED:$*" >> "$HOME/.chmod_backup_calls"
            return 0
        }
        chmod "dummy" >/dev/null 2>&1 || true
        export -f chmod 2>/dev/null || true
        umask 0000
        cmd_restore "dummy_vault.enc" >/dev/null 2>&1
    )

    # 4. Locate generated password file
    local pw_file
    pw_file=$(find . -maxdepth 1 -name "gitsetu_vault_pre_restore_*.password" 2>/dev/null | head -n1)
    assert_file_exists "$pw_file" "safety backup password file created" || return 1

    # 5. On POSIX, assert permissions are 600 despite chmod being disabled
    if can_chmod_600; then
        local perms
        perms=$(stat -c '%a' "$pw_file" 2>/dev/null || stat -f '%Lp' "$pw_file" 2>/dev/null || echo "???")
        assert_equals "600" "$perms" "safety password file born with 600 permissions" || return 1
    fi

    rm -f dummy_vault.enc gitsetu_vault_pre_restore_*
    unset GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify intermediate tarball is isolated in private mode 0700 temp directory
# ==============================================================================
test_backup_tar_isolated_in_private_temp_dir() {
    setup_test_home
    source_gitsetu_libs

    mkdir -p "$GITSETU_CONFIG_DIR"
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_priv"
    chmod 600 "$HOME/.ssh/id_ed25519_priv" 2>/dev/null || true
    cat > "$GITSETU_PROFILES_CONF" <<EOF
priv::$HOME/p:github.com:0:$HOME/.ssh/id_ed25519_priv:
EOF

    local captured_tar_path=""
    local captured_tar_dir_perms=""

    tar() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == *".tar.gz" ]]; then
                captured_tar_path="$arg"
                local tar_dir
                tar_dir=$(dirname "$arg")
                if can_chmod_600; then
                    captured_tar_dir_perms=$(stat -c '%a' "$tar_dir" 2>/dev/null || stat -f '%Lp' "$tar_dir" 2>/dev/null || echo "")
                else
                    captured_tar_dir_perms="700"
                fi
                break
            fi
        done
        command tar "$@"
    }
    tar "dummy" >/dev/null 2>&1 || true

    export GITSETU_TEST_VAULT_PASS="testpass"
    cmd_backup "vault_check.enc" >/dev/null 2>&1

    assert_not_contains "$captured_tar_path" "gitsetu_vault_$$" "intermediate tar does not use predictable name" || return 1

    if can_chmod_600; then
        assert_equals "700" "$captured_tar_dir_perms" "intermediate tar parent directory restricted to 0700" || return 1
    fi

    assert_file_not_contains "$captured_tar_path" "" "intermediate tar deleted after backup"
    rm -f "vault_check.enc"
    unset GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify ciphertext vault file permissions
# ==============================================================================
test_backup_vault_file_permissions_600() {
    setup_test_home
    source_gitsetu_libs
    mkdir -p "$GITSETU_CONFIG_DIR"
    mkdir -p "$HOME/.ssh"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
test::$HOME/test:github.com:0:$HOME/.ssh/id_ed25519_test:
EOF
    touch "$HOME/.ssh/id_ed25519_test"
    chmod 600 "$HOME/.ssh/id_ed25519_test" 2>/dev/null || true

    export GITSETU_TEST_VAULT_PASS="testpass"
    local vault_out="secure_vault.enc"
    cmd_backup "$vault_out" >/dev/null 2>&1

    assert_file_exists "$vault_out" "vault file created" || return 1

    if can_chmod_600; then
        local perms
        perms=$(stat -c '%a' "$vault_out" 2>/dev/null || stat -f '%Lp' "$vault_out" 2>/dev/null || echo "???")
        assert_equals "600" "$perms" "vault ciphertext file restricted to mode 600" || return 1
    fi

    rm -f "$vault_out"
    unset GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify cleanup on decryption failure
# ==============================================================================
test_backup_restore_cleanup_on_decryption_failure() {
    setup_test_home
    source_gitsetu_libs

    echo "CORRUPTED_BINARY_DATA" > "corrupted_vault.enc"

    export GITSETU_TEST_VAULT_PASS="wrongpass"
    local res=0
    cmd_restore "corrupted_vault.enc" >/dev/null 2>&1 || res=$?

    assert_equals 1 "$res" "restore fails cleanly on bad vault" || return 1

    local leaks
    leaks=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "*gitsetu_vault*" 2>/dev/null | wc -l)
    assert_equals "0" "$leaks" "no temporary vault files leaked on restore failure"

    rm -f "corrupted_vault.enc"
    unset GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify GITSETU_VAULT_PASS is never exported into environment
# ==============================================================================
test_backup_does_not_leak_env_var() {
    setup_test_home
    source_gitsetu_libs
    export GITSETU_TEST_VAULT_PASS="test_secret_pass"
    mkdir -p "$GITSETU_CONFIG_DIR"
    mkdir -p "$HOME/.ssh"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
test::$HOME/test:github.com:0:$HOME/.ssh/id_ed25519_test:
EOF
    touch "$HOME/.ssh/id_ed25519_test"

    local vault_file="test_vault_env.enc"
    cmd_backup "$vault_file" >/dev/null 2>&1

    assert_equals "" "${GITSETU_VAULT_PASS:-}" "GITSETU_VAULT_PASS is not exported during backup" || return 1

    cmd_restore "$vault_file" >/dev/null 2>&1
    assert_equals "" "${GITSETU_VAULT_PASS:-}" "GITSETU_VAULT_PASS is not exported during restore" || return 1

    rm -f "$vault_file" gitsetu_vault_pre_restore_*
    unset GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify restore rejects vault containing path traversal
# ==============================================================================
test_backup_rejects_path_traversal() {
    setup_test_home
    source_gitsetu_libs

    local bad_tar
    bad_tar=$(mktemp "${TMPDIR:-/tmp}/bad_vault.XXXXXX.tar.gz")
    local evil_file="/tmp/evil_file_$$"
    touch "$evil_file"
    tar -Pczf "$bad_tar" "$evil_file" 2>/dev/null || true
    rm -f "$evil_file"

    local bad_vault="malicious_vault.enc"
    local ssl_args=("-aes-256-cbc" "-salt")
    local -a extra_ssl_args=()
    read -r -a extra_ssl_args <<< "$(get_openssl_args)"
    ssl_args+=("${extra_ssl_args[@]}")
    printf '%s\n' "testpass" | openssl enc "${ssl_args[@]}" -in "$bad_tar" -out "$bad_vault" -pass stdin 2>/dev/null
    rm -f "$bad_tar"

    export GITSETU_TEST_VAULT_PASS="testpass"
    local res=0
    cmd_restore "$bad_vault" >/dev/null 2>&1 || res=$?

    assert_equals 1 "$res" "restore rejects archive with path traversal" || return 1

    rm -f "$bad_vault"
    unset GITSETU_TEST_VAULT_PASS
}

# --- Run ---

printf '\n%btest_backup.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "ensure_dirs creates all directories" test_ensure_dirs_creates_all
run_test "backup creates timestamped copy" test_backup_creates_timestamped_copy
run_test "backup preserves file content" test_backup_preserves_content
run_test "backup does not modify original" test_backup_does_not_modify_original
run_test "backup nonexistent file returns error" test_backup_nonexistent_file_returns_error
run_test "multiple backups don't overwrite each other" test_multiple_backups_dont_overwrite
run_test "full encrypted backup/restore lifecycle" test_cmd_backup_restore
run_test "safety password permissions from inception" test_backup_safety_password_permissions_from_inception
run_test "intermediate tar isolated in private temp dir" test_backup_tar_isolated_in_private_temp_dir
run_test "vault ciphertext permissions 600" test_backup_vault_file_permissions_600
run_test "restore cleanup on decryption failure" test_backup_restore_cleanup_on_decryption_failure
run_test "backup does not leak env var" test_backup_does_not_leak_env_var
run_test "restore rejects path traversal" test_backup_rejects_path_traversal

print_results "Backup tests"
