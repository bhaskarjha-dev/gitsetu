#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables used by sourcing script
# lib/teardown.sh — Safely remove all GitSetu configurations
#
# Removes managed blocks from ~/.gitconfig and ~/.ssh/config,
# uninstalls the guard hook, and deletes the ~/.config/gitsetu directory.
# Leaves SSH keys intact but lists them for manual deletion.
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# teardown_gitconfig — Remove managed block from ~/.gitconfig
#
# Usage: teardown_gitconfig
# ------------------------------------------------------------------------------
teardown_gitconfig() {
    local gitconfig="$HOME/.gitconfig"

    if [[ ! -f "$gitconfig" ]]; then
        print_info "No ~/.gitconfig found, skipping."
        return 0
    fi

    if ! grep -q "\[gitsetu:managed:start\]" "$gitconfig" 2>/dev/null; then
        print_info "No gitsetu managed block found in ~/.gitconfig, skipping."
        return 0
    fi

    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would remove managed block from: $gitconfig"
        return 0
    fi

    backup_file "$gitconfig"

    local tmp_file
    tmp_file=$(mktemp "${gitconfig}.tmp.XXXXXX")
    GITSETU_CLEANUP_FILES+=("$tmp_file")

    awk '
        /\[gitsetu:managed:start\]/ {skip=1; next}
        /\[gitsetu:managed:end\]/   {skip=0; next}
        !skip                      {print}
    ' "$gitconfig" > "$tmp_file"

    # If the resulting file is empty or only whitespace, delete it
    if ! grep -q '[^[:space:]]' "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        rm -f "$gitconfig"
        print_success "Removed ~/.gitconfig (it was empty after cleanup)"
    else
        mv "$tmp_file" "$gitconfig"
        print_success "Removed managed block from: $gitconfig"
    fi
}

# ------------------------------------------------------------------------------
# teardown_sshconfig — Remove managed host blocks from ~/.ssh/config
#
# Usage: teardown_sshconfig
# ------------------------------------------------------------------------------
teardown_sshconfig() {
    local ssh_config="$HOME/.ssh/config"
    local isolated_config="$GITSETU_PROFILES_DIR/ssh_config"
    local include_directive="Include $isolated_config"

    # 1. Delete the isolated file
    if [[ -f "$isolated_config" ]]; then
        if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
            print_info "[DRY RUN] Would delete isolated config: $isolated_config"
        else
            rm -f "$isolated_config"
            print_success "Deleted isolated gitsetu SSH config: $isolated_config"
        fi
    fi

    if [[ ! -f "$ssh_config" ]]; then
        print_info "No ~/.ssh/config found, skipping."
        return 0
    fi

    # 2. Legacy Migration Cleanup: Just in case they still have old blocks
    if grep -q "\[gitsetu:managed:start\]" "$ssh_config" 2>/dev/null; then
        if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
            print_info "[DRY RUN] Would remove legacy managed blocks from: $ssh_config"
        else
            backup_file "$ssh_config"
            local tmp_legacy
            tmp_legacy=$(mktemp "${ssh_config}.tmp.legacy.XXXXXX")
            GITSETU_CLEANUP_FILES+=("$tmp_legacy")
            awk '
                /\[gitsetu:managed:start\]/ {skip=1; next}
                /\[gitsetu:managed:end\]/   {skip=0; next}
                !skip                      {print}
            ' "$ssh_config" > "$tmp_legacy"
            mv "$tmp_legacy" "$ssh_config"
            print_success "Removed legacy managed blocks from: $ssh_config"
        fi
    fi

    # 3. Remove the Include directive safely
    if grep -q -F "$include_directive" "$ssh_config" 2>/dev/null; then
        if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
            print_info "[DRY RUN] Would remove Include directive from: $ssh_config"
            return 0
        fi

        backup_file "$ssh_config"
        local tmp_file
        tmp_file=$(mktemp "${ssh_config}.tmp.XXXXXX")
        GITSETU_CLEANUP_FILES+=("$tmp_file")

        grep -v -F "$include_directive" "$ssh_config" > "$tmp_file" || true

        # If the resulting file is empty or only whitespace, delete it
        if ! grep -q '[^[:space:]]' "$tmp_file" 2>/dev/null; then
            rm -f "$tmp_file"
            rm -f "$ssh_config"
            print_success "Removed ~/.ssh/config (it was empty after cleanup)"
        else
            mv "$tmp_file" "$ssh_config"
            print_success "Removed Include directive from: $ssh_config"
        fi
    else
        print_info "No gitsetu Include directive found in ~/.ssh/config, skipping."
    fi
}

# ------------------------------------------------------------------------------
# teardown_config_dir — Remove ~/.config/gitsetu
#
# Usage: teardown_config_dir
# ------------------------------------------------------------------------------
teardown_config_dir() {
    if [[ ! -d "$GITSETU_CONFIG_DIR" ]]; then
        print_info "Directory $GITSETU_CONFIG_DIR not found, skipping."
        return 0
    fi

    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
        print_info "[DRY RUN] Would completely remove: $GITSETU_CONFIG_DIR"
        return 0
    fi

    rm -rf "$GITSETU_CONFIG_DIR"
    print_success "Removed configuration directory: $GITSETU_CONFIG_DIR"
}

# ------------------------------------------------------------------------------
# list_orphaned_keys — Show SSH keys generated by gitsetu
#
# Usage: list_orphaned_keys
# ------------------------------------------------------------------------------
list_orphaned_keys() {
    local keys=()
    local f
    
    # Check for keys generated by gitsetu pattern (id_ed25519_<label>)
    # Ignore the standard id_ed25519 key to avoid false positives
    if [[ -d "$HOME/.ssh" ]]; then
        # shellcheck disable=SC2045  # Iterating safely since we control names
        for f in "$HOME/.ssh"/id_ed25519_*; do
            if [[ -f "$f" ]] && [[ ! "$f" == *.pub ]] && [[ ! "$f" == *.old.* ]] && [[ "$f" != "$HOME/.ssh/id_ed25519" ]]; then
                keys+=("$f")
            fi
        done
    fi

    if [[ ${#keys[@]} -gt 0 ]]; then
        print_section "Action Required: SSH Keys"
        print_warning "GitSetu has left your SSH keys intact to prevent accidental lockouts."
        print_info "If you no longer need them, remove them from GitHub/GitLab and delete them locally:"
        
        local key
        for key in "${keys[@]}"; do
            printf >&2 "    rm %s %s.pub\n" "$key" "$key"
        done
        printf >&2 "\n"
    fi
}

# ------------------------------------------------------------------------------
# teardown_deep — Remove local overrides from repositories
#
# Usage: teardown_deep
# ------------------------------------------------------------------------------
teardown_deep() {
    print_section "Deep Cleanup: Repository Overrides"
    
    # We must load profiles to know what directories to scan and what to unset
    load_profiles 2>/dev/null || return 0
    
    if [[ "$PROFILE_COUNT" -eq 0 ]]; then
        print_info "No profiles found. Skipping deep cleanup."
        return 0
    fi
    
    local i
    local found_any=0
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        local dir="${PROFILE_DIRS[$i]}"
        local p_email="${PROFILE_EMAILS[$i]}"
        local p_key="${PROFILE_KEYS[$i]}"
        
        if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
            # Prevent catastrophic global traverse DoS
            # shellcheck disable=SC2088
            if [[ "$dir" == "/" || "$dir" == "$HOME" || "$dir" == "$HOME/" || "$dir" == "~" || "$dir" == "~/" ]]; then
                print_warning "Skipping deep cleanup for '$dir' to prevent Denial of Service traversal."
                continue
            fi
            
            # Find all .git/config in the directory tree
            local repo_conf
            while IFS= read -r repo_conf; do
                [[ -z "$repo_conf" ]] && continue
                
                # Check if this repo config has our identity
                local repo_email repo_key
                repo_email=$(git config -f "$repo_conf" user.email 2>/dev/null || true)
                
                if [[ "$repo_email" == "$p_email" ]]; then
                    if [[ "$GITSETU_DRY_RUN" -eq 1 ]]; then
                        print_info "[DRY RUN] Would strip local GitSetu identity from: $repo_conf"
                    else
                        git config -f "$repo_conf" --unset user.email 2>/dev/null || true
                        git config -f "$repo_conf" --unset user.name 2>/dev/null || true
                        
                        repo_key=$(git config -f "$repo_conf" core.sshCommand 2>/dev/null || true)
                        if [[ "$repo_key" == *"ssh -i $p_key"* ]]; then
                            git config -f "$repo_conf" --unset core.sshCommand 2>/dev/null || true
                        fi
                        print_success "Removed local overrides from: $repo_conf"
                    fi
                    found_any=1
                fi
            done < <(find "$dir" -type f -name config -path "*/.git/config" 2>/dev/null || true)
        fi
    done
    
    if [[ "$found_any" -eq 0 ]]; then
        print_info "No local repository overrides found."
    fi
}

# ------------------------------------------------------------------------------
# teardown_all — Main coordinator for teardown
#
# Usage: teardown_all [deep]
# ------------------------------------------------------------------------------
teardown_all() {
    local deep="${1:-0}"
    
    print_section "Teardown Process"
    
    # 1. Uninstall guard hook (relies on config dir existing)
    uninstall_guard
    
    # 2. Clean gitconfig
    teardown_gitconfig
    
    # 3. Clean ssh config
    teardown_sshconfig
    
    # 3.5 Deep cleanup (if requested)
    if [[ "$deep" -eq 1 ]]; then
        teardown_deep
    fi
    
    # 4. Remove config directory (must be last state modifier)
    teardown_config_dir
    
    # 5. Provide final advice on keys
    list_orphaned_keys
    
    if [[ "$GITSETU_DRY_RUN" -eq 0 ]]; then
        print_success "GitSetu teardown complete."
    fi
}
