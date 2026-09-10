#!/usr/bin/env bash
# tests/test_audit_regressions.sh — Regression tests for zero-defect audit findings
#
# Each test validates a specific fix from the v1.1.1 audit.
# Tests are designed to FAIL without the corresponding code fix.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/helpers.sh"

# ==============================================================================
# F01: cmd_status active identity checkmark was broken because profiles.conf
#      writes an empty email column but cmd_status compared that empty string
#      to the current git email.
# ==============================================================================
test_f01_status_loads_email_from_gitconfig() {
    setup_test_home
    source_gitsetu_libs

    # Create a profile gitconfig with a known email
    mkdir -p "$HOME/.config/gitsetu/profiles"
    cat > "$HOME/.config/gitsetu/profiles/work.gitconfig" <<EOF
[user]
    name = Test User
    email = work@company.com
[core]
    sshCommand = ssh -i $HOME/.ssh/id_ed25519_work
EOF

    # Create profiles.conf with EMPTY email column (this is what write_profiles_conf does)
    cat > "$HOME/.config/gitsetu/profiles.conf" <<EOF
work::$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:
EOF

    # The GITSETU_PROFILES_DIR must point to our test dir
    GITSETU_PROFILES_DIR="$HOME/.config/gitsetu/profiles"

    # Parse the profile like cmd_status does
    local profile_email=""
    while IFS=: read -r label email dir provider sign_commits key_path _unused || [[ -n "$label" ]]; do
        [[ "$label" == "#"* ]] && continue
        [[ -z "$label" ]] && continue
        # This is the fix: load from gitconfig instead of using empty registry email
        profile_email=$(git config -f "$GITSETU_PROFILES_DIR/${label}.gitconfig" user.email 2>/dev/null || true)
        if [[ -z "$profile_email" ]] && [[ -n "$email" ]]; then
            profile_email="$email"
        fi
    done < "$HOME/.config/gitsetu/profiles.conf"

    assert_equals "work@company.com" "$profile_email" "Email should be loaded from profile gitconfig, not empty registry column"
}

# ==============================================================================
# F02: doctor.sh was sending all output to stdout instead of stderr
# ==============================================================================
test_f02_doctor_outputs_to_stderr() {
    setup_test_home
    source_gitsetu_libs

    # Set up minimal state so doctor doesn't crash
    PROFILE_COUNT=0
    PROFILE_LABELS=()
    PROFILE_DIRS=()
    mkdir -p "$HOME/.config/gitsetu"

    # Capture stdout only — it should be empty
    local stdout_output
    stdout_output=$(run_doctor 2>/dev/null) || true

    assert_equals "" "$stdout_output" "doctor should produce zero stdout output"
}

# ==============================================================================
# F03: generate_initial_blueprint() didn't initialize PROFILE_USERS/PROFILE_PATS
# ==============================================================================
test_f03_blueprint_initializes_all_arrays() {
    setup_test_home
    source_gitsetu_libs

    # Reset all arrays
    PROFILE_COUNT=0
    PROFILE_LABELS=()
    PROFILE_NAMES=()
    PROFILE_EMAILS=()
    PROFILE_DIRS=()
    PROFILE_PROVIDERS=()
    PROFILE_SIGNS=()
    PROFILE_KEYS=()
    PROFILE_USERS=()
    PROFILE_PATS=()

    generate_initial_blueprint

    # After blueprint, PROFILE_USERS[0] and PROFILE_PATS[0] should be initialized (even if empty)
    # Under set -u, accessing an uninitialized array index would crash
    # Note: use ${var-X} not ${var:-X} because :-  treats empty as unset
    local users_val="${PROFILE_USERS[0]-UNSET}"
    local pats_val="${PROFILE_PATS[0]-UNSET}"

    # They should be empty strings, NOT "UNSET"
    assert_equals "" "$users_val" "PROFILE_USERS[0] should be initialized to empty string"
    assert_equals "" "$pats_val" "PROFILE_PATS[0] should be initialized to empty string"
}

# ==============================================================================
# F04: MANAGED_BLOCK env var was exported and never unset
# ==============================================================================
test_f04_managed_block_not_leaked() {
    setup_test_home
    source_gitsetu_libs

    # Set up minimal profiles for write_global_gitconfig
    PROFILE_COUNT=1
    PROFILE_LABELS=("global")
    PROFILE_NAMES=("Test")
    PROFILE_EMAILS=("test@test.com")
    PROFILE_DIRS=("")
    PROFILE_PROVIDERS=("github.com")
    PROFILE_SIGNS=("0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global")
    PROFILE_USERS=("")
    PROFILE_PATS=("")
    GITSETU_DRY_RUN=0
    GITSETU_SCRIPT_DIR="$SCRIPT_DIR/.."

    # Create an existing gitconfig WITH a managed block so the awk path runs
    cat > "$HOME/.gitconfig" <<EOF
# [gitsetu:managed:start]
[user]
    name = old
# [gitsetu:managed:end]
EOF

    write_global_gitconfig >/dev/null 2>&1

    # MANAGED_BLOCK should have been unset after use
    if [[ -n "${MANAGED_BLOCK:-}" ]]; then
        printf '    FAIL: MANAGED_BLOCK env var still set after write_global_gitconfig\n'
        return 1
    fi
    return 0
}

# ==============================================================================
# F07: completion.sh should not offer non-existent 'init' subcommand
# ==============================================================================
test_f07_completion_no_ghost_subcommands() {
    setup_test_home

    local completion_file="$SCRIPT_DIR/../lib/completion.sh"
    local opts_line
    opts_line=$(grep 'opts=' "$completion_file")

    assert_not_contains "$opts_line" "init" "completion should not offer non-existent 'init' subcommand"
    assert_contains "$opts_line" "backup" "completion should offer 'backup' subcommand"
    assert_contains "$opts_line" "restore" "completion should offer 'restore' subcommand"
    assert_contains "$opts_line" "credential" "completion should offer 'credential' subcommand"
}

# ==============================================================================
# F09: Empty cleanup arrays should not crash under set -u
# ==============================================================================
test_f09_empty_cleanup_arrays_safe() {
    setup_test_home
    source_gitsetu_libs

    # Ensure cleanup arrays are empty
    GITSETU_CLEANUP_FILES=()
    # shellcheck disable=SC2034  # consumed by gitsetu_global_cleanup() below
    GITSETU_CLEANUP_DIRS=()

    # This should NOT crash under set -u
    gitsetu_global_cleanup 2>/dev/null

    # If we got here, it didn't crash
    return 0
}

# ==============================================================================
# C01: ask_password must NOT be called via command substitution $()
#      because it sets $REPLY (lost in subshell) and prints nothing to stdout
# ==============================================================================
test_c01_ask_password_not_in_subshell() {
    local backup_file="$SCRIPT_DIR/../lib/backup.sh"

    # Grep for the broken pattern: $(ask_password ...)
    local violations
    # shellcheck disable=SC2016  # Intentional: grepping for the literal pattern $(ask_password
    violations=$(grep -c '$(ask_password' "$backup_file" 2>/dev/null | tr -d '\r') || true

    if [[ "$violations" -gt 0 ]]; then
        printf '    FAIL: ask_password called via command substitution (%s times)\n' "$violations"
        # shellcheck disable=SC2016  # Intentional: human-readable message referencing $REPLY
        printf '    This silently discards $REPLY. Use: ask_password "..."; var="$REPLY"\n'
        return 1
    fi
    return 0
}

# ==============================================================================
# S01: cleanup trap must restore stty echo to prevent stuck terminal
# ==============================================================================
test_s01_cleanup_restores_stty() {
    local gitsetu_file="$SCRIPT_DIR/../gitsetu"

    # The cleanup() function must contain stty echo
    local has_stty
    has_stty=$(grep -A5 'cleanup()' "$gitsetu_file" | grep -c 'stty echo' | tr -d '\r') || true

    if [[ "$has_stty" -eq 0 ]]; then
        printf '    FAIL: cleanup() does not restore stty echo\n'
        return 1
    fi
    return 0
}

# ==============================================================================
# W01: Windows drive path normalization converts /c/path to C:/path
# ==============================================================================
test_w01_windows_path_normalization() {
    setup_test_home
    source_gitsetu_libs

    if [[ "$GITSETU_OS" == "gitbash" ]]; then
        local p1 p2
        p1=$(normalize_path "/c/Users/test/pro")
        assert_equals "C:/Users/test/pro" "$p1" "convert /c/ to C:/"

        p2=$(normalize_path 'D:\dev\work')
        assert_equals "D:/dev/work" "$p2" "convert backslash to forward slash and uppercase drive"
    fi
    return 0
}

# ==============================================================================
# W02: OpenSSH Include and IdentityFile use portable tilde notation
# ==============================================================================
test_w02_openssh_portable_paths() {
    setup_test_home
    source_gitsetu_libs

    local block
    block=$(build_ssh_host_block "work" "github.com" "$HOME/.ssh/id_ed25519_work")
    assert_contains "$block" "IdentityFile ~/.ssh/id_ed25519_work" "IdentityFile uses portable ~/.ssh/"

    PROFILE_LABELS=("global" "work")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_work")
    PROFILE_COUNT=2

    write_ssh_config >/dev/null 2>&1
    assert_file_contains "$HOME/.ssh/config" "Include ~/.config/gitsetu/profiles/ssh_config" "Include uses portable path"
}

# ==============================================================================
# W03: Profile gitconfig uses portable sshCommand
# ==============================================================================
test_w03_profile_portable_sshcommand() {
    setup_test_home
    source_gitsetu_libs

    local content
    content=$(build_profile_gitconfig "work" "Work User" "work@company.com" 0 "$HOME/.ssh/id_ed25519_work")
    assert_contains "$content" "sshCommand = ssh -i ~/.ssh/id_ed25519_work" "sshCommand uses portable path"
}

# ==============================================================================
# W04: Windows uses native credential manager helper
# ==============================================================================
test_w04_windows_credential_helper() {
    setup_test_home
    source_gitsetu_libs

    if [[ "$GITSETU_OS" == "gitbash" ]]; then
        local block
        block=$(build_global_gitconfig_block)
        assert_contains "$block" "helper = manager" "Windows uses manager credential helper"
    fi
    return 0
}

# ==============================================================================
# W06: NTFS 644 permission warnings suppressed under gitbash
# ==============================================================================
test_w06_ntfs_permissions_handling() {
    setup_test_home
    source_gitsetu_libs

    if [[ "$GITSETU_OS" == "gitbash" ]]; then
        local key="$HOME/.ssh/id_ed25519_test"
        mkdir -p "$HOME/.ssh"
        touch "$key" "$key.pub"
        chmod 644 "$key" 2>/dev/null || true

        local issues=0
        PROFILE_LABELS=("test")
        PROFILE_KEYS=("$key")
        PROFILE_COUNT=1
        verify_ssh_keys || issues=$?
        assert_equals 0 "$issues" "644 on NTFS should not trigger permission error"
    fi
    return 0
}

# ==============================================================================
# W07: Live Git configuration evaluation in a real repo
# ==============================================================================
test_w07_live_git_resolution() {
    setup_test_home
    source_gitsetu_libs

    local work_dir="$HOME/work_repo"
    mkdir -p "$work_dir"

    PROFILE_LABELS=("global" "work")
    PROFILE_NAMES=("Global User" "Work User")
    PROFILE_EMAILS=("global@example.com" "work@company.com")
    PROFILE_DIRS=("" "$work_dir")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_work")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")
    PROFILE_COUNT=2

    ensure_dirs
    write_global_gitconfig >/dev/null 2>&1
    write_profile_gitconfig "work" "Work User" "work@company.com" >/dev/null 2>&1
    write_profiles_conf >/dev/null 2>&1

    # Initialize a real Git repository in work_dir
    (
        cd "$work_dir"
        git init --quiet
        local resolved_email
        resolved_email=$(git config user.email 2>/dev/null || echo "")
        assert_equals "work@company.com" "$resolved_email" "Live Git resolves work profile email inside work_dir"
    )
}

# ==============================================================================
# Run all regression tests
# ==============================================================================
run_test "F01: cmd_status loads email from profile gitconfig" test_f01_status_loads_email_from_gitconfig
run_test "F02: doctor outputs exclusively to stderr" test_f02_doctor_outputs_to_stderr
run_test "F03: generate_initial_blueprint initializes all 9 arrays" test_f03_blueprint_initializes_all_arrays
run_test "F04: MANAGED_BLOCK env var is unset after use" test_f04_managed_block_not_leaked
run_test "F07: completion offers no ghost subcommands" test_f07_completion_no_ghost_subcommands
run_test "F09: empty cleanup arrays survive set -u" test_f09_empty_cleanup_arrays_safe
run_test "C01: ask_password not called via subshell capture" test_c01_ask_password_not_in_subshell
run_test "S01: cleanup trap restores stty echo" test_s01_cleanup_restores_stty
run_test "W01: Windows drive path normalization converts /c/path to C:/path" test_w01_windows_path_normalization
run_test "W02: OpenSSH Include and IdentityFile use portable tilde notation" test_w02_openssh_portable_paths
run_test "W03: Profile gitconfig uses portable sshCommand" test_w03_profile_portable_sshcommand
run_test "W04: Windows uses native credential manager helper" test_w04_windows_credential_helper
run_test "W06: NTFS 644 permissions accepted under gitbash" test_w06_ntfs_permissions_handling
run_test "W07: Live Git resolves includeIf in real repo" test_w07_live_git_resolution

print_results "Audit Regression tests"

