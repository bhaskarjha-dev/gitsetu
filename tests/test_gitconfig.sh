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
    assert_contains "$content" "sshCommand = ssh -o IdentitiesOnly=yes -i '~/.ssh/id_ed25519_pro'" "has safely quoted sshCommand" &&
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
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_pro")
    PROFILE_USERS=("global_user" "pro_user")
    PROFILE_PATS=("" "")
    PROFILE_COUNT=2

    write_profiles_conf 2>/dev/null

    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf created" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "# gitsetu-registry-v2" "strict v2 header" || return 1
    assert_file_contains "$GITSETU_PROFILES_CONF" "%70%72%6F" "encoded pro record" || return 1
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
    # Newlines are rejected rather than silently stripped or written into INI.
    PROFILE_LABELS=("global" "hacker")
    PROFILE_NAMES=("Global" "Hacker")
    PROFILE_EMAILS=("g@t.com" "hacker@test.com")
    PROFILE_DIRS=("" "bad_path"$'\n'"with_newline")
    PROFILE_COUNT=2

    local status=0
    build_global_gitconfig_block >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "newline-bearing paths are rejected" || return 1
}

test_unicode_route_canonicalization_and_git_resolution() {
    local old_os="${GITSETU_OS:-}"
    local unicode_dir="$HOME/café/プロジェクト/日本語"
    local repo_dir="$unicode_dir/repository"
    local config_file="$HOME/.gitconfig-unicode-route"
    local profile_file="$GITSETU_PROFILES_DIR/unicode.gitconfig"
    mkdir -p "$repo_dir" "$GITSETU_PROFILES_DIR"

    cat > "$profile_file" <<'EOF'
[user]
    name = Unicode User
    email = unicode@example.test
EOF
    GITSETU_OS=gitbash
    PROFILE_LABELS=("global" "unicode")
    PROFILE_NAMES=("Global" "Unicode User")
    PROFILE_EMAILS=("global@example.test" "unicode@example.test")
    PROFILE_DIRS=("" "$unicode_dir")
    PROFILE_COUNT=2

    # Force the C locale at the call boundary. The byte-level control
    # validator must accept valid multibyte UTF-8 path bytes as ordinary data.
    local normalized block status=0
    normalized=$(LC_ALL=C _gitconfig_normalize_path "$unicode_dir") || return 1
    block=$(LC_ALL=C build_global_gitconfig_block) || return 1
    assert_contains "$block" "$normalized/" "UTF-8 route is emitted without C-locale rejection" || return 1
    printf '%s\n' "$block" > "$config_file"
    if ! git config --file "$config_file" --list >/dev/null 2>&1; then
        printf '    FAIL: generated UTF-8 Git config is not parseable\n'
        return 1
    fi
    git -C "$repo_dir" init -q
    local resolved_email
    resolved_email=$(GIT_CONFIG_GLOBAL="$config_file" GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$repo_dir" config user.email 2>/dev/null || true)
    assert_equals "unicode@example.test" "$resolved_email" "Git resolves identity through UTF-8 includeIf route" || return 1

    # Preserve strict rejection of actual ASCII control bytes even in C locale;
    # valid UTF-8 continuation bytes must not be treated as controls.
    local control
    for control in $'\r' $'\n' $'\t' $'\177'; do
        PROFILE_DIRS=("" "$unicode_dir${control}injected")
        status=0
        LC_ALL=C build_global_gitconfig_block >/dev/null 2>&1 || status=$?
        assert_equals "1" "$status" "UTF-8 support does not weaken ASCII control rejection" || return 1
    done

    # Persisted v2 paths must be canonical; preview-only normalization does
    # not make backslashes or traversal acceptable in registry state.
    rm -f "$HOME/.gitconfig"
    PROFILE_DIRS=("" "$HOME\\noncanonical")
    status=0
    write_global_gitconfig >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "persisted backslash path is rejected" || return 1
    PROFILE_DIRS=("" "$HOME/../outside")
    status=0
    write_global_gitconfig >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "persisted traversal path is rejected" || return 1
    GITSETU_OS="$old_os"
}

test_generated_gitconfig_is_deterministic_across_locales() {
    PROFILE_LABELS=("global" "parent" "zeta" "alpha")
    PROFILE_NAMES=("Global" "Parent" "Zeta" "Alpha")
    PROFILE_EMAILS=("g@t.com" "p@t.com" "z@t.com" "a@t.com")
    PROFILE_DIRS=("" "/dev/parent" "/dev/zeta" "/dev/alpha")
    PROFILE_PROVIDERS=("github.com" "github.com" "github.com" "github.com")
    PROFILE_SIGNS=("0" "0" "0" "0")
    PROFILE_KEYS=("$HOME/.ssh/g" "$HOME/.ssh/p" "$HOME/.ssh/z" "$HOME/.ssh/a")
    PROFILE_USERS=("g" "p" "z" "a")
    PROFILE_PATS=("" "" "" "")
    PROFILE_COUNT=4
    GITSETU_DRY_RUN=0
    rm -f "$HOME/.gitconfig"
    LC_ALL=C write_global_gitconfig >/dev/null
    cp "$HOME/.gitconfig" "$HOME/gitconfig-c-locale"
    LC_ALL=C.UTF-8 write_global_gitconfig >/dev/null
    if ! cmp -s "$HOME/.gitconfig" "$HOME/gitconfig-c-locale"; then
        printf '    FAIL: locale changed generated config ordering/content\n'
        return 1
    fi
    return 0
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
run_test "UTF-8 routes canonicalize and resolve under C locale" test_unicode_route_canonicalization_and_git_resolution
run_test "generated config is locale-deterministic" test_generated_gitconfig_is_deterministic_across_locales
print_results "Git config tests"
