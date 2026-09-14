#!/usr/bin/env bash
# lib/discovery.sh — Auto-discovery engine for GitSetu
#
# Scans the system for existing Git configurations, SSH keys,
# and common workspace directories to pre-populate the setup blueprint.

# ------------------------------------------------------------------------------
# discover_global_git_identity
#
# Returns global name and email from ~/.gitconfig if present.
# Variables set: DISCOVERED_GLOBAL_NAME, DISCOVERED_GLOBAL_EMAIL
# ------------------------------------------------------------------------------
discover_global_git_identity() {
    DISCOVERED_GLOBAL_NAME=""
    DISCOVERED_GLOBAL_EMAIL=""

    # 1. Try to read from git config
    if command -v git >/dev/null 2>&1; then
        DISCOVERED_GLOBAL_NAME=$(git config --global user.name 2>/dev/null || true)
        DISCOVERED_GLOBAL_EMAIL=$(git config --global user.email 2>/dev/null || true)
    fi

    # 1b. Fallback directly to $HOME/.gitconfig if present
    if [[ -z "$DISCOVERED_GLOBAL_NAME" ]] && [[ -f "$HOME/.gitconfig" ]]; then
        DISCOVERED_GLOBAL_NAME=$(git config --file "$HOME/.gitconfig" user.name 2>/dev/null || true)
    fi
    if [[ -z "$DISCOVERED_GLOBAL_EMAIL" ]] && [[ -f "$HOME/.gitconfig" ]]; then
        DISCOVERED_GLOBAL_EMAIL=$(git config --file "$HOME/.gitconfig" user.email 2>/dev/null || true)
    fi

    # 2. If name/email are empty, check if global.gitconfig exists (GitSetu fallback)
    if [[ -z "$DISCOVERED_GLOBAL_NAME" ]] && [[ -f "$HOME/.config/gitsetu/profiles/global.gitconfig" ]]; then
        DISCOVERED_GLOBAL_NAME=$(git config --file "$HOME/.config/gitsetu/profiles/global.gitconfig" user.name 2>/dev/null || true)
    fi
    if [[ -z "$DISCOVERED_GLOBAL_EMAIL" ]] && [[ -f "$HOME/.config/gitsetu/profiles/global.gitconfig" ]]; then
        DISCOVERED_GLOBAL_EMAIL=$(git config --file "$HOME/.config/gitsetu/profiles/global.gitconfig" user.email 2>/dev/null || true)
    fi

    # 3. If email is STILL empty, try to extract it from SSH public keys
    if [[ -z "$DISCOVERED_GLOBAL_EMAIL" ]]; then
        local pub_key
        for pub_key in "$HOME/.ssh/id_ed25519_global.pub" "$HOME/.ssh/id_rsa_global.pub" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
            if [[ -f "$pub_key" ]]; then
                local extracted
                extracted=$(awk '{print $3}' "$pub_key" | grep "@" || true)
                if [[ -n "$extracted" ]]; then
                    DISCOVERED_GLOBAL_EMAIL="$extracted"
                    break
                fi
            fi
        done
    fi
}

# ------------------------------------------------------------------------------
# discover_ssh_keys
#
# Scans ~/.ssh/ for ed25519 or rsa keys and returns the best match for a label.
#
# Usage: key_path=$(discover_ssh_key_for_label "work")
# Returns: path or empty string
# ------------------------------------------------------------------------------
discover_ssh_key_for_label() {
    local label="$1"
    local ssh_dir="$HOME/.ssh"
    
    if [[ ! -d "$ssh_dir" ]]; then
        echo ""
        return
    fi

    # Patterns to look for, in order of preference
    local patterns=(
        "id_ed25519_sk_${label}"
        "id_ed25519_${label}"
        "id_rsa_${label}"
    )

    local p
    for p in "${patterns[@]}"; do
        if [[ -f "$ssh_dir/$p" ]]; then
            echo "$ssh_dir/$p"
            return
        fi
    done

    echo ""
}

# ------------------------------------------------------------------------------
# discover_workspace_dir
#
# Checks if common workspace directories exist for a label.
# e.g. "work" -> ~/work, ~/dev/work
#
# Usage: dir=$(discover_workspace_dir "work")
# Returns: path or empty string
# ------------------------------------------------------------------------------
discover_workspace_dir() {
    local label="$1"
    
    # Don't try to guess for generic global labels
    if [[ "$label" == "global" ]] || [[ "$label" == "default" ]]; then
        echo ""
        return
    fi

    # 1. Parse existing ~/.gitconfig for includeIf sections matching the label
    if [[ -f "$HOME/.gitconfig" ]]; then
        local label_lower
        label_lower=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')

        local current_gitdir=""
        local current_path=""
        local tier1_candidate=""
        local tier2_candidate=""
        local tier3_candidate=""

        check_section() {
            local gdir="$1"
            local ppath="$2"
            [[ -z "$gdir" ]] && return 0

            # Strip leading/trailing quotes and trailing wildcards/slashes
            gdir="${gdir%\"}"
            gdir="${gdir#\"}"
            gdir="${gdir%\'}"
            gdir="${gdir#\'}"
            gdir="${gdir%/\*\*}"
            gdir="${gdir%/\*}"
            gdir="${gdir%/}"

            ppath="${ppath%\"}"
            ppath="${ppath#\"}"
            ppath="${ppath%\'}"
            ppath="${ppath#\'}"

            local ppath_clean="${ppath//\\//}"
            local ppath_base
            ppath_base=$(basename "$ppath_clean" 2>/dev/null || echo "$ppath_clean")
            local ppath_base_lower
            ppath_base_lower=$(printf '%s' "$ppath_base" | tr '[:upper:]' '[:lower:]')

            local gdir_clean="${gdir//\\//}"
            local gdir_base
            gdir_base=$(basename "$gdir_clean" 2>/dev/null || echo "$gdir_clean")
            local gdir_base_lower
            gdir_base_lower=$(printf '%s' "$gdir_base" | tr '[:upper:]' '[:lower:]')

            # Normalize candidate directory to verify existence
            local norm_dir
            norm_dir=$(normalize_path "$gdir")

            # Tier 1: Target profile path matches label
            # e.g., work.gitconfig, .gitconfig-work, gitconfig-work, *-work.gitconfig, *-work
            if [[ -z "$tier1_candidate" ]]; then
                if [[ "$ppath_base_lower" == "${label_lower}.gitconfig" ]] || \
                   [[ "$ppath_base_lower" == ".gitconfig-${label_lower}" ]] || \
                   [[ "$ppath_base_lower" == "gitconfig-${label_lower}" ]] || \
                   [[ "$ppath_base_lower" == *"-${label_lower}.gitconfig" ]] || \
                   [[ "$ppath_base_lower" == *"_${label_lower}.gitconfig" ]] || \
                   [[ "$ppath_base_lower" == *"-${label_lower}" ]] || \
                   [[ "$ppath_base_lower" == *"_${label_lower}" ]] || \
                   [[ "$ppath_base_lower" == "${label_lower}" ]]; then
                    if [[ -d "$norm_dir" ]]; then
                        tier1_candidate="$norm_dir"
                        return 0
                    fi
                fi
            fi

            # Tier 2: gitdir exact directory segment match
            # e.g. .../work or .../work/
            if [[ -z "$tier2_candidate" ]]; then
                if [[ "$gdir_base_lower" == "$label_lower" ]]; then
                    if [[ -d "$norm_dir" ]]; then
                        tier2_candidate="$norm_dir"
                        return 0
                    fi
                fi
            fi

            # Tier 3: gitdir base starts or ends with label + delimiter
            # e.g. work_dir, work-dir, dev-work (excluding middle substring like client_work_dir)
            if [[ -z "$tier3_candidate" ]]; then
                if [[ "$gdir_base_lower" == "${label_lower}_"* ]] || \
                   [[ "$gdir_base_lower" == "${label_lower}-"* ]] || \
                   [[ "$gdir_base_lower" == *"_${label_lower}" ]] || \
                   [[ "$gdir_base_lower" == *"-${label_lower}" ]]; then
                    if [[ -d "$norm_dir" ]]; then
                        tier3_candidate="$norm_dir"
                    fi
                fi
            fi
        }

        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == "#"* || "$line" == ";"* ]] && continue

            if [[ "$line" =~ ^\[includeIf[[:space:]]+\"gitdir(/i)?:(.*)\"\]$ ]] || \
               [[ "$line" =~ ^\[includeIf[[:space:]]+\'gitdir(/i)?:(.*)\'\]$ ]] || \
               [[ "$line" =~ ^\[includeIf[[:space:]]+gitdir(/i)?:(.*)\]$ ]]; then
                check_section "$current_gitdir" "$current_path"
                current_gitdir="${BASH_REMATCH[2]}"
                current_path=""
            elif [[ "$line" =~ ^\[ ]]; then
                check_section "$current_gitdir" "$current_path"
                current_gitdir=""
                current_path=""
            elif [[ -n "$current_gitdir" ]] && [[ "$line" =~ ^path[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                current_path="${BASH_REMATCH[1]}"
            fi
        done < "$HOME/.gitconfig"

        check_section "$current_gitdir" "$current_path"

        if [[ -n "$tier1_candidate" ]]; then
            echo "$tier1_candidate"
            return
        fi

        if [[ -n "$tier2_candidate" ]]; then
            echo "$tier2_candidate"
            return
        fi

        if [[ -n "$tier3_candidate" ]]; then
            echo "$tier3_candidate"
            return
        fi
    fi

    # 2. Hardcoded fallback paths
    local potential_dirs=(
        "$HOME/$label"
        "$HOME/dev/$label"
        "$HOME/Development/$label"
        "$HOME/workspace/$label"
        "$HOME/projects/$label"
    )

    local p
    for p in "${potential_dirs[@]}"; do
        if [[ -d "$p" ]]; then
            echo "$p"
            return
        fi
    done

    echo ""
}

# ------------------------------------------------------------------------------
# generate_initial_blueprint
#
# Initializes PROFILE_* arrays with discovered defaults if profiles.conf is empty.
# ------------------------------------------------------------------------------
generate_initial_blueprint() {
    # If we already have profiles (from load_profiles), do nothing
    if [[ "$PROFILE_COUNT" -gt 0 ]]; then
        return 0
    fi

    discover_global_git_identity

    # Initialize Global Profile (Index 0)
    # shellcheck disable=SC2034
    PROFILE_LABELS[0]="global"
    # shellcheck disable=SC2034
    PROFILE_NAMES[0]="${DISCOVERED_GLOBAL_NAME:-}"
    # shellcheck disable=SC2034
    PROFILE_EMAILS[0]="${DISCOVERED_GLOBAL_EMAIL:-}"
    # shellcheck disable=SC2034
    PROFILE_DIRS[0]=""
    # shellcheck disable=SC2034
    PROFILE_PROVIDERS[0]="github.com"
    # shellcheck disable=SC2034
    PROFILE_SIGNS[0]="0"
    
    local global_key
    global_key=$(discover_ssh_key_for_label "global")
    # shellcheck disable=SC2034
    PROFILE_KEYS[0]="${global_key:-$HOME/.ssh/id_ed25519_global}"
    # shellcheck disable=SC2034
    PROFILE_USERS[0]=""
    # shellcheck disable=SC2034
    PROFILE_PATS[0]=""
    
    PROFILE_COUNT=1

    # Try to discover candidate profiles (work, personal, oss) if directory or key exists
    local candidate
    for candidate in "work" "personal" "oss"; do
        local cand_dir
        cand_dir=$(discover_workspace_dir "$candidate")
        local cand_key
        cand_key=$(discover_ssh_key_for_label "$candidate")
        
        if [[ -n "$cand_dir" ]] || [[ -n "$cand_key" ]]; then
            local idx=$PROFILE_COUNT
            # shellcheck disable=SC2034
            PROFILE_LABELS[idx]="$candidate"
            # shellcheck disable=SC2034
            PROFILE_NAMES[idx]="${DISCOVERED_GLOBAL_NAME:-}"
            # shellcheck disable=SC2034
            PROFILE_EMAILS[idx]=""
            
            # Try to extract email from pubkey if available
            if [[ -n "$cand_key" ]] && [[ -f "${cand_key}.pub" ]]; then
                local ext_mail
                ext_mail=$(awk '{print $3}' "${cand_key}.pub" | grep "@" || true)
                if [[ -n "$ext_mail" ]]; then
                    # shellcheck disable=SC2034
                    PROFILE_EMAILS[idx]="$ext_mail"
                fi
            fi
            
            # shellcheck disable=SC2034
            PROFILE_DIRS[idx]="${cand_dir:-$HOME/$candidate}"
            # shellcheck disable=SC2034
            PROFILE_PROVIDERS[idx]="github.com"
            # shellcheck disable=SC2034
            PROFILE_SIGNS[idx]="0"
            # shellcheck disable=SC2034
            PROFILE_KEYS[idx]="${cand_key:-$HOME/.ssh/id_ed25519_${candidate}}"
            # shellcheck disable=SC2034
            PROFILE_USERS[idx]=""
            # shellcheck disable=SC2034
            PROFILE_PATS[idx]=""
            
            PROFILE_COUNT=$((PROFILE_COUNT + 1))
        fi
    done
}
