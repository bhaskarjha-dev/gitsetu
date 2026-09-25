#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked functions invoked dynamically or via subshells
# tests/test_ssh_automation.sh — SSH Automation & Key Management Suite
# Verifies Phase 2 SSH Automation (Tasks T2.1, T2.2, T2.3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

# ------------------------------------------------------------------------------
# Test 1: auto_register_ssh_keys with missing SSH_AUTH_SOCK skips gracefully
# ------------------------------------------------------------------------------
test_auto_register_no_agent() {
    local saved_sock="${SSH_AUTH_SOCK:-}"
    unset SSH_AUTH_SOCK

    local output
    output=$(auto_register_ssh_keys 2>&1)
    local rc=$?

    if [[ -n "$saved_sock" ]]; then
        export SSH_AUTH_SOCK="$saved_sock"
    fi

    assert_equals "0" "$rc" "exits 0 when SSH_AUTH_SOCK is unset" || return 1
    assert_contains "$output" "SSH agent not running" "prints agent not running info" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: auto_register_ssh_keys with dead socket emits non-fatal warning
# ------------------------------------------------------------------------------
test_auto_register_dead_socket() {
    export SSH_AUTH_SOCK="/tmp/nonexistent_mock_sock"

    local output
    output=$(
        ssh-add() {
            return 2
        }
        auto_register_ssh_keys 2>&1
    )
    local rc=$?
    unset SSH_AUTH_SOCK

    assert_equals "0" "$rc" "exits 0 on dead socket (non-fatal)" || return 1
    assert_contains "$output" "SSH agent socket not responding" "prints socket dead warning" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: auto_register_ssh_keys key already in agent is deduplicated
# ------------------------------------------------------------------------------
test_auto_register_key_already_loaded() {
    export SSH_AUTH_SOCK="/tmp/mock_sock"

    local dummy_key="$TEST_HOME/.ssh/id_ed25519_test"
    mkdir -p "$TEST_HOME/.ssh"
    ssh-keygen -t ed25519 -C "test@example.com" -f "$dummy_key" -N "" -q

    local fp
    fp=$(ssh-keygen -lf "$dummy_key" | awk '{print $2}')

    local output
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then
                echo "256 $fp test@example.com (ED25519)"
                return 0
            fi
            echo "ssh-add invoked unexpectedly"
            return 1
        }
        auto_register_ssh_keys "$dummy_key" 2>&1
    )
    unset SSH_AUTH_SOCK

    assert_contains "$output" "Key already loaded in SSH agent" "detects already loaded key" || return 1
    assert_not_contains "$output" "ssh-add invoked unexpectedly" "skips invoking ssh-add" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: auto_register_ssh_keys registers unloaded key successfully
# ------------------------------------------------------------------------------
test_auto_register_registers_unloaded_key() {
    export SSH_AUTH_SOCK="/tmp/mock_sock"

    local dummy_key="$TEST_HOME/.ssh/id_ed25519_work"
    mkdir -p "$TEST_HOME/.ssh"
    ssh-keygen -t ed25519 -C "work@corp.com" -f "$dummy_key" -N "" -q

    local output
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then
                return 1 # no identities currently
            fi
            echo "Identity added: $1"
            return 0
        }
        auto_register_ssh_keys "$dummy_key" 2>&1
    )
    unset SSH_AUTH_SOCK

    assert_contains "$output" "Registered with SSH agent" "successfully registers key" || return 1
    assert_contains "$output" "Registered 1 key(s) with SSH agent" "summary count matches" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: auto_register_ssh_keys handles failed registration non-fatally
# ------------------------------------------------------------------------------
test_auto_register_handles_add_failure() {
    export SSH_AUTH_SOCK="/tmp/mock_sock"

    local dummy_key="$TEST_HOME/.ssh/id_ed25519_fail"
    mkdir -p "$TEST_HOME/.ssh"
    ssh-keygen -t ed25519 -C "fail@example.com" -f "$dummy_key" -N "" -q

    local output
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then
                return 1
            fi
            return 1 # simulate ssh-add failure
        }
        auto_register_ssh_keys "$dummy_key" 2>&1
    )
    unset SSH_AUTH_SOCK

    assert_contains "$output" "Could not auto-register" "emits non-fatal warning on add failure" || return 1
    assert_contains "$output" "To add manually: ssh-add" "prints manual fallback instructions" || return 1
}

# ------------------------------------------------------------------------------
# Test 6: auto_register_ssh_keys discovers keys from PROFILE_KEYS array
# ------------------------------------------------------------------------------
test_auto_register_from_profile_keys() {
    export SSH_AUTH_SOCK="/tmp/mock_sock"

    local k1="$TEST_HOME/.ssh/id_ed25519_p1"
    local k2="$TEST_HOME/.ssh/id_ed25519_p2"
    mkdir -p "$TEST_HOME/.ssh"
    ssh-keygen -t ed25519 -C "p1@test.com" -f "$k1" -N "" -q
    ssh-keygen -t ed25519 -C "p2@test.com" -f "$k2" -N "" -q

    PROFILE_COUNT=2
    PROFILE_LABELS[0]="p1"
    PROFILE_KEYS[0]="$k1"
    PROFILE_LABELS[1]="p2"
    PROFILE_KEYS[1]="$k2"

    local output
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then
                return 1
            fi
            return 0
        }
        auto_register_ssh_keys 2>&1
    )
    unset SSH_AUTH_SOCK

    assert_contains "$output" "Registered 2 key(s) with SSH agent" "auto-registers all profile keys" || return 1
}

# ------------------------------------------------------------------------------
# Test 7: try_gh_key_upload returns 1 if gh binary is not installed
# ------------------------------------------------------------------------------
test_try_gh_missing_binary() {
    local dummy_pub="$TEST_HOME/dummy.pub"
    touch "$dummy_pub"

    local output rc=0
    output=$(
        export PATH="/dev/null"
        try_gh_key_upload "work" "$dummy_pub" 2>&1
    ) || rc=$?

    assert_equals "1" "$rc" "returns 1 when gh is missing" || return 1
}

# ------------------------------------------------------------------------------
# Test 8: try_gh_key_upload returns 1 if public key file is missing
# ------------------------------------------------------------------------------
test_try_gh_missing_pubkey() {
    local rc=0
    try_gh_key_upload "work" "$TEST_HOME/nonexistent.pub" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "returns 1 when pubkey file does not exist" || return 1
}

# ------------------------------------------------------------------------------
# Test 9: try_gh_key_upload returns 1 if gh is not authenticated
# ------------------------------------------------------------------------------
test_try_gh_unauthenticated() {
    local dummy_pub="$TEST_HOME/dummy.pub"
    touch "$dummy_pub"

    local rc=0
    (
        gh() {
            if [[ "$1" == "api" ]]; then
                return 1
            fi
            return 0
        }
        GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "work" "$dummy_pub"
    ) || rc=$?

    assert_equals "1" "$rc" "returns 1 when gh api user returns empty" || return 1
}

# ------------------------------------------------------------------------------
# Test 10: try_gh_key_upload returns 1 when user declines upload prompt
# ------------------------------------------------------------------------------
test_try_gh_user_declines() {
    local dummy_pub="$TEST_HOME/dummy.pub"
    touch "$dummy_pub"

    local rc=0
    (
        gh() {
            if [[ "$1" == "api" ]]; then
                echo "octocat"
                return 0
            fi
            return 0
        }
        GITSETU_TEST_GH_MOCK=1 GITSETU_TEST_DECLINE=1 try_gh_key_upload "work" "$dummy_pub"
    ) || rc=$?

    assert_equals "1" "$rc" "returns 1 when user declines prompt" || return 1
}

# ------------------------------------------------------------------------------
# Test 11: try_gh_key_upload returns 0 when key is already registered on GitHub
# ------------------------------------------------------------------------------
test_try_gh_key_already_registered() {
    local dummy_pub="$TEST_HOME/dummy.pub"
    touch "$dummy_pub"

    local output rc=0
    output=$(
        gh() {
            if [[ "$1" == "api" ]]; then
                echo "octocat"
                return 0
            fi
            if [[ "$1" == "ssh-key" && "$2" == "add" ]]; then
                echo "HTTP 422: Key is already in use (key_already_exists)" >&2
                return 1
            fi
            return 0
        }
        GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "work" "$dummy_pub" 2>&1
    ) || rc=$?

    assert_equals "0" "$rc" "returns 0 when key already in use" || return 1
    assert_contains "$output" "Key already registered on GitHub." "prints already registered info" || return 1
}

# ------------------------------------------------------------------------------
# Test 12: try_gh_key_upload succeeds when gh ssh-key add succeeds
# ------------------------------------------------------------------------------
test_try_gh_upload_success() {
    local dummy_pub="$TEST_HOME/dummy.pub"
    touch "$dummy_pub"

    local output rc=0
    output=$(
        gh() {
            if [[ "$1" == "api" ]]; then
                echo "octocat"
                return 0
            fi
            if [[ "$1" == "ssh-key" && "$2" == "add" ]]; then
                return 0
            fi
            return 0
        }
        GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "work" "$dummy_pub" 2>&1
    ) || rc=$?

    assert_equals "0" "$rc" "returns 0 on successful key upload" || return 1
    assert_contains "$output" "Key successfully added to GitHub!" "prints success message" || return 1
}

# ------------------------------------------------------------------------------
# Test 13: verify_ssh_handshake port 22 success returns 0
# ------------------------------------------------------------------------------
test_verify_handshake_port22_success() {
    local dummy_key="$TEST_HOME/id_ed25519_test"
    touch "$dummy_key"

    local output rc=0
    output=$(
        ssh() {
            echo "Hi octocat! You've successfully authenticated, but GitHub does not provide shell access."
            return 1
        }
        GITSETU_TEST_SSH_VERIFY=1 verify_ssh_handshake "$dummy_key" "github.com" 2>&1
    ) || rc=$?

    assert_equals "0" "$rc" "returns 0 when port 22 handshake succeeds" || return 1
    assert_contains "$output" "SSH connection verified: github.com (port 22;" "prints port 22 verified" || return 1
}

# ------------------------------------------------------------------------------
# Test 14: verify_ssh_handshake corporate fallback to Port 443 on GitHub
# ------------------------------------------------------------------------------
test_verify_handshake_port443_fallback() {
    local dummy_key="$TEST_HOME/id_ed25519_corp"
    touch "$dummy_key"

    local output rc=0
    output=$(
        ssh() {
            # If port 443 flag (-p 443) is passed
            local is_443=0
            local arg
            for arg in "$@"; do
                if [[ "$arg" == "443" ]]; then
                    is_443=1
                    break
                fi
            done
            if [[ "$is_443" -eq 1 ]]; then
                echo "Hi octocat! You've successfully authenticated, but GitHub does not provide shell access."
                return 1
            fi
            # Standard port 22 timed out
            echo "ssh: connect to host github.com port 22: Connection timed out" >&2
            return 255
        }
        GITSETU_TEST_SSH_VERIFY=1 GITSETU_ALLOW_SSH_PORT443=1 \
            verify_ssh_handshake "$dummy_key" "github.com" 2>&1
    ) || rc=$?

    assert_equals "0" "$rc" "returns 0 when explicitly opted-in port 443 succeeds" || return 1
    assert_contains "$output" "explicit port 443 opt-in" "verifies explicit port 443 message" || return 1
}

# ------------------------------------------------------------------------------
# Test 15: build_ssh_host_block standard configuration (no Port 443)
# ------------------------------------------------------------------------------
test_build_ssh_host_block_standard() {
    GITSETU_PORT443_NEEDED=0
    local block
    block=$(build_ssh_host_block "work" "github.com" "$HOME/.ssh/id_ed25519_work")

    assert_contains "$block" "Host github-work" "alias format correct" || return 1
    assert_contains "$block" "HostName github.com" "standard hostname emitted" || return 1
    assert_not_contains "$block" "Port 443" "port 443 omitted on standard config" || return 1
    assert_not_contains "$block" "ssh.github.com" "ssh.github.com omitted on standard config" || return 1
}

# ------------------------------------------------------------------------------
# Test 16: build_ssh_host_block corporate Port 443 configuration for GitHub
# ------------------------------------------------------------------------------
test_build_ssh_host_block_port443_github() {
    GITSETU_PORT443_NEEDED=1
    local block
    block=$(build_ssh_host_block "corp" "github.com" "$HOME/.ssh/id_ed25519_corp")
    GITSETU_PORT443_NEEDED=0

    assert_contains "$block" "Host github-corp" "alias format correct" || return 1
    assert_contains "$block" "HostName ssh.github.com" "corporate fallback hostname emitted" || return 1
    assert_contains "$block" "Port 443" "corporate fallback port 443 emitted" || return 1
}

# ------------------------------------------------------------------------------
# Test 17: build_ssh_host_block Port 443 is ignored for non-GitHub providers
# ------------------------------------------------------------------------------
test_build_ssh_host_block_port443_ignored_gitlab() {
    GITSETU_PORT443_NEEDED=1
    local block
    block=$(build_ssh_host_block "corp" "gitlab.com" "$HOME/.ssh/id_ed25519_corp")
    GITSETU_PORT443_NEEDED=0

    assert_contains "$block" "Host gitlab-corp" "alias format correct" || return 1
    assert_contains "$block" "HostName gitlab.com" "gitlab hostname preserved" || return 1
    assert_not_contains "$block" "Port 443" "port 443 omitted for non-GitHub" || return 1
    assert_not_contains "$block" "ssh.github.com" "ssh.github.com omitted for non-GitHub" || return 1
}

# ------------------------------------------------------------------------------
# Test 18: auto_register_ssh_keys in dry-run mode skips ssh-add
# ------------------------------------------------------------------------------
test_auto_register_dry_run_skips_ssh_add() {
    export SSH_AUTH_SOCK="/tmp/mock_sock"
    export GITSETU_DRY_RUN=1

    local dummy_key="$TEST_HOME/.ssh/id_ed25519_dryrun"
    mkdir -p "$TEST_HOME/.ssh"
    ssh-keygen -t ed25519 -C "dry@corp.com" -f "$dummy_key" -N "" -q

    local output
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then
                return 1 # no identities currently
            fi
            echo "ERROR: ssh-add should not be called in dry run"
            return 1
        }
        auto_register_ssh_keys "$dummy_key" 2>&1
    )
    unset SSH_AUTH_SOCK
    unset GITSETU_DRY_RUN

    assert_contains "$output" "[DRY RUN] Would register with SSH agent: $dummy_key" "emits dry run action" || return 1
    assert_not_contains "$output" "ERROR: ssh-add should not be called" "does not invoke ssh-add" || return 1
}

# ------------------------------------------------------------------------------
# Test 19: try_gh_key_upload in dry-run mode skips upload
# ------------------------------------------------------------------------------
test_try_gh_dry_run_skips_upload() {
    export GITSETU_DRY_RUN=1

    local dummy_pub="$TEST_HOME/.ssh/id_ed25519_work.pub"
    mkdir -p "$TEST_HOME/.ssh"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... work@corp.com" > "$dummy_pub"

    local output rc=0
    local gh_called="$TEST_HOME/gh-called"
    : > "$gh_called"
    output=$(
        gh() {
            printf 'called:%s\n' "$*" >> "$gh_called"
            echo "ERROR: gh should not be called in dry run"
            return 1
        }
        GITSETU_TEST_GH_MOCK=1 try_gh_key_upload "work" "$dummy_pub" 2>&1
    ) || rc=$?
    unset GITSETU_DRY_RUN

    assert_equals "0" "$rc" "dry run returns 0" || return 1
    assert_contains "$output" "[DRY RUN] Would upload 'work' key to GitHub (account lookup and upload skipped)" "emits dry run action" || return 1
    assert_not_contains "$output" "ERROR: gh should not be called in dry run" "does not invoke gh" || return 1
    assert_not_contains "$(cat "$gh_called")" "called:" "does not query GitHub during dry run" || return 1
}

# ------------------------------------------------------------------------------
# Registry scope tests for automatic key discovery
# ------------------------------------------------------------------------------
test_auto_register_invalid_registry_never_scans_ssh_dir() {
    unset SSH_AUTH_SOCK
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    printf '# unsupported registry\nwork::%s\n' "$HOME" > "$GITSETU_PROFILES_CONF"
    local broad_key="$HOME/.ssh/id_ed25519_broad"
    touch "$broad_key"
    PROFILE_COUNT=0

    local output rc=0 add_log="$TEST_HOME/unexpected-ssh-add"
    : > "$add_log"
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then return 1; fi
            printf 'add %s\n' "$*" >> "$add_log"
            return 0
        }
        auto_register_ssh_keys 2>&1
    ) || rc=$?
    unset SSH_AUTH_SOCK

    assert_equals "2" "$rc" "invalid v2 registry fails closed" || return 1
    assert_contains "$output" "existing v2 profile registry is invalid" "error identifies invalid registry" || return 1
    assert_not_contains "$output" "$broad_key" "malformed state does not widen to ~/.ssh" || return 1
    assert_equals "0" "$(wc -c < "$add_log" | tr -d ' ')" "no broad key is registered" || return 1
}

test_auto_register_unconfigured_discovery_requires_no_registry() {
    export SSH_AUTH_SOCK="$TEST_HOME/mock-agent-discover.sock"
    rm -f "$GITSETU_PROFILES_CONF"
    local discovered="$HOME/.ssh/id_ed25519_discovered"
    ssh-keygen -t ed25519 -C discovered@example.com -f "$discovered" -N "" -q
    PROFILE_COUNT=0

    local output
    output=$(
        ssh-add() {
            if [[ "${1:-}" == "-l" ]]; then return 1; fi
            return 0
        }
        auto_register_ssh_keys 2>&1
    )
    unset SSH_AUTH_SOCK

    assert_contains "$output" "Registered with SSH agent: $discovered" "no-registry discovery remains supported" || return 1
}

# ------------------------------------------------------------------------------
# Tests 20-22: explicit port/trust policy and dry-run no-network behavior
# ------------------------------------------------------------------------------
test_verify_handshake_refuses_implicit_port443_and_host_trust() {
    local dummy_key="$TEST_HOME/id_ed25519_policy"
    local calls="$TEST_HOME/ssh-policy.calls"
    : > "$calls"
    touch "$dummy_key"
    unset GITSETU_ALLOW_SSH_PORT443 GITSETU_ALLOW_SSH_HOST_KEY

    local output rc=0
    output=$(
        ssh() {
            printf '%s\n' "$*" >> "$calls"
            return 255
        }
        GITSETU_TEST_SSH_VERIFY=1 verify_ssh_handshake "$dummy_key" "github.com" 2>&1
    ) || rc=$?

    assert_equals "1" "$rc" "default failed verification returns nonzero" || return 1
    assert_equals "1" "$(wc -l < "$calls" | tr -d ' ')" "port 443 is not attempted without consent" || return 1
    assert_contains "$(cat "$calls")" "StrictHostKeyChecking=yes" "unknown host keys are refused by default" || return 1
    assert_contains "$(cat "$calls")" "UpdateHostkeys=no" "known_hosts updates are disabled" || return 1
    assert_not_contains "$(cat "$calls")" "accept-new" "first-use trust is never implicit" || return 1
    assert_contains "$output" "GITSETU_ALLOW_SSH_PORT443=1" "port consent is discoverable" || return 1
}

test_verify_handshake_explicit_host_key_consent() {
    local dummy_key="$TEST_HOME/id_ed25519_trust"
    local calls="$TEST_HOME/ssh-trust.calls"
    : > "$calls"
    touch "$dummy_key"

    local output rc=0
    output=$(
        ssh() {
            printf '%s\n' "$*" > "$calls"
            echo "successfully authenticated"
            return 1
        }
        GITSETU_TEST_SSH_VERIFY=1 GITSETU_ALLOW_SSH_HOST_KEY=1 \
            verify_ssh_handshake "$dummy_key" "github.com" 2>&1
    ) || rc=$?
    unset GITSETU_ALLOW_SSH_HOST_KEY

    assert_equals "0" "$rc" "explicit host trust opt-in succeeds" || return 1
    assert_contains "$(cat "$calls")" "StrictHostKeyChecking=accept-new" "explicit consent enables first-use trust" || return 1
    assert_contains "$(cat "$calls")" "UpdateHostkeys=no" "consent is limited to first-use acceptance" || return 1
}

test_verify_handshake_dry_run_never_calls_ssh() {
    local dummy_key="$TEST_HOME/id_ed25519_dryverify"
    local calls="$TEST_HOME/ssh-dry.calls"
    : > "$calls"
    touch "$dummy_key"

    local rc=0
    (
        ssh() { printf 'called\n' >> "$calls"; return 99; }
        GITSETU_DRY_RUN=1 GITSETU_TEST_SSH_VERIFY=1 \
            verify_ssh_handshake "$dummy_key" "github.com"
    ) || rc=$?
    unset GITSETU_DRY_RUN

    assert_equals "0" "$rc" "dry-run verification succeeds without network" || return 1
    assert_equals "0" "$(wc -c < "$calls" | tr -d ' ')" "dry-run does not invoke ssh" || return 1
}

test_verify_handshake_deceptive_host_never_uses_443() {
    local dummy_key="$TEST_HOME/id_ed25519_deceptive"
    local calls="$TEST_HOME/ssh-deceptive.calls"
    : > "$calls"
    touch "$dummy_key"

    local rc=0
    (
        ssh() {
            printf '%s\n' "$*" >> "$calls"
            return 255
        }
        GITSETU_TEST_SSH_VERIFY=1 GITSETU_ALLOW_SSH_PORT443=1 \
            verify_ssh_handshake "$dummy_key" "github.com.evil"
    ) >/dev/null 2>&1 || rc=$?
    unset GITSETU_ALLOW_SSH_PORT443

    assert_equals "1" "$rc" "deceptive host verification fails" || return 1
    assert_equals "1" "$(wc -l < "$calls" | tr -d ' ')" "deceptive host is attempted only on its literal port 22 route" || return 1
    assert_not_contains "$(cat "$calls")" " -p 443 " "deceptive host never receives the GitHub 443 route" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_ssh_automation.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "auto_register_ssh_keys missing SSH_AUTH_SOCK skips gracefully" test_auto_register_no_agent
run_test "auto_register_ssh_keys dead socket emits non-fatal warning" test_auto_register_dead_socket
run_test "auto_register_ssh_keys already loaded key is deduplicated" test_auto_register_key_already_loaded
run_test "auto_register_ssh_keys registers unloaded key successfully" test_auto_register_registers_unloaded_key
run_test "auto_register_ssh_keys handles failed registration non-fatally" test_auto_register_handles_add_failure
run_test "auto_register_ssh_keys discovers keys from PROFILE_KEYS" test_auto_register_from_profile_keys
run_test "auto_register_ssh_keys in dry run mode skips ssh-add" test_auto_register_dry_run_skips_ssh_add
run_test "invalid v2 registry never broadens SSH key scope" test_auto_register_invalid_registry_never_scans_ssh_dir
run_test "unconfigured no-registry SSH discovery remains supported" test_auto_register_unconfigured_discovery_requires_no_registry
run_test "try_gh_key_upload returns 1 when gh binary is missing" test_try_gh_missing_binary
run_test "try_gh_key_upload returns 1 when pubkey file is missing" test_try_gh_missing_pubkey
run_test "try_gh_key_upload returns 1 when gh is unauthenticated" test_try_gh_unauthenticated
run_test "try_gh_key_upload returns 1 when user declines upload" test_try_gh_user_declines
run_test "try_gh_key_upload returns 0 when key already registered" test_try_gh_key_already_registered
run_test "try_gh_key_upload succeeds when gh ssh-key add succeeds" test_try_gh_upload_success
run_test "try_gh_key_upload in dry run mode skips upload" test_try_gh_dry_run_skips_upload
run_test "verify_ssh_handshake port 22 success returns 0" test_verify_handshake_port22_success
run_test "verify_ssh_handshake port 443 corporate fallback returns 0" test_verify_handshake_port443_fallback
run_test "build_ssh_host_block standard configuration" test_build_ssh_host_block_standard
run_test "build_ssh_host_block corporate Port 443 for GitHub" test_build_ssh_host_block_port443_github
run_test "build_ssh_host_block Port 443 ignored for non-GitHub" test_build_ssh_host_block_port443_ignored_gitlab
run_test "handshake refuses implicit port 443 and host trust" test_verify_handshake_refuses_implicit_port443_and_host_trust
run_test "handshake deceptive host never receives GitHub 443" test_verify_handshake_deceptive_host_never_uses_443
run_test "handshake accepts explicit first-use host trust" test_verify_handshake_explicit_host_key_consent
run_test "handshake dry-run performs no network" test_verify_handshake_dry_run_never_calls_ssh
print_results "SSH Automation tests"
