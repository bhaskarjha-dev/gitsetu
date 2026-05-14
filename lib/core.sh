#!/usr/bin/env bash
# shellcheck disable=SC2034  # All variables here are used by modules that source this file
# lib/core.sh — Constants, version, and global state for gitsetu
#
# This file is sourced by the main gitsetu script.
# All variables defined here are available to all other modules.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}

# ------------------------------------------------------------------------------
# Version
# ------------------------------------------------------------------------------

GITSETU_VERSION="1.1.0"

# ------------------------------------------------------------------------------
# Directory layout (XDG-compliant)
# ------------------------------------------------------------------------------

GITSETU_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu"
GITSETU_BACKUP_DIR="$GITSETU_CONFIG_DIR/backups"
GITSETU_PROFILES_DIR="$GITSETU_CONFIG_DIR/profiles"
GITSETU_HOOKS_DIR="$GITSETU_CONFIG_DIR/hooks"
GITSETU_PROFILES_CONF="$GITSETU_CONFIG_DIR/profiles.conf"

# ------------------------------------------------------------------------------
# Managed block markers
# Used to identify sections in config files that gitsetu owns.
# Everything between START and END markers is replaced on re-run (idempotent).
# Content outside these markers is never touched.
# ------------------------------------------------------------------------------

GITSETU_MARKER_PREFIX="# [gitsetu:managed"
GITSETU_MANAGED_START="# [gitsetu:managed:start]"
GITSETU_MANAGED_END="# [gitsetu:managed:end]"

# ------------------------------------------------------------------------------
# Profile state (collected during wizard)
#
# Bash 3.2 compat: using parallel indexed arrays instead of associative arrays.
# Index 0 is always the default/global profile.
# ------------------------------------------------------------------------------

PROFILE_LABELS=()
PROFILE_NAMES=()
PROFILE_EMAILS=()
PROFILE_DIRS=()
PROFILE_PROVIDERS=()
PROFILE_SIGNS=()
PROFILE_KEYS=()
PROFILE_USERS=()
PROFILE_PATS=()
PROFILE_COUNT=0

# ------------------------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------------------------

GITSETU_OS=""           # Set by detect_os(): linux, macos, wsl, gitbash, unknown
GITSETU_DRY_RUN=0      # Set to 1 by --dry-run flag
GITSETU_USE_PASSPHRASE=0 # Set to 1 to prompt for SSH passphrases

# ------------------------------------------------------------------------------
# load_profiles — Reads registry into arrays
# ------------------------------------------------------------------------------
load_profiles() {
    PROFILE_COUNT=0
    PROFILE_LABELS=()
    PROFILE_NAMES=()
    PROFILE_EMAILS=()
    PROFILE_DIRS=()
    PROFILE_PROVIDERS=()
    PROFILE_SIGNS=()
    PROFILE_KEYS=()
    PROFILE_USERS=()
    PROFILE_PATS=()
    
    if [[ ! -f "$GITSETU_PROFILES_CONF" ]]; then
        return 0
    fi
    local label email dir provider sign_commits key_path provider_user
    while IFS=: read -r label email dir provider sign_commits key_path provider_user || [[ -n "$label" ]]; do
        [[ "$label" == "#"* ]] && continue
        [[ -z "$label" ]] && continue
        PROFILE_LABELS+=("$label")
        PROFILE_DIRS+=("$dir")
        PROFILE_PROVIDERS+=("${provider:-github.com}")
        PROFILE_SIGNS+=("${sign_commits:-0}")
        PROFILE_KEYS+=("${key_path:-$HOME/.ssh/id_ed25519_${label}}")
        PROFILE_USERS+=("$provider_user")
        PROFILE_PATS+=("")
        
        # Load name and email from profile config
        local profile_path="$GITSETU_PROFILES_DIR/${label}.gitconfig"
        local loaded_name=""
        local loaded_email=""
        
        if [[ -f "$profile_path" ]]; then
            loaded_name=$(git config -f "$profile_path" user.name 2>/dev/null || echo "")
            loaded_email=$(git config -f "$profile_path" user.email 2>/dev/null || echo "")
        fi
        
        if [[ -z "$loaded_name" ]]; then
            loaded_name=$(git config --global user.name 2>/dev/null || echo "")
        fi
        PROFILE_NAMES+=("$loaded_name")
        
        # If email was provided in profiles.conf (legacy fallback) and wasn't found in .gitconfig, use it
        if [[ -z "$loaded_email" && -n "$email" ]]; then
            loaded_email="$email"
        fi
        PROFILE_EMAILS+=("$loaded_email")
        
        PROFILE_COUNT=$((PROFILE_COUNT + 1))
    done < "$GITSETU_PROFILES_CONF"
}
GITSETU_SCRIPT_DIR="${GITSETU_SCRIPT_DIR:-}"   # Preserve value set by main script

# ------------------------------------------------------------------------------
# Helper: lowercase a string (bash 3.2 compatible)
# Usage: result=$(to_lower "FooBar")
# ------------------------------------------------------------------------------
to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# ------------------------------------------------------------------------------
# Helper: check if a value exists in an indexed array
# Usage: array_contains "needle" "${haystack[@]}"
# Returns: 0 if found, 1 if not
# ------------------------------------------------------------------------------
array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# Helper: safely remove a profile by index (Bash 3.2 array slice drops empty strings)
# Usage: remove_profile_at_index <idx>
# ------------------------------------------------------------------------------
remove_profile_at_index() {
    local target_idx="$1"
    
    if [[ "$target_idx" -lt 0 ]] || [[ "$target_idx" -ge "$PROFILE_COUNT" ]]; then
        return 1
    fi
    
    local new_labels=()
    local new_names=()
    local new_emails=()
    local new_dirs=()
    local new_providers=()
    local new_signs=()
    local new_keys=()
    local new_users=()
    local new_pats=()
    
    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ "$i" -ne "$target_idx" ]]; then
            new_labels+=("${PROFILE_LABELS[$i]}")
            new_names+=("${PROFILE_NAMES[$i]}")
            new_emails+=("${PROFILE_EMAILS[$i]}")
            new_dirs+=("${PROFILE_DIRS[$i]}")
            new_providers+=("${PROFILE_PROVIDERS[$i]}")
            new_signs+=("${PROFILE_SIGNS[$i]}")
            new_keys+=("${PROFILE_KEYS[$i]}")
            new_users+=("${PROFILE_USERS[$i]:-}")
            new_pats+=("${PROFILE_PATS[$i]:-}")
        fi
    done
    
    PROFILE_LABELS=(${new_labels[@]+"${new_labels[@]}"})
    PROFILE_NAMES=(${new_names[@]+"${new_names[@]}"})
    PROFILE_EMAILS=(${new_emails[@]+"${new_emails[@]}"})
    PROFILE_DIRS=(${new_dirs[@]+"${new_dirs[@]}"})
    PROFILE_PROVIDERS=(${new_providers[@]+"${new_providers[@]}"})
    PROFILE_SIGNS=(${new_signs[@]+"${new_signs[@]}"})
    PROFILE_KEYS=(${new_keys[@]+"${new_keys[@]}"})
    PROFILE_USERS=(${new_users[@]+"${new_users[@]}"})
    PROFILE_PATS=(${new_pats[@]+"${new_pats[@]}"})
    
    PROFILE_COUNT=$((PROFILE_COUNT - 1))
    return 0
}
