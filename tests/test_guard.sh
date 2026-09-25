#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked confirmation is invoked indirectly by install_guard.
# tests/test_guard.sh — Tests for lib/guard.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

# --- Helpers ---
setup_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init --quiet
}

# Write the strict v2 registry and its single identity source. The first record
# is always the required global profile.
seed_v2_work_profile() {
    local dir="${1:-$HOME/work}" name="${2:-Test User}" email="${3:-work@example.com}"
    GITSETU_DRY_RUN=0
    PROFILE_LABELS=("global" "work")
    PROFILE_NAMES=("Global User" "$name")
    PROFILE_EMAILS=("global@example.com" "$email")
    PROFILE_DIRS=("" "$dir")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_work")
    PROFILE_USERS=("global_user" "work_user")
    PROFILE_PATS=("" "")
    PROFILE_COUNT=2
    write_profiles_conf >/dev/null
}

# --- Tests ---
test_install_guard() {
    GITSETU_DRY_RUN=0
    install_guard 2>/dev/null
    
    assert_file_exists "$GITSETU_HOOKS_DIR/pre-commit" "hook file created" || return 1
    local hooks_path
    hooks_path=$(git config --global core.hooksPath 2>/dev/null || echo "")
    
    assert_equals "$(normalize_path "$GITSETU_HOOKS_DIR")" "$(normalize_path "$hooks_path")" "core.hooksPath set globally" || return 1
}

test_guard_blocks_mismatch() {
    GITSETU_DRY_RUN=0
    seed_v2_work_profile "$HOME/work" "Test" "work@example.com"
    install_guard 2>/dev/null
    
    setup_repo "$HOME/work"
    git -C "$HOME/work" config user.email "wrong@example.com"
    git -C "$HOME/work" config user.name "Test"
    
    touch "$HOME/work/test.txt"
    git -C "$HOME/work" add test.txt
    
    local output
    output=$(git -C "$HOME/work" commit -m "Test" 2>&1 || echo "FAILED")
    
    assert_contains "$output" "BLOCKING COMMIT" "hook blocks mismatch" || return 1
    assert_contains "$output" "effective Git identity" "mismatch identifies effective config" || return 1
}

test_guard_allows_match() {
    GITSETU_DRY_RUN=0
    seed_v2_work_profile "$HOME/work" "Test" "work@example.com"
    install_guard 2>/dev/null
    
    setup_repo "$HOME/work"
    git -C "$HOME/work" config user.email "work@example.com"
    git -C "$HOME/work" config user.name "Test"
    
    touch "$HOME/work/test.txt"
    git -C "$HOME/work" add test.txt
    
    local output
    # Git requires author/committer names, provide env to satisfy it since no global config
    output=$(GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="work@example.com" GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="work@example.com" git -C "$HOME/work" commit -m "Test" 2>&1 || echo "FAILED")
    
    assert_not_contains "$output" "GitSetu Guard: BLOCKING" "hook allows match" || return 1
    assert_not_contains "$output" "FAILED" "matched commit succeeds" || return 1
}

test_guard_missing_registry_is_unmanaged_fail_open() {
    GITSETU_DRY_RUN=0
    # With no registry and no managed global block, the repository is unmanaged;
    # identity enforcement fails open while the normal Git commit rules apply.
    rm -f "$GITSETU_PROFILES_CONF"
    install_guard 2>/dev/null

    setup_repo "$HOME/work"
    touch "$HOME/work/unmanaged.txt"
    git -C "$HOME/work" add unmanaged.txt

    local output
    output=$(GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="outside@example.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="outside@example.com" \
        git -C "$HOME/work" commit -m "Unmanaged" 2>&1 || echo "FAILED")
    assert_not_contains "$output" "GitSetu Guard: BLOCKING" "unmanaged repo is not identity-blocked" || return 1
    assert_not_contains "$output" "FAILED" "unmanaged commit can proceed" || return 1
}

test_guard_pass_through() {
    GITSETU_DRY_RUN=0
    seed_v2_work_profile "$HOME/work" "Test" "work@example.com"
    install_guard 2>/dev/null
    
    setup_repo "$HOME/work"
    git -C "$HOME/work" config user.email "work@example.com"
    git -C "$HOME/work" config user.name "Test"
    
    # Create local hook
    mkdir -p "$HOME/work/.git/hooks"
    cat > "$HOME/work/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "LOCAL HOOK PASSTHROUGH SUCCESS"
exit 0
EOF
    chmod +x "$HOME/work/.git/hooks/pre-commit"
    
    touch "$HOME/work/test2.txt"
    git -C "$HOME/work" add test2.txt
    
    local output
    output=$(GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="work@example.com" GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="work@example.com" git -C "$HOME/work" commit -m "Test 2" 2>&1 || echo "FAILED")
    
    assert_contains "$output" "LOCAL HOOK PASSTHROUGH SUCCESS" "local hook ran" || return 1
}
test_guard_reads_v2_profile_identity() {
    # The v2 registry stores no email; the linked profile gitconfig is the
    # single identity source loaded by core and consumed by the guard.
    GITSETU_DRY_RUN=0
    seed_v2_work_profile "$HOME/work" "Test" "new.truth@example.com"

    install_guard 2>/dev/null
    
    setup_repo "$HOME/work"
    git -C "$HOME/work" config user.email "new.truth@example.com"
    git -C "$HOME/work" config user.name "Test"
    
    touch "$HOME/work/test3.txt"
    git -C "$HOME/work" add test3.txt
    
    local output
    output=$(GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="new.truth@example.com" GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="new.truth@example.com" git -C "$HOME/work" commit -m "Test 3" 2>&1 || echo "FAILED")
    
    assert_not_contains "$output" "FAILED" "guard allowed commit using the dynamically read email" || return 1
}

test_guard_prompt_bypassed_in_test_mode() {
    rm -f "$GITSETU_HOOKS_DIR/pre-commit"
    local should_prompt=0
    if [[ ! -f "$GITSETU_HOOKS_DIR/pre-commit" ]] && [[ -z "${GITSETU_TEST:-}" ]]; then
        should_prompt=1
    fi
    assert_equals "0" "$should_prompt" "guard prompt bypassed when GITSETU_TEST=1" || return 1
}

test_guard_prompt_skipped_if_already_installed() {
    install_guard 2>/dev/null
    assert_file_exists "$GITSETU_HOOKS_DIR/pre-commit" "hook exists" || return 1
    local should_prompt=0
    local saved_test="${GITSETU_TEST:-}"
    unset GITSETU_TEST
    if [[ ! -f "$GITSETU_HOOKS_DIR/pre-commit" ]] && [[ -z "${GITSETU_TEST:-}" ]]; then
        should_prompt=1
    fi
    export GITSETU_TEST="${saved_test:-1}"
    assert_equals "0" "$should_prompt" "guard prompt skipped when hook already installed" || return 1
}

test_guard_prompt_default_yes() {
    rm -f "$GITSETU_HOOKS_DIR/pre-commit"
    local result=1
    if printf "\n" | confirm "Enable pre-commit identity guard?" "y" >/dev/null 2>&1; then
        result=0
    fi
    assert_equals "0" "$result" "confirm defaults to yes on empty input" || return 1
}

test_guard_preserves_existing_hooks_path() {
    GITSETU_DRY_RUN=0
    local prior="$HOME/custom-hooks"
    mkdir -p "$prior"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$prior/pre-commit"
    chmod 700 "$prior/pre-commit"
    git config --global core.hooksPath "$prior"
    confirm() { return 0; }
    install_guard >/dev/null 2>&1 || return 1
    assert_equals "$(normalize_path "$GITSETU_HOOKS_DIR")" "$(normalize_path "$(git config --global core.hooksPath)")" "guard installs over a prior hooks path after consent" || return 1
    uninstall_guard >/dev/null 2>&1 || return 1
    assert_equals "$(normalize_path "$prior")" "$(normalize_path "$(git config --global core.hooksPath)")" "uninstall restores the exact prior hooks path" || return 1
}

test_guard_fails_closed_for_corrupt_managed_registry() {
    GITSETU_DRY_RUN=0
    seed_v2_work_profile "$HOME/work" "Test" "work@example.com"
    install_guard >/dev/null 2>&1
    printf '%s\n' "# gitsetu-registry-v2" "malformed" > "$GITSETU_PROFILES_CONF"
    setup_repo "$HOME/work"
    touch "$HOME/work/bad.txt"
    git -C "$HOME/work" add bad.txt
    local output
    output=$(GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="wrong@example.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="wrong@example.com" \
        git -C "$HOME/work" commit -m "bad" 2>&1 || true)
    assert_contains "$output" "BLOCKING COMMIT" "corrupt managed state fails closed" || return 1
}

printf '\n%btest_guard.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "install_guard links hook" test_install_guard
run_test "guard blocks mismatched email" test_guard_blocks_mismatch
run_test "guard allows matched email" test_guard_allows_match
run_test "missing registry is unmanaged and fails open" test_guard_missing_registry_is_unmanaged_fail_open
run_test "guard passes through to local hooks" test_guard_pass_through
run_test "guard reads identity from v2 profile config" test_guard_reads_v2_profile_identity
run_test "guard prompt bypassed in test mode" test_guard_prompt_bypassed_in_test_mode
run_test "guard prompt skipped if already installed" test_guard_prompt_skipped_if_already_installed
run_test "guard prompt defaults to yes" test_guard_prompt_default_yes
run_test "guard preserves prior core.hooksPath" test_guard_preserves_existing_hooks_path
run_test "corrupt managed registry fails closed" test_guard_fails_closed_for_corrupt_managed_registry
print_results "Guard tests"
