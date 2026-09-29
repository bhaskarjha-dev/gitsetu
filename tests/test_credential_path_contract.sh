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
printf '%s BUILTIN\\Administrators:(F)\n' "$1"
printf '  NT AUTHORITY\\SYSTEM:(F)\n'
printf '  %s:(F)\n' "$(id -un)"
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
    # Keep ordinary tuple/lock cases on deterministic POSIX semantics. The
    # dedicated keychain suite exercises the Git Bash/NTFS DACL parser.
    export OSTYPE=linux-gnu
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

# Start one real credential CLI process at a test-only mutation barrier.  The
# barrier is reached only after the process owns the plaintext lock, making the
# critical-section ordering observable without timing the read-modify-write.
_start_barrier_cli() {
    local input="$1" barrier_dir="$2" tag="$3" action="$4"
    BARRIER_OUT="$HOME/$tag.out"
    BARRIER_ERR="$HOME/$tag.err"
    (
        : > "$barrier_dir/started.$tag"
        printf '%s' "$input" |
            GITSETU_TEST=1 \
            GITSETU_TEST_CREDENTIAL_BARRIER_DIR="$barrier_dir" \
            GITSETU_LOCK_TIMEOUT=10 \
            bash "$CONTRACT_EXE" credential "$action"
    ) >"$BARRIER_OUT" 2>"$BARRIER_ERR" &
    BARRIER_PID=$!
}

_wait_for_barrier_entry() {
    local barrier_dir="$1" process_pid="$2" minimum="${3:-1}"
    local attempts=0 count=0
    while [[ "$attempts" -lt 500 ]]; do
        count=$(find "$barrier_dir" -maxdepth 1 -type f -name 'entered.*' 2>/dev/null | wc -l | tr -d '[:space:]')
        [[ -n "$count" && "$count" -ge "$minimum" ]] && return 0
        kill -0 "$process_pid" 2>/dev/null || return 1
        attempts=$((attempts + 1))
        sleep 0.02
    done
    return 1
}

_wait_for_barrier_start() {
    local barrier_dir="$1" tag="$2" process_pid="$3"
    local attempts=0
    while [[ "$attempts" -lt 500 ]]; do
        [[ -f "$barrier_dir/started.$tag" ]] && return 0
        kill -0 "$process_pid" 2>/dev/null || return 1
        attempts=$((attempts + 1))
        sleep 0.02
    done
    return 1
}

_barrier_entry_count() {
    local barrier_dir="$1" count=""
    count=$(find "$barrier_dir" -maxdepth 1 -type f -name 'entered.*' 2>/dev/null | wc -l | tr -d '[:space:]')
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$count"
}

_wait_for_process() {
    local process_pid="$1"
    if wait "$process_pid"; then
        BARRIER_WAIT_STATUS=0
    else
        BARRIER_WAIT_STATUS=$?
    fi
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

# Setup stores its PAT in one reserved canonical scope. The Git helper keeps
# exact repository tuples authoritative, then falls back only within the same
# profile and host. Both lookup and erase must use the same compatibility rule.
test_setup_pat_scope_fallback_is_exact_and_account_isolated() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1

    local setup_scope status=0 output=""
    setup_scope=$(keychain_setup_pat_scope) || return 1
    [[ -n "$setup_scope" ]] || return 1
    _store_silently "work" "github.com" "work-user" "work-setup-pass" "$setup_scope" || return 1
    _store_silently "global" "github.com" "other-user" "other-setup-pass" "$setup_scope" || return 1

    # Low-level exact lookup remains exact; compatibility is a broker policy.
    _get_silently "work" "github.com" "/org/repo" >/dev/null || status=$?
    assert_equals 1 "$status" "setup PAT does not blur low-level path exactness" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential get
    _assert_cli_status 0 "path-scoped request retrieves the setup PAT fallback" || return 1
    _assert_cli_stdout $'username=work-user\npassword=work-setup-pass' \
        "fallback selects only the active profile's setup PAT" || return 1

    _run_cli $'protocol=https\nhost=gitlab.example\npath=/org/repo\n\n' __default__ credential get
    _assert_cli_status 1 "setup PAT fallback never crosses provider hosts" || return 1
    _assert_cli_stdout "" "cross-host fallback emits no credential" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __exact-override credential get
    _assert_cli_status 1 "explicit environment paths retain exact miss semantics" || return 1
    _assert_cli_stdout "" "exact environment override does not use setup fallback" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\nusername=repo-user\npassword=repo-pass\n\n' \
        __default__ credential store
    _assert_cli_status 0 "repository-specific credential stores normally" || return 1
    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential get
    _assert_cli_stdout $'username=repo-user\npassword=repo-pass' \
        "exact repository credential takes precedence over setup PAT" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential erase
    _assert_cli_status 0 "exact repository credential erases normally" || return 1
    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential get
    _assert_cli_status 0 "setup fallback returns after exact credential erase" || return 1
    _assert_cli_stdout $'username=work-user\npassword=work-setup-pass' \
        "exact erase leaves the profile setup PAT intact" || return 1

    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential erase
    _assert_cli_status 0 "absent exact erase falls back to the setup PAT" || return 1
    _run_cli $'protocol=https\nhost=github.com\npath=/org/repo\n\n' __default__ credential get
    _assert_cli_status 1 "fallback setup PAT is erased" || return 1
    _assert_cli_stdout "" "erased setup PAT emits no credential" || return 1

    output=$(_get_silently "global" "github.com" "$setup_scope") || return 1
    assert_equals $'username=other-user\npassword=other-setup-pass' "$output" \
        "work fallback/erase does not affect another profile" || return 1
}

# Two independent CLI writers must not both enter the plaintext mutation
# critical section. Releasing the first at the barrier lets the second proceed
# and proves that distinct records survive without a read-modify-write race.
test_concurrent_plaintext_stores_are_serialized() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1

    local barrier_dir="$HOME/store-barrier"
    local failed=0 first_pid="" second_pid="" entry_count=""
    mkdir -p "$barrier_dir"

    _start_barrier_cli $'protocol=https\nhost=github.com\npath=/one\nusername=one-user\npassword=one-pass\n\n' \
        "$barrier_dir" concurrent-store-one store
    first_pid="$BARRIER_PID"
    if ! _wait_for_barrier_entry "$barrier_dir" "$first_pid" 1; then
        : > "$barrier_dir/release"
        _wait_for_process "$first_pid"
        assert_equals 0 "$BARRIER_WAIT_STATUS" "first blocked store completed after release" || failed=1
        return "$failed"
    fi

    _start_barrier_cli $'protocol=https\nhost=github.com\npath=/two\nusername=two-user\npassword=two-pass\n\n' \
        "$barrier_dir" concurrent-store-two store
    second_pid="$BARRIER_PID"
    if ! _wait_for_barrier_start "$barrier_dir" concurrent-store-two "$second_pid"; then
        failed=1
    else
        # Let the fully started second CLI contend for the lock. It must remain
        # alive outside the barrier while the first process owns the lock.
        sleep 1
        if ! kill -0 "$second_pid" 2>/dev/null; then
            failed=1
        fi
        entry_count=$(_barrier_entry_count "$barrier_dir") || entry_count=""
        assert_equals 1 "$entry_count" "only one plaintext mutation enters the barrier" || failed=1
    fi

    : > "$barrier_dir/release"
    _wait_for_process "$first_pid"
    assert_equals 0 "$BARRIER_WAIT_STATUS" "first concurrent store succeeds" || failed=1
    if [[ -n "$second_pid" ]]; then
        _wait_for_process "$second_pid"
        assert_equals 0 "$BARRIER_WAIT_STATUS" "second concurrent store succeeds after serialization" || failed=1
    fi

    local output_one="" output_two=""
    output_one=$(_get_silently "work" "github.com" "/one") || failed=1
    assert_equals $'username=one-user\npassword=one-pass' "$output_one" \
        "first concurrent record survives" || failed=1
    output_two=$(_get_silently "work" "github.com" "/two") || failed=1
    assert_equals $'username=two-user\npassword=two-pass' "$output_two" \
        "second concurrent record is not lost" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens.mutation.lock" \
        "plaintext mutation lock is released" || failed=1
    return "$failed"
}

# Store and erase share the same cross-process lock. An erase paused in the
# critical section must block a later store, after which both operations commit.
test_concurrent_plaintext_store_and_erase_are_serialized() {
    _setup_contract_home || return 1
    _seed_cli_profile || return 1
    _store_silently "work" "github.com" "keep-user" "keep-pass" "/keep" || return 1
    _store_silently "work" "github.com" "remove-user" "remove-pass" "/remove" || return 1

    local barrier_dir="$HOME/store-erase-barrier"
    local failed=0 erase_pid="" store_pid="" entry_count=""
    mkdir -p "$barrier_dir"

    _start_barrier_cli $'protocol=https\nhost=github.com\npath=/remove\n\n' \
        "$barrier_dir" concurrent-erase erase
    erase_pid="$BARRIER_PID"
    if ! _wait_for_barrier_entry "$barrier_dir" "$erase_pid" 1; then
        : > "$barrier_dir/release"
        _wait_for_process "$erase_pid"
        return 1
    fi

    _start_barrier_cli $'protocol=https\nhost=github.com\npath=/new\nusername=new-user\npassword=new-pass\n\n' \
        "$barrier_dir" concurrent-store-after-erase store
    store_pid="$BARRIER_PID"
    if ! _wait_for_barrier_start "$barrier_dir" concurrent-store-after-erase "$store_pid"; then
        failed=1
    else
        sleep 1
        if ! kill -0 "$store_pid" 2>/dev/null; then
            failed=1
        fi
        entry_count=$(_barrier_entry_count "$barrier_dir") || entry_count=""
        assert_equals 1 "$entry_count" "store cannot enter while erase owns the mutation lock" || failed=1
    fi

    : > "$barrier_dir/release"
    _wait_for_process "$erase_pid"
    assert_equals 0 "$BARRIER_WAIT_STATUS" "concurrent erase succeeds" || failed=1
    if [[ -n "$store_pid" ]]; then
        _wait_for_process "$store_pid"
        assert_equals 0 "$BARRIER_WAIT_STATUS" "store commits after the erase releases the lock" || failed=1
    fi

    local status=0 output=""
    _get_silently "work" "github.com" "/remove" >/dev/null || status=$?
    assert_equals 1 "$status" "serialized erase removed its exact record" || failed=1
    output=$(_get_silently "work" "github.com" "/keep") || failed=1
    assert_equals $'username=keep-user\npassword=keep-pass' "$output" \
        "unrelated record survives erase/store serialization" || failed=1
    output=$(_get_silently "work" "github.com" "/new") || failed=1
    assert_equals $'username=new-user\npassword=new-pass' "$output" \
        "serialized store is retained after erase" || failed=1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens.mutation.lock" \
        "shared plaintext mutation lock is released" || failed=1
    return "$failed"
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

# The credential codec must be byte-exact for every byte value.  Encoding a
# field one character at a time with printf '%d' is broken on bash 3.2 for any
# byte >= 0x80, where the ordinal comes back as a 64-bit integer and "%02x" --
# a minimum width, not a maximum -- emits sixteen hex digits instead of two.
# Repository paths are allowed to contain UTF-8, so this is reachable.
test_hex_codec_is_byte_exact_for_non_ascii() {
    _setup_contract_home || return 1

    local input encoded decoded expected
    local -a samples=(
        '/repos/café/work'
        '/repos/プロジェクト/日本語'
        'naïve-user'
        $'raw\ttab'
        'plain-ascii-path'
    )
    local failures=0 sample

    for sample in "${samples[@]}"; do
        input="$sample"
        # od gives the authoritative expected encoding, independent of bash.
        expected=$(printf '%s' "$input" | od -A n -v -t x1 | tr -d ' \r\n')

        _keychain_hex_encode "$input" || { failures=$((failures + 1)); continue; }
        encoded="$KEYCHAIN_HEX_DECODED"
        if [[ "$encoded" != "$expected" ]]; then
            printf '    FAIL: encode mismatch for %s\n      got:      %s\n      expected: %s\n' \
                "$sample" "$encoded" "$expected" >&2
            failures=$((failures + 1))
            continue
        fi
        # And the decoded value must come back byte-identical, not merely be the
        # right length.
        _keychain_hex_decode "$encoded" || { failures=$((failures + 1)); continue; }
        decoded="$KEYCHAIN_HEX_DECODED"
        if [[ "$decoded" != "$input" ]]; then
            printf '    FAIL: round-trip mismatch for %s\n' "$sample" >&2
            failures=$((failures + 1))
        fi
    done

    # An empty field must stay empty rather than inheriting the previous value.
    _keychain_hex_encode "seeded" || return 1
    _keychain_hex_encode "" || return 1
    if [[ -n "$KEYCHAIN_HEX_DECODED" ]]; then
        printf '    FAIL: empty field encoded to %s\n' "$KEYCHAIN_HEX_DECODED" >&2
        failures=$((failures + 1))
    fi

    assert_equals "0" "$failures" \
        "credential hex codec is byte-exact for non-ASCII and empty fields" || return 1
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
run_test "setup PAT fallback is exact and account-isolated" test_setup_pat_scope_fallback_is_exact_and_account_isolated
run_test "concurrent plaintext stores are serialized" test_concurrent_plaintext_stores_are_serialized
run_test "concurrent plaintext store and erase are serialized" test_concurrent_plaintext_store_and_erase_are_serialized
run_test "CLI tolerates nonmatching records before exact match" test_cli_multiple_records_do_not_abort_on_nonmatch
run_test "CLI duplicate credential fields fail closed" test_cli_duplicate_fields_fail_closed
run_test "CLI unsupported and malformed input" test_cli_unsupported_and_malformed_input
run_test "exact profile/host/path tuple isolation" test_exact_tuple_isolation_and_erase_scope
run_test "literal percent-0A suffix roundtrip" test_literal_percent_0a_suffix_roundtrips_exactly
run_test "hex codec is byte-exact for non-ASCII fields" test_hex_codec_is_byte_exact_for_non_ascii
run_test "v2 trailing newline and odd hex rejection" test_v2_trailing_newline_and_odd_hex_are_rejected
run_test "v2 duplicate and corrupt record rejection" test_v2_duplicate_and_corrupt_records_fail_closed
print_results "Credential path contract tests"
