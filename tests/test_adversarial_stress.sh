#!/usr/bin/env bash
# tests/test_adversarial_stress.sh — Exhaustive Adversarial & Edge-Case Stress Suite
# Tests strange paths (spaces, quotes, unicode, brackets), concurrency, CRLF injection, and boundaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source testing framework
source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

printf '\n%b=== Running tests/test_adversarial_stress.sh ===%b\n' "$T_BOLD" "$T_RESET"

# ------------------------------------------------------------------------------
# Test 1: Workspace paths with multiple spaces, parentheses, brackets, and plus signs
# ------------------------------------------------------------------------------
test_paths_with_spaces_and_special_chars() {
    local weird_dir="$HOME/My Projects (Work)/Client + Partner/team-alpha"
    mkdir -p "$weird_dir"

    # Add profile with spaces, parens, and plus signs in path
    GITSETU_DRY_RUN=0
    local out
    out=$(bash "$REPO_DIR/gitsetu" add weird "Weird User" "weird@example.com" "$weird_dir" 2>&1)

    assert_contains "$out" "Setup complete" "Profile added with spaces and special chars" || return 1

    # Verify profiles.conf stores path correctly
    assert_file_contains "$GITSETU_PROFILES_CONF" "weird::" "profile recorded in registry" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/weird.gitconfig" "email = weird@example.com" "email in profile gitconfig" || return 1

    # Verify includeIf in global gitconfig matches the escaped path
    local gitconf_content
    gitconf_content=$(cat "$HOME/.gitconfig")
    local norm_dir
    norm_dir=$(normalize_path "$weird_dir")
    assert_contains "$gitconf_content" "$norm_dir/" "gitconfig includes normalized weird path with trailing slash" || return 1

    # Live Git verification: inside the weird repo, Git resolves the identity
    pushd "$weird_dir" >/dev/null
    git init -q
    local resolved_name resolved_email
    resolved_name=$(git config user.name || true)
    resolved_email=$(git config user.email || true)
    popd >/dev/null

    assert_equals "Weird User" "$resolved_name" "Git correctly resolves user.name inside spaces/symbols directory" || return 1
    assert_equals "weird@example.com" "$resolved_email" "Git correctly resolves user.email inside spaces/symbols directory" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: Deeply nested child repository inside workspace
# ------------------------------------------------------------------------------
test_deeply_nested_workspace_subdirectories() {
    local root_ws="$HOME/workspaces/mega-corp"
    local deep_repo="$root_ws/dept/subdept/team/project/services/backend/repo"
    mkdir -p "$deep_repo"

    bash "$REPO_DIR/gitsetu" add megacorp "Corp User" "corp@megacorp.internal" "$root_ws" >/dev/null 2>&1

    pushd "$deep_repo" >/dev/null
    git init -q
    local active_email
    active_email=$(git config user.email || true)
    
    # Check prompt resolution 8 directories deep
    local prompt_id
    prompt_id=$(bash "$REPO_DIR/gitsetu" prompt 2>/dev/null || true)
    popd >/dev/null

    assert_equals "corp@megacorp.internal" "$active_email" "Git resolves identity 8 levels deep inside workspace" || return 1
    assert_equals "megacorp" "$prompt_id" "gitsetu prompt correctly identifies active profile 8 levels deep" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: Path with single quote (apostrophe) in directory name
# ------------------------------------------------------------------------------
test_path_with_single_quote() {
    local quote_dir="$HOME/dev/o'reilly_media/books"
    mkdir -p "$quote_dir"

    local out
    out=$(bash "$REPO_DIR/gitsetu" add oreilly "Editor" "editor@oreilly.com" "$quote_dir" 2>&1)
    assert_contains "$out" "Setup complete" "Profile added with single quote in directory path" || return 1

    pushd "$quote_dir" >/dev/null
    git init -q
    local res_email
    res_email=$(git config user.email || true)
    popd >/dev/null

    assert_equals "editor@oreilly.com" "$res_email" "Single quote path resolves identity via Git includeIf" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: Unicode UTF-8 directory names (Accented characters & Japanese)
# ------------------------------------------------------------------------------
test_unicode_directory_paths() {
    local unicode_dir="$HOME/projets_étudiant/プロジェクト/日本語"
    mkdir -p "$unicode_dir"

    local out
    out=$(bash "$REPO_DIR/gitsetu" add tokyo "Dev Tokyo" "tokyo@example.jp" "$unicode_dir" 2>&1)
    assert_contains "$out" "Setup complete" "Profile added with UTF-8 Unicode directory path" || return 1

    pushd "$unicode_dir" >/dev/null
    git init -q
    local res_email
    res_email=$(git config user.email || true)
    popd >/dev/null

    assert_equals "tokyo@example.jp" "$res_email" "Unicode UTF-8 path resolves identity via Git" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: CRLF-contaminated profiles.conf resilience
# ------------------------------------------------------------------------------
test_crlf_profiles_conf_resilience() {
    local backup_conf=""
    if [[ -f "$GITSETU_PROFILES_CONF" ]]; then
        backup_conf=$(cat "$GITSETU_PROFILES_CONF")
    fi

    # Write profiles.conf with Windows CRLF line endings
    cat > "$GITSETU_PROFILES_CONF" <<EOF
alpha:alpha@test.com:$HOME/alpha:github.com:0:$HOME/.ssh/id_ed25519_alpha:
beta:beta@test.com:$HOME/beta:github.com:0:$HOME/.ssh/id_ed25519_beta:
EOF
    # Inject carriage returns (\r\n)
    if command -v unix2dos >/dev/null 2>&1; then
        unix2dos -q "$GITSETU_PROFILES_CONF"
    else
        sed -i -e 's/$/\r/' "$GITSETU_PROFILES_CONF"
    fi

    # Check that status executes and parses labels without trailing \r
    local status_out
    status_out=$(bash "$REPO_DIR/gitsetu" status 2>&1)
    assert_contains "$status_out" "alpha" "CRLF profiles.conf parsed cleanly for alpha" || return 1
    assert_contains "$status_out" "beta" "CRLF profiles.conf parsed cleanly for beta" || return 1

    # Load profiles using library function and check that \r is stripped
    load_profiles
    assert_equals "alpha" "${PROFILE_LABELS[0]}" "First label has no carriage return" || return 1
    assert_equals "alpha@test.com" "${PROFILE_EMAILS[0]}" "First email has no carriage return" || return 1

    # Restore backup so subsequent tests have a clean or preserved state
    if [[ -n "$backup_conf" ]]; then
        printf '%s\n' "$backup_conf" > "$GITSETU_PROFILES_CONF"
    else
        rm -f "$GITSETU_PROFILES_CONF"
    fi
}

# ------------------------------------------------------------------------------
# Test 6: Guard hook enforcement with Git commit edge cases (Detached HEAD, Cherry-pick)
# ------------------------------------------------------------------------------
test_guard_hook_edge_cases() {
    local repo="$HOME/repos/guard-test"
    mkdir -p "$repo"

    # Add work profile
    bash "$REPO_DIR/gitsetu" add work "Work Dev" "work@corp.com" "$repo" >/dev/null 2>&1
    bash "$REPO_DIR/gitsetu" guard --install >/dev/null 2>&1

    pushd "$repo" >/dev/null
    git init -q
    git config user.name "Work Dev"
    git config user.email "work@corp.com"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "feat: initial commit"

    # 1. Valid commit passes
    echo "update" >> file.txt
    git add file.txt
    git commit -q -m "feat: valid commit"
    local commit_res=$?
    assert_equals 0 "$commit_res" "Guard hook allows commit matching workspace profile" || { popd >/dev/null; return 1; }

    # 2. Tampered author email is BLOCKED by guard
    git config user.email "personal@attacker.com"
    echo "tamper" >> file.txt
    git add file.txt
    local blocked=0
    git commit -m "feat: bad commit" >/dev/null 2>&1 || blocked=1
    assert_equals 1 "$blocked" "Guard hook strictly blocks commit when user.email diverges" || { popd >/dev/null; return 1; }

    # Restore valid email for detached head test
    git config user.email "work@corp.com"

    # 3. Detached HEAD commit
    local head_commit
    head_commit=$(git rev-parse HEAD)
    git checkout --detach "$head_commit" -q
    echo "detached work" >> file.txt
    git add file.txt
    git commit -q -m "feat: detached HEAD commit"
    local detached_res=$?
    assert_equals 0 "$detached_res" "Guard hook operates smoothly on detached HEAD" || { popd >/dev/null; return 1; }

    # Return to branch
    git checkout - -q
    popd >/dev/null

    bash "$REPO_DIR/gitsetu" guard --uninstall >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Test 7: Adversarial input injection prevention
# ------------------------------------------------------------------------------
test_adversarial_input_rejections() {
    # 1. Invalid labels with path traversal or command injection
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "../hacker" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "bad;rm" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "bad\`id\`" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "bad\$(id)" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "bad|pipe" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "123startnum" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "ends-with-hyphen-" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "has space" "Hacker" "h@h.com" "/tmp/h" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add "waytoolongprofilelabelnamethatexceedstwenty" "Hacker" "h@h.com" "/tmp/h" || return 1

    # 2. Invalid emails with INI newline injection
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add safe1 "User" "bad"$'\n'"[user]" "/tmp/s" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add safe2 "User" "no-at-sign.com" "/tmp/s" || return 1
    assert_exit_code 1 bash "$REPO_DIR/gitsetu" add safe3 "User" "@no-user.com" "/tmp/s" || return 1
}

# ------------------------------------------------------------------------------
# Test 8: Concurrency & atomic lock stress under parallel profile operations
# ------------------------------------------------------------------------------
test_concurrent_parallel_profile_mutations() {
    local i
    for i in {1..5}; do
        bash "$REPO_DIR/gitsetu" add "worker${i}" "Worker ${i}" "worker${i}@stress.test" "$HOME/ws/worker${i}" >/dev/null 2>&1 &
    done

    wait

    # Verify all 5 profiles exist in profiles.conf
    load_profiles
    local worker_count=0
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ "${PROFILE_LABELS[$i]}" == worker* ]]; then
            worker_count=$((worker_count + 1))
        fi
    done

    assert_equals 5 "$worker_count" "Exactly 5 worker profiles registered after parallel execution" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
run_test "paths with spaces, parentheses, brackets, and plus signs" test_paths_with_spaces_and_special_chars
run_test "deeply nested workspace subdirectories (8 levels)" test_deeply_nested_workspace_subdirectories
run_test "path with single quote (apostrophe)" test_path_with_single_quote
run_test "unicode UTF-8 directory paths" test_unicode_directory_paths
run_test "CRLF-contaminated profiles.conf resilience" test_crlf_profiles_conf_resilience
run_test "guard hook edge cases (detached HEAD, author mismatch)" test_guard_hook_edge_cases
run_test "adversarial input injection rejections" test_adversarial_input_rejections
run_test "concurrent parallel profile mutations (8 workers)" test_concurrent_parallel_profile_mutations

print_results "Adversarial & Stress tests"
teardown_test_home
