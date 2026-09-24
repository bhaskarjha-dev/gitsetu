#!/usr/bin/env bash
# tests/test_prompt.sh — Prompt routing tests for the strict v2 registry
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home
source_gitsetu_libs

GITSETU_EXE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

write_prompt_registry() {
    local global_key work_key work_dir
    global_key=$(normalize_path "$HOME/.ssh/id_ed25519_global")
    work_key=$(normalize_path "$HOME/.ssh/id_ed25519_work")
    work_dir=$(normalize_path "$HOME/work")

    PROFILE_COUNT=3
    PROFILE_LABELS=(global work freelance)
    PROFILE_NAMES=("Global User" "Work User" "Freelance User")
    PROFILE_EMAILS=(global@example.com work@example.com freelance@example.com)
    PROFILE_DIRS=("" "$work_dir" "$work_dir/freelance")
    PROFILE_PROVIDERS=(github.com github.com github.com)
    PROFILE_SIGNS=(0 0 0)
    PROFILE_KEYS=("$global_key" "$work_key" "$work_key")
    PROFILE_USERS=("" "" "")
    PROFILE_PATS=("" "" "")
    mkdir -p "$GITSETU_PROFILES_DIR"
    printf '[user]\n    name = Global User\n    email = global@example.com\n' > "$GITSETU_PROFILES_DIR/global.gitconfig"
    printf '[user]\n    name = Work User\n    email = work@example.com\n' > "$GITSETU_PROFILES_DIR/work.gitconfig"
    printf '[user]\n    name = Freelance User\n    email = freelance@example.com\n' > "$GITSETU_PROFILES_DIR/freelance.gitconfig"
    {
        test_v2_registry_header
        test_v2_registry_line global "" "github.com" "0" "$global_key" ""
        test_v2_registry_line work "$work_dir" "github.com" "0" "$work_key" ""
        test_v2_registry_line freelance "$work_dir/freelance" "github.com" "0" "$work_key" ""
    } > "$GITSETU_PROFILES_CONF"
}

test_prompt_empty_registry() {
    rm -f "$GITSETU_PROFILES_CONF"
    local output
    output=$(bash "$GITSETU_EXE" prompt)
    assert_equals "" "$output" "returns empty string when no registry exists" || return 1
}

test_prompt_v2_longest_match() {
    write_prompt_registry
    mkdir -p "$HOME/work/freelance/ui"
    cd "$HOME/work/freelance/ui"

    local out
    out=$(bash "$GITSETU_EXE" prompt)
    assert_equals "freelance" "$out" "longest v2 profile directory wins" || return 1

    mkdir -p "$HOME/work/api"
    cd "$HOME/work/api"
    out=$(bash "$GITSETU_EXE" prompt)
    assert_equals "work" "$out" "parent v2 profile matches nested repository" || return 1

    mkdir -p "$HOME/personal"
    cd "$HOME/personal"
    out=$(bash "$GITSETU_EXE" prompt)
    assert_equals "" "$out" "unmapped directory has no active profile" || return 1
}

# ------------------------------------------------------------------------------
# Mixed MSYS/Git Bash HOME/XDG/current-directory context
# ------------------------------------------------------------------------------
test_prompt_mixed_windows_home_and_xdg_context() {
    case "${GITSETU_OS:-}:${OSTYPE:-}" in
        gitbash:*|cygwin:*|msys:*|mingw:*) ;;
        *) skip_test "prompt mixed Windows HOME/XDG context" "requires an MSYS/Git Bash environment"; return 0 ;;
    esac

    write_prompt_registry
    local original_xdg="${XDG_CONFIG_HOME:-$HOME/.config}"
    local original_pwd="$PWD"
    local mixed_home="/tmp/gitsetu-prompt-mixed-home.$$"
    mkdir -p "$HOME/work/freelance/ui"
    cd "$HOME/work/freelance/ui" || return 1

    local output real_pwd mixed_pwd_bin mixed_pwd_path windows_pwd
    real_pwd=$(command -v pwd)
    mixed_pwd_bin="$TEST_HOME/mixed-pwd-bin"
    rm -rf "$mixed_pwd_bin"
    mkdir -p "$mixed_pwd_bin"
    windows_pwd=$(cygpath -m "$HOME/work/freelance/ui")
    cat > "$mixed_pwd_bin/pwd" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-W" ]]; then
    printf '%s\\n' '$windows_pwd'
    exit 0
fi
if [[ "\${1:-}" == "-P" ]]; then
    printf '%s\\n' '/tmp'
    exit 0
fi
exec '$real_pwd' "\$@"
EOF
    chmod +x "$mixed_pwd_bin/pwd"
    mixed_pwd_path="$mixed_pwd_bin"
    if command -v cygpath >/dev/null 2>&1; then mixed_pwd_path=$(cygpath -u "$mixed_pwd_bin"); fi
    output=$(HOME="$mixed_home" XDG_CONFIG_HOME="$original_xdg" GITSETU_OS=gitbash \
        PATH="$mixed_pwd_path:$PATH" bash "$GITSETU_EXE" prompt)
    rm -rf "$mixed_pwd_bin"
    cd "$original_pwd" || return 1
    assert_equals "freelance" "$output" "MSYS prompt context uses pwd -W despite POSIX HOME" || return 1
}

# ------------------------------------------------------------------------------
# Legacy registry remains unsupported
# ------------------------------------------------------------------------------
test_prompt_rejects_legacy_registry() {
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    cat > "$GITSETU_PROFILES_CONF" <<EOF
work:work@example.com:$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:
EOF
    mkdir -p "$HOME/work/repo"
    cd "$HOME/work/repo"
    local output
    output=$(bash "$GITSETU_EXE" prompt)
    assert_equals "" "$output" "legacy unversioned registry is not interpreted" || return 1
}

test_prompt_rejects_malformed_v2_record() {
    write_prompt_registry
    printf '%s\n' 'not-a-valid-v2-record' >> "$GITSETU_PROFILES_CONF"
    mkdir -p "$HOME/work/repo"
    cd "$HOME/work/repo"
    local output
    output=$(bash "$GITSETU_EXE" prompt)
    assert_equals "" "$output" "a malformed v2 record suppresses prompt output" || return 1
}

test_prompt_rejects_noncanonical_key_path() {
    write_prompt_registry
    local encoded_label encoded_dir encoded_provider encoded_sign encoded_key encoded_user bad_key
    encoded_label=$(escape_registry_field work)
    encoded_dir=$(escape_registry_field "$HOME/work")
    encoded_provider=$(escape_registry_field github.com)
    encoded_sign=$(escape_registry_field 0)
    bad_key=$(escape_registry_field "$HOME/.ssh/../outside")
    encoded_user=$(escape_registry_field "")
    {
        printf '%s\n' '# gitsetu-registry-v2'
        printf '%s:%s:%s:%s:%s:%s\n' \
            "$encoded_label" "$encoded_dir" "$encoded_provider" "$encoded_sign" "$bad_key" "$encoded_user"
    } > "$GITSETU_PROFILES_CONF"
    mkdir -p "$HOME/work/repo"
    cd "$HOME/work/repo"
    local output
    output=$(bash "$GITSETU_EXE" prompt)
    assert_equals "" "$output" "noncanonical key paths suppress prompt output" || return 1
}

test_prompt_rejects_unresolved_profile_identity() {
    write_prompt_registry
    rm -f "$GITSETU_PROFILES_DIR/work.gitconfig"
    mkdir -p "$HOME/work/repo"
    cd "$HOME/work/repo"
    local output
    output=$(bash "$GITSETU_EXE" prompt)
    assert_equals "" "$output" "missing profile identity suppresses prompt output" || return 1
}

printf '\n%btest_prompt.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "prompt empty registry safely" test_prompt_empty_registry
run_test "prompt routes longest v2 directory match" test_prompt_v2_longest_match
run_test "prompt canonicalizes mixed Windows HOME/XDG context" test_prompt_mixed_windows_home_and_xdg_context
run_test "prompt rejects legacy registry without compatibility fallback" test_prompt_rejects_legacy_registry
run_test "prompt rejects malformed v2 records" test_prompt_rejects_malformed_v2_record
run_test "prompt rejects noncanonical key paths" test_prompt_rejects_noncanonical_key_path
run_test "prompt rejects unresolved profile identities" test_prompt_rejects_unresolved_profile_identity
print_results "Prompt tests"
