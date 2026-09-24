#!/usr/bin/env bash
# tests/test_assurance.sh — Contracts for the test harness itself.
#
# The deliberately failing cases execute in child shells.  They are expected to
# fail; this suite fails only when the harness fails to notice those failures.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/helpers.sh"

TEST_FIXTURE=""

write_fixture() {
    local contents_path="$1"
    cat > "$contents_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"

fail_then_pass() {
    if ! assert_equals 1 2 "intentional fail-then-pass assertion"; then
        :
    fi
    assert_equals 1 1 "later passing assertion"
}

subshell_case() {
    if ! (assert_equals 1 2 "intentional subshell assertion"); then
        :
    fi
    assert_equals 1 1 "later assertion after subshell"
}

pipeline_case() {
    if ! printf 'fixture\n' | { assert_equals 1 2 "intentional pipeline assertion"; }; then
        :
    fi
    assert_equals 1 1 "later assertion after pipeline"
}

command_substitution_case() {
    local ignored
    if ! ignored=$(assert_equals 1 2 "intentional command-substitution assertion"); then
        :
    fi
    assert_equals 1 1 "later assertion after command substitution"
}

skip_case() {
    skip_test "optional contract" "capability intentionally unavailable"
    return 0
}

source_module="${TMPDIR:-/tmp}/gitsetu-assurance-source-module.$$"
printf 'printf "sourced\\n"\n' > "$source_module"
if ! source_test_module "$source_module"; then
    rm -f "$source_module"
    exit 1
fi
# Replace an already syntax-cached module with invalid syntax.  The source
# return-status check must still fail even though bash -n is not rerun.
printf 'if then\n' > "$source_module"
source_failure_case() {
    source_test_module "$source_module"
}

run_test "fail then pass" fail_then_pass
run_test "subshell" subshell_case
run_test "pipeline" pipeline_case
run_test "command substitution" command_substitution_case
run_test "explicit skip" skip_case
run_test "undefined function" __gitsetu_assurance_function_that_does_not_exist
run_test "module source failure" source_failure_case
rm -f "$source_module"

# Four assertion failures, one undefined-function failure, one module-source
# failure, and one explicit skip must be visible in the counters.  A
# variable-only latch would lose the first four failures and fail this
# contract.
if [[ "$TESTS_FAILED" -ne 6 || "$TESTS_PASSED" -ne 0 || "$TESTS_SKIPPED" -ne 1 ]]; then
    printf 'ASSURANCE_SELF_TEST_COUNTS_FAILED pass=%s fail=%s skip=%s\n' \
        "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED" >&2
    exit 1
fi

# Exercise the non-vacuous assertion contracts in the same controlled child.
if assert_contains "text" ""; then
    printf 'ASSURANCE_EMPTY_NEEDLE_ACCEPTED\n' >&2
    exit 1
fi
if assert_not_contains "text" ""; then
    printf 'ASSURANCE_EMPTY_NEGATIVE_NEEDLE_ACCEPTED\n' >&2
    exit 1
fi
if assert_file_not_contains "/definitely/missing/file" "needle"; then
    printf 'ASSURANCE_MISSING_FILE_NEGATIVE_ACCEPTED\n' >&2
    exit 1
fi
empty_file="${TMPDIR:-/tmp}/gitsetu-assurance-empty.$$"
: > "$empty_file"
if assert_file_not_contains "$empty_file" "needle"; then
    rm -f "$empty_file"
    printf 'ASSURANCE_EMPTY_FILE_NEGATIVE_ACCEPTED\n' >&2
    exit 1
fi
rm -f "$empty_file"

printf 'ASSURANCE_SELF_TEST_OK\n'
EOF
    chmod 700 "$contents_path"
}

# The child receives a fresh helper state.  In particular, do not let it share
# the parent's latch file or EXIT cleanup.
run_child_fixture() {
    local fixture="$1"
    local output=""
    local rc=0

    if output=$(env -u GITSETU_TEST_LATCH_FILE bash "$fixture" "$SCRIPT_DIR/helpers.sh" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    TEST_FIXTURE="$fixture"
    printf '%s\n' "$output"
    return "$rc"
}

test_failure_latch_survives_shell_boundaries() {
    local fixture
    fixture=$(mktemp "$TEST_STATE_DIR/gitsetu-assurance-self-test.XXXXXX")
    write_fixture "$fixture"

    local output=""
    local rc=0
    if output=$(run_child_fixture "$fixture" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    rm -f "$fixture"
    TEST_FIXTURE=""
    assert_equals "0" "$rc" "controlled failure-latch self-test exits successfully"
    assert_contains "$output" "ASSURANCE_SELF_TEST_OK" "self-test verifies expected failures were counted"
}

test_environment_stack_restores_real_state() {
    local fixture
    fixture=$(mktemp "$TEST_STATE_DIR/gitsetu-assurance-env-test.XXXXXX")
    cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
original_home="$HOME"
export GITSETU_ASSURANCE_SENTINEL="outer"
export GIT_CONFIG_GLOBAL="$original_home/.outer-gitconfig"
export CI="outer"

setup_test_home
first_home="$HOME"
[[ "$first_home" != "$original_home" ]]
[[ -z "${GITSETU_ASSURANCE_SENTINEL-}" ]]
[[ -z "${GIT_CONFIG_GLOBAL-}" ]]
[[ -z "${CI-}" ]]
[[ "$GITSETU_TEST" == "1" ]]

setup_test_home
second_home="$HOME"
[[ "$second_home" != "$first_home" ]]
teardown_test_home
[[ "$HOME" == "$first_home" ]]
[[ -z "${GITSETU_ASSURANCE_SENTINEL-}" ]]
teardown_test_home
[[ "$HOME" == "$original_home" ]]
[[ "$GITSETU_ASSURANCE_SENTINEL" == "outer" ]]
[[ "$GIT_CONFIG_GLOBAL" == "$original_home/.outer-gitconfig" ]]
[[ "$CI" == "outer" ]]
printf 'ASSURANCE_ENV_OK\n'
EOF
    chmod 700 "$fixture"

    local output=""
    local rc=0
    if output=$(env -u GITSETU_TEST_LATCH_FILE bash "$fixture" "$SCRIPT_DIR/helpers.sh" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    rm -f "$fixture"
    assert_equals "0" "$rc" "repeated test-home setup restores the source environment"
    assert_contains "$output" "ASSURANCE_ENV_OK" "environment stack contract is satisfied"
}

test_explicit_skip_is_not_a_pass() {
    local fixture
    fixture=$(mktemp "$TEST_STATE_DIR/gitsetu-assurance-skip-test.XXXXXX")
    cat > "$fixture" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
optional_case() {
    skip_test "optional tool" "tool is unavailable"
    return 0
}
run_test "optional case" optional_case
[[ "$TESTS_PASSED" -eq 0 && "$TESTS_FAILED" -eq 0 && "$TESTS_SKIPPED" -eq 1 ]]
printf 'ASSURANCE_SKIP_OK\n'
EOF
    chmod 700 "$fixture"

    local output=""
    local rc=0
    if output=$(env -u GITSETU_TEST_LATCH_FILE bash "$fixture" "$SCRIPT_DIR/helpers.sh" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    rm -f "$fixture"
    assert_equals "0" "$rc" "explicit skip exits successfully"
    assert_contains "$output" "ASSURANCE_SKIP_OK" "skip is counted separately from PASS"
    assert_contains "$output" "[SKIP]" "skip is visible in test output"
}

test_runner_rejects_legacy_bundle_selector() {
    local output=""
    local rc=0
    if output=$(GITSETU_TEST_BIN="$SCRIPT_DIR/../dist/gitsetu" \
        bash "$SCRIPT_DIR/run_all.sh" --suite __legacy_selector_contract__ 2>&1); then
        rc=0
    else
        rc=$?
    fi

    assert_equals "2" "$rc" "legacy GITSETU_TEST_BIN selector is rejected"
    assert_contains "$output" "not a supported test-runner selector" "runner explains the explicit bundle alternative"
}

printf '\n%btest_assurance.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "failure latch survives subshells and pipelines" test_failure_latch_survives_shell_boundaries
run_test "test-home stack restores real environment" test_environment_stack_restores_real_state
run_test "explicit skip semantics" test_explicit_skip_is_not_a_pass
run_test "legacy bundle selector is rejected" test_runner_rejects_legacy_bundle_selector
print_results "Test assurance tests"
