#!/usr/bin/env bash
# Development updater tests: no mutable fetch/reset path exists.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/helpers.sh"
setup_test_home

create_checkout() {
    local checkout="$1"
    rm -rf "$checkout"
    mkdir -p "$checkout"
    cp "$REPO_ROOT/gitsetu" "$checkout/gitsetu"
    cp -R "$REPO_ROOT/lib" "$checkout/lib"
    git -C "$checkout" init -q
    git -C "$checkout" config user.name "Updater Test"
    git -C "$checkout" config user.email "updater@example.invalid"
    git -C "$checkout" checkout -q -b feature/v1.1.0-onboarding-overhaul
    git -c core.autocrlf=false -C "$checkout" add gitsetu lib
    git -C "$checkout" commit -q -m "test: clean updater fixture"
    git -C "$checkout" remote add origin "https://invalid.example.invalid/gitsetu.git"
}

test_production_update_is_disabled() {
    local output rc=0
    output=$(bash "$REPO_ROOT/gitsetu" update 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$output" == *"Production update is disabled"* || "$output" == *"Usage: gitsetu update --development"* ]] || return 1
    [[ "$output" != *"origin/main"* && "$output" != *"Update found"* ]]
}

test_clean_development_checkout_is_verified_without_fetch() {
    local checkout="$HOME/clean-updater" output before after
    create_checkout "$checkout"
    before=$(git -C "$checkout" rev-parse HEAD)
    output=$(bash "$checkout/gitsetu" update --development 2>&1) || return 1
    after=$(git -C "$checkout" rev-parse HEAD)
    [[ "$output" == *"Development checkout verified"* ]] || return 1
    [[ "$before" == "$after" ]] || return 1
    [[ "$output" == *"No fetch, branch reset"* ]]
}

test_dirty_development_checkout_is_refused() {
    local checkout="$HOME/dirty-updater" output rc=0 before after
    create_checkout "$checkout"
    printf 'dirty\n' > "$checkout/untracked-file"
    before=$(git -C "$checkout" rev-parse HEAD)
    output=$(bash "$checkout/gitsetu" update --development 2>&1) || rc=$?
    after=$(git -C "$checkout" rev-parse HEAD)
    [[ "$rc" -ne 0 && "$output" == *"dirty; no update or reset"* ]] || return 1
    [[ "$before" == "$after" ]]
}

test_wrong_development_branch_is_refused() {
    local checkout="$HOME/wrong-branch-updater" output rc=0
    create_checkout "$checkout"
    git -C "$checkout" branch -m main
    output=$(bash "$checkout/gitsetu" update --development 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$output" == *"Development branch drift"* ]]
}

printf '\n%btest_update.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "production updater is disabled during development" test_production_update_is_disabled
run_test "clean development checkout is verified without fetch/reset" test_clean_development_checkout_is_verified_without_fetch
run_test "dirty development checkout is refused without mutation" test_dirty_development_checkout_is_refused
run_test "wrong development branch is refused" test_wrong_development_branch_is_refused
print_results "Updater tests"
