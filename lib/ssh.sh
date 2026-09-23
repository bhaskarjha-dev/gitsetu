#!/usr/bin/env bash
# lib/ssh.sh — SSH key generation and ~/.ssh/config management
#
# Generates Ed25519 keys per profile and creates host alias blocks
# in ~/.ssh/config for the clone workflow.
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# generate_ssh_key — Generate an Ed25519 SSH key pair for a profile
#
# Creates: $HOME/.ssh/id_ed25519_<label> (private) and .pub (public)
# If key exists: prompts user to skip, rename old, or overwrite.
#
# Usage: generate_ssh_key "pro" "user@example.com"
# Returns: 0 on success/skip, 1 on failure
# ------------------------------------------------------------------------------
generate_ssh_key() {
    local label="$1"
    local email="$2"
    local key_path="${3:-$HOME/.ssh/id_ed25519_${label}}"

    # Warn if ~/.ssh is on a shared mount
    if is_shared_mount "$HOME/.ssh" 2>/dev/null; then
        # shellcheck disable=SC2088  # Tilde is in a display string, not a path
        print_warning "~/.ssh appears to be on a shared folder (VirtualBox/VMware)."
        print_warning "SSH keys require strict permissions (600) which shared folders cannot enforce."
        print_info "Consider storing keys on the native filesystem instead."
    fi

    # Create ~/.ssh if it doesn't exist
    if [[ ! -d "$HOME/.ssh" ]]; then
        mkdir -p "$HOME/.ssh"
        print_step "Created ~/.ssh directory"
    fi
    chmod 700 "$HOME/.ssh"

    # Check if key already exists
    if [[ -f "$key_path" ]]; then
        print_warning "SSH key already exists: $key_path"

        if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
            print_info "[DRY RUN] Would prompt for action on existing key"
            return 0
        fi

        if [[ "${GITSETU_AUTO_MODE:-0}" -eq 1 ]]; then
            print_info "Auto-mode: keeping existing key for '$label'"
            return 0
        fi

        ask_choice "What to do with existing key?" "skip (keep current)" "rename old key" "overwrite"

        case "$REPLY" in
            "skip (keep current)")
                print_info "Keeping existing key for '$label'"
                return 0
                ;;
            "rename old key")
                local timestamp
                timestamp=$(date +%Y%m%dT%H%M%S)
                mv "$key_path" "${key_path}.old.${timestamp}"
                mv "${key_path}.pub" "${key_path}.pub.old.${timestamp}" 2>/dev/null || true
                print_info "Renamed old key to ${key_path}.old.${timestamp}"
                ;;
            "overwrite")
                print_info "Overwriting existing key for '$label'"
                ;;
        esac
    fi

    # Dry run: just show what would happen
    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would generate: $key_path"
        print_info "[DRY RUN] ssh-keygen -t ed25519 -C \"$email\" -f \"$key_path\" -N \"\""
        return 0
    fi

    # Generate the key
    print_step "Generating SSH key for '$label'..."

    # Check if FIDO2 hardware key was requested based on filename convention
    local key_type="ed25519"
    local -a fido_args=()
    if [[ "$key_path" == *"_sk_"* ]]; then
        key_type="ed25519-sk"
        fido_args=(-O resident -O verify-required)
        print_info "Hardware Security Key detected. Please TOUCH YOUR YUBIKEY when prompted."
    fi

    if [[ "${GITSETU_USE_PASSPHRASE:-0}" -eq 1 ]]; then
        # Prompt user for passphrase interactively
        ssh-keygen -t "$key_type" ${fido_args[@]+"${fido_args[@]}"} -C "$email" -f "$key_path"
        local status=$?
    elif [[ "$key_type" == "ed25519-sk" ]]; then
        # FIDO2 touch without passphrase prompt
        ssh-keygen -t "$key_type" ${fido_args[@]+"${fido_args[@]}"} -C "$email" -f "$key_path" -N ""
        local status=$?
    else
        # Password-less standard key (instant, synchronous, Bash 3.2+ compatible)
        ssh-keygen -t "$key_type" -C "$email" -f "$key_path" -N "" -q
        local status=$?
    fi

    # FIDO2 Fallback Mechanism
    if [[ "$status" -ne 0 ]] && [[ "$key_type" == "ed25519-sk" ]]; then
        print_warning "Hardware Security Key enrollment failed (missing device or libfido2 unsupported)."
        print_info "Falling back to standard ed25519 software key generation..."
        
        key_type="ed25519"
        fido_args=()
        if [[ "${GITSETU_USE_PASSPHRASE:-0}" -eq 1 ]]; then
            ssh-keygen -t "$key_type" -C "$email" -f "$key_path"
            status=$?
        else
            ssh-keygen -t "$key_type" -C "$email" -f "$key_path" -N "" -q
            status=$?
        fi
    fi

    if [[ "$status" -eq 0 ]]; then
        chmod 600 "$key_path" 2>/dev/null || true
        chmod 644 "${key_path}.pub" 2>/dev/null || true
        print_success "Created: $key_path"
        return 0
    else
        print_error "Failed to generate SSH key for '$label'"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# build_ssh_host_block — Generate a single Host block for ~/.ssh/config
#
# Usage: block=$(build_ssh_host_block "pro" "github.com")
# Output: formatted Host block with managed markers
# ------------------------------------------------------------------------------
build_ssh_host_block() {
    local label="$1"
    local hostname="${2:-github.com}"
    local key_path="${3:-$HOME/.ssh/id_ed25519_${label}}"
    
    # Use portable home relative path if key is inside ~/.ssh or $HOME
    local portable_key="$key_path"
    if [[ "$key_path" == "$HOME/.ssh/"* ]] || [[ "$key_path" =~ (\.ssh/.*)$ ]]; then
        portable_key="~/.ssh/${key_path##*/}"
    elif [[ "$key_path" == "$HOME/"* ]]; then
        portable_key="~/${key_path#"$HOME"/}"
    fi

    # Extract the main part of the domain (e.g., gitlab.com -> gitlab) for the alias prefix
    local prefix
    prefix=$(printf '%s' "$hostname" | cut -d'.' -f1)

    if [[ "${GITSETU_PORT443_NEEDED:-0}" -eq 1 ]] && [[ "$hostname" == *"github"* ]]; then
        cat <<EOF
Host ${prefix}-${label}
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ${portable_key}
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
    else
        cat <<EOF
Host ${prefix}-${label}
    HostName ${hostname}
    User git
    IdentityFile ${portable_key}
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
    fi

    if [[ "${GITSETU_OS:-}" == "macos" || "${OSTYPE:-}" == "darwin"* ]]; then
        echo "    UseKeychain yes"
    fi
}

# ------------------------------------------------------------------------------
# write_ssh_config — Update ~/.ssh/config with gitsetu-managed host blocks
#
# Strategy (Phase 1 Pivot):
#   1. Write all host aliases to an isolated file (~/.config/gitsetu/profiles/ssh_config)
#   2. Ensure 'Include ~/.config/gitsetu/profiles/ssh_config' is the FIRST line of ~/.ssh/config
#   3. Remove any legacy inline managed blocks from ~/.ssh/config
#
# This achieves 100% Zero-Trust isolation while respecting OpenSSH's "first-match wins" rule.
# Usage: write_ssh_config
# ------------------------------------------------------------------------------
write_ssh_config() {
    local ssh_config="$HOME/.ssh/config"
    local isolated_config="$GITSETU_PROFILES_DIR/ssh_config"
    local include_path="$isolated_config"
    if [[ "$isolated_config" == "$HOME/"* ]]; then
        include_path="~/${isolated_config#"$HOME"/}"
    elif [[ "$isolated_config" =~ (\.config/.*)$ ]]; then
        include_path="~/${BASH_REMATCH[1]}"
    fi
    local include_directive="Include ${include_path}"

    # Create ~/.ssh if needed
    if [[ ! -d "$HOME/.ssh" ]]; then
        mkdir -p "$HOME/.ssh"
    fi
    chmod 700 "$HOME/.ssh" 2>/dev/null || true

    # Create isolated profiles directory if needed
    if [[ ! -d "$GITSETU_PROFILES_DIR" ]]; then
        mkdir -p "$GITSETU_PROFILES_DIR"
    fi

    # Dry run
    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would prepend to: $ssh_config"
        print_info "          $include_directive"
        print_info "[DRY RUN] Would write host aliases to: $isolated_config"
        return 0
    fi

    # 1. Legacy Migration: Remove any old inline managed blocks
    if [[ -f "$ssh_config" ]] && grep -q "\[gitsetu:managed:start\]" "$ssh_config" 2>/dev/null; then
        local tmp_legacy
        tmp_legacy=$(mktemp "${ssh_config}.tmp.legacy.XXXXXX")
        GITSETU_CLEANUP_FILES+=("$tmp_legacy")

        awk '
            BEGIN { in_block=0 }
            /\[gitsetu:managed:start\]/ { in_block=1; next }
            in_block && /\[gitsetu:managed:end\]/ { in_block=0; next }
            in_block { next }
            !in_block { print }
        ' "$ssh_config" > "$tmp_legacy"
        
        backup_file "$ssh_config"
        mv "$tmp_legacy" "$ssh_config"
        print_info "Migrated legacy inline blocks from ~/.ssh/config"
    fi

    # 2. Write the isolated GitSetu ssh_config
    # We overwrite it completely every time, achieving 100% idempotency
    echo "# Generated by gitsetu v${GITSETU_VERSION} on $(date +%Y-%m-%d)" > "$isolated_config"
    echo "# Do not edit this file directly. It is overwritten by gitsetu." >> "$isolated_config"
    
    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local label="${PROFILE_LABELS[$i]}"
        local provider="${PROFILE_PROVIDERS[$i]:-github.com}"
        local key_path="${PROFILE_KEYS[$i]:-$HOME/.ssh/id_ed25519_${label}}"
        printf '\n' >> "$isolated_config"
        build_ssh_host_block "$label" "$provider" "$key_path" >> "$isolated_config"
    done
    chmod 600 "$isolated_config"

    # 3. Ensure the Include directive is at the absolute top of the global ~/.ssh/config
    if [[ ! -f "$ssh_config" ]]; then
        # File doesn't exist, simply create it with the Include line
        echo "$include_directive" > "$ssh_config"
        chmod 600 "$ssh_config"
        print_success "Created: $ssh_config (with isolated Include directive)"
    else
        # File exists. Check if the exact Include line is already the very first line.
        local first_line
        first_line=$(head -n 1 "$ssh_config" 2>/dev/null || true)
        
        if [[ "$first_line" != "$include_directive" ]]; then
            # We must prepend it. First, remove any stray instances of our Include anywhere else in the file.
            local tmp_prepend
            tmp_prepend=$(mktemp "${ssh_config}.tmp.prepend.XXXXXX")
            GITSETU_CLEANUP_FILES+=("$tmp_prepend")
            
            # Print the Include line first
            echo "$include_directive" > "$tmp_prepend"
            
            # Then append the rest of the file, stripping out any old instances of our Include directive
            grep -v -F "$include_directive" "$ssh_config" | grep -v -F "Include $isolated_config" >> "$tmp_prepend" || true
            
            # Safely swap
            backup_file "$ssh_config"
            mv "$tmp_prepend" "$ssh_config"
            chmod 600 "$ssh_config"
            print_success "Prepended isolated Include directive to: $ssh_config"
        else
            print_success "Verified isolated Include directive in: $ssh_config"
        fi
    fi
}

# ------------------------------------------------------------------------------
# try_gh_key_upload — Upload an SSH public key to GitHub via gh CLI
#
# Locked Constraint: Scope discipline — only interacts with currently authenticated
# account via `gh api user -q .login`. No multi-account detection, no auth switch.
#
# Usage: try_gh_key_upload "work" "/path/to/key.pub"
# Returns: 0 on success or already registered, 1 on failure / skipped / declined
# ------------------------------------------------------------------------------
try_gh_key_upload() {
    local label="$1"
    local pubkey_path="$2"

    # a) Check if gh is installed
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi

    # Validate key file existence
    if [[ ! -f "$pubkey_path" ]]; then
        return 1
    fi

    # b) Get login username
    local login
    login=$(gh api user -q .login 2>/dev/null || true)
    login="${login%$'\r'}"
    if [[ -z "$login" ]]; then
        return 1
    fi

    # Dry run check: suppress mutation
    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would upload '$label' key to GitHub (@$login)"
        return 0
    fi

    # c) If non-TTY or GITSETU_TEST is set, do NOT prompt interactively — skip or return 1 (unless mock is testing it)
    if [[ -n "${GITSETU_TEST:-}" ]]; then
        local is_mock=0
        if [[ -n "${GITSETU_TEST_GH:-}" || -n "${GITSETU_TEST_GH_MOCK:-}" ]]; then
            is_mock=1
        elif [[ "$(type -t gh 2>/dev/null)" == "function" ]]; then
            is_mock=1
        elif [[ -n "${TEST_HOME:-}" && "$(command -v gh 2>/dev/null)" == *"$TEST_HOME"* ]]; then
            is_mock=1
        fi
        if [[ "$is_mock" -eq 0 ]]; then
            return 1
        fi
    elif [[ ! -t 0 ]]; then
        return 1
    fi

    # d) Display: GitHub CLI: logged in as @$login
    printf >&2 '  GitHub CLI: logged in as @%s\n' "$login"

    # e) Confirm: confirm "Upload '$label' key to GitHub (@$login)?" "y"
    # If user declines, return 1
    if [[ -n "${GITSETU_TEST:-}" ]]; then
        if [[ "${GITSETU_TEST_DECLINE:-0}" -eq 1 ]]; then
            return 1
        fi
    else
        if ! confirm "Upload '$label' key to GitHub (@$login)?" "y"; then
            return 1
        fi
    fi

    # f) Run upload
    local hostname_str
    hostname_str=$(hostname 2>/dev/null || echo "workstation")
    hostname_str="${hostname_str%$'\r'}"
    local upload_out
    local exit_code=0
    upload_out=$(gh ssh-key add "$pubkey_path" --title "GitSetu ($label - $hostname_str)" 2>&1) || exit_code=$?

    # g) If exit_code == 0:
    if [[ "$exit_code" -eq 0 ]]; then
        print_success "Key successfully added to GitHub!"
        return 0
    fi

    # h) If output matches "already in use" or "key is already in use":
    local lower_out
    lower_out=$(printf '%s' "$upload_out" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_out" == *"already in use"* ]]; then
        print_info "Key already registered on GitHub."
        return 0
    fi

    # i) Any other error:
    print_warning "Failed to upload key via GitHub CLI: $upload_out"
    return 1
}

# ------------------------------------------------------------------------------
# display_public_keys — Show all public keys with copy instructions
#
# Displays each key in a formatted box with the GitHub settings URL.
# Usage: display_public_keys
# ------------------------------------------------------------------------------
display_public_keys() {
    print_section "Public Keys — Add These to GitHub/GitLab"

    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local label="${PROFILE_LABELS[$i]}"
        local email="${PROFILE_EMAILS[$i]}"
        local provider="${PROFILE_PROVIDERS[$i]:-github.com}"
        local pubkey="${PROFILE_KEYS[$i]:-$HOME/.ssh/id_ed25519_${label}}.pub"

        if [[ -f "$pubkey" ]]; then
            print_key_box "$label" "$email" "$pubkey"
            if [[ "$provider" == *"github"* ]]; then
                if ! try_gh_key_upload "$label" "$pubkey"; then
                    print_info "To add key manually, copy the key above and add at: https://github.com/settings/ssh/new"
                fi
            fi
        else
            print_warning "Key not found for '$label': $pubkey"
        fi
    done

    print_section "The Magical Clone"
    printf >&2 "  %bYou no longer need special host aliases to clone!%b\n\n" "$BOLD" "$RESET"
    printf >&2 "  Simply %bcd%b into your profile's directory and run:\n" "$CYAN" "$RESET"
    printf >&2 "    git clone git@github.com:username/repo.git\n\n"
    printf >&2 "  %bGitSetu will automatically intercept and use the correct SSH key!%b\n" "$BOLD" "$RESET"
}

# ------------------------------------------------------------------------------
# auto_register_ssh_keys — Automatically register profile SSH keys with ssh-agent
#
# Non-fatal: checks socket liveness, skips already loaded keys, and adds keys
# with macOS keychain persistence or standard ssh-add.
# Usage: auto_register_ssh_keys [key_path...]
# ------------------------------------------------------------------------------
auto_register_ssh_keys() {
    print_section "SSH Agent Key Registration"

    # a) Check if SSH_AUTH_SOCK is set.
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        print_info "SSH agent not running (SSH_AUTH_SOCK not set)."
        print_info "To start ssh-agent, run: eval \$(ssh-agent -s)"
        return 0
    fi

    # b) Socket liveness test: run `ssh-add -l >/dev/null 2>&1`. Exit code 2 means dead socket.
    local agent_status=0
    ssh-add -l >/dev/null 2>&1 || agent_status=$?
    if [[ "$agent_status" -eq 2 ]]; then
        print_warning "SSH agent socket not responding ($SSH_AUTH_SOCK)"
        print_info "To restart ssh-agent, run: eval \$(ssh-agent -s)"
        return 0
    fi

    # Loaded keys list for fingerprint deduplication (exit code 0 means identities present)
    local loaded_keys=""
    if [[ "$agent_status" -eq 0 ]]; then
        loaded_keys=$(ssh-add -l 2>/dev/null || true)
    fi

    # c) Determine keys to register
    local -a keys_to_process=()
    if [[ "$#" -gt 0 ]]; then
        keys_to_process=("$@")
    elif [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        local i
        for (( i=0; i<PROFILE_COUNT; i++ )); do
            local k="${PROFILE_KEYS[$i]:-$HOME/.ssh/id_ed25519_${PROFILE_LABELS[$i]}}"
            keys_to_process+=("$k")
        done
    else
        # If PROFILE_COUNT is 0, try loading from profiles.conf if available
        if declare -f load_profiles >/dev/null 2>&1; then
            load_profiles 2>/dev/null || true
        fi
        if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
            local i
            for (( i=0; i<PROFILE_COUNT; i++ )); do
                local k="${PROFILE_KEYS[$i]:-$HOME/.ssh/id_ed25519_${PROFILE_LABELS[$i]}}"
                keys_to_process+=("$k")
            done
        else
            # Discover keys in ~/.ssh
            local found_key
            for found_key in "$HOME/.ssh"/id_ed25519_*; do
                if [[ -f "$found_key" && "$found_key" != *.pub && "$found_key" != *.old* ]]; then
                    keys_to_process+=("$found_key")
                fi
            done
        fi
    fi

    # Deduplicate candidate key paths
    local -a unique_keys=()
    local kp
    for kp in "${keys_to_process[@]}"; do
        [[ -z "$kp" ]] && continue
        local seen=0
        local u
        for u in "${unique_keys[@]}"; do
            if [[ "$u" == "$kp" ]]; then
                seen=1
                break
            fi
        done
        if [[ "$seen" -eq 0 ]]; then
            unique_keys+=("$kp")
        fi
    done

    if [[ "${#unique_keys[@]}" -eq 0 ]]; then
        print_info "No profile SSH keys found to register."
        return 0
    fi

    local registered_count=0
    local already_loaded_count=0

    for kp in "${unique_keys[@]}"; do
        if [[ ! -f "$kp" ]]; then
            continue
        fi

        # Check if key is already loaded in agent (compare fingerprint)
        local key_fp=""
        key_fp=$(ssh-keygen -lf "$kp" 2>/dev/null | awk '{print $2}')
        if [[ -n "$key_fp" && -n "$loaded_keys" ]]; then
            if printf '%s\n' "$loaded_keys" | grep -q -F "$key_fp"; then
                already_loaded_count=$((already_loaded_count + 1))
                print_info "Key already loaded in SSH agent: $kp"
                continue
            fi
        fi

        # Dry run check: suppress ssh-add invocation
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would register with SSH agent: $kp"
            registered_count=$((registered_count + 1))
            continue
        fi

        # Registration attempt (macOS keychain support or standard)
        local add_status=0
        if [[ "${GITSETU_OS:-}" == "macos" || "${OSTYPE:-}" == "darwin"* ]]; then
            ssh-add --apple-use-keychain "$kp" 2>/dev/null || ssh-add "$kp" 2>/dev/null || add_status=$?
        else
            ssh-add "$kp" 2>/dev/null || add_status=$?
        fi

        if [[ "$add_status" -eq 0 ]]; then
            registered_count=$((registered_count + 1))
            print_success "Registered with SSH agent: $kp"
            if [[ -n "$key_fp" ]]; then
                loaded_keys=$(printf '%s\n%s' "$loaded_keys" "$key_fp")
            fi
        else
            print_warning "Could not auto-register $kp (may require passphrase or hardware key)"
            print_info "To add manually: ssh-add $kp"
        fi
    done

    if [[ "$registered_count" -gt 0 ]]; then
        if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
            print_info "[DRY RUN] Would register ${registered_count} key(s) with SSH agent"
        else
            print_success "Registered ${registered_count} key(s) with SSH agent"
        fi
    fi
    if [[ "$already_loaded_count" -gt 0 ]]; then
        print_info "${already_loaded_count} key(s) already loaded in SSH agent"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# verify_ssh_handshake — Verify SSH connectivity with Port 443 fallback
#
# Attempts SSH connection on standard Port 22 first. If Port 22 fails and the
# provider is GitHub, automatically falls back to Port 443 via ssh.github.com.
# If Port 443 succeeds, exports GITSETU_PORT443_NEEDED=1 to trigger clean
# regeneration of ~/.config/gitsetu/profiles/ssh_config.
#
# Usage: verify_ssh_handshake "/path/to/key" "github.com"
# Returns: 0 on success, 1 on failure
# ------------------------------------------------------------------------------
verify_ssh_handshake() {
    local key_path="$1"
    local provider="${2:-github.com}"
    local host="$provider"

    # If key file does not exist, return 0
    if [[ ! -f "$key_path" ]]; then
        return 0
    fi

    # a) If GITSETU_TEST is set and not explicitly testing SSH handshake, return 0 (never hang on network timeouts)
    if [[ -n "${GITSETU_TEST:-}" ]]; then
        local is_mock=0
        if [[ -n "${GITSETU_TEST_SSH_VERIFY:-}" || -n "${GITSETU_TEST_SSH:-}" ]]; then
            is_mock=1
        elif [[ "$(type -t ssh 2>/dev/null)" == "function" ]]; then
            is_mock=1
        elif [[ -n "${TEST_HOME:-}" && "$(command -v ssh 2>/dev/null)" == *"$TEST_HOME"* ]]; then
            is_mock=1
        fi
        if [[ "$is_mock" -eq 0 ]]; then
            return 0
        fi
    fi

    # b) Try port 22
    local out
    out=$(ssh -T -i "$key_path" -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "git@$host" 2>&1 || true)
    if [[ "$out" == *"successfully authenticated"* || "$out" == *"Welcome to GitLab"* ]]; then
        print_success "SSH connection verified: $host (port 22)"
        return 0
    fi

    # c) If port 22 fails AND host is "github.com" or provider is "github.com": Try port 443
    if [[ "$host" == *"github.com"* || "$provider" == *"github.com"* ]]; then
        local out443
        out443=$(ssh -T -i "$key_path" -p 443 -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@ssh.github.com 2>&1 || true)
        if [[ "$out443" == *"successfully authenticated"* ]]; then
            print_success "SSH connection verified: github.com (port 443 corporate fallback)"
            export GITSETU_PORT443_NEEDED=1
            return 0
        fi
    fi

    # d) If all fail
    print_warning "SSH verification for $provider failed (non-fatal, setup continues)"
    return 1
}

