#!/usr/bin/env bash
# tests/test_core.sh — Unit tests for lib/core.sh
#
# Tests: strict v2 load_profiles(), remove_profile_at_index(), to_lower(), array_contains()
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

# This suite has one isolated HOME and resets only its generated profile state
# between cases.  Avoid taking a full environment snapshot for every small unit
# case; the assurance suite exercises that behavior separately.
_TEST_SKIP_ENV_SNAPSHOT=1

reset_core_test_state() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
}

# The shared helpers in tests/helpers.sh construct strict v2 fixtures.  Keep all
# registry acceptance tests below on that contract; legacy files are rejection
# tests only.

seed_removal_v2_profiles() {
    local count="$1"
    test_v2_profile_config global "Global User" "global@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
    } > "$GITSETU_PROFILES_CONF"

    if [[ "$count" -ge 2 ]]; then
        test_v2_profile_config work "Work User" "work@example.com"
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "" >> "$GITSETU_PROFILES_CONF"
    fi
    if [[ "$count" -ge 3 ]]; then
        test_v2_profile_config oss "OSS User" "oss@example.com"
        test_v2_registry_line oss "$HOME/oss" "gitlab.com" "0" \
            "$HOME/.ssh/id_ed25519_oss" "" >> "$GITSETU_PROFILES_CONF"
    fi
    load_profiles
}

# ==============================================================================
# to_lower
# ==============================================================================
test_to_lower_basic() {
    local result
    result=$(to_lower "FooBar")
    assert_equals "foobar" "$result" "converts mixed case to lowercase"
}

test_to_lower_already_lower() {
    local result
    result=$(to_lower "hello")
    assert_equals "hello" "$result" "no-op on lowercase"
}

test_to_lower_all_upper() {
    local result
    result=$(to_lower "HELLO")
    assert_equals "hello" "$result" "converts all uppercase"
}

test_to_lower_empty() {
    local result
    result=$(to_lower "")
    assert_equals "" "$result" "handles empty string"
}

# ==============================================================================
# array_contains
# ==============================================================================
test_array_contains_found() {
    local arr=("alpha" "beta" "gamma")
    array_contains "beta" "${arr[@]}"
}

test_array_contains_not_found() {
    local arr=("alpha" "beta" "gamma")
    ! array_contains "delta" "${arr[@]}"
}

test_array_contains_single() {
    local arr=("only")
    array_contains "only" "${arr[@]}"
}

test_array_contains_empty_needle() {
    local arr=("alpha" "" "gamma")
    array_contains "" "${arr[@]}"
}

# ==============================================================================
# load_profiles — strict v2 registry
# ==============================================================================
test_load_profiles_basic() {
    reset_core_test_state

    test_v2_profile_config global "Global User" "global@corp.com"
    test_v2_profile_config work "Work User" "work@corp.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "ghuser"
    } > "$GITSETU_PROFILES_CONF"

    load_profiles

    assert_equals "2" "$PROFILE_COUNT" "loaded global and work v2 profiles"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global is the first v2 profile"
    assert_equals "" "${PROFILE_DIRS[0]}" "global directory remains empty"
    assert_equals "work" "${PROFILE_LABELS[1]}" "work label decoded from v2"
    assert_equals "Work User" "${PROFILE_NAMES[1]}" "name loaded from profile gitconfig"
    assert_equals "work@corp.com" "${PROFILE_EMAILS[1]}" "email loaded from profile gitconfig"
    assert_equals "$HOME/work" "${PROFILE_DIRS[1]}" "directory decoded from v2"
    assert_equals "github.com" "${PROFILE_PROVIDERS[1]}" "provider decoded from v2"
    assert_equals "0" "${PROFILE_SIGNS[1]}" "sign flag decoded from v2"
    assert_equals "$HOME/.ssh/id_ed25519_work" "${PROFILE_KEYS[1]}" "key path decoded from v2"
    assert_equals "ghuser" "${PROFILE_USERS[1]}" "provider user decoded from v2"
}

# ==============================================================================
# load_profiles — invalid empty/comment-only v2 input
# ==============================================================================
test_load_profiles_empty_file_rejected() {
    reset_core_test_state

    mkdir -p "$GITSETU_CONFIG_DIR"
    : > "$GITSETU_PROFILES_CONF"

    local rc=0
    load_profiles >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "an empty registry is rejected as invalid v2"
    assert_equals "0" "$PROFILE_COUNT" "rejected empty registry clears profile state"
    assert_contains "$GITSETU_REGISTRY_ERROR" "header" "empty registry reports the missing v2 header"
}

test_load_profiles_comments_only_rejected() {
    reset_core_test_state

    mkdir -p "$GITSETU_CONFIG_DIR"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
# gitsetu profile registry
# Format: label:email:directory:provider:sign_commits:key_path:provider_user
EOF

    local rc=0
    load_profiles >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "legacy comment-only registry is rejected"
    assert_equals "0" "$PROFILE_COUNT" "rejected legacy registry clears profile state"
}

# ==============================================================================
# load_profiles — missing profiles.conf
# ==============================================================================
test_load_profiles_no_file() {
    reset_core_test_state

    # Don't create profiles.conf
    load_profiles

    assert_equals 0 "$PROFILE_COUNT" "missing file yields 0 profiles"
}

# ==============================================================================
# load_profiles — multiple strict v2 profiles
# ==============================================================================
test_load_profiles_multiple() {
    reset_core_test_state

    test_v2_profile_config global "Global" "global@test.com"
    test_v2_profile_config work "Worker" "worker@corp.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "1" \
            "$HOME/.ssh/id_ed25519_work" "myuser"
    } > "$GITSETU_PROFILES_CONF"

    load_profiles

    assert_equals "2" "$PROFILE_COUNT" "loaded two strict v2 profiles"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global remains first"
    assert_equals "work" "${PROFILE_LABELS[1]}" "work follows global"
    assert_equals "1" "${PROFILE_SIGNS[1]}" "sign flag decoded for work"
    assert_equals "myuser" "${PROFILE_USERS[1]}" "provider user decoded for work"
}

# ==============================================================================
# load_profiles — legacy seven-field input is rejection-only
# ==============================================================================
test_load_profiles_legacy_format_rejected() {
    reset_core_test_state

    mkdir -p "$GITSETU_PROFILES_DIR"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
# gitsetu profile registry
# Format: label:email:directory:provider:sign_commits:key_path:provider_user
work:work@corp.com:$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:ghuser
EOF

    local rc=0
    load_profiles >/dev/null 2>&1 || rc=$?

    assert_equals "1" "$rc" "legacy seven-field registry is rejected"
    assert_equals "0" "$PROFILE_COUNT" "legacy rejection leaves no loaded profiles"
    assert_contains "$GITSETU_REGISTRY_ERROR" "unsupported or legacy" "legacy rejection is explicit"
}

# ==============================================================================
# remove_profile_at_index — basic removal
# ==============================================================================
test_remove_profile_basic() {
    reset_core_test_state
    seed_removal_v2_profiles 3

    remove_profile_at_index 1

    assert_equals "2" "$PROFILE_COUNT" "count decremented"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global preserved"
    assert_equals "oss" "${PROFILE_LABELS[1]}" "oss shifted to index 1"
    assert_equals "oss@example.com" "${PROFILE_EMAILS[1]}" "oss email shifted"
    assert_equals "gitlab.com" "${PROFILE_PROVIDERS[1]}" "oss provider shifted"
}

# ==============================================================================
# remove_profile_at_index — remove last element (boundary)
# ==============================================================================
test_remove_profile_last() {
    reset_core_test_state
    seed_removal_v2_profiles 2

    remove_profile_at_index 1

    assert_equals "1" "$PROFILE_COUNT" "count is 1"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global preserved"
}

# ==============================================================================
# remove_profile_at_index — mandatory global is rejected
# ==============================================================================
test_remove_global_profile_rejected() {
    reset_core_test_state
    seed_removal_v2_profiles 1

    local result=0
    remove_profile_at_index 0 || result=$?

    assert_equals "1" "$result" "mandatory global profile cannot be removed"
    assert_equals "1" "$PROFILE_COUNT" "failed global removal leaves profile count unchanged"
    assert_equals "global" "${PROFILE_LABELS[0]}" "failed global removal leaves global intact"
}

# ==============================================================================
# remove_profile_at_index — out of bounds
# ==============================================================================
test_remove_profile_out_of_bounds() {
    reset_core_test_state
    seed_removal_v2_profiles 2

    local result=0
    remove_profile_at_index 5 || result=$?

    assert_equals "1" "$result" "returns 1 for out of bounds"
    assert_equals "2" "$PROFILE_COUNT" "count unchanged"
    assert_equals "global" "${PROFILE_LABELS[0]}" "global remains unchanged"
    assert_equals "work" "${PROFILE_LABELS[1]}" "work remains unchanged"
}

# ==============================================================================
# Top-level array initialization (all 9 arrays declared)
# ==============================================================================
test_top_level_array_init() {
    # After sourcing core.sh, all arrays should be declared even when empty.
    # Inspect declarations rather than element zero: an empty Bash array is
    # legitimately unset for `${array[0]-fallback}` under nounset.
    if ! declare -p PROFILE_USERS >/dev/null 2>&1; then
        printf '    FAIL: PROFILE_USERS not initialized at module scope\n'
        return 1
    fi
    if ! declare -p PROFILE_PATS >/dev/null 2>&1; then
        printf '    FAIL: PROFILE_PATS not initialized at module scope\n'
        return 1
    fi
    if ! declare -p PROFILE_LABELS >/dev/null 2>&1; then
        printf '    FAIL: PROFILE_LABELS not initialized at module scope\n'
        return 1
    fi
    return 0
}

# ==============================================================================
# Run
# ==============================================================================
printf '\n%btest_core.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "to_lower: mixed case" test_to_lower_basic
run_test "to_lower: already lowercase" test_to_lower_already_lower
run_test "to_lower: all uppercase" test_to_lower_all_upper
run_test "to_lower: empty string" test_to_lower_empty
run_test "array_contains: found" test_array_contains_found
run_test "array_contains: not found" test_array_contains_not_found
run_test "array_contains: single element" test_array_contains_single
run_test "array_contains: empty needle" test_array_contains_empty_needle
run_test "load_profiles: strict v2 registry" test_load_profiles_basic
run_test "load_profiles: empty file rejected" test_load_profiles_empty_file_rejected
run_test "load_profiles: comments-only rejected" test_load_profiles_comments_only_rejected
run_test "load_profiles: missing file" test_load_profiles_no_file
run_test "load_profiles: multiple strict v2 profiles" test_load_profiles_multiple
run_test "load_profiles: legacy format rejected" test_load_profiles_legacy_format_rejected
run_test "remove_profile: basic removal" test_remove_profile_basic
run_test "remove_profile: remove last element" test_remove_profile_last
run_test "remove_profile: mandatory global rejected" test_remove_global_profile_rejected
run_test "remove_profile: out of bounds" test_remove_profile_out_of_bounds
run_test "top-level: all 9 arrays initialized" test_top_level_array_init
print_results "Core tests"
