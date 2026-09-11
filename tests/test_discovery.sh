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
print_results "Discovery tests"
