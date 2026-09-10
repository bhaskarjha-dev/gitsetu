#!/usr/bin/env bash
# tests/test_platform.sh — Tests for lib/platform.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source_gitsetu_libs

# --- Tests ---

test_detect_os_returns_value() {
    detect_os
    # Must be one of the known values
    case "$GITSETU_OS" in
        linux|macos|wsl|gitbash|unknown) return 0 ;;
        *)
            printf '    Unexpected GITSETU_OS value: %s\n' "$GITSETU_OS"
            return 1
            ;;
    esac
}

test_normalize_path_tilde() {
    local result
    # shellcheck disable=SC2088  # Intentional: testing that normalize_path handles literal tilde
    result=$(normalize_path "~/foo/bar")
    local expected="$HOME/foo/bar"
    if [[ "$GITSETU_OS" == "gitbash" ]] && [[ "$expected" =~ ^/([a-zA-Z])/(.*) ]]; then
        expected="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'):/${BASH_REMATCH[2]}"
    fi
    assert_equals "$expected" "$result" "tilde expansion"
}

test_normalize_path_windows_drive() {
    if [[ "$GITSETU_OS" == "gitbash" ]]; then
        local res1 res2 res3
        res1=$(normalize_path "/c/Users/test")
        assert_equals "C:/Users/test" "$res1" "convert /c/ to C:/"

        res2=$(normalize_path 'd:\dev\pro')
        assert_equals "D:/dev/pro" "$res2" "convert d:\\dev\\pro to D:/dev/pro"

        res3=$(normalize_path "c:/Users/test/")
        assert_equals "C:/Users/test" "$res3" "uppercase drive letter and strip trailing slash"
    fi
    return 0
}

test_normalize_path_trailing_slash() {
    local result
    result=$(normalize_path "/foo/bar/")
    assert_equals "/foo/bar" "$result" "trailing slash removal"
}

test_normalize_path_double_slash() {
    local result
    result=$(normalize_path "/foo//bar")
    assert_equals "/foo/bar" "$result" "double slash collapse"
}

test_normalize_path_backslash() {
    local result
    result=$(normalize_path '/foo\bar\baz')
    assert_equals "/foo/bar/baz" "$result" "backslash to forward slash"
}

test_normalize_path_root() {
    local result
    result=$(normalize_path "/")
    assert_equals "/" "$result" "root path unchanged"
}

test_get_gitdir_keyword_not_empty() {
    detect_os
    local keyword
    keyword=$(get_gitdir_keyword)
    # Must start with "gitdir"
    assert_contains "$keyword" "gitdir" "keyword contains gitdir"
}

# --- Run ---

printf '\n%btest_platform.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "detect_os returns a known value" test_detect_os_returns_value
run_test "normalize_path expands tilde" test_normalize_path_tilde
run_test "normalize_path normalizes Windows drive paths" test_normalize_path_windows_drive
run_test "normalize_path removes trailing slash" test_normalize_path_trailing_slash
run_test "normalize_path collapses double slashes" test_normalize_path_double_slash
run_test "normalize_path converts backslashes" test_normalize_path_backslash
run_test "normalize_path preserves root /" test_normalize_path_root
run_test "get_gitdir_keyword returns gitdir variant" test_get_gitdir_keyword_not_empty
print_results "Platform tests"
