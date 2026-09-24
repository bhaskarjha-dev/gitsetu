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

# Headless `gitsetu add` derives the mandatory global profile from the
# configured Git identity.  Seed that identity in the isolated HOME so path
# and Unicode cases exercise setup rather than failing at global validation.
if ! git config --global user.name "Global Stress User" ||
   ! git config --global user.email "global-stress@example.test"; then
    printf '  [FATAL] could not seed the global Git identity\n' >&2
    exit 1
fi

# Avoid spawning a Win32 helper for every private path component in Cygwin;
# the shim still recognizes ordinary symlinks and is used only by this suite.
if [[ "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "msys"* ]]; then
    # shellcheck disable=SC2329  # invoked indirectly by platform helpers
    cygpath() {
        printf '%s' "${!#}"
    }
    # shellcheck disable=SC2329  # invoked indirectly by platform helpers
    fsutil.exe() {
        local path="${!#}"
        [[ -L "$path" ]] && return 0
        return 1
    }
    export -f cygpath fsutil.exe
fi

ADVERSARIAL_LOCK_TIMEOUT_WAS_SET=0
ADVERSARIAL_LOCK_TIMEOUT_VALUE=""
set_adversarial_test_lock_timeout() {
    if [[ -n "${GITSETU_LOCK_TIMEOUT+x}" ]]; then
        ADVERSARIAL_LOCK_TIMEOUT_WAS_SET=1
        ADVERSARIAL_LOCK_TIMEOUT_VALUE="$GITSETU_LOCK_TIMEOUT"
    else
        ADVERSARIAL_LOCK_TIMEOUT_WAS_SET=0
        ADVERSARIAL_LOCK_TIMEOUT_VALUE=""
    fi
    export GITSETU_LOCK_TIMEOUT=120
}

restore_adversarial_test_lock_timeout() {
    if [[ "$ADVERSARIAL_LOCK_TIMEOUT_WAS_SET" -eq 1 ]]; then
        export GITSETU_LOCK_TIMEOUT="$ADVERSARIAL_LOCK_TIMEOUT_VALUE"
    else
        unset GITSETU_LOCK_TIMEOUT
    fi
}

reset_adversarial_state() {
    if ! rm -rf -- "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig"; then
        printf '    FAIL: could not reset adversarial test state\n'
        return 1
    fi
    if ! mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"; then
        printf '    FAIL: could not initialize adversarial test state\n'
        return 1
    fi
    if ! git config --global user.name "Global Stress User" ||
       ! git config --global user.email "global-stress@example.test"; then
        printf '    FAIL: could not seed the global Git identity\n'
        return 1
    fi
    return 0
}

printf '\n%b=== Running tests/test_adversarial_stress.sh ===%b\n' "$T_BOLD" "$T_RESET"

# ------------------------------------------------------------------------------
# Test 1: Workspace paths with multiple spaces, parentheses, brackets, and plus signs
# ------------------------------------------------------------------------------
test_paths_with_spaces_and_special_chars() {
    reset_adversarial_state || return 1
    local weird_dir="$HOME/My Projects (Work)/Client + Partner/team-alpha"
    mkdir -p "$weird_dir"

    # Add profile with spaces, parens, and plus signs in path
    GITSETU_DRY_RUN=0
    local out
    out=$(bash "$REPO_DIR/gitsetu" add weird "Weird User" "weird@example.com" "$weird_dir" 2>&1)

    assert_contains "$out" "Setup complete! You're ready to go." "Profile added and completion summary rendered" || return 1

    # Verify the strict v2 registry and profile identity.
    load_profiles
    array_contains "weird" "${PROFILE_LABELS[@]}" || {
        printf '    FAIL: weird profile missing from strict v2 registry\n'
        return 1
    }
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
    if ! resolved_name=$(git config user.name 2>/dev/null); then
        resolved_name=""
    fi
    if ! resolved_email=$(git config user.email 2>/dev/null); then
        resolved_email=""
    fi
    popd >/dev/null

    assert_equals "Weird User" "$resolved_name" "Git correctly resolves user.name inside spaces/symbols directory" || return 1
    assert_equals "weird@example.com" "$resolved_email" "Git correctly resolves user.email inside spaces/symbols directory" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: Deeply nested child repository inside workspace
# ------------------------------------------------------------------------------
test_deeply_nested_workspace_subdirectories() {
    reset_adversarial_state || return 1
    local root_ws="$HOME/workspaces/mega-corp"
    local deep_repo="$root_ws/dept/subdept/team/project/services/backend/repo"
    mkdir -p "$deep_repo"

    bash "$REPO_DIR/gitsetu" add megacorp "Corp User" "corp@megacorp.internal" "$root_ws" >/dev/null 2>&1

    pushd "$deep_repo" >/dev/null
    git init -q
    local active_email
    active_email=$(git config user.email 2>/dev/null)

    # Check prompt resolution 8 directories deep
    local prompt_id prompt_rc=0
    prompt_id=$(bash "$REPO_DIR/gitsetu" prompt 2>/dev/null) || prompt_rc=$?
    popd >/dev/null

    assert_equals "corp@megacorp.internal" "$active_email" "Git resolves identity 8 levels deep inside workspace" || return 1
    assert_equals "0" "$prompt_rc" "gitsetu prompt exits successfully" || return 1
    assert_equals "megacorp" "$prompt_id" "gitsetu prompt correctly identifies active profile 8 levels deep" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: Path with single quote (apostrophe) in directory name
# ------------------------------------------------------------------------------
test_path_with_single_quote() {
    reset_adversarial_state || return 1
    local quote_dir="$HOME/dev/o'reilly_media/books"
    mkdir -p "$quote_dir"

    local out
    out=$(bash "$REPO_DIR/gitsetu" add oreilly "Editor" "editor@oreilly.com" "$quote_dir" 2>&1)
    assert_contains "$out" "Setup complete! You're ready to go." "Profile added and completion summary rendered" || return 1

    pushd "$quote_dir" >/dev/null
    git init -q
    local res_email
    if ! res_email=$(git config user.email 2>/dev/null); then
        res_email=""
    fi
    popd >/dev/null

    assert_equals "editor@oreilly.com" "$res_email" "Single quote path resolves identity via Git includeIf" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: Unicode UTF-8 directory names (Accented characters & Japanese)
# ------------------------------------------------------------------------------
test_unicode_directory_paths() {
    reset_adversarial_state || return 1
    local unicode_dir="$HOME/projets_étudiant/プロジェクト/日本語"
    mkdir -p "$unicode_dir"

    local out
    out=$(bash "$REPO_DIR/gitsetu" add tokyo "Dev Tokyo" "tokyo@example.jp" "$unicode_dir" 2>&1)
    assert_contains "$out" "Setup complete" "Profile added with UTF-8 Unicode directory path" || return 1

    pushd "$unicode_dir" >/dev/null
    git init -q
    local res_email
    if ! res_email=$(git config user.email 2>/dev/null); then
        res_email=""
    fi
    popd >/dev/null

    assert_equals "tokyo@example.jp" "$res_email" "Unicode UTF-8 path resolves identity via Git" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: CRLF-contaminated profiles.conf resilience
# ------------------------------------------------------------------------------
test_crlf_v2_registry_rejected() {
    reset_adversarial_state || return 1
    local backup_conf=""
    if [[ -f "$GITSETU_PROFILES_CONF" ]]; then
        backup_conf=$(cat "$GITSETU_PROFILES_CONF")
    fi

    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config alpha "Alpha User" "alpha@example.com"
    test_v2_profile_config beta "Beta User" "beta@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line alpha "$HOME/alpha" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_alpha" ""
        test_v2_registry_line beta "$HOME/beta" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_beta" ""
    } > "$GITSETU_PROFILES_CONF"

    # A CRLF-contaminated v2 record is malformed, not a legacy format to be
    # silently migrated.  The loader must reject it without loading profiles.
    local crlf_tmp="${GITSETU_PROFILES_CONF}.crlf.$$"
    local crlf_line
    while IFS= read -r crlf_line || [[ -n "$crlf_line" ]]; do
        printf '%s\r\n' "$crlf_line"
    done < "$GITSETU_PROFILES_CONF" > "$crlf_tmp"
    mv "$crlf_tmp" "$GITSETU_PROFILES_CONF"

    local rc=0
    load_profiles >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "CRLF-contaminated v2 registry is rejected"
    assert_equals "0" "$PROFILE_COUNT" "rejected CRLF registry loads no profiles"

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
    reset_adversarial_state || return 1
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
    reset_adversarial_state || return 1
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
    reset_adversarial_state || return 1
    set_adversarial_test_lock_timeout

    local i status output_file failed_count=0
    local expected_workers=5
    # MSYS/Cygwin process creation is expensive and can exhaust the process
    # table when several full CLI children contend. Two workers still exercise
    # real lock serialization without turning this into a Windows stress loop.
    if [[ "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "mingw"* ]]; then
        expected_workers=2
    fi
    local -a child_pids=()
    local -a child_logs=()
    for ((i=1; i<=expected_workers; i++)); do
        output_file="$TEST_HOME/stress-worker-$i.log"
        rm -f "$output_file"
        child_logs+=("$output_file")
        bash "$REPO_DIR/gitsetu" add "worker${i}" "Worker ${i}" \
            "worker${i}@stress.test" "$HOME/ws/worker${i}" >"$output_file" 2>&1 &
        child_pids+=("$!")
    done
    for i in "${!child_pids[@]}"; do
        status=0
        wait "${child_pids[$i]}" || status=$?
        if [[ "$status" -ne 0 ]]; then
            printf '    FAIL: stress worker %s exited %s\n' "$i" "$status"
            if [[ -f "${child_logs[$i]}" ]]; then
                cat "${child_logs[$i]}"
            fi
            failed_count=$((failed_count + 1))
        fi
    done
    restore_adversarial_test_lock_timeout
    [[ "$failed_count" -eq 0 ]] || return 1
    rm -f "$TEST_HOME"/stress-worker-*.log

    # Verify all expected workers exist in profiles.conf
    load_profiles
    local worker_count=0
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ "${PROFILE_LABELS[$i]}" == worker* ]]; then
            worker_count=$((worker_count + 1))
        fi
    done

    assert_equals "$expected_workers" "$worker_count" "expected worker profiles registered after parallel execution" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
run_test "paths with spaces, parentheses, brackets, and plus signs" test_paths_with_spaces_and_special_chars
run_test "deeply nested workspace subdirectories (8 levels)" test_deeply_nested_workspace_subdirectories
run_test "path with single quote (apostrophe)" test_path_with_single_quote
run_test "unicode UTF-8 directory paths" test_unicode_directory_paths
run_test "CRLF-contaminated v2 registry is rejected" test_crlf_v2_registry_rejected
run_test "guard hook edge cases (detached HEAD, author mismatch)" test_guard_hook_edge_cases
run_test "adversarial input injection rejections" test_adversarial_input_rejections
run_test "concurrent parallel profile mutations (bounded workers)" test_concurrent_parallel_profile_mutations

print_results "Adversarial & Stress tests"
teardown_test_home
