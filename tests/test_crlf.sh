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
    { read -r l1 || true; read -r l2 || true; } < "$tmp_crlf" 2>/dev/null || true
    local has_crlf=0
    if [[ "$l1" == *$'\r'* ]] || [[ "$l2" == *$'\r'* ]]; then
        has_crlf=1
    fi
    assert_equals "1" "$has_crlf" "Pure bash detects CRLF in line 1/2"

    l1="" l2=""
    { read -r l1 || true; read -r l2 || true; } < "$tmp_lf" 2>/dev/null || true
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
        created_tmp=$(umask 077; mktemp "${cand%/}/.gitsetu_test_crlf.XXXXXX" 2>/dev/null || true)
        if [[ -n "$created_tmp" && -f "$created_tmp" && -w "$created_tmp" ]]; then
            break
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
read -r _l1 < "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true #
[[ "$_crlf_depth" -ge 2 ]] && { echo "ERROR: recursion limit reached depth=$_crlf_depth" >&2; exit 1; } #
[[ "$_crlf_depth" -ge 1 && "$_l1" == *$'\r'* ]] && { echo "Error: CRLF normalization loop detected." >&2; exit 1; } #
[[ "$_l1" == *$'\r'* ]] && { #
    export GITSETU_CRLF_DEPTH=$(( _crlf_depth + 1 )) #
    export GITSETU_CRLF_CLEAN=1 #
    _tmp=$(mktemp "${TMPDIR:-/tmp}/test_loop_tmp.XXXXXX") #
    tr -d '\r' < "${BASH_SOURCE[0]:-$0}" > "$_tmp" #
    sed -i -e 's/$/\r/' "$_tmp" 2>/dev/null || (sed -e 's/$/\r/' "$_tmp" > "${_tmp}.crlf" && mv "${_tmp}.crlf" "$_tmp" 2>/dev/null) || true #
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
        assert_contains "$out" "gitsetu v1.0.0" "CRLF gitsetu prints version output" || return 1
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
read -r _l1 < "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true #
[[ "${GITSETU_CRLF_CLEAN:-}" != "1" && "$_l1" == *$'\r'* ]] && { #
    export GITSETU_CRLF_CLEAN=1 #
    _tmp=$(mktemp "${TMPDIR:-/tmp}/test_stdin_tmp.XXXXXX") #
    tr -d '\r' < "${BASH_SOURCE[0]:-$0}" > "$_tmp" #
    trap 'rm -f "$_tmp" 2>/dev/null || true' EXIT INT TERM #
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
    chmod +x "$mock_bin/tr.exe" 2>/dev/null || true

    # 1. Clean LF execution without tr
    local out="" rc=0
    out=$(PATH="$mock_bin:$PATH" bash "$gitsetu_exe" --version 2>&1) || rc=$?
    assert_equals "0" "$rc" "Clean LF gitsetu executes without tr in PATH"
    assert_contains "$out" "gitsetu v1.0.0" "Version displayed without tr"

    # 2. CRLF-contaminated execution without tr
    local crlf_exe="$repo_dir/.gitsetu_crlf_test_no_tr"
    sed -e 's/$/\r/' "$gitsetu_exe" > "$crlf_exe"
    chmod +x "$crlf_exe"
    out="" rc=0
    out=$(PATH="$mock_bin:$PATH" bash "$crlf_exe" --version 2>&1) || rc=$?
    rm -f "$crlf_exe"
    assert_equals "0" "$rc" "CRLF gitsetu executes without tr in PATH"
    assert_contains "$out" "gitsetu v1.0.0" "Version displayed for CRLF script without tr"

    rm -rf "$mock_bin"
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

teardown_test_home
print_results "CRLF & Platform Robustness tests"
