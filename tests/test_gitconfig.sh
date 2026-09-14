#!/usr/bin/env bash
# shellcheck disable=SC2034  # Test state vars are consumed by sourced library functions
# tests/test_gitconfig.sh — Tests for lib/gitconfig.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs
detect_os

# --- Tests ---

test_global_block_has_useconfigonly() {
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test User" "Pro User")
    PROFILE_EMAILS=("global@test.com" "pro@test.com")
    PROFILE_DIRS=("" "/dev/pro")
    PROFILE_COUNT=2

    local block
    block=$(build_global_gitconfig_block)

    assert_contains "$block" "useConfigOnly = true" "has useConfigOnly"
}

test_global_block_has_includeif() {
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test" "Pro")
    PROFILE_EMAILS=("g@t.com" "p@t.com")
    PROFILE_DIRS=("" "/dev/pro")
    PROFILE_COUNT=2

    local block
    block=$(build_global_gitconfig_block)

    local keyword
    keyword=$(get_gitdir_keyword)
    local expected_path
    expected_path=$(normalize_path "${GITSETU_PROFILES_DIR}/pro.gitconfig")

    assert_contains "$block" "[includeIf \"${keyword}/dev/pro/\"]" "has includeIf for pro" &&
    assert_contains "$block" "path = \"${expected_path}\"" "has profile path"
}

test_global_block_has_safe_directories() {
    PROFILE_LABELS=("global" "pro" "work")
    PROFILE_NAMES=("Test" "Pro" "Work")
    PROFILE_EMAILS=("g@t.com" "p@t.com" "w@t.com")
    PROFILE_DIRS=("" "/dev/pro" "/dev/work")
    PROFILE_COUNT=3

    local block
    block=$(build_global_gitconfig_block)

    assert_contains "$block" "[safe]" "has safe block header" &&
    assert_contains "$block" "directory = \"/dev/pro/*\"" "has safe directory for pro" &&
    assert_contains "$block" "directory = \"/dev/work/*\"" "has safe directory for work"
}

test_global_block_has_trailing_slash() {
    PROFILE_LABELS=("global" "work")
    PROFILE_NAMES=("Test" "Work")
    PROFILE_EMAILS=("g@t.com" "w@t.com")
    PROFILE_DIRS=("" "/dev/work")
    PROFILE_COUNT=2

    local block
    block=$(build_global_gitconfig_block)

    # Directory should end with /
    assert_contains "$block" "/dev/work/\"]" "gitdir path has trailing slash"
}

test_global_block_has_managed_markers() {
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Test")
    PROFILE_EMAILS=("g@t.com")
    PROFILE_DIRS=("")
    PROFILE_COUNT=1

    local block
    block=$(build_global_gitconfig_block)

    assert_contains "$block" "[gitsetu:managed:start]" "has start marker" &&
    assert_contains "$block" "[gitsetu:managed:end]" "has end marker"
}

test_profile_gitconfig_content() {
    local content
    content=$(build_profile_gitconfig "pro" "Pro User" "pro@test.com" "0" "${HOME}/.ssh/id_ed25519_pro")

    assert_contains "$content" "name = Pro User" "has name" &&
    assert_contains "$content" "email = pro@test.com" "has email" &&
    assert_contains "$content" "sshCommand = ssh -i ~/.ssh/id_ed25519_pro" "has sshCommand" &&
    assert_contains "$content" "[gitsetu:managed:start] Profile: pro" "has start marker" &&
    assert_contains "$content" "[gitsetu:managed:end] Profile: pro" "has end marker"
}

test_write_global_gitconfig_creates_file() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Test")
    PROFILE_EMAILS=("g@t.com")
    PROFILE_DIRS=("")
    PROFILE_COUNT=1

    write_global_gitconfig 2>/dev/null

    assert_file_exists "$HOME/.gitconfig" "gitconfig created"
}

test_write_global_gitconfig_idempotent() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test" "Pro")
    PROFILE_EMAILS=("g@t.com" "p@t.com")
    PROFILE_DIRS=("" "/dev/pro")
    PROFILE_COUNT=2

    write_global_gitconfig 2>/dev/null
    write_global_gitconfig 2>/dev/null

    local count
    count=$(grep -c "\[gitsetu:managed:start\]" "$HOME/.gitconfig")
    assert_equals "1" "$count" "exactly one managed block after two runs"
}

test_write_global_gitconfig_preserves_user_content() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Test")
    PROFILE_EMAILS=("g@t.com")
    PROFILE_DIRS=("")
    PROFILE_COUNT=1

    # Pre-populate with user content
    cat > "$HOME/.gitconfig" <<'EOF'
[alias]
    co = checkout
    st = status
EOF

    write_global_gitconfig 2>/dev/null

    assert_file_contains "$HOME/.gitconfig" "co = checkout" "user alias preserved" &&
    assert_file_contains "$HOME/.gitconfig" "[gitsetu:managed:start]" "managed block added"
}

test_write_profile_gitconfig() {
    GITSETU_DRY_RUN=0
    ensure_dirs
    write_profile_gitconfig "pro" "Pro User" "pro@test.com" 2>/dev/null

    assert_file_exists "$GITSETU_PROFILES_DIR/pro.gitconfig" "profile file created" &&
    assert_file_contains "$GITSETU_PROFILES_DIR/pro.gitconfig" "email = pro@test.com" "has email"
}

test_write_profiles_conf() {
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "pro")
    PROFILE_NAMES=("Test" "Pro")
    PROFILE_EMAILS=("g@t.com" "p@t.com")
    PROFILE_DIRS=("" "/dev/pro")
    PROFILE_COUNT=2

    write_profiles_conf 2>/dev/null

    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf created" &&
    assert_file_contains "$GITSETU_PROFILES_CONF" "global:::" "has global entry" &&
    assert_file_contains "$GITSETU_PROFILES_CONF" "pro::/dev/pro" "has pro entry"
}

test_path_escaping() {
    # Test that GitConfig paths are properly escaped for double quotes and normalized
    PROFILE_LABELS=("global" "hacker")
    PROFILE_NAMES=("Global" "Hacker")
    PROFILE_EMAILS=("g@t.com" "hacker@test.com")
    # A path that contains double quotes and backslashes
    PROFILE_DIRS=("" 'C:\Users\John"Doe\work')
    PROFILE_COUNT=2

    local block
    block=$(build_global_gitconfig_block)

    # Backslashes are normalized to forward slashes, quotes are escaped
    local expected_escaped_dir='C:/Users/John\"Doe/work/'
    local keyword
    keyword=$(get_gitdir_keyword)
    
    assert_contains "$block" "[includeIf \"${keyword}${expected_escaped_dir}\"]" "path is properly escaped in includeIf" || return 1
    
    # Check that [safe] directory is also escaped
    local expected_safe_dir='C:/Users/John\"Doe/work/*'
    assert_contains "$block" "directory = \"${expected_safe_dir}\"" "path is properly escaped in safe directory" || return 1
}

test_path_injection_newlines() {
    # Test that newlines are stripped from paths to prevent INI corruption
    PROFILE_LABELS=("global" "hacker")
    PROFILE_NAMES=("Global" "Hacker")
    PROFILE_EMAILS=("g@t.com" "hacker@test.com")
    # A path that contains explicit newlines
    PROFILE_DIRS=("" "bad_path"$'\n'"with_newline")
    PROFILE_COUNT=2

    local block
    block=$(build_global_gitconfig_block)

    # It should strip the newline and evaluate as a single line
    local expected_escaped_dir='bad_pathwith_newline/'
    local keyword
    keyword=$(get_gitdir_keyword)
    
    assert_contains "$block" "[includeIf \"${keyword}${expected_escaped_dir}\"]" "newlines are stripped from includeIf paths" || return 1
}

# --- Run ---

printf '\n%btest_gitconfig.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "global block contains useConfigOnly" test_global_block_has_useconfigonly
run_test "global block has includeIf for profiles" test_global_block_has_includeif
run_test "global block has safe directories" test_global_block_has_safe_directories
run_test "includeIf paths have trailing slash" test_global_block_has_trailing_slash
run_test "includeIf paths are securely escaped" test_path_escaping
run_test "includeIf paths strip newlines" test_path_injection_newlines
run_test "global block has managed markers" test_global_block_has_managed_markers
run_test "profile gitconfig has correct content" test_profile_gitconfig_content
run_test "write creates ~/.gitconfig" test_write_global_gitconfig_creates_file
run_test "write is idempotent (no duplicates)" test_write_global_gitconfig_idempotent
run_test "write preserves user content" test_write_global_gitconfig_preserves_user_content
run_test "write creates profile gitconfig file" test_write_profile_gitconfig
run_test "write creates profiles.conf registry" test_write_profiles_conf
print_results "Git config tests"
