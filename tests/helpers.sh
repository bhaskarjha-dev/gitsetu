#!/usr/bin/env bash
# tests/helpers.sh — Minimal, fail-closed test framework for gitsetu
#
# Zero dependencies. Pure bash. Bash 3.2 compatible.
# Provides assertion functions, a failure latch that survives subshells, and
# isolated $HOME/environment management.

set -euo pipefail

# ------------------------------------------------------------------------------
# Test counters and result state
# ------------------------------------------------------------------------------
# Keep the initialized state when a suite sources helpers a second time from a
# function or a generated fixture.  Only a fresh shell starts a new run.
_TEST_HELPERS_INITIALIZED="${_TEST_HELPERS_INITIALIZED:-0}"
if [[ "$_TEST_HELPERS_INITIALIZED" -eq 0 ]]; then
    TESTS_RUN=0
    TESTS_PASSED=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0
    CURRENT_TEST=""
    CURRENT_TEST_SKIPPED=0
    CURRENT_TEST_SKIP_REASON=""

    # The latch has two representations:
    #   * shell variables, for failures in the current process; and
    #   * a file, for failures in a subshell, pipeline component, or command
    #     substitution (where shell variables cannot propagate to the parent).
    _TEST_HAS_FAILURE=0
    # _TEST_FAILED is retained as a compatibility alias for callers that used
    # the name from the original audit plan.
    _TEST_FAILED=0
    _TEST_FAILURE_FILE=""
    _TEST_LATCH_IO_ERROR=0
    _TEST_IN_RUN=0
    TEST_LAST_STATUS=""
fi

# Colors (simplified)
if [[ -t 1 ]]; then
    T_RED='\033[0;31m'
    T_GREEN='\033[0;32m'
    T_YELLOW='\033[0;33m'
    T_DIM='\033[2m'
    T_BOLD='\033[1m'
    T_RESET='\033[0m'
else
    # shellcheck disable=SC2034
    T_RED='' T_GREEN='' T_YELLOW='' T_DIM='' T_BOLD='' T_RESET=''
fi

# ------------------------------------------------------------------------------
# Internal, portable test-environment state
# ------------------------------------------------------------------------------
if [[ "$_TEST_HELPERS_INITIALIZED" -eq 0 ]]; then
    TEST_STATE_DIR=""
    _TEST_STATE_DIR_OWNED=0
    _TEST_SYNTAX_CACHE_FILE=""
    _TEST_GITSETU_LIBS_READY=0
    _TEST_GITSETU_SOURCE_CONFIG_DIR=""
    _TEST_SKIP_ENV_SNAPSHOT=0
    _TEST_ORIGINAL_ENV_SAVED=0
    _TEST_ORIGINAL_LATCH_SET=0
    _TEST_ORIGINAL_LATCH_VALUE=""
    _TEST_EXIT_CLEANUP_RUNNING=0

    ORIGINAL_HOME=""
    TEST_HOME=""
    TEST_HOME_STACK=()
    TEST_ENV_STACK=()
fi

# These are the non-prefixed/platform variables which can redirect Git, SSH,
# Windows tools, or CI behavior.  The prefix patterns are handled separately.
_TEST_MANAGED_ENV_NAMES=(
    HOME
    USERPROFILE
    HOMEDRIVE
    HOMEPATH
    APPDATA
    LOCALAPPDATA
    XDG_CONFIG_HOME
    XDG_DATA_HOME
    XDG_STATE_HOME
    XDG_CACHE_HOME
    XDG_RUNTIME_DIR
    GIT_CONFIG_GLOBAL
    GIT_CONFIG_SYSTEM
    GIT_CONFIG_NOSYSTEM
    GIT_CONFIG_COUNT
    GIT_CONFIG_KEY_0
    GIT_CONFIG_VALUE_0
    GIT_AUTHOR_NAME
    GIT_AUTHOR_EMAIL
    GIT_COMMITTER_NAME
    GIT_COMMITTER_EMAIL
    GIT_NAME
    GIT_EMAIL
    GIT_CEILING_DIRECTORIES
    GIT_DISCOVERY_ACROSS_FILESYSTEM
    GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_INDEX_FILE
    GIT_COMMON_DIR
    GIT_NAMESPACE
    GIT_OPTIONAL_LOCKS
    GIT_PAGER
    GIT_EDITOR
    GIT_SEQUENCE_EDITOR
    GIT_EXTERNAL_DIFF
    GIT_DIFF_OPTS
    GIT_ATTR_NOSYSTEM
    GIT_ASKPASS
    SSH_ASKPASS
    SSH_AUTH_SOCK
    SSH_AGENT_PID
    GIT_SSH_COMMAND
    GIT_SSH
    GIT_PROXY_COMMAND
    GIT_TERMINAL_PROMPT
    GIT_DIR
    GIT_WORK_TREE
    CI
    CONTINUOUS_INTEGRATION
    GITHUB_ACTIONS
    BUILD_BUILDID
)

# ------------------------------------------------------------------------------
# Failure latch plumbing
# ------------------------------------------------------------------------------

# Keep the harness's own path out of the environment-neutralization rules.  It
# is deliberately test-only and is exported so a child Bash which sources this
# file can report an assertion failure back to the parent runner.
_test_is_internal_name() {
    case "$1" in
        GITSETU_TEST_LATCH_FILE|GITSETU_TEST_STATE_DIR|TEST_FAILURE_LATCH_FILE)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_test_is_managed_env_name() {
    local name="$1"

    _test_is_internal_name "$name" && return 1

    case "$name" in
        GITSETU_*|GIT_CONFIG_*|XDG_*)
            return 0
            ;;
    esac

    local fixed
    for fixed in "${_TEST_MANAGED_ENV_NAMES[@]}"; do
        if [[ "$name" == "$fixed" ]]; then
            return 0
        fi
    done
    return 1
}

_test_ensure_latch_file() {
    if [[ -z "$_TEST_FAILURE_FILE" ]]; then
        _TEST_FAILURE_FILE="$TEST_STATE_DIR/failure.latch"
    fi
    if [[ ! -e "$_TEST_FAILURE_FILE" ]]; then
        if ! : > "$_TEST_FAILURE_FILE"; then
            printf '  [FATAL] unable to create test failure latch: %s\n' \
                "$_TEST_FAILURE_FILE" >&2
            return 1
        fi
    fi
    export GITSETU_TEST_LATCH_FILE="$_TEST_FAILURE_FILE"
    TEST_FAILURE_LATCH_FILE="$_TEST_FAILURE_FILE"
}

_test_reset_failure_latch() {
    _TEST_HAS_FAILURE=0
    _TEST_FAILED=0
    _TEST_LATCH_IO_ERROR=0
    CURRENT_TEST_SKIPPED=0
    CURRENT_TEST_SKIP_REASON=""

    if [[ -n "$_TEST_FAILURE_FILE" ]]; then
        if ! : > "$_TEST_FAILURE_FILE"; then
            _TEST_LATCH_IO_ERROR=1
            return 1
        fi
    fi
    return 0
}

_test_failure_file_has_failure() {
    [[ -n "$_TEST_FAILURE_FILE" && -s "$_TEST_FAILURE_FILE" ]]
}

# Mark a failure in both the current shell and the cross-process latch.  The
# function itself always returns success so callers can print their assertion
# details and then return their normal assertion status.
mark_test_failure() {
    _TEST_HAS_FAILURE=1
    _TEST_FAILED=1

    if [[ -n "$_TEST_FAILURE_FILE" ]]; then
        if ! printf 'assertion failure\n' >> "$_TEST_FAILURE_FILE" 2>/dev/null; then
            _TEST_LATCH_IO_ERROR=1
        fi
    fi
    return 0
}

_test_assertion_failed() {
    # Keep this in one place so every assertion failure updates both latch
    # representations.  The caller supplies its user-facing diagnostics.
    mark_test_failure
    return 0
}

# Reset a latch after a deliberately expected failure in a contract test.  This
# is public so a test can exercise an assertion without making its own case
# red; normal tests should not need it.
reset_test_failure_latch() {
    _test_reset_failure_latch
}

# ------------------------------------------------------------------------------
# Test lifecycle
# ------------------------------------------------------------------------------

# Record an explicit skip.  When called from a function invoked by run_test,
# run_test owns the counter update so the case is counted exactly once.  When
# called by a standalone test script, it is counted immediately.
skip_test() {
    local description="${1:-test skipped}"
    local reason="${2:-no reason supplied}"

    if [[ "$CURRENT_TEST_SKIPPED" -ne 0 ]]; then
        return 0
    fi
    CURRENT_TEST_SKIPPED=1
    CURRENT_TEST_SKIP_REASON="$reason"

    if [[ "$_TEST_IN_RUN" -eq 0 ]]; then
        printf '  [SKIP] %s (%s)\n' "$description" "$reason"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    fi
    return 0
}

# Run a test function by name.  The function is intentionally invoked in a
# conditional context so one failed assertion does not abort a suite before its
# summary is printed.  The explicit assertion latch and the function status are
# both honored.  Latch I/O is checked as well, so a broken harness cannot turn
# a failed assertion into a pass.
# Usage: run_test "test_description" test_function_name
run_test() {
    local description="$1"
    local func="$2"
    local result=0
    local depth_before=0
    local env_snapshot=""
    local cleanup_result=0

    CURRENT_TEST="$description"
    TESTS_RUN=$((TESTS_RUN + 1))
    _TEST_IN_RUN=1
    depth_before=${#TEST_HOME_STACK[@]}

    if ! _test_reset_failure_latch; then
        result=1
    fi

    if ! _test_ensure_latch_file; then
        result=1
    fi

    # Preserve the environment around each case.  This prevents a failed case
    # from leaking a vault password, a Git override, or a CI switch into the
    # next case, while still allowing the isolated HOME itself to persist for
    # suites that intentionally share files between cases.
    if [[ "${_TEST_SKIP_ENV_SNAPSHOT:-0}" -eq 0 &&
          -n "$TEST_STATE_DIR" && -d "$TEST_STATE_DIR" ]]; then
        env_snapshot="$TEST_STATE_DIR/run-env.$$.$TESTS_RUN"
        if ! _test_snapshot_environment "$env_snapshot"; then
            result=1
        fi
    fi

    if ! declare -F "$func" >/dev/null 2>&1; then
        printf '    FAIL: undefined test function: %s\n' "$func"
        mark_test_failure
        result=127
    else
        # shellcheck disable=SC2310
        "$func" || result=$?
    fi

    if _test_failure_file_has_failure || [[ "$_TEST_LATCH_IO_ERROR" -ne 0 ]]; then
        result=1
    fi

    # A conventional exit 77 is also an explicit skip for small standalone
    # test functions.  A failure latch always wins over a skip.  Keep
    # _TEST_IN_RUN set while normalizing the status so skip_test cannot double
    # increment the counters.
    if [[ "$result" -eq 77 ]] && ! _test_failure_file_has_failure && [[ "$_TEST_LATCH_IO_ERROR" -eq 0 ]]; then
        if [[ "$CURRENT_TEST_SKIPPED" -eq 0 ]]; then
            skip_test "$description" "test returned 77"
        fi
        result=0
    fi
    _TEST_IN_RUN=0

    if [[ "$CURRENT_TEST_SKIPPED" -eq 1 && "$result" -eq 0 ]]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        result=0
        TEST_LAST_STATUS="SKIP"
        printf '  %b[SKIP]%b %s%s\n' "$T_YELLOW" "$T_RESET" "$description" \
            "${CURRENT_TEST_SKIP_REASON:+ ($CURRENT_TEST_SKIP_REASON)}"
    elif [[ "$result" -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TEST_LAST_STATUS="PASS"
        printf '  %b[PASS]%b %s\n' "$T_GREEN" "$T_RESET" "$description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TEST_LAST_STATUS="FAIL"
        printf '  %b[FAIL]%b %s\n' "$T_RED" "$T_RESET" "$description"
    fi

    # A test which created nested test homes must not leave the next test in a
    # child sandbox.  Existing top-level test homes remain intact.
    while [[ "${#TEST_HOME_STACK[@]}" -gt "$depth_before" ]]; do
        if ! teardown_test_home; then
            cleanup_result=1
        fi
    done

    if [[ -n "$env_snapshot" ]]; then
        if ! _test_restore_environment "$env_snapshot"; then
            cleanup_result=1
        fi
        rm -f "$env_snapshot"
    fi

    if [[ "$cleanup_result" -ne 0 ]]; then
        # The result was already counted above.  Convert that single result to
        # FAIL rather than incrementing a second counter entry for the same
        # test (which would make the total exceed TESTS_RUN).
        case "$TEST_LAST_STATUS" in
            PASS)
                TESTS_PASSED=$((TESTS_PASSED - 1))
                TESTS_FAILED=$((TESTS_FAILED + 1))
                ;;
            SKIP)
                TESTS_SKIPPED=$((TESTS_SKIPPED - 1))
                TESTS_FAILED=$((TESTS_FAILED + 1))
                ;;
            FAIL)
                ;;
            *)
                TESTS_FAILED=$((TESTS_FAILED + 1))
                ;;
        esac
        printf '  %b[FAIL]%b %s (test environment cleanup failed)\n' \
            "$T_RED" "$T_RESET" "$description"
        TEST_LAST_STATUS="FAIL"
    fi

    _TEST_HAS_FAILURE=0
    _TEST_FAILED=0
    return 0
}

# Print final results summary.  PASS, FAIL, and SKIP are intentionally
# separate; a skipped case is never silently counted as a pass.
print_results() {
    local suite_name="${1:-Tests}"
    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

    printf '\n  %b%s: %d passed, %d failed, %d skipped, %d total%b\n\n' \
        "$T_BOLD" "$suite_name" "$TESTS_PASSED" "$TESTS_FAILED" \
        "$TESTS_SKIPPED" "$total" "$T_RESET"

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Assertions
# All assertions return 0 (pass) or 1 (fail) with an error message.  Every
# failure branch records the latch, including input-contract failures.
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
    _test_assertion_failed
    return 1
}

# Assert string contains substring.  Empty needles are rejected: otherwise the
# assertion is true for every input and provides no coverage.
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ -z "$needle" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_contains}"
        printf '      Needle must not be empty.\n'
        _test_assertion_failed
        return 1
    fi

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_contains}"
    printf '      String does not contain: "%s"\n' "$needle"
    printf '      In: "%s"\n' "$haystack"
    _test_assertion_failed
    return 1
}

# Assert string does NOT contain substring
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ -z "$needle" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_not_contains}"
        printf '      Needle must not be empty.\n'
        _test_assertion_failed
        return 1
    fi

    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_not_contains}"
    printf '      String should not contain: "%s"\n' "$needle"
    _test_assertion_failed
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
    _test_assertion_failed
    return 1
}

# Assert file does not exist.  This is intentionally separate from a negative
# content assertion: a missing file is not evidence that its contents are safe.
assert_file_not_exists() {
    local path="$1"
    local msg="${2:-}"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_file_not_exists}"
    printf '      File should not exist: %s\n' "$path"
    _test_assertion_failed
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
    _test_assertion_failed
    return 1
}

# Assert directory does NOT exist
assert_dir_not_exists() {
    local path="$1"
    local msg="${2:-}"

    if [[ ! -d "$path" && ! -L "$path" ]]; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_dir_not_exists}"
    printf '      Directory should not exist: %s\n' "$path"
    _test_assertion_failed
    return 1
}

# Assert file contains a string
assert_file_contains() {
    local path="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ -z "$needle" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_file_contains}"
        printf '      Needle must not be empty.\n'
        _test_assertion_failed
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_file_contains}"
        printf '      File not found: %s\n' "$path"
        _test_assertion_failed
        return 1
    fi

    if grep -qF -e "$needle" "$path"; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_file_contains}"
    printf '      File does not contain: "%s"\n' "$needle"
    printf '      In: %s\n' "$path"
    _test_assertion_failed
    return 1
}

# Assert file does NOT contain a string.  Unlike the historical version, a
# missing or empty file is a failed contract rather than a vacuous pass.
assert_file_not_contains() {
    local path="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ -z "$needle" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_file_not_contains}"
        printf '      Needle must not be empty.\n'
        _test_assertion_failed
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_file_not_contains}"
        printf '      File not found (negative assertions require an existing file): %s\n' "$path"
        _test_assertion_failed
        return 1
    fi

    if [[ ! -s "$path" ]]; then
        printf '    FAIL: %s\n' "${msg:-assert_file_not_contains}"
        printf '      File is empty (negative assertions require a non-empty fixture): %s\n' "$path"
        _test_assertion_failed
        return 1
    fi

    if ! grep -qF -e "$needle" "$path"; then
        return 0
    fi

    printf '    FAIL: %s\n' "${msg:-assert_file_not_contains}"
    printf '      File should not contain: "%s"\n' "$needle"
    printf '      In: %s\n' "$path"
    _test_assertion_failed
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
    _test_assertion_failed
    return 1
}

# Check if chmod 600 is honored on the current $HOME filesystem.
# Some CI runners, container mounts, and VM shared folders ignore chmod.
# Usage: if can_chmod_600; then ...; else skip_test ...; fi
can_chmod_600() {
    local test_file
    if ! test_file=$(umask 077; mktemp "$HOME/.chmod_test.XXXXXX"); then
        return 1
    fi
    if ! chmod 600 "$test_file"; then
        rm -f "$test_file"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "$test_file" 2>/dev/null || stat -f '%Lp' "$test_file" 2>/dev/null || echo "???")
    rm -f "$test_file"
    [[ "$perms" == "600" ]]
}

# ------------------------------------------------------------------------------
# Environment snapshots and test HOME isolation
# ------------------------------------------------------------------------------

_test_snapshot_one_env() {
    local snapshot="$1"
    local name="$2"
    local declaration=""
    local serialized=""

    if ! _test_is_managed_env_name "$name"; then
        return 0
    fi

    if ! declaration=$(declare -p "$name" 2>/dev/null); then
        printf 'unset %s\n' "$name" >> "$snapshot"
        return 0
    fi

    # Shell arrays are test/process state, not inherited environment.  Keep
    # them intact; setup_test_home controls scalar configuration variables.
    case "$declaration" in
        declare\ -[aA]*|typeset\ -[aA]*)
            return 0
            ;;
    esac

    printf -v serialized '%q' "${!name}"
    case "$declaration" in
        declare\ -x*|typeset\ -x*)
            printf 'export %s=%s\n' "$name" "$serialized" >> "$snapshot"
            ;;
        *)
            printf '%s=%s\n' "$name" "$serialized" >> "$snapshot"
            ;;
    esac
    return 0
}

# Capture scalar shell/environment variables which can affect a test.  The
# generated lines contain only shell assignments or unset commands; values are
# escaped with printf %q, so restoring a value never evaluates it as input.
_test_snapshot_environment() {
    local snapshot="$1"
    local name

    if ! : > "$snapshot"; then
        return 1
    fi

    for name in "${_TEST_MANAGED_ENV_NAMES[@]}"; do
        _test_snapshot_one_env "$snapshot" "$name"
    done

    # Include dynamically introduced GitSetu/Git/XDG variables as well.  A
    # duplicate fixed entry is harmless and keeps this Bash-3.2-safe.
    while IFS= read -r name; do
        case "$name" in
            GITSETU_*|GIT_CONFIG_*|XDG_*)
                _test_snapshot_one_env "$snapshot" "$name"
                ;;
        esac
    done < <(compgen -v)
    return 0
}

_test_clear_managed_environment() {
    local name declaration

    while IFS= read -r name; do
        if ! _test_is_managed_env_name "$name"; then
            continue
        fi
        if _test_is_internal_name "$name"; then
            continue
        fi

        if declaration=$(declare -p "$name" 2>/dev/null); then
            case "$declaration" in
                declare\ -[aArR]*|typeset\ -[aArR]*)
                    continue
                    ;;
            esac
        fi
        unset "$name"
    done < <(compgen -v)
    return 0
}

_test_restore_environment() {
    local snapshot="$1"
    local line

    _test_clear_managed_environment
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            unset\ *|export\ *=*|[A-Za-z_][A-Za-z0-9_]*=*)
                eval "$line"
                ;;
            '' )
                ;;
            *)
                printf '    [WARN] ignoring malformed test environment snapshot line\n' >&2
                return 1
                ;;
        esac
    done < "$snapshot"
    return 0
}

_test_initialize_state() {
    local state_template="${TMPDIR:-/tmp}/gitsetu-test-state.XXXXXX"
    local inherited_latch="${GITSETU_TEST_LATCH_FILE:-}"
    if [[ -n "${GITSETU_TEST_LATCH_FILE+x}" ]]; then
        _TEST_ORIGINAL_LATCH_SET=1
        _TEST_ORIGINAL_LATCH_VALUE="$inherited_latch"
    fi

    if ! TEST_STATE_DIR=$(umask 077; mktemp -d "$state_template"); then
        printf '  [FATAL] unable to create test state directory\n' >&2
        return 1
    fi
    _TEST_STATE_DIR_OWNED=1
    _TEST_SYNTAX_CACHE_FILE="$TEST_STATE_DIR/module-syntax.cache"
    if ! : > "$_TEST_SYNTAX_CACHE_FILE"; then
        printf '  [FATAL] unable to create module syntax cache\n' >&2
        return 1
    fi
    if [[ -n "$inherited_latch" ]]; then
        _TEST_FAILURE_FILE="$inherited_latch"
    else
        _TEST_FAILURE_FILE="$TEST_STATE_DIR/failure.latch"
    fi
    _test_ensure_latch_file
    if ! _test_snapshot_environment "$TEST_STATE_DIR/original.env"; then
        return 1
    fi
    _TEST_ORIGINAL_ENV_SAVED=1
    ORIGINAL_HOME="${HOME-}"
    return 0
}

_test_restore_latch_variable() {
    if [[ "$_TEST_ORIGINAL_LATCH_SET" -eq 1 ]]; then
        export GITSETU_TEST_LATCH_FILE="$_TEST_ORIGINAL_LATCH_VALUE"
    else
        unset GITSETU_TEST_LATCH_FILE
    fi
}

_test_restore_original_environment() {
    if [[ "$_TEST_ORIGINAL_ENV_SAVED" -eq 1 && -f "$TEST_STATE_DIR/original.env" ]]; then
        _test_restore_environment "$TEST_STATE_DIR/original.env"
    fi
    _test_restore_latch_variable
}

_test_exit_cleanup() {
    local exit_status=$?
    local cleanup_status=0

    if [[ "$_TEST_EXIT_CLEANUP_RUNNING" -eq 1 ]]; then
        exit "$exit_status"
    fi
    _TEST_EXIT_CLEANUP_RUNNING=1
    trap - EXIT

    # A suite may have changed HOME directly or created several nested homes.
    # Restore the complete stack before putting the source-time environment
    # back.  Every command is conditional so cleanup itself cannot abort early.
    while [[ "${#TEST_HOME_STACK[@]}" -gt 0 ]]; do
        if ! teardown_test_home; then
            cleanup_status=1
        fi
    done
    if ! _test_restore_original_environment; then
        cleanup_status=1
    fi

    if [[ "$_TEST_STATE_DIR_OWNED" -eq 1 && -n "$TEST_STATE_DIR" && -d "$TEST_STATE_DIR" ]]; then
        if ! rm -rf "$TEST_STATE_DIR"; then
            cleanup_status=1
        fi
    fi

    if [[ "$cleanup_status" -ne 0 && "$exit_status" -eq 0 ]]; then
        exit_status=1
    fi
    exit "$exit_status"
}

# Create a temporary directory to use as $HOME so tests don't touch real
# configuration.  Calls are stacked: teardown pops one sandbox and restores the
# environment which was active before that call.  The original environment is
# captured once and restored by the EXIT trap.
setup_test_home() {
    local frame_index=${#TEST_HOME_STACK[@]}
    local snapshot="$TEST_STATE_DIR/env.$$.$frame_index"
    local new_home=""

    if [[ -z "$TEST_STATE_DIR" || ! -d "$TEST_STATE_DIR" ]]; then
        printf '  [FATAL] test state directory is unavailable\n' >&2
        return 1
    fi

    if ! _test_snapshot_environment "$snapshot"; then
        return 1
    fi

    if ! new_home=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/gitsetu-test.XXXXXX"); then
        rm -f "$snapshot"
        printf '  [FATAL] unable to create isolated test home\n' >&2
        return 1
    fi
    if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]] || [[ "${OSTYPE:-}" == "mingw"* ]]; then
        new_home=$(cd "$new_home" && pwd -W)
    else
        new_home=$(cd "$new_home" && pwd -P)
    fi

    TEST_ENV_STACK[frame_index]="$snapshot"
    TEST_HOME_STACK[frame_index]="$new_home"
    TEST_HOME="$new_home"

    _test_clear_managed_environment
    export HOME="$TEST_HOME"
    export GITSETU_TEST=1

    # Keep platform profile roots inside the same sandbox for child tools.
    export USERPROFILE="$TEST_HOME"
    export APPDATA="$TEST_HOME/AppData/Roaming"
    export LOCALAPPDATA="$TEST_HOME/AppData/Local"
    mkdir -p "$HOME/.ssh" "$HOME/.config" "$APPDATA" "$LOCALAPPDATA"
    if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]] || [[ "${OSTYPE:-}" == "mingw"* ]]; then
        case "$TEST_HOME" in
            [A-Za-z]:/*)
                export HOMEDRIVE="${TEST_HOME%%:*}"
                export HOMEPATH="${TEST_HOME#*:}"
                ;;
            *)
                unset HOMEDRIVE HOMEPATH
                ;;
        esac
    else
        unset HOMEDRIVE HOMEPATH
    fi

    # Do not inherit a system/global Git config, agent, or CI branch selector.
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0

    export GITSETU_CONFIG_DIR="$HOME/.config/gitsetu"
    export GITSETU_BACKUP_DIR="$GITSETU_CONFIG_DIR/backups"
    export GITSETU_PROFILES_DIR="$GITSETU_CONFIG_DIR/profiles"
    export GITSETU_HOOKS_DIR="$GITSETU_CONFIG_DIR/hooks"
    export GITSETU_PROFILES_CONF="$GITSETU_CONFIG_DIR/profiles.conf"
    # Keep test locks in a disposable per-HOME runtime tree, never in the
    # removable config tree that teardown is expected to delete.
    export GITSETU_TEST_RUNTIME_DIR="$HOME/.gitsetu-test-runtime"
    export GITSETU_LOCK_DIR="$GITSETU_TEST_RUNTIME_DIR/profiles.lock"
    GITSETU_DEFAULT_LOCK_DIR="$GITSETU_LOCK_DIR"
    GITSETU_LOCK_RUNTIME_CONFIGURED=0
    GITSETU_LOCK_PATH=""
    GITSETU_LOCK_TOKEN=""
    GITSETU_LOCK_PROCESS_START=""
    GITSETU_LOCK_DEPTH=0
    return 0
}

teardown_test_home() {
    local stack_index=$(( ${#TEST_HOME_STACK[@]} - 1 ))
    local home=""
    local snapshot=""
    local result=0

    if [[ "$stack_index" -lt 0 ]]; then
        # Even without an active stack, restore the source-time environment if
        # a caller explicitly asks for teardown.
        _test_restore_original_environment || result=1
        TEST_HOME=""
        return "$result"
    fi

    home="${TEST_HOME_STACK[$stack_index]}"
    snapshot="${TEST_ENV_STACK[$stack_index]}"

    if [[ -n "$home" && -d "$home" ]]; then
        rm -rf "$home" || result=1
    fi

    if [[ -n "$snapshot" && -f "$snapshot" ]]; then
        _test_restore_environment "$snapshot" || result=1
        rm -f "$snapshot" || result=1
    fi

    unset "TEST_ENV_STACK[$stack_index]"
    unset "TEST_HOME_STACK[$stack_index]"
    if [[ "$stack_index" -gt 0 ]]; then
        TEST_HOME="${TEST_HOME_STACK[$((stack_index - 1))]}"
    else
        TEST_HOME=""
        _test_restore_latch_variable
    fi

    return "$result"
}

# Install the cleanup trap only once per shell.  Some suites source helpers a
# second time from a function; resetting the stack there would lose isolation.
if [[ "$_TEST_HELPERS_INITIALIZED" -eq 0 ]]; then
    _test_initialize_state
    _TEST_HELPERS_INITIALIZED=1
    trap _test_exit_cleanup EXIT
fi

# ------------------------------------------------------------------------------
# Strict v2 registry fixture helpers
#
# These are intentionally test-only.  They centralize construction of the
# versioned six-field format so unrelated suites cannot accidentally create a
# legacy seven-field acceptance fixture.  Call them after source_gitsetu_libs.
# ------------------------------------------------------------------------------
test_v2_registry_header() {
    printf '%s\n' "${GITSETU_REGISTRY_HEADER:-# gitsetu-registry-v2}"
}

test_v2_registry_line() {
    [[ $# -eq 6 ]] || return 1
    local encoded_label encoded_directory encoded_provider encoded_sign encoded_key encoded_user
    encoded_label=$(escape_registry_field "$1") || return 1
    encoded_directory=$(escape_registry_field "$2") || return 1
    encoded_provider=$(escape_registry_field "$3") || return 1
    encoded_sign=$(escape_registry_field "$4") || return 1
    encoded_key=$(escape_registry_field "$5") || return 1
    encoded_user=$(escape_registry_field "$6") || return 1
    printf '%s:%s:%s:%s:%s:%s\n' \
        "$encoded_label" "$encoded_directory" "$encoded_provider" \
        "$encoded_sign" "$encoded_key" "$encoded_user"
}

test_v2_profile_config() {
    [[ $# -eq 3 ]] || return 1
    local label="$1"
    local name="$2"
    local email="$3"
    local path="$GITSETU_PROFILES_DIR/${label}.gitconfig"
    mkdir -p "$GITSETU_PROFILES_DIR"
    cat > "$path" <<EOF
[user]
    name = $name
    email = $email
EOF
}

# Validate each module at most once per test process.  Source return status is
# checked on the initial load (and whenever a test home changes), so a module
# which fails while executing cannot be hidden by the syntax cache.
_test_validate_module_syntax() {
    local path="$1"

    if [[ -n "$_TEST_SYNTAX_CACHE_FILE" && -f "$_TEST_SYNTAX_CACHE_FILE" ]] &&
       grep -F -x -q -e "$path" "$_TEST_SYNTAX_CACHE_FILE"; then
        return 0
    fi

    if ! bash -n "$path"; then
        return 1
    fi
    if [[ -n "$_TEST_SYNTAX_CACHE_FILE" ]]; then
        if ! printf '%s\n' "$path" >> "$_TEST_SYNTAX_CACHE_FILE"; then
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Source gitsetu modules for testing
# ------------------------------------------------------------------------------
# Source one module with an explicit syntax and return-status check.  This is
# intentionally used instead of bare `source` commands: run_test invokes test
# functions in a conditional context, which suppresses errexit inside a sourced
# module and would otherwise turn a broken module into a later PASS.
source_test_module() {
    local path="$1"
    local status=0

    if [[ ! -f "$path" ]]; then
        printf '    FAIL: required test module is missing: %s\n' "$path"
        mark_test_failure
        return 1
    fi
    if ! _test_validate_module_syntax "$path"; then
        printf '    FAIL: test module has a syntax error: %s\n' "$path"
        mark_test_failure
        return 1
    fi

    # shellcheck disable=SC1090  # path is checked immediately above
    source "$path" || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf '    FAIL: test module returned %d while sourcing: %s\n' "$status" "$path"
        mark_test_failure
        return "$status"
    fi
    return 0
}

source_gitsetu_libs() {
    local script_dir
    local module
    local status=0
    local config_dir="${GITSETU_CONFIG_DIR:-}"
    local -a modules

    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

    if [[ "$_TEST_GITSETU_LIBS_READY" -eq 1 ]]; then
        if [[ "$config_dir" == "$_TEST_GITSETU_SOURCE_CONFIG_DIR" ]]; then
            detect_os || status=$?
            if [[ "$status" -ne 0 ]]; then
                printf '    FAIL: detect_os returned %d after cached module loading\n' "$status"
                mark_test_failure
                return "$status"
            fi
            return 0
        fi
        # setup_test_home intentionally clears inherited GITSETU_* values.
        # Refresh the schema/constant modules after a new sandbox, while the
        # already-validated implementation modules remain loaded.
        modules=(core.sh validate.sh)
        _TEST_GITSETU_LIBS_READY=0
    else
        modules=(
            core.sh
            platform.sh
            ui.sh
            validate.sh
            backup.sh
            ssh.sh
            gitconfig.sh
            guard.sh
            verify.sh
            teardown.sh
            discovery.sh
            setup.sh
            doctor.sh
            keychain.sh
        )
    fi

    for module in "${modules[@]}"; do
        source_test_module "$script_dir/lib/$module" || status=$?
        if [[ "$status" -ne 0 ]]; then
            return "$status"
        fi
    done

    detect_os || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf '    FAIL: detect_os returned %d after module loading\n' "$status"
        mark_test_failure
        return "$status"
    fi
    _TEST_GITSETU_LIBS_READY=1
    _TEST_GITSETU_SOURCE_CONFIG_DIR="$config_dir"
    return 0
}
