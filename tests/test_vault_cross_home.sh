#!/usr/bin/env bash
# Hermetic cross-HOME vault migration, collision, preservation, and rollback tests.
# All identities and token/key values are disposable fixtures, never real secrets.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

# HOME and XDG are deliberately switched between cases. Explicit activation and
# fixture resets below replace per-test environment snapshot restoration.
_TEST_SKIP_ENV_SNAPSHOT=1

_CROSS_ROOT="$TEST_HOME/vault-cross-home"
_CROSS_A_HOME="$_CROSS_ROOT/home-a"
_CROSS_A_XDG="$_CROSS_ROOT/xdg-a"
_CROSS_B_HOME="$_CROSS_ROOT/home-b"
_CROSS_B_XDG="$_CROSS_ROOT/xdg-b"
_CROSS_ARTIFACTS="$_CROSS_ROOT/artifacts"
_CROSS_VAULT="$_CROSS_ARTIFACTS/home-a.gitsetu-v2.vault"
_CROSS_VAULT_PASSWORD='fixture-only-cross-home-password'
_CROSS_SOURCE_PRIVATE='disposable-private-A'
_CROSS_SOURCE_PUBLIC='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICROSSFIXTURE source@example.invalid'
_CROSS_SOURCE_TOKEN='fixture-token-A-not-a-secret'

_cross_activate_home() {
    local role="${1:-}"
    local home="" xdg=""
    case "$role" in
        a)
            home="$_CROSS_A_HOME"
            xdg="$_CROSS_A_XDG"
            ;;
        b)
            home="$_CROSS_B_HOME"
            xdg="$_CROSS_B_XDG"
            ;;
        *)
            printf '    FAIL: unknown cross-home fixture role: %s\n' "$role" >&2
            return 1
            ;;
    esac
    mkdir -p "$home/.ssh" "$home/AppData/Roaming" "$home/AppData/Local" "$xdg"

    export HOME="$home"
    export USERPROFILE="$home"
    export APPDATA="$home/AppData/Roaming"
    export LOCALAPPDATA="$home/AppData/Local"
    export XDG_CONFIG_HOME="$xdg"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    export GITSETU_TEST=1
    export GITSETU_CONFIG_DIR="$XDG_CONFIG_HOME/gitsetu"
    export GITSETU_BACKUP_DIR="$GITSETU_CONFIG_DIR/backups"
    export GITSETU_PROFILES_DIR="$GITSETU_CONFIG_DIR/profiles"
    export GITSETU_HOOKS_DIR="$GITSETU_CONFIG_DIR/hooks"
    export GITSETU_PROFILES_CONF="$GITSETU_CONFIG_DIR/profiles.conf"
    export GITSETU_TEST_RUNTIME_DIR="$HOME/.gitsetu-test-runtime"
    export GITSETU_LOCK_DIR="$GITSETU_TEST_RUNTIME_DIR/profiles.lock"
    export GITSETU_CREDENTIAL_BACKEND=file
    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS="$_CROSS_VAULT_PASSWORD"
    unset GITSETU_VAULT_PASS

    GITSETU_DEFAULT_LOCK_DIR="$GITSETU_LOCK_DIR"
    GITSETU_LOCK_RUNTIME_CONFIGURED=0
    GITSETU_LOCK_PATH=""
    GITSETU_LOCK_TOKEN=""
    GITSETU_LOCK_PROCESS_START=""
    GITSETU_LOCK_DEPTH=0
    GITSETU_CLEANUP_FILES=()
    GITSETU_CLEANUP_DIRS=()
    _VAULT_ROOT_KEY=""
    _VAULT_ACTIVE_TEMP=""
    GITSETU_VAULT_ACTIVE_TRANSACTION=""

    source_gitsetu_libs
}

_cross_reset_home_state() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig" \
        "$HOME/.gitsetu-test-runtime" "$HOME/work" "$HOME/target"
    mkdir -p "$GITSETU_CONFIG_DIR/backups" "$GITSETU_PROFILES_DIR" \
        "$GITSETU_HOOKS_DIR" "$HOME/.ssh"
    chmod 700 "$GITSETU_CONFIG_DIR" "$GITSETU_BACKUP_DIR" \
        "$GITSETU_PROFILES_DIR" "$GITSETU_HOOKS_DIR" "$HOME/.ssh"
    _clear_profile_state
}

_cross_seed_source_home() {
    _cross_activate_home a || return 1
    _cross_reset_home_state || return 1
    mkdir -p "$HOME/work" "$HOME/.ssh" || return 1

    test_v2_profile_config global 'Source Global' 'source-global@example.invalid' || return 1
    test_v2_profile_config work 'Source Work' 'source-work@example.invalid' || return 1
    printf '%s\n' "$_CROSS_SOURCE_PRIVATE" > "$HOME/.ssh/id_ed25519_global" || return 1
    printf '%s\n' "$_CROSS_SOURCE_PRIVATE-work" > "$HOME/.ssh/id_ed25519_work" || return 1
    printf '%s\n' "$_CROSS_SOURCE_PUBLIC" > "$HOME/.ssh/id_ed25519_global.pub" || return 1
    printf '%s\n' "$_CROSS_SOURCE_PUBLIC-work" > "$HOME/.ssh/id_ed25519_work.pub" || return 1
    chmod 600 "$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_work" || return 1
    chmod 644 "$HOME/.ssh/id_ed25519_global.pub" "$HOME/.ssh/id_ed25519_work.pub" || return 1
    {
        test_v2_registry_header
        test_v2_registry_line global '' github.com 0 \
            "$HOME/.ssh/id_ed25519_global" source-global-user
        test_v2_registry_line work "$HOME/work" github.com 0 \
            "$HOME/.ssh/id_ed25519_work" source-work-user
    } > "$GITSETU_PROFILES_CONF" || return 1
    load_profiles "$GITSETU_PROFILES_CONF" || return 1

    write_global_gitconfig >/dev/null || return 1
    write_ssh_config >/dev/null || return 1
    install_guard >/dev/null || return 1
    keychain_store work github.com fixture-user "$_CROSS_SOURCE_TOKEN" \
        >/dev/null 2>&1 || return 1
    [[ -f "$GITSETU_HOOKS_DIR/pre-commit" && -f "$GITSETU_CONFIG_DIR/.tokens" ]]
}

_cross_seed_target_home() {
    _cross_activate_home b || return 1
    _cross_reset_home_state || return 1
    mkdir -p "$HOME/target" || return 1
    printf '%s\n' 'target-backup-must-survive' > "$GITSETU_BACKUP_DIR/existing.bak" || return 1
    printf '%s\n' 'target-unmanaged-must-survive' > "$GITSETU_CONFIG_DIR/unmanaged.conf" || return 1
    test_v2_profile_config global 'Target Global' 'target-global@example.invalid' || return 1
    test_v2_profile_config target 'Target Only' 'target-only@example.invalid' || return 1
    printf '%s\n' 'target-private-collision' > "$HOME/.ssh/id_ed25519_global" || return 1
    printf '%s\n' 'target-work-collision' > "$HOME/.ssh/id_ed25519_work" || return 1
    printf '%s\n' 'target-public-collision' > "$HOME/.ssh/id_ed25519_global.pub" || return 1
    printf '%s\n' 'target-work-public-collision' > "$HOME/.ssh/id_ed25519_work.pub" || return 1
    {
        test_v2_registry_header
        test_v2_registry_line global '' github.com 0 \
            "$HOME/.ssh/id_ed25519_global" target-global-user
        test_v2_registry_line target "$HOME/target" github.com 0 \
            "$HOME/.ssh/id_ed25519_global" target-only-user
    } > "$GITSETU_PROFILES_CONF" || return 1
    cat > "$HOME/.gitconfig" <<'EOF'
[user]
    name = Existing Target User
    email = existing-target@example.invalid
[credential]
    helper = target-existing-helper
[alias]
    target-existing = !echo target-existing
EOF
    cat > "$HOME/.ssh/config" <<'EOF'
Host target-user-host
    HostName target.example.invalid
    User target-user
EOF
    cat > "$GITSETU_HOOKS_DIR/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'target-hook-must-be-restored-on-rollback'
EOF
    chmod 700 "$GITSETU_HOOKS_DIR/pre-commit" || return 1
    keychain_store target github.com target-user target-token-before-restore \
        >/dev/null 2>&1 || return 1
    load_profiles "$GITSETU_PROFILES_CONF" || return 1
}

_cross_checksum_file() {
    local path="${1:-}"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    cksum < "$path"
}

_cross_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

_cross_assert_no_transaction() {
    local context="$1"
    local candidate found=0
    for candidate in "$(dirname "$GITSETU_CONFIG_DIR")"/.gitsetu-restore.*; do
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            found=1
            assert_file_not_exists "$candidate" \
                "$context removes successful/aborted transaction directories" || return 1
        fi
    done
    [[ "$found" -eq 0 ]]
}

_cross_assert_no_sidecars() {
    local context="$1"
    local root candidate
    for root in "$TEST_HOME" "$HOME" "$GITSETU_CONFIG_DIR"; do
        [[ -d "$root" ]] || continue
        for candidate in "$root"/gitsetu_vault_pre_restore_*.enc \
            "$root"/gitsetu_vault_pre_restore_*.password; do
            if [[ -e "$candidate" || -L "$candidate" ]]; then
                assert_file_not_exists "$candidate" "$context leaves no password sidecar" || return 1
            fi
        done
    done
}

_cross_restore_vault() {
    cmd_restore "$_CROSS_VAULT" >/dev/null 2>&1
}

# Build the source through the real backup command. This is the sole expensive
# PBKDF2 fixture shared by the migration and rollback cases.
_cross_seed_source_home || {
    printf '  [FATAL] could not seed source home for cross-home vault tests\n' >&2
    exit 1
}
mkdir -p "$_CROSS_ARTIFACTS"
if [[ -e "$_CROSS_VAULT" || -L "$_CROSS_VAULT" ]]; then
    printf '  [FATAL] unexpected pre-existing cross-home vault fixture\n' >&2
    exit 1
fi
if ! _cross_activate_home a || ! cmd_backup "$_CROSS_VAULT" >/dev/null 2>&1; then
    printf '  [FATAL] could not create authenticated source vault\n' >&2
    exit 1
fi
if ! grep -q '^GITSETU_VAULT_V2$' "$_CROSS_VAULT" ||
   grep -qF "$_CROSS_SOURCE_PRIVATE" "$_CROSS_VAULT" ||
   grep -qF "$_CROSS_SOURCE_TOKEN" "$_CROSS_VAULT"; then
    printf '  [FATAL] source vault fixture is not an opaque authenticated v2 envelope\n' >&2
    exit 1
fi

# --- Test cases ---

test_cross_home_backup_refuses_output_collisions() {
    local candidate="$_CROSS_ARTIFACTS/collision.gitsetu-v2.vault"
    local before after status=0

    _cross_activate_home a || return 1
    rm -f "$candidate"
    printf '%s\n' 'do-not-overwrite' > "$candidate" || return 1
    chmod 600 "$candidate" || return 1

    cmd_backup "$candidate" >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "backup refuses an existing output path" || return 1
    assert_file_contains "$candidate" "do-not-overwrite" \
        "failed backup collision leaves the existing file untouched" || return 1

    before=$(_cross_checksum_file "$_CROSS_VAULT") || return 1
    cmd_backup "$_CROSS_VAULT" >/dev/null 2>&1 || status=$?
    after=$(_cross_checksum_file "$_CROSS_VAULT") || return 1
    assert_equals "1" "$status" "backup refuses to replace its own prior vault" || return 1
    assert_equals "$before" "$after" "output collision leaves the prior vault byte-identical" || return 1
    rm -f "$candidate"
}

test_cross_home_restore_maps_paths_and_preserves_user_config() {
    local output="" token_output="" effective_email="" helper="" hooks_path=""

    _cross_seed_target_home || return 1
    output=$(_cross_restore_vault 2>&1) || {
        printf '    FAIL: cross-home restore failed: %s\n' "$output"
        mark_test_failure
        return 1
    }

    load_profiles "$GITSETU_PROFILES_CONF" || return 1
    assert_equals "2" "$PROFILE_COUNT" "cross-home restore activates both source profiles" || return 1
    assert_equals "global" "${PROFILE_LABELS[0]}" "global profile remains first" || return 1
    assert_equals "work" "${PROFILE_LABELS[1]}" "work profile order is preserved" || return 1
    assert_equals "$HOME/work" "${PROFILE_DIRS[1]}" \
        "profile directory is remapped from HOME A to HOME B" || return 1
    assert_equals "$HOME/.ssh/id_ed25519_global" "${PROFILE_KEYS[0]}" \
        "global key path is remapped into HOME B" || return 1
    assert_equals "$HOME/.ssh/id_ed25519_work" "${PROFILE_KEYS[1]}" \
        "work key path is remapped into HOME B" || return 1
    assert_not_contains "$GITSETU_PROFILES_CONF" "$_CROSS_A_HOME" \
        "restored registry does not retain source-home bytes" || return 1

    assert_file_contains "$HOME/.ssh/id_ed25519_global" "$_CROSS_SOURCE_PRIVATE" \
        "existing private-key collision is replaced transactionally" || return 1
    assert_file_contains "$HOME/.ssh/id_ed25519_work" "$_CROSS_SOURCE_PRIVATE-work" \
        "second colliding private key is restored" || return 1
    assert_file_contains "$HOME/.ssh/id_ed25519_global.pub" "$_CROSS_SOURCE_PUBLIC" \
        "existing public-key collision is replaced" || return 1
    assert_file_contains "$HOME/.gitconfig" "Existing Target User" \
        "existing global Git identity remains outside managed state" || return 1
    assert_file_contains "$HOME/.gitconfig" "target-existing-helper" \
        "existing credential helper policy remains authoritative" || return 1
    helper=$(git config --global --get-all credential.helper 2>/dev/null | head -n 1) || return 1
    assert_equals "target-existing-helper" "$helper" \
        "restore does not shadow the target credential helper" || return 1
    assert_file_contains "$HOME/.ssh/config" "Host target-user-host" \
        "existing SSH hosts are preserved" || return 1
    assert_file_contains "$HOME/.ssh/config" "Include" \
        "restored managed SSH include is added without discarding user hosts" || return 1
    assert_file_contains "$GITSETU_CONFIG_DIR/unmanaged.conf" "target-unmanaged-must-survive" \
        "unrelated files in the XDG config root survive restore" || return 1
    assert_file_contains "$GITSETU_BACKUP_DIR/existing.bak" "target-backup-must-survive" \
        "existing backup directory contents survive restore" || return 1
    assert_file_not_exists "$GITSETU_PROFILES_DIR/target.gitconfig" \
        "target-only managed profile is replaced by the source registry" || return 1

    assert_file_contains "$GITSETU_HOOKS_DIR/pre-commit" "[gitsetu:managed] v2 pre-commit identity guard" \
        "source hook presence causes a fresh target guard to be installed" || return 1
    hooks_path=$(git config --global --get core.hooksPath 2>/dev/null) || return 1
    assert_contains "$hooks_path" "$GITSETU_HOOKS_DIR" \
        "restored guard configures the target XDG hook directory" || return 1

    token_output=$(keychain_get work github.com 2>/dev/null) || return 1
    assert_contains "$token_output" "password=$_CROSS_SOURCE_TOKEN" \
        "file-backend token is restored without contacting a native/network backend" || return 1
    assert_not_contains "$GITSETU_CONFIG_DIR/.tokens" "target-token-before-restore" \
        "explicit target token state is replaced, not ambiguously merged" || return 1

    mkdir -p "$HOME/work/repo" || return 1
    git -C "$HOME/work/repo" init -q >/dev/null 2>&1 || return 1
    effective_email=$(git -C "$HOME/work/repo" config user.email 2>/dev/null) || return 1
    assert_equals "source-work@example.invalid" "$effective_email" \
        "target repository routes to the remapped source work identity" || return 1

    if can_chmod_600; then
        assert_equals "600" "$(_cross_mode "$HOME/.ssh/id_ed25519_global")" \
            "restored private key is mode 0600" || return 1
        assert_equals "600" "$(_cross_mode "$GITSETU_CONFIG_DIR/.tokens")" \
            "restored token store is mode 0600" || return 1
        assert_equals "700" "$(_cross_mode "$GITSETU_HOOKS_DIR/pre-commit")" \
            "restored guard hook is mode 0700" || return 1
    fi
    _cross_assert_no_transaction "successful cross-home restore" || return 1
    _cross_assert_no_sidecars "successful cross-home restore"
}

test_cross_home_failed_commit_rolls_back_without_marker() {
    local status=0 output=""
    local before_registry before_profile before_key before_hook before_token
    local before_git before_ssh after_registry after_profile after_key after_hook after_token
    local after_git after_ssh

    _cross_seed_target_home || return 1
    before_registry=$(_cross_checksum_file "$GITSETU_PROFILES_CONF") || return 1
    before_profile=$(_cross_checksum_file "$GITSETU_PROFILES_DIR/target.gitconfig") || return 1
    before_key=$(_cross_checksum_file "$HOME/.ssh/id_ed25519_global") || return 1
    before_hook=$(_cross_checksum_file "$GITSETU_HOOKS_DIR/pre-commit") || return 1
    before_token=$(_cross_checksum_file "$GITSETU_CONFIG_DIR/.tokens") || return 1
    before_git=$(_cross_checksum_file "$HOME/.gitconfig") || return 1
    before_ssh=$(_cross_checksum_file "$HOME/.ssh/config") || return 1

    if (
        # shellcheck disable=SC2329  # invoked indirectly by cmd_restore
        write_profile_gitconfig() { return 1; }
        cmd_restore "$_CROSS_VAULT"
    ) >/dev/null 2>&1; then
        status=0
    else
        status=$?
    fi
    assert_equals "1" "$status" "forced post-commit failure reports rollback" || return 1

    after_registry=$(_cross_checksum_file "$GITSETU_PROFILES_CONF") || return 1
    after_profile=$(_cross_checksum_file "$GITSETU_PROFILES_DIR/target.gitconfig") || return 1
    after_key=$(_cross_checksum_file "$HOME/.ssh/id_ed25519_global") || return 1
    after_hook=$(_cross_checksum_file "$GITSETU_HOOKS_DIR/pre-commit") || return 1
    after_token=$(_cross_checksum_file "$GITSETU_CONFIG_DIR/.tokens") || return 1
    after_git=$(_cross_checksum_file "$HOME/.gitconfig") || return 1
    after_ssh=$(_cross_checksum_file "$HOME/.ssh/config") || return 1
    assert_equals "$before_registry" "$after_registry" "rollback restores registry bytes" || return 1
    assert_equals "$before_profile" "$after_profile" "rollback restores profile files" || return 1
    assert_equals "$before_key" "$after_key" "rollback restores colliding private keys" || return 1
    assert_equals "$before_hook" "$after_hook" "rollback restores the target hook" || return 1
    assert_equals "$before_token" "$after_token" "rollback restores target token state" || return 1
    assert_equals "$before_git" "$after_git" "rollback restores global Git config bytes" || return 1
    assert_equals "$before_ssh" "$after_ssh" "rollback restores global SSH config bytes" || return 1
    _cross_assert_no_transaction "successful rollback" || return 1
    _cross_assert_no_sidecars "successful rollback"

    output=$(cmd_restore "$_CROSS_VAULT" 2>&1 || true)
    assert_contains "$output" "Authenticated v2 vault restored successfully" \
        "sanity check: shared source vault remains reusable after rollback" || return 1
}

test_cross_home_incomplete_rollback_leaves_recovery_marker() {
    local status=0 output="" txn="" candidate found=0
    local before_registry before_key before_git before_ssh

    _cross_seed_target_home || return 1
    before_registry=$(_cross_checksum_file "$GITSETU_PROFILES_CONF") || return 1
    before_key=$(_cross_checksum_file "$HOME/.ssh/id_ed25519_global") || return 1
    before_git=$(_cross_checksum_file "$HOME/.gitconfig") || return 1
    before_ssh=$(_cross_checksum_file "$HOME/.ssh/config") || return 1

    if (
        # shellcheck disable=SC2329  # invoked indirectly by cmd_restore
        write_profile_gitconfig() { return 1; }
        # shellcheck disable=SC2329  # invoked indirectly by abort helper
        _vault_rollback_transaction() { return 1; }
        cmd_restore "$_CROSS_VAULT"
    ) >"$TEST_HOME/incomplete-restore.out" 2>&1; then
        status=0
    else
        status=$?
    fi
    assert_equals "1" "$status" "incomplete rollback reports restore failure" || return 1
    output=$(cat "$TEST_HOME/incomplete-restore.out" 2>/dev/null) || return 1
    assert_contains "$output" "automatic rollback was incomplete" \
        "incomplete rollback is explicit" || return 1
    assert_contains "$output" "Private recovery data remains at:" \
        "incomplete rollback reports the private transaction path" || return 1

    for candidate in "$(dirname "$GITSETU_CONFIG_DIR")"/.gitsetu-restore.*; do
        if [[ -d "$candidate" && ! -L "$candidate" ]]; then
            txn="$candidate"
            found=$((found + 1))
        fi
    done
    assert_equals "1" "$found" "incomplete rollback leaves exactly one transaction snapshot" || return 1
    assert_contains "$output" "$txn" "reported recovery path is the retained transaction" || return 1
    assert_file_contains "$txn/RECOVERY_REQUIRED" "state=rollback-incomplete" \
        "retained transaction has an incomplete-rollback marker" || return 1
    assert_file_contains "$txn/RECOVERY_REQUIRED" "Do not delete it until recovery is complete" \
        "recovery marker warns before destructive manual action" || return 1
    assert_file_exists "$txn/old-state/profiles.conf" \
        "recovery snapshot retains the previous registry" || return 1
    assert_file_exists "$txn/old-keys/0" \
        "recovery snapshot retains previous colliding key material" || return 1
    assert_file_exists "$txn/old-global/gitconfig" \
        "recovery snapshot retains the previous global Git config" || return 1
    assert_equals "$before_registry" "$(_cross_checksum_file "$txn/old-state/profiles.conf")" \
        "snapshotted registry is byte-identical to pre-restore state" || return 1
    assert_equals "$before_key" "$(_cross_checksum_file "$txn/old-keys/0")" \
        "snapshotted key is byte-identical to pre-restore state" || return 1
    assert_equals "$before_git" "$(_cross_checksum_file "$txn/old-global/gitconfig")" \
        "snapshotted global Git config is byte-identical to pre-restore state" || return 1
    assert_equals "$before_ssh" "$(_cross_checksum_file "$txn/old-global/sshconfig")" \
        "snapshotted global SSH config is byte-identical to pre-restore state" || return 1
    assert_file_contains "$HOME/.ssh/id_ed25519_global" "$_CROSS_SOURCE_PRIVATE" \
        "forced incomplete rollback leaves the committed source state discoverable" || return 1
    if can_chmod_600; then
        assert_equals "700" "$(_cross_mode "$txn")" \
            "recovery transaction directory is private mode 0700" || return 1
        assert_equals "600" "$(_cross_mode "$txn/RECOVERY_REQUIRED")" \
            "recovery marker is private mode 0600" || return 1
    fi
    _cross_assert_no_sidecars "incomplete rollback"
    rm -f "$TEST_HOME/incomplete-restore.out"
    rm -rf "$txn"
}

printf '\n%btest_vault_cross_home.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "backup output collisions are non-destructive" \
    test_cross_home_backup_refuses_output_collisions
run_test "HOME A backup restores into HOME B with different XDG" \
    test_cross_home_restore_maps_paths_and_preserves_user_config
run_test "post-commit failure rolls back state without a marker" \
    test_cross_home_failed_commit_rolls_back_without_marker
run_test "incomplete rollback retains a private recovery marker" \
    test_cross_home_incomplete_rollback_leaves_recovery_marker

print_results "Cross-home vault tests"
