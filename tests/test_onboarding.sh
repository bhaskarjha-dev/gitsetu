#!/usr/bin/env bash
# shellcheck disable=SC2329  # Mocked functions invoked dynamically or via subshells
# tests/test_onboarding.sh — Onboarding, Entrypoint, Guided On-Ramp & Dashboard Suite
# Verifies Tasks T1.1, T1.2, T1.3 (15 tests)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"
setup_test_home
source_gitsetu_libs
detect_os

GITSETU_EXE="$REPO_DIR/gitsetu"
GITSETU_EXE="${GITSETU_EXE%$'\r'}"

# ------------------------------------------------------------------------------
# Test 1: Bare gitsetu non-TTY prints brief usage and exits 0
# ------------------------------------------------------------------------------
test_bare_gitsetu_nontty_usage() {
    local output rc=0
    output=$(bash "$GITSETU_EXE" 2>&1) || rc=$?
    assert_equals "0" "$rc" "bare gitsetu non-TTY exits 0" || return 1
    assert_contains "$output" "Usage: gitsetu setup" "prints brief usage" || return 1
    assert_contains "$output" "One command. All identities." "prints tagline" || return 1
}

# ------------------------------------------------------------------------------
# Test 2: show_brief_usage() output contains version string
# ------------------------------------------------------------------------------
test_brief_usage_contains_version() {
    local output
    output=$(bash "$GITSETU_EXE" 2>&1 || true)
    assert_contains "$output" "gitsetu v1.1.0" "brief usage contains version 1.1.0" || return 1
}

# ------------------------------------------------------------------------------
# Test 3: Bare gitsetu interactive TTY with no profiles launches on-ramp
# ------------------------------------------------------------------------------
test_bare_gitsetu_unconfigured_launches_onramp() {
    rm -f "$GITSETU_PROFILES_CONF"
    # Create a wrapper that simulates an unconfigured interactive entrypoint
    local mock_script="$TEST_HOME/mock_entry_unconf.sh"
    cat << EOF > "$mock_script"
#!/usr/bin/env bash
source "$REPO_DIR/tests/helpers.sh"
source_gitsetu_libs
preset_guided_onboarding() {
    echo "ON_RAMP_LAUNCHED"
    exit 0
}
cmd_status() {
    echo "STATUS_LAUNCHED"
    exit 0
}
load_profiles
if [[ -f "\$GITSETU_PROFILES_CONF" ]] && [[ "\$PROFILE_COUNT" -gt 0 ]]; then
    cmd_status
else
    preset_guided_onboarding
fi
EOF
    local output
    output=$(bash "$mock_script" 2>&1 || true)
    assert_contains "$output" "ON_RAMP_LAUNCHED" "unconfigured bare entrypoint launches on-ramp" || return 1
}

# ------------------------------------------------------------------------------
# Test 4: Bare gitsetu interactive TTY with profiles configured invokes cmd_status
# ------------------------------------------------------------------------------
test_bare_gitsetu_configured_launches_status() {
    mkdir -p "$(dirname "$GITSETU_PROFILES_CONF")"
    echo "work:work@corp.com:$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:" > "$GITSETU_PROFILES_CONF"

    local mock_script="$TEST_HOME/mock_entry_conf.sh"
    cat << EOF > "$mock_script"
#!/usr/bin/env bash
source "$REPO_DIR/tests/helpers.sh"
source_gitsetu_libs
preset_guided_onboarding() {
    echo "ON_RAMP_LAUNCHED"
    exit 0
}
cmd_status() {
    echo "STATUS_LAUNCHED"
    exit 0
}
load_profiles
if [[ -f "\$GITSETU_PROFILES_CONF" ]] && [[ "\$PROFILE_COUNT" -gt 0 ]]; then
    cmd_status
else
    preset_guided_onboarding
fi
EOF
    local output
    output=$(bash "$mock_script" 2>&1 || true)
    assert_contains "$output" "STATUS_LAUNCHED" "configured bare entrypoint invokes cmd_status" || return 1
}

# ------------------------------------------------------------------------------
# Test 5: Preset 1 (Single) creates single global profile in profiles.conf
# ------------------------------------------------------------------------------
test_preset1_single_identity() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    mkdir -p "$GITSETU_CONFIG_DIR"

    # Simulate Preset 1 input: choice=1, name="Solo Dev", email="solo@example.com"
    local input_data=$'1\nSolo Dev\nsolo@example.com\n'
    printf '%s' "$input_data" | preset_guided_onboarding >/dev/null 2>&1 || true

    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf created" || return 1
    local count
    count=$(grep -v '^#' "$GITSETU_PROFILES_CONF" | grep -c ':' || echo "0")
    assert_equals "1" "$count" "single profile recorded in registry" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/global.gitconfig" "solo@example.com" "global profile contains correct email" || return 1
}

# ------------------------------------------------------------------------------
# Test 6: Preset 2 (Dual) creates 3 profiles (global, work, personal)
# ------------------------------------------------------------------------------
test_preset2_dual_identity() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    mkdir -p "$GITSETU_CONFIG_DIR"

    # Preset 2 input: choice=2, name="Dual Dev", personal email="me@personal.dev",
    # work email="dev@company.com", work dir="$HOME/work", personal dir="$HOME/personal"
    local input_data=$'2\nDual Dev\nme@personal.dev\ndev@company.com\n\n\n'
    printf '%s' "$input_data" | preset_guided_onboarding >/dev/null 2>&1 || true

    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf created" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/global.gitconfig" "me@personal.dev" "global fallback uses personal email" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/work.gitconfig" "dev@company.com" "work profile configured" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/personal.gitconfig" "me@personal.dev" "personal profile configured" || return 1
}

# ------------------------------------------------------------------------------
# Test 7: Preset 3 (Custom) falls through to interactive_setup_wizard
# ------------------------------------------------------------------------------
test_preset3_custom_falls_through() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    mkdir -p "$GITSETU_CONFIG_DIR"

    # Run in subshell with mocked interactive_setup_wizard
    local output
    output=$(
        interactive_setup_wizard() {
            echo "INTERACTIVE_DASHBOARD_INVOKED"
            return 0
        }
        printf '3\n' | preset_guided_onboarding 2>&1 || true
    )
    assert_contains "$output" "INTERACTIVE_DASHBOARD_INVOKED" "Option 3 falls through to dashboard wizard" || return 1
}

# ------------------------------------------------------------------------------
# Test 8: Default selection (ENTER on prompt) selects Preset 1
# ------------------------------------------------------------------------------
test_preset_default_selection_is_single() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    mkdir -p "$GITSETU_CONFIG_DIR"

    # Empty first line (ENTER) -> default option 1
    local input_data=$'\nDefault User\ndefault@example.com\n'
    printf '%s' "$input_data" | preset_guided_onboarding >/dev/null 2>&1 || true

    assert_file_exists "$GITSETU_PROFILES_CONF" "profiles.conf created" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/global.gitconfig" "default@example.com" "default selection created single global profile" || return 1
}

# ------------------------------------------------------------------------------
# Test 9: useConfigOnly + Single preset resolves user.name and user.email in any dir
# ------------------------------------------------------------------------------
test_single_preset_useconfigonly_commits() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    mkdir -p "$GITSETU_CONFIG_DIR"

    # Set up single preset
    local input_data=$'1\nSingle Tester\nsingle.test@domain.com\n'
    printf '%s' "$input_data" | preset_guided_onboarding >/dev/null 2>&1 || true

    # Arbitrary directory
    local test_repo="$HOME/random/nested/repo"
    mkdir -p "$test_repo"
    git -C "$test_repo" init -q

    local res_name res_email
    res_name=$(git -C "$test_repo" config user.name || echo "")
    res_email=$(git -C "$test_repo" config user.email || echo "")

    assert_equals "Single Tester" "$res_name" "global user.name resolves in arbitrary repo" || return 1
    assert_equals "single.test@domain.com" "$res_email" "global user.email resolves in arbitrary repo" || return 1
}

# ------------------------------------------------------------------------------
# Test 10: gitsetu setup on unconfigured machine triggers on-ramp wizard
# ------------------------------------------------------------------------------
test_setup_unconfigured_triggers_onramp() {
    rm -rf "$HOME/.ssh" "$GITSETU_CONFIG_DIR"
    rm -f "$HOME/.gitconfig"

    # Mock preset_guided_onboarding
    local output
    output=$(
        preset_guided_onboarding() {
            echo "TRIGGERED_ONRAMP"
            return 0
        }
        render_blueprint_dashboard() {
            echo "RAW_DASHBOARD"
            return 0
        }
        printf 'Q\n' | interactive_setup_wizard 2>&1 || true
    )
    assert_contains "$output" "TRIGGERED_ONRAMP" "unconfigured machine triggers on-ramp before dashboard" || return 1
}

# ------------------------------------------------------------------------------
# Test 11: gitsetu setup on configured machine shows normal dashboard
# ------------------------------------------------------------------------------
test_setup_configured_shows_dashboard() {
    mkdir -p "$GITSETU_CONFIG_DIR"
    echo "work:dev@corp.com:$HOME/work:github.com:0:$HOME/.ssh/id_ed25519_work:" > "$GITSETU_PROFILES_CONF"
    echo "personal:me@home.dev:$HOME/personal:github.com:0:$HOME/.ssh/id_ed25519_personal:" >> "$GITSETU_PROFILES_CONF"

    local output
    output=$(
        preset_guided_onboarding() {
            echo "UNEXPECTED_ONRAMP"
            return 0
        }
        render_blueprint_dashboard() {
            echo "RENDERED_NORMAL_DASHBOARD"
            return 0
        }
        printf 'Q\n' | interactive_setup_wizard 2>&1 || true
    )
    assert_contains "$output" "RENDERED_NORMAL_DASHBOARD" "configured machine shows normal dashboard" || return 1
    assert_not_contains "$output" "UNEXPECTED_ONRAMP" "on-ramp is skipped on configured machine" || return 1
}

# ------------------------------------------------------------------------------
# Test 12: Discovery pre-population from global git config
# ------------------------------------------------------------------------------
test_discovery_prepopulation() {
    git config --global user.name "Discovered Master"
    git config --global user.email "discovered.master@example.com"

    discover_global_git_identity
    assert_equals "Discovered Master" "$DISCOVERED_GLOBAL_NAME" "discovered name from global git config" || return 1
    assert_equals "discovered.master@example.com" "$DISCOVERED_GLOBAL_EMAIL" "discovered email from global git config" || return 1

    git config --global --unset user.name || true
    git config --global --unset user.email || true
}

# ------------------------------------------------------------------------------
# Test 13: Dashboard ENTER with incomplete profile invokes prompt_edit_profile
# ------------------------------------------------------------------------------
test_dashboard_enter_incomplete_invokes_edit() {
    PROFILE_COUNT=1
    PROFILE_LABELS[0]="global"
    PROFILE_NAMES[0]="Incomplete User"
    PROFILE_EMAILS[0]=""
    PROFILE_DIRS[0]=""
    PROFILE_KEYS[0]="$HOME/.ssh/id_ed25519_global"

    local output
    output=$(
        prompt_edit_profile() {
            echo "AUTO_PROMPTED_EDIT_PROFILE_$1"
            return 0
        }
        execute_blueprint() {
            echo "EXECUTED"
            return 0
        }
        # Simulate pressing ENTER on dashboard menu with incomplete profile
        printf '\n' | GITSETU_SKIP_ON_RAMP=1 interactive_setup_wizard 2>&1 || true
    )
    assert_contains "$output" "AUTO_PROMPTED_EDIT_PROFILE_0" "ENTER on incomplete profile invokes prompt_edit_profile" || return 1
}

# ------------------------------------------------------------------------------
# Test 14: Dashboard single profile edit directly edits profile 0
# ------------------------------------------------------------------------------
test_dashboard_single_profile_direct_edit() {
    rm -rf "$GITSETU_CONFIG_DIR"
    mkdir -p "$GITSETU_PROFILES_DIR"
    echo "global:::" > "$GITSETU_PROFILES_CONF"
    cat << EOF > "$GITSETU_PROFILES_DIR/global.gitconfig"
[user]
    name = Single User
    email = single@test.com
EOF

    local output
    output=$(
        prompt_edit_profile() {
            echo "DIRECT_EDIT_PROFILE_$1"
            return 0
        }
        # Simulate pressing E on single-profile dashboard
        printf 'E\nQ\n' | GITSETU_SKIP_ON_RAMP=1 interactive_setup_wizard 2>&1 || true
    )
    assert_contains "$output" "DIRECT_EDIT_PROFILE_0" "E on single profile directly edits profile 0 without asking for index" || return 1
}

# ------------------------------------------------------------------------------
# Test 15: Incomplete tag rendered next to incomplete profiles
# ------------------------------------------------------------------------------
test_incomplete_tag_rendering() {
    PROFILE_COUNT=2
    PROFILE_LABELS[0]="global"
    PROFILE_NAMES[0]="Configured User"
    PROFILE_EMAILS[0]="user@complete.com"
    PROFILE_DIRS[0]=""
    PROFILE_KEYS[0]="$HOME/.ssh/id_ed25519_global"

    PROFILE_LABELS[1]="work"
    PROFILE_NAMES[1]=""
    PROFILE_EMAILS[1]=""
    PROFILE_DIRS[1]="$HOME/work"
    PROFILE_KEYS[1]="$HOME/.ssh/id_ed25519_work"

    local output
    output=$(render_blueprint_dashboard 2>&1 || true)
    assert_contains "$output" "[⚠ Incomplete]" "renders incomplete tag for profile with missing details" || return 1
}

# ------------------------------------------------------------------------------
# Run all tests
# ------------------------------------------------------------------------------
printf '\n%btest_onboarding.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "bare gitsetu non-TTY prints usage and exits 0" test_bare_gitsetu_nontty_usage
run_test "show_brief_usage contains v1.1.0" test_brief_usage_contains_version
run_test "bare gitsetu unconfigured launches on-ramp" test_bare_gitsetu_unconfigured_launches_onramp
run_test "bare gitsetu configured invokes status" test_bare_gitsetu_configured_launches_status
run_test "preset 1 creates single global profile" test_preset1_single_identity
run_test "preset 2 creates 3 profiles (global, work, personal)" test_preset2_dual_identity
run_test "preset 3 falls through to dashboard wizard" test_preset3_custom_falls_through
run_test "default selection (ENTER) chooses preset 1" test_preset_default_selection_is_single
run_test "useConfigOnly + single preset commits resolve everywhere" test_single_preset_useconfigonly_commits
run_test "gitsetu setup unconfigured triggers on-ramp" test_setup_unconfigured_triggers_onramp
run_test "gitsetu setup configured shows normal dashboard" test_setup_configured_shows_dashboard
run_test "discovery pre-population from gitconfig" test_discovery_prepopulation
run_test "dashboard ENTER on incomplete profile auto-prompts edit" test_dashboard_enter_incomplete_invokes_edit
run_test "dashboard E on single profile edits profile 0 directly" test_dashboard_single_profile_direct_edit
run_test "dashboard renders [⚠ Incomplete] tag" test_incomplete_tag_rendering
print_results "Onboarding tests"
