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
    assert_contains "$block" "IdentityFile ~/.ssh/id_ed25519_pro" "has IdentityFile" &&
    assert_contains "$block" "IdentitiesOnly yes" "has IdentitiesOnly"
}

test_ssh_host_block_custom_host() {
    local block
    block=$(build_ssh_host_block "work" "gitlab.com")

    assert_contains "$block" "Host gitlab-work" "has Host with label" &&
    assert_contains "$block" "HostName gitlab.com" "has custom HostName"
}

test_ssh_assert_components_one_argument_under_set_u() {
    local path="$HOME/.ssh"
    local status=0
    mkdir -p "$path"
    (set -u; _ssh_assert_no_symlink_components "$path") >/dev/null 2>&1 || status=$?
    assert_equals "0" "$status" "one-argument component validation is safe under set -u" || return 1
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
        skip_test "generate key permissions" "permissions are not enforceable on Git Bash/NTFS"
        return 0
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
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_pro")
    PROFILE_COUNT=2

    write_ssh_config 2>/dev/null

    assert_file_exists "$HOME/.ssh/config" "ssh config created" &&
    assert_file_contains "$HOME/.ssh/config" "Include ~/.config/gitsetu/profiles/ssh_config" "has include directive" &&
    assert_file_exists "$GITSETU_PROFILES_DIR/ssh_config" "isolated config created" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-global" "has global host" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "Host github-pro" "has pro host"
}

test_write_ssh_config_idempotent() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "pro")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_pro")
    PROFILE_COUNT=2

    write_ssh_config 2>/dev/null
    write_ssh_config 2>/dev/null

    # Count occurrences of "Include" — should be exactly 1
    local count
    count=$(grep -c "Include ~/.config/gitsetu/profiles/ssh_config" "$HOME/.ssh/config")
    assert_equals "1" "$count" "no duplicate include directives after re-run"
}

test_write_ssh_config_preserves_user_content() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global")
    PROFILE_COUNT=1

    # Add user content first
    printf 'Host my-custom-server\n    HostName 192.168.1.1\n    User admin\n\n' > "$HOME/.ssh/config"

    write_ssh_config 2>/dev/null

    assert_file_contains "$HOME/.ssh/config" "Host my-custom-server" "user content preserved" &&
    assert_file_contains "$HOME/.ssh/config" "Include ~/.config/gitsetu/profiles/ssh_config" "include directive added"
}

test_write_ssh_config_is_deterministic_and_keeps_legacy_user_content() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "work")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_work")
    PROFILE_COUNT=2
    printf '%s\n' '# [gitsetu:managed:start]' 'User Host legacy' '# [gitsetu:managed:end]' > "$HOME/.ssh/config"
    write_ssh_config >/dev/null
    local first
    first=$(cat "$GITSETU_PROFILES_DIR/ssh_config")
    write_ssh_config >/dev/null
    assert_equals "$first" "$(cat "$GITSETU_PROFILES_DIR/ssh_config")" "generated SSH config is deterministic" || return 1
    assert_file_contains "$HOME/.ssh/config" "User Host legacy" "no inline legacy cleanup is performed" || return 1
}

test_write_ssh_config_rejects_missing_v2_fields() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_COUNT=1
    unset PROFILE_PROVIDERS PROFILE_KEYS
    local status=0
    write_ssh_config >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "missing provider/key fields are rejected" || return 1

    PROFILE_PROVIDERS=("github.com")
    PROFILE_KEYS=("")
    status=0
    write_ssh_config >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "empty key field is rejected" || return 1
}

test_write_ssh_config_rejects_symlink_components() {
    local real_ssh="$HOME/real-ssh"
    rm -rf "$real_ssh" "$HOME/.ssh"
    mkdir -p "$real_ssh"
    if ! ln -s "$real_ssh" "$HOME/.ssh" 2>/dev/null; then
        skip_test "symlinked SSH components" "symlink/junction creation is unavailable"
        return 0
    fi
    local redirected=0
    if [[ -L "$HOME/.ssh" ]]; then
        redirected=1
    elif [[ "${GITSETU_OS:-}" == "gitbash" ]] && command -v cygpath >/dev/null 2>&1 && command -v fsutil.exe >/dev/null 2>&1; then
        local windows_ssh
        windows_ssh=$(cygpath -w "$HOME/.ssh" 2>/dev/null) || return 1
        fsutil.exe reparsepoint query "$windows_ssh" >/dev/null 2>&1 && redirected=1
    fi
    if [[ "$redirected" -ne 1 ]]; then
        if ! rm -rf "$real_ssh" "$HOME/.ssh" 2>/dev/null; then
            printf '    FAIL: could not clean the unavailable SSH link fixture\n'
            return 1
        fi
        skip_test "symlinked SSH components" "symlink/junction creation is unavailable"
        return 0
    fi
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_KEYS=("$real_ssh/id")
    PROFILE_COUNT=1
    local status=0
    write_ssh_config >/dev/null 2>&1 || status=$?
    if [[ -L "$HOME/.ssh" || -d "$HOME/.ssh" ]]; then
        if ! rm -rf "$HOME/.ssh" 2>/dev/null; then
            printf '    FAIL: could not clean the SSH link fixture\n'
            return 1
        fi
    fi
    assert_equals "1" "$status" "symlinked ~/.ssh is rejected" || return 1
}
test_write_ssh_config_rejects_symlink_profiles_directory() {
    local real_profiles="$HOME/real-profiles"
    rm -rf "$real_profiles" "$GITSETU_PROFILES_DIR"
    mkdir -p "$real_profiles"
    if ! ln -s "$real_profiles" "$GITSETU_PROFILES_DIR" 2>/dev/null || [[ ! -L "$GITSETU_PROFILES_DIR" ]]; then
        rm -rf "$real_profiles" "$GITSETU_PROFILES_DIR" 2>/dev/null || true
        skip_test "symlinked profiles directory" "symlink/junction creation is unavailable"
        return 0
    fi
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_global")
    PROFILE_COUNT=1
    local status=0
    write_ssh_config >/dev/null 2>&1 || status=$?
    if [[ -L "$GITSETU_PROFILES_DIR" ]]; then rm -f "$GITSETU_PROFILES_DIR" 2>/dev/null || unlink "$GITSETU_PROFILES_DIR" 2>/dev/null || true; fi
    assert_equals "1" "$status" "symlinked profiles directory is rejected" || return 1
}
test_ssh_reparse_cache_is_bounded_and_fast_on_gitbash() {
    local old_os="${GITSETU_OS:-}"
    local old_cache_max="${GITSETU_SSH_REPARSE_CACHE_MAX:-}"
    local old_core_cache_max="${GITSETU_REPARSE_CACHE_MAX:-}"
    local root="$HOME/reparse-cache-perf/level1/level2/level3/level4/leaf"
    local i variant_root
    mkdir -p "$root"

    # Use deterministic stand-ins for the Win32 probes. This exercises the
    # production cache path on Git Bash without making the test itself spawn
    # fsutil.exe hundreds of times.
    SSH_REPARSE_PROBE_COUNT=0
    # shellcheck disable=SC2329  # invoked indirectly by the SSH path validator
    cygpath() { printf '%s' "${!#}"; }
    # shellcheck disable=SC2329  # invoked indirectly by the SSH path validator
    fsutil.exe() {
        SSH_REPARSE_PROBE_COUNT=$((SSH_REPARSE_PROBE_COUNT + 1))
        return 1
    }
    GITSETU_OS=gitbash
    GITSETU_SSH_REPARSE_CACHE_MAX=64
    _ssh_reparse_cache_reset

    _ssh_assert_no_symlink_components "$root" || return 1
    local first_probe_count="$SSH_REPARSE_PROBE_COUNT"
    local start_seconds=$SECONDS
    for (( i=0; i<30; i++ )); do
        _ssh_assert_no_symlink_components "$root" || return 1
    done
    local elapsed=$((SECONDS - start_seconds))
    assert_equals "$first_probe_count" "$SSH_REPARSE_PROBE_COUNT" "repeated component checks reuse the bounded cache" || return 1
    if [[ "$elapsed" -gt 8 ]]; then
        printf '    FAIL: repeated Git Bash reparse checks exceeded 8 seconds (%s)\n' "$elapsed"
        return 1
    fi

    GITSETU_SSH_REPARSE_CACHE_MAX=4
    _ssh_reparse_cache_reset
    for i in {1..8}; do
        variant_root="$HOME/reparse-cache-perf/variant-$i/level1/level2/level3"
        mkdir -p "$variant_root"
        _ssh_assert_no_symlink_components "$variant_root" || return 1
    done
    if [[ "${_SSH_REPARSE_CACHE_SIZE:-0}" -gt 4 ]]; then
        printf '    FAIL: reparse cache exceeded its configured bound\n'
        return 1
    fi

    # Core path guards share the same Windows probe policy and must not bring
    # the expensive helper back for every repeated component walk.
    GITSETU_REPARSE_CACHE_MAX=4
    _gitsetu_reparse_cache_reset
    local core_status=0
    _gitsetu_is_reparse_point "$root" || core_status=$?
    [[ "$core_status" -le 1 ]] || return 1
    local core_first_probe_count="$SSH_REPARSE_PROBE_COUNT"
    core_status=0
    _gitsetu_is_reparse_point "$root" || core_status=$?
    [[ "$core_status" -le 1 ]] || return 1
    assert_equals "$core_first_probe_count" "$SSH_REPARSE_PROBE_COUNT" "core reparse checks reuse their bounded cache" || return 1

    unset -f cygpath fsutil.exe
    GITSETU_OS="$old_os"
    if [[ -n "$old_cache_max" ]]; then
        GITSETU_SSH_REPARSE_CACHE_MAX="$old_cache_max"
    else
        unset GITSETU_SSH_REPARSE_CACHE_MAX
    fi
    if [[ -n "$old_core_cache_max" ]]; then
        GITSETU_REPARSE_CACHE_MAX="$old_core_cache_max"
    else
        unset GITSETU_REPARSE_CACHE_MAX
    fi
    _ssh_reparse_cache_reset
    _gitsetu_reparse_cache_reset
}

test_generate_key_fido2_no_software_fallback() {
    GITSETU_DRY_RUN=0
    local key_path="$HOME/.ssh/id_ed25519_sk_fidotest"
    local output status=0

    # A requested hardware key must never be silently downgraded. Mock the
    # enrollment failure so the expectation is deterministic on every platform.
    output=$(
        # shellcheck disable=SC2329  # invoked indirectly by generate_ssh_key
        ssh-keygen() { return 1; }
        generate_ssh_key "fidotest" "fido@example.com" "$key_path" 2>&1
    ) || status=$?

    assert_equals "1" "$status" "FIDO2 failure is returned to caller" || return 1
    assert_contains "$output" "No software-key fallback was attempted" "fallback is explicit" || return 1
    assert_not_contains "$output" "Falling back" "no automatic software downgrade" || return 1
    if [[ -e "$key_path" || -e "$key_path.pub" ]]; then
        printf '    FAIL: failed FIDO2 enrollment left key artifacts\n'
        return 1
    fi
}

test_ssh_host_block_port443() {
    GITSETU_PORT443_NEEDED=1
    local block
    block=$(build_ssh_host_block "work" "github.com")
    unset GITSETU_PORT443_NEEDED

    assert_contains "$block" "Port 443" "has Port 443" &&
    assert_contains "$block" "HostName ssh.github.com" "has ssh.github.com HostName" &&
    assert_contains "$block" "Host github-work" "has Host alias"
}

# --- Run ---

printf '\n%btest_ssh.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "SSH host block has correct format" test_ssh_host_block_format
run_test "SSH host block uses custom hostname" test_ssh_host_block_custom_host
run_test "one-argument path validation is set -u safe" test_ssh_assert_components_one_argument_under_set_u
run_test "SSH host block with Port 443 fallback" test_ssh_host_block_port443
run_test "generate_ssh_key creates key files" test_generate_key_creates_files
run_test "generated key has 600 permissions" test_generate_key_permissions
run_test "dry run does not create keys" test_generate_key_dry_run
run_test "write_ssh_config creates config file" test_write_ssh_config_creates_file
run_test "write_ssh_config is idempotent" test_write_ssh_config_idempotent
run_test "write_ssh_config preserves user content" test_write_ssh_config_preserves_user_content
run_test "write SSH config is deterministic and leaves legacy content" test_write_ssh_config_is_deterministic_and_keeps_legacy_user_content
run_test "write SSH config rejects missing v2 fields" test_write_ssh_config_rejects_missing_v2_fields
run_test "write SSH config rejects symlink components" test_write_ssh_config_rejects_symlink_components
run_test "write SSH config rejects symlinked profiles directory" test_write_ssh_config_rejects_symlink_profiles_directory
run_test "Git Bash reparse cache is bounded and fast" test_ssh_reparse_cache_is_bounded_and_fast_on_gitbash
run_test "FIDO2 failure never downgrades to software" test_generate_key_fido2_no_software_fallback
print_results "SSH tests"
