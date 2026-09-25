#!/usr/bin/env bash
# shellcheck disable=SC2329  # Test overrides are invoked indirectly by sourced functions.
# tests/test_registry_boundaries.sh — Strict v2 schema, identity, and writer boundaries.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

seed_profile_pair() {
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$HOME/.ssh/id_ed25519_global" ""
        test_v2_registry_line work "$HOME/work" "github.com" "0" "$HOME/.ssh/id_ed25519_work" ""
    } > "$GITSETU_PROFILES_CONF"
}

test_registry_rejects_oversized_encoded_field() {
    setup_test_home
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs
    local oversized_encoded="" i
    for ((i = 0; i < 4097; i++)); do oversized_encoded+="%41"; done
    local line
    line=$(printf '%s::%s:0::' "$oversized_encoded" "$oversized_encoded")
    if validate_registry_line "$line"; then
        printf 'oversized registry field was accepted\n' >&2
        return 1
    fi
}

test_registry_rejects_duplicate_labels() {
    setup_test_home
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs
    seed_profile_pair
    local duplicate
    duplicate=$(test_v2_registry_line work "$HOME/other" "github.com" "0" "$HOME/.ssh/id_ed25519_work" "")
    printf '%s\n' "$duplicate" >> "$GITSETU_PROFILES_CONF"
    if load_profiles >/dev/null 2>&1; then
        printf 'duplicate profile label was accepted\n' >&2
        return 1
    fi
}

test_registry_requires_global_first() {
    setup_test_home
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs
    seed_profile_pair
    {
        test_v2_registry_header
        tail -n 1 "$GITSETU_PROFILES_CONF"
        head -n 2 "$GITSETU_PROFILES_CONF" | tail -n 1
    } > "$GITSETU_PROFILES_CONF.reordered"
    mv "$GITSETU_PROFILES_CONF.reordered" "$GITSETU_PROFILES_CONF"
    if load_profiles >/dev/null 2>&1; then
        printf 'registry without global-first ordering was accepted\n' >&2
        return 1
    fi
}

test_registry_rejects_missing_profile_identity() {
    setup_test_home
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs
    seed_profile_pair
    printf '[user]\n    name = Broken User\n' > "$GITSETU_PROFILES_DIR/work.gitconfig"
    if load_profiles >/dev/null 2>&1; then
        printf 'profile with missing email was accepted\n' >&2
        return 1
    fi
}

test_registry_writer_failure_preserves_previous_file() {
    setup_test_home
    _TEST_GITSETU_LIBS_READY=0
    source_gitsetu_libs
    seed_profile_pair
    local before
    before=$(sha256sum "$GITSETU_PROFILES_CONF" | awk '{print $1}')
    local output status=0
    output=$(
        mv() { return 1; }
        write_profiles_conf 2>&1
    ) || status=$?
    if [[ "$status" -eq 0 ]]; then
        printf 'writer reported success despite atomic replacement failure\n' >&2
        return 1
    fi
    local after
    after=$(sha256sum "$GITSETU_PROFILES_CONF" | awk '{print $1}')
    assert_equals "$before" "$after" "failed writer preserved the previous registry"
}

printf '\n%btest_registry_boundaries.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "oversized encoded field rejected" test_registry_rejects_oversized_encoded_field
run_test "duplicate labels rejected" test_registry_rejects_duplicate_labels
run_test "global-first ordering required" test_registry_requires_global_first
run_test "missing profile identity rejected" test_registry_rejects_missing_profile_identity
run_test "writer failure preserves registry" test_registry_writer_failure_preserves_previous_file
print_results "Registry boundary tests"
