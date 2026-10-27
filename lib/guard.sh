#!/usr/bin/env bash
# lib/guard.sh — managed-scope pre-commit identity guard
#
# Policy:
#   * A repository selected by the v2 profile registry is managed and fails
#     closed on registry/config/identity errors.
#   * A valid registry match that does not exist is unmanaged and fails open for
#     identity checks only; its ordinary repository hook still runs normally.
#   * If a broken managed installation makes managed/unmanaged status unknowable,
#     the hook fails closed rather than guessing.
#   * The hook validates the effective configured identity and the prospective
#     author and committer identities exposed by Git. Git does not expose whether
#     the author came from config, environment, or --author; the guard checks the
#     resulting identity, not its source, and cannot protect --no-verify, direct
#     object writes, filters, or later history rewrites.
#
# Bash 3.2 compatible.

_GUARD_STATE_BASENAME=".previous-hooks-path"

# ------------------------------------------------------------------------------
# Path and registry resolution
# ------------------------------------------------------------------------------

_guard_normalize_path() {
    local path="${1-}"
    if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
        return 1
    fi
    path="${path//\\//}"
    if [[ "${GITSETU_OS:-}" == "gitbash" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ]]; then
        if command -v cygpath >/dev/null 2>&1; then
            path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
            path="${path//\\//}"
        fi
        if [[ "$path" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
            local drive="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]-}"
            drive=$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')
            path="${drive}:${rest:-/}"
        fi
    fi
    while [[ "$path" == *"//"* ]]; do path="${path//\/\///}"; done
    while [[ ${#path} -gt 1 && "$path" == */ && ! "$path" =~ ^[a-zA-Z]:/$ ]]; do path="${path%/}"; done
    printf '%s' "$path"
}

_guard_paths_equal() {
    local left="${1-}" right="${2-}"
    left=$(_guard_normalize_path "$left") || return 1
    right=$(_guard_normalize_path "$right") || return 1
    if [[ "$left" == "~" ]]; then left="$HOME"; elif [[ "$left" == "~/"* ]]; then left="$HOME/${left:2}"; fi
    if [[ "$right" == "~" ]]; then right="$HOME"; elif [[ "$right" == "~/"* ]]; then right="$HOME/${right:2}"; fi
    while [[ ${#left} -gt 1 && "$left" == */ ]]; do left="${left%/}"; done
    while [[ ${#right} -gt 1 && "$right" == */ ]]; do right="${right%/}"; done
    [[ "$left" == "$right" ]]
}

_guard_path_contains() {
    local path="${1%/}" root="${2%/}" path_check="$1" root_check="$2"
    if [[ "${GITSETU_OS:-}" == "gitbash" || "${GITSETU_OS:-}" == "macos" ]]; then
        path_check=$(printf '%s' "$path_check" | tr '[:upper:]' '[:lower:]')
        root_check=$(printf '%s' "$root_check" | tr '[:upper:]' '[:lower:]')
    fi
    [[ "$path_check" == "$root_check" || "$path_check" == "$root_check/"* ]]
}

# Populate GUARD_PROFILE_* for the longest matching managed root.
# Return 0 managed match, 1 unmanaged, 2 indeterminate/invalid managed state.
_guard_managed_profile_for_path() {
    local current_path="${1-}" registry="${GITSETU_PROFILES_CONF:-}"
    local i label directory normalized current_norm best_len=-1 best_label="" best_dir=""
    local load_status=0

    GUARD_PROFILE_LABEL=""
    GUARD_PROFILE_DIR=""
    GUARD_PROFILE_CONFIG=""
    GUARD_MATCH_LENGTH=-1

    current_norm=$(_guard_normalize_path "$current_path") || return 2
    [[ -n "$current_norm" ]] || return 2
    if ! declare -f load_profiles >/dev/null 2>&1; then
        return 2
    fi

    load_profiles || load_status=$?
    if [[ "$load_status" -ne 0 ]]; then
        return 2
    fi
    if [[ ! -f "$registry" ]]; then
        if [[ -f "$HOME/.gitconfig" ]] && grep -qF "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}" "$HOME/.gitconfig" 2>/dev/null; then
            return 2
        fi
        return 1
    fi
    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        # A managed global block with an empty registry is an incomplete install,
        # not evidence that this repository is unmanaged.
        if [[ -f "$HOME/.gitconfig" ]] && grep -qF "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}" "$HOME/.gitconfig" 2>/dev/null; then
            return 2
        fi
        return 1
    fi

    for (( i=0; i<PROFILE_COUNT; i++ )); do
        if [[ ! ${PROFILE_DIRS[$i]+x} || ! ${PROFILE_LABELS[$i]+x} ]]; then
            return 2
        fi
        directory="${PROFILE_DIRS[$i]}"
        [[ -n "$directory" ]] || continue
        normalized=$(_guard_normalize_path "$directory") || return 2
        label="${PROFILE_LABELS[$i]}"
        [[ -n "$label" ]] || return 2
        if [[ "$normalized" == "$best_dir" ]]; then
            return 2
        fi
        if _guard_path_contains "$current_norm" "$normalized"; then
            if [[ "${#normalized}" -gt "$best_len" ]]; then
                best_len="${#normalized}"
                best_label="$label"
                best_dir="$normalized"
            elif [[ "${#normalized}" -eq "$best_len" ]]; then
                # Same effective root is ambiguous, even if raw spellings differ.
                return 2
            fi
        fi
    done

    if [[ "$best_len" -ge 0 ]]; then
        GUARD_PROFILE_LABEL="$best_label"
        GUARD_PROFILE_DIR="$best_dir"
        GUARD_MATCH_LENGTH="$best_len"
        GUARD_PROFILE_CONFIG="${GITSETU_PROFILES_DIR:-${GITSETU_CONFIG_DIR:-${HOME}/.config/gitsetu}/profiles}/${best_label}.gitconfig"
        return 0
    fi

    # Check remote URL routing if not matched by directory
    local remotes_dir="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/remotes"
    if [[ -d "$remotes_dir" ]] && command -v git >/dev/null 2>&1; then
        if git rev-parse --git-dir >/dev/null 2>&1; then
            local rem_urls
            rem_urls=$(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | awk '{print $2}' || true)
            if [[ -n "$rem_urls" ]]; then
                local rf r_label r_pat rem_match_label=""
                for rf in "$remotes_dir"/*.remotes; do
                    [[ -f "$rf" ]] || continue
                    r_label=$(basename "$rf" .remotes)
                    local is_valid_profile=0 p_idx
                    for (( p_idx=0; p_idx<PROFILE_COUNT; p_idx++ )); do
                        if [[ "${PROFILE_LABELS[$p_idx]:-}" == "$r_label" ]]; then
                            is_valid_profile=1
                            break
                        fi
                    done
                    [[ "$is_valid_profile" -eq 1 ]] || continue

                    while IFS= read -r r_pat || [[ -n "$r_pat" ]]; do
                        r_pat=$(printf '%s' "$r_pat" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                        [[ -n "$r_pat" && "$r_pat" != \#* ]] || continue
                        local u
                        while IFS= read -r u || [[ -n "$u" ]]; do
                            [[ -n "$u" ]] || continue
                            case "$u" in
                                $r_pat)
                                    if [[ -n "$rem_match_label" && "$rem_match_label" != "$r_label" ]]; then
                                        return 2
                                    fi
                                    rem_match_label="$r_label"
                                    ;;
                            esac
                        done <<< "$rem_urls"
                    done < "$rf"
                done

                if [[ -n "$rem_match_label" ]]; then
                    GUARD_PROFILE_LABEL="$rem_match_label"
                    GUARD_PROFILE_DIR=""
                    GUARD_MATCH_LENGTH=0
                    GUARD_PROFILE_CONFIG="${GITSETU_PROFILES_DIR:-${GITSETU_CONFIG_DIR:-${HOME}/.config/gitsetu}/profiles}/${rem_match_label}.gitconfig"
                    return 0
                fi
            fi
        fi
    fi

    return 1
}

# ------------------------------------------------------------------------------
# Identity evaluation
# ------------------------------------------------------------------------------

_guard_identity_from_ident() {
    local ident="${1-}" name email
    [[ "$ident" == *"<"*">"* ]] || return 1
    name=${ident%<*}
    email=${ident##*<}
    email=${email%%>*}
    while [[ "$name" == " "* || "$name" == $'\t'* ]]; do name="${name# }"; name="${name#$'\t'}"; done
    while [[ "$name" == *" " || "$name" == *$'\t' ]]; do name="${name% }"; name="${name%$'\t'}"; done
    [[ -n "$name" && -n "$email" ]] || return 1
    GUARD_IDENT_NAME="$name"
    GUARD_IDENT_EMAIL="$email"
}

_guard_record_mismatch() {
    local kind="$1" expected_name="$2" expected_email="$3" actual_name="$4" actual_email="$5"
    GUARD_MISMATCH_KIND="$kind"
    GUARD_EXPECTED_NAME="$expected_name"
    GUARD_EXPECTED_EMAIL="$expected_email"
    GUARD_ACTUAL_NAME="$actual_name"
    GUARD_ACTUAL_EMAIL="$actual_email"
}

# Return 0 identity is valid, 1 mismatch/error with diagnostics populated.
_guard_validate_effective_identity() {
    local label="$1" profile_config="$2"
    local expected_name expected_email configured_name configured_email
    local author_ident committer_ident author_name author_email committer_name committer_email
    local origin_line

    GUARD_MISMATCH_KIND=""
    GUARD_EXPECTED_ORIGIN="$profile_config"
    GUARD_ACTUAL_NAME_ORIGIN=""
    GUARD_ACTUAL_EMAIL_ORIGIN=""

    [[ -f "$profile_config" ]] || {
        _guard_record_mismatch "managed profile config" "" "" "$profile_config" ""
        return 1
    }
    expected_name=$(git config -f "$profile_config" --get user.name 2>/dev/null) || expected_name=""
    expected_email=$(git config -f "$profile_config" --get user.email 2>/dev/null) || expected_email=""
    if [[ -z "$expected_name" || -z "$expected_email" ]]; then
        _guard_record_mismatch "managed identity definition" "$expected_name" "$expected_email" "" ""
        return 1
    fi

    origin_line=$(git config --show-origin --get user.name 2>/dev/null || true)
    if [[ -n "$origin_line" ]]; then
        GUARD_ACTUAL_NAME_ORIGIN="${origin_line%%	*}"
        GUARD_ACTUAL_NAME_ORIGIN="${GUARD_ACTUAL_NAME_ORIGIN#file:}"
    fi
    origin_line=$(git config --show-origin --get user.email 2>/dev/null || true)
    if [[ -n "$origin_line" ]]; then
        GUARD_ACTUAL_EMAIL_ORIGIN="${origin_line%%	*}"
        GUARD_ACTUAL_EMAIL_ORIGIN="${GUARD_ACTUAL_EMAIL_ORIGIN#file:}"
    fi

    # These commands include system/global/worktree/local values under Git's
    # normal precedence; they are not registry or global-only lookups.
    configured_name=$(git config --get user.name 2>/dev/null) || configured_name=""
    configured_email=$(git config --get user.email 2>/dev/null) || configured_email=""
    if [[ "$configured_name" != "$expected_name" || "$configured_email" != "$expected_email" ]]; then
        _guard_record_mismatch "effective Git identity" "$expected_name" "$expected_email" "$configured_name" "$configured_email"
        return 1
    fi

    # git var observes GIT_AUTHOR_* / GIT_COMMITTER_* and Git's --author option
    # before object creation. Parse the resulting prospective identities.
    author_ident=$(git var GIT_AUTHOR_IDENT 2>/dev/null) || author_ident=""
    committer_ident=$(git var GIT_COMMITTER_IDENT 2>/dev/null) || committer_ident=""
    _guard_identity_from_ident "$author_ident" || {
        _guard_record_mismatch "prospective author identity" "$expected_name" "$expected_email" "$author_ident" ""
        return 1
    }
    author_name="$GUARD_IDENT_NAME"
    author_email="$GUARD_IDENT_EMAIL"
    if [[ "$author_name" != "$expected_name" || "$author_email" != "$expected_email" ]]; then
        _guard_record_mismatch "prospective author identity" "$expected_name" "$expected_email" "$author_name" "$author_email"
        return 1
    fi

    _guard_identity_from_ident "$committer_ident" || {
        _guard_record_mismatch "prospective committer identity" "$expected_name" "$expected_email" "$committer_ident" ""
        return 1
    }
    committer_name="$GUARD_IDENT_NAME"
    committer_email="$GUARD_IDENT_EMAIL"
    if [[ "$committer_name" != "$expected_name" || "$committer_email" != "$expected_email" ]]; then
        _guard_record_mismatch "prospective committer identity" "$expected_name" "$expected_email" "$committer_name" "$committer_email"
        return 1
    fi
    return 0
}

_guard_block_identity() {
    local label="$1"
    local red='\033[0;31m' green='\033[0;32m' bold='\033[1m' reset='\033[0m'
    local exp_origin="${GUARD_EXPECTED_ORIGIN:+ (from ${GUARD_EXPECTED_ORIGIN})}"
    local act_name_origin="${GUARD_ACTUAL_NAME_ORIGIN:+ (from ${GUARD_ACTUAL_NAME_ORIGIN})}"
    local act_email_origin="${GUARD_ACTUAL_EMAIL_ORIGIN:+ (from ${GUARD_ACTUAL_EMAIL_ORIGIN})}"
    printf '\n  %bGitSetu Guard: BLOCKING COMMIT%b\n' "$red" "$reset" >&2
    printf '  Managed profile: %b%s%b\n' "$bold" "$label" "$reset" >&2
    printf '  Mismatch: %s\n' "${GUARD_MISMATCH_KIND:-managed identity unavailable}" >&2
    printf '  Expected name:  %b%s%b%s\n' "$green" "${GUARD_EXPECTED_NAME:-<unset>}" "$reset" "$exp_origin" >&2
    printf '  Expected email: %b%s%b%s\n' "$green" "${GUARD_EXPECTED_EMAIL:-<unset>}" "$reset" "$exp_origin" >&2
    printf '  Actual name:    %s%s\n' "${GUARD_ACTUAL_NAME:-<unset>}" "$act_name_origin" >&2
    printf '  Actual email:   %s%s\n' "${GUARD_ACTUAL_EMAIL:-<unset>}" "$act_email_origin" >&2
    printf '  Git does not reveal whether --author, environment, or config supplied the prospective author.\n' >&2
    printf '  The resulting author and committer were checked; --no-verify and later history rewrites remain outside this hook.\n' >&2
    printf '  Run %bgitsetu doctor%b or remove the conflicting local/worktree override.\n' "$bold" "$reset" >&2
    exit 65
}

_guard_block_unknown_managed_state() {
    printf '\n  %bGitSetu Guard: BLOCKING COMMIT%b\n' '\033[0;31m' '\033[0m' >&2
    printf '  Managed identity state is missing or invalid, so this repository cannot be classified safely.\n' >&2
    printf '  Run %bgitsetu doctor%b; use --no-verify only if you independently verified the identity.\n' '\033[1m' '\033[0m' >&2
    exit 65
}

_guard_execute() {
    local root common_dir route_path resolve_status=0
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd)
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || common_dir="$root/.git"
    if [[ "$common_dir" != /* && "$common_dir" != [a-zA-Z]:/* ]]; then
        common_dir="$root/$common_dir"
    fi
    route_path="$common_dir"
    _guard_managed_profile_for_path "$route_path" || resolve_status=$?

    if [[ "$resolve_status" -eq 1 ]]; then
        return 0
    fi
    if [[ "$resolve_status" -ne 0 ]]; then
        _guard_block_unknown_managed_state
    fi

    if ! _guard_validate_effective_identity "$GUARD_PROFILE_LABEL" "$GUARD_PROFILE_CONFIG"; then
        _guard_block_identity "$GUARD_PROFILE_LABEL"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Installation lifecycle
# ------------------------------------------------------------------------------

GITSETU_GUARD_HOOK_NAMES=(
    applypatch-msg
    pre-applypatch
    post-applypatch
    pre-commit
    pre-merge-commit
    prepare-commit-msg
    commit-msg
    post-commit
    pre-rebase
    post-checkout
    post-merge
    pre-push
    post-rewrite
    pre-auto-gc
    reference-transaction
    sendemail-validate
    post-index-change
)

_guard_resolve_entrypoint() {
    local entrypoint=""
    if [[ -n "${GITSETU_ENTRYPOINT:-}" && -f "$GITSETU_ENTRYPOINT" ]]; then
        entrypoint="$GITSETU_ENTRYPOINT"
    elif [[ -f "$HOME/.local/bin/gitsetu" ]]; then
        entrypoint="$HOME/.local/bin/gitsetu"
    elif command -v gitsetu >/dev/null 2>&1; then
        entrypoint="$(command -v gitsetu)"
    elif [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        local src_candidate
        src_candidate=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/gitsetu
        if [[ -f "$src_candidate" ]]; then
            entrypoint="$src_candidate"
        fi
    fi
    if [[ -z "$entrypoint" && -f "$0" ]]; then
        entrypoint="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
    fi
    entrypoint=$(normalize_path "$entrypoint") || true
    GUARD_RESOLVED_ENTRYPOINT="$entrypoint"
}

_guard_generate_stub_content() {
    local entrypoint="$1"
    cat <<'STUB_EOF'
#!/usr/bin/env bash
# [gitsetu:managed] gitsetu-hook v3
HOOK_NAME="$(basename "$0")"
HOOKS_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
ENTRYPOINT=""
if [[ -f "$HOOKS_DIR/entrypoint" ]]; then
    ENTRYPOINT="$(cat "$HOOKS_DIR/entrypoint" 2>/dev/null || true)"
    ENTRYPOINT="${ENTRYPOINT%$'\r'}"
fi
if [[ -z "$ENTRYPOINT" ]]; then
STUB_EOF
    printf '    ENTRYPOINT="%s"\n' "$entrypoint"
    cat <<'STUB_EOF'
fi

if [[ "$HOOK_NAME" == "pre-commit" || "$HOOK_NAME" == "pre-merge-commit" ]]; then
    if [[ -z "$ENTRYPOINT" || ! -x "$ENTRYPOINT" ]]; then
        printf 'GitSetu guard: gitsetu not found at %s; commit allowed (failsafe). Run gitsetu doctor.\n' "${ENTRYPOINT:-<empty>}" >&2
    else
        "$ENTRYPOINT" __guard-hook "$HOOK_NAME" "$@"
        rc=$?
        if [[ $rc -eq 65 ]]; then
            exit 65
        elif [[ $rc -eq 126 || $rc -eq 127 ]]; then
            printf 'GitSetu guard: gitsetu invocation failed (code %d); commit allowed (failsafe).\n' "$rc" >&2
        elif [[ $rc -ne 0 ]]; then
            printf 'GitSetu guard: identity verification error (code %d); commit blocked.\n' "$rc" >&2
            exit "$rc"
        fi
    fi
fi

DISPLACED=""
if command -v git >/dev/null 2>&1; then
    raw_hooks=$(git config --show-origin --get-all core.hooksPath 2>/dev/null || true)
    if [[ -n "$raw_hooks" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            origin="${line%%	*}"
            path="${line#*	}"
            origin="${origin#file:}"
            case "$origin" in
                *gitsetu*|*profiles*) continue ;;
            esac
            if [[ "$path" == "~" ]]; then
                path="$HOME"
            elif [[ "$path" == "~/"* ]]; then
                path="$HOME/${path:2}"
            fi
            DISPLACED="$path"
        done <<RAW_EOF
$raw_hooks
RAW_EOF
    fi

    if [[ -n "$DISPLACED" && "$DISPLACED" != /* && ! "$DISPLACED" =~ ^[a-zA-Z]:[/\\] ]]; then
        TOP_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        DISPLACED="$TOP_DIR/$DISPLACED"
    fi

    if [[ -z "$DISPLACED" ]]; then
        COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
        if [[ -n "$COMMON_DIR" ]]; then
            if [[ "$COMMON_DIR" != /* && ! "$COMMON_DIR" =~ ^[a-zA-Z]:[/\\] ]]; then
                TOP_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
                COMMON_DIR="$TOP_DIR/$COMMON_DIR"
            fi
            DISPLACED="$COMMON_DIR/hooks"
        fi
    fi
fi

if [[ -n "$DISPLACED" && -f "$DISPLACED/$HOOK_NAME" && -x "$DISPLACED/$HOOK_NAME" ]]; then
    DISPLACED_CANONICAL="$(cd "$(dirname "$DISPLACED/$HOOK_NAME")" 2>/dev/null && pwd)"
    if [[ "$DISPLACED_CANONICAL" != "$HOOKS_DIR" ]]; then
        exec "$DISPLACED/$HOOK_NAME" "$@"
    fi
fi

exit 0
STUB_EOF
}

_guard_cleanup_legacy_global_hookspath() {
    local global_hooks previous="" state_file="${GITSETU_HOOKS_DIR:-$HOME/.config/gitsetu/hooks}/$_GUARD_STATE_BASENAME"
    global_hooks=$(git config --global core.hooksPath 2>/dev/null || true)
    if _guard_paths_equal "$global_hooks" "${GITSETU_HOOKS_DIR:-$HOME/.config/gitsetu/hooks}"; then
        if [[ -f "$state_file" ]]; then
            previous=$(cat "$state_file" 2>/dev/null || true)
            previous=${previous%$'\r'}
        fi
        if [[ -n "$previous" && "$previous" != "none" ]]; then
            git config --global core.hooksPath "$previous" 2>/dev/null || true
        else
            git config --global --unset core.hooksPath 2>/dev/null || true
        fi
    fi
}

install_guard() {
    local hooks_dir="$GITSETU_HOOKS_DIR"
    local h stub_tmp stub_content

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would install guard hook stubs into: $hooks_dir"
        return 0
    fi

    if declare -f load_profiles >/dev/null 2>&1; then
        if ! load_profiles; then
            print_error "Cannot install guard: profile registry is invalid or unreadable."
            return 1
        fi
    fi

    ensure_dirs || return 1
    mkdir -p "$hooks_dir" || return 1
    chmod 700 "$hooks_dir" 2>/dev/null || true

    _guard_resolve_entrypoint
    local entrypoint="$GUARD_RESOLVED_ENTRYPOINT"
    printf '%s\n' "$entrypoint" > "$hooks_dir/entrypoint" || return 1
    chmod 600 "$hooks_dir/entrypoint" 2>/dev/null || true

    stub_content=$(_guard_generate_stub_content "$entrypoint")

    for h in "${GITSETU_GUARD_HOOK_NAMES[@]}"; do
        stub_tmp=$(umask 077; mktemp "$hooks_dir/${h}.tmp.XXXXXX" 2>/dev/null) || {
            print_error "Failed to create temporary hook file for $h."
            return 1
        }
        printf '%s\n' "$stub_content" > "$stub_tmp" || { rm -f "$stub_tmp"; return 1; }
        chmod 700 "$stub_tmp" 2>/dev/null || { rm -f "$stub_tmp"; return 1; }
        mv -f "$stub_tmp" "$hooks_dir/$h" || { rm -f "$stub_tmp"; return 1; }
    done

    touch "$hooks_dir/enabled" || return 1
    chmod 600 "$hooks_dir/enabled" 2>/dev/null || true

    _guard_cleanup_legacy_global_hookspath

    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        [[ "${PROFILE_LABELS[$i]}" == "global" ]] && continue
        if declare -f write_profile_gitconfig >/dev/null 2>&1; then
            write_profile_gitconfig "${PROFILE_LABELS[$i]}" "${PROFILE_NAMES[$i]}" \
                "${PROFILE_EMAILS[$i]}" "${PROFILE_SIGNS[$i]}" "${PROFILE_KEYS[$i]}" \
                "${PROFILE_PROVIDERS[$i]:-}" "${PROFILE_USERS[$i]:-}" 2>/dev/null || true
        fi
    done
    if [[ "${GITSETU_REGISTRY_WAS_V1:-0}" -eq 1 ]]; then
        if declare -f write_profiles_registry >/dev/null 2>&1; then
            write_profiles_registry "$GITSETU_PROFILES_CONF" || true
        fi
    elif declare -f write_profiles_conf >/dev/null 2>&1; then
        write_profiles_conf || true
    fi

    print_success "Guard installed in: $hooks_dir"
    print_info "Managed profiles enforce identity guard. Unmanaged repositories fail open."
    return 0
}

uninstall_guard() {
    local hooks_dir="$GITSETU_HOOKS_DIR"
    local h

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would remove guard hooks from: $hooks_dir"
        return 0
    fi

    rm -f "$hooks_dir/enabled" "$hooks_dir/entrypoint" 2>/dev/null || true
    for h in "${GITSETU_GUARD_HOOK_NAMES[@]}"; do
        rm -f "$hooks_dir/$h" 2>/dev/null || true
    done

    _guard_cleanup_legacy_global_hookspath
    rm -f "$hooks_dir/$_GUARD_STATE_BASENAME" 2>/dev/null || true

    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]] && declare -f load_profiles >/dev/null 2>&1; then
        load_profiles >/dev/null 2>&1 || true
    fi
    local i
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        [[ "${PROFILE_LABELS[$i]}" == "global" ]] && continue
        if declare -f write_profile_gitconfig >/dev/null 2>&1; then
            write_profile_gitconfig "${PROFILE_LABELS[$i]}" "${PROFILE_NAMES[$i]}" \
                "${PROFILE_EMAILS[$i]}" "${PROFILE_SIGNS[$i]}" "${PROFILE_KEYS[$i]}" \
                "${PROFILE_PROVIDERS[$i]:-}" "${PROFILE_USERS[$i]:-}" 2>/dev/null || true
        fi
    done
    if declare -f write_profiles_conf >/dev/null 2>&1; then
        write_profiles_conf || true
    fi

    print_success "Guard uninstalled."
    return 0
}
