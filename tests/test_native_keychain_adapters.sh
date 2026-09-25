#!/usr/bin/env bash
# tests/test_native_keychain_adapters.sh — Hermetic native credential-adapter
# contracts using logging shims only.
#
# No test invokes a real security, secret-tool, or Git Credential Manager
# executable.  Each shim records its arguments/environment and keeps a private
# state directory beneath the test HOME.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# The adapter cases own their HOME, PATH, backend, and shim-state variables;
# skip the expensive whole-environment snapshot on every run_test invocation.
_TEST_SKIP_ENV_SNAPSHOT=1

ADAPTER_LOG=""
ADAPTER_STATE_DIR=""
ADAPTER_MODE="normal"
BASE_PATH="$PATH"

# ---------------------------------------------------------------------------
# Test environment and logging shims
# ---------------------------------------------------------------------------

_native_setup() {
    local os_name="$1"
    local backend="${2-native}"

    setup_test_home || return 1
    source_gitsetu_libs || return 1
    # core.sh initializes GITSETU_OS while it is sourced, so apply the
    # platform override after module loading (as production callers do).
    export GITSETU_OS="$os_name"
    export GITSETU_CREDENTIAL_BACKEND="$backend"
    export PATH="$BASE_PATH"

    ADAPTER_LOG="$HOME/adapter.log"
    ADAPTER_STATE_DIR="$HOME/adapter-state"
    ADAPTER_MODE="normal"
    mkdir -p "$ADAPTER_STATE_DIR"
    : > "$ADAPTER_LOG"
    export ADAPTER_LOG ADAPTER_STATE_DIR ADAPTER_MODE
}

_adapter_bin() {
    ADAPTER_BIN="$HOME/adapter-bin"
    mkdir -p "$ADAPTER_BIN"
    local path_bin="$ADAPTER_BIN"
    if command -v cygpath >/dev/null 2>&1; then
        path_bin=$(cygpath -u "$ADAPTER_BIN" 2>/dev/null || printf '%s' "$ADAPTER_BIN")
    fi
    case ":$PATH:" in
        *":$path_bin:"*) ;;
        *) export PATH="$path_bin:$PATH" ;;
    esac
}

# The security shim implements just enough of the three operations used by
# lib/keychain.sh.  It deliberately returns 44 for a missing item, like the
# real macOS tool, so tests can detect whether the public adapter normalizes
# that result consistently.
_make_security_shim() {
    local bin
    _adapter_bin || return 1
    bin="$ADAPTER_BIN"
    cat > "$bin/security" <<'EOF'
#!/usr/bin/env bash
set -u

op="${1-}"
if [[ $# -gt 0 ]]; then shift; fi
service=""
record=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a)
            if [[ $# -ge 2 ]]; then
                shift 2
            else
                shift
            fi
            ;;
        -s)
            if [[ $# -ge 2 ]]; then
                service="$2"
                shift 2
            else
                shift
            fi
            ;;
        -w)
            if [[ "$op" == "add-generic-password" && $# -ge 2 ]]; then
                record="$2"
                shift 2
            else
                shift
            fi
            ;;
        *)
            shift
            ;;
    esac
done

safe=$(printf '%s' "$service" | sed 's/[^A-Za-z0-9_.-]/_/g')
state_file="$ADAPTER_STATE_DIR/$safe"
printf 'command=security op=%s service=%s record_present=%s\n' \
    "$op" "$service" "$([[ -n "$record" ]] && printf yes || printf no)" >> "$ADAPTER_LOG"

case "$op" in
    add-generic-password)
        [[ "${ADAPTER_MODE:-normal}" != "store_fail" ]] || exit 7
        printf '%s' "$record" > "$state_file"
        exit 0
        ;;
    find-generic-password)
        if [[ "${ADAPTER_MODE:-normal}" == "find_fail" ]]; then
            exit 7
        fi
        if [[ "${ADAPTER_MODE:-normal}" == "malformed" ]]; then
            printf 'v2\tnot-a-record\n'
            exit 0
        fi
        if [[ "${ADAPTER_MODE:-normal}" == "not_found" || ! -f "$state_file" ]]; then
            exit 44
        fi
        cat "$state_file"
        exit 0
        ;;
    delete-generic-password)
        [[ "${ADAPTER_MODE:-normal}" != "delete_fail" ]] || exit 7
        rm -f "$state_file"
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod 700 "$bin/security"
}

# Secret Service's attributes are the namespace for Linux/WSL.  The shim
# stores one record per profile/host/path tuple and emits the raw v2 record on
# lookup, matching the production adapter's contract.
_make_secret_tool_shim() {
    local bin
    _adapter_bin || return 1
    bin="$ADAPTER_BIN"
    cat > "$bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
set -u

op="${1-}"
if [[ $# -gt 0 ]]; then shift; fi
printf 'command=secret-tool op=%s args=' "$op" >> "$ADAPTER_LOG"
arg=""
for arg in "$@"; do
    printf '<%s>' "$arg" >> "$ADAPTER_LOG"
done
printf '\n' >> "$ADAPTER_LOG"

profile=""
host=""
credential_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label=*|gitsetu|v2)
            shift
            ;;
        profile|host|path)
            field="$1"
            if [[ $# -ge 2 ]]; then
                value="$2"
                shift 2
            else
                value=""
                shift
            fi
            if [[ "$field" == "profile" ]]; then
                profile="$value"
            elif [[ "$field" == "host" ]]; then
                host="$value"
            else
                credential_path="$value"
            fi
            ;;
        *)
            shift
            ;;
    esac
done
safe=$(printf '%s' "$profile|$host|$credential_path" | sed 's/[^A-Za-z0-9_.-]/_/g')
state_file="$ADAPTER_STATE_DIR/$safe"

case "$op" in
    store)
        [[ "${ADAPTER_MODE:-normal}" != "store_fail" ]] || exit 7
        record=$(cat)
        printf 'tuple=profile:%s host:%s path:%s record_present=yes\n' \
            "$profile" "$host" "$credential_path" >> "$ADAPTER_LOG"
        printf '%s' "$record" > "$state_file"
        exit 0
        ;;
    lookup)
        if [[ "${ADAPTER_MODE:-normal}" == "malformed" ]]; then
            printf 'v2\tnot-a-record\n'
            exit 0
        fi
        if [[ "${ADAPTER_MODE:-normal}" == "not_found" || ! -f "$state_file" ]]; then
            exit 1
        fi
        cat "$state_file"
        exit 0
        ;;
    clear)
        [[ "${ADAPTER_MODE:-normal}" != "clear_fail" ]] || exit 7
        rm -f "$state_file"
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod 700 "$bin/secret-tool"
}

# GCM receives a normal Git credential request on stdin.  The shim records the
# non-secret target fields and environment flags, while storing only the
# password line in its private state file.
_make_gcm_shim() {
    local bin="$1"
    local name="$2"
    cat > "$bin/$name" <<'EOF'
#!/usr/bin/env bash
set -u

op="${1-}"
if [[ $# -gt 0 ]]; then shift; fi
input=$(cat)
protocol=""
host=""
username=""
password_seen=0
password=""
while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        protocol=*) protocol="${line#protocol=}" ;;
        host=*) host="${line#host=}" ;;
        username=*) username="${line#username=}" ;;
        password=*)
            password_seen=1
            password="${line#password=}"
            ;;
    esac
done <<< "$input"

printf 'command=%s op=%s protocol=%s host=%s username=%s password_seen=%s GIT_TERMINAL_PROMPT=%s GCM_INTERACTIVE=%s\n' \
    "GITSETU_TEST_GCM" "$op" "$protocol" "$host" "$username" "$password_seen" \
    "${GIT_TERMINAL_PROMPT-}" "${GCM_INTERACTIVE-}" >> "$ADAPTER_LOG"
safe=$(printf '%s' "$host|$username" | sed 's/[^A-Za-z0-9_.-]/_/g')
state_file="$ADAPTER_STATE_DIR/$safe"

case "$op" in
    store)
        [[ "${ADAPTER_MODE:-normal}" != "store_fail" ]] || exit 7
        printf '%s' "$password" > "$state_file"
        exit 0
        ;;
    get)
        if [[ "${ADAPTER_MODE:-normal}" == "malformed" ]]; then
            printf 'protocol=https\nhost=%s\nusername=%s\npassword=not-a-v2-record\n\n' "$host" "$username"
            exit 0
        fi
        if [[ "${ADAPTER_MODE:-normal}" == "not_found" || ! -f "$state_file" ]]; then
            exit 1
        fi
        printf 'protocol=https\nhost=%s\nusername=%s\n' "$host" "$username"
        if [[ "${ADAPTER_MODE:-normal}" == "no_password" ]]; then
            exit 0
        fi
        printf 'password=%s\n\n' "$(cat "$state_file")"
        exit 0
        ;;
    erase)
        [[ "${ADAPTER_MODE:-normal}" != "erase_fail" ]] || exit 7
        rm -f "$state_file"
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod 700 "$bin/$name"
}

_make_full_gcm_shim() {
    local bin
    _adapter_bin || return 1
    bin="$ADAPTER_BIN"
    _make_gcm_shim "$bin" git-credential-manager || return 1
    _make_gcm_shim "$bin" git-credential-manager-core || return 1
}

# ---------------------------------------------------------------------------
# Adapter contracts
# ---------------------------------------------------------------------------

test_macos_security_service_names_and_roundtrip() {
    _native_setup macos native || return 1
    _make_security_shim || return 1

    local expected_service="gitsetu:credential:v2:776f726b2070726f66696c65:6769746875622e636f6d3a343433:2f6f72672f7265706f"
    _keychain_service_name "work profile" "github.com:443" "" || return 1
    assert_equals "gitsetu:credential:v2:776f726b2070726f66696c65:6769746875622e636f6d3a343433:root" \
        "$KEYCHAIN_SERVICE_NAME" "macOS empty path uses the root service suffix" || return 1
    _keychain_service_name "work profile" "github.com:443" "/" || return 1
    assert_equals "gitsetu:credential:v2:776f726b2070726f66696c65:6769746875622e636f6d3a343433:2f" \
        "$KEYCHAIN_SERVICE_NAME" "macOS slash path has a distinct service suffix" || return 1
    local status=0
    keychain_store "work profile" "github.com:443" "user" "secret" "/org/repo" \
        >/dev/null 2>&1 || status=$?
    assert_equals 0 "$status" "macOS shim stores through security" || return 1
    assert_file_contains "$ADAPTER_LOG" "op=add-generic-password service=$expected_service" \
        "macOS uses the exact namespaced service name" || return 1

    local output
    output=$(keychain_get "work profile" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=user\npassword=secret' "$output" \
        "macOS get returns the exact v2 record" || return 1
    assert_file_contains "$ADAPTER_LOG" "op=find-generic-password service=$expected_service" \
        "macOS get queries the same exact service" || return 1

    status=0
    keychain_get "work profile" "github.com:443" "/other" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "macOS not-found is normalized to a public miss" || return 1

    keychain_erase "work profile" "github.com:443" "/org/repo" >/dev/null 2>&1 || return 1
    assert_file_contains "$ADAPTER_LOG" "op=delete-generic-password service=$expected_service" \
        "macOS erase deletes the exact service" || return 1
}

test_macos_security_failure_modes() {
    _native_setup macos native || return 1
    _make_security_shim || return 1

    local status=0 output
    ADAPTER_MODE=store_fail
    export ADAPTER_MODE
    keychain_store "work" "github.com" "user" "secret" "" >/dev/null 2>&1 || status=$?
    assert_equals 7 "$status" "macOS store propagates security failure" || return 1

    status=0
    ADAPTER_MODE=malformed
    export ADAPTER_MODE
    output=$(keychain_get "work" "github.com" "" 2>/dev/null) || status=$?
    assert_equals 2 "$status" "macOS malformed native record is rejected" || return 1
    assert_equals "" "$output" "macOS malformed record emits no secret" || return 1

    # Missing is idempotent, but a real keychain/backend failure is not.
    status=0
    ADAPTER_MODE=not_found
    keychain_erase "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 0 "$status" "macOS erase treats an already-missing item as success" || return 1

    status=0
    ADAPTER_MODE=find_fail
    keychain_erase "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 7 "$status" "macOS erase does not hide a backend failure as not-found" || return 1
}

test_macos_security_not_found_is_a_public_miss() {
    _native_setup macos native || return 1
    _make_security_shim || return 1
    local status=0
    ADAPTER_MODE=not_found
    keychain_get "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "macOS missing item is normalized to a public miss" || return 1
}

test_linux_secret_tool_attributes_and_lifecycle() {
    _native_setup linux native || return 1
    _make_secret_tool_shim || return 1

    local status=0
    keychain_store "work" "github.com:443" "empty-user" "empty-pass" "" \
        >/dev/null 2>&1 || status=$?
    assert_equals 0 "$status" "Linux shim stores the empty-path tuple" || return 1
    keychain_store "work" "github.com:443" "root-user" "root-pass" "/" \
        >/dev/null 2>&1 || return 1
    keychain_store "work" "github.com:443" "user" "secret" "/org/repo" \
        >/dev/null 2>&1 || return 1
    assert_file_contains "$ADAPTER_LOG" "op=store" "Linux store invokes secret-tool" || return 1
    assert_file_contains "$ADAPTER_LOG" "tuple=profile:work host:github.com:443 path: record_present=yes" \
        "Linux store preserves an empty path attribute" || return 1
    assert_file_contains "$ADAPTER_LOG" "tuple=profile:work host:github.com:443 path:/ record_present=yes" \
        "Linux store preserves the root path attribute" || return 1
    assert_file_contains "$ADAPTER_LOG" "tuple=profile:work host:github.com:443 path:/org/repo" \
        "Linux store uses exact Secret Service attributes" || return 1

    local output
    output=$(keychain_get "work" "github.com:443" "") || return 1
    assert_equals $'username=empty-user\npassword=empty-pass' "$output" \
        "Linux get returns the empty-path record" || return 1
    output=$(keychain_get "work" "github.com:443" "/") || return 1
    assert_equals $'username=root-user\npassword=root-pass' "$output" \
        "Linux get returns the root-path record" || return 1
    output=$(keychain_get "work" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=user\npassword=secret' "$output" \
        "Linux get returns the exact v2 record" || return 1
    assert_file_contains "$ADAPTER_LOG" "op=lookup" "Linux lookup invokes secret-tool" || return 1

    status=0
    keychain_get "work" "github.com:443" "/other" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "Linux wrong-path lookup is a miss" || return 1

    keychain_erase "work" "github.com:443" "/org/repo" >/dev/null 2>&1 || return 1
    assert_file_contains "$ADAPTER_LOG" "op=clear" "Linux erase clears the exact Secret Service tuple" || return 1
}

test_linux_secret_tool_failure_modes_and_wsl() {
    _native_setup linux native || return 1
    _make_secret_tool_shim || return 1

    local status=0 output
    ADAPTER_MODE=store_fail
    keychain_store "work" "github.com" "user" "secret" "" >/dev/null 2>&1 || status=$?
    assert_equals 7 "$status" "Linux store propagates secret-tool failure" || return 1

    status=0
    ADAPTER_MODE=not_found
    keychain_get "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "Linux missing item is a normal miss" || return 1

    status=0
    ADAPTER_MODE=malformed
    export ADAPTER_MODE
    output=$(keychain_get "work" "github.com" "" 2>/dev/null) || status=$?
    assert_equals 2 "$status" "Linux malformed native record is rejected" || return 1
    assert_equals "" "$output" "Linux malformed record emits no secret" || return 1

    status=0
    ADAPTER_MODE=clear_fail
    keychain_erase "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 7 "$status" "Linux erase propagates clear failure" || return 1

    # WSL deliberately shares the Secret Service adapter, not a Windows GCM
    # emulation.  This call still uses the isolated shim.
    GITSETU_OS=wsl
    export GITSETU_OS
    keychain_store "wsl" "github.com" "wsl-user" "wsl-pass" "" >/dev/null 2>&1 || return 1
    output=$(keychain_get "wsl" "github.com" "") || return 1
    assert_equals $'username=wsl-user\npassword=wsl-pass' "$output" \
        "WSL uses the Secret Service shim" || return 1
}

test_gcm_target_names_and_command_selection() {
    _native_setup gitbash native || return 1

    _keychain_gcm_target "work" "github.com" "" || return 1
    assert_equals "gitsetu-776f726b.invalid" "$KEYCHAIN_GCM_HOST" \
        "GCM host is profile-scoped and fixed" || return 1
    assert_equals "credential-v2-6769746875622e636f6d-root" "$KEYCHAIN_GCM_USERNAME" \
        "GCM username uses root for the empty path" || return 1

    _keychain_gcm_target "work" "github.com" "/" || return 1
    assert_equals "credential-v2-6769746875622e636f6d-2f" "$KEYCHAIN_GCM_USERNAME" \
        "GCM root slash is distinct from the empty path" || return 1

    _keychain_gcm_target "work" "github.com" "/org/repo" || return 1
    assert_equals "credential-v2-6769746875622e636f6d-2f6f72672f7265706f" "$KEYCHAIN_GCM_USERNAME" \
        "GCM repository path is hex-namespaced" || return 1

    local bin
    _adapter_bin || return 1
    bin="$ADAPTER_BIN"
    _make_gcm_shim "$bin" git-credential-manager-core || return 1
    local restricted_path="$bin"
    if command -v cygpath >/dev/null 2>&1; then
        restricted_path=$(cygpath -u "$bin" 2>/dev/null || printf '%s' "$bin")
    fi
    PATH="$restricted_path:/usr/bin:/bin"
    export PATH
    _keychain_gcm_command || return 1
    assert_equals "git-credential-manager-core" "${KEYCHAIN_GCM_COMMAND[0]}" \
        "GCM core executable is selected when the full name is absent" || return 1
}

test_gcm_roundtrip_is_noninteractive_and_exact() {
    _native_setup gitbash native || return 1
    _make_full_gcm_shim || return 1

    local status=0
    keychain_store "work" "github.com:443" "user" "secret" "/org/repo" \
        >/dev/null 2>&1 || status=$?
    assert_equals 0 "$status" "GCM shim stores the namespaced target" || return 1
    keychain_store "personal" "github.com:443" "personal-user" "personal-pass" "/org/repo" \
        >/dev/null 2>&1 || return 1

    local output
    output=$(keychain_get "work" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=user\npassword=secret' "$output" \
        "GCM get returns the exact v2 record" || return 1
    output=$(keychain_get "personal" "github.com:443" "/org/repo") || return 1
    assert_equals $'username=personal-user\npassword=personal-pass' "$output" \
        "GCM isolates profiles sharing a host and path" || return 1
    assert_file_contains "$ADAPTER_LOG" "op=store" "GCM store is logged" || return 1
    assert_file_contains "$ADAPTER_LOG" "op=get" "GCM get is logged" || return 1
    assert_file_contains "$ADAPTER_LOG" "host=gitsetu-776f726b.invalid" \
        "GCM request uses the exact synthetic host" || return 1
    assert_file_contains "$ADAPTER_LOG" "username=credential-v2-6769746875622e636f6d3a343433-2f6f72672f7265706f" \
        "GCM request uses the exact path-scoped username" || return 1
    assert_file_contains "$ADAPTER_LOG" "GIT_TERMINAL_PROMPT=0" \
        "GCM is invoked with terminal prompting disabled" || return 1
    assert_file_contains "$ADAPTER_LOG" "GCM_INTERACTIVE=never" \
        "GCM is invoked in noninteractive mode" || return 1

    status=0
    keychain_get "work" "github.com:443" "/other" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "GCM wrong-path lookup is a miss" || return 1

    keychain_erase "work" "github.com:443" "/org/repo" >/dev/null 2>&1 || return 1
    assert_file_contains "$ADAPTER_LOG" "op=erase" "GCM erase is logged" || return 1
}

test_gcm_failure_modes_are_not_ambiguous() {
    _native_setup gitbash native || return 1
    _make_full_gcm_shim || return 1

    local status=0 output
    ADAPTER_MODE=store_fail
    keychain_store "work" "github.com" "user" "secret" "" >/dev/null 2>&1 || status=$?
    assert_equals 7 "$status" "GCM store propagates backend failure" || return 1

    status=0
    ADAPTER_MODE=not_found
    keychain_get "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "GCM missing item is a normal miss" || return 1

    status=0
    ADAPTER_MODE=malformed
    export ADAPTER_MODE
    output=$(keychain_get "work" "github.com" "" 2>/dev/null) || status=$?
    assert_equals 2 "$status" "GCM malformed v2 record is rejected" || return 1
    assert_equals "" "$output" "GCM malformed record emits no secret" || return 1

    status=0
    ADAPTER_MODE=no_password
    keychain_get "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 1 "$status" "GCM response without a password is a miss" || return 1

    status=0
    ADAPTER_MODE=erase_fail
    keychain_erase "work" "github.com" "" >/dev/null 2>&1 || status=$?
    assert_equals 7 "$status" "GCM erase does not hide a backend failure" || return 1
}

test_missing_native_commands_fail_closed_without_plaintext_fallback() {
    _native_setup unknown native || return 1
    local empty_bin="$HOME/empty-bin"
    mkdir -p "$empty_bin"
    local old_path="$PATH"
    export PATH="$empty_bin"

    local os_name status=0 output
    for os_name in macos linux gitbash; do
        GITSETU_OS="$os_name"
        export GITSETU_OS
        status=0
        output=$(keychain_store "work" "github.com" "user" "secret" "" 2>&1) || status=$?
        assert_equals 2 "$status" "missing $os_name native command fails closed" || {
            export PATH="$old_path"
            return 1
        }
        assert_contains "$output" "no fallback" "missing $os_name command explains no fallback" || {
            export PATH="$old_path"
            return 1
        }
    done
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "missing native command never creates a plaintext fallback" || {
        export PATH="$old_path"
        return 1
    }

    # Restore the ordinary tool path before checking the explicit opt-in.
    export PATH="$old_path"
    export GITSETU_OS=unknown
    export GITSETU_CREDENTIAL_BACKEND=file
    local stat_bin="$HOME/file-stat-bin"
    mkdir -p "$stat_bin"
    cat > "$stat_bin/stat" <<'EOF'
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
    chmod 700 "$stat_bin/stat"
    cat > "$stat_bin/fsutil.exe" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
    cat > "$stat_bin/icacls.exe" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
    chmod 700 "$stat_bin/fsutil.exe" "$stat_bin/icacls.exe"
    local stat_path="$stat_bin"
    if command -v cygpath >/dev/null 2>&1; then
        stat_path=$(cygpath -u "$stat_bin" 2>/dev/null || printf '%s' "$stat_bin")
    fi
    export PATH="$stat_path:$old_path"
    status=0
    output=$(keychain_store "work" "github.com" "user" "secret" "" 2>&1) || status=$?
    assert_equals 0 "$status" "explicit file backend is available" || return 1
    assert_contains "$output" "PLAINTEXT" "explicit file backend warns before use" || return 1
    assert_file_exists "$GITSETU_CONFIG_DIR/.tokens" "explicit file backend writes the isolated file" || return 1

    rm -f "$GITSETU_CONFIG_DIR/.tokens"
    unset GITSETU_CREDENTIAL_BACKEND
    export GITSETU_ALLOW_PLAINTEXT=1
    status=0
    output=$(keychain_store "work" "github.com" "user" "allow-pass" "" 2>&1) || status=$?
    assert_equals 0 "$status" "GITSETU_ALLOW_PLAINTEXT is an explicit file opt-in" || return 1
    assert_contains "$output" "PLAINTEXT" "allow-plaintext opt-in remains disclosed" || return 1
    assert_file_exists "$GITSETU_CONFIG_DIR/.tokens" "allow-plaintext opt-in writes the isolated file" || return 1
}

test_unsupported_native_backend_is_rejected() {
    _native_setup unknown bogus || return 1
    local status=0 output
    output=$(keychain_store "work" "github.com" "user" "secret" "" 2>&1) || status=$?
    assert_equals 2 "$status" "unsupported credential backend is rejected" || return 1
    assert_contains "$output" "Unsupported GITSETU_CREDENTIAL_BACKEND" \
        "unsupported backend identifies the configuration error" || return 1
    assert_file_not_exists "$GITSETU_CONFIG_DIR/.tokens" \
        "unsupported backend does not create a plaintext store" || return 1
}

printf '\n%btest_native_keychain_adapters.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "macOS security service names and roundtrip" test_macos_security_service_names_and_roundtrip
run_test "macOS security malformed and erase failures" test_macos_security_failure_modes
run_test "macOS security not-found normalization" test_macos_security_not_found_is_a_public_miss
run_test "Linux secret-tool attributes and lifecycle" test_linux_secret_tool_attributes_and_lifecycle
run_test "Linux secret-tool failures and WSL routing" test_linux_secret_tool_failure_modes_and_wsl
run_test "GCM target names and command selection" test_gcm_target_names_and_command_selection
run_test "GCM exact roundtrip and noninteractive flags" test_gcm_roundtrip_is_noninteractive_and_exact
run_test "GCM not-found, malformed, and erase failures" test_gcm_failure_modes_are_not_ambiguous
run_test "missing native commands and explicit fallback" test_missing_native_commands_fail_closed_without_plaintext_fallback
run_test "unsupported native backend" test_unsupported_native_backend_is_rejected
print_results "Native keychain adapter tests"
