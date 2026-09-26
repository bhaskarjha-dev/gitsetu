#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked functions invoked dynamically or via subshells
# tests/test_lock_contention.sh — Lock Contention & Stale Lock Recovery Suite
# Verifies re-entrancy, stale lock cleanup, and contention timeouts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

reset_lock_fixture() {
    GITSETU_LOCK_DEPTH=0
    unset GITSETU_LOCK_PATH GITSETU_LOCK_TOKEN GITSETU_LOCK_PROCESS_START
    rm -rf "$GITSETU_LOCK_DIR"
}

# ------------------------------------------------------------------------------
# Test 1: acquire_lock succeeds and creates atomic lock directory with PID
# ------------------------------------------------------------------------------
test_acquire_and_release_basic() {
    rm -rf "$GITSETU_LOCK_DIR"
    GITSETU_LOCK_DEPTH=0

    acquire_lock
    assert_dir_exists "$GITSETU_LOCK_DIR" "lock directory created" || return 1
    assert_file_exists "$GITSETU_LOCK_DIR/pid" "pid file created inside lock" || return 1
    
    local recorded_pid
    recorded_pid=$(cat "$GITSETU_LOCK_DIR/pid")
    assert_equals "$$" "$recorded_pid" "lock records current process PID" || return 1

    release_lock
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "release_lock removed lock directory" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: Re-entrant locking increases depth without error
# ------------------------------------------------------------------------------
test_lock_reentrancy() {
    rm -rf "$GITSETU_LOCK_DIR"
    GITSETU_LOCK_DEPTH=0

    acquire_lock
    assert_equals "1" "${GITSETU_LOCK_DEPTH:-0}" "initial lock sets depth to 1" || return 1

    acquire_lock
    assert_equals "2" "${GITSETU_LOCK_DEPTH:-0}" "nested acquire increments depth to 2" || return 1

    release_lock
    assert_equals "1" "${GITSETU_LOCK_DEPTH:-0}" "first release decrements depth to 1" || return 1
    assert_dir_exists "$GITSETU_LOCK_DIR" "lock directory still held at depth 1" || return 1

    release_lock
    assert_equals "0" "${GITSETU_LOCK_DEPTH:-0}" "final release resets depth to 0" || return 1
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "lock directory removed when depth reaches 0" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: Stale lock recovery when holding process is dead
# ------------------------------------------------------------------------------
test_stale_lock_recovery() {
    rm -rf "$GITSETU_LOCK_DIR"
    GITSETU_LOCK_DEPTH=0

    mkdir -p "$GITSETU_LOCK_DIR"
    # Choose a PID that does not exist
    echo "999999" > "$GITSETU_LOCK_DIR/pid"
    date +%s > "$GITSETU_LOCK_DIR/timestamp"

    # acquire_lock should detect dead PID and recover
    acquire_lock
    assert_dir_exists "$GITSETU_LOCK_DIR" "acquired lock after clearing stale lock" || return 1
    
    local new_pid
    new_pid=$(cat "$GITSETU_LOCK_DIR/pid")
    assert_equals "$$" "$new_pid" "lock now owned by current PID" || return 1

    release_lock
    assert_dir_not_exists "$GITSETU_LOCK_DIR" "released cleanly" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: Lock timeout failure when lock is actively held
# ------------------------------------------------------------------------------
test_lock_timeout_contention() {
    rm -rf "$GITSETU_LOCK_DIR"
    GITSETU_LOCK_DEPTH=0

    # Simulate another live process holding the lock
    mkdir -p "$GITSETU_LOCK_DIR"
    echo "12345" > "$GITSETU_LOCK_DIR/pid"
    date +%s > "$GITSETU_LOCK_DIR/timestamp"

    # Attempt acquire with small timeout in subshell with mock live PID
    local rc=0
    (
        kill() {
            # Mock kill -0 returning 0 (process is alive)
            return 0
        }
        GITSETU_LOCK_DEPTH=0
        GITSETU_LOCK_TIMEOUT=1
        acquire_lock >/dev/null 2>&1
    ) || rc=$?

    rm -rf "$GITSETU_LOCK_DIR"

    assert_equals "1" "$rc" "acquire_lock timed out and returned 1" || return 1
}

# ------------------------------------------------------------------------------
# Adversarial ownership and replacement cases
# ------------------------------------------------------------------------------
test_lock_symlink_is_refused() {
    reset_lock_fixture
    if [[ "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "mingw"* ]]; then
        skip_test "lock symlink refusal" "MSYS/Cygwin directory-link semantics require native Windows coverage"
        return 0
    fi
    local outside="$TEST_HOME/lock-outside"
    rm -rf "$outside"
    mkdir -p "$outside"
    if ! ln -s "$outside" "$GITSETU_LOCK_DIR" 2>/dev/null; then
        skip_test "lock symlink refusal" "symlink creation is unavailable on this host"
        return 0
    fi

    local rc=0
    acquire_lock >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a symlink at the lock path is refused"
    assert_dir_exists "$outside" "symlink target is not removed"
    assert_file_not_exists "$outside/pid" "symlink target is not populated"
    rm -f "$GITSETU_LOCK_DIR"
}

test_release_rejects_wrong_path() {
    reset_lock_fixture
    acquire_lock || return 1
    local other="$TEST_HOME/other.lock"
    local rc=0
    release_lock "$other" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "release refuses a path other than the owned lock"
    assert_dir_exists "$GITSETU_LOCK_DIR" "wrong-path release preserves the owned lock"
    release_lock >/dev/null 2>&1 || return 1
}

test_release_rejects_replaced_token() {
    reset_lock_fixture
    acquire_lock || return 1
    local owned_token="$GITSETU_LOCK_TOKEN"
    printf 'attacker-token\n' > "$GITSETU_LOCK_DIR/token"
    local rc=0
    release_lock >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "release rejects a replaced ownership token"
    assert_dir_exists "$GITSETU_LOCK_DIR" "replaced-token lock is not deleted"
    printf '%s\n' "$owned_token" > "$GITSETU_LOCK_DIR/token"
    release_lock >/dev/null 2>&1 || return 1
}

test_live_owner_with_old_timestamp_is_not_reaped() {
    reset_lock_fixture
    mkdir -p "$GITSETU_LOCK_DIR"
    printf '%s\n' "$$" > "$GITSETU_LOCK_DIR/pid"
    printf '%s\n' "fixture-live-token" > "$GITSETU_LOCK_DIR/token"
    printf '%s\n' "$(_gitsetu_lock_process_start "$$" 2>/dev/null || printf '')" > "$GITSETU_LOCK_DIR/process_start"
    printf '0\n' > "$GITSETU_LOCK_DIR/timestamp"
    GITSETU_LOCK_TIMEOUT=1
    local rc=0
    acquire_lock >/dev/null 2>&1 || rc=$?
    unset GITSETU_LOCK_TIMEOUT
    assert_equals "1" "$rc" "a live owner is not reaped because its timestamp is old"
    assert_file_contains "$GITSETU_LOCK_DIR/token" "fixture-live-token" "live owner token remains"
    rm -rf "$GITSETU_LOCK_DIR"
}

test_process_start_mismatch_is_reaped() {
    reset_lock_fixture
    mkdir -p "$GITSETU_LOCK_DIR"
    printf '%s\n' "$$" > "$GITSETU_LOCK_DIR/pid"
    printf '%s\n' "old-process-token" > "$GITSETU_LOCK_DIR/token"
    printf '0\n' > "$GITSETU_LOCK_DIR/process_start"
    printf '0\n' > "$GITSETU_LOCK_DIR/timestamp"
    GITSETU_LOCK_TIMEOUT=2
    acquire_lock >/dev/null 2>&1 || {
        unset GITSETU_LOCK_TIMEOUT
        return 1
    }
    unset GITSETU_LOCK_TIMEOUT
    assert_dir_exists "$GITSETU_LOCK_DIR" "a new owner acquires a process-start-mismatched lock"
    if [[ "$(cat "$GITSETU_LOCK_DIR/token")" == "old-process-token" ]]; then
        printf '    FAIL: new owner retained the replaced lock token\n'
        return 1
    fi
    release_lock >/dev/null 2>&1 || return 1
}

# ------------------------------------------------------------------------------
# Lock parent must be private without demanding a private ancestry
# ------------------------------------------------------------------------------
# The lock parent itself must be a real, user-owned directory, but requiring
# every ancestor up to "/" to be user-owned rejects ordinary installations:
# /home and /tmp are root-owned on Linux, /Users is root-owned on macOS, and
# macOS ships /tmp and /var as symlinks into /private. This regression passed
# unnoticed on Git Bash because MSYS reports every path as owned by the caller,
# so the ownership gate was unreachable on the only platform available locally.
test_lock_parent_under_shared_ancestor_is_accepted() {
    local shared_base="" candidate
    for candidate in "${TMPDIR:-/tmp}" /tmp /var/tmp /private/tmp; do
        [[ -n "$candidate" && -d "$candidate" && -w "$candidate" ]] || continue
        shared_base="$candidate"
        break
    done
    if [[ -z "$shared_base" ]]; then
        skip_test "shared-ancestor lock parent" "no writable shared temp directory is available"
        return 0
    fi

    local parent status=0
    parent=$(umask 077 && mktemp -d "$shared_base/gitsetu-lock-ancestor.XXXXXX") || {
        printf '    FAIL: could not create a lock parent under %s\n' "$shared_base"
        return 1
    }

    _gitsetu_lock_parent_is_safe "$parent" || status=$?
    assert_equals "0" "$status" \
        "lock parent under a shared ancestor ($shared_base) is accepted" || {
        rm -rf "$parent"
        return 1
    }

    # A symlinked lock parent is still refused: that is the component an
    # attacker could redirect, and it is where the check must bite.
    local link="$parent/redirected"
    if ln -s "$parent" "$link" 2>/dev/null; then
        status=0
        _gitsetu_lock_parent_is_safe "$link" || status=$?
        assert_equals "1" "$status" "symlinked lock parent is refused" || {
            rm -rf "$parent"
            return 1
        }
    else
        skip_test "symlinked lock parent" "symlink creation is unavailable on this host"
    fi
    rm -rf "$parent"
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_lock_contention.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "basic acquire_lock and release_lock lifecycle" test_acquire_and_release_basic
run_test "re-entrant locking increments and decrements depth" test_lock_reentrancy
run_test "stale lock recovery from dead PID" test_stale_lock_recovery
run_test "lock contention timeout when held by live PID" test_lock_timeout_contention
run_test "lock symlink is refused" test_lock_symlink_is_refused
run_test "lock parent under a shared ancestor is accepted" test_lock_parent_under_shared_ancestor_is_accepted
run_test "release rejects wrong path" test_release_rejects_wrong_path
run_test "release rejects replaced token" test_release_rejects_replaced_token
run_test "live owner survives old timestamp" test_live_owner_with_old_timestamp_is_not_reaped
run_test "process-start mismatch is reaped" test_process_start_mismatch_is_reaped
print_results "Lock Contention tests"
