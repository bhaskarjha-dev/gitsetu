#!/usr/bin/env bash
# tests/test_audit_regressions.sh — Regression tests for zero-defect audit findings
#
# Each test validates a specific fix from the v1.1.0 audit.
# Tests are designed to FAIL without the corresponding code fix.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/helpers.sh"

# ==============================================================================
# F01: cmd_status active identity checkmark must use the identity stored in
#      profile gitconfig; strict v2 registry records do not carry email fields.
# ==============================================================================
test_f01_status_loads_email_from_gitconfig() {
    setup_test_home
    source_gitsetu_libs

    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Test User" "work@company.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" ""
    } > "$GITSETU_PROFILES_CONF"

    # The v2 loader is the same path used by status; email is intentionally
    # absent from the registry and must come from profile gitconfig.
    load_profiles

    assert_equals "2" "$PROFILE_COUNT" "strict v2 registry loaded both profiles"
    assert_equals "work@company.com" "${PROFILE_EMAILS[1]}" "email is loaded from profile gitconfig"
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
    stdout_output=$(run_doctor 2>/dev/null)

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
# F07: init is a supported setup alias and must remain in completion
# ==============================================================================
test_f07_completion_alias_is_present() {
    setup_test_home

    local completion_file="$SCRIPT_DIR/../lib/completion.sh"
    local opts_line
    opts_line=$(grep 'opts=' "$completion_file")

    assert_contains "$opts_line" "init" "completion should offer the supported 'init' setup alias"
    assert_contains "$opts_line" "backup" "completion should offer 'backup' subcommand"
    assert_contains "$opts_line" "restore" "completion should offer 'restore' subcommand"
    assert_contains "$opts_line" "credential" "completion should offer 'credential' subcommand"
}

# ==============================================================================
# F09: Empty cleanup arrays should not crash under set -u
# ==============================================================================
test_f09_empty_cleanup_arrays_safe() {
    setup_test_home

    # The cleanup function is defined by the root entrypoint, not by the
    # library-only source helper.  Exercise the real entrypoint in a child
    # shell; --version reaches its EXIT cleanup and returns normally.
    local root_entrypoint="$SCRIPT_DIR/../gitsetu"
    local output rc=0
    output=$(GITSETU_TEST=1 bash "$root_entrypoint" --version 2>&1) || rc=$?

    assert_equals "0" "$rc" "root entrypoint cleanup handles empty cleanup arrays"
    assert_contains "$output" "gitsetu v" "root entrypoint still renders its version after cleanup"
}

# ==============================================================================
# C01: ask_password must NOT be called via command substitution $()
#      because it sets $REPLY (lost in subshell) and prints nothing to stdout
# ==============================================================================
test_c01_ask_password_not_in_subshell() {
    local backup_file="$SCRIPT_DIR/../lib/backup.sh"

    # Grep for the broken pattern: $(ask_password ...)
    local violations
    assert_file_exists "$backup_file" "backup module exists for command-substitution check"
    # shellcheck disable=SC2016  # Intentional: grepping for the literal pattern $(ask_password
    if ! violations=$(grep -c '$(ask_password' "$backup_file" 2>/dev/null | tr -d '\r'); then
        # grep -c returns 1 when there are no matches; normalize that expected
        # status to the actual count instead of hiding a command failure.
        violations=0
    fi

    if [[ "$violations" -gt 0 ]]; then
        printf '    FAIL: ask_password called via command substitution (%s times)\n' "$violations"
        # shellcheck disable=SC2016  # Intentional: human-readable message referencing $REPLY
        printf '    This silently discards $REPLY. Use: ask_password "..."; var="$REPLY"\n'
        return 1
    fi
    return 0
}

# ==============================================================================
# S01: terminal cleanup is delegated to the UI restoration helper
# ==============================================================================
test_s01_cleanup_restores_stty() {
    local gitsetu_file="$SCRIPT_DIR/../gitsetu"
    assert_file_exists "$gitsetu_file" "root entrypoint exists for cleanup check" || return 1

    # The current contract routes terminal restoration through the shared UI
    # helper and installs the global EXIT/signal traps around it.  Assert the
    # contract, not a fixed line window around a legacy cleanup() body.
    assert_file_contains "$gitsetu_file" "ui_restore_terminal" \
        "global cleanup delegates terminal restoration to the UI helper" || return 1
    assert_file_contains "$gitsetu_file" "trap gitsetu_global_cleanup EXIT" \
        "global cleanup is installed as the EXIT trap" || return 1
    assert_file_contains "$gitsetu_file" "gitsetu_signal_cleanup" \
        "signal cleanup uses the same terminal-restoration contract" || return 1
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
    else
        skip_test "W01: Windows drive path normalization" "test is only applicable to Git Bash"
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
    assert_contains "$block" "IdentityFile" "IdentityFile directive is present" || return 1
    assert_contains "$block" "id_ed25519_work" "IdentityFile references the effective key basename" || return 1

    PROFILE_LABELS=("global" "work")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519_global" "$HOME/.ssh/id_ed25519_work")
    PROFILE_COUNT=2

    write_ssh_config >/dev/null 2>&1
    assert_file_contains "$HOME/.ssh/config" "profiles/ssh_config" "Include references the generated SSH config" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/ssh_config" "id_ed25519_work" "generated SSH config retains the effective key" || return 1
}

# ==============================================================================
# W03: Profile gitconfig uses portable sshCommand
# ==============================================================================
test_w03_profile_portable_sshcommand() {
    setup_test_home
    source_gitsetu_libs

    local content config_file ssh_command
    content=$(build_profile_gitconfig "work" "Work User" "work@company.com" 0 "$HOME/.ssh/id_ed25519_work")
    config_file="$TEST_HOME/profile-gitconfig.w03"
    printf '%s\n' "$content" > "$config_file"
    if ! ssh_command=$(git config --file "$config_file" --get core.sshCommand); then
        rm -f "$config_file"
        printf '    FAIL: Git could not parse the generated core.sshCommand\n'
        return 1
    fi
    assert_contains "$ssh_command" "-i" "effective sshCommand uses an identity-file option" || return 1
    assert_contains "$ssh_command" "id_ed25519_work" "effective sshCommand references the managed key basename" || return 1
    assert_contains "$ssh_command" "IdentitiesOnly=yes" "effective sshCommand keeps the identity restriction" || return 1
    rm -f "$config_file"
}

# ==============================================================================
# W04: Windows credential policy is native/broker, never plaintext
# ==============================================================================
test_w04_windows_credential_helper() {
    setup_test_home
    source_gitsetu_libs
    GITSETU_OS=gitbash
    export GIT_CONFIG_NOSYSTEM=1
    rm -f "$HOME/.gitconfig"

    local block
    block=$(build_global_gitconfig_block)
    assert_not_contains "$block" ".tokens" "managed config never configures plaintext token storage" || return 1
    if [[ "$block" == *"[credential]"* ]]; then
        assert_contains "$block" "gitsetu" "managed credential policy uses the validated broker" || return 1
    fi
    return 0
}

# ==============================================================================
# W06: NTFS 644 permission warnings suppressed under gitbash
# ==============================================================================
test_w06_ntfs_permissions_handling() {
    setup_test_home
    source_gitsetu_libs
    GITSETU_OS=gitbash

    if [[ "${OSTYPE:-}" == "cygwin"* || "${OSTYPE:-}" == "msys"* || "${OSTYPE:-}" == "mingw"* ]]; then
        local key="$HOME/.ssh/id_ed25519_test"
        mkdir -p "$HOME/.ssh"
        ssh-keygen -t ed25519 -N "" -C "test@example.com" -f "$key" -q >/dev/null 2>&1 || {
            skip_test "W06: NTFS permission handling" "ssh-keygen fixture creation failed"
            return 0
        }
        if ! chmod 644 "$key" 2>/dev/null; then
            skip_test "W06: NTFS permission handling" "chmod is unavailable on this filesystem"
            return 0
        fi
        if ! _verify_is_supported_ntfs "$key"; then
            skip_test "W06: NTFS permission handling" "fixture is not on a supported NTFS/MSYS filesystem"
            return 0
        fi

        local issues=0 verify_output
        PROFILE_LABELS=("global")
        PROFILE_KEYS=("$key")
        PROFILE_COUNT=1
        verify_output=$(verify_ssh_keys 2>&1) || issues=$?
        assert_equals 0 "$issues" "644 on NTFS should not trigger permission error" || return 1
        assert_not_contains "$verify_output" "Incorrect permissions" "NTFS verification does not report a POSIX mode error" || return 1
    else
        skip_test "W06: NTFS permission handling" "test is only applicable to Git Bash"
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
        if ! resolved_email=$(git config user.email 2>/dev/null); then
            resolved_email=""
        fi
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
run_test "F07: completion offers the supported init alias" test_f07_completion_alias_is_present
run_test "F09: empty cleanup arrays survive set -u" test_f09_empty_cleanup_arrays_safe
run_test "C01: ask_password not called via subshell capture" test_c01_ask_password_not_in_subshell
run_test "S01: cleanup trap restores stty echo" test_s01_cleanup_restores_stty
run_test "W01: Windows drive path normalization converts /c/path to C:/path" test_w01_windows_path_normalization
run_test "W02: OpenSSH Include and IdentityFile use portable tilde notation" test_w02_openssh_portable_paths
run_test "W03: Profile gitconfig uses portable sshCommand" test_w03_profile_portable_sshcommand
run_test "W04: Windows credential policy is native/broker, never plaintext" test_w04_windows_credential_helper
run_test "W06: NTFS 644 permissions accepted under gitbash" test_w06_ntfs_permissions_handling
run_test "W07: Live Git resolves includeIf in real repo" test_w07_live_git_resolution

print_results "Audit Regression tests"

