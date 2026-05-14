#!/usr/bin/env bash
# tests/test_update.sh — Tests for gitsetu update
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/helpers.sh"

setup_test_home
source_gitsetu_libs

# Mock gitsetu script paths
export GITSETU_DIR="$HOME/.local/share/gitsetu"

test_update_fails_if_not_git_repo() {
    mkdir -p "$GITSETU_DIR"
    
    local gitsetu_script="$TEST_DIR/../gitsetu"
    
    local output
    output=$(bash "$gitsetu_script" update 2>&1 || true)
    
    assert_contains "$output" "was not installed via Git" "detects missing .git" || return 1
}

test_update_succeeds_up_to_date() {
    # 1. Create a fake remote repository
    local remote_dir="$HOME/fake_remote_1.git"
    git init --bare "$remote_dir" >/dev/null 2>&1
    
    # 2. Setup the local GitSetu installation
    rm -rf "$GITSETU_DIR"
    mkdir -p "$GITSETU_DIR"
    cd "$GITSETU_DIR"
    git init >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "$remote_dir"
    
    # Create an initial commit and push to remote so origin/main exists
    echo "test" > test.txt
    git add test.txt
    git commit -m "initial" >/dev/null 2>&1
    git branch -M main
    git push -u origin main >/dev/null 2>&1
    
    local gitsetu_script="$TEST_DIR/../gitsetu"
    
    local output
    output=$(bash "$gitsetu_script" update 2>&1 || true)
    
    rm -rf "$remote_dir"
    
    assert_contains "$output" "GitSetu is already up-to-date" "detects up to date" || return 1
}

test_update_applies_update() {
    # 1. Create a fake remote repository
    local remote_dir="$HOME/fake_remote_2.git"
    git init --bare "$remote_dir" >/dev/null 2>&1
    
    # 2. Setup the local GitSetu installation
    rm -rf "$GITSETU_DIR"
    mkdir -p "$GITSETU_DIR"
    cd "$GITSETU_DIR"
    git init >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "$remote_dir"
    
    # Create initial commit and push
    echo "test" > test.txt
    git add test.txt
    git commit -m "initial" >/dev/null 2>&1
    git branch -M main
    git push -u origin main >/dev/null 2>&1
    
    # 3. Simulate an update on the remote
    local tmp_clone="$HOME/tmp_clone"
    git clone "$remote_dir" "$tmp_clone" >/dev/null 2>&1
    cd "$tmp_clone"
    git checkout main >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Mock core.sh to simulate the version parsing logic in the NEW version
    mkdir -p lib
    echo 'GITSETU_VERSION="1.2.3"' > lib/core.sh
    git add lib/core.sh
    git commit -m "update version" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
    
    # 4. Run gitsetu update in the local installation
    local gitsetu_script="$TEST_DIR/../gitsetu"
    
    local output
    output=$(bash "$gitsetu_script" update 2>&1 || true)
    
    rm -rf "$remote_dir" "$tmp_clone"
    
    assert_contains "$output" "Update found" "detects update" || return 1
    assert_contains "$output" "from v${GITSETU_VERSION} to v1.2.3" "reports version change" || return 1
}

# --- Run ---

printf '\n%btest_update.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "update fails cleanly if not a git repo" test_update_fails_if_not_git_repo
run_test "update succeeds when up to date" test_update_succeeds_up_to_date
run_test "update successfully applies update" test_update_applies_update
print_results "Update tests"
