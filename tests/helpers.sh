#!/usr/bin/env bash
# tests/helpers.sh — Minimal test framework for gitsetu
#
# Zero dependencies. Pure bash. Bash 3.2 compatible.
# Provides assertion functions and isolated $HOME management.

set -euo pipefail

# ------------------------------------------------------------------------------
# Test counters
# ------------------------------------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Colors (simplified)
if [[ -t 1 ]]; then
    T_RED='\033[0;31m'
    T_GREEN='\033[0;32m'
    T_DIM='\033[2m'
    T_BOLD='\033[1m'
    T_RESET='\033[0m'
else
    # shellcheck disable=SC2034
    T_RED='' T_GREEN='' T_DIM='' T_BOLD='' T_RESET=''
fi

# ------------------------------------------------------------------------------
# Test lifecycle
# ------------------------------------------------------------------------------

# Run a test function by name. Captures failures.
# Usage: run_test "test_description" test_function_name
run_test() {
    local description="$1"
    local func="$2"
    # shellcheck disable=SC2034
    CURRENT_TEST="$description"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Run the test, capture exit code
    local result=0
    "$func" || result=$?

    if [[ "$result" -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '  %b✔%b %s\n' "$T_GREEN" "$T_RESET" "$description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  %b✖%b %s\n' "$T_RED" "$T_RESET" "$description"
    fi
}

# Print final results summary
print_results() {
    local suite_name="${1:-Tests}"
    printf '\n  %b%s: %d passed, %d failed, %d total%b\n\n' \
        "$T_BOLD" "$suite_name" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_RUN" "$T_RESET"

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Assertions
# All assertions return 0 (pass) or 1 (fail) with an error message.
# ------------------------------------------------------------------------------

# Assert two strings are equal
assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_equals}"
    printf '      Expected: "%s"\n' "$expected"
    printf '      Actual:   "%s"\n' "$actual"
    return 1
}

# Assert string contains substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_contains}"
    printf '      String does not contain: "%s"\n' "$needle"
    printf '      In: "%s"\n' "$haystack"
    return 1
}

# Assert string does NOT contain substring
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_not_contains}"
    printf '      String should not contain: "%s"\n' "$needle"
    return 1
}

# Assert file exists
assert_file_exists() {
    local path="$1"
    local msg="${2:-}"

    if [[ -f "$path" ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_file_exists}"
    printf '      File not found: %s\n' "$path"
    return 1
}

# Assert directory exists
assert_dir_exists() {
    local path="$1"
    local msg="${2:-}"

    if [[ -d "$path" ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_dir_exists}"
    printf '      Directory not found: %s\n' "$path"
    return 1
}

# Assert directory does NOT exist
assert_dir_not_exists() {
    local path="$1"
    local msg="${2:-}"

    if [[ ! -d "$path" ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_dir_not_exists}"
    printf '      Directory should not exist: %s\n' "$path"
    return 1
}

# Assert file contains a string
assert_file_contains() {
    local path="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ ! -f "$path" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_file_contains}"
        printf '      File not found: %s\n' "$path"
        return 1
    fi

    if grep -qF "$needle" "$path"; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_file_contains}"
    printf '      File does not contain: "%s"\n' "$needle"
    printf '      In: %s\n' "$path"
    return 1
}

# Assert file does NOT contain a string
assert_file_not_contains() {
    local path="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ ! -f "$path" ]]; then
        # File doesn't exist → it can't contain the string
        return 0
    fi

    if ! grep -qF "$needle" "$path"; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_file_not_contains}"
    printf '      File should not contain: "%s"\n' "$needle"
    printf '      In: %s\n' "$path"
    return 1
}

# Assert exit code of a command
assert_exit_code() {
    local expected="$1"
    shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?

    if [[ "$actual" -eq "$expected" ]]; then
        return 0
    fi

    printf '    FAIL: assert_exit_code\n'
    printf '      Expected exit code: %d\n' "$expected"
    printf '      Actual exit code:   %d\n' "$actual"
    printf '      Command: %s\n' "$*"
    return 1
}

# Check if chmod 600 is honored on the current $HOME filesystem.
# Some CI runners, container mounts, and VM shared folders ignore chmod.
# Usage: if can_chmod_600; then ... fi
can_chmod_600() {
    local test_file
    test_file=$(mktemp "$HOME/.chmod_test.XXXXXX")
    chmod 600 "$test_file"
    local perms
    perms=$(stat -c '%a' "$test_file" 2>/dev/null || stat -f '%Lp' "$test_file" 2>/dev/null || echo "???")
    rm -f "$test_file"
    [[ "$perms" == "600" ]]
}

# ------------------------------------------------------------------------------
# Test HOME isolation
# Creates a temporary directory to use as $HOME so tests don't touch real config.
# ------------------------------------------------------------------------------

ORIGINAL_HOME=""
TEST_HOME=""

setup_test_home() {
    ORIGINAL_HOME="$HOME"
    TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-test.XXXXXX")
    if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]]; then
        TEST_HOME=$(cd "$TEST_HOME" && pwd -W)
    else
        TEST_HOME=$(cd "$TEST_HOME" && pwd -P)
    fi
    export HOME="$TEST_HOME"
    unset XDG_CONFIG_HOME
    mkdir -p "$HOME/.ssh"
    mkdir -p "$HOME/.config"
}

teardown_test_home() {
    if [[ -n "$TEST_HOME" ]] && [[ -d "$TEST_HOME" ]]; then
        rm -rf "$TEST_HOME"
    fi
    if [[ -n "$ORIGINAL_HOME" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
    TEST_HOME=""
    ORIGINAL_HOME=""
}

# Cleanup on exit
trap teardown_test_home EXIT

# ------------------------------------------------------------------------------
# Source gitsetu modules for testing
# ------------------------------------------------------------------------------
source_gitsetu_libs() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

    source "$script_dir/lib/core.sh"
    source "$script_dir/lib/platform.sh"
    source "$script_dir/lib/ui.sh"
    source "$script_dir/lib/validate.sh"
    source "$script_dir/lib/backup.sh"
    source "$script_dir/lib/ssh.sh"
    source "$script_dir/lib/gitconfig.sh"
    source "$script_dir/lib/guard.sh"
    source "$script_dir/lib/verify.sh"
    source "$script_dir/lib/teardown.sh"
    source "$script_dir/lib/discovery.sh"
    source "$script_dir/lib/setup.sh"
    source "$script_dir/lib/doctor.sh"
    source "$script_dir/lib/keychain.sh"
    
    detect_os
}
