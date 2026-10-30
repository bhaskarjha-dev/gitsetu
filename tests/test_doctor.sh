#!/usr/bin/env bash
# tests/test_doctor.sh — Tests for the diagnostic doctor tool
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

source_gitsetu_libs

test_doctor_detects_missing_registry() {
    # Delete registry
    rm -f "$GITSETU_PROFILES_CONF"
    
    local output
    output=$(run_doctor 2>&1 || true)
    
    assert_contains "$output" "ERROR: Registry missing" "detects missing registry" || return 1
}

test_doctor_detects_missing_ssh_agent() {
    # Unset SSH_AUTH_SOCK
    local old_sock="${SSH_AUTH_SOCK:-}"
    unset SSH_AUTH_SOCK
    
    local output
    output=$(run_doctor 2>&1 || true)
    
    assert_contains "$output" "WARNING: SSH_AUTH_SOCK is not set" "detects missing ssh agent" || return 1
    
    # Restore
    if [[ -n "$old_sock" ]]; then
        export SSH_AUTH_SOCK="$old_sock"
    fi
}

test_doctor_detects_missing_managed_blocks() {
    # Delete gitconfig
    rm -f "$HOME/.gitconfig" "$HOME/.ssh/config"
    
    local output
    output=$(run_doctor 2>&1 || true)
    
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.gitconfig: " "checks gitconfig" || return 1
    assert_contains "$output" "ERROR: Registry missing" "detects missing required registry" || return 1
    assert_contains "$output" "~/.gitconfig: ERROR" "detects missing gitconfig state" || return 1
    assert_contains "$output" "gitsetu doctor --repair" "suggests repair when issues found" || return 1
}

test_doctor_success_state() {
    # Build a genuinely healthy strict-v2 state. An empty registry is not a
    # healthy fixture: required identity/key checks must remain strict.
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519_global"
    test_v2_profile_config global "Global User" "global@example.com"
    local global_key
    global_key=$(normalize_path "$HOME/.ssh/id_ed25519_global")
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$global_key" ""
    } > "$GITSETU_PROFILES_CONF"
    load_profiles || return 1
    write_global_gitconfig >/dev/null 2>&1 || return 1
    write_ssh_config >/dev/null 2>&1 || return 1

    local output
    output=$(run_doctor 2>&1 || true)

    assert_contains "$output" "Registry: OK" "registry ok" || return 1
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.gitconfig: OK" "gitconfig ok" || return 1
    # shellcheck disable=SC2088
    assert_contains "$output" "~/.ssh/config: OK" "ssh config ok" || return 1
    assert_contains "$output" "All required offline diagnostics passed" "healthy diagnostics report success" || return 1
    assert_not_contains "$output" "gitsetu doctor --repair" "does not suggest repair when clean" || return 1
}

test_doctor_environment_checks() {
    local clip git_v ossl kh
    clip=$(doctor_check_clipboard)
    [[ -n "$clip" ]] || {
        printf '    FAIL: doctor_check_clipboard returned empty\n'
        return 1
    }

    git_v=$(doctor_check_git_version)
    assert_contains "$git_v" "git version" "doctor_check_git_version finds git" || return 1

    ossl=$(doctor_check_openssl)
    [[ -n "$ossl" ]] || {
        printf '    FAIL: doctor_check_openssl returned empty\n'
        return 1
    }

    # known_hosts in empty TEST_HOME
    rm -rf "$HOME/.ssh"
    kh=$(doctor_check_known_hosts 2>&1 || true)
    assert_equals "missing" "$kh" "doctor_check_known_hosts detects missing known_hosts" || return 1

    mkdir -p "$HOME/.ssh"
    printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI mock\n' > "$HOME/.ssh/known_hosts"
    kh=$(doctor_check_known_hosts)
    assert_contains "$kh" "github.com" "doctor_check_known_hosts detects github.com" || return 1
}

test_doctor_json_output() {
    # Test healthy state
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig"
    mkdir -p "$GITSETU_PROFILES_DIR" "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519_global"
    test_v2_profile_config global "Global User" "global@example.com"
    local global_key
    global_key=$(normalize_path "$HOME/.ssh/id_ed25519_global")
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$global_key" ""
    } > "$GITSETU_PROFILES_CONF"
    load_profiles || return 1
    write_global_gitconfig >/dev/null 2>&1 || return 1
    write_ssh_config >/dev/null 2>&1 || return 1

    local output rc=0
    output=$(run_doctor_json) || rc=$?
    assert_equals "0" "$rc" "run_doctor_json exits 0 for clean state" || return 1
    assert_contains "$output" '"status": "healthy"' "json reports healthy status" || return 1
    assert_contains "$output" '"issues_found": 0' "json reports issues_found 0" || return 1
    assert_contains "$output" '"issuesFound": 0' "json reports 0 issues" || return 1
    assert_contains "$output" '"checks": [' "json reports checks array" || return 1
    assert_contains "$output" '"name": "git_version"' "json contains git_version check" || return 1
    assert_contains "$output" '"name": "profiles_registry"' "json contains profiles_registry check" || return 1

    # Test unhealthy state
    rm -f "$GITSETU_PROFILES_CONF"
    rc=0
    output=$(run_doctor_json) || rc=$?
    assert_equals "1" "$rc" "run_doctor_json exits 1 for missing registry" || return 1
    assert_contains "$output" '"status": "unhealthy"' "json reports unhealthy status" || return 1
    assert_contains "$output" '"issues_found":' "json reports issues_found count" || return 1
    assert_contains "$output" '"issuesFound":' "json reports issues count" || return 1
}

test_cmd_import_ignores_gitsetu_managed_blocks() {
    cat <<'EOF' > "$HOME/.gitconfig"
# [gitsetu:managed:start]
# Generated by gitsetu v1.1.0; managed routes
[includeIf "gitdir:~/work/**"]
    path = ~/.config/gitsetu/profiles/work.gitconfig
# [gitsetu:managed:end]
EOF
    local output
    output=$(cmd_import --yes 2>&1 || true)
    assert_not_contains "$output" "Discovered unmanaged identity route" || return 1
}

test_cmd_import_supports_case_insensitive_and_sanitizes_labels() {
    cat <<'EOF' > "$HOME/.gitconfig"
[includeIf "gitdir/i:~/my_client_repos/"]
    path = ~/.gitconfig-client
EOF
    cat <<'EOF' > "$HOME/.gitconfig-client"
[user]
    name = Client Dev
    email = dev@client.com
EOF

    local output
    output=$(cmd_import --yes 2>&1 || true)
    assert_contains "$output" "Discovered unmanaged identity route" "detects gitdir/i: unmanaged route" || return 1
    assert_contains "$output" "Successfully imported" "successfully imported sanitized profile" || return 1
}

test_doctor_json_cli_corrupted_registry() {
    local gitsetu_exe
    gitsetu_exe="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gitsetu"
    gitsetu_exe="${gitsetu_exe%$'\r'}"

    # Corrupt profiles.conf
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    printf 'corrupted-unversioned-garbage\n' > "$GITSETU_PROFILES_CONF"

    local output rc=0
    output=$(bash "$gitsetu_exe" doctor --json 2>&1) || rc=$?
    assert_equals "1" "$rc" "doctor --json exits 1 on corrupted registry" || return 1
    assert_contains "$output" '"status": "unhealthy"' "doctor --json outputs valid JSON unhealthy status on corrupted registry" || return 1
    assert_contains "$output" '"issues_found":' "doctor --json contains issues_found count on corrupted registry" || return 1
    assert_contains "$output" '"schema_version": "1.0.0"' "doctor --json outputs valid schema_version on corrupted registry" || return 1
}

test_cmd_import_requires_confirmation_without_yes() {
    cat <<'EOF' > "$HOME/.gitconfig"
[includeIf "gitdir:~/other_client/"]
    path = ~/.gitconfig-other
EOF
    cat <<'EOF' > "$HOME/.gitconfig-other"
[user]
    name = Other Client
    email = other@example.com
EOF

    local output rc=0
    output=$(cmd_import 2>&1) || rc=$?
    assert_equals "3" "$rc" "import requires confirmation in non-interactive mode and exits 3" || return 1
    assert_contains "$output" "Confirmation required" "output gives confirmation warning" || return 1
}

test_doctor_warns_on_migrated_v1_registry() {
    # Set up a v1.0.0 registry fixture
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")" "$GITSETU_PROFILES_DIR" "$HOME/.ssh" "$HOME/work"
    touch "$HOME/.ssh/id_ed25519_work"
    git config --global user.name "Pat Example"
    git config --global user.email "pat.personal@example.com"
    git config -f "$GITSETU_PROFILES_DIR/work.gitconfig" user.name "Pat Example"
    git config -f "$GITSETU_PROFILES_DIR/work.gitconfig" user.email "pat.work@example.com"
    cat <<EOF > "$GITSETU_PROFILES_CONF"
# gitsetu profile registry — generated on 2026-01-01
work:pat.work@example.com:${HOME}/work:github.com:0:${HOME}/.ssh/id_ed25519_work:legacy_user
EOF
    cat <<EOF > "$HOME/.gitconfig"
# [gitsetu:managed:head:start]
# Generated by gitsetu
# [gitsetu:managed:head:end]
# [gitsetu:managed:start]
# Generated by gitsetu
# [gitsetu:managed:end]
EOF
    load_profiles || return 1
    assert_equals "1" "${GITSETU_REGISTRY_WAS_V1:-0}" "registry detected as v1" || return 1

    local output rc=0
    output=$(run_doctor 2>&1) || rc=$?
    assert_contains "$output" "Registry was migrated from v1.0 format in memory" "doctor warns about v1 format" || return 1
    assert_not_contains "$output" "Registry header is missing or unsupported" "doctor does not report unsupported header error" || return 1
}

test_doctor_repair_cleans_legacy_hookspath() {
    cat <<EOF > "$HOME/.gitconfig"
[user]
    name = Test User
    email = test@example.com
# [gitsetu:managed:head:start]
# [gitsetu:managed:head:end]
# [gitsetu:managed:start]
# [gitsetu:managed:end]
EOF
    mkdir -p "$GITSETU_HOOKS_DIR"
    git config --global core.hooksPath "$GITSETU_HOOKS_DIR"
    assert_equals "$GITSETU_HOOKS_DIR" "$(git config --global core.hooksPath 2>/dev/null || true)" "global hooksPath set" || return 1

    run_doctor_repair >/dev/null 2>&1 || true
    local remaining
    remaining=$(git config --global core.hooksPath 2>/dev/null || true)
    assert_equals "" "$remaining" "doctor repair removed legacy global core.hooksPath" || return 1
}

printf '\n%btest_doctor.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "doctor detects missing registry" test_doctor_detects_missing_registry
run_test "doctor detects missing ssh agent" test_doctor_detects_missing_ssh_agent
run_test "doctor detects missing managed blocks" test_doctor_detects_missing_managed_blocks
run_test "doctor reports OK for clean state" test_doctor_success_state
run_test "doctor environment checks report tool details" test_doctor_environment_checks
run_test "doctor --json outputs structured telemetry" test_doctor_json_output
run_test "import ignores GitSetu managed includeIf blocks" test_cmd_import_ignores_gitsetu_managed_blocks
run_test "doctor import supports gitdir/i: and sanitizes labels" test_cmd_import_supports_case_insensitive_and_sanitizes_labels
run_test "doctor import requires confirmation without --yes" test_cmd_import_requires_confirmation_without_yes
run_test "doctor warns on migrated v1 registry" test_doctor_warns_on_migrated_v1_registry
run_test "doctor repair cleans legacy global hookspath" test_doctor_repair_cleans_legacy_hookspath
run_test "doctor --json CLI produces parseable JSON on corrupted registry" test_doctor_json_cli_corrupted_registry
print_results "Doctor tests"
