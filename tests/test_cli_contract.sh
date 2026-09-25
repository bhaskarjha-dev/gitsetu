#!/usr/bin/env bash
# tests/test_cli_contract.sh — Exhaustive top-level command/arity/error contracts.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXE="$ROOT/gitsetu"
EXE="${EXE%$'\r'}"

CLI_OUTPUT=""
CLI_STATUS=0

contract_home() {
    setup_test_home
    source_gitsetu_libs
    export CI=1
    export GITSETU_TEST=1
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
}

invoke_cli() {
    if CLI_OUTPUT=$(bash "$EXE" "$@" 2>&1); then
        CLI_STATUS=0
    else
        CLI_STATUS=$?
    fi
    return 0
}

assert_cli_status() {
    local expected="$1"
    local message="$2"
    assert_equals "$expected" "$CLI_STATUS" "$message"
}

assert_cli_contains() {
    local needle="$1"
    local message="$2"
    assert_contains "$CLI_OUTPUT" "$needle" "$message"
}

test_no_args_non_tty_is_usage_success() {
    contract_home
    export CI=1
    invoke_cli
    assert_cli_status 0 "no arguments in non-interactive mode is a successful usage path"
    assert_cli_contains "Usage: gitsetu setup" "no-argument usage names setup"
    assert_cli_contains "gitsetu v1.1.0" "no-argument usage includes the current version"
}

test_help_aliases_and_extra_arguments() {
    contract_home
    local arg
    for arg in --help -h help; do
        invoke_cli "$arg"
        assert_cli_status 0 "$arg returns success"
        assert_cli_contains "USAGE" "$arg prints the full usage"
        assert_cli_contains "profile" "$arg documents profile management"
        assert_cli_contains "credential" "$arg documents the credential protocol"
    done
    invoke_cli --help extra
    assert_cli_status 1 "help rejects extra arguments"
    assert_cli_contains "Usage: gitsetu --help" "help explains its arity"
}

test_version_aliases_and_extra_arguments() {
    contract_home
    local arg
    for arg in --version -v; do
        invoke_cli "$arg"
        assert_cli_status 0 "$arg returns success"
        assert_cli_contains "gitsetu v1.1.0" "$arg prints the current version"
    done
    invoke_cli --version extra
    assert_cli_status 1 "version rejects extra arguments"
    assert_cli_contains "Usage: gitsetu --version" "version explains its arity"
}

test_unknown_command_and_setup_option_fail_closed() {
    contract_home
    invoke_cli definitely-not-a-command
    assert_cli_status 1 "unknown top-level command fails"
    assert_cli_contains "Unknown command" "unknown command is named"

    invoke_cli setup --definitely-not-an-option
    assert_cli_status 1 "unknown setup option fails"
    assert_cli_contains "Unknown setup option" "unknown setup option is named"
}

test_add_status_verify_and_run_arity_contracts() {
    contract_home
    invoke_cli add
    assert_cli_status 1 "add requires four arguments"
    assert_cli_contains "Usage: gitsetu add" "add arity is explained"

    invoke_cli status extra
    assert_cli_status 1 "status rejects extra arguments"
    assert_cli_contains "Usage: gitsetu status" "status arity is explained"

    invoke_cli verify extra
    assert_cli_status 1 "verify rejects extra arguments"
    assert_cli_contains "Usage: gitsetu verify" "verify arity is explained"

    invoke_cli run
    assert_cli_status 1 "run requires a profile and separator"
    invoke_cli run work
    assert_cli_status 1 "run requires the literal command separator"
}

test_backup_restore_and_profile_arity_contracts() {
    contract_home
    invoke_cli backup one two
    assert_cli_status 1 "backup accepts at most one output path"
    assert_cli_contains "Usage: gitsetu backup" "backup arity is explained"

    invoke_cli restore
    assert_cli_status 1 "restore requires exactly one vault path"
    assert_cli_contains "Usage: gitsetu restore" "restore arity is explained"
    invoke_cli restore one two
    assert_cli_status 1 "restore rejects extra paths"

    invoke_cli profile
    assert_cli_status 1 "profile requires an action and label"
    assert_cli_contains "Usage: gitsetu profile" "profile arity is explained"
    invoke_cli profile unknown action
    assert_cli_status 1 "profile rejects unknown actions"
    assert_cli_contains "Unknown profile action" "profile action error is named"
}

test_credential_arity_and_non_https_behavior() {
    contract_home
    invoke_cli credential
    assert_cli_status 1 "credential requires an action"
    invoke_cli credential unknown
    assert_cli_status 1 "credential rejects unknown actions"
    assert_cli_contains "Unknown credential action" "credential action error is named"

    CLI_OUTPUT=$(printf 'protocol=ssh\nhost=example.com\n\n' | bash "$EXE" credential get 2>&1)
    CLI_STATUS=$?
    assert_cli_status 0 "non-HTTPS credential requests are safely ignored"
    assert_equals "" "$CLI_OUTPUT" "non-HTTPS credential request emits no secret"
}

test_teardown_guard_and_update_option_contracts() {
    contract_home
    invoke_cli teardown --unknown-option
    assert_cli_status 1 "teardown rejects unknown options"
    assert_cli_contains "Unknown teardown option" "teardown option error is named"

    invoke_cli guard
    assert_cli_status 1 "guard requires install or uninstall"
    invoke_cli guard --unknown
    assert_cli_status 1 "guard rejects unknown actions"
    assert_cli_contains "Unknown guard option" "guard action error is named"
    invoke_cli guard --install extra
    assert_cli_status 1 "guard rejects extra arguments"

    invoke_cli update
    assert_cli_status 1 "bare update is refused"
    assert_cli_contains "Usage: gitsetu update --development" "update explains development-only mode"
    invoke_cli update --unknown
    assert_cli_status 1 "update rejects unknown modes"
}

test_doctor_unknown_option_and_status_without_registry() {
    contract_home
    invoke_cli doctor --unknown-option
    assert_cli_status 1 "doctor rejects unknown options"
    assert_cli_contains "Unknown doctor option" "doctor option error is named"

    invoke_cli status
    assert_cli_status 0 "status is an informational success without a registry"
    assert_cli_contains "No complete profiles configured" "status explains the unconfigured state"
    invoke_cli verify
    assert_cli_status 1 "verify fails clearly without a valid registry"
    assert_cli_contains "No profiles configured" "verify explains the missing setup"
}

test_remove_and_prompt_empty_state_contracts() {
    contract_home
    invoke_cli remove
    assert_cli_status 1 "remove requires a profile label"
    assert_cli_contains "Usage: gitsetu remove" "remove arity is explained"

    CLI_OUTPUT=$(cd "$HOME" && bash "$EXE" prompt 2>/dev/null)
    CLI_STATUS=$?
    assert_cli_status 0 "prompt is a safe no-op outside a mapped profile"
    assert_equals "" "$CLI_OUTPUT" "prompt emits no label without a registry"
}

test_profile_remove_rejects_force_flag() {
    contract_home
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" "$HOME/.ssh/id_ed25519_work" ""
    } > "$GITSETU_PROFILES_CONF"
    invoke_cli profile remove work --force
    assert_cli_status 1 "profile remove rejects the unsupported force flag"
    assert_cli_contains "does not accept flags" "profile remove explains its flag contract"
}

test_profile_global_removal_is_rejected() {
    contract_home
    mkdir -p "$GITSETU_PROFILES_DIR"
    test_v2_profile_config global "Global User" "global@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" ""
    } > "$GITSETU_PROFILES_CONF"
    invoke_cli profile remove global
    assert_cli_status 1 "the mandatory global profile cannot be removed"
    assert_cli_contains "global" "global-profile rejection identifies the profile"
}

printf '\n%btest_cli_contract.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "no arguments non-TTY usage" test_no_args_non_tty_is_usage_success
run_test "help aliases and arity" test_help_aliases_and_extra_arguments
run_test "version aliases and arity" test_version_aliases_and_extra_arguments
run_test "unknown command and setup option" test_unknown_command_and_setup_option_fail_closed
run_test "add status verify run arity" test_add_status_verify_and_run_arity_contracts
run_test "backup restore profile arity" test_backup_restore_and_profile_arity_contracts
run_test "credential arity and non-HTTPS" test_credential_arity_and_non_https_behavior
run_test "teardown guard update options" test_teardown_guard_and_update_option_contracts
run_test "doctor status verify empty state" test_doctor_unknown_option_and_status_without_registry
run_test "remove and prompt empty state" test_remove_and_prompt_empty_state_contracts
run_test "profile remove force rejected" test_profile_remove_rejects_force_flag
run_test "global profile removal rejected" test_profile_global_removal_is_rejected
print_results "CLI contract tests"
