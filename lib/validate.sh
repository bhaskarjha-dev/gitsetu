#!/usr/bin/env bash
# lib/validate.sh — Input validation functions
#
# All validators return 0 for valid, 1 for invalid.
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# validate_email — Basic email format check
#
# Checks: contains @, has text before @, has a dot after @.
# This is NOT a full RFC 5322 check — just catches obvious typos.
#
# Usage: if validate_email "user@example.com"; then ...
# ------------------------------------------------------------------------------
validate_email() {
    local email="$1"

    # Must not be empty
    if [[ -z "$email" ]]; then
        return 1
    fi

    # Must not contain newlines or carriage returns (prevents INI injection)
    if [[ "$email" == *$'\n'* ]] || [[ "$email" == *$'\r'* ]]; then
        return 1
    fi

    # Must contain @
    if [[ "$email" != *"@"* ]]; then
        return 1
    fi

    # Must have text before @
    local local_part="${email%%@*}"
    if [[ -z "$local_part" ]]; then
        return 1
    fi

    # Must have a dot in the domain part
    local domain_part="${email#*@}"
    if [[ "$domain_part" != *.* ]]; then
        return 1
    fi

    # Domain part must not be empty after the dot
    local tld="${domain_part##*.}"
    if [[ -z "$tld" ]]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# validate_github_noreply_email — Check if email matches GitHub's strict mask
#
# Rules:
#   - Format: ID+username@users.noreply.github.com
#
# Usage: if validate_github_noreply_email "123+name@users.noreply.github.com"; then ...
# ------------------------------------------------------------------------------
validate_github_noreply_email() {
    local email="$1"
    
    if [[ -z "$email" ]]; then
        return 1
    fi

    local github_regex="^[0-9]+\+[a-zA-Z0-9_-]+@users\.noreply\.github\.com$"
    if [[ ! "$email" =~ $github_regex ]]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# validate_label — Profile label validation
#
# Rules:
#   - Lowercase alphanumeric and hyphens only
#   - Must start with a letter
#   - 1-20 characters
#   - No spaces
#
# Usage: if validate_label "work-client"; then ...
# ------------------------------------------------------------------------------
validate_label() {
    local label="$1"

    # Must not be empty
    if [[ -z "$label" ]]; then
        return 1
    fi

    # Length check (1-20)
    if [[ "${#label}" -gt 20 ]]; then
        return 1
    fi

    # Must match pattern: starts with letter, then alphanumeric or hyphen
    # Bash 3.2 compatible regex
    if ! printf '%s' "$label" | grep -qE '^[a-z][a-z0-9-]*$'; then
        return 1
    fi

    # Must not end with hyphen
    if [[ "$label" == *"-" ]]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# validate_path — Directory path validation
#
# Checks: path exists, OR parent directory exists and is writable.
# Expands tilde via normalize_path before checking.
#
# Usage: if validate_path "~/dev/work"; then ...
# ------------------------------------------------------------------------------
validate_path() {
    local path="$1"

    # Must not be empty
    if [[ -z "$path" ]]; then
        return 1
    fi

    # Normalize (expand tilde, etc.)
    path=$(normalize_path "$path")

    # If directory exists, valid
    if [[ -d "$path" ]]; then
        return 0
    fi

    # Recursively check if the nearest existing ancestor is writable
    local current="$path"
    while [[ "$current" != "/" && "$current" != "." ]]; do
        local parent
        parent=$(dirname "$current")
        if [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
        if [[ -d "$current" ]]; then
            if [[ -w "$current" ]]; then
                return 0
            else
                return 1
            fi
        fi
    done

    return 1
}


# ------------------------------------------------------------------------------
# validate_key_name — SSH key filename validation
#
# Allowed: a-z, A-Z, 0-9, underscore, hyphen
# No spaces, no dots, no special characters.
#
# Usage: if validate_key_name "id_ed25519_work"; then ...
# ------------------------------------------------------------------------------
validate_key_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        return 1
    fi

    if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        return 1
    fi

    return 0
}
