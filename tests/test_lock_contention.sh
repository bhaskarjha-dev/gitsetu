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
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_lock_contention.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "basic acquire_lock and release_lock lifecycle" test_acquire_and_release_basic
run_test "re-entrant locking increments and decrements depth" test_lock_reentrancy
run_test "stale lock recovery from dead PID" test_stale_lock_recovery
run_test "lock contention timeout when held by live PID" test_lock_timeout_contention
print_results "Lock Contention tests"
