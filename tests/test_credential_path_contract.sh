#!/usr/bin/env bash
# tests/test_credential_path_contract.sh — Hermetic Git credential protocol and
# exact v2 credential-record contracts.
#
# The normal CLI uses Git's path= attribute as an exact credential-tuple
# component, with an explicit environment override for controlled wrappers.
# The tests also check fail-closed record parsing. All persistence is in a
# disposable HOME; no native store or network is used.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# Each case creates and tears down its own HOME and explicitly resets the
# backend/path variables it changes; avoid snapshotting the entire inherited
# process environment a second time for every case.
_TEST_SKIP_ENV_SNAPSHOT=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT_EXE="$ROOT_DIR/gitsetu"
CONTRACT_EXE="${CONTRACT_EXE%$'\r'}"

CLI_STATUS=0
CLI_STDOUT=""
CLI_STDERR=""
BASE_PATH="$PATH"

# Keep the file backend's permission checks deterministic on Git Bash/NTFS as
# well as POSIX hosts.  The shim only supplies deterministic metadata; writes,
# directory checks, and ownership checks remain in lib/keychain.sh.
_install_contract_stat_shim() {
    local bin="$HOME/contract-bin"
    mkdir -p "$bin"
    cat > "$bin/stat" <<'EOF'
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
    chmod 700 "$bin/stat"
    # Keep Windows reparse/ACL probes hermetic as well: these commands are
    # metadata gates, not credential stores, and must not inspect the host.
    cat > "$bin/fsutil.exe" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
    cat > "$bin/icacls.exe" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
    chmod 700 "$bin/fsutil.exe" "$bin/icacls.exe"
    local path_bin="$bin"
    if command -v cygpath >/dev/null 2>&1; then
        path_bin=$(cygpath -u "$bin" 2>/dev/null || printf '%s' "$bin")
    fi
    case ":$PATH:" in
        *":$path_bin:"*) ;;
        *) export PATH="$path_bin:$PATH" ;;
    esac
}

_setup_contract_home() {
    setup_test_home || return 1
    # A prior case may have changed into its profile directory.  The shared
    # helper resolves module paths relative to its own source location, so
    # return to the checkout before refreshing the modules.
    cd "$ROOT_DIR" || return 1
    source_gitsetu_libs || return 1
    export GITSETU_OS=unknown
    export GITSETU_CREDENTIAL_BACKEND=file
    export PATH="$BASE_PATH"
    _install_contract_stat_shim
    mkdir -p "$GITSETU_CONFIG_DIR"
}

# Seed the minimum strict-v2 registry needed for cmd_prompt.  The active
# profile is selected by the caller's working directory.
_seed_cli_profile() {
    local repository="$HOME/repository"
    mkdir -p "$repository"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" "global_user"
        test_v2_registry_line work "$repository" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "work_user"
    } > "$GITSETU_PROFILES_CONF" || return 1
    cd "$repository" || return 1
}

# Invoke the real CLI in a child process.  The optional second argument is a
# path override: __default__ leaves GITSETU_CREDENTIAL_PATH unset, __empty__
# supplies an explicitly empty value, and any other value is exported.
_invoke_cli_child() {
    local input="$1"
    local path_mode="$2"
    shift 2

    case "$path_mode" in
        __default__)
            printf '%s' "$input" | bash "$CONTRACT_EXE" "$@"
            ;;
        __empty__)
            printf '%s' "$input" | GITSETU_CREDENTIAL_PATH='' bash "$CONTRACT_EXE" "$@"
            ;;
        *)
            printf '%s' "$input" | GITSETU_CREDENTIAL_PATH="$path_mode" bash "$CONTRACT_EXE" "$@"
            ;;
    esac
}

# Use the same small watchdog pattern as the older credential suite.  It keeps
# a malformed adapter or a regressed CLI from wedging the whole test process.
_run_cli() {
    local input="$1"
    local path_mode="${2-__default__}"
    if [[ $# -ge 2 ]]; then
        shift 2
    else
        shift
    fi

    local out_file="$HOME/.contract-cli-out.$$.$RANDOM"
    local err_file="$HOME/.contract-cli-err.$$.$RANDOM"
    local command_pid watchdog_pid status=0 wait_status=0 kill_status=0

    _invoke_cli_child "$input" "$path_mode" "$@" >"$out_file" 2>"$err_file" &
    command_pid=$!
    (sleep 15 && kill -9 "$command_pid" 2>/dev/null) &
    watchdog_pid=$!

    if wait "$command_pid"; then
        status=0
    else
        status=$?
    fi
    if kill "$watchdog_pid" 2>/dev/null; then
        :
    else
        kill_status=$?
        if [[ "$kill_status" -ne 1 ]]; then
            rm -f "$out_file" "$err_file"
            return "$kill_status"
        fi
    fi
    if wait "$watchdog_pid" 2>/dev/null; then
        :
    else
        wait_status=$?
        if [[ "$wait_status" -ne 143 && "$wait_status" -ne 137 ]]; then
            rm -f "$out_file" "$err_file"
            return "$wait_status"
        fi
    fi

    CLI_STATUS="$status"
    CLI_STDOUT="$(cat "$out_file")"
    CLI_STDERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
    return 0
}

_assert_cli_status() {
    assert_equals "$1" "$CLI_STATUS" "$2"
}

_assert_cli_stdout() {
    assert_equals "$1" "$CLI_STDOUT" "$2"
}

# Build one structurally valid v2 record.  The builder is intentionally
# independent of the store writer so corruption tests can alter one field.
_make_v2_line() {
    local profile="$1"
    local host="$2"
    local credential_path="$3"
    local username="$4"
    local password="$5"
    local profile_hex host_hex path_hex username_hex password_hex

    _keychain_hex_encode "$profile" || return 1
    profile_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$host" || return 1
    host_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$credential_path" || return 1
    path_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$username" || return 1
    username_hex="$KEYCHAIN_HEX_DECODED"
    _keychain_hex_encode "$password" || return 1
    password_hex="$KEYCHAIN_HEX_DECODED"
    [[ -n "$path_hex" ]] || path_hex="-"

    printf 'v2\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile_hex" "$host_hex" "$path_hex" "$username_hex" "$password_hex"
}

_write_tokens_fixture() {
    local tokens_file="$GITSETU_CONFIG_DIR/.tokens"
    mkdir -p "$GITSETU_CONFIG_DIR"
    (
        umask 077
        cat > "$tokens_file"
    ) || return 1
    chmod 700 "$GITSETU_CONFIG_DIR" || return 1
    chmod 600 "$tokens_file" || return 1
    printf '%s' "$tokens_file"
}

_store_silently() {
    keychain_store "$@" >/dev/null 2>&1
}

_get_silently() {
    keychain_get "$@" 2>/dev/null
}

# The CLI uses Git's path= attribute as the exact path component. Exercise
# empty, repository-root, and repository-specific values, then verify that an
# explicit environment override remains available for wrappers and tests.
test_cli_path_is_exact_but_env_path_can_override() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1

    local output status
    _store_silently "work" "github.com" "empty-user" "empty-pass" "" || return 1
    _store_silently "work" "github.com" "root-user" "root-pass" "/" || return 1
    _store_silently "work" "github.com" "repo-user" "repo-pass" "/org/repo" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=\n\n' __default__ credential get
    _assert_cli_status 0 "empty path is accepted" || return 1
    _assert_cli_stdout $'username=empty-user\npassword=empty-pass' \
        "empty path selects the empty-path tuple" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/\n\n' __default__ credential get
    _assert_cli_status 0 "root path is accepted" || return 1
    _assert_cli_stdout $'username=root-user\npassword=root-pass' \
        "root path selects the root tuple" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential get
    _assert_cli_status 0 "repository path is accepted" || return 1
    _assert_cli_stdout $'username=repo-user\npassword=repo-pass' \
        "repository path selects the repository tuple" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' "/" credential get
    _assert_cli_status 0 "explicit environment root path is usable" || return 1
    _assert_cli_stdout $'username=root-user\npassword=root-pass' \
        "environment path overrides the protocol path when explicitly set" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/\n\n' "/org/repo" credential get
    _assert_cli_status 0 "explicit environment repository path is usable" || return 1
    _assert_cli_stdout $'username=repo-user\npassword=repo-pass' \
        "GITSETU_CREDENTIAL_PATH selects the exact repository tuple" || return 1

    rm -f "$GITSETU_CONFIG_DIR/.tokens"
    _run_cli $'protocol=https\nhost=github.com\npath=/wrong\nusername=cli-user\npassword=cli-pass\n\n' \
        "/cli-path" credential store
    _assert_cli_status 0 "CLI store accepts the explicit environment path" || return 1
    output=$(_get_silently "work" "github.com" "/cli-path") || return 1
    assert_equals $'username=cli-user\npassword=cli-pass' "$output" \
        "CLI store uses the environment path rather than path= input" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/wrong\n\n' "/cli-path" credential erase
    _assert_cli_status 0 "CLI erase accepts the explicit environment path" || return 1
    status=0
    _get_silently "work" "github.com" "/cli-path" >/dev/null || status=$?
    assert_equals 1 "$status" "CLI erase removes the environment-selected tuple" || return 1
}

# A real profile can have several path-scoped records.  A nonmatching record
# is a normal iteration result, not a reason for the CLI's errexit shell to
# terminate before the exact match is visited.
test_cli_multiple_records_do_not_abort_on_nonmatch() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1

    _store_silently "work" "github.com" "empty-user" "empty-pass" "" || return 1
    _store_silently "work" "github.com" "root-user" "root-pass" "/" || return 1
    _run_cli $'protocol=https\nhost=github.com\npath=\n\n' __default__ credential get
    _assert_cli_status 0 "CLI get tolerates a nonmatching path record" || return 1
    _assert_cli_stdout $'username=empty-user\npassword=empty-pass' \
        "CLI get reaches the exact empty-path record" || return 1
}

# A credential protocol with repeated security-relevant attributes is
# ambiguous.  The broker must fail closed rather than silently taking the last
# value and potentially looking up or storing the wrong secret.
test_cli_duplicate_fields_fail_closed() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1
    local failed=0

    _run_cli $'protocol=https\nprotocol=ssh\nhost=github.com\n\n' __default__ credential get
    _assert_cli_status 1 "duplicate protocol fields are rejected" || failed=1
    _assert_cli_stdout "" "duplicate protocol fields emit no credential" || failed=1

    _store_silently "work" "github.com" "original-user" "original-pass" "" || return 1
    _run_cli $'protocol=https\nhost=first.example\nhost=github.com\n\n' __default__ credential get
    _assert_cli_status 1 "duplicate host fields are rejected" || failed=1
    _assert_cli_stdout "" "duplicate host fields emit no credential" || failed=1

    _run_cli $'protocol=https\nhost=github.com\npath=/one\npath=/two\n\n' __default__ credential get
    _assert_cli_status 1 "duplicate path fields are rejected even though path is ignored" || failed=1
    _assert_cli_stdout "" "duplicate path fields emit no credential" || failed=1

    _run_cli $'protocol=https\nhost=github.com\nusername=first\nusername=second\npassword=one\npassword=two\n\n' \
        __default__ credential store
    _assert_cli_status 1 "duplicate username/password fields are rejected" || failed=1
    _assert_cli_stdout "" \
        "a rejected duplicate-field store emits no credential" || failed=1
    local output
    output=$(_get_silently "work" "github.com" "") || {
        failed=1
        output=""
    }
    assert_equals "$output" $'username=original-user\npassword=original-pass' \
        "duplicate-field rejection preserves the exact stored tuple" || failed=1
    return "$failed"
}

# Unsupported protocols and incomplete/malformed requests are no-ops from a
# credential secrecy perspective.  In particular, they must not create a
# plaintext record as a side effect.
test_cli_unsupported_and_malformed_input() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1
    local failed=0

    local input
    for input in \
        $'protocol=ssh\nhost=github.com\n\n' \
        $'protocol=ftp\nhost=github.com\nusername=u\npassword=p\n\n' \
        $'host=github.com\n\n' \
        $'protocol=https\n\n' \
        $'protocol=https\nhost=\n\n'; do
        _run_cli "$input" __default__ credential store
        _assert_cli_status 0 "unsupported or empty credential input is ignored" || failed=1
        _assert_cli_stdout "" "ignored credential input emits no secret" || failed=1
        assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
            "ignored credential input creates no fallback store" || failed=1
        rm -f "$GITSETU_CONFIG_DIR/.tokens"
    done

    # CRLF is not a valid credential-protocol line ending.  It must fail
    # closed rather than becoming a host containing a carriage return.
    _run_cli $'protocol=https\nhost=github.com\r\nusername=u\r\npassword=p\r\n\n' \
        __default__ credential store
    _assert_cli_status 1 "CRLF credential input is rejected" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "CRLF credential input creates no fallback store" || failed=1
    rm -f "$GITSETU_CONFIG_DIR/.tokens"

    # A valid-looking prefix followed by a non-key line is malformed.  It
    # must not be treated as a complete store request.
    _run_cli $'protocol=https\nhost=github.com\nusername=u\npassword=p\nnot-a-key\n\n' \
        __default__ credential store
    _assert_cli_status 1 "malformed credential input is rejected" || failed=1
    _assert_cli_stdout "" "malformed credential input emits no secret" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "malformed credential input creates no fallback store" || failed=1
    rm -f "$GITSETU_CONFIG_DIR/.tokens"

    # Data after the blank-line terminator is also malformed, rather than an
    # invitation to silently ignore a second request.
    _run_cli $'protocol=https\nhost=github.com\nusername=u\npassword=p\n\nextra=value\n' \
        __default__ credential store
    _assert_cli_status 1 "data after the credential terminator is rejected" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "post-terminator data creates no fallback store" || failed=1
    rm -f "$GITSETU_CONFIG_DIR/.tokens"

    # Git's helper framing is blank-line terminated.  EOF without that
    # delimiter is not accepted as a complete protocol message.
    _run_cli $'protocol=https\nhost=github.com\nusername=u\npassword=p' \
        __default__ credential store
    _assert_cli_status 1 "unterminated credential input is rejected" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "unterminated credential input creates no fallback store" || failed=1
    return "$failed"
}

# Empty, root, and repository paths are distinct lower-level keys.  Host ports
# and punctuation are included to catch delimiter/regex regressions.
test_exact_tuple_isolation_and_erase_scope() {
    _setup_contract_home || return 1

    _store_silently "work" "github.com:443" "empty-user" "empty-pass" "" || return 1
    _store_silently "work" "github.com:443" "root-user" "root-pass" "/" || return 1
    _store_silently "work" "github.com:443" "repo-user" "repo-pass" "/org/repo" || return 1
    _store_silently "personal" "github.com:443" "personal-user" "personal-pass" "/org/repo" || return 1

    local output
    output=$(_get_silently "work" "github.com:443" "") || return 1
    assert_equals $'username=empty-user\npassword=empty-pass' "$output" \
        "empty path is isolated" || return 1
    output=$(_get_silently "work" "github.com:443" "/") || return 1
    assert_equals $'username=root-user\npassword=root-pass' "$output" \
        "root path is isolated" || return 1
    output=$(_get_silently "work" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=repo-user\npassword=repo-pass' "$output" \
        "repository path is isolated" || return 1
    output=$(_get_silently "personal" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=personal-user\npassword=personal-pass' "$output" \
        "profile is part of the exact tuple" || return 1

    local status=0
    _get_silently "work" "github.com:8443" "/org/repo" >/dev/null || status=$?
    assert_equals 1 "$status" "a different host port cannot cross-match" || return 1
    status=0
    _get_silently "work" "github.com:443" "/org/other" >/dev/null || status=$?
    assert_equals 1 "$status" "a different repository path cannot cross-match" || return 1

    keychain_erase "work" "github.com:443" "/org/repo" >/dev/null 2>&1 || return 1
    status=0
    _get_silently "work" "github.com:443" "/org/repo" >/dev/null || status=$?
    assert_equals 1 "$status" "erased tuple is absent" || return 1
    output=$(_get_silently "work" "github.com:443" "") || return 1
    assert_equals $'username=empty-user\npassword=empty-pass' "$output" \
        "erase leaves the empty-path tuple intact" || return 1
    output=$(_get_silently "personal" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=personal-user\npassword=personal-pass' "$output" \
        "erase leaves the other profile tuple intact" || return 1
}

# Percent escapes in a Git credential value are opaque bytes, not an implicit
# request to decode a newline.  The exact literal suffix must round-trip.
test_literal_percent_0a_suffix_roundtrips_exactly() {
    _setup_contract_home || return 1
    _store_silently "work" "github.example" "user%0A" "secret%0A" "/percent%0A" || return 1

    local output
    output=$(_get_silently "work" "github.example" "/percent%0A") || return 1
    assert_equals $'username=user%0A\npassword=secret%0A' "$output" \
        "literal percent-0A text is preserved byte-for-byte" || return 1
}

# A v2 field is hex, and decoded CR/LF bytes are never valid credential
# values.  Test both the actual trailing-newline byte and an odd-length hex
# field through the public file backend.
test_v2_trailing_newline_and_odd_hex_are_rejected() {
    _setup_contract_home || return 1
    local failed=0

    local newline_record odd_record tokens_file
    newline_record=$(_make_v2_line "work" "github.com" "/org/repo" "user" $'token\n') || return 1
    tokens_file=$(_write_tokens_fixture <<EOF
$_KEYCHAIN_CREDENTIAL_STORE_HEADER
$newline_record
EOF
    ) || return 1
    assert_file_exists "$tokens_file" "newline-corrupt fixture was written" || failed=1

    local status=0 output
    output=$(_get_silently "work" "github.com" "/org/repo") || status=$?
    assert_equals 2 "$status" "decoded trailing newline makes the v2 record malformed" || failed=1
    assert_equals "" "$output" "newline-corrupt record emits no credential" || failed=1

    odd_record=$(_make_v2_line "work" "github.com" "/org/repo" "user" "token") || return 1
    odd_record="${odd_record}a"
    tokens_file=$(_write_tokens_fixture <<EOF
$_KEYCHAIN_CREDENTIAL_STORE_HEADER
$odd_record
EOF
    ) || return 1
    status=0
    output=$(_get_silently "work" "github.com" "/org/repo") || status=$?
    assert_equals 2 "$status" "odd-length hex makes the v2 record malformed" || failed=1
    assert_equals "" "$output" "odd-hex record emits no credential" || failed=1
    return "$failed"
}

# Duplicate exact records are ambiguous, and any corrupt record must prevent a
# read-modify-write operation rather than being silently retained or replaced.
test_v2_duplicate_and_corrupt_records_fail_closed() {
    _setup_contract_home || return 1

    local record tokens_file before_file
    record=$(_make_v2_line "work" "github.com" "/org/repo" "user" "secret") || return 1
    tokens_file=$(_write_tokens_fixture <<EOF
$_KEYCHAIN_CREDENTIAL_STORE_HEADER
$record
$record
EOF
    ) || return 1
    assert_file_exists "$tokens_file" "duplicate-record fixture was written" || return 1

    local status=0 output
    output=$(_get_silently "work" "github.com" "/org/repo") || status=$?
    assert_equals 2 "$status" "duplicate exact records are ambiguous" || return 1
    assert_equals "" "$output" "duplicate exact records emit no credential" || return 1

    status=0
    keychain_erase "work" "github.com" "/org/repo" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "duplicate exact records cannot be erased by guesswork" || return 1

    local corrupt_file="$HOME/corrupt-tokens"
    cat > "$corrupt_file" <<EOF
$_KEYCHAIN_CREDENTIAL_STORE_HEADER
$record
v2\tnot-a-valid-record\textra-field\textra
EOF
    chmod 600 "$corrupt_file"
    before_file="$HOME/tokens-before"
    cp "$corrupt_file" "$before_file"
    export XDG_CONFIG_HOME="$HOME/corrupt-xdg"
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs || return 1
    corrupt_file="$GITSETU_CONFIG_DIR/.tokens"
    mkdir -p "$GITSETU_CONFIG_DIR"
    cp "$HOME/corrupt-tokens" "$corrupt_file"
    chmod 700 "$GITSETU_CONFIG_DIR"
    status=0
    _store_silently "work" "github.com" "new-user" "new-pass" "/org/repo" || status=$?
    assert_equals 1 "$status" "a corrupt v2 record blocks overwrite" || return 1
    assert_equals "$(cat "$HOME/tokens-before")" "$(cat "$GITSETU_CONFIG_DIR/.tokens")" \
        "corrupt-record rejection leaves the original file byte-for-byte intact" || return 1
}

printf '\n%btest_credential_path_contract.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "CLI path= exactness and environment override" test_cli_path_is_exact_but_env_path_can_override
run_test "CLI tolerates nonmatching records before exact match" test_cli_multiple_records_do_not_abort_on_nonmatch
run_test "CLI duplicate credential fields fail closed" test_cli_duplicate_fields_fail_closed
run_test "CLI unsupported and malformed input" test_cli_unsupported_and_malformed_input
run_test "exact profile/host/path tuple isolation" test_exact_tuple_isolation_and_erase_scope
run_test "literal percent-0A suffix roundtrip" test_literal_percent_0a_suffix_roundtrips_exactly
run_test "v2 trailing newline and odd hex rejection" test_v2_trailing_newline_and_odd_hex_are_rejected
run_test "v2 duplicate and corrupt record rejection" test_v2_duplicate_and_corrupt_records_fail_closed
print_results "Credential path contract tests"
