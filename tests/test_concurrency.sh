#!/usr/bin/env bash
# tests/test_concurrency.sh — Concurrency tests for GitSetu
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

# The product deliberately keeps its lock outside the removable config tree.
# Resolve the same lazy runtime path that child gitsetu processes will use, and
# make the test fail closed if a fixture ever points back into teardown roots.
export GITSETU_TEST_RUNTIME_DIR="${GITSETU_TEST_RUNTIME_DIR:-$HOME/.gitsetu-test-runtime}"
if ! _gitsetu_configure_lock_path; then
    printf '  [FATAL] could not configure the test runtime lock path\n' >&2
    exit 1
fi

assert_concurrency_lock_path() {
    case "$GITSETU_LOCK_DIR" in
        "$GITSETU_CONFIG_DIR"|"$GITSETU_CONFIG_DIR"/*|"$HOME/.ssh"|"$HOME/.ssh"/*)
            printf '    FAIL: lock path is inside a teardown root: %s\n' "$GITSETU_LOCK_DIR"
            return 1
            ;;
    esac
    case "$GITSETU_LOCK_DIR" in
        "$TEST_HOME"/*) ;;
        *)
            printf '    FAIL: lock path escaped the isolated test home: %s\n' "$GITSETU_LOCK_DIR"
            return 1
            ;;
    esac
    return 0
}

assert_concurrency_lock_path || exit 1

# The lock and registry behavior under test is real, but Cygwin's Win32
# fsutil/cygpath probes are needlessly expensive for these private fixtures.
# Export a test-only probe shim; ordinary symlink checks remain strict.
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
    export -f cygpath fsutil.exe
fi

seed_concurrency_global_profile() {
    rm -f -- "$GITSETU_PROFILES_CONF"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    if ! git config --global user.name "Global User" ||
       ! git config --global user.email "global@test.com"; then
        printf '    FAIL: could not seed the global Git identity\n'
        return 1
    fi
    test_v2_profile_config global "Global User" "global@test.com"
    printf '%s\n' "global-private-key" > "$HOME/.ssh/id_ed25519_global"
    printf '%s\n' "global-public-key" > "$HOME/.ssh/id_ed25519_global.pub"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
    } > "$GITSETU_PROFILES_CONF"
}

CONCURRENCY_LOCK_TIMEOUT_WAS_SET=0
CONCURRENCY_LOCK_TIMEOUT_VALUE=""
set_concurrency_test_lock_timeout() {
    if [[ -n "${GITSETU_LOCK_TIMEOUT+x}" ]]; then
        CONCURRENCY_LOCK_TIMEOUT_WAS_SET=1
        CONCURRENCY_LOCK_TIMEOUT_VALUE="$GITSETU_LOCK_TIMEOUT"
    else
        CONCURRENCY_LOCK_TIMEOUT_WAS_SET=0
        CONCURRENCY_LOCK_TIMEOUT_VALUE=""
    fi
    export GITSETU_LOCK_TIMEOUT=120
}

restore_concurrency_test_lock_timeout() {
    if [[ "$CONCURRENCY_LOCK_TIMEOUT_WAS_SET" -eq 1 ]]; then
        export GITSETU_LOCK_TIMEOUT="$CONCURRENCY_LOCK_TIMEOUT_VALUE"
    else
        unset GITSETU_LOCK_TIMEOUT
    fi
}

write_stale_lock_fixture() {
    local pid_value="${1-}"
    local age_seconds="${2:-0}"
    local include_timestamp="${3:-1}"
    local now

    rm -rf -- "$GITSETU_LOCK_DIR"
    mkdir -p "$GITSETU_LOCK_DIR" || return 1
    if [[ -n "$pid_value" ]]; then
        printf '%s\n' "$pid_value" > "$GITSETU_LOCK_DIR/pid" || return 1
    else
        : > "$GITSETU_LOCK_DIR/pid" || return 1
    fi
    printf '%s\n' "concurrency-fixture-token" > "$GITSETU_LOCK_DIR/token" || return 1
    printf '%s\n' "0" > "$GITSETU_LOCK_DIR/process_start" || return 1
    if [[ "$include_timestamp" == "1" ]]; then
        now=$(date +%s) || return 1
        printf '%s\n' "$((now - age_seconds))" > "$GITSETU_LOCK_DIR/timestamp" || return 1
    fi
    return 0
}

age_lock_directory() {
    local age_seconds="$1" now stamp
    now=$(date +%s) || return 1
    if touch -d "@$((now - age_seconds))" "$GITSETU_LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    stamp=$(date -v-"${age_seconds}"M '+%Y%m%d%H%M.%S' 2>/dev/null || printf '')
    [[ -n "$stamp" ]] || return 1
    touch -t "$stamp" "$GITSETU_LOCK_DIR" 2>/dev/null || return 1
    return 0
}

load_v2_profiles_or_fail() {
    local status=0
    load_profiles >/dev/null 2>&1 || status=$?
    return "$status"
}

test_atomic_registry_writes() {
    GITSETU_DRY_RUN=0
    
    # Simulate setup
    PROFILE_COUNT=2
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test Global" "Test Pro")
    PROFILE_EMAILS=("global@test.com" "pro@test.com")
    PROFILE_DIRS=("" "$HOME/dev/pro")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_pro")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
    
    # Spawn parallel writes, retaining each child status and diagnostic.  Five
    # contenders exercise serialization without exhausting Cygwin process slots.
    local i status output_file failed_count=0
    local -a write_pids=()
    for i in {1..5}; do
        output_file="$TEST_HOME/parallel-write-$i.log"
        rm -f "$output_file"
        write_profiles_conf >"$output_file" 2>&1 &
        write_pids+=("$!")
    done
    for i in "${!write_pids[@]}"; do
        status=0
        wait "${write_pids[$i]}" || status=$?
        if [[ "$status" -ne 0 ]]; then
            printf '    FAIL: parallel registry writer %s exited %s\n' "$i" "$status"
            if [[ -f "$TEST_HOME/parallel-write-$i.log" ]]; then
                cat "$TEST_HOME/parallel-write-$i.log"
            fi
            failed_count=$((failed_count + 1))
        fi
    done
    [[ "$failed_count" -eq 0 ]] || return 1
    rm -f "$TEST_HOME"/parallel-write-*.log
    
    # A v2 registry has one exact header plus one record per profile.
    local line_count
    line_count=$(wc -l < "$GITSETU_PROFILES_CONF" | tr -d ' \t\r\n')
    assert_equals "3" "$line_count" "v2 profiles.conf has header plus two records" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "# gitsetu-registry-v2" "has strict v2 header" || return 1
    load_v2_profiles_or_fail || return 1
    assert_equals "2" "$PROFILE_COUNT" "parallel v2 writes preserve both profiles"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global record survives parallel writes"
    assert_equals "pro" "${PROFILE_LABELS[1]}" "pro record survives parallel writes"
}

test_atomic_headless_add() {
    GITSETU_DRY_RUN=0
    set_concurrency_test_lock_timeout
    
    # Seed the mandatory global identity so children contend only on the
    # profile-add transaction.  Pre-create every key so this test measures
    # registry serialization rather than racing key generation.
    seed_concurrency_global_profile
    local i
    for i in {1..2}; do
        if ! ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519_user${i}"; then
            printf '    FAIL: could not create user%s SSH fixture key\n' "$i"
            return 1
        fi
    done

    # Invoke the main CLI headless add in parallel twice.  This is enough to
    # exercise the real lock while avoiding Cygwin process-table exhaustion.
    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"
    local i status output_file failed_count=0
    local -a add_pids=()
    for i in {1..2}; do
        output_file="$TEST_HOME/parallel-add-$i.log"
        rm -f "$output_file"
        bash "$gitsetu_bin" profile add "user${i}" --name="User ${i}" \
            --email="user${i}@test.com" --dir="$HOME/user${i}" \
            >"$output_file" 2>&1 &
        add_pids+=("$!")
    done
    for i in "${!add_pids[@]}"; do
        status=0
        wait "${add_pids[$i]}" || status=$?
        if [[ "$status" -ne 0 ]]; then
            printf '    FAIL: parallel profile-add child %s exited %s\n' "$i" "$status"
            if [[ -f "$TEST_HOME/parallel-add-$i.log" ]]; then
                cat "$TEST_HOME/parallel-add-$i.log"
            fi
            failed_count=$((failed_count + 1))
        fi
    done
    restore_concurrency_test_lock_timeout
    [[ "$failed_count" -eq 0 ]] || return 1
    rm -f "$TEST_HOME"/parallel-add-*.log
    
    # A v2 registry has one exact header plus global and two added records.
    local line_count
    line_count=$(wc -l < "$GITSETU_PROFILES_CONF" | tr -d ' \t\r\n')
    assert_equals "4" "$line_count" "v2 profiles.conf has header plus three records" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "# gitsetu-registry-v2" "contains strict v2 header" || return 1
    load_v2_profiles_or_fail || return 1
    assert_equals "3" "$PROFILE_COUNT" "parallel additions load three v2 profiles"
    local label
    for label in global user1 user2; do
        array_contains "$label" "${PROFILE_LABELS[@]}" || {
            printf '    FAIL: missing v2 profile label: %s\n' "$label"
            return 1
        }
    done
}

test_stale_lock_recovery() {
    GITSETU_DRY_RUN=0
    set_concurrency_test_lock_timeout
    assert_concurrency_lock_path || return 1
    if ! write_stale_lock_fixture "999999" 0; then
        printf '    FAIL: could not create the stale-lock fixture\n'
        return 1
    fi
    seed_concurrency_global_profile

    # Now run gitsetu headless add. It should reap the stale lock and succeed.
    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"

    local output status=0
    output=$(bash "$gitsetu_bin" profile add "stale-test" --name="Stale" \
        --email="stale@test.com" --dir="$HOME/stale" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf '    FAIL: stale-lock child exited %s\n%s\n' "$status" "$output"
        return 1
    fi
    load_v2_profiles_or_fail || return 1
    array_contains "stale-test" "${PROFILE_LABELS[@]}" || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "stale lock is reaped after successful add" || return 1
    restore_concurrency_test_lock_timeout
}

test_lock_reentrancy_and_release() {
    GITSETU_DRY_RUN=0
    assert_concurrency_lock_path || return 1
    rm -rf -- "$GITSETU_LOCK_DIR"

    # 1. Test acquire_lock and explicit release_lock
    acquire_lock || return 1
    assert_dir_exists "$GITSETU_LOCK_DIR" "lock directory exists while held" || return 1
    assert_file_exists "$GITSETU_LOCK_DIR/pid" "lock pid file exists" || return 1
    assert_file_exists "$GITSETU_LOCK_DIR/timestamp" "lock timestamp file exists" || return 1

    # 2. Test re-entrancy depth tracking
    acquire_lock || return 1
    assert_equals "2" "$GITSETU_LOCK_DEPTH" "lock depth increments to 2" || return 1

    release_lock || return 1
    assert_equals "1" "$GITSETU_LOCK_DEPTH" "lock depth decrements to 1" || return 1
    assert_dir_exists "$GITSETU_LOCK_DIR" "lock directory remains while outer depth held" || return 1

    release_lock || return 1
    assert_equals "0" "$GITSETU_LOCK_DEPTH" "lock depth is 0" || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "lock directory deleted upon final release" || return 1
}

test_stale_lock_empty_pid_recovery() {
    GITSETU_DRY_RUN=0
    set_concurrency_test_lock_timeout
    assert_concurrency_lock_path || return 1
    # An empty PID is an incomplete lock.  Include ownership metadata and an
    # old timestamp so the bounded test-mode reaper can classify it promptly.
    if ! write_stale_lock_fixture "" 70; then
        printf '    FAIL: could not create the empty-PID lock fixture\n'
        return 1
    fi
    seed_concurrency_global_profile

    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"

    local output status=0
    output=$(bash "$gitsetu_bin" profile add "empty-pid-test" --name="Test" \
        --email="empty@test.com" --dir="$HOME/empty" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf '    FAIL: empty-PID child exited %s\n%s\n' "$status" "$output"
        return 1
    fi
    load_v2_profiles_or_fail || return 1
    array_contains "empty-pid-test" "${PROFILE_LABELS[@]}" || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "empty-PID lock is reaped after successful add" || return 1
    restore_concurrency_test_lock_timeout
}

test_stale_lock_missing_timestamp_recovery() {
    GITSETU_DRY_RUN=0
    assert_concurrency_lock_path || return 1
    if ! write_stale_lock_fixture "" 70 0; then
        printf '    FAIL: could not create the missing-timestamp lock fixture\n'
        return 1
    fi
    if ! age_lock_directory 70; then
        skip_test "missing-timestamp stale lock" "filesystem cannot set directory mtime"
        rm -rf -- "$GITSETU_LOCK_DIR"
        return 0
    fi
    [[ ! -e "$GITSETU_LOCK_DIR/timestamp" ]] || return 1

    # Exercise the lock implementation directly so this regression remains
    # fast and does not depend on SSH generation or profile-discovery timing.
    GITSETU_LOCK_TIMEOUT=1
    acquire_lock || {
        printf '    FAIL: missing-timestamp lock was not reaped\n'
        return 1
    }
    assert_file_contains "$GITSETU_LOCK_DIR/pid" "$$" "missing-timestamp lock was replaced by this owner" || return 1
    release_lock || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "missing-timestamp lock is reaped after direct acquisition" || return 1
}

test_stale_lock_timeout_recovery() {
    GITSETU_DRY_RUN=0
    set_concurrency_test_lock_timeout
    assert_concurrency_lock_path || return 1
    # A live PID is authoritative regardless of age.  Use a dead PID with an
    # expired timestamp to exercise the intended stale-owner policy.
    if ! write_stale_lock_fixture "999998" 70; then
        printf '    FAIL: could not create the expired-lock fixture\n'
        return 1
    fi
    seed_concurrency_global_profile

    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"

    local output status=0
    output=$(bash "$gitsetu_bin" profile add "timeout-test" --name="Test" \
        --email="timeout@test.com" --dir="$HOME/timeout" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf '    FAIL: expired-lock child exited %s\n%s\n' "$status" "$output"
        return 1
    fi
    load_v2_profiles_or_fail || return 1
    array_contains "timeout-test" "${PROFILE_LABELS[@]}" || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "expired lock is reaped after successful add" || return 1
    restore_concurrency_test_lock_timeout
}

test_concurrent_profile_add_and_remove() {
    GITSETU_DRY_RUN=0
    set_concurrency_test_lock_timeout
    assert_concurrency_lock_path || return 1
    rm -rf -- "$GITSETU_LOCK_DIR"
    seed_concurrency_global_profile

    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"

    # Seed initial registry with base profiles and report each seed failure.
    local seed_log="$TEST_HOME/concurrency-seed.log"
    if ! bash "$gitsetu_bin" profile add "base1" --name="Base 1" \
        --email="base1@test.com" --dir="$HOME/base1" >"$seed_log" 2>&1; then
        printf '    FAIL: base1 seed child failed\n'
        cat "$seed_log"
        return 1
    fi
    if ! bash "$gitsetu_bin" profile add "base2" --name="Base 2" \
        --email="base2@test.com" --dir="$HOME/base2" >"$seed_log" 2>&1; then
        printf '    FAIL: base2 seed child failed\n'
        cat "$seed_log"
        return 1
    fi
    rm -f "$seed_log"

    # Concurrently spawn adds and a remove; retain each child status/log.
    local -a child_pids=()
    local -a child_names=()
    local -a child_logs=()
    local name log
    for name in add1 add2 remove-base2; do
        log="$TEST_HOME/concurrency-$name.log"
        rm -f "$log"
        child_names+=("$name")
        child_logs+=("$log")
    done
    bash "$gitsetu_bin" profile add "add1" --name="Add 1" \
        --email="add1@test.com" --dir="$HOME/add1" >"${child_logs[0]}" 2>&1 &
    child_pids+=("$!")
    bash "$gitsetu_bin" profile add "add2" --name="Add 2" \
        --email="add2@test.com" --dir="$HOME/add2" >"${child_logs[1]}" 2>&1 &
    child_pids+=("$!")
    bash "$gitsetu_bin" profile remove "base2" >"${child_logs[2]}" 2>&1 &
    child_pids+=("$!")

    local i status failed_count=0
    for i in "${!child_pids[@]}"; do
        status=0
        wait "${child_pids[$i]}" || status=$?
        if [[ "$status" -ne 0 ]]; then
            printf '    FAIL: %s child exited %s\n' "${child_names[$i]}" "$status"
            if [[ -f "${child_logs[$i]}" ]]; then
                cat "${child_logs[$i]}"
            fi
            failed_count=$((failed_count + 1))
        fi
    done
    restore_concurrency_test_lock_timeout
    [[ "$failed_count" -eq 0 ]] || return 1
    rm -f "$TEST_HOME"/concurrency-*.log

    # Verify the strict v2 registry through its real loader.
    load_v2_profiles_or_fail || return 1
    ! array_contains "base2" "${PROFILE_LABELS[@]}" || return 1
    array_contains "base1" "${PROFILE_LABELS[@]}" || return 1
    array_contains "add1" "${PROFILE_LABELS[@]}" || return 1
    array_contains "add2" "${PROFILE_LABELS[@]}" || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "parallel profile mutations release the runtime lock" || return 1
}

# --- Run ---

printf '\n%btest_concurrency.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "atomic writes survive parallel execution" test_atomic_registry_writes
run_test "runtime lock survives parallel headless profile additions" test_atomic_headless_add
run_test "stale runtime locks are automatically reaped" test_stale_lock_recovery
run_test "lock re-entrancy and explicit release contract" test_lock_reentrancy_and_release
run_test "stale lock empty PID recovery" test_stale_lock_empty_pid_recovery
run_test "stale lock missing timestamp recovery" test_stale_lock_missing_timestamp_recovery
run_test "stale lock 60s timeout recovery" test_stale_lock_timeout_recovery
run_test "concurrent profile add and remove serialization" test_concurrent_profile_add_and_remove
print_results "Concurrency tests"
