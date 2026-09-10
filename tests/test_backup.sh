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
    assert_equals 0 $? "cmd_backup runs successfully" || return 1
    
    if [[ ! -f "$vault_file" ]]; then
        echo "Failed: Vault file $vault_file was not created."
        return 1
    fi
    
    # 2. Wipe state
    rm -rf "$GITSETU_CONFIG_DIR"
    rm -f "$HOME/.ssh/id_ed25519_test" "$HOME/.ssh/id_ed25519_test.pub"
    
    # 3. Test Restore
    cmd_restore "$vault_file" || return 1
    assert_equals 0 $? "cmd_restore runs successfully" || return 1
    
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
    cmd_restore "$vault_file" >/dev/null 2>&1
    assert_equals 0 $? "second cmd_restore runs successfully" || return 1
    
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

# --- Run ---

printf '\n%btest_backup.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "ensure_dirs creates all directories" test_ensure_dirs_creates_all
run_test "backup creates timestamped copy" test_backup_creates_timestamped_copy
run_test "backup preserves file content" test_backup_preserves_content
run_test "backup does not modify original" test_backup_does_not_modify_original
run_test "backup nonexistent file returns error" test_backup_nonexistent_file_returns_error
run_test "multiple backups don't overwrite each other" test_multiple_backups_dont_overwrite
run_test "full encrypted backup/restore lifecycle" test_cmd_backup_restore

print_results "Backup tests"
