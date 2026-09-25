#!/usr/bin/env bash
# tests/test_cli.sh — CLI argument parsing tests for gitsetu entrypoint
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home
source_gitsetu_libs

# We need the absolute path to the executable (tests may cd elsewhere)
GITSETU_EXE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_cli_no_args_shows_help() {
    local output
    output=$(bash "$GITSETU_EXE" 2>&1 || true)
    assert_contains "$output" "One command. All identities. Every machine." "shows brief usage tagline" || return 1
    assert_contains "$output" "Usage: gitsetu setup" "no args prints usage" || return 1
    assert_contains "$output" "gitsetu v1.1.0" "shows version string in brief usage" || return 1
}

test_cli_invalid_command() {
    local output
    output=$(bash "$GITSETU_EXE" fakecmd 2>&1 || true)
    assert_contains "$output" "Unknown command" "catches invalid command" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" fakecmd || return 1
}

test_cli_add_missing_args() {
    local output
    output=$(bash "$GITSETU_EXE" add 2>&1 || true)
    assert_contains "$output" "Usage: gitsetu add" "catches missing args" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" add || return 1
}

test_cli_add_invalid_label() {
    local output
    output=$(bash "$GITSETU_EXE" add "bad label" "Name" "email@test.com" "$HOME/dir" 2>&1 || true)
    assert_contains "$output" "Invalid profile label" "catches invalid label format" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" add "bad label" "Name" "email@test.com" "$HOME/dir" || return 1
}

test_cli_remove_invalid_arg() {
    local output
    output=$(bash "$GITSETU_EXE" remove 2>&1 || true)
    assert_contains "$output" "Usage: gitsetu remove" "catches missing arg for remove" || return 1
    assert_exit_code 1 bash "$GITSETU_EXE" remove || return 1
}

test_cli_help_flag() {
    local output
    output=$(bash "$GITSETU_EXE" --help 2>&1 || true)
    assert_contains "$output" "USAGE" "prints help" || return 1
    assert_exit_code 0 bash "$GITSETU_EXE" --help || return 1
}

test_cli_status_empty_registry_is_safe() {
    # An empty registry is an informational status, not a ghost list command.
    mkdir -p "$HOME/.config/gitsetu"
    : > "$HOME/.config/gitsetu/profiles.conf"
    local output rc=0
    output=$(bash "$GITSETU_EXE" status 2>&1) || rc=$?
    assert_equals "1" "$rc" "empty registry status fails closed"
    assert_not_contains "$output" "bad array subscript" "empty registry status avoids array subscript errors"
    assert_contains "$output" "registry header is missing" "empty registry status explains the invalid format"
}

test_cli_v2_profile_parsing() {
    # The CLI prompt consumes the strict v2 registry.  Email and display name
    # live in profile gitconfig; the registry carries six encoded fields.
    mkdir -p "$HOME/.config/gitsetu" "$HOME/.ssh" "$HOME/work/repo"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@corp.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "myghuser"
    } > "$GITSETU_PROFILES_CONF"

    local output
    output=$(cd "$HOME/work/repo" && bash "$GITSETU_EXE" prompt 2>/dev/null)
    assert_equals "work" "$output" "prompt reads a strict v2 registry" || return 1
}

test_cli_legacy_registry_rejected() {
    source_gitsetu_libs
    mkdir -p "$GITSETU_PROFILES_DIR"
    test_v2_profile_config global "Global User" "global@example.com"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
# legacy seven-field registry
global:::/github.com:0:$HOME/.ssh/id_ed25519_global:global_user
EOF

    local rc=0
    load_profiles >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "CLI library rejects legacy seven-field registry"
    assert_equals "0" "$PROFILE_COUNT" "legacy registry is never migrated or accepted"
}

setup_run_fixture() {
    export GITSETU_OS=gitbash
    local external_dir="$REPO_DIR/.gitsetu-test-external-$$"
    local work_dir="$HOME/work"
    if command -v cygpath >/dev/null 2>&1; then
        external_dir=$(cygpath -w "$external_dir")
        external_dir="${external_dir//\\//}"
        work_dir=$(cygpath -w "$work_dir")
        work_dir="${work_dir//\\//}"
    fi
    rm -rf "$external_dir"
    mkdir -p "$external_dir" "$GITSETU_PROFILES_DIR" "$HOME/.ssh" "$work_dir"
    if ! chmod 700 "$external_dir" 2>/dev/null; then
        printf '    FAIL: could not secure the external-key fixture directory\n'
        return 1
    fi
    mkdir -p "$GITSETU_CONFIG_DIR"
    printf 'gitbash\n' > "$GITSETU_CONFIG_DIR/.test_os"
    ssh-keygen -q -t ed25519 -N '' -f "$external_dir/identity"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$external_dir/identity" ""
        test_v2_registry_line work "$work_dir" "github.com" "0" "$external_dir/identity" ""
    } > "$GITSETU_PROFILES_CONF"
}

test_cli_run_uses_strict_external_key_field() {
    setup_run_fixture
    local output rc=0
    output=$(bash "$GITSETU_EXE" run work -- bash -c 'printf "%s|%s" "$GIT_AUTHOR_EMAIL" "$GIT_COMMITTER_EMAIL"' 2>&1) || rc=$?
    assert_equals "0" "$rc" "run succeeds with a validated external v2 key" || return 1
    assert_equals "work@example.com|work@example.com" "$output" "run exports the strict profile identity" || return 1
    rm -rf "$REPO_DIR/.gitsetu-test-external-$$"
}

test_cli_run_missing_key_never_defaults() {
    setup_run_fixture
    rm -f "$REPO_DIR/.gitsetu-test-external-$$/identity" "$REPO_DIR/.gitsetu-test-external-$$/identity.pub"
    local output rc=0
    output=$(bash "$GITSETU_EXE" run work -- true 2>&1) || rc=$?
    assert_equals "1" "$rc" "run fails when the v2 key field is missing" || return 1
    assert_contains "$output" "missing, unsafe, or non-canonical SSH key path" "run reports the missing strict key" || return 1
    rm -rf "$REPO_DIR/.gitsetu-test-external-$$"
}

# Regression: the initial blueprint deliberately stores the global profile's
# directory as an empty string.  A sequential headless add must normalize that
# one intentional sentinel to the root route, while retaining strict canonical
# validation for every non-empty profile directory.
test_cli_sequential_headless_add_with_empty_global_directory() {
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    rm -f "$GITSETU_PROFILES_CONF" "$HOME/.gitconfig"
    printf '[user]\n\tname = Global User\n\temail = global@example.com\n' > "$HOME/.gitconfig"
    rm -rf "$GITSETU_PROFILES_DIR" "$GITSETU_CONFIG_DIR/backups"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"

    local output rc=0
    output=$(bash "$GITSETU_EXE" profile add alpha \
        --name="Alpha User" --email="alpha@example.com" \
        --dir="$HOME/alpha" --key="$HOME/.ssh/id_alpha" 2>&1) || rc=$?
    assert_equals "0" "$rc" "first sequential headless add succeeds with an empty global directory" || {
        printf '%s\n' "$output" >&2
        return 1
    }

    rc=0
    output=$(bash "$GITSETU_EXE" profile add beta \
        --name="Beta User" --email="beta@example.com" \
        --dir="$HOME/beta" --key="$HOME/.ssh/id_beta" 2>&1) || rc=$?
    assert_equals "0" "$rc" "second sequential headless add succeeds" || {
        printf '%s\n' "$output" >&2
        return 1
    }

    load_profiles >/dev/null 2>&1 || return 1
    assert_equals "3" "$PROFILE_COUNT" "sequential adds preserve the global profile" || return 1
    assert_equals "" "${PROFILE_DIRS[0]}" "global profile directory remains the empty sentinel" || return 1
    array_contains "alpha" "${PROFILE_LABELS[@]}" || return 1
    array_contains "beta" "${PROFILE_LABELS[@]}" || return 1
}

printf '\n%btest_cli.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "no arguments shows help" test_cli_no_args_shows_help
run_test "invalid command caught" test_cli_invalid_command
run_test "add with missing args caught" test_cli_add_missing_args
run_test "add with invalid label caught" test_cli_add_invalid_label
run_test "remove with missing args caught" test_cli_remove_invalid_arg
run_test "--help prints menu and exits 0" test_cli_help_flag
run_test "empty registry status is safe" test_cli_status_empty_registry_is_safe
run_test "strict v2 profiles.conf parsing" test_cli_v2_profile_parsing
run_test "legacy seven-field registry rejected" test_cli_legacy_registry_rejected
run_test "run uses the strict external v2 key field" test_cli_run_uses_strict_external_key_field
run_test "run never defaults a missing v2 key path" test_cli_run_missing_key_never_defaults
run_test "sequential headless add handles the empty global directory" test_cli_sequential_headless_add_with_empty_global_directory
print_results "CLI tests"
