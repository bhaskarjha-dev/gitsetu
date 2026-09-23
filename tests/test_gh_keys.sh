#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked functions invoked dynamically or via subshells
# tests/test_gh_keys.sh — GitHub CLI Key Registration Automation Suite
# Verifies try_gh_key_upload title tagging, scope discipline, and display integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

# ------------------------------------------------------------------------------
# Test 1: Key title contains GitSetu, label, and hostname
# ------------------------------------------------------------------------------
test_gh_key_title_formatting() {
    local dummy_pub="$TEST_HOME/title_test.pub"
    touch "$dummy_pub"

    gh() {
        if [[ "$1" == "api" ]]; then
            echo "monalisa"
            return 0
        fi
        if [[ "$1" == "ssh-key" && "$2" == "add" ]]; then
            echo "$5" > "$TEST_HOME/title_cap"
            return 0
        fi
        return 0
    }

    GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "work" "$dummy_pub" >/dev/null 2>&1
    unset -f gh

    local captured_title=""
    if [[ -f "$TEST_HOME/title_cap" ]]; then
        captured_title=$(cat "$TEST_HOME/title_cap")
    fi

    assert_contains "$captured_title" "GitSetu (work -" "key title contains GitSetu and profile label" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: Scope discipline: uses authenticated user without account switching
# ------------------------------------------------------------------------------
test_gh_key_scope_discipline() {
    local dummy_pub="$TEST_HOME/scope_test.pub"
    touch "$dummy_pub"

    local output
    gh() {
        if [[ "$1" == "api" && "$2" == "user" ]]; then
            echo "authorized_dev"
            return 0
        fi
        if [[ "$1" == "ssh-key" && "$2" == "add" ]]; then
            return 0
        fi
        return 0
    }

    output=$(GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "client" "$dummy_pub" 2>&1)
    unset -f gh

    assert_contains "$output" "GitHub CLI: logged in as @authorized_dev" "displays currently authenticated user" || return 1
    assert_contains "$output" "Key successfully added to GitHub!" "succeeds under current user scope" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: Unauthenticated gh returns 1 without attempting upload
# ------------------------------------------------------------------------------
test_gh_unauthenticated_aborts() {
    local dummy_pub="$TEST_HOME/unauth.pub"
    touch "$dummy_pub"

    local rc=0
    gh() {
        if [[ "$1" == "api" ]]; then
            echo "gh: not logged in" >&2
            return 1
        fi
        echo "ssh-key add called unexpectedly" >&2
        return 0
    }

    local output
    output=$(GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "work" "$dummy_pub" 2>&1) || rc=$?
    unset -f gh

    assert_equals "1" "$rc" "returns 1 when unauthenticated" || return 1
    assert_not_contains "$output" "ssh-key add called unexpectedly" "does not attempt upload" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: Idempotency on 422 key already in use returns 0
# ------------------------------------------------------------------------------
test_gh_key_already_registered_idempotent() {
    local dummy_pub="$TEST_HOME/existing.pub"
    touch "$dummy_pub"

    local output rc=0
    gh() {
        if [[ "$1" == "api" ]]; then
            echo "monalisa"
            return 0
        fi
        if [[ "$1" == "ssh-key" && "$2" == "add" ]]; then
            echo "HTTP 422: Key is already in use (key_already_exists)" >&2
            return 1
        fi
        return 0
    }

    output=$(GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "personal" "$dummy_pub" 2>&1) || rc=$?
    unset -f gh

    assert_equals "0" "$rc" "returns 0 when key already registered" || return 1
    assert_contains "$output" "Key already registered on GitHub." "prints already registered status" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: display_public_keys provides manual fallback on upload failure
# ------------------------------------------------------------------------------
test_display_public_keys_manual_fallback() {
    mkdir -p "$TEST_HOME/.ssh"
    local kpath="$TEST_HOME/.ssh/id_ed25519_manual"
    ssh-keygen -t ed25519 -C "manual@example.com" -f "$kpath" -N "" -q

    PROFILE_COUNT=1
    PROFILE_LABELS[0]="manual"
    PROFILE_EMAILS[0]="manual@example.com"
    PROFILE_PROVIDERS[0]="github.com"
    PROFILE_KEYS[0]="$kpath"

    # Simulate failing or non-interactive upload
    local output
    output=$(
        try_gh_key_upload() {
            return 1
        }
        display_public_keys 2>&1
    )

    assert_contains "$output" "https://github.com/settings/ssh/new" "provides manual fallback URL" || return 1
    assert_contains "$output" "To add key manually" "provides manual instructions" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_gh_keys.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "key title formatting contains GitSetu and label" test_gh_key_title_formatting
run_test "scope discipline uses authenticated user" test_gh_key_scope_discipline
run_test "unauthenticated gh aborts cleanly" test_gh_unauthenticated_aborts
run_test "idempotent handling on 422 key already in use" test_gh_key_already_registered_idempotent
run_test "display_public_keys provides manual fallback URL" test_display_public_keys_manual_fallback
print_results "GitHub Keys tests"
