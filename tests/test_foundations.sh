#!/usr/bin/env bash
# Isolated tests for strict v2 registry, numeric, path, and secure temp helpers.
set -euo pipefail

TEST_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)/gitsetu-foundations.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME/.config/gitsetu/profiles" "$HOME/work" "$HOME/.ssh"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"
source lib/core.sh
source lib/platform.sh
source lib/validate.sh

TESTS_RUN=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        printf '  PASS %s\n' "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FAIL %s\n' "$name"
    fi
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

PRIVATE_MODES_SUPPORTED=0
_mode_probe="$TEST_ROOT/.mode-probe"
: > "$_mode_probe"
chmod 600 "$_mode_probe" 2>/dev/null || true
if [[ "$(file_mode "$_mode_probe")" == 600 ]]; then
    PRIVATE_MODES_SUPPORTED=1
fi
rm -f "$_mode_probe"

test_percent_round_trip() {
    local value=$'colon: backslash\\ percent% tab\t newline\n cr\r'
    local encoded decoded
    encoded=$(escape_registry_field "$value")
    [[ "$encoded" == '%63%6F%6C%6F%6E%3A%20%62%61%63%6B%73%6C%61%73%68%5C%20%70%65%72%63%65%6E%74%25%20%74%61%62%09%20%6E%65%77%6C%69%6E%65%0A%20%63%72%0D' ]]
    decoded=$(unescape_registry_field "$encoded"; printf x)
    decoded=${decoded%x}
    [[ "$decoded" == "$value" ]]
}

test_strict_encoded_fields() {
    validate_registry_field '' || return 1
    validate_registry_field '%6E%6F%74%65%73' || return 1
    ! validate_registry_field 'notes' || return 1
    ! validate_registry_field '%6e%6F%74%65%73' || return 1
    ! validate_registry_field '%6' || return 1
    ! validate_registry_field '%00' || return 1
    ! unescape_registry_field '%GG' || return 1
    validate_registry_line '%77%6F%72%6B::%67%69%74%68%75%62%2E%63%6F%6D:%30:%2F%74%6D%70%2F%6B%65%79:' || return 1
    ! validate_registry_line 'work::github.com:0:/tmp/key' || return 1
    ! validate_registry_line '# gitsetu-registry-v2' || return 1
}

test_safe_numeric_validators() {
    validate_nonnegative_integer 0 || return 1
    validate_nonnegative_integer 42 || return 1
    ! validate_nonnegative_integer 08 || return 1
    ! validate_nonnegative_integer '1+1' || return 1
    # shellcheck disable=SC2016  # Intentionally tests a literal arithmetic expression.
    ! validate_nonnegative_integer 'x[$(printf injected)]' || return 1
    validate_bounded_uint 100 1 1000 || return 1
    ! validate_bounded_uint 99 100 1000 || return 1
    validate_array_index 0 1 || return 1
    validate_array_index 99 100 || return 1
    ! validate_array_index 100 100 || return 1
    ! validate_array_index 0 0 || return 1
    ! validate_array_index 08 10 || return 1
}

test_strict_field_validators() {
    validate_label work-client || return 1
    ! validate_label Work || return 1
    validate_provider github.com || return 1
    ! validate_provider 'github.com:22' || return 1
    validate_sign_flag 0 || return 1
    validate_sign_flag 1 || return 1
    ! validate_sign_flag true || return 1
    validate_provider_user octo-user_1 || return 1
    ! validate_provider_user 'user name' || return 1
    validate_email 'user+tag@example.co.uk' || return 1
    ! validate_email 'user@example.' || return 1
}

test_canonical_paths() {
    local old_os="${GITSETU_OS:-}"
    GITSETU_OS=linux
    local root expected actual
    root=$(normalize_path "$TEST_ROOT") || return 1
    expected=$(pwd -P) || return 1
    actual=$(normalize_path '.') || return 1
    [[ "$actual" == "$expected" ]] || return 1
    actual=$(normalize_path "$root/missing/../work") || return 1
    [[ "$actual" == "$root/work" ]] || return 1
    actual=$(normalize_path '/../../') || return 1
    [[ "$actual" == '/' ]] || return 1

    mkdir -p "$root/real/sub"
    ln -s "$root/real/sub" "$root/link" 2>/dev/null || true
    if [[ -L "$root/link" ]]; then
        actual=$(normalize_path "$root/link/../target") || return 1
        [[ "$actual" == "$root/real/target" ]] || return 1
    fi

    GITSETU_OS=gitbash
    local windows_path
    windows_path=$'d:\\dev\\pro\\'
    [[ $(normalize_path '/c/Users/test/') == 'C:/Users/test' ]] || return 1
    [[ $(normalize_path "$windows_path") == 'D:/dev/pro' ]] || return 1
    local unc_path
    unc_path=$'\\\\server\\share\\project'
    [[ $(normalize_path "$unc_path") == '//server/share/project' ]] || return 1
    GITSETU_OS=wsl
    [[ $(normalize_path 'C:\\work') == '/mnt/c/work' ]] || return 1
    GITSETU_OS="$old_os"
}

test_gitbash_reparse_status_handling() {
    local old_os="${GITSETU_OS:-}"
    GITSETU_OS=gitbash
    local drive_path='C:/Users/example/AppData/Local/Temp'
    if command -v cygpath >/dev/null 2>&1; then
        drive_path=$(cygpath -m "$TEST_ROOT") || return 1
    fi

    local status=0
    _gitsetu_path_has_symlink_component "$drive_path" || status=$?
    [[ "$status" -eq 1 ]] || return 1
    status=0
    _gitsetu_path_has_symlink_component '//server/share' || status=$?
    [[ "$status" -eq 1 ]] || return 1
    status=0
    _gitsetu_path_has_symlink_component 'relative/path' || status=$?
    [[ "$status" -eq 2 ]] || return 1

    if command -v cmd.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        local target="$TEST_ROOT/junction-target"
        local junction="$TEST_ROOT/junction-link"
        local target_win junction_win
        mkdir -p "$target"
        target_win=$(cygpath -w "$target") || return 1
        junction_win=$(cygpath -w "$junction") || return 1
        if cmd.exe //d //c "mklink /J \"$junction_win\" \"$target_win\"" >/dev/null 2>&1; then
            status=0
            _gitsetu_is_reparse_point "$junction" || status=$?
            if [[ "$status" -ne 0 ]]; then
                cmd.exe //d //c "rmdir \"$junction_win\"" >/dev/null 2>&1 || true
                return 1
            fi
            status=0
            _gitsetu_path_has_symlink_component "$junction" || status=$?
            cmd.exe //d //c "rmdir \"$junction_win\"" >/dev/null 2>&1 || true
            [[ "$status" -eq 0 ]] || return 1
        fi
    fi
    GITSETU_OS="$old_os"
}

test_secure_temp_helpers() {
    local file dir mode
    secure_mktemp "$TEST_ROOT/secure-file.XXXXXX" >/dev/null || return 1
    file="$GITSETU_TMP_FILE"
    [[ -f "$file" ]] || return 1
    mode=$(file_mode "$file") || return 1
    if [[ "$PRIVATE_MODES_SUPPORTED" -eq 1 && "$mode" != 600 ]]; then
        return 1
    fi

    secure_mktemp_dir "$TEST_ROOT/secure-dir.XXXXXX" >/dev/null || return 1
    dir="$GITSETU_TMP_DIR"
    [[ -d "$dir" ]] || return 1
    mode=$(file_mode "$dir") || return 1
    if [[ "$PRIVATE_MODES_SUPPORTED" -eq 1 && "$mode" != 700 ]]; then
        return 1
    fi

    secure_mkdir "$TEST_ROOT/private-dir" >/dev/null || return 1
    [[ -d "$GITSETU_PRIVATE_DIR" ]] || return 1
    ! secure_mkdir "$TEST_ROOT/private-dir" >/dev/null || return 1
    cleanup_temp_resources
    [[ ! -e "$file" && ! -e "$dir" && ! -e "$GITSETU_PRIVATE_DIR" ]]
}

test_cleanup_rejects_replaced_paths() {
    local target linked_file linked_dir
    target="$TEST_ROOT/cleanup-target"
    mkdir -p "$target"
    printf '%s\n' 'do-not-delete' > "$target/keep.txt"
    linked_file="$TEST_ROOT/cleanup-file-link"
    linked_dir="$TEST_ROOT/cleanup-dir-link"
    ln -s "$target/keep.txt" "$linked_file" 2>/dev/null || true
    ln -s "$target" "$linked_dir" 2>/dev/null || true
    if [[ -L "$linked_file" ]]; then
        GITSETU_CLEANUP_FILES=("$linked_file")
        GITSETU_CLEANUP_DIRS=()
        if cleanup_temp_resources; then
            return 1
        fi
        [[ -f "$target/keep.txt" ]] || return 1
    fi
    if [[ -L "$linked_dir" ]]; then
        GITSETU_CLEANUP_FILES=()
        GITSETU_CLEANUP_DIRS=("$linked_dir")
        if cleanup_temp_resources; then
            return 1
        fi
        [[ -d "$target" && -f "$target/keep.txt" ]] || return 1
    fi
    GITSETU_CLEANUP_FILES=()
    GITSETU_CLEANUP_DIRS=()
}

test_secure_helpers_reject_redirected_parents() {
    local actual_dir link_dir
    actual_dir="$TEST_ROOT/actual-private"
    link_dir="$TEST_ROOT/linked-private"
    mkdir -p "$actual_dir"
    ln -s "$actual_dir" "$link_dir" 2>/dev/null || true
    if [[ -L "$link_dir" ]]; then
        if secure_mktemp "$link_dir/file.XXXXXX" >/dev/null 2>&1; then
            return 1
        fi
        if secure_mkdir "$link_dir/dir" >/dev/null 2>&1; then
            return 1
        fi
    fi
    return 0
}

populate_v2_profiles() {
    local work key
    work=$(normalize_path "$HOME/work") || return 1
    key=$(normalize_path "$HOME/.ssh/id_ed25519") || return 1
    PROFILE_COUNT=2
    PROFILE_LABELS=(global work)
    PROFILE_NAMES=('Global User' 'Work User')
    PROFILE_EMAILS=(global@example.com work@example.com)
    PROFILE_DIRS=('' "$work")
    PROFILE_PROVIDERS=(github.com github.com)
    PROFILE_SIGNS=(0 1)
    PROFILE_KEYS=("$key" "$key")
    PROFILE_USERS=('' work-user)
    PROFILE_PATS=('' '')
    cat > "$GITSETU_PROFILES_DIR/global.gitconfig" <<'EOF'
[user]
    name = Global User
    email = global@example.com
EOF
    cat > "$GITSETU_PROFILES_DIR/work.gitconfig" <<'EOF'
[user]
    name = Work User
    email = work@example.com
EOF
}

test_registry_write_destination_hardening() {
    populate_v2_profiles || return 1
    local original_config="$GITSETU_PROFILES_CONF"
    local original_root="$GITSETU_CONFIG_DIR"
    local backup="$original_root/profiles.conf.backup-test"
    local had_original=0
    if [[ -f "$original_config" ]]; then
        mv "$original_config" "$backup" || return 1
        had_original=1
    fi

    local redirect="$TEST_ROOT/registry-redirect"
    mkdir -p "$redirect"
    if write_profiles_registry "$redirect/profiles.conf" 2>/dev/null; then
        return 1
    fi
    [[ ! -e "$redirect/profiles.conf" ]] || return 1

    local rogue_root="$TEST_ROOT/rogue-root/gitsetu"
    mkdir -p "$rogue_root"
    GITSETU_CONFIG_DIR="$rogue_root"
    GITSETU_PROFILES_CONF="$rogue_root/profiles.conf"
    if write_profiles_registry 2>/dev/null; then
        GITSETU_CONFIG_DIR="$original_root"
        GITSETU_PROFILES_CONF="$original_config"
        return 1
    fi
    [[ ! -e "$rogue_root/profiles.conf" ]] || return 1
    GITSETU_CONFIG_DIR="$original_root"
    GITSETU_PROFILES_CONF="$original_config"

    mkdir "$original_config" 2>/dev/null || return 1
    if write_profiles_registry 2>/dev/null; then
        rmdir "$original_config" 2>/dev/null || true
        return 1
    fi
    rmdir "$original_config" 2>/dev/null || return 1

    local target="$TEST_ROOT/registry-symlink-target"
    printf '%s\n' 'sentinel' > "$target"
    if ln -s "$target" "$original_config" 2>/dev/null && [[ -L "$original_config" ]]; then
        if write_profiles_registry 2>/dev/null; then
            rm -f "$original_config" 2>/dev/null || true
            return 1
        fi
        [[ $(cat "$target") == sentinel ]] || return 1
        rm -f "$original_config" 2>/dev/null || return 1
    elif [[ -e "$original_config" ]]; then
        rm -f "$original_config" 2>/dev/null || return 1
    fi

    local redirect_config="$TEST_ROOT/linked-config-target"
    local linked_config="$TEST_ROOT/linked-config"
    mkdir -p "$redirect_config"
    if ln -s "$redirect_config" "$linked_config" 2>/dev/null && [[ -L "$linked_config" ]]; then
        GITSETU_CONFIG_DIR="$linked_config"
        GITSETU_PROFILES_CONF="$linked_config/profiles.conf"
        if write_profiles_registry 2>/dev/null; then
            GITSETU_CONFIG_DIR="$original_root"
            GITSETU_PROFILES_CONF="$original_config"
            return 1
        fi
        [[ ! -e "$redirect_config/profiles.conf" ]] || return 1
    fi
    GITSETU_CONFIG_DIR="$original_root"
    GITSETU_PROFILES_CONF="$original_config"

    if [[ "$had_original" -eq 1 ]]; then
        mv "$backup" "$original_config" || return 1
    fi
    return 0
}

test_v2_write_and_load() {
    populate_v2_profiles || return 1
    write_profiles_registry || return 1
    [[ $(head -n 1 "$GITSETU_PROFILES_CONF") == '# gitsetu-registry-v2' ]] || return 1
    [[ $(wc -l < "$GITSETU_PROFILES_CONF") -eq 3 ]] || return 1
    if [[ "$PRIVATE_MODES_SUPPORTED" -eq 1 && "$(file_mode "$GITSETU_PROFILES_CONF")" != 600 ]]; then
        return 1
    fi
    load_profiles || return 1
    [[ "$PROFILE_COUNT" -eq 2 ]] || return 1
    [[ "${PROFILE_LABELS[1]}" == work ]] || return 1
    [[ "${PROFILE_EMAILS[1]}" == work@example.com ]] || return 1
    [[ "${PROFILE_SIGNS[1]}" == 1 ]] || return 1
}

test_remove_global_fails_closed() {
    populate_v2_profiles || return 1
    local before_count="$PROFILE_COUNT"
    local before_first="${PROFILE_LABELS[0]}"
    local before_second="${PROFILE_LABELS[1]}"
    if remove_profile_at_index 0; then
        return 1
    fi
    [[ "$PROFILE_COUNT" -eq "$before_count" ]] || return 1
    [[ "${PROFILE_LABELS[0]}" == "$before_first" ]] || return 1
    [[ "${PROFILE_LABELS[1]}" == "$before_second" ]]
}

test_invalid_profile_does_not_replace_registry() {
    populate_v2_profiles || return 1
    write_profiles_registry || return 1
    local before
    before=$(cat "$GITSETU_PROFILES_CONF") || return 1

    PROFILE_SIGNS[1]=2
    if write_profiles_registry 2>/dev/null; then
        return 1
    fi
    [[ $(cat "$GITSETU_PROFILES_CONF") == "$before" ]]
}

test_legacy_and_partial_v2_rejected() {
    populate_v2_profiles || return 1
    write_profiles_registry || return 1
    local good
    good=$(cat "$GITSETU_PROFILES_CONF")

    printf '%s\n' 'global::/tmp:github.com:0:/tmp/key:' > "$GITSETU_PROFILES_CONF"
    ! load_profiles 2>/dev/null || return 1
    [[ "$PROFILE_COUNT" -eq 0 ]] || return 1

    printf '%s\n' "$good" | sed '2s/%30/0/' > "$GITSETU_PROFILES_CONF"
    ! load_profiles 2>/dev/null || return 1
    [[ "$PROFILE_COUNT" -eq 0 ]] || return 1

    printf '%s\n' "$good" | sed '2s/::/:%0A:/' > "$GITSETU_PROFILES_CONF"
    ! load_profiles 2>/dev/null || return 1
    [[ "$PROFILE_COUNT" -eq 0 ]] || return 1
}

printf '\nFoundation helper tests\n'
run_test 'percent encoding round trip' test_percent_round_trip
run_test 'strict encoded field syntax' test_strict_encoded_fields
run_test 'safe numeric validators' test_safe_numeric_validators
run_test 'strict semantic field validators' test_strict_field_validators
run_test 'canonical path resolution' test_canonical_paths
run_test 'Git Bash reparse status handling' test_gitbash_reparse_status_handling
run_test 'secure temporary helpers' test_secure_temp_helpers
run_test 'secure helpers reject redirected parents' test_secure_helpers_reject_redirected_parents
run_test 'cleanup rejects replaced symlink paths' test_cleanup_rejects_replaced_paths
run_test 'registry write destination hardening' test_registry_write_destination_hardening
run_test 'v2 registry write/load round trip' test_v2_write_and_load
run_test 'mandatory global cannot be removed' test_remove_global_fails_closed
run_test 'invalid profile leaves registry intact' test_invalid_profile_does_not_replace_registry
run_test 'legacy and partial v2 files rejected' test_legacy_and_partial_v2_rejected

printf '%s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
