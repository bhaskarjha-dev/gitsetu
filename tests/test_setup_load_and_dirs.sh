#!/usr/bin/env bash
# tests/test_setup_load_and_dirs.sh — Regression tests for setup profile loading & workspace directory auto-creation
#
# Validates:
# 1. Existing strict v2 profiles in profiles.conf are not erased when setup runs.
# 2. Workspace directories for configured profiles are created automatically if missing.
# 3. Existing directories remain untouched.
# 4. Dry-run mode does not create directories on disk.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/helpers.sh"

test_setup_preserves_existing_profiles() {
    setup_test_home
    source_gitsetu_libs

    # Seed a strict v2 registry and profile gitconfigs.  Legacy seven-field
    # records are rejection fixtures, never setup inputs.
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    test_v2_profile_config personal "Personal User" "personal@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" ""
        test_v2_registry_line personal "$HOME/personal" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_personal" ""
    } > "$GITSETU_PROFILES_CONF"

    # Simulate setup bootstrap logic (load_profiles + conditional generate_initial_blueprint)
    PROFILE_COUNT=0
    load_profiles
    if [[ "$PROFILE_COUNT" -eq 0 ]]; then
        generate_initial_blueprint
    fi

    assert_equals "3" "$PROFILE_COUNT" "Setup loaded all 3 existing profiles"
    assert_equals "global" "${PROFILE_LABELS[0]}" "Profile 0 is global"
    assert_equals "work" "${PROFILE_LABELS[1]}" "Profile 1 is work"
    assert_equals "personal" "${PROFILE_LABELS[2]}" "Profile 2 is personal"
    assert_equals "work@example.com" "${PROFILE_EMAILS[1]}" "Work email loaded correctly"
    assert_equals "personal@example.com" "${PROFILE_EMAILS[2]}" "Personal email loaded correctly"
}

test_ensure_workspace_dirs_creates_missing_dirs() {
    setup_test_home
    source_gitsetu_libs

    local work_dir="$HOME/new_work_ws"
    local personal_dir="$HOME/new_personal_ws"

    assert_dir_not_exists "$work_dir" "Work workspace should not exist initially"
    assert_dir_not_exists "$personal_dir" "Personal workspace should not exist initially"

    PROFILE_COUNT=3
    PROFILE_LABELS=("global" "work" "personal")
    PROFILE_DIRS=("" "$work_dir" "$personal_dir")

    GITSETU_DRY_RUN=0
    ensure_workspace_dirs

    assert_dir_exists "$work_dir" "ensure_workspace_dirs created missing work directory"
    assert_dir_exists "$personal_dir" "ensure_workspace_dirs created missing personal directory"
}

test_ensure_workspace_dirs_idempotent_on_existing_dirs() {
    setup_test_home
    source_gitsetu_libs

    local existing_dir="$HOME/already_exists"
    mkdir -p "$existing_dir"
    echo "keep_me" > "$existing_dir/test_file.txt"

    PROFILE_COUNT=1
    PROFILE_LABELS=("custom")
    PROFILE_DIRS=("$existing_dir")

    GITSETU_DRY_RUN=0
    ensure_workspace_dirs

    assert_dir_exists "$existing_dir" "Existing directory remains present"
    assert_file_exists "$existing_dir/test_file.txt" "Contents of existing directory preserved"
}

test_ensure_workspace_dirs_dry_run_creates_nothing() {
    setup_test_home
    source_gitsetu_libs

    local dry_dir="$HOME/dry_run_ws"
    assert_dir_not_exists "$dry_dir" "Dry run dir should not exist initially"

    PROFILE_COUNT=1
    PROFILE_LABELS=("dry_profile")
    PROFILE_DIRS=("$dry_dir")

    GITSETU_DRY_RUN=1
    ensure_workspace_dirs

    assert_dir_not_exists "$dry_dir" "Dry run did NOT create directory on disk"
}

# Run all tests
run_test "Setup preserves existing strict v2 profiles" test_setup_preserves_existing_profiles
run_test "ensure_workspace_dirs creates missing workspace directories" test_ensure_workspace_dirs_creates_missing_dirs
run_test "ensure_workspace_dirs is idempotent on existing directories" test_ensure_workspace_dirs_idempotent_on_existing_dirs
run_test "ensure_workspace_dirs does not create directories in dry-run mode" test_ensure_workspace_dirs_dry_run_creates_nothing

print_results "Setup Profile Loading and Workspace Dirs tests"
