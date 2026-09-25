#!/usr/bin/env bash
# tests/test_sandbox_contract.sh — Static honesty/provenance contracts for Sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/sandbox/README.md"
LAUNCHER="$ROOT/sandbox/launch_sandbox.ps1"
BOOTSTRAP="$ROOT/sandbox/bootstrap.ps1"
AUDIT="$ROOT/sandbox/comprehensive_audit.sh"

assert_file_contains() {
    local file="$1" needle="$2" message="$3"
    if ! grep -Fq -- "$needle" "$file"; then
        printf '    FAIL: %s\n' "$message" >&2
        return 1
    fi
}

assert_file_not_contains() {
    local file="$1" needle="$2" message="$3"
    if grep -Fq -- "$needle" "$file"; then
        printf '    FAIL: %s\n' "$message" >&2
        return 1
    fi
}

printf '\n%btest_sandbox_contract.sh%b\n' "${T_BOLD:-}" "${T_RESET:-}"
assert_file_contains "$README" "legacy/experimental" "Sandbox documentation is explicitly legacy/experimental"
assert_file_contains "$README" "not a release qualification gate" "Sandbox documentation denies release-gate status"
assert_file_not_contains "$AUDIT" "PRODUCTION-READY" "legacy audit never emits a production-ready verdict"
assert_file_contains "$LAUNCHER" "runId" "Sandbox launcher creates a run-scoped result"
assert_file_contains "$LAUNCHER" "source_commit=" "Sandbox launcher records source provenance"
assert_file_contains "$LAUNCHER" "source_dirty=" "Sandbox launcher records source cleanliness"
assert_file_contains "$LAUNCHER" "networking=\$networkingMode" "Sandbox launcher records network policy"
assert_file_contains "$LAUNCHER" "Get-FileHash" "Sandbox launcher records the generated WSB digest"
assert_file_contains "$LAUNCHER" "Get-Command git.exe" "Sandbox launcher resolves Git from PATH"
assert_file_contains "$LAUNCHER" "GitInstallPath" "Sandbox launcher accepts an explicit Git installation path"
assert_file_contains "$BOOTSTRAP" "COMPLETED_INCONCLUSIVE" "Sandbox bootstrap has an inconclusive terminal state"
assert_file_contains "$AUDIT" "GITSETU_TEST_VAULT_MODE" "Sandbox audit uses the current vault test contract"
assert_file_not_contains "$AUDIT" "GITSETU_REPO_URL" "Sandbox audit does not use the obsolete repository URL switch"
assert_file_not_contains "$AUDIT" "GITSETU_TEST=true" "Sandbox audit does not use the obsolete installer test switch"
assert_file_not_contains "$AUDIT" "gitsetu/share" "Sandbox audit does not assert the obsolete share layout"
assert_file_not_contains "$AUDIT" "gitsetu_vault_pre_restore_" "Sandbox audit does not expect obsolete restore sidecars"
assert_file_contains "$AUDIT" "WARNED_TESTS" "Sandbox audit counts warnings explicitly"
assert_file_contains "$AUDIT" "exit 2" "Sandbox warnings produce an inconclusive result"
assert_file_contains "$AUDIT" "GITSETU_CREDENTIAL_BACKEND=file" "Sandbox credential test selects the explicit file backend"
assert_file_not_contains "$AUDIT" "pat_token_secret_123" "Sandbox audit does not embed a reusable secret literal"

printf 'Sandbox contract tests: PASS\n'
