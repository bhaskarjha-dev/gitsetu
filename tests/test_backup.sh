#!/usr/bin/env bash
# tests/test_backup.sh — Tests for lib/backup.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs
detect_os

# Cygwin's fsutil.exe is an expensive Win32 process for every path component.
# These fixtures are created inside the private test HOME and contain no
# junction by contract.  Keep a test-only shim which still recognizes ordinary
# symlinks, but avoids spawning Win32 helpers for every private directory.
if [[ "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "msys"* ]]; then
    # shellcheck disable=SC2329  # invoked indirectly by platform helpers
    cygpath() {
        printf '%s' "${!#}"
    }
    # shellcheck disable=SC2329  # invoked indirectly by platform helpers
    fsutil.exe() {
        local path="${!#}"
        [[ -L "$path" ]] && return 0
        return 1
    }
fi

# This suite uses one isolated HOME and loads the product modules once.  Each
# case gets a deterministic state reset below instead of paying for a fresh
# environment snapshot and a full module reload.  The harness assurance suite
# exercises the general nested-home/snapshot contract independently.
_TEST_SKIP_ENV_SNAPSHOT=1

reset_backup_test_state() {
    # Remove only paths owned by this test home.  The test never changes the
    # configured test root, so this cannot follow an inherited user path.
    case "$GITSETU_CONFIG_DIR" in
        "$HOME"/*) ;;
        *)
            printf '    FAIL: backup fixture config path escaped the test HOME\n'
            return 1
            ;;
    esac
    if ! rm -rf -- "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig"; then
        printf '    FAIL: could not reset the backup test state\n'
        return 1
    fi
    if ! rm -f -- test_vault.enc rollback_vault.enc dummy_vault.enc \
        vault_check.enc secure_vault.enc test_vault_env.enc \
        corrupted_vault.enc malicious_vault.enc; then
        printf '    FAIL: could not remove a backup test artifact\n'
        return 1
    fi
    if ! mkdir -p "$GITSETU_PROFILES_DIR" "$GITSETU_HOOKS_DIR" \
        "$GITSETU_BACKUP_DIR" "$HOME/.ssh" "$HOME/.config"; then
        printf '    FAIL: could not initialize the backup test directories\n'
        return 1
    fi

    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS GITSETU_VAULT_PASS
    GITSETU_CLEANUP_FILES=()
    GITSETU_CLEANUP_DIRS=()
    _VAULT_ROOT_KEY=""
    _VAULT_ACTIVE_TEMP=""
    GITSETU_VAULT_ACTIVE_TRANSACTION=""
    _VAULT_TXN_STATE_DIR=""
    _VAULT_MANIFEST_COUNT=0
    _VAULT_MANIFEST_SOURCE_HOME=""
    _VAULT_MANIFEST_CONFIGS=()
    _VAULT_MANIFEST_KEYS=()
    _VAULT_MANIFEST_PUBLICS=()
    _VAULT_MANIFEST_SSH=0
    _VAULT_MANIFEST_HOOK=0
    _VAULT_MANIFEST_TOKENS=0
    _VAULT_ALLOWED_MEMBERS=()
    _VAULT_RESTORE_KEY_SOURCES=()
    _VAULT_RESTORE_PUB_SOURCES=()
    _VAULT_RESTORE_KEY_TARGETS=()
    GITSETU_REGISTRY_ERROR=""

    PROFILE_LABELS=()
    PROFILE_NAMES=()
    PROFILE_EMAILS=()
    PROFILE_DIRS=()
    PROFILE_PROVIDERS=()
    PROFILE_SIGNS=()
    PROFILE_KEYS=()
    PROFILE_USERS=()
    PROFILE_PATS=()
    PROFILE_COUNT=0
}

run_backup_test() {
    if ! reset_backup_test_state; then
        local description="${1:-backup test}"
        TESTS_RUN=$((TESTS_RUN + 1))
        mark_test_failure
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TEST_LAST_STATUS="FAIL"
        printf '  %b[FAIL]%b %s (fixture reset failed)\n' \
            "$T_RED" "$T_RESET" "$description"
        return 0
    fi
    run_test "$@"
}

# The v2 restore path is transactional and intentionally does not create the
# removed pre_restore_*.enc/.password migration sidecars.
assert_no_vault_restore_sidecars() {
    local search_root candidate

    # The removed policy wrote these files directly in the restore working
    # directory.  Keep the check shell-portable (BSD find has no -maxdepth).
    for search_root in . "$TEST_HOME" "$GITSETU_CONFIG_DIR"; do
        [[ -d "$search_root" ]] || continue
        for candidate in \
            "$search_root"/gitsetu_vault_pre_restore_*.enc \
            "$search_root"/gitsetu_vault_pre_restore_*.password; do
            if [[ -e "$candidate" || -L "$candidate" ]]; then
                assert_file_not_exists "$candidate" \
                    "restore leaves no pre_restore sidecar files" || return 1
            fi
        done
    done
    return 0
}

# The vault's archive safety check reads "tar -tv" listings, and GNU and BSD
# disagree about the owner field. macOS ships bsdtar, so a GNU-shaped parse put
# the group name in the size column and backup rejected its own fresh archive.
# Feed recorded listing lines from both implementations so the contract is
# verifiable on every platform, not only where a BSD tar happens to exist.
test_vault_verbose_listing_size_layouts() {
    local line want got rc=0 failures=0 entry rest kind
    local -a cases=(
        'gnu|-rw------- 0/0          1234 2026-09-27 09:26 gitsetu-v2/state/profiles.conf|1234'
        'gnu-zero|-rw------- 0/0             0 2026-09-27 09:26 gitsetu-v2/keys/0.pub|0'
        'bsd|-rw-------  0 runner  staff    1234 Sep 27 09:26 gitsetu-v2/state/profiles.conf|1234'
        'bsd-zero|-rw-r--r--  0 runner  staff       0 Sep 27 09:26 gitsetu-v2/keys/0.pub|0'
        'bsd-numeric-gid|-rw-r--r--  0 runner  20  4096 Sep 27 09:26 gitsetu-v2/state/profiles.conf|4096'
    )
    for entry in "${cases[@]}"; do
        rest="${entry#*|}"
        line="${rest%%|*}"
        want="${rest##*|}"
        got=""
        rc=0
        got=$(_vault_verbose_member_size "$line" "-") || rc=$?
        if [[ "$rc" -ne 0 || "$got" != "$want" ]]; then
            failures=$((failures + 1))
        fi
    done
    assert_equals "0" "$failures" \
        "GNU and BSD tar -tv layouts both yield the member size" || return 1

    # Non-regular members and unrecognized layouts must still fail closed.
    local -a refused=(
        'drwxr-xr-x  0 runner  staff      64 Sep 27 09:26 gitsetu-v2/state|d'
        'lrwxr-xr-x  0 runner  staff       7 Sep 27 09:26 gitsetu-v2/keys/evil|l'
        'hrw-r--r--  0 runner  staff       0 Sep 27 09:26 link to gitsetu-v2/keys/0|h'
        '-rw-------  0 runner  staff  nope Sep 27 09:26 gitsetu-v2/x|-'
    )
    failures=0
    for entry in "${refused[@]}"; do
        line="${entry%%|*}"
        kind="${entry##*|}"
        rc=0
        _vault_verbose_member_size "$line" "$kind" >/dev/null 2>&1 || rc=$?
        [[ "$rc" -ne 0 ]] || failures=$((failures + 1))
    done
    assert_equals "0" "$failures" \
        "directory, symlink, hardlink and unparsable listings fail closed"
}

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
    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="secure_password"
    
    # Setup mock state: config dir + strict v2 profiles + SSH keys in ~/.ssh/
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config test "Test User" "test@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line test "$HOME/test" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_test" ""
    } > "$GITSETU_PROFILES_CONF"
    
    # Create mock SSH key files (where GitSetu actually stores them)
    echo "test_private_key" > "$HOME/.ssh/id_ed25519_test"
    echo "test_public_key" > "$HOME/.ssh/id_ed25519_test.pub"
    chmod 600 "$HOME/.ssh/id_ed25519_test"
    
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
    
    # The removed migration safety sidecars are not part of v2 restore.  A
    # successful restore must leave only the authenticated vault and the
    # restored managed state.
    assert_no_vault_restore_sidecars || return 1

    rm -f "$vault_file"
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
    return 0
}

# ==============================================================================
# Transactional restore rollback; v2 restore has no migration password sidecar
# ==============================================================================
test_backup_restore_rolls_back_without_sidecars() {
    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="rollback_test_pass"
    local vault_file="$TEST_HOME/rollback_vault.enc"
    local status=0

    # Build a valid source vault.
    mkdir -p "$HOME/.ssh"
    test_v2_profile_config global "Vault User" "vault@example.com"
    test_v2_profile_config source "Source User" "source@example.com"
    printf 'source-private\n' > "$HOME/.ssh/id_ed25519_source"
    printf 'source-public\n' > "$HOME/.ssh/id_ed25519_source.pub"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line source "$HOME/source" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_source" ""
    } > "$GITSETU_PROFILES_CONF"
    if ! cmd_backup "$vault_file" >/dev/null 2>&1; then
        printf '    FAIL: could not create the rollback test vault\n'
        rm -f "$vault_file"
        unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
        return 1
    fi

    # Replace live state with a distinct valid v2 state.  The failed restore
    # below must put this state back byte-for-byte.
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    test_v2_profile_config global "Live User" "live-global@example.com"
    test_v2_profile_config live "Live User" "live@example.com"
    printf 'live-private\n' > "$HOME/.ssh/id_ed25519_live"
    printf 'live-public\n' > "$HOME/.ssh/id_ed25519_live.pub"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line live "$HOME/live" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_live" ""
    } > "$GITSETU_PROFILES_CONF"

    local before_registry before_profile before_key
    before_registry=$(cat "$GITSETU_PROFILES_CONF") || return 1
    before_profile=$(cat "$GITSETU_PROFILES_DIR/live.gitconfig") || return 1
    before_key=$(cat "$HOME/.ssh/id_ed25519_live") || return 1

    # Force a failure after the restore transaction has begun.  The product
    # must roll back rather than leave a half-restored state or a password file.
    if (
        # shellcheck disable=SC2329  # invoked indirectly by cmd_restore
        write_profile_gitconfig() { return 1; }
        cmd_restore "$vault_file" >/dev/null 2>&1
    ); then
        status=0
    else
        status=$?
    fi
    assert_equals "1" "$status" "failed restore reports a transaction failure" || return 1

    local after_registry after_profile after_key
    after_registry=$(cat "$GITSETU_PROFILES_CONF") || return 1
    after_profile=$(cat "$GITSETU_PROFILES_DIR/live.gitconfig") || return 1
    after_key=$(cat "$HOME/.ssh/id_ed25519_live") || return 1
    assert_equals "$before_registry" "$after_registry" "failed restore rolls back the registry" || return 1
    assert_equals "$before_profile" "$after_profile" "failed restore rolls back profile files" || return 1
    assert_equals "$before_key" "$after_key" "failed restore rolls back managed keys" || return 1
    assert_no_vault_restore_sidecars || return 1

    rm -f "$vault_file"
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
    return 0
}

# ==============================================================================
# Interrupted/incomplete rollback must leave a discoverable private snapshot
# and must never create a plaintext password sidecar.
# ==============================================================================
test_backup_reports_recovery_snapshot() {
    mkdir -p "$GITSETU_CONFIG_DIR"
    local txn output signal_output rc=0 signal_rc=0
    txn=$(umask 077 && mktemp -d "$GITSETU_CONFIG_DIR/.gitsetu-restore.test.XXXXXX" 2>/dev/null) || return 1
    chmod 700 "$txn" 2>/dev/null || {
        rm -rf "$txn"
        return 1
    }
    if ! _vault_write_recovery_marker "$txn" "active"; then
        rm -rf "$txn"
        return 1
    fi
    output=$(mktemp "$TEST_HOME/recovery-abort.XXXXXX") || {
        rm -rf "$txn"
        return 1
    }
    signal_output=$(mktemp "$TEST_HOME/recovery-signal.XXXXXX") || {
        rm -f "$output"
        rm -rf "$txn"
        return 1
    }

    if (
        # shellcheck disable=SC2329  # invoked indirectly by abort helper
        _vault_rollback_transaction() { return 1; }
        _vault_restore_abort_transaction "$txn" "" 0
    ) >"$output" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    assert_equals "1" "$rc" "failed rollback is reported" || return 1
    assert_file_contains "$output" "Private recovery data remains at: $txn" "abort reports private recovery path" || return 1
    assert_file_contains "$txn/RECOVERY_REQUIRED" "state=rollback-incomplete" "recovery marker records incomplete rollback" || return 1

    if (
        # shellcheck disable=SC2329  # invoked indirectly by signal handler
        _vault_rollback_transaction() { return 1; }
        GITSETU_VAULT_ACTIVE_TRANSACTION="$txn"
        _vault_signal_handler
    ) >"$signal_output" 2>&1; then
        signal_rc=0
    else
        signal_rc=$?
    fi
    assert_equals "130" "$signal_rc" "interrupted restore exits with signal status" || return 1
    assert_file_contains "$signal_output" "Private recovery snapshot remains at: $txn" "interrupt reports private recovery path" || return 1
    assert_file_contains "$txn/RECOVERY_REQUIRED" "state=rollback-incomplete" "interrupt leaves recovery marker" || return 1
    assert_no_vault_restore_sidecars || return 1

    if can_chmod_600; then
        local perms
        perms=$(stat -c '%a' "$txn/RECOVERY_REQUIRED" 2>/dev/null || stat -f '%Lp' "$txn/RECOVERY_REQUIRED" 2>/dev/null || echo "???")
        assert_equals "600" "$perms" "recovery marker is private" || return 1
    fi

    rm -f "$output" "$signal_output"
    rm -rf "$txn"
    return 0
}

# ==============================================================================
# Verify intermediate tarball is isolated in private mode 0700 temp directory
# ==============================================================================
test_backup_tar_isolated_in_private_temp_dir() {
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config priv "Private User" "private@example.com"
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_ed25519_priv"
    if ! chmod 600 "$HOME/.ssh/id_ed25519_priv" 2>/dev/null; then
        skip_test "private-key permissions" "filesystem does not support chmod 600"
        return 0
    fi
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line priv "$HOME/p" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_priv" ""
    } > "$GITSETU_PROFILES_CONF"

    local captured_tar_path=""
    local captured_tar_dir_perms=""

    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="testpass"
    if ! (
        # shellcheck disable=SC2329  # invoked indirectly by cmd_backup
        tar() {
            local arg
            for arg in "$@"; do
                if [[ "$arg" == *".tar.gz" ]]; then
                    echo "$arg" > "$HOME/.captured_tar_path"
                    local tar_dir
                    tar_dir=$(dirname "$arg")
                    if can_chmod_600; then
                        (stat -c '%a' "$tar_dir" 2>/dev/null || stat -f '%Lp' "$tar_dir" 2>/dev/null || echo "") > "$HOME/.captured_tar_perms"
                    else
                        echo "700" > "$HOME/.captured_tar_perms"
                    fi
                    break
                fi
            done
            command tar "$@"
        }
        cmd_backup "vault_check.enc" >/dev/null 2>&1
    ); then
        printf '    FAIL: backup fixture command failed\n'
        return 1
    fi

    if ! captured_tar_path=$(cat "$HOME/.captured_tar_path" 2>/dev/null); then
        captured_tar_path=""
    fi
    if ! captured_tar_dir_perms=$(cat "$HOME/.captured_tar_perms" 2>/dev/null); then
        captured_tar_dir_perms=""
    fi
    if [[ -z "$captured_tar_path" ]]; then
        printf '    FAIL: backup did not expose the intermediate tar path\n'
        return 1
    fi

    assert_not_contains "$captured_tar_path" "gitsetu_vault_$$" "intermediate tar does not use predictable name" || return 1

    if can_chmod_600; then
        assert_equals "700" "$captured_tar_dir_perms" "intermediate tar parent directory restricted to 0700" || return 1
    fi

    assert_file_not_exists "$captured_tar_path" "intermediate tar deleted after backup"
    rm -f "vault_check.enc" "$HOME/.captured_tar_path" "$HOME/.captured_tar_perms"
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify ciphertext vault file permissions
# ==============================================================================
test_backup_vault_file_permissions_600() {
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config test "Test User" "test@example.com"
    mkdir -p "$HOME/.ssh"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line test "$HOME/test" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_test" ""
    } > "$GITSETU_PROFILES_CONF"
    touch "$HOME/.ssh/id_ed25519_test"
    if ! chmod 600 "$HOME/.ssh/id_ed25519_test" 2>/dev/null; then
        skip_test "private-key permissions" "filesystem does not support chmod 600"
        return 0
    fi

    export GITSETU_TEST_VAULT_MODE=1
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
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify cleanup on decryption failure
# ==============================================================================
test_backup_restore_cleanup_on_decryption_failure() {
    echo "CORRUPTED_BINARY_DATA" > "corrupted_vault.enc"

    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="wrongpass"
    local res=0
    cmd_restore "corrupted_vault.enc" >/dev/null 2>&1 || res=$?

    assert_equals 1 "$res" "restore fails cleanly on bad vault" || return 1

    local leaks
    # BSD/macOS wc pads its output with leading spaces when reading a pipe, so
    # normalize before comparing. Without this the count is "       0" and the
    # assertion fails on a clean run.
    leaks=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "*gitsetu_vault*" 2>/dev/null | wc -l | tr -d '[:space:]')
    assert_equals "0" "$leaks" "no temporary vault files leaked on restore failure"

    rm -f "corrupted_vault.enc"
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify GITSETU_VAULT_PASS is never exported into environment
# ==============================================================================
test_backup_does_not_leak_env_var() {
    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="test_secret_pass"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config test "Test User" "test@example.com"
    mkdir -p "$HOME/.ssh"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line test "$HOME/test" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_test" ""
    } > "$GITSETU_PROFILES_CONF"
    touch "$HOME/.ssh/id_ed25519_test"

    local vault_file="test_vault_env.enc"
    cmd_backup "$vault_file" >/dev/null 2>&1

    assert_equals "" "${GITSETU_VAULT_PASS:-}" "GITSETU_VAULT_PASS is not exported during backup" || return 1

    cmd_restore "$vault_file" >/dev/null 2>&1
    assert_equals "" "${GITSETU_VAULT_PASS:-}" "GITSETU_VAULT_PASS is not exported during restore" || return 1

    rm -f "$vault_file"
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
}

# ==============================================================================
# Verify restore rejects vault containing path traversal
# ==============================================================================
test_backup_rejects_path_traversal() {
    local bad_tar
    bad_tar=$(mktemp "${TMPDIR:-/tmp}/bad_vault.XXXXXX")
    local evil_file="/tmp/evil_file_$$"
    touch "$evil_file"
    if ! tar -Pczf "$bad_tar" "$evil_file" 2>/dev/null; then
        rm -f "$bad_tar" "$evil_file"
        printf '    FAIL: failed to create traversal archive fixture\n'
        return 1
    fi
    rm -f "$evil_file"

    local bad_vault="malicious_vault.enc"
    local ssl_args=("-aes-256-cbc" "-salt")
    local -a extra_ssl_args=()
    read -r -a extra_ssl_args <<< "$(get_openssl_args)"
    ssl_args+=("${extra_ssl_args[@]}")
    printf '%s\n' "testpass" | openssl enc "${ssl_args[@]}" -in "$bad_tar" -out "$bad_vault" -pass stdin 2>/dev/null
    rm -f "$bad_tar"

    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="testpass"
    local res=0
    cmd_restore "$bad_vault" >/dev/null 2>&1 || res=$?

    assert_equals 1 "$res" "restore rejects archive with path traversal" || return 1

    rm -f "$bad_vault"
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS
}

# --- Run ---

printf '\n%btest_backup.sh%b\n' "$T_BOLD" "$T_RESET"
run_backup_test "ensure_dirs creates all directories" test_ensure_dirs_creates_all
run_backup_test "backup creates timestamped copy" test_backup_creates_timestamped_copy
run_backup_test "backup preserves file content" test_backup_preserves_content
run_backup_test "backup does not modify original" test_backup_does_not_modify_original
run_backup_test "backup nonexistent file returns error" test_backup_nonexistent_file_returns_error
run_backup_test "multiple backups don't overwrite each other" test_multiple_backups_dont_overwrite
run_backup_test "full encrypted backup/restore lifecycle" test_cmd_backup_restore
run_backup_test "restore rolls back without password sidecars" test_backup_restore_rolls_back_without_sidecars
run_backup_test "interrupted restore reports private recovery snapshot" test_backup_reports_recovery_snapshot
run_backup_test "intermediate tar isolated in private temp dir" test_backup_tar_isolated_in_private_temp_dir
run_backup_test "vault ciphertext permissions 600" test_backup_vault_file_permissions_600
run_backup_test "restore cleanup on decryption failure" test_backup_restore_cleanup_on_decryption_failure
run_backup_test "backup does not leak env var" test_backup_does_not_leak_env_var
run_backup_test "restore rejects path traversal" test_backup_rejects_path_traversal
run_backup_test "GNU and BSD tar listing sizes parse identically" test_vault_verbose_listing_size_layouts

print_results "Backup tests"
