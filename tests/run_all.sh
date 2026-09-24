#!/usr/bin/env bash
# tests/run_all.sh — Run the GitSetu regression suites with honest statuses.
#
# The ordinary source-tree run is:
#     bash tests/run_all.sh
#
# A bundle is selected explicitly; the runner never treats the historical,
# unsupported GITSETU_TEST_BIN variable as if it selected a product binary:
#     bash scripts/bundle.sh
#     bash tests/run_all.sh --bundle ./dist/gitsetu
#
# The bundle mode runs a contract suite against the exact artifact supplied by
# the caller.  It does not claim that source-tree tests magically use a bundle.

set -u
set -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$ROOT_DIR/tests"
BUNDLE_CONTRACT="$TEST_DIR/test_bundle_path.sh"
cd "$ROOT_DIR" || exit 1

bundle_path=""
include_powershell=0
include_live_windows=0
require_powershell=0
timeout_seconds="${GITSETU_TEST_TIMEOUT:-300}"
suite_patterns=()

usage() {
    cat <<'EOF'
Usage: bash tests/run_all.sh [options]

Options:
  --suite PATTERN          Run only shell suites whose path contains PATTERN
  --bundle PATH            Run the exact bundle contract suite against PATH
  --test-bin PATH          Alias for --bundle (explicit, not an env override)
  --include-powershell     Run the checked-in PowerShell suites when possible
  --include-live-windows  Also run the live Scoop installer suite (opt-in)
  --require-powershell    Treat unavailable PowerShell as a failure
  --timeout SECONDS        Per-suite timeout (default: 300)
  -h, --help               Show this help

Exit status is nonzero when a required suite fails or a required capability is
missing.  A skipped suite is reported as SKIP and is never counted as PASS.
EOF
}

fail_usage() {
    printf 'ERROR: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle|--test-bin)
            [[ $# -ge 2 ]] || fail_usage "$1 requires a path"
            bundle_path="$2"
            shift 2
            ;;
        --bundle=*|--test-bin=*)
            bundle_path="${1#*=}"
            shift
            ;;
        --suite)
            [[ $# -ge 2 ]] || fail_usage "--suite requires a pattern"
            suite_patterns+=("$2")
            shift 2
            ;;
        --include-powershell)
            include_powershell=1
            shift
            ;;
        --include-live-windows)
            include_live_windows=1
            include_powershell=1
            shift
            ;;
        --require-powershell)
            include_powershell=1
            require_powershell=1
            shift
            ;;
        --timeout)
            [[ $# -ge 2 ]] || fail_usage "--timeout requires seconds"
            timeout_seconds="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                suite_patterns+=("$1")
                shift
            done
            ;;
        -* )
            fail_usage "unknown option: $1"
            ;;
        *)
            suite_patterns+=("$1")
            shift
            ;;
    esac
done

if [[ -n "${GITSETU_TEST_BIN:-}" ]]; then
    if [[ -z "$bundle_path" ]]; then
        printf '%s\n' \
            'ERROR: GITSETU_TEST_BIN is not a supported test-runner selector.' \
            'Use the explicit --bundle PATH form after building the artifact.' >&2
        exit 2
    fi
    printf '%s\n' \
        'WARNING: ignoring GITSETU_TEST_BIN; the explicit --bundle path is authoritative.' >&2
fi

if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    fail_usage "--timeout must be a positive integer"
fi

if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]] || [[ "${OSTYPE:-}" == "win"* ]]; then
    include_powershell=1
fi

passed=0
failed=0
skipped=0
total=0
failed_suites=()
skipped_suites=()

_test_child_pids() {
    local parent="$1"
    ps -ef 2>/dev/null | awk -v p="$parent" 'NR > 1 && $3 == p { print $2 }'
}

_test_kill_process_tree() {
    local pid="$1" signal="${2:-TERM}" child
    while IFS= read -r child; do
        [[ "$child" =~ ^[0-9]+$ ]] || continue
        _test_kill_process_tree "$child" "$signal"
    done < <(_test_child_pids "$pid")
    kill "-$signal" "$pid" 2>/dev/null || true
}

run_with_timeout() {
    local seconds="$1"
    shift

    # MSYS/Cygwin timeout implementations do not reliably terminate Win32
    # descendants (Node, ssh, or Git children). Use a small process-tree
    # watchdog there so a failed suite cannot leave the runner blocked.
    if [[ "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "mingw"* ]]; then
        "$@" &
        local command_pid=$!
        (
            sleep "$seconds"
            if kill -0 "$command_pid" 2>/dev/null; then
                _test_kill_process_tree "$command_pid" TERM
                sleep 1
                if kill -0 "$command_pid" 2>/dev/null; then
                    _test_kill_process_tree "$command_pid" KILL
                fi
            fi
        ) &
        local watchdog_pid=$!
        local command_status=0
        wait "$command_pid" || command_status=$?
        if kill -0 "$watchdog_pid" 2>/dev/null; then
            kill -TERM "$watchdog_pid" 2>/dev/null || true
        fi
        wait "$watchdog_pid" 2>/dev/null || true
        if [[ "$command_status" -eq 143 || "$command_status" -eq 137 ]]; then
            return 124
        fi
        return "$command_status"
    fi

    if command -v timeout >/dev/null 2>&1; then
        # GNU timeout supports --foreground; older/BSD-compatible wrappers may
        # not. Probe the option before relying on it.
        if timeout --foreground 1 true >/dev/null 2>&1; then
            if timeout --foreground "$seconds" "$@"; then
                return 0
            else
                return $?
            fi
        fi
    fi

    # Portable Bash fallback for macOS and older Unix images.
    "$@" &
    local command_pid=$!
    (
        sleep "$seconds"
        if kill -0 "$command_pid" 2>/dev/null; then
            _test_kill_process_tree "$command_pid" TERM
            sleep 1
            if kill -0 "$command_pid" 2>/dev/null; then
                _test_kill_process_tree "$command_pid" KILL
            fi
        fi
    ) &
    local watchdog_pid=$!
    local command_status=0
    wait "$command_pid" || command_status=$?
    if kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
    fi
    wait "$watchdog_pid" 2>/dev/null || true
    if [[ "$command_status" -eq 143 || "$command_status" -eq 137 ]]; then
        return 124
    fi
    return "$command_status"
}

record_result() {
    local status="$1"
    local suite="$2"
    local reason="${3:-}"

    total=$((total + 1))
    case "$status" in
        PASS)
            passed=$((passed + 1))
            printf '  [PASS] %s\n' "$suite"
            ;;
        SKIP)
            skipped=$((skipped + 1))
            skipped_suites+=("$suite${reason:+ ($reason)}")
            printf '  [SKIP] %s%s\n' "$suite" "${reason:+ ($reason)}"
            ;;
        *)
            failed=$((failed + 1))
            failed_suites+=("$suite${reason:+ ($reason)}")
            printf '  [FAIL] %s%s\n' "$suite" "${reason:+ (exit $status)}"
            ;;
    esac
}

run_shell_suite() {
    local suite="$1"
    shift
    local status=0

    printf '\n=== Running %s ===\n' "$suite"
    if run_with_timeout "$timeout_seconds" bash "$suite" "$@"; then
        status=0
    else
        status=$?
    fi

    if [[ "$status" -eq 77 ]]; then
        record_result "SKIP" "$suite" "test returned 77"
    elif [[ "$status" -eq 0 ]]; then
        record_result "PASS" "$suite"
    else
        record_result "FAIL" "$suite"
    fi
}

matches_suite_filter() {
    local suite="$1"
    local pattern
    [[ "${#suite_patterns[@]}" -eq 0 ]] && return 0
    for pattern in "${suite_patterns[@]}"; do
        if [[ "$suite" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

run_bundle_mode() {
    if [[ ! -f "$bundle_path" || ! -s "$bundle_path" ]]; then
        printf 'ERROR: bundle path is missing or empty: %s\n' "$bundle_path" >&2
        printf 'Build it first with: bash scripts/bundle.sh\n' >&2
        exit 1
    fi
    if [[ ! -f "$BUNDLE_CONTRACT" ]]; then
        printf 'ERROR: bundle contract suite is missing: %s\n' "$BUNDLE_CONTRACT" >&2
        exit 1
    fi

    printf 'Bundle mode: testing exact artifact %s\n' "$bundle_path"
    run_shell_suite "$BUNDLE_CONTRACT" "$bundle_path"
}

run_default_mode() {
    local suite
    local matched=0
    local -a shell_suites=()

    for suite in "$TEST_DIR"/test_*.sh; do
        [[ -f "$suite" ]] || continue
        # The bundle contract takes an explicit artifact path and is not a
        # source-tree suite; it is run only by --bundle.
        [[ "$suite" == "$BUNDLE_CONTRACT" ]] && continue
        if matches_suite_filter "$suite"; then
            shell_suites+=("$suite")
        fi
    done

    for suite in "${shell_suites[@]}"; do
        matched=1
        run_shell_suite "$suite"
    done

    # PowerShell tests are included by default on Windows.  On other hosts they
    # are visible SKIPs unless explicitly requested, rather than being silently
    # counted as green.  Use --require-powershell in a Windows gate to make an
    # absent interpreter a failure.
    local ps_bin=""
    if [[ "$include_powershell" -eq 1 ]]; then
        if command -v powershell.exe >/dev/null 2>&1; then
            ps_bin="powershell.exe"
        elif command -v pwsh >/dev/null 2>&1; then
            ps_bin="pwsh"
        fi
    fi

    local ps_suite
    for ps_suite in \
        "$TEST_DIR/test_gh_extension_e2e.ps1" \
        "$TEST_DIR/test_powershell_installer_e2e.ps1" \
        "$TEST_DIR/test_windows_launcher.ps1" \
        "$TEST_DIR/test_scoop_e2e.ps1"; do
        [[ -f "$ps_suite" ]] || continue
        if ! matches_suite_filter "$ps_suite"; then
            continue
        fi
        matched=1
        if [[ "$ps_suite" == *test_scoop_e2e.ps1 && "$include_live_windows" -eq 0 ]]; then
            if [[ "$require_powershell" -eq 1 ]]; then
                record_result "FAIL" "$ps_suite" "live Windows suite was required but not explicitly enabled"
            else
                record_result "SKIP" "$ps_suite" "live installer test requires --include-live-windows"
            fi
            continue
        fi
        if [[ -z "$ps_bin" ]]; then
            if [[ "$require_powershell" -eq 1 ]]; then
                record_result "FAIL" "$ps_suite" "PowerShell is required but unavailable"
            else
                record_result "SKIP" "$ps_suite" "PowerShell unavailable; use --include-powershell on a Windows runner"
            fi
            continue
        fi

        printf '\n=== Running %s (%s) ===\n' "$ps_suite" "$ps_bin"
        local ps_status=0
        if run_with_timeout "$timeout_seconds" "$ps_bin" -NoProfile -ExecutionPolicy Bypass -File "$ps_suite"; then
            ps_status=0
        else
            ps_status=$?
        fi
        if [[ "$ps_status" -eq 0 ]]; then
            record_result "PASS" "$ps_suite"
        elif [[ "$ps_status" -eq 77 ]]; then
            record_result "SKIP" "$ps_suite" "test returned 77"
        else
            record_result "FAIL" "$ps_suite"
        fi
    done

    if [[ "$matched" -eq 0 ]]; then
        printf 'ERROR: no test suites selected\n' >&2
        exit 1
    fi
}

printf '==========================================\n'
printf 'GitSetu test runner\n'
printf '==========================================\n'

if [[ -n "$bundle_path" ]]; then
    run_bundle_mode
else
    run_default_mode
fi

printf '\n==========================================\n'
printf 'TEST SUITE SUMMARY\n'
printf '==========================================\n'
printf 'Total suites: %d\n' "$total"
printf 'PASS:          %d\n' "$passed"
printf 'FAIL:          %d\n' "$failed"
printf 'SKIP:          %d\n' "$skipped"

if [[ "${#failed_suites[@]}" -gt 0 ]]; then
    printf '\nFailed suites:\n'
    for suite in "${failed_suites[@]}"; do
        printf '  - %s\n' "$suite"
    done
fi
if [[ "${#skipped_suites[@]}" -gt 0 ]]; then
    printf '\nSkipped suites (not counted as PASS):\n'
    for suite in "${skipped_suites[@]}"; do
        printf '  - %s\n' "$suite"
    done
fi

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
if [[ "$require_powershell" -eq 1 && "$skipped" -gt 0 ]]; then
    printf '\nRequired capability was skipped; failing closed.\n' >&2
    exit 1
fi

printf '\nALL REQUIRED TESTS PASSED\n'
exit 0
