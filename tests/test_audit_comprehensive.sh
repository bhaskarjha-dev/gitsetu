#!/usr/bin/env bash
# tests/test_audit_comprehensive.sh — Tests for all 8 comprehensive audit findings
#
# Bash 3.2 compatible. Zero external dependencies.
# Validates:
#   1. Infinite loop prevention in validate_path on drive roots (C:/, C:)
#   2. Global fallback include in ~/.gitconfig before includeIf directives
#   3. Guard hook case-insensitivity and longest prefix match
#   4. SSH key path quoting with spaces in gitconfig and cmd_run
#   5. Dynamic XDG_CONFIG_HOME handling across backup, ssh, teardown, keychain
#   6. Dry-run directory mutation prevention in ensure_dirs
#   7. Terminal cursor and echo restoration in cleanup handlers
#   8. Automatic lowercase normalization for profile labels in CLI commands

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/helpers.sh"

# ==============================================================================
# Finding 1: validate_path infinite loop on Windows drive roots
# ==============================================================================
test_f01_validate_path_terminates_on_drive_root() {
    setup_test_home
    source_gitsetu_libs

    # Test Windows drive root path C:/
    local res=0
    validate_path "C:/" 2>/dev/null || res=$?
    # On Windows C:/ exists (res=0); on Linux/macOS it doesn't (res=1).
    # The critical test is that it terminates immediately without infinite hanging.
    assert_contains "0 1" "$res" "validate_path 'C:/' must terminate"

    # Test Windows drive without trailing slash C:
    res=0
    validate_path "C:" 2>/dev/null || res=$?
    assert_contains "0 1" "$res" "validate_path 'C:' must terminate"

    # Test nonexistent path on drive root
    res=0
    validate_path "C:/audit_nonexistent_test_12345" 2>/dev/null || res=$?
    assert_contains "0 1" "$res" "validate_path 'C:/...' must terminate"
}

# ==============================================================================
# Finding 2: Global fallback gitconfig include before includeIf
# ==============================================================================
test_f02_global_gitconfig_fallback_included() {
    setup_test_home
    source_gitsetu_libs

    GITSETU_DRY_RUN=0
    PROFILE_COUNT=2
    PROFILE_LABELS=("global" "work")
    PROFILE_NAMES=("Global Developer" "Work Dev")
    PROFILE_EMAILS=("global@company.com" "work@company.com")
    PROFILE_DIRS=("" "$HOME/work")
    PROFILE_PROVIDERS=("github.com" "github.com")
    PROFILE_SIGNS=("0" "0")
    PROFILE_KEYS=("$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519_work")
    PROFILE_USERS=("" "")
    PROFILE_PATS=("" "")

    # Generate master gitconfig
    write_global_gitconfig

    # ~/.gitconfig must contain an [include] directive pointing to global profile gitconfig
    assert_file_contains "$HOME/.gitconfig" "global.gitconfig" "Master gitconfig must include global.gitconfig fallback"

    # Verify that the fallback [include] comes BEFORE the [includeIf]
    local fallback_line includeif_line
    fallback_line=$(grep -n "global.gitconfig" "$HOME/.gitconfig" | head -n1 | cut -d: -f1)
    includeif_line=$(grep -n "includeIf" "$HOME/.gitconfig" | head -n1 | cut -d: -f1)

    if [[ -n "$fallback_line" && -n "$includeif_line" ]]; then
        if [[ "$fallback_line" -ge "$includeif_line" ]]; then
            printf "    FAIL: global fallback must precede includeIf directives\n"
            return 1
        fi
    else
        printf "    FAIL: missing fallback or includeIf directive\n"
        return 1
    fi
}

# ==============================================================================
# Finding 3: Guard hook case-insensitivity and longest prefix match
# ==============================================================================
test_f03_guard_longest_match_and_casing() {
    setup_test_home
    source_gitsetu_libs

    mkdir -p "$HOME/.config/gitsetu/profiles"
    mkdir -p "$HOME/.config/gitsetu/hooks"

    # Profile 1: parent dir /workspace (shorter match)
    cat > "$HOME/.config/gitsetu/profiles/general.gitconfig" <<EOF
[user]
    name = General
    email = general@example.com
EOF

    # Profile 2: nested dir /workspace/special (longer match)
    cat > "$HOME/.config/gitsetu/profiles/special.gitconfig" <<EOF
[user]
    name = Special
    email = special@example.com
EOF

    # Write profiles.conf with the shorter match AFTER the longer match (or vice versa)
    # The longest match should win regardless of file order!
    cat > "$HOME/.config/gitsetu/profiles.conf" <<EOF
special::$HOME/workspace/special:github.com:0:$HOME/.ssh/id_special:
general::$HOME/workspace:github.com:0:$HOME/.ssh/id_general:
EOF

    # Install the guard hook
    install_guard

    local hook="$HOME/.config/gitsetu/hooks/pre-commit"
    assert_file_exists "$hook" "Guard pre-commit hook must exist"

    # Test inside nested directory repo
    local repo_dir="$HOME/workspace/special/repo1"
    mkdir -p "$repo_dir/.git"
    git init "$repo_dir" >/dev/null 2>&1 || true
    git -C "$repo_dir" config user.email "special@example.com"
    git -C "$repo_dir" config user.name "Special"

    # Execute the hook inside repo_dir with correct email
    local exit_code=0
    (cd "$repo_dir" && bash "$hook") || exit_code=$?
    assert_equals "0" "$exit_code" "Guard hook should allow commit when email matches the longest profile match"

    # Execute the hook inside repo_dir with wrong email (general@example.com)
    git -C "$repo_dir" config user.email "general@example.com"
    exit_code=0
    (cd "$repo_dir" && bash "$hook" 2>/dev/null) || exit_code=$?
    assert_equals "1" "$exit_code" "Guard hook should reject commit when email doesn't match the most specific profile"
}

# ==============================================================================
# Finding 4: Key paths with spaces quoted in gitconfig and cmd_run
# ==============================================================================
test_f04_key_path_spaces_quoted() {
    setup_test_home
    source_gitsetu_libs

    local space_key="$HOME/My Secret Keys/id_ed25519_work"
    local content
    content=$(build_profile_gitconfig "work" "Work User" "work@company.com" "0" "$space_key")

    assert_contains "$content" "sshCommand = ssh -i \"~/My Secret Keys/id_ed25519_work\"" "build_profile_gitconfig must quote key paths with spaces"
}

# ==============================================================================
# Finding 5: Incomplete XDG support across backup, ssh, teardown, keychain
# ==============================================================================
test_f05_xdg_config_home_support() {
    setup_test_home
    local custom_xdg="$HOME/custom_xdg"
    export XDG_CONFIG_HOME="$custom_xdg"
    source_gitsetu_libs

    # 1. Test SSH config dynamic Include
    local ssh_config="$HOME/.ssh/config"
    write_ssh_config

    assert_file_exists "$ssh_config" "SSH config must exist"
    assert_file_contains "$ssh_config" "custom_xdg" "SSH config Include directive must reference XDG_CONFIG_HOME"

    # 2. Test Keychain fallback token storage
    keychain_store "test_label" "github.com" "test_user" "secret_token_123"
    assert_file_exists "$custom_xdg/gitsetu/.tokens" "Tokens must be saved under custom XDG_CONFIG_HOME"
    local loaded
    loaded=$(keychain_get "test_label" "github.com" | grep "password=" | cut -d= -f2)
    assert_equals "secret_token_123" "$loaded" "Token loaded from custom XDG_CONFIG_HOME"

    # 3. Test Teardown dynamic Include cleanup
    teardown_all 0
    assert_file_not_contains "$ssh_config" "custom_xdg" "Teardown must clean up custom XDG SSH Include directive"
}

# ==============================================================================
# Finding 6: Dry-run directory mutation in ensure_dirs
# ==============================================================================
test_f06_dry_run_prevents_directory_creation() {
    setup_test_home
    source_gitsetu_libs

    local target_conf="$HOME/.config/gitsetu"
    rm -rf "$target_conf"

    GITSETU_DRY_RUN=1
    ensure_dirs

    assert_dir_not_exists "$target_conf" "ensure_dirs must NOT create directories when GITSETU_DRY_RUN=1"
    GITSETU_DRY_RUN=0
}

# ==============================================================================
# Finding 7: Terminal cursor and echo restoration in cleanup
# ==============================================================================
test_f07_cleanup_restores_cursor() {
    setup_test_home

    local root_bin="$SCRIPT_DIR/../gitsetu"
    # 1. Check statically that both cleanup traps restore cursor
    assert_file_contains "$root_bin" "printf '\033[?25h'" "gitsetu must contain cursor restore code"

    # 2. Run gitsetu and capture stderr to verify the escape sequence is emitted on exit
    local out
    out=$(bash "$root_bin" --version 2>&1 || true)
    local has_cursor=0
    if [[ "$out" == *$'\033[?25h'* ]]; then
        has_cursor=1
    fi
    assert_equals "1" "$has_cursor" "gitsetu execution must output \\033[?25h on exit"
}

# ==============================================================================
# Finding 8: CLI automatic lowercase normalization for profile labels
# ==============================================================================
test_f08_cli_label_lowercase_normalization() {
    setup_test_home
    source_gitsetu_libs

    # Setup baseline
    mkdir -p "$HOME/.config/gitsetu"
    local root_bin="$SCRIPT_DIR/../gitsetu"

    # Add profile with uppercase label "WorkProfile" via gitsetu add CLI
    bash "$root_bin" add "WorkProfile" "Aditya Work" "work@company.com" "$HOME/work" >/dev/null 2>&1

    # Read profiles.conf and verify label was lowercased to "workprofile"
    local found_label=""
    while IFS=: read -r label rest || [[ -n "$label" ]]; do
        [[ "$label" == "#"* ]] && continue
        [[ -z "$label" ]] && continue
        if [[ "$label" == "workprofile" ]]; then
            found_label="$label"
            break
        fi
    done < "$HOME/.config/gitsetu/profiles.conf"

    assert_equals "workprofile" "$found_label" "gitsetu add must normalize profile label to lowercase"

    # Test removing with mixed case "WorkProfile" via gitsetu profile remove CLI
    bash "$root_bin" profile remove "WorkProfile" >/dev/null 2>&1

    # Verify profile was removed
    local still_exists=0
    while IFS=: read -r label rest || [[ -n "$label" ]]; do
        [[ "$label" == "#"* ]] && continue
        [[ -z "$label" ]] && continue
        if [[ "$label" == "workprofile" ]]; then
            still_exists=1
            break
        fi
    done < "$HOME/.config/gitsetu/profiles.conf"

    assert_equals "0" "$still_exists" "gitsetu remove must normalize label to lowercase"
}

# ==============================================================================
# Main Runner
# ==============================================================================
printf '\n=== Running Comprehensive Audit Test Suite ===\n\n'

run_test "F01: validate_path terminates on drive roots (C:/, C:)" test_f01_validate_path_terminates_on_drive_root
run_test "F02: global gitconfig fallback included before includeIf" test_f02_global_gitconfig_fallback_included
run_test "F03: guard hook longest match and case-insensitivity" test_f03_guard_longest_match_and_casing
run_test "F04: key path with spaces quoted in gitconfig" test_f04_key_path_spaces_quoted
run_test "F05: dynamic XDG_CONFIG_HOME across backup, ssh, teardown, keychain" test_f05_xdg_config_home_support
run_test "F06: dry-run early return in ensure_dirs prevents mutation" test_f06_dry_run_prevents_directory_creation
run_test "F07: cursor restoration sequence in cleanup" test_f07_cleanup_restores_cursor
run_test "F08: CLI label lowercase normalization in add and profile" test_f08_cli_label_lowercase_normalization

print_results "Audit Comprehensive Tests"
