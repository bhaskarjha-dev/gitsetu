#!/usr/bin/env bash
# tests/test_credential.sh — Tests for the Git credential helper broker
#
# Uses a portable POSIX timeout watchdog (macOS lacks GNU `timeout`).
# If a subprocess hangs, the watchdog kills it after 15s and the test
# fails cleanly instead of hanging CI forever.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# This suite owns one fixed backend/PATH environment; per-case snapshots only
# duplicate that environment and are especially costly on Git Bash/Windows.
_TEST_SKIP_ENV_SNAPSHOT=1
setup_test_home
source_gitsetu_libs

GITSETU_EXE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

# Force file-fallback path for credential storage in tests.
# On macOS CI, `security add-internet-password` hangs because there is no
# unlocked user keychain in headless environments.
#
# We use a marker file ($HOME/.config/gitsetu/.test_os) because macOS
# bash 3.2 does NOT propagate environment variables through pipelines
# inside background subshells (confirmed empirically: export, POSIX
# command prefix, and subshell export all fail).
#
# detect_os() checks for this file and sets GITSETU_OS to its contents,
# bypassing native OS detection and preventing keychain calls.
mkdir -p "$HOME/.config/gitsetu"
printf 'test' > "$HOME/.config/gitsetu/.test_os"

# The credential roundtrip deliberately selects the supported zero-dependency
# plaintext backend. Permission metadata is shimmed so the production checks
# remain deterministic on both POSIX CI and Git Bash hosts.
export GITSETU_CREDENTIAL_BACKEND=file
# Keep the broker protocol suite deterministic; NTFS DACL behavior has a
# dedicated shimmed contract in test_keychain.sh.
export OSTYPE=linux-gnu
mkdir -p "$HOME/test-bin"
cat > "$HOME/test-bin/stat" <<'EOF'
#!/usr/bin/env sh
format=""
path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|-f) format="$2"; shift 2 ;;
        -*) shift ;;
        *) path="$1"; shift ;;
    esac
done
case "$format" in
    %U|%Su) id -un ;;
    %u) id -u ;;
    *)
        case "$path" in
            */.tokens|*/.tokens.tmp.*) printf '600\n' ;;
            *) printf '700\n' ;;
        esac
        ;;
esac
EOF
chmod +x "$HOME/test-bin/stat"
cat > "$HOME/test-bin/icacls.exe" <<'EOF'
#!/usr/bin/env sh
printf '%s BUILTIN\\Administrators:(F)\n' "$1"
printf '  NT AUTHORITY\\SYSTEM:(F)\n'
printf '  %s:(F)\n' "$(id -un)"
EOF
cat > "$HOME/test-bin/fsutil.exe" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
chmod +x "$HOME/test-bin/icacls.exe" "$HOME/test-bin/fsutil.exe"
test_bin="$HOME/test-bin"
if command -v cygpath >/dev/null 2>&1; then
    test_bin=$(cygpath -u "$test_bin" 2>/dev/null || printf '%s' "$test_bin")
fi
export PATH="$test_bin:$PATH"

# ------------------------------------------------------------------------------
# Helper: run gitsetu credential with a portable POSIX timeout watchdog.
#
# Usage: _run_credential <timeout_secs> <stdin_data> [args...]
# Returns: exit code of the gitsetu command, or 137 on timeout (SIGKILL)
# Stdout: whatever gitsetu prints to stdout (for credential get)
# ------------------------------------------------------------------------------
_run_credential() {
    local timeout_secs="$1"
    local stdin_data="$2"
    shift 2

    local stdout_log="$HOME/.credential_stdout_$$.log"
    local stderr_log="$HOME/.credential_stderr_$$.log"
    local kill_status=0
    local wait_status=0

    # Run in a background subshell (portable — no GNU timeout needed).
    # OS override is via marker file, not env var (bash 3.2 limitation).
    # stderr is captured rather than discarded: the broker reports refusals
    # there, and dropping it made every failure indistinguishable.
    (printf "%b" "$stdin_data" | bash "$GITSETU_EXE" "$@" \
        >"$stdout_log" 2>"$stderr_log") &
    local cmd_pid=$!

    # Watchdog: kill the command after timeout_secs
    (sleep "$timeout_secs" && kill -9 "$cmd_pid" 2>/dev/null) &
    local watchdog_pid=$!

    # Wait for the command to finish
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?

    # Kill the watchdog (command finished before timeout).  A process which
    # exited between the wait and kill is an expected race; all other failures
    # remain visible.
    if kill "$watchdog_pid" 2>/dev/null; then
        :
    else
        kill_status=$?
        [[ "$kill_status" -eq 1 ]] || return "$kill_status"
    fi
    if wait "$watchdog_pid" 2>/dev/null; then
        :
    else
        wait_status=$?
        [[ "$wait_status" -eq 143 || "$wait_status" -eq 137 ]] || return "$wait_status"
    fi

    if [[ $rc -ne 0 ]]; then
        CREDENTIAL_LAST_STATUS="$rc"
        CREDENTIAL_LAST_STDERR=$(cat "$stderr_log" 2>/dev/null || printf '')
        CREDENTIAL_LAST_STDOUT=$(cat "$stdout_log" 2>/dev/null || printf '')
        rm -f "$stdout_log" "$stderr_log"
        return "$rc"
    fi

    # Print stdout (needed for credential get) and retain stderr for diagnosis.
    CREDENTIAL_LAST_STATUS=0
    CREDENTIAL_LAST_STDERR=$(cat "$stderr_log" 2>/dev/null || printf '')
    cat "$stdout_log" 2>/dev/null
    rm -f "$stdout_log" "$stderr_log"
    return 0
}

test_credential_broker() {
    mkdir -p "$HOME/.config/gitsetu"

    # Create a strict v2 registry and profile identities.
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" "global_user"
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "work_user"
    } > "$GITSETU_PROFILES_CONF"

    mkdir -p "$HOME/work"
    cd "$HOME/work" || return 1

    # 1. Test storing credentials (simulating Git's stdin)
    local store_input="protocol=https\nhost=github.com\nusername=work_user\npassword=secret_pat_123\n\n"
    _run_credential 15 "$store_input" credential store || {
        printf '    FAIL: credential store hung or failed\n'
        printf '    store status: %s\n' "${CREDENTIAL_LAST_STATUS:-?}"
        printf '    store stderr: %s\n' "${CREDENTIAL_LAST_STDERR:-<empty>}"
        return 1
    }
    local store_status="$CREDENTIAL_LAST_STATUS"
    local store_stderr="$CREDENTIAL_LAST_STDERR"

    # Verify it hit the fallback file
    assert_equals 0 "$store_status" "credential store exits cleanly" || return 1

    # 2. Test getting credentials
    local get_input="protocol=https\nhost=github.com\n\n"
    local get_output
    get_output=$(_run_credential 15 "$get_input" credential get) || {
        printf '    FAIL: credential get hung or failed\n'
        printf '    get status: %s\n' "${CREDENTIAL_LAST_STATUS:-?}"
        printf '    get stderr: %s\n' "${CREDENTIAL_LAST_STDERR:-<empty>}"
        printf '    store stderr: %s\n' "${store_stderr:-<empty>}"
        return 1
    }

    # It should output username=... and password=...
    if [[ "$get_output" != *"username=work_user"* ]] || [[ "$get_output" != *"password=secret_pat_123"* ]]; then
        printf 'Failed to retrieve correct credentials. Output: %s\n' "$get_output"
        printf '    get status:   %s\n' "${CREDENTIAL_LAST_STATUS:-?}"
        printf '    get stderr:   %s\n' "${CREDENTIAL_LAST_STDERR:-<empty>}"
        printf '    store status: %s\n' "$store_status"
        printf '    store stderr: %s\n' "${store_stderr:-<empty>}"
        printf '    backend: %s  os: %s  OSTYPE: %s\n' \
            "${GITSETU_CREDENTIAL_BACKEND:-unset}" "${GITSETU_OS:-unset}" "${OSTYPE:-unset}"
        printf '    token store:\n'
        local tokens_file="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/.tokens"
        if [[ -f "$tokens_file" ]]; then
            printf '      %s (%s bytes)\n' "$tokens_file" "$(wc -c < "$tokens_file" | tr -d ' ')"
            sed -e 's/^/      | /' "$tokens_file"
        else
            printf '      absent: %s\n' "$tokens_file"
        fi
        return 1
    fi

    # 3. Test erase
    _run_credential 15 "$store_input" credential erase || {
        printf '    FAIL: credential erase hung or failed\n'
        return 1
    }

    local get_output_after
    get_output_after=$(_run_credential 15 "$get_input" credential get || true)
    if [[ -n "$get_output_after" ]]; then
        echo "Credentials were not erased properly. Output: $get_output_after"
        return 1
    fi

    return 0
}

test_credential_ignores_ssh() {
    mkdir -p "$HOME/.config/gitsetu"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" "global_user"
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "work_user"
    } > "$GITSETU_PROFILES_CONF"
    mkdir -p "$HOME/work"
    cd "$HOME/work" || return 1

    # SSH protocol should be ignored
    local get_input="protocol=ssh\nhost=github.com\n\n"
    local get_output
    get_output=$(_run_credential 15 "$get_input" credential get || true)

    assert_equals "" "$get_output" "ssh protocol is ignored" || return 1
}

test_credential_outside_profile() {
    mkdir -p "$HOME/.config/gitsetu"
    test_v2_profile_config global "Global User" "global@example.com"
    test_v2_profile_config work "Work User" "work@example.com"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_global" "global_user"
        test_v2_registry_line work "$HOME/work" "github.com" "0" \
            "$HOME/.ssh/id_ed25519_work" "work_user"
    } > "$GITSETU_PROFILES_CONF"
    mkdir -p "$HOME/personal"
    cd "$HOME/personal" || return 1

    local get_input="protocol=https\nhost=github.com\n\n"
    local get_output
    get_output=$(_run_credential 15 "$get_input" credential get || true)

    assert_equals "" "$get_output" "empty output when outside profile directory" || return 1
}

printf '\n%btest_credential.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "Credential broker roundtrip (store/get/erase)" test_credential_broker
run_test "Credential broker ignores ssh protocol" test_credential_ignores_ssh
run_test "Credential broker ignores non-profile directories" test_credential_outside_profile
print_results "Credential tests"
