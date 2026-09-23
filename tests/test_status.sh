#!/usr/bin/env bash
# tests/test_status.sh — GitSetu Status Command Suite
# Verifies cmd_status active identity detection, profile registry rendering,
# and guard bypass warnings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

GITSETU_EXE="$REPO_DIR/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

# ------------------------------------------------------------------------------
# Test 1: cmd_status displays (not set) when no git identity configured
# ------------------------------------------------------------------------------
test_status_not_set() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.gitconfig"
    git config --global --unset user.name 2>/dev/null || true
    git config --global --unset user.email 2>/dev/null || true

    local output
    output=$(bash "$GITSETU_EXE" status 2>&1 || true)

    assert_contains "$output" "Active Identity" "displays active identity box" || return 1
    assert_contains "$output" "Name:  (not set)" "displays name not set" || return 1
    assert_contains "$output" "Email: (not set)" "displays email not set" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: cmd_status displays active identity when set in repo
# ------------------------------------------------------------------------------
test_status_repo_identity() {
    local repo_dir="$TEST_HOME/repos/my-repo"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name "Alice Dev"
    git -C "$repo_dir" config user.email "alice@company.com"

    local output
    output=$(cd "$repo_dir" && bash "$GITSETU_EXE" status 2>&1 || true)

    assert_contains "$output" "Alice Dev" "displays active repo name" || return 1
    assert_contains "$output" "alice@company.com" "displays active repo email" || return 1
    assert_contains "$output" "SSH:   (default)" "displays default SSH command in git repo" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: cmd_status warns on local core.hooksPath guard subversion
# ------------------------------------------------------------------------------
test_status_warns_hooks_subversion() {
    local repo_dir="$TEST_HOME/repos/subverted-repo"
    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.name "Hacker"
    git -C "$repo_dir" config user.email "hacker@evil.dev"
    git -C "$repo_dir" config --local core.hooksPath ".local-hooks"

    local output
    output=$(cd "$repo_dir" && bash "$GITSETU_EXE" status 2>&1 || true)

    assert_contains "$output" "SECURITY WARNING" "displays security warning banner" || return 1
    assert_contains "$output" "locally overrides core.hooksPath (.local-hooks)" "identifies subverting path" || return 1
    assert_contains "$output" "guard is completely bypassed" "warns of guard bypass" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: cmd_status displays configured profiles and active match checkmark
# ------------------------------------------------------------------------------
test_status_displays_profiles_and_active_check() {
    mkdir -p "$GITSETU_PROFILES_DIR"
    cat << EOF > "$GITSETU_PROFILES_CONF"
work::$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:
personal::$HOME/personal:github.com:0:$HOME/.ssh/id_ed25519_personal:
EOF
    cat << EOF > "$GITSETU_PROFILES_DIR/work.gitconfig"
[user]
    name = Alice Work
    email = alice@corp.com
EOF
    cat << EOF > "$GITSETU_PROFILES_DIR/personal.gitconfig"
[user]
    name = Alice Personal
    email = alice@me.dev
EOF

    # Test inside work directory
    local work_repo="$TEST_HOME/work/repo1"
    mkdir -p "$work_repo"
    git -C "$work_repo" init -q
    git -C "$work_repo" config user.name "Alice Work"
    git -C "$work_repo" config user.email "alice@corp.com"

    local output
    output=$(cd "$work_repo" && bash "$GITSETU_EXE" status 2>&1 || true)

    assert_contains "$output" "Configured Profiles" "displays configured profiles header" || return 1
    assert_contains "$output" "✓ work" "renders active checkmark next to matching work profile" || return 1
    assert_contains "$output" "personal" "renders personal profile" || return 1
    assert_contains "$output" "alice@corp.com" "renders work profile email" || return 1
    assert_contains "$output" "alice@me.dev" "renders personal profile email" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: cmd_status displays [Manual Mode] for profile without directory
# ------------------------------------------------------------------------------
test_status_manual_mode_display() {
    mkdir -p "$GITSETU_PROFILES_DIR"
    cat << EOF > "$GITSETU_PROFILES_CONF"
global:::github.com:0:$HOME/.ssh/id_ed25519_global:
EOF
    cat << EOF > "$GITSETU_PROFILES_DIR/global.gitconfig"
[user]
    name = Solo Dev
    email = solo@example.com
EOF

    local output
    output=$(bash "$GITSETU_EXE" status 2>&1 || true)

    assert_contains "$output" "[Manual Mode]" "displays manual mode for unbound directory" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_status.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "cmd_status displays (not set) for unconfigured identity" test_status_not_set
run_test "cmd_status displays active identity when set in repo" test_status_repo_identity
run_test "cmd_status warns on local core.hooksPath guard subversion" test_status_warns_hooks_subversion
run_test "cmd_status displays profiles and active checkmark" test_status_displays_profiles_and_active_check
run_test "cmd_status displays [Manual Mode] for unbound directory" test_status_manual_mode_display
print_results "Status tests"
