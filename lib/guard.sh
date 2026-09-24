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

    [[ "$best_len" -ge 0 ]] || return 1
    GUARD_PROFILE_LABEL="$best_label"
    GUARD_PROFILE_DIR="$best_dir"
    GUARD_MATCH_LENGTH="$best_len"
    GUARD_PROFILE_CONFIG="${GITSETU_PROFILES_DIR:-${GITSETU_CONFIG_DIR:-${HOME}/.config/gitsetu}/profiles}/${best_label}.gitconfig"
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

    GUARD_MISMATCH_KIND=""
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
    printf '\n  %bGitSetu Guard: BLOCKING COMMIT%b\n' "$red" "$reset" >&2
    printf '  Managed profile: %b%s%b\n' "$bold" "$label" "$reset" >&2
    printf '  Mismatch: %s\n' "${GUARD_MISMATCH_KIND:-managed identity unavailable}" >&2
    printf '  Expected name:  %b%s%b\n' "$green" "${GUARD_EXPECTED_NAME:-<unset>}" "$reset" >&2
    printf '  Expected email: %b%s%b\n' "$green" "${GUARD_EXPECTED_EMAIL:-<unset>}" "$reset" >&2
    printf '  Actual name:    %s\n' "${GUARD_ACTUAL_NAME:-<unset>}" >&2
    printf '  Actual email:   %s\n' "${GUARD_ACTUAL_EMAIL:-<unset>}" >&2
    printf '  Git does not reveal whether --author, environment, or config supplied the prospective author.\n' >&2
    printf '  The resulting author and committer were checked; --no-verify and later history rewrites remain outside this hook.\n' >&2
    printf '  Run %bgitsetu doctor%b or remove the conflicting local/worktree override.\n' "$bold" "$reset" >&2
    exit 1
}

_guard_block_unknown_managed_state() {
    printf '\n  %bGitSetu Guard: BLOCKING COMMIT%b\n' '\033[0;31m' '\033[0m' >&2
    printf '  Managed identity state is missing or invalid, so this repository cannot be classified safely.\n' >&2
    printf '  Run %bgitsetu doctor%b; use --no-verify only if you independently verified the identity.\n' '\033[1m' '\033[0m' >&2
    exit 1
}

# Run the repository hook that the global hooksPath temporarily displaced.
# stdin remains untouched and all arguments are forwarded.
_guard_run_downstream_hook() {
    local root="$1" state_file="${GITSETU_HOOKS_DIR:-${GITSETU_CONFIG_DIR:-${HOME}/.config/gitsetu}/hooks}/$_GUARD_STATE_BASENAME"
    local configured="" candidate common_dir status=0

    if [[ -L "$state_file" ]]; then
        printf '%s\n' '[GitSetu Guard] ERROR: redirected prior hooksPath state; refusing to guess.' >&2
        exit 1
    fi
    if [[ -f "$state_file" ]]; then
        configured=$(cat "$state_file" 2>/dev/null) || configured=""
        configured=${configured%$'\r'}
        if [[ "$configured" == *$'\n'* || "$configured" == *$'\r'* ]]; then
            printf '%s\n' '[GitSetu Guard] ERROR: invalid prior hooksPath state; refusing to guess.' >&2
            exit 1
        fi
        [[ "$configured" == "none" ]] && configured=""
    fi

    if [[ -n "$configured" ]]; then
        if [[ "$configured" != /* && "$configured" != [a-zA-Z]:/* ]]; then
            candidate="$root/$configured"
        else
            candidate="$configured"
        fi
    else
        # `git rev-parse --git-path hooks` honors core.hooksPath and would point
        # back to this wrapper. Derive the repository's real common-dir hook
        # directly; this also gives linked worktrees their common hook location.
        common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || common_dir="$root/.git"
        if [[ "$common_dir" != /* && "$common_dir" != [a-zA-Z]:/* ]]; then
            common_dir="$root/$common_dir"
        fi
        candidate="${common_dir%/}/hooks/pre-commit"
    fi

    if _guard_paths_equal "$candidate" "$GITSETU_HOOKS_DIR/pre-commit"; then
        return 0
    fi
    if [[ -f "$candidate" && -x "$candidate" ]]; then
        "$candidate" "$@" || status=$?
        return "$status"
    fi
    return 0
}

# This function is called by the installed hook after loading the current
# GitSetu modules. Keeping policy in the library makes installed and source-test
# behavior identical.
_guard_execute() {
    local root common_dir route_path resolve_status=0
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd)
    # Match Git's own includeIf semantics: conditional gitdir routing uses the
    # repository's common git directory. For a linked worktree this remains
    # under the primary repository, so routing is deterministic even when the
    # linked working tree is checked out elsewhere.
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || common_dir="$root/.git"
    if [[ "$common_dir" != /* && "$common_dir" != [a-zA-Z]:/* ]]; then
        common_dir="$root/$common_dir"
    fi
    route_path="$common_dir"
    _guard_managed_profile_for_path "$route_path"
    resolve_status=$?

    if [[ "$resolve_status" -eq 1 ]]; then
        _guard_run_downstream_hook "$root" "$@"
        return $?
    fi
    if [[ "$resolve_status" -ne 0 ]]; then
        _guard_block_unknown_managed_state
    fi

    if ! _guard_validate_effective_identity "$GUARD_PROFILE_LABEL" "$GUARD_PROFILE_CONFIG"; then
        _guard_block_identity "$GUARD_PROFILE_LABEL"
    fi
    _guard_run_downstream_hook "$root" "$@"
}

# ------------------------------------------------------------------------------
# Installation lifecycle
# ------------------------------------------------------------------------------

_guard_shell_quote() {
    local value="$1"
    value="${value//\'/\'\\\'\'}"
    printf "'%s'" "$value"
}

# Resolve the one library root trusted for a persistent hook. Production is
# bound to the canonical root of the guard.sh that is executing now; caller
# supplied GITSETU_DIR is ignored. A test/developer checkout may opt in
# explicitly, but module shape is still validated before persistence.
_guard_trusted_library_root() {
    local origin_file="${BASH_SOURCE[0]}" origin_dir candidate canonical module
    origin_dir=$(cd "$(dirname "$origin_file")" 2>/dev/null && pwd -P) || return 1
    if [[ "$(basename "$origin_file")" == "guard.sh" ]]; then
        candidate=$(dirname "$origin_dir")
    else
        candidate="$origin_dir"
    fi

    if [[ -n "${GITSETU_DIR:-}" && "${GITSETU_TEST:-0}" == "1" && "${GITSETU_ALLOW_TEST_LIB_DIR:-0}" == "1" ]]; then
        candidate="$GITSETU_DIR"
    fi
    canonical=$(cd "$candidate" 2>/dev/null && pwd -P) || return 1
    for module in core.sh platform.sh validate.sh ui.sh gitconfig.sh guard.sh; do
        [[ -f "$canonical/lib/$module" && ! -L "$canonical/lib/$module" ]] || return 1
    done
    GUARD_TRUSTED_LIB_ROOT="$canonical"
}

# Hook-side counterpart: reject missing and symlinked module files.
_guard_hook_module_is_safe() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]]
}

_guard_write_state() {
    local state_path="$1" value="$2" tmp
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    tmp=$(umask 077; mktemp "${state_path}.tmp.XXXXXX") || return 1
    printf '%s\n' "${value:-none}" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$state_path"
}

install_guard() {
    local hook_path="$GITSETU_HOOKS_DIR/pre-commit"
    local state_path="$GITSETU_HOOKS_DIR/$_GUARD_STATE_BASENAME"
    local existing_hooks_path current_hooks_path
    local hooks_dir lib_dir lib_quoted hook_tmp

    existing_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)

    if [[ -n "$existing_hooks_path" ]] && ! _guard_paths_equal "$existing_hooks_path" "$GITSETU_HOOKS_DIR"; then
        print_warning "core.hooksPath is already set to: $existing_hooks_path"
        print_warning "GitSetu will chain that hook explicitly; uninstall restores the exact prior value."
        if ! confirm "Override core.hooksPath with the gitsetu hooks directory?" "n"; then
            print_info "Guard hook installation skipped."
            return 0
        fi
    fi

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would install guard hook at: $hook_path"
        print_info "[DRY RUN] Would set core.hooksPath = $GITSETU_HOOKS_DIR"
        return 0
    fi

    _guard_trusted_library_root || {
        print_error "Cannot establish a canonical regular-file GitSetu library root for the persistent guard hook."
        return 1
    }
    lib_dir="$GUARD_TRUSTED_LIB_ROOT"
    lib_quoted=$(_guard_shell_quote "$lib_dir") || return 1

    ensure_dirs || return 1
    chmod 700 "$GITSETU_HOOKS_DIR" 2>/dev/null || {
        print_error "Failed to enforce mode 0700 on hooks directory."
        return 1
    }

    if [[ -z "$existing_hooks_path" ]] || ! _guard_paths_equal "$existing_hooks_path" "$GITSETU_HOOKS_DIR"; then
        _guard_write_state "$state_path" "${existing_hooks_path:-none}" || {
            print_error "Failed to record the existing hooksPath policy."
            return 1
        }
    elif [[ ! -f "$state_path" ]]; then
        # A fresh v2 installation has no previous hook to recover. Do not infer
        # or migrate a policy from an older on-disk format.
        _guard_write_state "$state_path" "none" || return 1
    fi

    hooks_dir=$(normalize_path "$GITSETU_HOOKS_DIR") || return 1
    hook_tmp=$(umask 077; mktemp "${hook_path}.tmp.XXXXXX") || {
        print_error "Failed to create temporary guard hook."
        return 1
    }

    cat > "$hook_tmp" <<HOOK_SCRIPT
#!/usr/bin/env bash
# [gitsetu:managed] v2 pre-commit identity guard
set -u
set -o pipefail
GITSETU_CLEANUP_FILES=()
GITSETU_CLEANUP_DIRS=()
GITSETU_LIB_DIR=${lib_quoted}

_guard_hook_load_failed() {
    printf '%s\n' '[GitSetu Guard] ERROR: installed guard modules are missing or unsafe; managed commits fail closed.' >&2
    exit 1
}

_guard_hook_module_is_safe() {
    [[ -f "\$1" && ! -L "\$1" ]]
}

for _guard_module in core.sh platform.sh validate.sh ui.sh gitconfig.sh guard.sh; do
    _guard_hook_module_is_safe "\$GITSETU_LIB_DIR/lib/\$_guard_module" || _guard_hook_load_failed
    # shellcheck disable=SC1090
    source "\$GITSETU_LIB_DIR/lib/\$_guard_module" || _guard_hook_load_failed
done
unset _guard_module

_guard_execute "\$@"
HOOK_SCRIPT

    chmod 700 "$hook_tmp" 2>/dev/null || {
        rm -f "$hook_tmp"
        print_error "Failed to enforce executable permissions on guard hook."
        return 1
    }
    mv -f "$hook_tmp" "$hook_path" || return 1
    git config --global core.hooksPath "$hooks_dir" || {
        rm -f "$hook_path"
        return 1
    }

    print_success "Guard hook installed: $hook_path"
    print_info "Managed repositories fail closed; unmanaged repositories only run their normal hooks."
    print_info "The guard checks prospective author and committer identities, but not --no-verify or history rewrites."
}

uninstall_guard() {
    local hook_path="$GITSETU_HOOKS_DIR/pre-commit"
    local state_path="$GITSETU_HOOKS_DIR/$_GUARD_STATE_BASENAME"
    local current_hooks_path previous=""

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        print_info "[DRY RUN] Would remove: $hook_path"
        print_info "[DRY RUN] Would restore the prior core.hooksPath policy"
        return 0
    fi

    if [[ -f "$hook_path" ]]; then
        rm -f "$hook_path"
        print_success "Removed guard hook: $hook_path"
    else
        print_info "No guard hook found at: $hook_path"
    fi

    current_hooks_path=$(git config --global core.hooksPath 2>/dev/null || true)
    if _guard_paths_equal "$current_hooks_path" "$GITSETU_HOOKS_DIR"; then
        if [[ -f "$state_path" ]]; then
            previous=$(cat "$state_path" 2>/dev/null) || previous=""
            previous=${previous%$'\r'}
        fi
        if [[ -n "$previous" && "$previous" != "none" ]]; then
            git config --global core.hooksPath "$previous" || return 1
            print_success "Restored prior core.hooksPath: $previous"
        else
            git config --global --unset core.hooksPath 2>/dev/null || true
            print_success "Unset core.hooksPath"
        fi
    elif [[ -n "$current_hooks_path" ]]; then
        print_warning "core.hooksPath points to '$current_hooks_path' (not gitsetu). Leaving it unchanged."
    fi
    rm -f "$state_path"
}
