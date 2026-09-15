#!/usr/bin/env bash
# lib/backup.sh — Timestamped backup and restore of configuration files
#
# Ensures no data is ever lost during gitsetu setup.
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# ensure_dirs — Create all required gitsetu directories
#
# Called at the start of setup. Idempotent.
# ------------------------------------------------------------------------------
ensure_dirs() {
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        return 0
    fi
    mkdir -p "$GITSETU_CONFIG_DIR" 2>/dev/null || true
    mkdir -p "$GITSETU_BACKUP_DIR" 2>/dev/null || true
    mkdir -p "$GITSETU_PROFILES_DIR" 2>/dev/null || true
    mkdir -p "$GITSETU_HOOKS_DIR" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# backup_file — Create a timestamped backup of a file
#
# Copies the file to $GITSETU_BACKUP_DIR/<basename>.<ISO-timestamp>.bak
# Preserves permissions with cp -p.
#
# Usage: backup_file "$HOME/.gitconfig"
# Returns: 0 on success, 1 if source doesn't exist
# ------------------------------------------------------------------------------
backup_file() {
    local source_path="$1"

    if [[ ! -f "$source_path" ]]; then
        return 1
    fi

    ensure_dirs

    local basename
    basename=$(basename "$source_path")

    local timestamp
    timestamp=$(date +%Y%m%dT%H%M%S)

    local backup_path="$GITSETU_BACKUP_DIR/${basename}.${timestamp}.bak"

    # Avoid overwriting if backup from same second exists (unlikely but safe)
    local counter=1
    while [[ -f "$backup_path" ]]; do
        backup_path="$GITSETU_BACKUP_DIR/${basename}.${timestamp}.${counter}.bak"
        counter=$((counter + 1))
    done

    if cp -p "$source_path" "$backup_path" 2>/dev/null; then
        print_info "Backed up: $source_path → $backup_path"
        return 0
    else
        print_error "Failed to backup: $source_path"
        return 1
    fi
}


# ------------------------------------------------------------------------------
# get_openssl_args — Cross-platform OpenSSL probing
# ------------------------------------------------------------------------------
get_openssl_args() {
    if openssl enc -help 2>&1 | grep -q -- "-pbkdf2"; then
        echo "-pbkdf2 -iter 100000"
    else
        echo "-md sha256"
    fi
}

# ------------------------------------------------------------------------------
# _collect_ssh_key_paths — Enumerate SSH key files managed by GitSetu
#
# Scans profiles.conf for key paths and collects those that exist on disk.
# Outputs paths relative to $HOME (for tar bundling), one per line.
# ------------------------------------------------------------------------------
_collect_ssh_key_paths() {
    local key_files=()

    if [[ -f "$GITSETU_PROFILES_CONF" ]]; then
        local raw_line
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            [[ "$raw_line" == "#"* ]] && continue
            [[ -z "$raw_line" ]] && continue
            
            # Protect Windows drive letters from IFS=: splitting
            local clean_line
            clean_line=$(printf '%s' "$raw_line" | sed -E 's/:([a-zA-Z]):/:\1#DRIVE#/g')
            local _label _email _dir _provider _sign _kpath _puser
            IFS=: read -r _label _email _dir _provider _sign _kpath _puser <<< "$clean_line"
            _dir="${_dir//#DRIVE#/:}"
            _kpath="${_kpath//#DRIVE#/:}"

            _kpath="${_kpath:-$HOME/.ssh/id_ed25519_${_label}}"
            if [[ "$_kpath" == "~/"* ]]; then
                _kpath="$HOME/${_kpath:2}"
            elif [[ "$_kpath" == "~" ]]; then
                _kpath="$HOME"
            fi
            local norm_kpath norm_home
            norm_kpath=$(normalize_path "$_kpath")
            norm_home=$(normalize_path "$HOME")
            if [[ -f "$_kpath" ]] || [[ -f "$norm_kpath" ]]; then
                # Convert absolute path to path relative to $HOME for tar
                local rel
                if [[ "$norm_kpath" == "$norm_home/"* ]]; then
                    rel="${norm_kpath#"$norm_home"/}"
                elif [[ "$_kpath" == "$HOME/"* ]]; then
                    rel="${_kpath#"$HOME"/}"
                elif [[ "$_kpath" =~ (\.ssh/.*)$ ]]; then
                    rel="${BASH_REMATCH[1]}"
                else
                    rel="$_kpath"
                fi
                key_files+=("$rel")
                if [[ -f "${_kpath}.pub" ]] || [[ -f "${norm_kpath}.pub" ]]; then
                    key_files+=("${rel}.pub")
                fi
            fi
        done < "$GITSETU_PROFILES_CONF"
    fi

    local kf
    for kf in ${key_files[@]+"${key_files[@]}"}; do
        printf '%s\n' "$kf"
    done
}

# ------------------------------------------------------------------------------
# cmd_backup — Full State Encrypted Backup
# ------------------------------------------------------------------------------
cmd_backup() {
    local out_file="${1:-}"

    # Check if there is any GitSetu state to backup
    local has_state=0
    [[ -d "$GITSETU_CONFIG_DIR" ]] && has_state=1
    if [[ "$has_state" -eq 0 ]] && [[ -f "$GITSETU_PROFILES_CONF" ]]; then
        has_state=1
    fi
    if [[ "$has_state" -eq 0 ]]; then
        print_error "No GitSetu state found to backup."
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [[ -z "$out_file" ]]; then
        out_file="gitsetu_vault_${timestamp}.tar.gz.enc"
    fi

    # Secure temporary directory created with mode 0700 under umask 077
    local temp_dir
    temp_dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/gitsetu_vault.XXXXXX")
    GITSETU_CLEANUP_DIRS+=("$temp_dir")
    local temp_tar="$temp_dir/gitsetu_vault.tar.gz"

    # Bundle: config directory + individual SSH key files from registry
    local tar_args=()
    if [[ -d "$GITSETU_CONFIG_DIR" ]]; then
        local norm_cfg norm_home rel_cfg
        norm_cfg=$(normalize_path "$GITSETU_CONFIG_DIR")
        norm_home=$(normalize_path "$HOME")
        if [[ "$norm_cfg" == "$norm_home/"* ]]; then
            rel_cfg="${norm_cfg#"$norm_home"/}"
        elif [[ "$GITSETU_CONFIG_DIR" == "$HOME/"* ]]; then
            rel_cfg="${GITSETU_CONFIG_DIR#"$HOME"/}"
        elif [[ "$GITSETU_CONFIG_DIR" =~ (\.config/gitsetu.*)$ ]]; then
            rel_cfg="${BASH_REMATCH[1]}"
        elif [[ "$norm_cfg" =~ (\.config/gitsetu.*)$ ]]; then
            rel_cfg="${BASH_REMATCH[1]}"
        else
            rel_cfg="$GITSETU_CONFIG_DIR"
        fi
        tar_args+=("$rel_cfg")
    fi

    local key_path
    while IFS= read -r key_path; do
        [[ -n "$key_path" ]] && tar_args+=("$key_path")
    done < <(_collect_ssh_key_paths)

    if [[ ${#tar_args[@]} -eq 0 ]]; then
        print_error "No state files found to backup."
        rm -rf "$temp_dir"
        return 1
    fi

    if ! (umask 077 && tar -czf "$temp_tar" -C "$HOME" "${tar_args[@]}" 2>/dev/null); then
        print_error "Failed to compress state directories."
        rm -rf "$temp_dir"
        return 1
    fi

    printf >&2 "  %bLocking Vault%b\n" "$BOLD" "$RESET"

    local password
    if [[ -n "${GITSETU_TEST_VAULT_PASS:-}" ]]; then
        password="$GITSETU_TEST_VAULT_PASS"
    else
        ask_password "Enter a strong password to encrypt the vault: "
        password="$REPLY"
        ask_password "Confirm password: "
        local confirm="$REPLY"

        if [[ "$password" != "$confirm" ]]; then
            print_error "Passwords do not match. Backup aborted."
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    local ssl_args=("-aes-256-cbc" "-salt")
    local -a extra_ssl_args=()
    read -r -a extra_ssl_args <<< "$(get_openssl_args)"
    ssl_args+=("${extra_ssl_args[@]}")

    # Pass password directly via stdin to prevent process environment or table leakage
    if (umask 077 && printf '%s\n' "$password" | openssl enc "${ssl_args[@]}" -in "$temp_tar" -out "$out_file" -pass stdin 2>/dev/null); then
        chmod 600 "$out_file" 2>/dev/null || true
        print_success "Vault created successfully: $out_file"
    else
        print_error "Encryption failed."
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"
    return 0
}

# ------------------------------------------------------------------------------
# cmd_restore — Import and regenerate state from an encrypted vault
# ------------------------------------------------------------------------------
cmd_restore() {
    local in_file="$1"

    if [[ -z "$in_file" ]] || [[ ! -f "$in_file" ]]; then
        print_error "Vault file not found: $in_file"
        return 1
    fi

    printf >&2 "  %bUnlocking Vault%b\n" "$BOLD" "$RESET"
    local password
    if [[ -n "${GITSETU_TEST_VAULT_PASS:-}" ]]; then
        password="$GITSETU_TEST_VAULT_PASS"
    else
        ask_password "Enter vault password: "
        password="$REPLY"
    fi

    local ssl_args=("-d" "-aes-256-cbc" "-salt")
    local -a extra_ssl_args=()
    read -r -a extra_ssl_args <<< "$(get_openssl_args)"
    ssl_args+=("${extra_ssl_args[@]}")

    # Secure temporary directory created with mode 0700 under umask 077
    local temp_dir
    temp_dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/gitsetu_vault.XXXXXX")
    GITSETU_CLEANUP_DIRS+=("$temp_dir")
    local temp_tar="$temp_dir/gitsetu_vault.tar.gz"

    # Pass password via stdin to prevent process environment leakage
    if ! (umask 077 && printf '%s\n' "$password" | openssl enc "${ssl_args[@]}" -in "$in_file" -out "$temp_tar" -pass stdin 2>/dev/null); then
        print_error "Decryption failed. Incorrect password or corrupted vault."
        rm -rf "$temp_dir"
        return 1
    fi

    if type acquire_lock >/dev/null 2>&1; then
        acquire_lock || { rm -rf "$temp_dir"; return 1; }
    fi

    # Pre-Flight Safety Net
    local has_active_state=0
    if [[ -f "$GITSETU_PROFILES_CONF" ]] || [[ -d "$GITSETU_CONFIG_DIR/profiles" ]]; then
        has_active_state=1
    elif [[ -d "$GITSETU_CONFIG_DIR" ]]; then
        local item
        for item in "$GITSETU_CONFIG_DIR"/*; do
            if [[ -e "$item" ]] && [[ "$item" != *.lock ]]; then
                has_active_state=1
                break
            fi
        done
    fi

    if [[ "$has_active_state" -eq 1 ]]; then
        print_warning "Active state detected. Creating pre-restore safety backup..."
        local safety_pass
        safety_pass=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)
        local safety_file
        safety_file="gitsetu_vault_pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz.enc"
        local saved_test_pass="${GITSETU_TEST_VAULT_PASS:-}"
        export GITSETU_TEST_VAULT_PASS="$safety_pass"
        cmd_backup "$safety_file" >/dev/null 2>&1 || {
            rm -rf "$temp_dir"
            if type release_lock >/dev/null 2>&1; then release_lock; fi
            return 1
        }
        if [[ -n "$saved_test_pass" ]]; then
            export GITSETU_TEST_VAULT_PASS="$saved_test_pass"
        else
            unset GITSETU_TEST_VAULT_PASS
        fi
        # Store password adjacent to vault with mode 0600 from inception
        (umask 077 && printf '%s\n' "$safety_pass" > "${safety_file}.password")
        chmod 600 "${safety_file}.password" 2>/dev/null || true
        print_info "Safety vault: $safety_file (password in ${safety_file}.password)"
        
        # Teardown current global configs to avoid duplicate block drift
        if type teardown_all >/dev/null 2>&1; then
            teardown_all >/dev/null 2>&1 || true
        fi
        local f
        for f in "$GITSETU_CONFIG_DIR"/*; do
            if [[ "$f" != *.lock ]]; then
                rm -rf "$f" 2>/dev/null || true
            fi
        done
    fi

    # Validate archive members against path traversal before extraction
    local bad_paths
    bad_paths=$(tar -tzf "$temp_tar" 2>/dev/null | grep -E '^/|\.\./' || true)
    if [[ -n "$bad_paths" ]]; then
        print_error "Security violation: backup archive contains prohibited path traversal entries."
        rm -rf "$temp_dir"
        if type release_lock >/dev/null 2>&1; then release_lock; fi
        return 1
    fi

    mkdir -p "$HOME/.config" "$HOME/.ssh"
    if ! tar -xzf "$temp_tar" -C "$HOME" 2>/dev/null; then
        print_error "Failed to extract vault."
        rm -rf "$temp_dir"
        if type release_lock >/dev/null 2>&1; then release_lock; fi
        return 1
    fi

    rm -rf "$temp_dir"
    print_success "State successfully extracted."

    # Regenerate global Git and SSH state from the restored profiles
    print_info "Regenerating global hooks and configurations..."
    if type write_global_gitconfig >/dev/null 2>&1; then
        # Load profile data from the restored registry + gitconfig files
        load_profiles

        write_global_gitconfig

        # Reinstall identity guard hook
        if type install_guard >/dev/null 2>&1; then
            install_guard >/dev/null 2>&1 || true
        fi

        # Regenerate per-profile gitconfigs (name/email sourced from restored .gitconfig files)
        local i
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            write_profile_gitconfig "${PROFILE_LABELS[$i]}" "${PROFILE_NAMES[$i]}" \
                "${PROFILE_EMAILS[$i]}" "${PROFILE_SIGNS[$i]}" "${PROFILE_KEYS[$i]}" \
                "${PROFILE_PROVIDERS[$i]}" "${PROFILE_USERS[$i]:-}"
        done

        # Regenerate SSH config (one call writes all host blocks)
        write_ssh_config
    fi

    if type release_lock >/dev/null 2>&1; then
        release_lock
    fi

    print_success "Restore complete. Your identity is active."
    return 0
}
