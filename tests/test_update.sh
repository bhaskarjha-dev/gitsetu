#!/usr/bin/env bash
# tests/test_update.sh — Tests for gitsetu update
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/helpers.sh"

setup_test_home
source_gitsetu_libs

# Mock gitsetu script paths
export GITSETU_DIR="$HOME/.local/share/gitsetu"

test_update_fails_if_not_git_repo() {
    mkdir -p "$GITSETU_DIR"
    
    local gitsetu_script="$TEST_DIR/../gitsetu"
    
    local output
    output=$(bash "$gitsetu_script" update 2>&1 || true)
    
    assert_contains "$output" "was not installed via Git" "detects missing .git" || return 1
}

test_update_succeeds_up_to_date() {
    mkdir -p "$GITSETU_DIR/.git"
    
    # Create a mock git command in a bin directory and prepend to PATH
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "fetch" ]]; then exit 0; fi
if [[ "$1" == "rev-parse" ]]; then echo "123456"; exit 0; fi
exec /usr/bin/git "$@"
EOF
    chmod +x "$TEST_DIR/bin/git"
    export PATH="$TEST_DIR/bin:$PATH"
    
    local gitsetu_script="$TEST_DIR/../gitsetu"
    
    local output
    output=$(bash "$gitsetu_script" update 2>&1 || true)
    
    # Cleanup PATH
    export PATH="${PATH#"$TEST_DIR"/bin:}"
    rm -rf "${TEST_DIR:?}/bin"
    
    assert_contains "$output" "GitSetu is already up-to-date" "detects up to date" || return 1
}

test_update_applies_update() {
    mkdir -p "$GITSETU_DIR/.git"
    
    # Mock core.sh to simulate the version parsing logic
    mkdir -p "$GITSETU_DIR/lib"
    echo 'GITSETU_VERSION="1.2.3"' > "$GITSETU_DIR/lib/core.sh"
    
    # Create a mock git command
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "fetch" ]]; then exit 0; fi
if [[ "$1" == "rev-parse" ]] && [[ "$2" == "HEAD" ]]; then echo "old_hash"; exit 0; fi
if [[ "$1" == "rev-parse" ]] && [[ "$2" == "origin/main" ]]; then echo "new_hash"; exit 0; fi
if [[ "$1" == "reset" ]]; then exit 0; fi
exec /usr/bin/git "$@"
EOF
    chmod +x "$TEST_DIR/bin/git"
    export PATH="$TEST_DIR/bin:$PATH"
    
    local gitsetu_script="$TEST_DIR/../gitsetu"
    
    local output
    output=$(bash "$gitsetu_script" update 2>&1 || true)
    
    # Cleanup PATH
    export PATH="${PATH#"$TEST_DIR"/bin:}"
    rm -rf "${TEST_DIR:?}/bin"
    
    assert_contains "$output" "Update found" "detects update" || return 1
    assert_contains "$output" "from v${GITSETU_VERSION} to v1.2.3" "reports version change" || return 1
}

# --- Run ---

printf '\n%btest_update.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "update fails cleanly if not a git repo" test_update_fails_if_not_git_repo
run_test "update succeeds when up to date" test_update_succeeds_up_to_date
run_test "update successfully applies update" test_update_applies_update
print_results "Update tests"
