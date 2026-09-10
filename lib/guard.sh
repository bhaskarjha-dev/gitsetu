#!/usr/bin/env bash
# lib/guard.sh — Pre-commit identity guard hook
#
# Installs a global pre-commit hook that warns when the current
# git user.email doesn't match the expected profile for the directory.
# Uses core.hooksPath to apply globally (no per-repo setup needed).
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# install_guard — Install the pre-commit identity guard hook
#
# Creates hook script in $GITSETU_HOOKS_DIR/pre-commit
# Sets git config --global core.hooksPath to point to that directory.
#
# Usage: install_guard
# ------------------------------------------------------------------------------
install_guard() {
    local hook_path="$GITSETU_HOOKS_DIR/pre-commit"

    # Check if core.hooksPath is already set to something else
    local existing_hooks_path
    existing_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)

    if [[ -n "$existing_hooks_path" ]] && [[ "$existing_hooks_path" != "$GITSETU_HOOKS_DIR" ]]; then
        print_warning "core.hooksPath is already set to: $existing_hooks_path"
        if ! confirm "Override with gitsetu hooks directory?" "n"; then
            print_info "Guard hook installation skipped."
            return 0
        fi
    fi

    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would install guard hook at: $hook_path"
        print_info "[DRY RUN] Would set core.hooksPath = $GITSETU_HOOKS_DIR"
        return 0
    fi

    ensure_dirs

    # Write the hook script
    cat > "$hook_path" <<'HOOK_SCRIPT'
#!/usr/bin/env bash
# [gitsetu:managed] Pre-commit identity guard
# Checks if current user.email matches expected profile for this directory.
# Installed by: gitsetu guard --install
# Remove with:  gitsetu guard --uninstall

set -euo pipefail

# Find the profiles.conf
GITSETU_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu"
GITSETU_CONF="$GITSETU_CONF_DIR/profiles.conf"

if [[ ! -f "$GITSETU_CONF" ]]; then
    # No config found — block commit to ensure zero-trust policy.
    printf "\033[0;31m[GitSetu Guard] ERROR: Identity configuration not found at %s\033[0m\n" "$GITSETU_CONF" >&2
    printf "If you uninstalled GitSetu, run: \033[1mgit config --global --unset core.hooksPath\033[0m\n" >&2
    printf "To bypass this check once, use: \033[1mgit commit --no-verify\033[0m\n" >&2
    exit 1
fi

# Get the current git directory (absolute path)
current_dir=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Detect case-insensitivity (Windows / macOS)
is_case_insensitive=0
case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*|darwin*)
        is_case_insensitive=1
        ;;
    *)
        u=$(uname -s 2>/dev/null || true)
        case "$u" in
            MSYS*|MINGW*|CYGWIN*|Darwin*)
                is_case_insensitive=1
                ;;
        esac
        ;;
esac

# Normalize current directory
current_norm="${current_dir//\\//}"
if [[ "$current_norm" =~ ^/([a-zA-Z])/(.*) ]]; then
    c_letter=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
    current_norm="${c_letter}:/${BASH_REMATCH[2]}"
elif [[ "$current_norm" =~ ^([a-zA-Z]):/(.*) ]]; then
    c_letter=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
    current_norm="${c_letter}:/${BASH_REMATCH[2]}"
fi
current_slash="${current_norm%/}/"

# Get the configured email for this repo
actual_email=$(git config user.email 2>/dev/null || true)

if [[ -z "$actual_email" ]]; then
    # No email configured — git will error anyway
    exit 0
fi

# Search profiles.conf for a matching directory (longest prefix match wins)
expected_email=""
expected_label=""
max_len=0

raw_line=""
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    # Skip comments and empty lines
    [[ "$raw_line" == "#"* ]] && continue
    [[ -z "$raw_line" ]] && continue
    
    clean_line=$(printf '%s' "$raw_line" | sed -E 's/:([a-zA-Z]):/:\1#DRIVE#/g')
    IFS=: read -r label email dir provider _rest <<< "$clean_line"
    dir="${dir//#DRIVE#/:}"
    
    # Skip manual mode profiles (no directory)
    [[ -z "$dir" ]] && continue

    # Normalize Windows drive letters and slashes
    dir_norm="${dir//\\//}"
    if [[ "$dir_norm" =~ ^/([a-zA-Z])/(.*) ]]; then
        d_letter=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
        dir_norm="${d_letter}:/${BASH_REMATCH[2]}"
    elif [[ "$dir_norm" =~ ^([a-zA-Z]):/(.*) ]]; then
        d_letter=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
        dir_norm="${d_letter}:/${BASH_REMATCH[2]}"
    fi
    dir_slash="${dir_norm%/}/"

    check_current="$current_slash"
    check_target="$dir_slash"
    if [[ "$is_case_insensitive" -eq 1 ]]; then
        check_current=$(printf '%s' "$check_current" | tr '[:upper:]' '[:lower:]')
        check_target=$(printf '%s' "$check_target" | tr '[:upper:]' '[:lower:]')
    fi

    # Check if current dir is under this profile's directory
    if [[ "$check_current" == "$check_target"* ]]; then
        dir_len=${#dir_slash}
        if [[ $dir_len -gt $max_len ]]; then
            max_len=$dir_len
            expected_label="$label"
            # Extract email from the local profile.gitconfig to avoid dual-state desync
            expected_email=$(git config -f "$GITSETU_CONF_DIR/profiles/${label}.gitconfig" user.email 2>/dev/null || true)
            
            # If the local config doesn't exist or doesn't have an email, fallback to the registry one (legacy)
            if [[ -z "$expected_email" && -n "$email" ]]; then
                expected_email="$email"
            fi
        fi
    fi
done < "$GITSETU_CONF"

# If no profile matched this directory, allow commit
if [[ -z "$expected_email" ]]; then
    exit 0
fi

# Compare
if [[ "$actual_email" != "$expected_email" ]]; then
    printf '\n'
    printf '  \033[0;33m⚠\033[0m  \033[1mgitsetu: Identity mismatch detected!\033[0m\n'
    printf '     Expected: \033[0;32m%s\033[0m (profile: %s)\n' "$expected_email" "$expected_label"
    printf '     Actual:   \033[0;31m%s\033[0m\n' "$actual_email"
    printf '\n'
    printf '     Run \033[1mgitsetu status\033[0m to investigate.\n'
    printf '     Use \033[2m--no-verify\033[0m to skip this check.\n'
    printf '\n'
    exit 1
fi

# --- Pass-through to local repository hook ---
# If the repo has its own pre-commit hook (e.g., Husky, Lefthook), we MUST run it
local_hooks_path=$(git config --local core.hooksPath 2>/dev/null || echo ".git/hooks")

# Resolve absolute path for local hook
if [[ "$local_hooks_path" != /* ]]; then
    local_hooks_path="$current_dir/$local_hooks_path"
fi

if [[ -x "$local_hooks_path/pre-commit" ]]; then
    "$local_hooks_path/pre-commit" "$@"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        exit $exit_code
    fi
fi

exit 0
HOOK_SCRIPT

    chmod +x "$hook_path"
    local hooks_dir
    hooks_dir=$(normalize_path "$GITSETU_HOOKS_DIR")
    git config --global core.hooksPath "$hooks_dir"

    print_success "Guard hook installed: $hook_path"
    print_info "All repos will now check identity before commits."
    print_info "Use 'gitsetu guard --uninstall' to remove."
}

# ------------------------------------------------------------------------------
# uninstall_guard — Remove the pre-commit identity guard hook
#
# Removes the hook file and unsets core.hooksPath (only if it was gitsetu's).
#
# Usage: uninstall_guard
# ------------------------------------------------------------------------------
uninstall_guard() {
    local hook_path="$GITSETU_HOOKS_DIR/pre-commit"

    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would remove: $hook_path"
        print_info "[DRY RUN] Would unset core.hooksPath"
        return 0
    fi

    # Remove hook file
    if [[ -f "$hook_path" ]]; then
        rm -f "$hook_path"
        print_success "Removed guard hook: $hook_path"
    else
        print_info "No guard hook found at: $hook_path"
    fi

    # Unset core.hooksPath only if it points to our directory
    local current_hooks_path
    current_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)
    
    # Normalize slashes for Windows Git Bash paths (C:\ vs C:/ vs /c/)
    local normalized_current="${current_hooks_path//\\//}"
    local normalized_target="${GITSETU_HOOKS_DIR//\\//}"

    # Match exact path or suffix (to handle Windows C:/ vs /c/ drive letter differences)
    if [[ "$normalized_current" == "$normalized_target" ]] || [[ "$normalized_current" == *"/gitsetu/hooks" ]]; then
        git config --global --unset core.hooksPath
        print_success "Unset core.hooksPath"
    elif [[ -n "$current_hooks_path" ]]; then
        print_warning "core.hooksPath points to '$current_hooks_path' (not gitsetu). Leaving it."
    fi
}
