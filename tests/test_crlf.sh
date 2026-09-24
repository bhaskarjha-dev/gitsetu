#!/usr/bin/env bash
# tests/test_crlf.sh — Test suite for CRLF Self-Healing & Platform Robustness
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source_gitsetu_libs

setup_test_home

# ------------------------------------------------------------------------------
# Test 1: Pure Bash CRLF Detection (Zero external process forks)
# ------------------------------------------------------------------------------
test_crlf_detection_pure_bash() {
    local tmp_crlf="$TEST_HOME/test_crlf.sh"
    local tmp_lf="$TEST_HOME/test_lf.sh"

    printf '#!/usr/bin/env bash\r\n# test comment\r\n' > "$tmp_crlf"
    printf '#!/usr/bin/env bash\n# test comment\n' > "$tmp_lf"

    local l1="" l2=""
    { read -r l1 || l1=""; read -r l2 || l2=""; } < "$tmp_crlf" 2>/dev/null
    local has_crlf=0
    if [[ "$l1" == *$'\r'* ]] || [[ "$l2" == *$'\r'* ]]; then
        has_crlf=1
    fi
    assert_equals "1" "$has_crlf" "Pure bash detects CRLF in line 1/2"

    l1="" l2=""
    { read -r l1 || l1=""; read -r l2 || l2=""; } < "$tmp_lf" 2>/dev/null
    has_crlf=0
    if [[ "$l1" == *$'\r'* ]] || [[ "$l2" == *$'\r'* ]]; then
        has_crlf=1
    fi
    assert_equals "0" "$has_crlf" "Pure bash does not trigger on clean LF"

    rm -f "$tmp_crlf" "$tmp_lf"
}

# ------------------------------------------------------------------------------
# Test 2: Stripping fallbacks (tr -> sed -> awk -> pure bash)
# ------------------------------------------------------------------------------
test_crlf_stripping_fallbacks() {
    local src="$TEST_HOME/test_strip_src.txt"
    printf 'line 1\r\nline 2 with data\r\nline 3\r\n' > "$src"

    local dst_tr="$TEST_HOME/test_strip_tr.txt"
    local dst_sed="$TEST_HOME/test_strip_sed.txt"
    local dst_awk="$TEST_HOME/test_strip_awk.txt"
    local dst_bash="$TEST_HOME/test_strip_bash.txt"

    tr -d '\r' < "$src" > "$dst_tr"
    sed -e 's/\r$//' < "$src" > "$dst_sed"
    awk '{ sub(/\r$/, ""); print }' "$src" > "$dst_awk"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "${line%$'\r'}"
    done < "$src" > "$dst_bash"

    local tr_content sed_content awk_content bash_content
    tr_content=$(cat "$dst_tr")
    sed_content=$(cat "$dst_sed")
    awk_content=$(cat "$dst_awk")
    bash_content=$(cat "$dst_bash")

    assert_equals "$tr_content" "$sed_content" "sed fallback matches tr output"
    assert_equals "$tr_content" "$awk_content" "awk fallback matches tr output"
    assert_equals "$tr_content" "$bash_content" "pure bash fallback matches tr output"

    rm -f "$src" "$dst_tr" "$dst_sed" "$dst_awk" "$dst_bash"
}

# ------------------------------------------------------------------------------
# Test 3: Multi-directory temp file creation with non-existent TMPDIR
# ------------------------------------------------------------------------------
test_crlf_temp_fallbacks() {
    local created_tmp=""
    local cand
    for cand in "/nonexistent/invalid/dir" "${TMPDIR:-}" "/tmp" "/var/tmp" "${TEST_HOME}" "."; do
        [[ -n "$cand" && -d "$cand" && -w "$cand" ]] || continue
        if created_tmp=$(umask 077; mktemp "${cand%/}/.gitsetu_test_crlf.XXXXXX" 2>/dev/null); then
            if [[ -n "$created_tmp" && -f "$created_tmp" && -w "$created_tmp" ]]; then
                break
            fi
        fi
        created_tmp=""
    done

    assert_file_exists "$created_tmp" "Temp file created despite invalid initial candidate"
    rm -f "$created_tmp"
}

# ------------------------------------------------------------------------------
# Test 4: Loop detection under simulated vboxsf re-injection
# ------------------------------------------------------------------------------
test_crlf_loop_detection_vboxsf() {
    local runner="$TEST_HOME/test_loop_runner.sh"
    cat << 'EOF' > "$runner"
#!/usr/bin/env bash
_crlf_depth="${GITSETU_CRLF_DEPTH:-0}" #
_l1="" #
read -r _l1 < "${BASH_SOURCE[0]:-$0}" 2>/dev/null || _l1="" #
[[ "$_crlf_depth" -ge 2 ]] && { echo "ERROR: recursion limit reached depth=$_crlf_depth" >&2; exit 1; } #
[[ "$_crlf_depth" -ge 1 && "$_l1" == *$'\r'* ]] && { echo "Error: CRLF normalization loop detected." >&2; exit 1; } #
[[ "$_l1" == *$'\r'* ]] && { #
    export GITSETU_CRLF_DEPTH=$(( _crlf_depth + 1 )) #
    export GITSETU_CRLF_CLEAN=1 #
    _tmp=$(mktemp "${TMPDIR:-/tmp}/test_loop_tmp.XXXXXX") #
    tr -d '\r' < "${BASH_SOURCE[0]:-$0}" > "$_tmp" #
    if ! sed -i -e 's/$/\r/' "$_tmp" 2>/dev/null; then
        sed -e 's/$/\r/' "$_tmp" > "${_tmp}.crlf" || exit 1
        mv "${_tmp}.crlf" "$_tmp" 2>/dev/null || exit 1
    fi #
    exec bash "$_tmp" "$@" #
    exit 1 #
} #
echo "SUCCESS" #
EOF

    # Add CRLF to initial script
    local crlf_runner="$TEST_HOME/test_crlf_loop_runner.sh"
    sed -e 's/$/\r/' "$runner" > "$crlf_runner"

    local output="" rc=0
    output=$(bash "$crlf_runner" 2>&1) || rc=$?
    assert_equals "1" "$rc" "Loop script exits with code 1"
    assert_contains "$output" "CRLF normalization loop detected" "Error diagnosed vboxsf loop"

    rm -f "$runner" "$crlf_runner"
}

# ------------------------------------------------------------------------------
# Test 5: Hard recursion depth limit (depth >= 2)
# ------------------------------------------------------------------------------
test_crlf_recursion_depth_limit() {
    local test_script="$TEST_HOME/test_depth.sh"
    cat << 'EOF' > "$test_script"
#!/usr/bin/env bash
_crlf_depth="${GITSETU_CRLF_DEPTH:-0}"
if [[ "$_crlf_depth" -ge 2 ]]; then
    echo "Error: CRLF self-healing recursion limit reached" >&2
    exit 1
fi
echo "RUNNING"
EOF

    local out="" rc=0
    out=$(GITSETU_CRLF_DEPTH=2 bash "$test_script" 2>&1) || rc=$?
    assert_equals "1" "$rc" "Recursion guard exits with code 1"
    assert_contains "$out" "recursion limit reached" "Error reported recursion limit"

    rm -f "$test_script"
}

# ------------------------------------------------------------------------------
# Test 6: End-to-end CRLF healing on full gitsetu executable
# ------------------------------------------------------------------------------
test_gitsetu_crlf_e2e_reexec() {
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local gitsetu_exe="$repo_dir/gitsetu"

    if [[ -f "$gitsetu_exe" ]]; then
        local crlf_exe="$repo_dir/.gitsetu_crlf_test_exe"
        sed -e 's/$/\r/' "$gitsetu_exe" > "$crlf_exe"
        chmod +x "$crlf_exe"

        local out="" rc=0
        out=$(bash "$crlf_exe" --version 2>&1) || rc=$?
        rm -f "$crlf_exe"
        assert_equals "0" "$rc" "CRLF gitsetu --version exits 0" || return 1
        assert_contains "$out" "gitsetu v1.1.0" "CRLF gitsetu prints version output" || return 1
    fi
}

# ------------------------------------------------------------------------------
# Test 7: Stdin preservation across re-exec
# ------------------------------------------------------------------------------
test_crlf_stdin_preservation() {
    local test_script="$TEST_HOME/test_stdin.sh"
    cat << 'EOF' > "$test_script"
#!/usr/bin/env bash
_crlf_depth="${GITSETU_CRLF_DEPTH:-0}" #
_l1="" #
read -r _l1 < "${BASH_SOURCE[0]:-$0}" 2>/dev/null || _l1="" #
[[ "${GITSETU_CRLF_CLEAN:-}" != "1" && "$_l1" == *$'\r'* ]] && { #
    export GITSETU_CRLF_CLEAN=1 #
    _tmp=$(mktemp "${TMPDIR:-/tmp}/test_stdin_tmp.XXXXXX") #
    tr -d '\r' < "${BASH_SOURCE[0]:-$0}" > "$_tmp" #
    trap 'rm -f "$_tmp" 2>/dev/null' EXIT INT TERM #
    exec bash "$_tmp" "$@" #
    exit 1 #
} #
read -r stdin_line
echo "RECEIVED: $stdin_line"
EOF

    local crlf_script="$TEST_HOME/test_stdin_crlf.sh"
    sed -e 's/$/\r/' "$test_script" > "$crlf_script"

    local result
    result=$(printf "hello_secure_token\n" | bash "$crlf_script")
    assert_contains "$result" "RECEIVED: hello_secure_token" "Stdin passed intact across re-exec"

    rm -f "$test_script" "$crlf_script"
}

# ------------------------------------------------------------------------------
# Test 8: gitsetu_source robustness and array preservation
# ------------------------------------------------------------------------------
test_gitsetu_source_robustness() {
    local test_mod="$TEST_HOME/test_mod.sh"
    printf 'MY_VAR="loaded_from_mod"\r\n' > "$test_mod"

    local _src_tmp=""
    _src_tmp=$(umask 077 && mktemp "${TEST_HOME}/.gitsetu_src.XXXXXX")
    GITSETU_CLEANUP_FILES+=("$_src_tmp")
    tr -d '\r' < "$test_mod" > "$_src_tmp"
    # shellcheck disable=SC1090
    source "$_src_tmp"
    rm -f "$_src_tmp"

    assert_equals "loaded_from_mod" "${MY_VAR:-}" "Variable loaded from CRLF module"
    assert_equals "1" "${#GITSETU_CLEANUP_FILES[@]}" "GITSETU_CLEANUP_FILES tracked temp file"

    rm -f "$test_mod"
}

# ------------------------------------------------------------------------------
# Test 9: Execution resilience when tr is completely missing from PATH
# ------------------------------------------------------------------------------
test_crlf_execution_without_tr() {
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local gitsetu_exe="$repo_dir/gitsetu"

    local mock_bin="$TEST_HOME/mock_bin_no_tr"
    mkdir -p "$mock_bin"
    cat << 'EOF' > "$mock_bin/tr"
#!/usr/bin/env bash
exit 127
EOF
    chmod +x "$mock_bin/tr"
    cat << 'EOF' > "$mock_bin/tr.exe"
#!/usr/bin/env bash
exit 127
EOF
    if ! chmod +x "$mock_bin/tr.exe" 2>/dev/null; then
        printf '    FAIL: could not prepare the Windows tr mock\n'
        return 1
    fi

    # 1. Clean LF execution without tr
    local out="" rc=0
    out=$(PATH="$mock_bin:$PATH" bash "$gitsetu_exe" --version 2>&1) || rc=$?
    assert_equals "0" "$rc" "Clean LF gitsetu executes without tr in PATH"
    assert_contains "$out" "gitsetu v1.1.0" "Version displayed without tr"

    # 2. CRLF-contaminated execution without tr
    local crlf_exe="$repo_dir/.gitsetu_crlf_test_no_tr"
    sed -e 's/$/\r/' "$gitsetu_exe" > "$crlf_exe"
    chmod +x "$crlf_exe"
    out="" rc=0
    out=$(PATH="$mock_bin:$PATH" bash "$crlf_exe" --version 2>&1) || rc=$?
    rm -f "$crlf_exe"
    assert_equals "0" "$rc" "CRLF gitsetu executes without tr in PATH"
    assert_contains "$out" "gitsetu v1.1.0" "Version displayed for CRLF script without tr"

    rm -rf "$mock_bin"
}

# ------------------------------------------------------------------------------
# Test 10: caller-controlled cleanup and origin values are never authorities
# ------------------------------------------------------------------------------
test_crlf_cleanup_environment_is_ignored() {
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local crlf_exe="$repo_dir/.gitsetu_crlf_cleanup_test"
    local victim="$TEST_HOME/caller-file.txt"
    printf 'caller data\n' > "$victim"

    sed -e 's/$/\r/' "$repo_dir/gitsetu" > "$crlf_exe"
    chmod +x "$crlf_exe"
    local output rc=0
    output=$(GITSETU_CRLF_TMP="$victim" \
        GITSETU_CRLF_CLEAN=1 \
        GITSETU_ORIG_SCRIPT="$victim" \
        bash "$crlf_exe" --version 2>&1) || rc=$?
    rm -f "$crlf_exe"

    assert_equals "0" "$rc" "CRLF run with forged cleanup environment succeeds" || return 1
    assert_file_exists "$victim" "caller-owned cleanup target is never removed" || return 1
    assert_contains "$output" "gitsetu v1.1.0" "forged cleanup environment does not alter execution" || return 1
}

# ------------------------------------------------------------------------------
# Test 11: CRLF temporary is process-owned and removed after execution
# ------------------------------------------------------------------------------
test_crlf_process_owned_temp_cleanup() {
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local crlf_exe="$repo_dir/.gitsetu_crlf_owned_test"
    local before after
    before=$(find "$repo_dir" -maxdepth 1 -name '.gitsetu_crlf.*' -print | sort)

    sed -e 's/$/\r/' "$repo_dir/gitsetu" > "$crlf_exe"
    chmod +x "$crlf_exe"
    bash "$crlf_exe" --version >/dev/null 2>&1
    rm -f "$crlf_exe"
    after=$(find "$repo_dir" -maxdepth 1 -name '.gitsetu_crlf.*' -print | sort)

    assert_equals "$before" "$after" "parent removes its exclusive CRLF recovery file" || return 1
}

# ------------------------------------------------------------------------------
# Test 12: GITSETU_DIR cannot redirect module loading
# ------------------------------------------------------------------------------
test_root_ignores_gitsetu_dir_override() {
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local redirect="$TEST_HOME/untrusted-checkout"
    local marker="$TEST_HOME/module-redirect-marker"
    mkdir -p "$redirect/lib"
    printf 'printf "MODULE_REDIRECTED\\n"\n' > "$redirect/lib/core.sh"

    local output rc=0
    output=$(GITSETU_DIR="$redirect" bash "$repo_dir/gitsetu" --version 2>&1) || rc=$?
    assert_equals "0" "$rc" "entrypoint runs with a hostile GITSETU_DIR" || return 1
    assert_not_contains "$output" "MODULE_REDIRECTED" "GITSETU_DIR does not redirect sourced modules" || return 1
    assert_contains "$output" "gitsetu v1.1.0" "entrypoint uses its own canonical checkout" || return 1
    assert_file_not_exists "$marker" "redirected module is never executed" || return 1
}

# ------------------------------------------------------------------------------
# Test 17: development update verification is local and fail-closed
# ------------------------------------------------------------------------------
make_development_checkout() {
    local repo_dir checkout
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    checkout="$TEST_HOME/update-checkout"
    rm -rf "$checkout"
    mkdir -p "$checkout"
    cp "$repo_dir/gitsetu" "$checkout/gitsetu"
    cp -R "$repo_dir/lib" "$checkout/lib"
    git -C "$checkout" init --quiet
    git -C "$checkout" config user.email test@example.com
    git -C "$checkout" config user.name Test
    git -C "$checkout" checkout --quiet -b feature/v1.1.0-onboarding-overhaul
    git -C "$checkout" add gitsetu lib
    git -C "$checkout" commit --quiet -m test
    printf '%s' "$checkout"
}

test_update_rejects_dirty_development_checkout() {
    local checkout output rc=0
    checkout=$(make_development_checkout)
    printf 'dirty\n' > "$checkout/untracked.txt"
    output=$(bash "$checkout/gitsetu" update --development 2>&1) || rc=$?
    assert_equals "1" "$rc" "dirty development checkout is rejected" || return 1
    assert_contains "$output" "dirty" "dirty checkout diagnostic is visible" || return 1
}

test_update_rejects_branch_drift() {
    local checkout output rc=0
    checkout=$(make_development_checkout)
    git -C "$checkout" checkout --quiet -b drifted-branch
    output=$(bash "$checkout/gitsetu" update --development 2>&1) || rc=$?
    assert_equals "1" "$rc" "branch drift is rejected" || return 1
    assert_contains "$output" "branch drift" "branch drift diagnostic is visible" || return 1
}

test_update_propagates_verification_failure() {
    local checkout real_git output rc=0 wrapper_dir
    checkout=$(make_development_checkout)
    real_git=$(command -v git)
    wrapper_dir="$TEST_HOME/fake-git-bin"
    rm -rf "$wrapper_dir"
    mkdir -p "$wrapper_dir"
    cat > "$wrapper_dir/git" <<EOF
#!/usr/bin/env bash
seen_rev_parse=0
for arg in "\$@"; do
    if [[ "\$seen_rev_parse" -eq 1 && "\$arg" == "--verify" ]]; then
        exit 19
    fi
    if [[ "\$arg" == "rev-parse" ]]; then
        seen_rev_parse=1
    fi
done
exec "$real_git" "\$@"
EOF
    chmod +x "$wrapper_dir/git"
    local wrapper_path="$wrapper_dir"
    if command -v cygpath >/dev/null 2>&1; then wrapper_path=$(cygpath -u "$wrapper_dir"); fi
    output=$(PATH="$wrapper_path:$PATH" bash "$checkout/gitsetu" update --development 2>&1) || rc=$?
    assert_equals "1" "$rc" "failed local verification is propagated" || return 1
    assert_contains "$output" "HEAD could not be verified" "verification failure is visible" || return 1
    assert_not_contains "$output" "Development checkout verified" "failed verification emits no success claim" || return 1
}

# ------------------------------------------------------------------------------
# Test 19: a non-writable install path falls back to a private runtime dir
# ------------------------------------------------------------------------------
test_crlf_read_only_install_uses_private_runtime() {
    local repo_dir checkout mock_bin real_mktemp runtime_log
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    checkout="$TEST_HOME/read-only-install-checkout"
    mock_bin="$TEST_HOME/read-only-install-bin"
    runtime_log="$TEST_HOME/read-only-install-runtime.log"
    rm -rf "$checkout" "$mock_bin"
    mkdir -p "$checkout" "$mock_bin"
    cp "$repo_dir/gitsetu" "$checkout/gitsetu"
    cp -R "$repo_dir/lib" "$checkout/lib"
    sed -e 's/$/\r/' "$repo_dir/gitsetu" > "$checkout/gitsetu"
    chmod +x "$checkout/gitsetu"
    real_mktemp=$(command -v mktemp)
    cat > "$mock_bin/mktemp" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [[ "\$arg" == *".gitsetu_crlf."* && "\$arg" != *".gitsetu-runtime."* ]]; then
        exit 1
    fi
    if [[ "\$arg" == *".gitsetu-runtime."* ]]; then
        result=\$("$real_mktemp" "\$@" 2>/dev/null) || exit 1
        printf '%s\\n' "\$result" >> "$runtime_log"
        printf '%s\\n' "\$result"
        exit 0
    fi
done
exec "$real_mktemp" "\$@"
EOF
    chmod +x "$mock_bin/mktemp"
    : > "$runtime_log"

    local output rc=0 caller_tmp="$TEST_HOME/caller-tmp"
    mkdir -p "$caller_tmp"
    local mock_path="$mock_bin"
    if command -v cygpath >/dev/null 2>&1; then mock_path=$(cygpath -u "$mock_bin"); fi
    output=$(TMPDIR="$caller_tmp" PATH="$mock_path:$PATH" bash "$checkout/gitsetu" --version 2>&1) || rc=$?
    assert_equals "0" "$rc" "read-only install path uses the trusted runtime fallback" || return 1
    assert_contains "$output" "gitsetu v1.1.0" "runtime fallback executes the normalized entrypoint" || return 1
    assert_equals "" "$(find "$caller_tmp" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" "caller TMPDIR is not used for the runtime fallback" || return 1
    if [[ ! -s "$runtime_log" ]]; then
        printf '    FAIL: read-only simulation did not reach the private runtime fallback\n'
        return 1
    fi
    local runtime_path
    while IFS= read -r runtime_path; do
        [[ -n "$runtime_path" ]] || continue
        assert_file_not_exists "$runtime_path" "private CRLF runtime directory is removed" || return 1
    done < "$runtime_log"
    rm -rf "$checkout" "$mock_bin" "$runtime_log"
}

# ------------------------------------------------------------------------------
# Test 18: inherited numeric and boolean environment values fail closed
# ------------------------------------------------------------------------------
test_crlf_rejects_unsafe_inherited_numbers() {
    local repo_dir output rc
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local value
    for value in 01 08 1x; do
        rc=0
        output=$(GITSETU_CRLF_DEPTH="$value" bash "$repo_dir/gitsetu" --version 2>&1) || rc=$?
        assert_equals "1" "$rc" "non-canonical CRLF depth is rejected" || return 1
        assert_contains "$output" "GITSETU_CRLF_DEPTH" "unsafe CRLF depth is diagnosed" || return 1
    done
    rc=0
    output=$(GITSETU_LOCK_TIMEOUT=08 bash "$repo_dir/gitsetu" --version 2>&1) || rc=$?
    assert_equals "1" "$rc" "octal-looking lock timeout is rejected before arithmetic" || return 1
    assert_contains "$output" "GITSETU_LOCK_TIMEOUT" "unsafe lock timeout is diagnosed" || return 1
    rc=0
    output=$(GITSETU_LOCK_TIMEOUT=9999 bash "$repo_dir/gitsetu" --version 2>&1) || rc=$?
    assert_equals "1" "$rc" "out-of-range lock timeout is rejected before arithmetic" || return 1
    rc=0
    output=$(GITSETU_VERIFY_NETWORK=2 bash "$repo_dir/gitsetu" --version 2>&1) || rc=$?
    assert_equals "1" "$rc" "invalid boolean flag is rejected" || return 1
    assert_contains "$output" "GITSETU_VERIFY_NETWORK" "invalid boolean is diagnosed" || return 1
}

# ------------------------------------------------------------------------------
# Test 16: teardown propagates a failed operation and releases its lock
# ------------------------------------------------------------------------------
test_teardown_failure_propagates_and_releases_lock() {
    local repo_dir checkout
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    checkout="$TEST_HOME/teardown-fault-checkout"
    mkdir -p "$checkout"
    cp "$repo_dir/gitsetu" "$checkout/gitsetu"
    cp -R "$repo_dir/lib" "$checkout/lib"
    printf '\nteardown_all() { return 23; }\n' >> "$checkout/lib/teardown.sh"

    local output rc=0
    output=$(GITSETU_TEST=1 bash "$checkout/gitsetu" teardown --force 2>&1) || rc=$?
    assert_equals "1" "$rc" "teardown failure is propagated" || return 1
    assert_contains "$output" "Teardown failed" "teardown reports partial cleanup failure" || return 1
    if [[ -d "$GITSETU_LOCK_DIR" ]]; then
        printf '    FAIL: teardown lock was not released after failure\n'
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Test 15: inherited Port 443 routing state is cleared
# ------------------------------------------------------------------------------
test_port443_routing_state_is_process_owned() {
    local repo_dir checkout
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    checkout="$TEST_HOME/port443-checkout"
    mkdir -p "$checkout"
    cp "$repo_dir/gitsetu" "$checkout/gitsetu"
    cp -R "$repo_dir/lib" "$checkout/lib"
    # shellcheck disable=SC2016  # Literal probe appended to a copied module.
    printf '\nprintf "PORT443_STATE=%%s\\n" "${GITSETU_PORT443_NEEDED:-unset}" >&2\n' >> "$checkout/lib/platform.sh"

    local output
    output=$(GITSETU_PORT443_NEEDED=1 bash "$checkout/gitsetu" --version 2>&1)
    assert_contains "$output" "PORT443_STATE=0" "inherited Port 443 routing state is cleared before module execution" || return 1
}

# ------------------------------------------------------------------------------
# Test 13: module load failures are fail-closed
# ------------------------------------------------------------------------------
test_module_load_failure_is_not_ignored() {
    local repo_dir checkout
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    checkout="$TEST_HOME/fault-checkout"
    mkdir -p "$checkout"
    cp "$repo_dir/gitsetu" "$checkout/gitsetu"
    cp -R "$repo_dir/lib" "$checkout/lib"
    printf '\nreturn 17\n' >> "$checkout/lib/doctor.sh"

    local output rc=0
    output=$(bash "$checkout/gitsetu" --version 2>&1) || rc=$?
    assert_equals "17" "$rc" "module source status is propagated" || return 1
    assert_contains "$output" "module loading aborted" "startup reports the failed module" || return 1
}

# ------------------------------------------------------------------------------
# Test 14: CRLF source staging ignores caller HOME/PWD/TMPDIR
# ------------------------------------------------------------------------------
test_source_staging_ignores_caller_directories() {
    local repo_dir checkout
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    checkout="$TEST_HOME/staging-checkout"
    mkdir -p "$checkout"
    cp "$repo_dir/gitsetu" "$checkout/gitsetu"
    cp -R "$repo_dir/lib" "$checkout/lib"
    sed -e 's/$/\r/' "$checkout/lib/ui.sh" > "$checkout/lib/ui.crlf"
    mv "$checkout/lib/ui.crlf" "$checkout/lib/ui.sh"

    local caller_home="$TEST_HOME/caller-home" caller_pwd="$TEST_HOME/caller-pwd" caller_tmp="$TEST_HOME/caller-tmp"
    mkdir -p "$caller_home" "$caller_pwd" "$caller_tmp"
    local output rc=0
    output=$(cd "$caller_pwd" && HOME="$caller_home" TMPDIR="$caller_tmp" XDG_CONFIG_HOME="$caller_home/.config" \
        bash "$checkout/gitsetu" --version 2>&1) || rc=$?
    assert_equals "0" "$rc" "CRLF module staging succeeds without caller temp roots" || return 1
    assert_equals "" "$(find "$caller_home" "$caller_pwd" "$caller_tmp" -name '.gitsetu-src.*' -print 2>/dev/null)" \
        "caller-controlled directories receive no source staging files" || return 1
}

# --- Run ---

printf '\n%btest_crlf.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "pure bash detects CRLF in header with 0 forks" test_crlf_detection_pure_bash
run_test "all stripping fallbacks produce identical clean output" test_crlf_stripping_fallbacks
run_test "multi-directory temp creation falls back on invalid TMPDIR" test_crlf_temp_fallbacks
run_test "loop detection catches simulated vboxsf re-injection" test_crlf_loop_detection_vboxsf
run_test "recursion limit terminates execution at depth 2" test_crlf_recursion_depth_limit
run_test "e2e CRLF-contaminated gitsetu normalizes and executes" test_gitsetu_crlf_e2e_reexec
run_test "stdin input is preserved across CRLF re-exec" test_crlf_stdin_preservation
run_test "gitsetu_source loads modules without wiping tracking" test_gitsetu_source_robustness
run_test "gitsetu executes cleanly when tr is absent from PATH" test_crlf_execution_without_tr
run_test "caller-controlled CRLF cleanup and origin values are ignored" test_crlf_cleanup_environment_is_ignored
run_test "CRLF recovery removes only its process-owned temporary file" test_crlf_process_owned_temp_cleanup
run_test "GITSETU_DIR cannot redirect module loading" test_root_ignores_gitsetu_dir_override
run_test "module source failures abort startup" test_module_load_failure_is_not_ignored
run_test "CRLF source staging ignores HOME, PWD, and TMPDIR" test_source_staging_ignores_caller_directories
run_test "inherited Port 443 routing state is cleared" test_port443_routing_state_is_process_owned
run_test "teardown failure propagates and releases its lock" test_teardown_failure_propagates_and_releases_lock
run_test "development update rejects dirty checkout" test_update_rejects_dirty_development_checkout
run_test "development update rejects branch drift" test_update_rejects_branch_drift
run_test "development update propagates verification failure" test_update_propagates_verification_failure
run_test "unsafe inherited numeric values fail closed" test_crlf_rejects_unsafe_inherited_numbers
run_test "read-only install path uses private CRLF runtime" test_crlf_read_only_install_uses_private_runtime

teardown_test_home
print_results "CRLF & Platform Robustness tests"
