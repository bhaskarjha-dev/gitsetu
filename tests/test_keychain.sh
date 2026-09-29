#!/usr/bin/env bash
# tests/test_keychain.sh — Unit tests for lib/keychain.sh file-fallback paths
#
# Tests the local file-based credential storage (.tokens) which is used
# when OS-native keychains (macOS security / Linux secret-tool) are unavailable.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# Each backend-sensitive case calls _keychain_setup, which explicitly restores
# its HOME, backend, OS, and PATH. Avoid redundant full-environment snapshots.
_TEST_SKIP_ENV_SNAPSHOT=1
setup_test_home

source_gitsetu_libs

# Select the deliberate zero-dependency backend explicitly. Native-only is the
# default and is exercised separately below.
GITSETU_CREDENTIAL_BACKEND="file"
GITSETU_OS="unknown"

# Helper: sets up a clean test environment with the config dir
_keychain_setup() {
    # Set OSTYPE *before* setup_test_home, which branches on it to choose
    # pwd -W vs pwd -P. A previous case that exports OSTYPE=msys must not leak
    # into this sandbox, or a POSIX host is handed an empty HOME and every
    # later mkdir targets "/" instead of the sandbox.
    export OSTYPE=linux-gnu
    setup_test_home
    source_gitsetu_libs
    GITSETU_OS="unknown"
    export GITSETU_CREDENTIAL_BACKEND=file
    # Use POSIX permission checks for ordinary cases. The dedicated ACL case
    # below restores an MSYS environment before invoking the DACL parser.

    # Supply a test-only stat shim so mode/owner checks are deterministic on
    # Git Bash/NTFS as well as POSIX hosts.
    local mock_bin="$HOME/test-bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/stat" <<'EOF'
#!/usr/bin/env sh
format=""
path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|-f) format="$2"; shift 2 ;;
        -*) shift ;;
        *) path="$1"; shift ;;
    esac
done
case "$format" in
    %U|%Su) id -un ;;
    %u) id -u ;;
    *)
        case "$path" in
            */.tokens|*/.tokens.tmp.*) printf '600\n' ;;
            *) printf '700\n' ;;
        esac
        ;;
esac
EOF
    chmod +x "$mock_bin/stat"
    local path_bin="$mock_bin"
    if command -v cygpath >/dev/null 2>&1; then
        path_bin=$(cygpath -u "$mock_bin" 2>/dev/null || printf '%s' "$mock_bin")
    fi
    case ":$PATH:" in
        *":$path_bin:"*) ;;
        *) export PATH="$path_bin:$PATH" ;;
    esac

    # keychain_store expects the config dir to exist (ensure_dirs creates it in production)
    mkdir -p "$HOME/.config/gitsetu"
    _install_ntfs_acl_shim
}

_install_ntfs_acl_shim() {
    local mock_bin="$HOME/test-bin"
    cat > "$mock_bin/icacls.exe" <<'EOF'
#!/usr/bin/env sh
case "${GITSETU_TEST_ACL_MODE:-restrictive}" in
    restrictive)
        printf '%s BUILTIN\\Administrators:(F)\n' "$1"
        printf '  NT AUTHORITY\\SYSTEM:(F)\n'
        printf '  %s:(F)\n' "$(id -un)"
        ;;
    permissive)
        printf '%s BUILTIN\\Administrators:(F)\n' "$1"
        printf '  NT AUTHORITY\\SYSTEM:(F)\n'
        printf '  %s:(F)\n' "$(id -un)"
        printf '  Everyone:(RX)\n'
        ;;
    empty)
        printf '%s\n' "$1"
        printf 'Successfully processed 1 files; Failed processing 0 files\n'
        ;;
    failure)
        exit 1
        ;;
    *)
        exit 2
        ;;
esac
EOF
    cat > "$mock_bin/fsutil.exe" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
    chmod 700 "$mock_bin/icacls.exe" "$mock_bin/fsutil.exe"
    local path_bin="$mock_bin"
    if command -v cygpath >/dev/null 2>&1; then
        path_bin=$(cygpath -u "$mock_bin" 2>/dev/null || printf '%s' "$mock_bin")
    fi
    case ":$PATH:" in
        *":$path_bin:"*) ;;
        *) export PATH="$path_bin:$PATH" ;;
    esac
}

# Remove a test-created directory symlink/junction without allowing cleanup
# behavior to change the product result.  Git Bash may expose a Windows
# junction as a directory, so rm -f is insufficient; PowerShell removes the
# reparse point itself when available, with rm -rf as a portable fallback.
cleanup_keychain_fixture_path() {
    local path="$1"
    local cleanup_status=0
    local windows_path

    if [[ -z "$path" ]]; then
        return 0
    fi

    if [[ "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "win"* ]] &&
       command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        if windows_path=$(cygpath -w "$path" 2>/dev/null); then
            export GITSETU_TEST_FIXTURE_PATH="$windows_path"
            # shellcheck disable=SC2016  # PowerShell expands the environment variable at runtime
            if ! powershell.exe -NoProfile -Command \
                '$p=$env:GITSETU_TEST_FIXTURE_PATH; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop }' \
                >/dev/null 2>&1; then
                cleanup_status=1
            fi
            unset GITSETU_TEST_FIXTURE_PATH
        else
            cleanup_status=1
        fi
    fi

    if [[ -e "$path" || -L "$path" ]]; then
        if ! rm -rf -- "$path"; then
            cleanup_status=1
        fi
    fi
    return "$cleanup_status"
}

create_keychain_directory_link() {
    local target="$1"
    local link="$2"
    local windows_target windows_link

    if [[ "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "win"* ]] &&
       command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        if ! windows_target=$(cygpath -w "$target" 2>/dev/null) ||
           ! windows_link=$(cygpath -w "$link" 2>/dev/null); then
            return 1
        fi
        export GITSETU_TEST_LINK_TARGET="$windows_target"
        export GITSETU_TEST_LINK_PATH="$windows_link"
        # A junction is the Windows directory-link equivalent of a POSIX
        # symlink and can be removed without traversing its target.
        # shellcheck disable=SC2016  # PowerShell expands environment variables
        if ! powershell.exe -NoProfile -Command \
            '$target=$env:GITSETU_TEST_LINK_TARGET; $link=$env:GITSETU_TEST_LINK_PATH; if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -Recurse -ErrorAction Stop }; New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null' \
            >/dev/null 2>&1; then
            unset GITSETU_TEST_LINK_TARGET GITSETU_TEST_LINK_PATH
            return 1
        fi
        unset GITSETU_TEST_LINK_TARGET GITSETU_TEST_LINK_PATH
        return 0
    fi

    ln -s "$target" "$link" 2>/dev/null && [[ -L "$link" ]]
}

create_keychain_file_link() {
    local target="$1"
    local link="$2"
    local windows_target windows_link

    if [[ "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "win"* ]] &&
       command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        if ! windows_target=$(cygpath -w "$target" 2>/dev/null) ||
           ! windows_link=$(cygpath -w "$link" 2>/dev/null); then
            return 1
        fi
        export GITSETU_TEST_LINK_TARGET="$windows_target"
        export GITSETU_TEST_LINK_PATH="$windows_link"
        # shellcheck disable=SC2016  # PowerShell expands environment variables
        if ! powershell.exe -NoProfile -Command \
            '$target=$env:GITSETU_TEST_LINK_TARGET; $link=$env:GITSETU_TEST_LINK_PATH; if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force -ErrorAction Stop }; New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null' \
            >/dev/null 2>&1; then
            unset GITSETU_TEST_LINK_TARGET GITSETU_TEST_LINK_PATH
            return 1
        fi
        unset GITSETU_TEST_LINK_TARGET GITSETU_TEST_LINK_PATH
        return 0
    fi

    ln -s "$target" "$link" 2>/dev/null && [[ -L "$link" ]]
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
    if ! count=$(grep -c '^v2' "$HOME/.config/gitsetu/.tokens" 2>/dev/null); then
        printf '    FAIL: token store is missing or has no v2 record\n'
        return 1
    fi
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
    if ! can_chmod_600; then
        skip_test "tokens file has 600 permissions" "filesystem does not enforce mode 600"
        return 0
    fi

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
        if ! chmod "$tokens_file" >/dev/null 2>&1; then
            printf '    FAIL: chmod mock could not be initialized\n'
            exit 1
        fi
        if ! export -f chmod; then
            printf '    FAIL: chmod mock could not be exported\n'
            exit 1
        fi
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

test_keychain_gcm_native_backend_keeps_exact_tuple() {
    local mock_bin="$HOME/gcm-bin"
    local record_file="$HOME/gcm-record"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/git-credential-manager" <<'EOF'
#!/usr/bin/env bash
set -e
case "$1" in
    store)
        cat > "$GCM_INPUT_FILE"
        sed -n 's/^password=//p' "$GCM_INPUT_FILE" > "$GCM_RECORD_FILE"
        ;;
    get)
        printf 'protocol=https\n'
        sed -n 's/^host=/host=/p; s/^username=/username=/p' "$GCM_INPUT_FILE"
        printf 'password='
        cat "$GCM_RECORD_FILE"
        ;;
    erase)
        : > "$GCM_RECORD_FILE"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$mock_bin/git-credential-manager"
    local old_path="$PATH" old_os="${GITSETU_OS:-}" old_backend="${GITSETU_CREDENTIAL_BACKEND:-}"
    export PATH="$mock_bin:$PATH" GITSETU_OS=gitbash GITSETU_CREDENTIAL_BACKEND=native
    export GCM_INPUT_FILE="$HOME/gcm-input" GCM_RECORD_FILE="$record_file"
    keychain_store "work" "github.com" "user" "secret" "/org/repo" >/dev/null
    local output
    output=$(keychain_get "work" "github.com" "/org/repo")
    assert_contains "$output" "username=user" "GCM returns exact username" || return 1
    assert_contains "$output" "password=secret" "GCM returns exact password" || return 1
    if keychain_get "work" "github.com" "/other" >/dev/null 2>&1; then
        printf '    FAIL: GCM lookup ignored credential path\n'
        return 1
    fi
    keychain_erase "work" "github.com" "/org/repo" >/dev/null
    export PATH="$old_path" GITSETU_OS="$old_os" GITSETU_CREDENTIAL_BACKEND="$old_backend"
    unset GCM_INPUT_FILE GCM_RECORD_FILE
}

# ==============================================================================
# Exact records, explicit backend selection, and no legacy reader
# ==============================================================================
test_keychain_exact_record_and_explicit_warning() {
    _keychain_setup

    local output
    output=$(keychain_store "work profile" "github.com:443" "name=user" "token: with=exact spacing" "/org/repo" 2>&1)
    assert_contains "$output" "explicit zero-dependency PLAINTEXT" "plaintext mode is clearly warned" || return 1

    output=$(keychain_get "work profile" "github.com:443" "/org/repo" 2>&1)
    assert_contains "$output" "username=name=user" "equals sign is preserved" || return 1
    assert_contains "$output" "password=token: with=exact spacing" "credential value is exact" || return 1

    local empty_path
    if keychain_get "work profile" "github.com:443" "" >/dev/null 2>&1; then
        printf '    FAIL: credential path lookup was not exact\n'
        return 1
    fi
}

test_keychain_native_default_never_implicitly_falls_back() {
    _keychain_setup
    unset GITSETU_CREDENTIAL_BACKEND
    GITSETU_OS=unknown

    local output status=0
    output=$(keychain_store "work" "github.com" "user" "token" 2>&1) || status=$?
    assert_equals "2" "$status" "missing native backend is an error" || return 1
    assert_contains "$output" "GITSETU_CREDENTIAL_BACKEND=file" "error explains explicit opt-in" || return 1
    assert_contains "$(keychain_print_backend_help)" "GITSETU_CREDENTIAL_BACKEND=file" "backend help is discoverable" || return 1
    if [[ -e "$HOME/.config/gitsetu/.tokens" ]]; then
        printf '    FAIL: native failure silently created a plaintext store\n'
        return 1
    fi
}

test_keychain_rejects_legacy_plaintext_record() {
    _keychain_setup
    printf '%s\n' 'gitsetu:work:github.com:user:secret' > "$HOME/.config/gitsetu/.tokens"
    local status=0 output
    output=$(keychain_get "work" "github.com" 2>&1) || status=$?
    assert_equals "2" "$status" "legacy record is rejected" || return 1
    assert_contains "$output" "legacy records are not supported" "no migration reader is advertised" || return 1
}

test_keychain_rejects_symlinked_config_directory() {
    _keychain_setup
    local outside="$HOME/outside-secret-dir"
    local link="$HOME/config-link"
    local real_config="$GITSETU_CONFIG_DIR"
    local status=0
    local cleanup_status=0

    mkdir -p "$outside"
    if ! cleanup_keychain_fixture_path "$link"; then
        printf '    FAIL: could not clean the previous config-link fixture\n'
        return 1
    fi
    if ! create_keychain_directory_link "$outside" "$link"; then
        cleanup_keychain_fixture_path "$link" || cleanup_status=1
        if [[ "$cleanup_status" -ne 0 ]]; then
            printf '    FAIL: could not clean an unavailable directory-link fixture\n'
            return 1
        fi
        skip_test "symlinked config directory" "directory symlink/junction creation is unavailable"
        return 0
    fi

    GITSETU_CONFIG_DIR="$link"
    keychain_store "work" "github.com" "user" "secret" >/dev/null 2>&1 || status=$?
    if ! assert_equals "1" "$status" "symlinked config directory is rejected"; then
        status=1
    fi
    if ! assert_file_not_exists "$outside/.tokens" "symlinked config did not redirect plaintext output"; then
        status=1
    fi
    if ! cleanup_keychain_fixture_path "$link"; then
        printf '    FAIL: config-link cleanup failed\n'
        return 1
    fi
    GITSETU_CONFIG_DIR="$real_config"
    [[ "$status" -eq 1 ]] || return 1
}

test_keychain_rejects_symlinked_token_file() {
    _keychain_setup
    local outside="$HOME/outside-secret-dir"
    local token_link="$GITSETU_CONFIG_DIR/.tokens"
    local status=0
    local cleanup_status=0

    mkdir -p "$outside" "$GITSETU_CONFIG_DIR"
    if ! cleanup_keychain_fixture_path "$token_link"; then
        printf '    FAIL: could not clean the previous token-link fixture\n'
        return 1
    fi
    if ! create_keychain_file_link "$outside/redirected.tokens" "$token_link"; then
        cleanup_keychain_fixture_path "$token_link" || cleanup_status=1
        if [[ "$cleanup_status" -ne 0 ]]; then
            printf '    FAIL: could not clean an unavailable file-link fixture\n'
            return 1
        fi
        skip_test "symlinked token file" "file symlink creation is unavailable"
        return 0
    fi

    keychain_store "work" "github.com" "user" "secret" >/dev/null 2>&1 || status=$?
    if ! assert_equals "1" "$status" "symlinked token file is rejected"; then
        status=1
    fi
    if ! assert_file_not_exists "$outside/redirected.tokens" "symlinked token file was not written through"; then
        status=1
    fi
    if ! cleanup_keychain_fixture_path "$token_link"; then
        printf '    FAIL: token-link cleanup failed\n'
        return 1
    fi
    [[ "$status" -eq 1 ]] || return 1
}

# A successful icacls exit is not sufficient evidence.  The explicit plaintext
# backend must reject permissive, empty, and failed DACL probes before it writes.
test_keychain_ntfs_acl_evidence_fails_closed() {
    _keychain_setup
    GITSETU_OS="gitbash"
    OSTYPE="msys"
    export GITSETU_OS OSTYPE GITSETU_TEST_ACL_MODE=restrictive

    local fixture="$HOME/acl-object"
    local failed=0 status=0
    printf 'fixture\n' > "$fixture"

    _keychain_ntfs_private_semantics "$fixture" || {
        printf '    FAIL: restrictive current-user DACL was rejected\n'
        failed=1
    }

    GITSETU_TEST_ACL_MODE=permissive
    status=0
    _keychain_ntfs_private_semantics "$fixture" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "permissive DACL is rejected" || failed=1

    GITSETU_TEST_ACL_MODE=empty
    status=0
    _keychain_ntfs_private_semantics "$fixture" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "missing DACL ACE evidence is rejected" || failed=1

    GITSETU_TEST_ACL_MODE=failure
    status=0
    _keychain_ntfs_private_semantics "$fixture" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "failed ACL inspection is rejected" || failed=1

    status=0
    (
        # shellcheck disable=SC2329  # invoked indirectly by the validator
        _keychain_ntfs_acl_command() { return 1; }
        _keychain_ntfs_private_semantics "$fixture"
    ) >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "missing ACL utility is rejected" || failed=1
    rm -f "$fixture"

    # Exercise the public file mutation gate as well: a permissive directory
    # DACL must fail before any plaintext token file is created.
    GITSETU_TEST_ACL_MODE=permissive
    status=0
    keychain_store "work" "github.com" "user" "permissive-pass" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "permissive DACL blocks the file backend" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "permissive DACL cannot create a plaintext store" || failed=1
    return "$failed"
}

test_keychain_ntfs_parser_accepts_path_prefixed_system_ace() {
    _keychain_setup
    KEYCHAIN_NTFS_CURRENT_USER="test-user"
    KEYCHAIN_NTFS_CURRENT_ACCOUNT="test-user"
    KEYCHAIN_NTFS_CURRENT_SID="S-1-5-21-1-2-3-1001"
    KEYCHAIN_NTFS_CURRENT_COMPUTER="TESTHOST"
    local acl_output
    acl_output='C:\Users\test-user\.config\gitsetu NT AUTHORITY\SYSTEM:(I)(OI)(CI)(F)
  TESTHOST\test-user:(F)
  BUILTIN\Administrators:(F)
Successfully processed 1 files; Failed processing 0 files'
    _keychain_ntfs_acl_is_restrictive "$acl_output"
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
run_test "exact record and explicit plaintext warning" test_keychain_exact_record_and_explicit_warning
run_test "native default never implicitly falls back" test_keychain_native_default_never_implicitly_falls_back
run_test "GCM native backend preserves exact tuple" test_keychain_gcm_native_backend_keeps_exact_tuple
run_test "legacy plaintext record is rejected" test_keychain_rejects_legacy_plaintext_record
run_test "symlinked config directory is rejected" test_keychain_rejects_symlinked_config_directory
run_test "symlinked token file is rejected" test_keychain_rejects_symlinked_token_file
run_test "NTFS DACL evidence fails closed" test_keychain_ntfs_acl_evidence_fails_closed
run_test "path-prefixed SYSTEM ACE is parsed" test_keychain_ntfs_parser_accepts_path_prefixed_system_ace
print_results "Keychain tests"
