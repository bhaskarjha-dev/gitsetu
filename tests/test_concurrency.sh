#!/usr/bin/env bash
# tests/test_concurrency.sh — Concurrency tests for GitSetu
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

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
    
    # Spawn 20 parallel writes
    local i
    for i in {1..20}; do
        write_profiles_conf 2>/dev/null &
    done
    
    wait
    
    # Verify the file is not corrupted (should have exactly 2 lines)
    local line_count
    line_count=$(wc -l < "$GITSETU_PROFILES_CONF" | tr -d ' \t\r\n')
    # Actually, the file has a 3-line header. 3 header + 2 profiles = 5 lines.
    assert_equals "5" "$line_count" "profiles.conf has exactly 5 lines (no data dropped or interleaved)" || return 1
    
    assert_file_contains "$GITSETU_PROFILES_CONF" "global:::" "has global" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "pro::$HOME/dev/pro:github.com:0:$HOME/.ssh/id_ed25519_pro" "has pro" || return 1
}

test_atomic_headless_add() {
    GITSETU_DRY_RUN=0
    
    # Empty out existing registry if any
    rm -f "$GITSETU_PROFILES_CONF"
    
    # We will invoke the main CLI headless add in parallel 5 times
    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"
    local i
    for i in {1..5}; do
        bash "$gitsetu_bin" profile add "user${i}" --name="User ${i}" --email="user${i}@test.com" --dir="$HOME/user${i}" >/dev/null 2>&1 &
    done
    
    wait
    
    # Verify the registry contains exactly 6 profile entries (plus 3 header lines = 9 lines)
    local line_count
    line_count=$(wc -l < "$GITSETU_PROFILES_CONF" | tr -d ' \t\r\n')
    assert_equals "9" "$line_count" "profiles.conf has exactly 9 lines (global + 5 parallel profiles)" || return 1
    
    assert_file_contains "$GITSETU_PROFILES_CONF" "global:" "contains global profile" || return 1
    
    assert_file_contains "$GITSETU_PROFILES_CONF" "user1::" "has user1" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "user2::" "has user2" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "user3::" "has user3" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "user4::" "has user4" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "user5::" "has user5" || return 1
}

test_stale_lock_recovery() {
    GITSETU_DRY_RUN=0
    
    # Create the config dir
    mkdir -p "$GITSETU_CONFIG_DIR"
    
    # Artificially create a stale lock with a dead PID (e.g. 999999)
    local lock_dir="$GITSETU_CONFIG_DIR/profiles.lock"
    mkdir "$lock_dir"
    echo "999999" > "$lock_dir/pid"
    
    # Now run gitsetu headless add. It should reap the stale lock and succeed.
    local gitsetu_bin
    gitsetu_bin="$(dirname "${BASH_SOURCE[0]}")/../gitsetu"
    gitsetu_bin="${gitsetu_bin%$'\r'}"
    
    local output
    output=$(bash "$gitsetu_bin" profile add "stale-test" --name="Stale" --email="stale@test.com" --dir="$HOME/stale" 2>&1 || echo "FAILED")
    
    assert_not_contains "$output" "FAILED" "gitsetu recovered from stale lock and succeeded" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "stale-test::" "stale-test profile added successfully" || return 1
}

# --- Run ---

printf '\n%btest_concurrency.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "atomic writes survive parallel execution" test_atomic_registry_writes
run_test "POSIX lock survives parallel headless profile additions" test_atomic_headless_add
run_test "stale POSIX locks are automatically reaped" test_stale_lock_recovery
print_results "Concurrency tests"
