#!/usr/bin/env bash
# lib/keychain.sh — OS-level keychain wrapper for Git credential management
#
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# keychain_store — Securely store a credential in the OS keychain
#
# Usage: keychain_store "$profile" "$host" "$username" "$token"
# ------------------------------------------------------------------------------
keychain_store() {
    local profile="$1"
    local host="$2"
    local username="$3"
    local token="$4"

    local service_name="gitsetu:${profile}:${host}"

    case "$GITSETU_OS" in
        macos)
            if command -v security >/dev/null 2>&1; then
                # Delete existing to prevent duplication errors
                security delete-internet-password -s "$service_name" >/dev/null 2>&1 || true
                security add-internet-password -s "$service_name" -a "$username" -w "$token" >/dev/null 2>&1
                return $?
            fi
            ;;
        linux)
            if command -v secret-tool >/dev/null 2>&1; then
                printf "%s" "$token" | secret-tool store --label="GitSetu ($profile) $host" gitsetu "$profile" host "$host" user "$username" >/dev/null 2>&1
                return $?
            fi
            ;;
    esac

    # Fallback to local file if OS tools are missing or unsupported (WSL/GitBash)
    local tokens_file="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/.tokens"
    touch "$tokens_file"
    
    # Remove existing entry
    if [[ -f "$tokens_file" ]]; then
        local tmp_file="${TMPDIR:-/tmp}/gitsetu_tokens_$$_${RANDOM}"
        GITSETU_CLEANUP_FILES+=("$tmp_file")
        awk -v s="$service_name" -F':' '$1":"$2":"$3 != s' "$tokens_file" > "$tmp_file"
        mv "$tmp_file" "$tokens_file"
    fi
    
    # Append new entry (service_name:username:token)
    echo "${service_name}:${username}:${token}" >> "$tokens_file"
    # Set restrictive permissions AFTER all writes (mv replaces inode, so chmod must come last)
    chmod 600 "$tokens_file"
    return 0
}

# ------------------------------------------------------------------------------
# keychain_get — Retrieve a credential from the OS keychain
#
# Usage: keychain_get "$profile" "$host"
# Outputs:
#   username=<username>
#   password=<token>
# ------------------------------------------------------------------------------
keychain_get() {
    local profile="$1"
    local host="$2"
    local service_name="gitsetu:${profile}:${host}"

    case "$GITSETU_OS" in
        macos)
            if command -v security >/dev/null 2>&1; then
                local out pass user
                # Fetch password and attributes
                if out=$(security find-internet-password -s "$service_name" -g 2>&1); then
                    pass=$(printf "%s" "$out" | grep "password:" | cut -d'"' -f2)
                    user=$(printf "%s" "$out" | grep "\"acct\"<blob>=" | cut -d'"' -f4)
                    if [[ -n "$user" ]] && [[ -n "$pass" ]]; then
                        printf "username=%s\npassword=%s\n" "$user" "$pass"
                        return 0
                    fi
                fi
                return 1
            fi
            ;;
        linux)
            if command -v secret-tool >/dev/null 2>&1; then
                # On Linux, secret-tool lookup only returns the password. 
                # We need the username. But we didn't store the username as an output of lookup, 
                # wait, secret-tool lookup searches by attributes. 
                # If we do `secret-tool search gitsetu $profile host $host`, it returns attributes.
                local search_out
                search_out=$(secret-tool search gitsetu "$profile" host "$host" 2>/dev/null)
                if [[ -n "$search_out" ]]; then
                    local user pass
                    user=$(printf "%s" "$search_out" | grep "user = " | cut -d' ' -f3-)
                    pass=$(secret-tool lookup gitsetu "$profile" host "$host" 2>/dev/null)
                    if [[ -n "$user" ]] && [[ -n "$pass" ]]; then
                        printf "username=%s\npassword=%s\n" "$user" "$pass"
                        return 0
                    fi
                fi
                return 1
            fi
            ;;
    esac

    # Fallback to local file
    local tokens_file="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/.tokens"
    if [[ -f "$tokens_file" ]]; then
        local entry
        entry=$(grep "^${service_name}:" "$tokens_file" 2>/dev/null || true)
        if [[ -n "$entry" ]]; then
            # Format: gitsetu:profile:host:username:token
            # We know service_name has 2 colons. So fields 4 and 5 are user and token.
            local user token
            user=$(printf "%s" "$entry" | cut -d':' -f4)
            token=$(printf "%s" "$entry" | cut -d':' -f5-)
            if [[ -n "$user" ]] && [[ -n "$token" ]]; then
                printf "username=%s\npassword=%s\n" "$user" "$token"
                return 0
            fi
        fi
    fi

    return 1
}

# ------------------------------------------------------------------------------
# keychain_erase — Remove a credential from the OS keychain
#
# Usage: keychain_erase "$profile" "$host"
# ------------------------------------------------------------------------------
keychain_erase() {
    local profile="$1"
    local host="$2"
    local service_name="gitsetu:${profile}:${host}"

    case "$GITSETU_OS" in
        macos)
            if command -v security >/dev/null 2>&1; then
                security delete-internet-password -s "$service_name" >/dev/null 2>&1 || true
                return 0
            fi
            ;;
        linux)
            if command -v secret-tool >/dev/null 2>&1; then
                secret-tool clear gitsetu "$profile" host "$host" >/dev/null 2>&1 || true
                return 0
            fi
            ;;
    esac

    # Fallback to local file
    local tokens_file="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/.tokens"
    if [[ -f "$tokens_file" ]]; then
        local tmp_file="${TMPDIR:-/tmp}/gitsetu_tokens_$$_${RANDOM}"
        GITSETU_CLEANUP_FILES+=("$tmp_file")
        awk -v s="$service_name" -F':' '$1":"$2":"$3 != s' "$tokens_file" > "$tmp_file"
        mv "$tmp_file" "$tokens_file"
    fi
    return 0
}
