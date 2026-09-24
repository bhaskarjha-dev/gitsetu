#!/usr/bin/env bash
# tests/test_discovery.sh — Tests for auto-discovery engine
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

test_discover_global_git_identity_from_ssh() {
    # Mock missing git config but existing ssh key
    mkdir -p "$HOME/.ssh"
    echo "ssh-ed25519 AAAAC3... user@testdomain.com" > "$HOME/.ssh/id_ed25519_global.pub"
    
    # Run discovery
    discover_global_git_identity
    
    assert_equals "user@testdomain.com" "$DISCOVERED_GLOBAL_EMAIL" "extracted email from ssh pub key" || return 1
}

test_discover_global_git_identity_from_gitconfig() {
    # Create gitconfig
    cat > "$HOME/.gitconfig" <<EOF
[user]
    name = John Doe
    email = john@example.com
EOF

    discover_global_git_identity
    
    assert_equals "John Doe" "$DISCOVERED_GLOBAL_NAME" "extracted name from gitconfig" || return 1
    assert_equals "john@example.com" "$DISCOVERED_GLOBAL_EMAIL" "extracted email from gitconfig" || return 1
}

test_discover_ssh_key() {
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/id_rsa_work"
    
    local result
    result=$(discover_ssh_key_for_label "work")
    assert_equals "$HOME/.ssh/id_rsa_work" "$result" "found rsa key" || return 1
    
    # Touch ed25519, it should be preferred over rsa
    touch "$HOME/.ssh/id_ed25519_work"
    result=$(discover_ssh_key_for_label "work")
    assert_equals "$HOME/.ssh/id_ed25519_work" "$result" "prefers ed25519 over rsa" || return 1
}

test_discover_workspace_dir_fallback() {
    # Should find ~/work if it exists
    mkdir -p "$HOME/work"
    
    local result
    result=$(discover_workspace_dir "work")
    assert_equals "$HOME/work" "$result" "found workspace dir" || return 1
}

test_discover_workspace_dir_includeif() {
    # Should parse from includeIf (label must be in the gitdir path)
    rm -rf "$HOME/work" # clean up from previous test
    mkdir -p "$HOME/random_work_folder"
    cat > "$HOME/.gitconfig" <<EOF
[includeIf "gitdir:~/random_work_folder/"]
    path = ~/.config/gitsetu/profiles/work.gitconfig
EOF

    local result
    result=$(discover_workspace_dir "work")
    assert_equals "$HOME/random_work_folder" "$result" "extracted from includeIf" || return 1
}

test_discover_workspace_dir_includeif_case_insensitive() {
    # Should parse from includeIf with gitdir/i: keyword (Windows and macOS)
    rm -rf "$HOME/random_client_folder"
    mkdir -p "$HOME/random_client_folder"
    cat > "$HOME/.gitconfig" <<EOF
[includeIf "gitdir/i:~/random_client_folder/"]
    path = ~/.config/gitsetu/profiles/client.gitconfig
EOF

    local result
    result=$(discover_workspace_dir "client")
    assert_equals "$HOME/random_client_folder" "$result" "extracted from gitdir/i: includeIf" || return 1
}

test_discover_workspace_dir_ignores_global() {
    # Should return empty for "global"
    mkdir -p "$HOME/global"
    
    local result
    result=$(discover_workspace_dir "global")
    assert_equals "" "$result" "ignores global label" || return 1
}

test_discover_workspace_dir_multi_profile_substring_shadowing() {
    rm -rf "$HOME/work" "$HOME/client_work_dir" "$HOME/work_dir"
    mkdir -p "$HOME/client_work_dir" "$HOME/work_dir"
    cat > "$HOME/.gitconfig" <<EOF
[includeIf "gitdir/i:$(normalize_path "$HOME/client_work_dir")/"]
    path = ~/.gitconfig-client
[includeIf "gitdir/i:$(normalize_path "$HOME/work_dir")/"]
    path = ~/.gitconfig-work
EOF

    local result
    result=$(discover_workspace_dir "work")
    assert_equals "$(normalize_path "$HOME/work_dir")" "$result" "matches work_dir without substring shadowing from client_work_dir" || return 1
}

test_discover_workspace_dir_exact_component_match() {
    rm -rf "$HOME/work" "$HOME/client_work"
    mkdir -p "$HOME/work" "$HOME/client_work"
    cat > "$HOME/.gitconfig" <<EOF
[includeIf "gitdir:~/work/"]
    path = ~/.custom.inc
[includeIf "gitdir:~/client_work/"]
    path = ~/.custom2.inc
EOF

    local result
    result=$(discover_workspace_dir "work")
    assert_equals "$HOME/work" "$result" "matches exact directory component work over client_work" || return 1
}

test_discover_workspace_dir_no_false_positive_substring() {
    rm -rf "$HOME/work" "$HOME/client_work_dir"
    mkdir -p "$HOME/client_work_dir"
    cat > "$HOME/.gitconfig" <<EOF
[includeIf "gitdir/i:$(normalize_path "$HOME/client_work_dir")/"]
    path = ~/.gitconfig-client
EOF

    local result
    result=$(discover_workspace_dir "work")
    assert_equals "" "$result" "does not match client_work_dir when searching for work" || return 1
}

test_discovery_rejects_malformed_identity() {
    rm -rf "$HOME/.config/gitsetu" "$HOME/.ssh"
    mkdir -p "$HOME/.config/gitsetu/profiles" "$HOME/.ssh"
    git config --file "$HOME/.gitconfig" user.name $'Safe\n[core]\n    pager = false'
    git config --file "$HOME/.gitconfig" user.email 'not-an-email'

    discover_global_git_identity
    assert_equals "" "$DISCOVERED_GLOBAL_NAME" "malformed discovered name is rejected" || return 1
    assert_equals "" "$DISCOVERED_GLOBAL_EMAIL" "malformed discovered email is rejected" || return 1
    assert_equals "1" "$DISCOVERY_INVALID" "discovery reports invalid untrusted identity" || return 1
}

test_discovery_uses_configured_v2_profile_location() {
    rm -f "$HOME/.gitconfig"
    rm -rf "$HOME/work"
    local xdg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    mkdir -p "$xdg_root/gitsetu/profiles"
    git config --file "$xdg_root/gitsetu/profiles/global.gitconfig" user.name 'Configured Global'
    git config --file "$xdg_root/gitsetu/profiles/global.gitconfig" user.email global@example.com

    discover_global_git_identity
    assert_equals "Configured Global" "$DISCOVERED_GLOBAL_NAME" "configured profile directory is used" || return 1
    assert_equals "global@example.com" "$DISCOVERED_GLOBAL_EMAIL" "configured global email is used" || return 1
}

test_discovery_does_not_fallback_candidate_to_global_identity() {
    rm -f "$HOME/.gitconfig"
    rm -rf "$HOME/.config/gitsetu" "$HOME/work" "$HOME/.ssh"
    mkdir -p "$HOME/.config/gitsetu/profiles" "$HOME/.ssh"
    git config --file "$HOME/.config/gitsetu/profiles/global.gitconfig" user.name 'Global User'
    git config --file "$HOME/.config/gitsetu/profiles/global.gitconfig" user.email global@example.com
    mkdir -p "$HOME/work" "$HOME/.ssh"
    : > "$HOME/.ssh/id_ed25519_work"
    printf 'ssh-ed25519 AAAA no-email-comment\n' > "$HOME/.ssh/id_ed25519_work.pub"

    PROFILE_COUNT=0
    generate_initial_blueprint
    assert_equals "1" "$PROFILE_COUNT" "incomplete discovered work profile is not registered" || return 1
    assert_equals "global" "${PROFILE_LABELS[0]}" "only the complete global profile remains" || return 1
}

test_validate_profile_blueprint_complete_mode() {
    PROFILE_COUNT=1
    PROFILE_LABELS=(global)
    PROFILE_NAMES=("")
    PROFILE_EMAILS=(global@example.com)
    PROFILE_DIRS=("")
    PROFILE_PROVIDERS=(github.com)
    PROFILE_SIGNS=(0)
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global")
    PROFILE_USERS=("")
    PROFILE_PATS=("")

    local shape_status=0 complete_status=0
    validate_profile_blueprint 0 || shape_status=$?
    validate_profile_blueprint 1 || complete_status=$?
    assert_equals "0" "$shape_status" "interactive shape validation permits an empty name" || return 1
    assert_equals "1" "$complete_status" "pre-mutation validation rejects an incomplete identity" || return 1
}

printf '\n%btest_discovery.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "extracts email from ssh public key" test_discover_global_git_identity_from_ssh
run_test "extracts identity from gitconfig" test_discover_global_git_identity_from_gitconfig
run_test "discovers ssh keys with priority" test_discover_ssh_key
run_test "discovers workspace fallback dirs" test_discover_workspace_dir_fallback
run_test "discovers workspace from includeIf" test_discover_workspace_dir_includeif
run_test "discovers workspace from gitdir/i: includeIf" test_discover_workspace_dir_includeif_case_insensitive
run_test "ignores global/default labels" test_discover_workspace_dir_ignores_global
run_test "resolves work_dir avoiding substring shadowing (Challenger 3.4)" test_discover_workspace_dir_multi_profile_substring_shadowing
run_test "resolves exact directory component over prefix" test_discover_workspace_dir_exact_component_match
run_test "rejects substring collision without profile match" test_discover_workspace_dir_no_false_positive_substring
run_test "rejects malformed discovered identity values" test_discovery_rejects_malformed_identity
run_test "discovers global identity from configured v2 profile path" test_discovery_uses_configured_v2_profile_location
run_test "does not apply global identity to an incomplete candidate" test_discovery_does_not_fallback_candidate_to_global_identity
run_test "blueprint validation separates shape from complete identity" test_validate_profile_blueprint_complete_mode
print_results "Discovery tests"
