#!/usr/bin/env bash
# lib/discovery.sh — Conservative auto-discovery engine for GitSetu
#
# Discovery never executes data from Git or SSH files. Returned values are
# checked again before setup applies a blueprint. Bash 3.2 compatible.

DISCOVERY_WARNINGS=()
DISCOVERY_INVALID=0

_discovery_reset_diagnostics() {
    DISCOVERY_WARNINGS=()
    DISCOVERY_INVALID=0
}

_discovery_warn() {
    DISCOVERY_INVALID=1
    DISCOVERY_WARNINGS+=("$1")
}

_discovery_valid_label() {
    local label="${1:-}"
    if declare -f validate_label >/dev/null 2>&1; then
        validate_label "$label"
        return $?
    fi
    [[ "$label" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || return 1
    [[ "$label" != *- ]]
}

_discovery_has_control_chars() {
    local value="${1:-}"
    if declare -f _gitsetu_contains_ascii_control >/dev/null 2>&1; then
        _gitsetu_contains_ascii_control "$value"
        return $?
    fi
    [[ "$value" == *$'\r'* || "$value" == *$'\n'* || "$value" == *$'\t'* || "$value" == *[[:cntrl:]]* ]]
}

_discovery_valid_name() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    _discovery_has_control_chars "$name" && return 1
    if declare -f validate_user_name >/dev/null 2>&1; then
        validate_user_name "$name"
        return $?
    fi
    return 0
}

_discovery_valid_email() {
    local email="${1:-}"
    [[ -n "$email" ]] || return 1
    _discovery_has_control_chars "$email" && return 1

    if declare -f validate_email >/dev/null 2>&1; then
        validate_email "$email"
        return $?
    fi

    local domain="${email#*@}"
    [[ "${email%%@*}" != "" && "$domain" == *.* && "$domain" != *. ]]
}

_discovery_valid_provider() {
    local provider="${1:-github.com}"
    [[ -n "$provider" ]] || return 1
    _discovery_has_control_chars "$provider" && return 1

    if declare -f validate_provider >/dev/null 2>&1; then
        validate_provider "$provider"
        return $?
    fi

    [[ "$provider" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?$ ]]
}

_discovery_email_from_public_key() {
    local key_file="${1:-}"
    local key_type key_data comment token candidate

    [[ -f "$key_file" && ! -L "$key_file" ]] || return 1
    while read -r key_type key_data comment; do
        [[ "$key_type" == ssh-* || "$key_type" == ecdsa-* ]] || continue
        for token in $comment; do
            candidate="${token//[<>()]/}"
            candidate="${candidate%,}"
            candidate="${candidate%;}"
            if _discovery_valid_email "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done < "$key_file"
    return 1
}

_discovery_canonical_existing_dir() {
    local raw="${1:-}"
    local normalized canonical

    [[ -n "$raw" ]] || return 1
    _discovery_has_control_chars "$raw" && return 1

    # shellcheck disable=SC2088  # Explicit expansion of a leading tilde.
    if [[ "$raw" == "~" ]]; then
        raw="${HOME:-}"
    elif [[ "$raw" == "~/"* ]]; then
        [[ -n "${HOME:-}" ]] || return 1
        raw="${HOME}/${raw:2}"
    fi

    if [[ "$raw" != /* && ! "$raw" =~ ^[A-Za-z]:/ ]]; then
        return 1
    fi

    normalized=$(normalize_path "$raw") || return 1
    [[ -d "$normalized" ]] || return 1
    canonical="$normalized"

    [[ "$canonical" != "/" && "$canonical" != "${HOME:-/}" ]] || return 1
    printf '%s\n' "$canonical"
}

_discovery_profile_config_path() {
    local profiles_dir="${GITSETU_PROFILES_DIR:-}"
    if [[ -z "$profiles_dir" && -n "${HOME:-}" ]]; then
        profiles_dir="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu/profiles"
    fi
    [[ -n "$profiles_dir" ]] || return 1
    printf '%s/global.gitconfig\n' "${profiles_dir%/}"
}

# ------------------------------------------------------------------------------
# discover_global_git_identity
# ------------------------------------------------------------------------------

discover_global_git_identity() {
    _discovery_reset_diagnostics
    DISCOVERED_GLOBAL_NAME=""
    DISCOVERED_GLOBAL_EMAIL=""

    [[ -n "${HOME:-}" ]] || {
        _discovery_warn "HOME is not set; Git identity discovery was skipped."
        return 0
    }

    if command -v git >/dev/null 2>&1; then
        DISCOVERED_GLOBAL_NAME=$(git config --global user.name 2>/dev/null || true)
        DISCOVERED_GLOBAL_EMAIL=$(git config --global user.email 2>/dev/null || true)
    fi

    if [[ -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]; then
        if [[ -z "$DISCOVERED_GLOBAL_NAME" ]] && command -v git >/dev/null 2>&1; then
            DISCOVERED_GLOBAL_NAME=$(git config --file "$HOME/.gitconfig" user.name 2>/dev/null || true)
        fi
        if [[ -z "$DISCOVERED_GLOBAL_EMAIL" ]] && command -v git >/dev/null 2>&1; then
            DISCOVERED_GLOBAL_EMAIL=$(git config --file "$HOME/.gitconfig" user.email 2>/dev/null || true)
        fi
    fi

    local managed_global
    managed_global=$(_discovery_profile_config_path 2>/dev/null || true)
    if [[ -n "$managed_global" && -f "$managed_global" && ! -L "$managed_global" ]] && command -v git >/dev/null 2>&1; then
        [[ -n "$DISCOVERED_GLOBAL_NAME" ]] || \
            DISCOVERED_GLOBAL_NAME=$(git config --file "$managed_global" user.name 2>/dev/null || true)
        [[ -n "$DISCOVERED_GLOBAL_EMAIL" ]] || \
            DISCOVERED_GLOBAL_EMAIL=$(git config --file "$managed_global" user.email 2>/dev/null || true)
    fi

    if [[ -z "$DISCOVERED_GLOBAL_EMAIL" ]]; then
        local pub_key extracted
        for pub_key in \
            "$HOME/.ssh/id_ed25519_global.pub" \
            "$HOME/.ssh/id_rsa_global.pub" \
            "$HOME/.ssh/id_ed25519.pub" \
            "$HOME/.ssh/id_rsa.pub"
        do
            [[ -f "$pub_key" && ! -L "$pub_key" ]] || continue
            extracted=$(_discovery_email_from_public_key "$pub_key" 2>/dev/null || true)
            if [[ -n "$extracted" ]]; then
                DISCOVERED_GLOBAL_EMAIL="$extracted"
                break
            fi
        done
    fi

    if [[ -n "$DISCOVERED_GLOBAL_NAME" ]] && ! _discovery_valid_name "$DISCOVERED_GLOBAL_NAME"; then
        _discovery_warn "Discovered Git user.name contains unsupported characters and was rejected."
        DISCOVERED_GLOBAL_NAME=""
    fi
    if [[ -n "$DISCOVERED_GLOBAL_EMAIL" ]] && ! _discovery_valid_email "$DISCOVERED_GLOBAL_EMAIL"; then
        _discovery_warn "Discovered Git user.email is invalid and was rejected."
        DISCOVERED_GLOBAL_EMAIL=""
    fi
}

# ------------------------------------------------------------------------------
# discover_ssh_key_for_label
# ------------------------------------------------------------------------------

discover_ssh_key_for_label() {
    local label="${1:-}"
    local ssh_dir="${HOME:-}/.ssh"
    local pattern path

    _discovery_valid_label "$label" || {
        printf '\n'
        return 0
    }
    [[ -n "${HOME:-}" && -d "$ssh_dir" && ! -L "$ssh_dir" ]] || {
        printf '\n'
        return 0
    }

    for pattern in \
        "id_ed25519_sk_${label}" \
        "id_ed25519_${label}" \
        "id_rsa_${label}"
    do
        path="$ssh_dir/$pattern"
        if [[ -f "$path" && ! -L "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    printf '\n'
}

# ------------------------------------------------------------------------------
# discover_workspace_dir
# ------------------------------------------------------------------------------

_gitsetu_discovery_check_include_section() {
    local gdir="${1:-}"
    local include_path="${2:-}"
    local candidate_dir=""
    local ppath_base ppath_base_lower gdir_base gdir_base_lower

    [[ -n "$gdir" ]] || return 0

    gdir="${gdir%\"}"; gdir="${gdir#\"}"
    gdir="${gdir%\'}"; gdir="${gdir#\'}"
    gdir="${gdir%/\*\*}"; gdir="${gdir%/\*}"
    gdir="${gdir%/}"

    include_path="${include_path%\"}"; include_path="${include_path#\"}"
    include_path="${include_path%\'}"; include_path="${include_path#\'}"
    include_path="${include_path%/}"

    _discovery_has_control_chars "$gdir" && return 0
    _discovery_has_control_chars "$include_path" && return 0

    ppath_base=$(basename "$include_path" 2>/dev/null || printf '%s' "$include_path")
    ppath_base_lower=$(printf '%s' "$ppath_base" | tr '[:upper:]' '[:lower:]')
    gdir_base=$(basename "$gdir" 2>/dev/null || printf '%s' "$gdir")
    gdir_base_lower=$(printf '%s' "$gdir_base" | tr '[:upper:]' '[:lower:]')

    candidate_dir=$(_discovery_canonical_existing_dir "$gdir" 2>/dev/null || true)
    [[ -n "$candidate_dir" ]] || return 0

    # Git's includeIf gitdir points at a repository's .git directory. Prefer
    # the working-tree parent when that conventional layout is present.
    if [[ "${candidate_dir##*/}" == ".git" ]]; then
        local parent="${candidate_dir%/.git}"
        local parent_canonical
        parent_canonical=$(_discovery_canonical_existing_dir "$parent" 2>/dev/null || true)
        [[ -n "$parent_canonical" ]] && candidate_dir="$parent_canonical"
    fi

    if [[ -z "$tier1_candidate" ]] && { \
        [[ "$ppath_base_lower" == "${label_lower}.gitconfig" ]] || \
        [[ "$ppath_base_lower" == ".gitconfig-${label_lower}" ]] || \
        [[ "$ppath_base_lower" == "gitconfig-${label_lower}" ]] || \
        [[ "$ppath_base_lower" == *"-${label_lower}.gitconfig" ]] || \
        [[ "$ppath_base_lower" == *"_${label_lower}.gitconfig" ]] || \
        [[ "$ppath_base_lower" == *"-${label_lower}" ]] || \
        [[ "$ppath_base_lower" == *"_${label_lower}" ]] || \
        [[ "$ppath_base_lower" == "${label_lower}" ]]
    }; then
        tier1_candidate="$candidate_dir"
        return 0
    fi

    if [[ -z "$tier2_candidate" ]] && [[ "$gdir_base_lower" == "$label_lower" ]]; then
        tier2_candidate="$candidate_dir"
        return 0
    fi

    if [[ -z "$tier3_candidate" ]] && { \
        [[ "$gdir_base_lower" == "${label_lower}_"* ]] || \
        [[ "$gdir_base_lower" == "${label_lower}-"* ]] || \
        [[ "$gdir_base_lower" == *"_${label_lower}" ]] || \
        [[ "$gdir_base_lower" == *"-${label_lower}" ]]
    }; then
        tier3_candidate="$candidate_dir"
    fi
}

discover_workspace_dir() {
    local label="${1:-}"
    local label_lower line current_gitdir current_path include_gitdir
    local tier1_candidate="" tier2_candidate="" tier3_candidate=""

    _discovery_valid_label "$label" || {
        printf '\n'
        return 0
    }
    [[ "$label" != "global" && "$label" != "default" ]] || {
        printf '\n'
        return 0
    }

    label_lower=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')

    if [[ -n "${HOME:-}" && -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]; then
        current_gitdir=""
        current_path=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

            if [[ "$line" =~ ^\[includeIf[[:space:]]+\"gitdir(/i)?:(.*)\"\]$ ]] || \
               [[ "$line" =~ ^\[includeIf[[:space:]]+\'gitdir(/i)?:(.*)\'\]$ ]] || \
               [[ "$line" =~ ^\[includeIf[[:space:]]+gitdir(/i)?:(.*)\]$ ]]; then
                # Preserve the match before the helper performs its own regex
                # tests; otherwise BASH_REMATCH[2] is overwritten under set -u.
                include_gitdir="${BASH_REMATCH[2]}"
                _gitsetu_discovery_check_include_section "$current_gitdir" "$current_path"
                current_gitdir="$include_gitdir"
                current_path=""
            elif [[ "$line" =~ ^\[ ]]; then
                _gitsetu_discovery_check_include_section "$current_gitdir" "$current_path"
                current_gitdir=""
                current_path=""
            elif [[ -n "$current_gitdir" ]] && [[ "$line" =~ ^path[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                current_path="${BASH_REMATCH[1]}"
            fi
        done < "$HOME/.gitconfig"
        _gitsetu_discovery_check_include_section "$current_gitdir" "$current_path"
    fi

    if [[ -n "$tier1_candidate" ]]; then
        printf '%s\n' "$tier1_candidate"
        return 0
    fi
    if [[ -n "$tier2_candidate" ]]; then
        printf '%s\n' "$tier2_candidate"
        return 0
    fi
    if [[ -n "$tier3_candidate" ]]; then
        printf '%s\n' "$tier3_candidate"
        return 0
    fi

    if [[ -n "${HOME:-}" ]]; then
        local potential
        for potential in \
            "$HOME/$label" \
            "$HOME/dev/$label" \
            "$HOME/Development/$label" \
            "$HOME/workspace/$label" \
            "$HOME/projects/$label"
        do
            local canonical
            canonical=$(_discovery_canonical_existing_dir "$potential" 2>/dev/null || true)
            if [[ -n "$canonical" ]]; then
                printf '%s\n' "$canonical"
                return 0
            fi
        done
    fi

    printf '\n'
}

# ------------------------------------------------------------------------------
# validate_profile_blueprint
#
# mode 0 validates the shape of values that are present and permits empty
# identity fields for the interactive editor. mode 1 (the default) requires a
# complete identity and is suitable immediately before mutation.
# ------------------------------------------------------------------------------

validate_profile_blueprint() {
    local mode="${1:-1}"
    local count_text="${PROFILE_COUNT:-0}"
    local i j label name email provider sign dir key_path provider_user

    [[ "$mode" == "0" || "$mode" == "1" ]] || return 1
    if declare -f validate_nonnegative_integer >/dev/null 2>&1; then
        validate_nonnegative_integer "$count_text" || return 1
    else
        [[ "$count_text" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    fi
    [[ "$count_text" != "0" ]] || return 1

    local labels_len=${#PROFILE_LABELS[@]}
    local names_len=${#PROFILE_NAMES[@]}
    local emails_len=${#PROFILE_EMAILS[@]}
    local dirs_len=${#PROFILE_DIRS[@]}
    local providers_len=${#PROFILE_PROVIDERS[@]}
    local signs_len=${#PROFILE_SIGNS[@]}
    local keys_len=${#PROFILE_KEYS[@]}
    local users_len=${#PROFILE_USERS[@]}
    local pats_len=${#PROFILE_PATS[@]}
    [[ "$labels_len" -eq "$count_text" && "$names_len" -eq "$count_text" &&
       "$emails_len" -eq "$count_text" && "$dirs_len" -eq "$count_text" &&
       "$providers_len" -eq "$count_text" && "$signs_len" -eq "$count_text" &&
       "$keys_len" -eq "$count_text" && "$users_len" -eq "$count_text" ]] || return 1
    [[ "$pats_len" -eq 0 || "$pats_len" -eq "$count_text" ]] || return 1
    [[ "${PROFILE_LABELS[0]:-}" == "global" ]] || return 1

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]}"
        name="${PROFILE_NAMES[$i]}"
        email="${PROFILE_EMAILS[$i]}"
        provider="${PROFILE_PROVIDERS[$i]}"
        sign="${PROFILE_SIGNS[$i]}"
        dir="${PROFILE_DIRS[$i]}"
        key_path="${PROFILE_KEYS[$i]}"
        provider_user="${PROFILE_USERS[$i]}"

        if [[ "$mode" -eq 1 ]]; then
            _discovery_valid_name "$name" || return 1
            _discovery_valid_email "$email" || return 1
        else
            [[ -z "$name" ]] || _discovery_valid_name "$name" || return 1
            [[ -z "$email" ]] || _discovery_valid_email "$email" || return 1
        fi

        if declare -f validate_profile_record >/dev/null 2>&1; then
            validate_profile_record "$label" "$dir" "$provider" "$sign" "$key_path" "$provider_user" || return 1
        else
            _discovery_valid_label "$label" || return 1
            _discovery_valid_provider "$provider" || return 1
            [[ "$sign" == "0" || "$sign" == "1" ]] || return 1
            [[ "$key_path" == /* || "$key_path" =~ ^[A-Za-z]:/ ]] || return 1
            [[ -z "$provider_user" || "$provider_user" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
            if [[ "$label" == "global" ]]; then
                [[ -z "$dir" ]] || return 1
            else
                [[ "$dir" == /* || "$dir" =~ ^[A-Za-z]:/ ]] || return 1
            fi
        fi

        for (( j=0; j<i; j++ )); do
            [[ "$label" != "${PROFILE_LABELS[$j]}" ]] || return 1
        done
    done
    return 0
}

# ------------------------------------------------------------------------------
# generate_initial_blueprint
# ------------------------------------------------------------------------------

generate_initial_blueprint() {
    if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        return 0
    fi

    discover_global_git_identity
    if [[ "$DISCOVERY_INVALID" -ne 0 ]]; then
        local warning
        for warning in "${DISCOVERY_WARNINGS[@]}"; do
            print_error "$warning"
        done
        return 1
    fi

    PROFILE_LABELS[0]="global"
    PROFILE_NAMES[0]="${DISCOVERED_GLOBAL_NAME:-}"
    PROFILE_EMAILS[0]="${DISCOVERED_GLOBAL_EMAIL:-}"
    PROFILE_DIRS[0]=""
    PROFILE_PROVIDERS[0]="github.com"
    PROFILE_SIGNS[0]="0"

    local global_key
    global_key=$(discover_ssh_key_for_label "global")
    PROFILE_KEYS[0]="${global_key:-$HOME/.ssh/id_ed25519_global}"
    PROFILE_USERS[0]=""
    PROFILE_PATS[0]=""
    PROFILE_COUNT=1

    local candidate cand_dir cand_key cand_email
    for candidate in "work" "personal" "oss"; do
        cand_dir=$(discover_workspace_dir "$candidate")
        cand_key=$(discover_ssh_key_for_label "$candidate")

        # A directory or key alone is not an identity. Do not fill a discovered
        # profile with the global user's name/email.
        if [[ -z "$cand_key" ]]; then
            continue
        fi
        cand_email=$(_discovery_email_from_public_key "${cand_key}.pub" 2>/dev/null || true)
        if [[ -z "$cand_email" ]] || ! _discovery_valid_email "$cand_email"; then
            _discovery_warn "Discovered SSH key for '$candidate' has no valid email comment; profile was not added."
            continue
        fi

        local idx=$PROFILE_COUNT
        PROFILE_LABELS[idx]="$candidate"
        PROFILE_NAMES[idx]=""
        PROFILE_EMAILS[idx]="$cand_email"
        PROFILE_DIRS[idx]="${cand_dir:-$HOME/$candidate}"
        PROFILE_PROVIDERS[idx]="github.com"
        PROFILE_SIGNS[idx]="0"
        PROFILE_KEYS[idx]="$cand_key"
        PROFILE_USERS[idx]=""
        PROFILE_PATS[idx]=""
        PROFILE_COUNT=$((PROFILE_COUNT + 1))
    done

    if [[ "$DISCOVERY_INVALID" -ne 0 ]]; then
        local warning
        for warning in "${DISCOVERY_WARNINGS[@]}"; do
            print_warning "$warning"
        done
    fi

    validate_profile_blueprint 0
}
