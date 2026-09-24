#!/usr/bin/env bash
# tests/test_bundle_path.sh — Contract tests for an explicitly supplied bundle.
#
# This suite is intentionally not a source-tree suite.  The runner invokes it
# as `bash tests/test_bundle_path.sh /path/to/dist/gitsetu`, and every command
# below executes the copied artifact outside a repository checkout.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/helpers.sh"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
    printf '  [SKIP] bundle contract requires an explicit artifact path (use --bundle PATH)\n'
    exit 77
fi

BUNDLE_INPUT="$1"
if [[ ! -f "$BUNDLE_INPUT" || ! -s "$BUNDLE_INPUT" ]]; then
    printf '  [FAIL] bundle artifact is missing or empty: %s\n' "$BUNDLE_INPUT" >&2
    exit 1
fi

# Resolve before changing directory; the supplied path may be relative.
BUNDLE_DIR=$(cd "$(dirname "$BUNDLE_INPUT")" && pwd -P)
BUNDLE_PATH="$BUNDLE_DIR/$(basename "$BUNDLE_INPUT")"
if [[ "${OSTYPE:-}" == "msys"* ]] || [[ "${OSTYPE:-}" == "cygwin"* ]] || [[ "${OSTYPE:-}" == "mingw"* ]]; then
    BUNDLE_DIR=$(cd "$BUNDLE_DIR" && pwd -W)
    BUNDLE_PATH="$BUNDLE_DIR/$(basename "$BUNDLE_INPUT")"
fi

setup_test_home
BUNDLE_RUN_DIR=$(mktemp -d "$TEST_STATE_DIR/gitsetu-bundle-run.XXXXXX")
BUNDLE_COPY="$BUNDLE_RUN_DIR/gitsetu"

printf '\n%btest_bundle_path.sh%b\n' "$T_BOLD" "$T_RESET"
printf 'Artifact under test: %s\n' "$BUNDLE_PATH"

copy_exact_artifact() {
    cp "$BUNDLE_PATH" "$BUNDLE_COPY"
    chmod 700 "$BUNDLE_COPY"
    assert_file_exists "$BUNDLE_COPY" "bundle is copied into an isolated run directory"
    assert_exit_code 0 cmp -s "$BUNDLE_PATH" "$BUNDLE_COPY"
    assert_dir_not_exists "$BUNDLE_RUN_DIR/lib" "bundle test directory has no source lib/ tree"
}

bundle_version_works() {
    local output rc=0
    output=$(cd "$BUNDLE_RUN_DIR" && bash "$BUNDLE_COPY" --version 2>&1) || rc=$?
    assert_equals "0" "$rc" "bundle --version exits successfully"
    assert_contains "$output" "gitsetu v" "bundle --version identifies GitSetu"
}

bundle_help_works() {
    local output rc=0
    output=$(cd "$BUNDLE_RUN_DIR" && bash "$BUNDLE_COPY" --help 2>&1) || rc=$?
    assert_equals "0" "$rc" "bundle --help exits successfully"
    assert_contains "$output" "USAGE" "bundle --help renders usage"
}

bundle_status_works_without_source_tree() {
    local output rc=0
    output=$(cd "$BUNDLE_RUN_DIR" && bash "$BUNDLE_COPY" status 2>&1) || rc=$?
    assert_equals "0" "$rc" "bundle status exits successfully without a configured profile"
    assert_contains "$output" "profiles configured" "bundle status reports the unconfigured state"
}

bundle_verify_fails_closed_without_profiles() {
    local output rc=0
    output=$(cd "$BUNDLE_RUN_DIR" && bash "$BUNDLE_COPY" verify 2>&1) || rc=$?
    assert_equals "1" "$rc" "bundle verify fails closed with no configured profile"
    assert_contains "$output" "profiles configured" "bundle verify explains the missing configuration"
}

run_test "copy exact supplied bundle" copy_exact_artifact
run_test "bundle --version" bundle_version_works
run_test "bundle --help" bundle_help_works
run_test "bundle status in isolation" bundle_status_works_without_source_tree
run_test "bundle verify fails closed when unconfigured" bundle_verify_fails_closed_without_profiles
print_results "Bundle contract tests"
