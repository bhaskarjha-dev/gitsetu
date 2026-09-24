#!/usr/bin/env bash
# Focused regression tests for owned v2 registry/routing/guard behavior.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home
source_gitsetu_libs
GITSETU_OS=gitbash

_seed_routes() {
    local parent="$1" child="$2"
    mkdir -p "$parent" "$child"
    PROFILE_LABELS=("global" "parent" "child")
    PROFILE_NAMES=("Global User" "Parent User" "Child User")
    PROFILE_EMAILS=("global@example.com" "parent@example.com" "child@example.com")
    PROFILE_DIRS=("" "$parent" "$child")
    PROFILE_PROVIDERS=("github.com" "github.com" "gitlab.com")
    PROFILE_SIGNS=("0" "0" "0")
    PROFILE_KEYS=(
        "$HOME/.ssh/id global"
        "$HOME/SSH Keys/id_parent"
        "$HOME/SSH Keys/id_%100.5C.local"
    )
    PROFILE_USERS=("global_user" "parent_user" "child_user")
    PROFILE_PATS=("" "" "")
    PROFILE_COUNT=3
    GITSETU_DRY_RUN=0
    write_profiles_conf >/dev/null
    write_global_gitconfig >/dev/null
}

test_v2_registry_exact_write_and_read() {
    local parent="$HOME/Work Root"
    local child="$parent/clients/acme"
    _seed_routes "$parent" "$child"

    local header
    header=$(head -n1 "$GITSETU_PROFILES_CONF")
    assert_equals "# gitsetu-registry-v2" "$header" "strict v2 header is written" || return 1

    local raw
    raw=$(grep '%63%68%69%6C%64' "$GITSETU_PROFILES_CONF" | head -n1 || true)
    assert_contains "$raw" "%25%31%30%30%2E%35%43%2E%6C%6F%63%61%6C" "literal percent is encoded" || return 1
    assert_not_contains "$raw" "Work Root" "decoded path is not emitted raw" || return 1

    load_profiles || return 1
    assert_equals "3" "$PROFILE_COUNT" "all v2 records load" || return 1
    assert_equals "$child" "${PROFILE_DIRS[2]}" "directory round-trips exactly" || return 1
    assert_equals "$HOME/SSH Keys/id_%100.5C.local" "${PROFILE_KEYS[2]}" "key path round-trips exactly" || return 1
    assert_equals "child_user" "${PROFILE_USERS[2]}" "provider user round-trips exactly" || return 1
    assert_equals "child@example.com" "${PROFILE_EMAILS[2]}" "identity loads from profile gitconfig" || return 1

    printf '# old registry\nwork::%s\n' "$child" > "$GITSETU_PROFILES_CONF"
    local status=0
    load_profiles >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "legacy registry is rejected without migration" || return 1
}

test_v2_includeif_effective_child_identity_and_worktree() {
    local parent="$HOME/Work Root"
    local child="$parent/clients/acme"
    _seed_routes "$parent" "$child"

    local parent_repo="$parent/parent-repo"
    local child_repo="$child/child-repo"
    local linked="$HOME/Linked Worktree"
    mkdir -p "$parent_repo" "$child_repo"
    git -C "$parent_repo" init -q
    git -C "$child_repo" init -q

    local parent_position child_position
    parent_position=$(grep -nF "[includeIf \"gitdir/i:${parent}/\"]" "$HOME/.gitconfig" | cut -d: -f1)
    child_position=$(grep -nF "[includeIf \"gitdir/i:${child}/\"]" "$HOME/.gitconfig" | cut -d: -f1)
    [[ -n "$parent_position" && -n "$child_position" && "$parent_position" -lt "$child_position" ]] || {
        printf '    FAIL: shallow parent include is not emitted before specific child include\n'
        return 1
    }

    local effective
    effective=$(git -C "$child_repo" config user.email)
    assert_equals "child@example.com" "$effective" "Git resolves nested child as the last scalar include" || return 1
    effective=$(git -C "$parent_repo" config user.email)
    assert_equals "parent@example.com" "$effective" "parent repository still resolves parent identity" || return 1

    echo initial > "$child_repo/file"
    git -C "$child_repo" add file
    GIT_AUTHOR_NAME="Child User" GIT_AUTHOR_EMAIL="child@example.com" \
    GIT_COMMITTER_NAME="Child User" GIT_COMMITTER_EMAIL="child@example.com" \
        git -C "$child_repo" commit -q -m initial
    git -C "$child_repo" worktree add -q --detach "$linked"
    effective=$(git -C "$linked" config user.email)
    assert_equals "child@example.com" "$effective" "linked worktree follows common gitdir routing" || return 1
}

test_v2_guard_checks_author_committer_and_worktree_scope() {
    local parent="$HOME/Guard Work"
    local child="$parent/client"
    _seed_routes "$parent" "$child"
    install_guard >/dev/null

    local repo="$child/repo"
    local linked="$HOME/Linked Guard Worktree"
    mkdir -p "$repo"
    git -C "$repo" init -q
    echo one > "$repo/file"
    git -C "$repo" add file

    local output status=0
    output=$(git -C "$repo" commit --author='Wrong Author <wrong@example.com>' -m wrong 2>&1 || true)
    assert_contains "$output" "prospective author identity" "mismatched --author result is checked" || return 1
    assert_contains "$output" "does not reveal whether --author" "message does not overclaim --author provenance" || return 1

    echo two > "$repo/file"
    git -C "$repo" add file
    output=$(GIT_COMMITTER_NAME="Wrong Committer" GIT_COMMITTER_EMAIL="wrong@example.com" \
        git -C "$repo" commit -m committer 2>&1 || true)
    assert_contains "$output" "prospective committer identity" "committer environment is checked" || return 1

    echo three > "$repo/file"
    git -C "$repo" add file
    output=$(git -C "$repo" commit -m valid 2>&1) || status=$?
    assert_equals "0" "$status" "matching effective author and committer commit succeeds" || return 1

    # A linked worktree outside the profile tree is still managed through the
    # common gitdir, matching Git includeIf rather than cwd-based guesswork.
    git -C "$repo" worktree add -q --detach "$linked"
    echo four > "$linked/file"
    git -C "$linked" add file
    status=0
    output=$(git -C "$linked" commit -m linked 2>&1) || status=$?
    assert_equals "0" "$status" "valid linked-worktree commit remains managed and succeeds" || return 1

    echo five > "$linked/file"
    git -C "$linked" add file
    output=$(GIT_AUTHOR_NAME="Wrong" GIT_AUTHOR_EMAIL="wrong@example.com" \
        git -C "$linked" commit -m linked-wrong 2>&1 || true)
    assert_contains "$output" "GitSetu Guard: BLOCKING" "linked worktree cannot escape managed guard" || return 1
}

test_guard_ignores_untrusted_environment_lib_root() {
    local evil="$HOME/evil 'checkout'"
    mkdir -p "$evil/lib"
    printf '%s\n' 'echo compromised' > "$evil/lib/core.sh"
    GITSETU_DIR="$evil"
    GITSETU_SCRIPT_DIR="$evil"
    GITSETU_ALLOW_TEST_LIB_DIR=0
    install_guard >/dev/null

    local hook
    hook=$(cat "$GITSETU_HOOKS_DIR/pre-commit")
    assert_not_contains "$hook" "$evil" "caller-controlled GITSETU_DIR is not embedded" || return 1
    assert_contains "$hook" "GITSETU_LIB_DIR='" "hook has one canonical library root" || return 1
    unset GITSETU_DIR GITSETU_SCRIPT_DIR GITSETU_ALLOW_TEST_LIB_DIR
}

test_gitconfig_helper_uses_validated_canonical_executable() {
    local evil="$HOME/evil-helper"
    mkdir -p "$evil"
    printf '%s\n' '#!/bin/sh' 'echo compromised' > "$evil/gitsetu"
    chmod +x "$evil/gitsetu"
    rm -f "$HOME/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    GITSETU_OS=linux
    GITSETU_DIR="$evil"
    GITSETU_SCRIPT_DIR="$evil"
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Global User")
    PROFILE_EMAILS=("global@example.com")
    PROFILE_DIRS=("")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_SIGNS=("0")
    PROFILE_KEYS=("$HOME/.ssh/id_global")
    PROFILE_USERS=("global_user")
    PROFILE_PATS=("")
    PROFILE_COUNT=1
    local block
    block=$(build_global_gitconfig_block) || return 1
    assert_not_contains "$block" "$evil" "caller helper redirection is not emitted" || return 1
    assert_contains "$block" "!'" "helper is shell-quoted" || return 1
    unset GITSETU_DIR GITSETU_SCRIPT_DIR GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL
    GITSETU_OS=gitbash
}

test_v2_writer_rejects_missing_provider_or_sign_fields() {
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Global User")
    PROFILE_EMAILS=("global@example.com")
    PROFILE_DIRS=("")
    PROFILE_KEYS=("$HOME/.ssh/id_global")
    PROFILE_USERS=("global_user")
    PROFILE_PATS=("")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_SIGNS=("0")
    PROFILE_COUNT=1
    unset PROFILE_PROVIDERS
    local status=0
    write_profiles_conf >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "missing provider is rejected" || return 1

    PROFILE_PROVIDERS=("github.com")
    unset PROFILE_SIGNS
    status=0
    write_profiles_conf >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" "missing sign field is rejected" || return 1
}

test_v2_preserves_existing_credential_helper_policy() {
    cat > "$HOME/.gitconfig" <<'EOF'
[credential]
    helper = osxkeychain
EOF
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Global User")
    PROFILE_EMAILS=("global@example.com")
    PROFILE_DIRS=("")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_SIGNS=("0")
    PROFILE_KEYS=("$HOME/.ssh/id_global")
    PROFILE_USERS=("global_user")
    PROFILE_PATS=("")
    PROFILE_COUNT=1
    local block
    block=$(build_global_gitconfig_block)
    local managed
    managed=$(printf '%s\n' "$block" | sed -n "/${GITSETU_MANAGED_START}/,/${GITSETU_MANAGED_END}/p")
    assert_not_contains "$managed" "gitsetu credential" "existing helper policy is not shadowed" || return 1
    write_global_gitconfig >/dev/null
    local effective
    effective=$(git config --global --get-all credential.helper)
    assert_equals "osxkeychain" "$effective" "existing helper remains the effective policy" || return 1
}

printf '\n%btest_owned_v2.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "v2 registry exact write/read and legacy rejection" test_v2_registry_exact_write_and_read
run_test "effective nested identity and linked-worktree routing" test_v2_includeif_effective_child_identity_and_worktree
run_test "managed guard author/committer/worktree behavior" test_v2_guard_checks_author_committer_and_worktree_scope
run_test "persistent guard ignores untrusted environment lib root" test_guard_ignores_untrusted_environment_lib_root
run_test "gitconfig helper uses validated canonical executable" test_gitconfig_helper_uses_validated_canonical_executable
run_test "v2 writer rejects missing provider/sign fields" test_v2_writer_rejects_missing_provider_or_sign_fields
run_test "existing credential helper policy is preserved" test_v2_preserves_existing_credential_helper_policy
print_results "Owned v2 tests"
