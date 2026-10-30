#!/usr/bin/env bash
# Updater tests: channel-aware updates.
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
    git -c core.autocrlf=false -C "$checkout" add gitsetu lib
    git -C "$checkout" commit -q -m "test: clean updater fixture"
}

test_update_rejects_extra_arguments() {
    local output rc=0
    output=$(bash "$REPO_ROOT/gitsetu" update extra 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$output" == *"Usage: gitsetu update"* ]]
}

test_dirty_git_checkout_is_refused() {
    local checkout="$HOME/dirty-updater" output rc=0 before after
    create_checkout "$checkout"
    printf 'dirty\n' > "$checkout/untracked-file"
    before=$(git -C "$checkout" rev-parse HEAD)
    output=$(bash "$checkout/gitsetu" update 2>&1) || rc=$?
    after=$(git -C "$checkout" rev-parse HEAD)
    [[ "$rc" -ne 0 && "$output" == *"dirty; no update or reset"* ]] || return 1
    [[ "$before" == "$after" ]]
}

test_clean_git_checkout_updates_to_highest_tag() {
    local remote_repo="$HOME/remote-tags"
    local checkout="$HOME/checkout-updater" output rc=0
    rm -rf "$remote_repo" "$checkout"
    git init -q --bare "$remote_repo"

    create_checkout "$checkout"
    git -C "$checkout" remote add origin "$remote_repo"
    git -C "$checkout" tag v1.0.0
    git -C "$checkout" push -q origin master:master --tags 2>/dev/null || git -C "$checkout" push -q origin main:main --tags

    # Add a newer commit and tag v1.2.0 on remote
    local tmp_work="$HOME/tmp-work"
    rm -rf "$tmp_work"
    git clone -q "$remote_repo" "$tmp_work"
    git -C "$tmp_work" config user.name "Updater Test"
    git -C "$tmp_work" config user.email "updater@example.invalid"
    printf 'new\n' >> "$tmp_work/file"
    git -C "$tmp_work" add file
    git -C "$tmp_work" commit -q -m "v1.2.0 release"
    git -C "$tmp_work" tag v1.2.0
    git -C "$tmp_work" push -q origin master --tags 2>/dev/null || git -C "$tmp_work" push -q origin main --tags
    rm -rf "$tmp_work"

    # Now checkout is at v1.0.0; running update should checkout v1.2.0
    output=$(bash "$checkout/gitsetu" update 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$output" == *"Updated GitSetu to v1.2.0"* ]] || return 1
    local current_tag
    current_tag=$(git -C "$checkout" describe --tags --exact-match 2>/dev/null || true)
    [[ "$current_tag" == "v1.2.0" ]]
}

test_update_never_downgrades_when_only_older_tags_exist() {
    local remote_repo="$HOME/remote-older-tags"
    local checkout="$HOME/checkout-no-downgrade" output rc=0
    rm -rf "$remote_repo" "$checkout"
    git init -q --bare "$remote_repo"

    create_checkout "$checkout"
    git -C "$checkout" remote add origin "$remote_repo"
    # Remote has only v1.0.0
    git -C "$checkout" tag v1.0.0
    git -C "$checkout" push -q origin master:master --tags 2>/dev/null || git -C "$checkout" push -q origin main:main --tags
    git -C "$checkout" tag -d v1.0.0 >/dev/null 2>&1 || true

    # Local checkout has a commit ahead of v1.0.0 (v1.1.0 development)
    printf 'ahead\n' >> "$checkout/dummy.txt"
    git -C "$checkout" add dummy.txt
    git -C "$checkout" commit -q -m "dev commit ahead of v1.0.0"

    output=$(bash "$checkout/gitsetu" update 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$output" == *"is current"* ]] || return 1
    local current_rev
    current_rev=$(git -C "$checkout" describe --tags --exact-match 2>/dev/null || true)
    [[ "$current_rev" != "v1.0.0" ]]
}

printf '\n%btest_update.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "update rejects extra arguments" test_update_rejects_extra_arguments
run_test "dirty checkout refuses update without mutation" test_dirty_git_checkout_is_refused
run_test "clean checkout updates to highest release tag" test_clean_git_checkout_updates_to_highest_tag
run_test "update never downgrades when only older tags exist" test_update_never_downgrades_when_only_older_tags_exist
print_results "Updater tests"
