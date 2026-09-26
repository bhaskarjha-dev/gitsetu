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

# These are deliberately kept outside the bundle's source directory.  The
# helpers' TEST_HOME is already platform-native on Git Bash/MSYS, which is
# important for exercising prompt/status path handling rather than papering over
# a Windows path mismatch with a POSIX-only fixture.
BUNDLE_CASE_ROOT=""
BUNDLE_HOME=""
BUNDLE_CONFIG_DIR=""
BUNDLE_PROFILES_DIR=""
BUNDLE_HOOKS_DIR=""
BUNDLE_REGISTRY=""
BUNDLE_SSH_CONFIG=""
BUNDLE_REPO_DIR=""
BUNDLE_VAULT_DIR=""
BUNDLE_RUNTIME_DIR=""
BUNDLE_LOCK_DIR=""
BUNDLE_KEY_GLOBAL=""
BUNDLE_KEY_WORK=""
BUNDLE_CWD="$BUNDLE_RUN_DIR"
BUNDLE_BIN_DIR=""
BUNDLE_BASH_ENV=""
BUNDLE_SNAPSHOT_DIR=""
BUNDLE_BASE_SNAPSHOT_DIR=""
BUNDLE_CONFIGURED_READY=0
BUNDLE_BASE_READY=0
BUNDLE_OUTPUT=""
BUNDLE_STATUS=0
BUNDLE_BACKGROUND_PID=""
bundle_lock_holder_pid=""
BUNDLE_FIXTURE_SKIPPED=0

printf '\n%btest_bundle_path.sh%b\n' "$T_BOLD" "$T_RESET"
printf 'Artifact under test: %s\n' "$BUNDLE_PATH"

bundle_is_windows_shell() {
    case "${OSTYPE:-}" in
        msys*|cygwin*|mingw*) return 0 ;;
    esac
    return 1
}

copy_exact_artifact() {
    cp "$BUNDLE_PATH" "$BUNDLE_COPY"
    chmod 700 "$BUNDLE_COPY"
    assert_file_exists "$BUNDLE_COPY" "bundle is copied into an isolated run directory"
    assert_exit_code 0 cmp -s "$BUNDLE_PATH" "$BUNDLE_COPY"
    assert_file_contains "$BUNDLE_COPY" "GITSETU_STANDALONE=1" "copied artifact identifies standalone mode" || return 1
    assert_dir_not_exists "$BUNDLE_RUN_DIR/lib" "bundle test directory has no source lib/ tree"
}

# Run the exact copied artifact.  No product module is sourced by this file;
# state is created only through the CLI and a small, self-contained fixture.
bundle_exec() {
    local cwd="${BUNDLE_CWD:-$BUNDLE_RUN_DIR}"

    (
        cd "$cwd" || exit 125
        if [[ -n "${BUNDLE_BIN_DIR:-}" ]]; then
            PATH="$BUNDLE_BIN_DIR:$PATH"
            export PATH
        fi
        env \
            HOME="$BUNDLE_HOME" \
            USERPROFILE="$BUNDLE_HOME" \
            APPDATA="$BUNDLE_HOME/AppData/Roaming" \
            LOCALAPPDATA="$BUNDLE_HOME/AppData/Local" \
            XDG_CONFIG_HOME="$BUNDLE_HOME/.config" \
            GIT_CONFIG_GLOBAL="$BUNDLE_HOME/.gitconfig" \
            GIT_CONFIG_NOSYSTEM=1 \
            GIT_TERMINAL_PROMPT=0 \
            GITSETU_TEST=1 \
            GITSETU_TEST_RUNTIME_DIR="$BUNDLE_RUNTIME_DIR" \
            GITSETU_LOCK_DIR="$BUNDLE_LOCK_DIR" \
            GITSETU_CONFIG_DIR="$BUNDLE_CONFIG_DIR" \
            GITSETU_BACKUP_DIR="$BUNDLE_CONFIG_DIR/backups" \
            GITSETU_PROFILES_DIR="$BUNDLE_PROFILES_DIR" \
            GITSETU_HOOKS_DIR="$BUNDLE_HOOKS_DIR" \
            GITSETU_PROFILES_CONF="$BUNDLE_REGISTRY" \
            GITSETU_VERIFY_NETWORK=0 \
            BASH_ENV="$BUNDLE_BASH_ENV" \
            CI=1 \
            bash "$BUNDLE_COPY" "$@"
    )
}

bundle_invoke() {
    BUNDLE_OUTPUT=""
    BUNDLE_STATUS=0
    if BUNDLE_OUTPUT=$(bundle_exec "$@" 2>&1); then
        BUNDLE_STATUS=0
    else
        BUNDLE_STATUS=$?
    fi
    return 0
}

# Assert the last artifact invocation succeeded and, when it did not, print the
# captured output.  A bare status code makes a platform-specific failure
# undiagnosable: the artifact's own error text is the only actionable evidence,
# and without it the same failure has to be reproduced on another platform.
bundle_assert_ok() {
    local label="$1"
    if [[ "$BUNDLE_STATUS" -eq 0 ]]; then
        return 0
    fi
    printf '    FAIL: %s\n' "$label"
    printf '      Exit status: %s\n' "$BUNDLE_STATUS"
    printf '      Artifact output (tail):\n'
    printf '%s\n' "$BUNDLE_OUTPUT" | tail -n 30 | sed 's/^/        /'
    return 1
}

# Start one isolated artifact invocation and write its status beside its output.
# This is used only by the lock-contention case; ordinary cases use
# bundle_invoke so their output remains easy to diagnose.
bundle_invoke_input() {
    local input="$1"
    shift
    BUNDLE_OUTPUT=""
    BUNDLE_STATUS=0
    if BUNDLE_OUTPUT=$(printf '%s' "$input" | bundle_exec "$@" 2>&1); then
        BUNDLE_STATUS=0
    else
        BUNDLE_STATUS=$?
    fi
    return 0
}

bundle_start() {
    local output_file="$1"
    shift

    BUNDLE_BACKGROUND_PID=""
    (
        child_status=0
        if bundle_exec "$@" >"$output_file" 2>&1; then
            child_status=0
        else
            child_status=$?
        fi
        printf '%s\n' "$child_status" > "${output_file}.rc"
        exit "$child_status"
    ) &
    BUNDLE_BACKGROUND_PID=$!
}

bundle_require_command() {
    local command_name="$1"
    local test_name="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        skip_test "$test_name" "required executable '$command_name' is unavailable"
        BUNDLE_FIXTURE_SKIPPED=1
        return 1
    fi
    return 0
}

bundle_require_vault_tools() {
    local openssl_help=""

    if ! bundle_require_command openssl "bundle backup/restore"; then
        return 1
    fi
    if ! bundle_require_command tar "bundle backup/restore"; then
        return 1
    fi
    if ! openssl_help=$(openssl enc -help 2>&1); then
        skip_test "bundle backup/restore" "OpenSSL cannot report enc options"
        BUNDLE_FIXTURE_SKIPPED=1
        return 1
    fi
    if ! printf '%s\n' "$openssl_help" | grep -qF -- '-pbkdf2'; then
        skip_test "bundle backup/restore" "OpenSSL lacks the PBKDF2 support required by vault v2"
        BUNDLE_FIXTURE_SKIPPED=1
        return 1
    fi
    return 0
}

bundle_export_fixture_environment() {
    # Explicitly replace all product/config roots so a child can never inherit
    # the harness HOME or a path belonging to a previous case.
    export HOME="$BUNDLE_HOME"
    export USERPROFILE="$BUNDLE_HOME"
    export APPDATA="$BUNDLE_HOME/AppData/Roaming"
    export LOCALAPPDATA="$BUNDLE_HOME/AppData/Local"
    export XDG_CONFIG_HOME="$BUNDLE_HOME/.config"
    export GIT_CONFIG_GLOBAL="$BUNDLE_HOME/.gitconfig"
    export GITSETU_CONFIG_DIR="$BUNDLE_CONFIG_DIR"
    export GITSETU_BACKUP_DIR="$BUNDLE_CONFIG_DIR/backups"
    export GITSETU_PROFILES_DIR="$BUNDLE_PROFILES_DIR"
    export GITSETU_HOOKS_DIR="$BUNDLE_HOOKS_DIR"
    export GITSETU_PROFILES_CONF="$BUNDLE_REGISTRY"
    export GITSETU_TEST_RUNTIME_DIR="$BUNDLE_RUNTIME_DIR"
    export GITSETU_LOCK_DIR="$BUNDLE_LOCK_DIR"
    export GITSETU_TEST=1
    export GITSETU_VERIFY_NETWORK=0
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    export CI=1

    unset XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
    unset GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_NAMESPACE
    unset GIT_PAGER GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_EXTERNAL_DIFF
    unset GIT_ASKPASS SSH_ASKPASS SSH_AUTH_SOCK GIT_SSH_COMMAND GIT_SSH
    unset GITSETU_TEST_VAULT_MODE GITSETU_TEST_VAULT_PASS GITSETU_VAULT_PASS
    unset GITSETU_ALLOW_TEST_LIB_DIR GITSETU_AUTO_MODE GITSETU_CRLF_DEPTH
    unset GITSETU_DEFAULT_LOCK_DIR GITSETU_LOCK_RUNTIME_CONFIGURED
    unset GITSETU_LOCK_PATH GITSETU_LOCK_TOKEN GITSETU_LOCK_PROCESS_START

    if bundle_is_windows_shell; then
        case "$BUNDLE_HOME" in
            [A-Za-z]:/*)
                export HOMEDRIVE="${BUNDLE_HOME%%:*}"
                export HOMEPATH="${BUNDLE_HOME#*:}"
                ;;
            *)
                unset HOMEDRIVE HOMEPATH
                ;;
        esac
    else
        unset HOMEDRIVE HOMEPATH
    fi
}

bundle_reset_fixture() {
    BUNDLE_CASE_ROOT="$TEST_HOME/bundle-contract"
    BUNDLE_HOME="$BUNDLE_CASE_ROOT/home"
    BUNDLE_CONFIG_DIR="$BUNDLE_HOME/.config/gitsetu"
    BUNDLE_PROFILES_DIR="$BUNDLE_CONFIG_DIR/profiles"
    BUNDLE_HOOKS_DIR="$BUNDLE_CONFIG_DIR/hooks"
    BUNDLE_REGISTRY="$BUNDLE_CONFIG_DIR/profiles.conf"
    BUNDLE_SSH_CONFIG="$BUNDLE_HOME/.ssh/config"
    BUNDLE_REPO_DIR="$BUNDLE_HOME/work/repo"
    BUNDLE_VAULT_DIR="$BUNDLE_CASE_ROOT/vaults"
    BUNDLE_RUNTIME_DIR="$BUNDLE_CASE_ROOT/runtime"
    BUNDLE_LOCK_DIR="$BUNDLE_RUNTIME_DIR/profiles.lock"
    BUNDLE_KEY_GLOBAL="$BUNDLE_HOME/.ssh/id_ed25519_global"
    BUNDLE_KEY_WORK="$BUNDLE_HOME/.ssh/id_ed25519_work"
    BUNDLE_SNAPSHOT_DIR="$BUNDLE_CASE_ROOT/configured-home"
    BUNDLE_BASE_SNAPSHOT_DIR="$BUNDLE_CASE_ROOT/base-home"
    BUNDLE_BASH_ENV="$BUNDLE_CASE_ROOT/bash-env"
    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    BUNDLE_BIN_DIR=""
    BUNDLE_CONFIGURED_READY=0
    BUNDLE_BASE_READY=0

    if ! rm -rf "$BUNDLE_CASE_ROOT"; then
        printf '    FAIL: unable to reset the isolated bundle fixture\n'
        mark_test_failure
        return 1
    fi
    if ! mkdir -p "$BUNDLE_HOME/.config" "$BUNDLE_HOME/.ssh" "$BUNDLE_HOME/work" \
        "$BUNDLE_REPO_DIR" "$BUNDLE_VAULT_DIR" "$BUNDLE_RUNTIME_DIR" \
        "$BUNDLE_HOME/AppData/Roaming" "$BUNDLE_HOME/AppData/Local"; then
        printf '    FAIL: unable to create the isolated bundle fixture\n'
        mark_test_failure
        return 1
    fi
    if ! printf '%s\n' '[user]' '    name = Bundle User' \
        '    email = bundle@example.com' > "$BUNDLE_HOME/.gitconfig"; then
        printf '    FAIL: unable to seed the isolated Git identity\n'
        mark_test_failure
        return 1
    fi
    if ! chmod 700 "$BUNDLE_HOME/.ssh" "$BUNDLE_RUNTIME_DIR" \
        "$BUNDLE_VAULT_DIR"; then
        printf '    FAIL: unable to secure the isolated bundle fixture\n'
        mark_test_failure
        return 1
    fi
    if ! chmod 600 "$BUNDLE_HOME/.gitconfig"; then
        printf '    FAIL: unable to secure the isolated Git identity\n'
        mark_test_failure
        return 1
    fi

    # The standalone child is a new Bash process, so shell-function shims are
    # supplied through BASH_ENV rather than by modifying the artifact.  This
    # keeps Windows reparse checks hermetic and avoids spawning fsutil for every
    # ordinary temporary-path component.
    : > "$BUNDLE_BASH_ENV"
    if bundle_is_windows_shell; then
        cat > "$BUNDLE_BASH_ENV" <<'BUNDLE_WINDOWS_TEST_ENV'
cygpath() {
    printf '%s' "${!#}"
}
fsutil.exe() {
    return 1
}
BUNDLE_WINDOWS_TEST_ENV
    fi
    bundle_export_fixture_environment
    return 0
}

bundle_seed_global_key() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        skip_test "bundle configured-state fixture" "ssh-keygen is unavailable for valid Ed25519 fixtures"
        BUNDLE_FIXTURE_SKIPPED=1
        return 1
    fi
    if ! ssh-keygen -q -t ed25519 -N '' -C 'bundle@example.com' \
        -f "$BUNDLE_KEY_GLOBAL" >/dev/null 2>&1; then
        skip_test "bundle configured-state fixture" "ssh-keygen could not create an Ed25519 keypair"
        BUNDLE_FIXTURE_SKIPPED=1
        return 1
    fi
    assert_file_exists "$BUNDLE_KEY_GLOBAL" "fixture creates the global private key" || return 1
    assert_file_exists "$BUNDLE_KEY_GLOBAL.pub" "fixture creates the global public key" || return 1
    return 0
}

bundle_prepare_base() {
    BUNDLE_FIXTURE_SKIPPED=0
    bundle_reset_fixture || return 1
    if ! bundle_require_command git "bundle fixture"; then
        return 0
    fi
    if ! bundle_seed_global_key; then
        return 0
    fi
    return 0
}

# These snapshots contain only state produced by prior real bundle invocations.
# Restoring one avoids repeating slow key generation for every command while
# each case still runs the copied artifact in a fresh process and isolated HOME.
bundle_cache_base_state() {
    if ! rm -rf "$BUNDLE_BASE_SNAPSHOT_DIR"; then
        printf '    FAIL: unable to reset the setup-state snapshot\n'
        mark_test_failure
        return 1
    fi
    if ! mkdir -p "$BUNDLE_BASE_SNAPSHOT_DIR" || \
        ! cp -pR "$BUNDLE_HOME/." "$BUNDLE_BASE_SNAPSHOT_DIR/"; then
        printf '    FAIL: unable to snapshot the setup isolated state\n'
        mark_test_failure
        return 1
    fi
    BUNDLE_BASE_READY=1
    return 0
}

bundle_restore_base_state() {
    if [[ ! -d "$BUNDLE_BASE_SNAPSHOT_DIR" ]]; then
        printf '    FAIL: setup-state snapshot is missing\n'
        mark_test_failure
        return 1
    fi
    if ! rm -rf "$BUNDLE_HOME" "$BUNDLE_VAULT_DIR" "$BUNDLE_RUNTIME_DIR"; then
        printf '    FAIL: unable to reset the setup isolated state\n'
        mark_test_failure
        return 1
    fi
    if ! mkdir -p "$BUNDLE_HOME" "$BUNDLE_VAULT_DIR" "$BUNDLE_RUNTIME_DIR"; then
        printf '    FAIL: unable to recreate the setup isolated state\n'
        mark_test_failure
        return 1
    fi
    if ! cp -pR "$BUNDLE_BASE_SNAPSHOT_DIR/." "$BUNDLE_HOME/"; then
        printf '    FAIL: unable to restore the setup isolated state\n'
        mark_test_failure
        return 1
    fi
    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    BUNDLE_BIN_DIR=""
    BUNDLE_CONFIGURED_READY=0
    bundle_export_fixture_environment
    return 0
}

bundle_cache_current_state() {
    if ! rm -rf "$BUNDLE_SNAPSHOT_DIR"; then
        printf '    FAIL: unable to reset the configured-state snapshot\n'
        mark_test_failure
        return 1
    fi
    if ! mkdir -p "$BUNDLE_SNAPSHOT_DIR" || \
        ! cp -pR "$BUNDLE_HOME/." "$BUNDLE_SNAPSHOT_DIR/"; then
        printf '    FAIL: unable to snapshot the configured isolated state\n'
        mark_test_failure
        return 1
    fi
    BUNDLE_CONFIGURED_READY=1
    return 0
}

bundle_restore_configured_state() {
    if [[ ! -d "$BUNDLE_SNAPSHOT_DIR" ]]; then
        printf '    FAIL: configured-state snapshot is missing\n'
        mark_test_failure
        return 1
    fi
    if ! rm -rf "$BUNDLE_HOME" "$BUNDLE_VAULT_DIR" "$BUNDLE_RUNTIME_DIR"; then
        printf '    FAIL: unable to reset the configured isolated state\n'
        mark_test_failure
        return 1
    fi
    if ! mkdir -p "$BUNDLE_HOME" "$BUNDLE_VAULT_DIR" "$BUNDLE_RUNTIME_DIR"; then
        printf '    FAIL: unable to recreate the configured isolated state\n'
        mark_test_failure
        return 1
    fi
    if ! cp -pR "$BUNDLE_SNAPSHOT_DIR/." "$BUNDLE_HOME/"; then
        printf '    FAIL: unable to restore the configured isolated state\n'
        mark_test_failure
        return 1
    fi
    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    BUNDLE_BIN_DIR=""
    bundle_export_fixture_environment
    return 0
}

bundle_prepare_configured() {
    BUNDLE_FIXTURE_SKIPPED=0
    if [[ "$BUNDLE_CONFIGURED_READY" -eq 1 ]]; then
        bundle_restore_configured_state || return 1
        return 0
    fi
    if [[ "$BUNDLE_BASE_READY" -eq 1 ]]; then
        bundle_restore_base_state || return 1
    else
        if ! bundle_prepare_base; then
            return 1
        fi
        if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
            return 0
        fi
        bundle_invoke setup --auto
        bundle_assert_ok "bundle setup --auto succeeds" || return 1
        assert_contains "$BUNDLE_OUTPUT" "Setup Complete" "bundle setup --auto reports completion" || return 1
        bundle_cache_base_state || return 1
    fi
    bundle_invoke add work "Work User" "work@example.com" "$BUNDLE_HOME/work"
    assert_equals "0" "$BUNDLE_STATUS" "bundle add creates a second profile" || return 1
    assert_contains "$BUNDLE_OUTPUT" "work@example.com" "bundle add reports the new profile" || return 1
    bundle_cache_current_state || return 1
    return 0
}

bundle_encode_ascii() {
    local value="$1"
    local char hex output=""
    local i
    local LC_ALL=C

    for (( i=0; i<${#value}; i++ )); do
        char="${value:i:1}"
        printf -v hex '%02X' "'$char"
        output="${output}%${hex}"
    done
    printf '%s' "$output"
}

bundle_valid_encoded_field() {
    local field="$1"
    [[ -z "$field" || "$field" =~ ^%[0-9A-F]{2}(%[0-9A-F]{2})*$ ]] &&
        [[ "$field" != *"%00"* ]]
}

# The registry is read once by this shell loop; awk only counts fields in the
# current line.  ShellCheck cannot prove that the read-only pipeline is safe.
# shellcheck disable=SC2094
bundle_assert_registry_v2() {
    local registry="${1:-$BUNDLE_REGISTRY}"
    local line field_count field
    local line_number=0 records=0 malformed=0
    local field1 field2 field3 field4 field5 field6 extra

    assert_file_exists "$registry" "strict v2 registry exists" || return 1
    assert_file_contains "$registry" "# gitsetu-registry-v2" "registry has the v2 header" || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if [[ "$line_number" -eq 1 ]]; then
            [[ "$line" == "# gitsetu-registry-v2" ]] || malformed=1
            continue
        fi
        [[ -n "$line" ]] || { malformed=1; continue; }
        field_count=$(awk -F: -v wanted="$line_number" 'NR == wanted { print NF; exit }' "$registry") || malformed=1
        if [[ "$field_count" != "6" ]]; then
            malformed=1
            continue
        fi
        IFS=: read -r field1 field2 field3 field4 field5 field6 extra <<< "$line"
        [[ -z "${extra:-}" ]] || malformed=1
        for field in "$field1" "$field2" "$field3" "$field4" "$field5" "$field6"; do
            bundle_valid_encoded_field "$field" || malformed=1
        done
        records=$((records + 1))
    done < "$registry"

    assert_equals "0" "$malformed" "registry records use the strict six-field envelope" || return 1
    [[ "$records" -gt 0 ]] || {
        printf '    FAIL: strict registry contains no profile records\n'
        mark_test_failure
        return 1
    }
    return 0
}

bundle_registry_has_label() {
    local label="$1"
    local registry="${2:-$BUNDLE_REGISTRY}"
    local encoded

    encoded=$(bundle_encode_ascii "$label") || return 1
    grep -qF -e "${encoded}:" "$registry"
}

bundle_registry_profile_count() {
    local registry="${1:-$BUNDLE_REGISTRY}"
    awk 'NR > 1 { count++ } END { print count + 0 }' "$registry"
}

bundle_init_repo() {
    if ! git -C "$BUNDLE_REPO_DIR" init --quiet; then
        printf '    FAIL: unable to initialize the mapped Git repository fixture\n'
        mark_test_failure
        return 1
    fi
    return 0
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

bundle_setup_auto_writes_state() {
    if ! bundle_prepare_base; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi

    bundle_invoke setup --auto
    assert_equals "0" "$BUNDLE_STATUS" "bundle setup --auto succeeds in isolation" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Zero-Prompt Auto-Discovery Blueprint" "setup uses the standalone auto path" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Setup Complete" "setup reports completion" || return 1
    assert_contains "$BUNDLE_OUTPUT" "bundle@example.com" "setup preserves the discovered identity" || return 1
    assert_file_exists "$BUNDLE_REGISTRY" "setup writes profiles.conf" || return 1
    assert_file_exists "$BUNDLE_PROFILES_DIR/global.gitconfig" "setup writes the global profile config" || return 1
    assert_file_contains "$BUNDLE_REGISTRY" "# gitsetu-registry-v2" "setup writes a v2 registry" || return 1
    assert_file_contains "$BUNDLE_PROFILES_DIR/global.gitconfig" "bundle@example.com" "profile config contains the identity" || return 1
    assert_file_contains "$BUNDLE_HOME/.gitconfig" "# [gitsetu:managed:start]" "setup writes a managed Git block" || return 1
    assert_file_exists "$BUNDLE_SSH_CONFIG" "setup writes SSH configuration" || return 1
    assert_file_contains "$BUNDLE_SSH_CONFIG" "Include" "SSH configuration contains the managed include" || return 1
    assert_file_exists "$BUNDLE_KEY_GLOBAL" "setup retains the fixture key" || return 1
    bundle_cache_base_state || return 1
    bundle_assert_registry_v2 || return 1
    assert_equals "1" "$(bundle_registry_profile_count)" "setup creates one global registry record" || return 1
    assert_dir_not_exists "$BUNDLE_RUN_DIR/lib" "configured setup still has no source lib/ tree" || return 1
}

bundle_add_remove_status_prompt_run() {
    BUNDLE_FIXTURE_SKIPPED=0
    if [[ "$BUNDLE_BASE_READY" -eq 1 ]]; then
        bundle_restore_base_state || return 1
    else
        if ! bundle_prepare_base; then
            return 1
        fi
        if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
            return 0
        fi
        bundle_invoke setup --auto
        assert_equals "0" "$BUNDLE_STATUS" "setup succeeds before add lifecycle" || return 1
        bundle_cache_base_state || return 1
    fi

    bundle_invoke add work "Work User" "work@example.com" "$BUNDLE_HOME/work"
    assert_equals "0" "$BUNDLE_STATUS" "bundle add succeeds" || return 1
    assert_contains "$BUNDLE_OUTPUT" "work@example.com" "add output identifies the profile" || return 1
    assert_file_exists "$BUNDLE_PROFILES_DIR/work.gitconfig" "add writes the profile config" || return 1
    assert_file_exists "$BUNDLE_KEY_WORK" "add creates the profile private key" || return 1
    assert_file_exists "$BUNDLE_KEY_WORK.pub" "add creates the profile public key" || return 1
    bundle_assert_registry_v2 || return 1
    assert_equals "2" "$(bundle_registry_profile_count)" "add extends the v2 registry" || return 1
    bundle_cache_current_state || return 1
    bundle_registry_has_label work || {
        mark_test_failure
        return 1
    }

    BUNDLE_CWD="$BUNDLE_REPO_DIR"
    bundle_invoke prompt
    assert_equals "0" "$BUNDLE_STATUS" "prompt succeeds in the mapped repository" || return 1
    assert_equals "work" "$BUNDLE_OUTPUT" "prompt returns the longest matching profile" || return 1
    bundle_invoke status
    assert_equals "0" "$BUNDLE_STATUS" "status succeeds in the mapped repository" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Directory context: work" "status reports the mapped context" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Configured Profiles" "status renders configured profiles" || return 1
    assert_contains "$BUNDLE_OUTPUT" "work@example.com" "status renders the added identity" || return 1

    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    # The single quotes are intentional: the child command must observe these
    # environment variables after gitsetu has exported them.
    # shellcheck disable=SC2016
    bundle_invoke run work -- bash -c 'printf "%s|%s|%s|%s" "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "$GIT_COMMITTER_EMAIL" "$GIT_SSH_COMMAND"'
    assert_equals "0" "$BUNDLE_STATUS" "run executes a command under the selected profile" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Work User|work@example.com|work@example.com" "run exports the selected identity" || return 1
    assert_contains "$BUNDLE_OUTPUT" "$BUNDLE_KEY_WORK" "run exports the selected SSH key" || return 1

    bundle_invoke remove work --force
    assert_equals "0" "$BUNDLE_STATUS" "remove deletes the selected profile" || return 1
    assert_contains "$BUNDLE_OUTPUT" "successfully removed" "remove reports success" || return 1
    assert_file_exists "$BUNDLE_KEY_WORK" "remove preserves private keys by default" || return 1
    assert_file_exists "$BUNDLE_KEY_WORK.pub" "remove preserves public keys by default" || return 1
    bundle_assert_registry_v2 || return 1
    assert_equals "1" "$(bundle_registry_profile_count)" "remove leaves the mandatory global record" || return 1
    if bundle_registry_has_label work; then
        mark_test_failure
        return 1
    fi

    BUNDLE_CWD="$BUNDLE_REPO_DIR"
    bundle_invoke prompt
    assert_equals "" "$BUNDLE_OUTPUT" "prompt emits no label after profile removal" || return 1
    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    bundle_invoke status
    assert_equals "0" "$BUNDLE_STATUS" "status remains safe after profile removal" || return 1
    assert_not_contains "$BUNDLE_OUTPUT" "work@example.com" "status no longer renders the removed identity" || return 1
}

bundle_guard_uninstall_restores_policy() {
    if ! bundle_require_command git "bundle guard uninstall"; then
        return 0
    fi
    if ! bundle_reset_fixture; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi

    mkdir -p "$BUNDLE_HOOKS_DIR" "$BUNDLE_CASE_ROOT/previous-hooks"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$BUNDLE_HOOKS_DIR/pre-commit"
    printf '%s\n' "$BUNDLE_CASE_ROOT/previous-hooks" > "$BUNDLE_HOOKS_DIR/.previous-hooks-path"
    if ! git config --file "$BUNDLE_HOME/.gitconfig" core.hooksPath "$BUNDLE_HOOKS_DIR"; then
        printf '    FAIL: unable to seed the prior core.hooksPath policy\n'
        mark_test_failure
        return 1
    fi

    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    bundle_invoke guard --uninstall
    assert_equals "0" "$BUNDLE_STATUS" "bundle guard --uninstall succeeds" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Removed guard hook" "guard uninstall removes the hook" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Restored prior core.hooksPath" "guard uninstall restores the prior policy" || return 1
    assert_file_not_exists "$BUNDLE_HOOKS_DIR/pre-commit" "guard uninstall removes the installed hook" || return 1
    assert_file_not_exists "$BUNDLE_HOOKS_DIR/.previous-hooks-path" "guard uninstall clears saved hook state" || return 1
    local restored_path=""
    restored_path=$(git config --file "$BUNDLE_HOME/.gitconfig" --get core.hooksPath 2>/dev/null || true)
    assert_equals "$BUNDLE_CASE_ROOT/previous-hooks" "$restored_path" "core.hooksPath is restored exactly" || return 1
}

bundle_guard_install_is_explicitly_skipped_for_standalone() {
    if ! bundle_require_command git "bundle guard --install"; then
        return 0
    fi
    if ! bundle_reset_fixture; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi

    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    bundle_invoke guard --install
    if [[ "$BUNDLE_STATUS" -eq 0 ]]; then
        assert_contains "$BUNDLE_OUTPUT" "Guard hook installed" "standalone guard install reports installation" || return 1
        assert_file_exists "$BUNDLE_HOOKS_DIR/pre-commit" "standalone guard install writes a hook when supported" || return 1
        bundle_invoke guard --uninstall
        assert_equals "0" "$BUNDLE_STATUS" "standalone guard uninstall follows a successful install" || return 1
        return 0
    fi
    if [[ "$BUNDLE_OUTPUT" == *"canonical regular-file GitSetu library root"* ]]; then
        skip_test "bundle guard --install" \
            "persistent hook installation requires a canonical lib/ checkout; a single-file artifact has no hermetic library tree"
        return 0
    fi

    printf '    FAIL: guard --install failed for an unexpected reason\n'
    printf '%s\n' "$BUNDLE_OUTPUT" >&2
    mark_test_failure
    return 1
}

bundle_verify_validates_isolated_state() {
    if ! bundle_prepare_configured; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi
    bundle_init_repo || return 1

    BUNDLE_CWD="$BUNDLE_REPO_DIR"
    bundle_invoke verify
    assert_equals "0" "$BUNDLE_STATUS" "verify succeeds for an isolated valid state" || return 1
    assert_contains "$BUNDLE_OUTPUT" "SSH key files, permissions, and key pairs are valid." "verify checks key pairs" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Git configuration and effective identities are valid." "verify checks effective identity" || return 1
    assert_contains "$BUNDLE_OUTPUT" "SKIPPED: network checks are opt-in" "verify keeps network checks explicitly skipped" || return 1
    assert_contains "$BUNDLE_OUTPUT" "All required offline checks passed!" "verify reports offline success" || return 1
}

bundle_doctor_validates_isolated_state() {
    if ! bundle_require_command ssh "bundle doctor"; then
        return 0
    fi
    if ! bundle_prepare_configured; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi
    bundle_init_repo || return 1

    BUNDLE_CWD="$BUNDLE_REPO_DIR"
    bundle_invoke doctor
    assert_equals "0" "$BUNDLE_STATUS" "doctor succeeds for an isolated valid state" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Active Profile: work" "doctor resolves the mapped profile" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Registry: OK (2 profile(s))" "doctor validates the strict registry" || return 1
    assert_contains "$BUNDLE_OUTPUT" "All required offline diagnostics passed." "doctor reports offline success" || return 1
}

bundle_backup_restore_round_trip() {
    if ! bundle_require_vault_tools; then
        return 0
    fi
    if ! bundle_prepare_configured; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi

    # This product test hook supplies a non-interactive password while the
    # command still performs the real v2 encryption, authentication, and
    # transactional restore.  It is used only inside this isolated fixture.
    export GITSETU_TEST_VAULT_MODE=1
    export GITSETU_TEST_VAULT_PASS='bundle-contract-password-123'
    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    bundle_invoke backup "$BUNDLE_VAULT_DIR/bundle.vault"
    assert_equals "0" "$BUNDLE_STATUS" "bundle backup creates a vault" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Authenticated v2 vault created successfully" "backup reports authenticated v2 creation" || return 1
    assert_file_exists "$BUNDLE_VAULT_DIR/bundle.vault" "backup installs the requested vault path" || return 1

    bundle_invoke teardown --force
    assert_equals "0" "$BUNDLE_STATUS" "teardown removes state before restore" || return 1
    assert_contains "$BUNDLE_OUTPUT" "teardown complete" "teardown reports completion" || return 1
    assert_dir_not_exists "$BUNDLE_CONFIG_DIR" "teardown removes the managed config root" || return 1
    assert_file_exists "$BUNDLE_HOME/.gitconfig" "teardown preserves the user Git config" || return 1
    assert_file_contains "$BUNDLE_HOME/.gitconfig" "bundle@example.com" "teardown preserves user identity content" || return 1
    assert_file_not_contains "$BUNDLE_HOME/.gitconfig" "# [gitsetu:managed:start]" "teardown removes the managed Git block" || return 1
    assert_file_exists "$BUNDLE_KEY_GLOBAL" "teardown preserves the global private key" || return 1
    assert_file_exists "$BUNDLE_KEY_WORK" "teardown preserves the work private key" || return 1
    bundle_invoke restore "$BUNDLE_VAULT_DIR/bundle.vault"
    assert_equals "0" "$BUNDLE_STATUS" "bundle restore succeeds from the standalone artifact" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Authenticated v2 vault restored successfully" "restore reports successful authentication" || return 1
    assert_file_exists "$BUNDLE_REGISTRY" "restore reinstalls the registry" || return 1
    assert_file_exists "$BUNDLE_PROFILES_DIR/work.gitconfig" "restore reinstalls profile configs" || return 1
    assert_file_exists "$BUNDLE_KEY_GLOBAL" "restore reinstalls the global key" || return 1
    assert_file_exists "$BUNDLE_KEY_WORK" "restore reinstalls the work key" || return 1
    assert_file_contains "$BUNDLE_HOME/.gitconfig" "# [gitsetu:managed:start]" "restore regenerates managed Git configuration" || return 1
    bundle_assert_registry_v2 || return 1
    assert_equals "2" "$(bundle_registry_profile_count)" "restore preserves both registry profiles" || return 1
}

bundle_credential_paths_are_isolated() {
    if ! bundle_prepare_configured; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi

    export GITSETU_CREDENTIAL_BACKEND=file
    BUNDLE_CWD="$BUNDLE_REPO_DIR"
    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-a\nusername=alice\npassword=alice-secret\n\n' credential store
    assert_equals "0" "$BUNDLE_STATUS" "bundle stores the first path-scoped credential" || return 1
    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-b\nusername=bob\npassword=bob-secret\n\n' credential store
    assert_equals "0" "$BUNDLE_STATUS" "bundle stores the second path-scoped credential" || return 1

    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-a\n\n' credential get
    assert_equals "0" "$BUNDLE_STATUS" "bundle reads the first path-scoped credential" || return 1
    assert_contains "$BUNDLE_OUTPUT" "username=alice" "first path resolves its own username" || return 1
    assert_not_contains "$BUNDLE_OUTPUT" "bob-secret" "first path does not expose the second secret" || return 1

    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-b\n\n' credential get
    assert_equals "0" "$BUNDLE_STATUS" "bundle reads the second path-scoped credential" || return 1
    assert_contains "$BUNDLE_OUTPUT" "username=bob" "second path resolves its own username" || return 1
    assert_not_contains "$BUNDLE_OUTPUT" "alice-secret" "second path does not expose the first secret" || return 1

    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-a\n\n' credential erase
    assert_equals "0" "$BUNDLE_STATUS" "bundle erases only the selected path" || return 1
    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-a\n\n' credential get
    assert_equals "1" "$BUNDLE_STATUS" "erased path is absent" || return 1
    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-b\n\n' credential get
    assert_equals "0" "$BUNDLE_STATUS" "other path survives selected-path erase" || return 1
    assert_contains "$BUNDLE_OUTPUT" "username=bob" "other path remains readable after erase" || return 1

    bundle_invoke_input $'protocol=https\nhost=github.com\npath=/repo-b\n\n' credential erase
    unset GITSETU_CREDENTIAL_BACKEND
    return 0
}

bundle_registry_rejects_legacy_format() {
    if ! bundle_require_command git "bundle registry contract"; then
        return 0
    fi
    if ! bundle_reset_fixture; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi
    mkdir -p "$BUNDLE_PROFILES_DIR"
    printf '%s\n' '# legacy seven-field registry' \
        "global::$BUNDLE_HOME/work:github.com:0:$BUNDLE_KEY_GLOBAL:legacy_user" \
        > "$BUNDLE_REGISTRY"

    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    bundle_invoke status
    assert_equals "1" "$BUNDLE_STATUS" "the standalone artifact rejects a legacy registry" || return 1
    assert_contains "$BUNDLE_OUTPUT" "invalid or uses an unsupported format" "registry rejection names the unsupported format" || return 1
}

bundle_lock_holder_pid=""

bundle_stop_lock_holder() {
    if [[ -n "$bundle_lock_holder_pid" ]]; then
        kill "$bundle_lock_holder_pid" 2>/dev/null || true
        wait "$bundle_lock_holder_pid" 2>/dev/null || true
        bundle_lock_holder_pid=""
    fi
    rm -rf "$BUNDLE_LOCK_DIR"
}

bundle_hold_runtime_lock() {
    local process_start=""
    local token="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    sleep 15 &
    bundle_lock_holder_pid=$!
    if ! mkdir "$BUNDLE_LOCK_DIR" 2>/dev/null; then
        bundle_stop_lock_holder
        printf '    FAIL: unable to create the concurrency lock fixture\n'
        mark_test_failure
        return 1
    fi
    chmod 700 "$BUNDLE_LOCK_DIR" 2>/dev/null || true
    process_start=$(ps -p "$bundle_lock_holder_pid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)
    printf '%s\n' "$bundle_lock_holder_pid" > "$BUNDLE_LOCK_DIR/pid"
    printf '%s\n' "$token" > "$BUNDLE_LOCK_DIR/token"
    printf '%s\n' "$process_start" > "$BUNDLE_LOCK_DIR/process_start"
    date +%s > "$BUNDLE_LOCK_DIR/timestamp"
    return 0
}

bundle_concurrent_registry_mutations_serialize() {
    local output="$BUNDLE_CASE_ROOT/concurrent-add.out"
    local read_output_one="$BUNDLE_CASE_ROOT/concurrent-status-one.out"
    local read_output_two="$BUNDLE_CASE_ROOT/concurrent-status-two.out"
    local read_pid_one="" read_pid_two="" read_rc_one=0 read_rc_two=0

    if ! bundle_prepare_configured; then
        return 1
    fi
    if [[ "$BUNDLE_FIXTURE_SKIPPED" -ne 0 ]]; then
        return 0
    fi
    if ! bundle_hold_runtime_lock; then
        return 1
    fi
    export GITSETU_LOCK_TIMEOUT=1
    BUNDLE_CWD="$BUNDLE_RUN_DIR"
    bundle_invoke add blocked "Blocked User" "blocked@example.com" "$BUNDLE_HOME/blocked"
    bundle_stop_lock_holder
    unset GITSETU_LOCK_TIMEOUT

    assert_equals "1" "$BUNDLE_STATUS" "a concurrent registry mutation fails closed while the lock is held" || return 1
    assert_contains "$BUNDLE_OUTPUT" "Failed to acquire lock" "lock contention is reported explicitly" || return 1
    assert_dir_not_exists "$BUNDLE_LOCK_DIR" "the externally held lock is cleaned up by the fixture" || return 1
    bundle_assert_registry_v2 || return 1
    assert_equals "2" "$(bundle_registry_profile_count)" "lock contention leaves the registry unchanged" || return 1
    bundle_registry_has_label work || {
        mark_test_failure
        return 1
    }
    if bundle_registry_has_label blocked; then
        mark_test_failure
        return 1
    fi

    # Two independent real artifact invocations also read the same registry
    # concurrently, proving the persisted state remains consumable after the
    # failed writer exits.
    bundle_start "$read_output_one" status
    read_pid_one="$BUNDLE_BACKGROUND_PID"
    bundle_start "$read_output_two" status
    read_pid_two="$BUNDLE_BACKGROUND_PID"
    wait "$read_pid_one" || read_rc_one=$?
    wait "$read_pid_two" || read_rc_two=$?
    assert_equals "0" "$read_rc_one" "first concurrent registry reader succeeds" || return 1
    assert_equals "0" "$read_rc_two" "second concurrent registry reader succeeds" || return 1
    assert_contains "$(cat "$read_output_one")" "Configured Profiles" "first reader renders the registry" || return 1
    assert_contains "$(cat "$read_output_two")" "Configured Profiles" "second reader renders the registry" || return 1
    assert_equals "2" "$(bundle_registry_profile_count)" "concurrent readers do not alter the registry" || return 1
    return 0
}

bundle_artifact_remains_exact() {
    assert_file_exists "$BUNDLE_COPY" "the copied bundle still exists after all invocations" || return 1
    assert_exit_code 0 cmp -s "$BUNDLE_PATH" "$BUNDLE_COPY"
    assert_dir_not_exists "$BUNDLE_RUN_DIR/lib" "all invocations remained standalone" || return 1
}

run_test "copy exact supplied bundle" copy_exact_artifact
run_test "bundle --version" bundle_version_works
run_test "bundle --help" bundle_help_works
run_test "bundle status in isolation" bundle_status_works_without_source_tree
run_test "bundle verify fails closed when unconfigured" bundle_verify_fails_closed_without_profiles
run_test "bundle guard uninstall restores prior hooks policy" bundle_guard_uninstall_restores_policy
run_test "bundle guard install capability" bundle_guard_install_is_explicitly_skipped_for_standalone
run_test "bundle setup --auto writes isolated state" bundle_setup_auto_writes_state
run_test "bundle add/remove/status/prompt/run lifecycle" bundle_add_remove_status_prompt_run
run_test "bundle verify validates isolated state" bundle_verify_validates_isolated_state
run_test "bundle doctor validates isolated state" bundle_doctor_validates_isolated_state
run_test "bundle backup/restore round trip" bundle_backup_restore_round_trip
run_test "bundle credential paths are isolated" bundle_credential_paths_are_isolated
run_test "bundle rejects concurrent registry mutation while locked" bundle_concurrent_registry_mutations_serialize
run_test "bundle rejects legacy registry format" bundle_registry_rejects_legacy_format
run_test "copied bundle remains byte-for-byte exact" bundle_artifact_remains_exact
print_results "Bundle contract tests"
