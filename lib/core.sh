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
# Normalize environment paths on Windows (converts backslashes to forward slashes)
# ------------------------------------------------------------------------------
if [[ -n "${HOME:-}" ]]; then
    HOME="${HOME//\\//}"
fi
if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME//\\//}"
fi
if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    XDG_STATE_HOME="${XDG_STATE_HOME//\\//}"
fi
if [[ -n "${LOCALAPPDATA:-}" ]]; then
    LOCALAPPDATA="${LOCALAPPDATA//\\//}"
fi
if [[ -n "${GITSETU_TEST_RUNTIME_DIR:-}" ]]; then
    GITSETU_TEST_RUNTIME_DIR="${GITSETU_TEST_RUNTIME_DIR//\\//}"
fi

GITSETU_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu"
GITSETU_BACKUP_DIR="$GITSETU_CONFIG_DIR/backups"
GITSETU_PROFILES_DIR="$GITSETU_CONFIG_DIR/profiles"
GITSETU_HOOKS_DIR="$GITSETU_CONFIG_DIR/hooks"
GITSETU_PROFILES_CONF="$GITSETU_CONFIG_DIR/profiles.conf"
# Immutable write anchor captured when core is sourced. Runtime code may point
# GITSETU_PROFILES_CONF at an archive for reads, but cannot redirect writes.
GITSETU_REGISTRY_WRITE_CONF="$GITSETU_PROFILES_CONF"
GITSETU_REGISTRY_WRITE_ROOT="$GITSETU_CONFIG_DIR"
# Lower-case internal anchors are not part of the GITSETU_* environment surface
# and therefore cannot be cleared by environment-isolating callers/tests.
_gitsetu_registry_write_conf="$GITSETU_PROFILES_CONF"
_gitsetu_registry_write_root="$GITSETU_CONFIG_DIR"

# The lock is runtime state, never part of the removable profile/config tree.
# Keep a marker for the lazy setup configurator so it can distinguish this
# safe core default from an explicitly selected integration path.
_gitsetu_lock_path_canonicalish() {
    local path="${1:-}"
    path="${path//\\//}"
    case "$path" in
        /[A-Za-z]/*)
            local drive
            drive=$(printf '%s' "${path:1:1}" | tr '[:lower:]' '[:upper:]')
            path="$drive:/${path:3}"
            ;;
    esac
    printf '%s' "$path"
}

_gitsetu_default_runtime_lock_path() {
    local base candidate config_root fallback
    if [[ "${GITSETU_TEST:-0}" == "1" ]]; then
        base="${GITSETU_TEST_RUNTIME_DIR:-${HOME:-}/.gitsetu-test-runtime}"
    elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
        base="$XDG_STATE_HOME"
    elif [[ "${GITSETU_OS:-}" == "gitbash" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* || "${OSTYPE:-}" == cygwin* ]] &&
         [[ -n "${LOCALAPPDATA:-}" ]]; then
        base="$LOCALAPPDATA"
    else
        base="${HOME:-}/.local/state"
    fi
    base="${base%/}"
    [[ -n "$base" && "$base" != "/" ]] || return 1
    if [[ "${GITSETU_TEST:-0}" == "1" ]]; then
        candidate="$base/profiles.lock"
    else
        candidate="$base/gitsetu/profiles.lock"
    fi

    # Invalid/ relative state variables must not silently redirect locking into
    # the config tree.  Fall back to a per-user state directory instead.
    case "$candidate" in
        /*|[A-Za-z]:/*) ;;
        *) candidate="" ;;
    esac
    if [[ -n "$candidate" ]]; then
        case "/$candidate/" in
            *"/../"*|*"/./"*) candidate="" ;;
        esac
    fi
    config_root="${GITSETU_CONFIG_DIR:-}"
    if [[ -n "$candidate" && -n "$config_root" ]]; then
        local candidate_norm config_norm
        candidate_norm=$(_gitsetu_lock_path_canonicalish "$candidate")
        config_norm=$(_gitsetu_lock_path_canonicalish "$config_root")
        case "$candidate_norm" in
            "$config_norm"|"$config_norm"/*) candidate="" ;;
        esac
    fi
    if [[ -z "$candidate" ]]; then
        fallback="${HOME:-}/.gitsetu-state"
        fallback="${fallback%/}"
        if [[ -z "$fallback" || "$fallback" == "/" ]]; then
            return 1
        fi
        candidate="$fallback/gitsetu/profiles.lock"
        case "$candidate" in
            /*|[A-Za-z]:/*) ;;
            *) return 1 ;;
        esac
    fi
    printf '%s' "$candidate"
}
GITSETU_DEFAULT_LOCK_DIR="$(_gitsetu_default_runtime_lock_path 2>/dev/null || printf '')"
_GITSETU_REQUESTED_LOCK_DIR="${GITSETU_LOCK_DIR:-}"
_GITSETU_REQUESTED_LOCK_DIR="${_GITSETU_REQUESTED_LOCK_DIR//\\//}"
_GITSETU_REQUESTED_LOCK_DIR="${_GITSETU_REQUESTED_LOCK_DIR%/}"
_GITSETU_CONFIG_LOCK_ROOT="${GITSETU_CONFIG_DIR%/}"
_GITSETU_REQUESTED_LOCK_NORM="$(_gitsetu_lock_path_canonicalish "$_GITSETU_REQUESTED_LOCK_DIR")"
_GITSETU_CONFIG_LOCK_NORM="$(_gitsetu_lock_path_canonicalish "$_GITSETU_CONFIG_LOCK_ROOT")"
if [[ -z "$_GITSETU_REQUESTED_LOCK_DIR" || "$_GITSETU_REQUESTED_LOCK_NORM" == "$_GITSETU_CONFIG_LOCK_NORM/profiles.lock" ]]; then
    GITSETU_LOCK_DIR="$GITSETU_DEFAULT_LOCK_DIR"
else
    case "$_GITSETU_REQUESTED_LOCK_NORM" in
        "$_GITSETU_CONFIG_LOCK_NORM"/*) GITSETU_LOCK_DIR="$GITSETU_DEFAULT_LOCK_DIR" ;;
        *) GITSETU_LOCK_DIR="$_GITSETU_REQUESTED_LOCK_DIR" ;;
    esac
fi
GITSETU_LOCK_DEPTH=0

# Versioned profile registry contract (v2 only; legacy files are rejected).
# Header: # gitsetu-registry-v2
# Record: E(label):E(directory):E(provider):E(sign):E(key_path):E(provider_user)
# E(field) is every UTF-8 byte rendered as an uppercase %HH token. Thus a data
# line contains only %HH tokens, literal ':' separators, and its terminating LF.
GITSETU_REGISTRY_VERSION=2
GITSETU_REGISTRY_HEADER="# gitsetu-registry-v2"
GITSETU_REGISTRY_FIELD_COUNT=6
GITSETU_REGISTRY_MAX_PROFILES=1024
GITSETU_REGISTRY_MAX_LINE_LENGTH=131072
GITSETU_REGISTRY_MAX_FIELD_LENGTH=12288
GITSETU_REGISTRY_ERROR=""
_GITSETU_REGISTRY_VERSION=2
_GITSETU_REGISTRY_HEADER="# gitsetu-registry-v2"
_GITSETU_REGISTRY_FIELD_COUNT=6
_GITSETU_REGISTRY_MAX_PROFILES=1024
_GITSETU_REGISTRY_MAX_LINE_LENGTH=131072
_GITSETU_REGISTRY_MAX_FIELD_LENGTH=12288

# ------------------------------------------------------------------------------
# Secure Temporary File & Directory Helpers
# Creates temporary files/directories with restrictive permissions (0600 / 0700)
# under umask 077. Direct calls register resources for cleanup; callers that use
# command substitution must register the returned path with track_temp_file/dir.
# ------------------------------------------------------------------------------
if ! declare -p GITSETU_CLEANUP_FILES >/dev/null 2>&1; then
    GITSETU_CLEANUP_FILES=()
fi
if ! declare -p GITSETU_CLEANUP_DIRS >/dev/null 2>&1; then
    GITSETU_CLEANUP_DIRS=()
fi

GITSETU_TMP_FILE=""
GITSETU_TMP_DIR=""
GITSETU_PRIVATE_DIR=""

# Test both POSIX symlinks and Windows reparse points when the native tools are
# available (notably junctions that some MSYS/Cygwin builds do not expose as -L).
# Cache only bounded, per-process observations. Final mutation callers that need
# a fresh probe can invoke _gitsetu_is_reparse_point_uncached directly.
_GITSETU_REPARSE_CACHE_PATHS=()
_GITSETU_REPARSE_CACHE_RESULTS=()
_GITSETU_REPARSE_CACHE_SIZE=0

_gitsetu_reparse_cache_limit() {
    local limit="${GITSETU_REPARSE_CACHE_MAX:-256}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=256
    (( limit < 1 )) && limit=1
    (( limit > 1024 )) && limit=1024
    printf '%s' "$limit"
}

_gitsetu_reparse_cache_reset() {
    _GITSETU_REPARSE_CACHE_PATHS=()
    _GITSETU_REPARSE_CACHE_RESULTS=()
    _GITSETU_REPARSE_CACHE_SIZE=0
}

_gitsetu_reparse_cache_lookup() {
    local context="${GITSETU_OS:-unknown}:${OSTYPE:-}"
    local key="$context|${1//\\//}" i
    for (( i=0; i<${#_GITSETU_REPARSE_CACHE_PATHS[@]}; i++ )); do
        if [[ "${_GITSETU_REPARSE_CACHE_PATHS[$i]}" == "$key" ]]; then
            if [[ "${_GITSETU_REPARSE_CACHE_RESULTS[$i]}" == "0" || -L "$1" ]]; then
                _GITSETU_REPARSE_CACHE_STATUS=0
            else
                _GITSETU_REPARSE_CACHE_STATUS=1
            fi
            return 0
        fi
    done
    return 1
}

_gitsetu_reparse_cache_store() {
    local context="${GITSETU_OS:-unknown}:${OSTYPE:-}"
    local key="$context|${1//\\//}" result="$2" limit i
    for (( i=0; i<${#_GITSETU_REPARSE_CACHE_PATHS[@]}; i++ )); do
        if [[ "${_GITSETU_REPARSE_CACHE_PATHS[$i]}" == "$key" ]]; then
            _GITSETU_REPARSE_CACHE_RESULTS[i]="$result"
            return 0
        fi
    done
    limit=$(_gitsetu_reparse_cache_limit)
    if (( ${#_GITSETU_REPARSE_CACHE_PATHS[@]} >= limit )); then
        _GITSETU_REPARSE_CACHE_PATHS=("${_GITSETU_REPARSE_CACHE_PATHS[@]:1}")
        _GITSETU_REPARSE_CACHE_RESULTS=("${_GITSETU_REPARSE_CACHE_RESULTS[@]:1}")
    fi
    _GITSETU_REPARSE_CACHE_PATHS+=("$key")
    _GITSETU_REPARSE_CACHE_RESULTS+=("$result")
    _GITSETU_REPARSE_CACHE_SIZE=${#_GITSETU_REPARSE_CACHE_PATHS[@]}
}

_gitsetu_is_reparse_point_uncached() {
    [[ $# -eq 1 ]] || return 2
    [[ -L "$1" ]] && return 0
    if [[ -z "${GITSETU_OS:-}" ]] && declare -f detect_os >/dev/null 2>&1; then
        detect_os
    fi
    if [[ "${GITSETU_OS:-}" == "gitbash" ]] &&
       command -v cygpath >/dev/null 2>&1 &&
       command -v fsutil.exe >/dev/null 2>&1; then
        # A path that does not exist cannot be an existing reparse point;
        # avoid spawning fsutil for every not-yet-created component.
        [[ -e "$1" ]] || return 1
        local windows_path status
        windows_path=$(cygpath -w "$1" 2>/dev/null) || return 2
        if fsutil.exe reparsepoint query "$windows_path" >/dev/null 2>&1; then
            return 0
        else
            status=$?
        fi
        # fsutil uses 0 for an existing reparse point and 1 for an ordinary
        # path. Any other status is indeterminate and must fail closed.
        [[ "$status" -eq 1 ]] && return 1
        return 2
    fi
    return 1
}

_gitsetu_is_reparse_point() {
    [[ $# -eq 1 ]] || return 2
    if _gitsetu_reparse_cache_lookup "$1"; then
        return "$_GITSETU_REPARSE_CACHE_STATUS"
    fi
    local status=0
    if _gitsetu_is_reparse_point_uncached "$1"; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -eq 0 || "$status" -eq 1 ]]; then
        _gitsetu_reparse_cache_store "$1" "$status"
    fi
    return "$status"
}

# Return 0 when any existing component of an absolute path is a symlink. This
# is intentionally a component walk: testing only the final path is insufficient
# when an ancestor is replaced with a link.
_gitsetu_path_has_symlink_component() {
    [[ $# -eq 1 ]] || return 2
    local path="$1"
    if declare -f _gitsetu_reject_ascii_controls >/dev/null 2>&1; then
        _gitsetu_reject_ascii_controls "path" "$path" || return 2
    else
        [[ ! "$path" =~ [[:cntrl:]] ]] || return 2
    fi

    local prefix body current component redirect_status
    local components=()
    local i
    case "$path" in
        /*|[a-zA-Z]:/*) ;;
        *) return 2 ;;
    esac
    if [[ "$path" =~ ^[a-zA-Z]:/ ]]; then
        prefix="${path:0:2}/"
        body="${path:3}"
    elif [[ "$path" == "//" || "$path" == //?* ]]; then
        prefix="//"
        body="${path:2}"
    else
        prefix="/"
        body="${path#/}"
    fi

    IFS='/' read -r -a components <<< "$body"
    current="$prefix"
    for (( i=0; i<${#components[@]}; i++ )); do
        component="${components[$i]}"
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || continue
        if [[ "$prefix" == "//" ]]; then
            if [[ "$current" == "//" ]]; then
                current="${current}${component}"
            else
                current="${current}/${component}"
            fi
        else
            current="${current%/}/${component}"
        fi
        redirect_status=0
        if _gitsetu_is_reparse_point "$current"; then
            return 0
        else
            redirect_status=$?
        fi
        if [[ "$redirect_status" -ne 1 ]]; then
            return 2
        fi
    done
    return 1
}

_gitsetu_secure_temp_template() {
    local template="$1"
    local temp_base="${TMPDIR:-/tmp}"
    local template_parent template_base canonical_parent link_status

    if [[ -z "$template" || "$template" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    if [[ "$template" != *XXXXXX* || "$template" != *XXXXXX ]]; then
        return 1
    fi
    if [[ "$template" != /* && ! "$template" =~ ^[a-zA-Z]:/ ]]; then
        template="${temp_base%/}/${template}"
    fi

    template_base="${template##*/}"
    template_parent="${template%/*}"
    if [[ "$template_parent" =~ ^[a-zA-Z]:$ ]]; then
        template_parent="${template_parent}/"
    fi
    if [[ -z "$template_base" || "$template_base" == "." || "$template_base" == ".." ]]; then
        return 1
    fi
    if [[ ! -d "$template_parent" ]]; then
        return 1
    fi

    link_status=0
    _gitsetu_path_has_symlink_component "$template_parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    if declare -f canonicalize_path >/dev/null 2>&1; then
        canonical_parent=$(canonicalize_path "$template_parent") || return 1
    else
        link_status=0
        _gitsetu_path_has_symlink_component "$template_parent" || link_status=$?
        [[ "$link_status" -eq 1 ]] || return 1
        canonical_parent="$template_parent"
    fi
    if [[ ! -d "$canonical_parent" || -L "$canonical_parent" ]]; then
        return 1
    fi
    link_status=0
    _gitsetu_path_has_symlink_component "$canonical_parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    template="${canonical_parent%/}/${template_base}"
    printf '%s' "$template"
}

_gitsetu_default_secure_template() {
    local base="${TMPDIR:-/tmp}"
    if declare -f canonicalize_path >/dev/null 2>&1; then
        base=$(canonicalize_path "$base") || return 1
    fi
    printf '%s/gitsetu.XXXXXX' "${base%/}"
}

secure_mktemp() {
    GITSETU_TMP_FILE=""
    if [[ $# -gt 1 ]]; then
        return 1
    fi

    local default_template template
    default_template=$(_gitsetu_default_secure_template) || return 1
    template=$(_gitsetu_secure_temp_template "${1:-$default_template}") || return 1
    local tmp_file
    tmp_file=$(umask 077 && mktemp "$template" 2>/dev/null) || return 1
    tmp_file=${tmp_file%$'\r'}

    if [[ -z "$tmp_file" || ! -f "$tmp_file" || -L "$tmp_file" || ! -O "$tmp_file" ]]; then
        _gitsetu_remove_owned_file "$tmp_file" 2>/dev/null || true
        return 1
    fi
    if ! chmod 600 "$tmp_file" 2>/dev/null; then
        _gitsetu_remove_owned_file "$tmp_file" 2>/dev/null || true
        return 1
    fi

    GITSETU_TMP_FILE="$tmp_file"
    GITSETU_CLEANUP_FILES+=("$tmp_file")
    printf '%s\n' "$tmp_file"
}

secure_mktemp_dir() {
    GITSETU_TMP_DIR=""
    if [[ $# -gt 1 ]]; then
        return 1
    fi

    local default_template template
    default_template=$(_gitsetu_default_secure_template) || return 1
    template=$(_gitsetu_secure_temp_template "${1:-$default_template}") || return 1
    local tmp_dir
    tmp_dir=$(umask 077 && mktemp -d "$template" 2>/dev/null) || return 1
    tmp_dir=${tmp_dir%$'\r'}

    if [[ -z "$tmp_dir" || ! -d "$tmp_dir" || -L "$tmp_dir" || ! -O "$tmp_dir" ]]; then
        rmdir "$tmp_dir" 2>/dev/null || true
        return 1
    fi
    if ! chmod 700 "$tmp_dir" 2>/dev/null ||
       ! _gitsetu_private_directory "$tmp_dir"; then
        rmdir "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    GITSETU_TMP_DIR="$tmp_dir"
    GITSETU_CLEANUP_DIRS+=("$tmp_dir")
    printf '%s\n' "$tmp_dir"
}

# secure_mkdir creates one new private directory. It never changes an existing
# directory's permissions, which avoids unexpectedly weakening a user path.
secure_mkdir() {
    GITSETU_PRIVATE_DIR=""
    if [[ $# -ne 1 ]] || [[ -z "$1" || "$1" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    local dir="$1"
    local base="${dir##*/}"
    local parent="${dir%/*}"
    local canonical_parent link_status=0
    case "$dir" in
        /*|[a-zA-Z]:/*) ;;
        *) return 1 ;;
    esac
    [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || return 1
    [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
    [[ -d "$parent" ]] || return 1
    _gitsetu_path_has_symlink_component "$parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    if declare -f canonicalize_path >/dev/null 2>&1; then
        canonical_parent=$(canonicalize_path "$parent") || return 1
    else
        canonical_parent="$parent"
    fi
    _gitsetu_path_has_symlink_component "$canonical_parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    dir="${canonical_parent%/}/${base}"
    if [[ -e "$dir" || -L "$dir" ]]; then
        return 1
    fi
    (umask 077 && mkdir -m 700 "$dir") 2>/dev/null || return 1
    if [[ ! -d "$dir" || -L "$dir" || ! -O "$dir" ]]; then
        rmdir "$dir" 2>/dev/null || true
        return 1
    fi
    chmod 700 "$dir" 2>/dev/null || { rmdir "$dir" 2>/dev/null || true; return 1; }
    _gitsetu_private_directory "$dir" || { rmdir "$dir" 2>/dev/null || true; return 1; }
    GITSETU_PRIVATE_DIR="$dir"
    printf '%s\n' "$dir"
}

_gitsetu_private_directory() {
    [[ $# -eq 1 ]] || return 1
    local path="$1"
    [[ -d "$path" && ! -L "$path" && -O "$path" ]] || return 1
    local reparse_status=0
    if _gitsetu_is_reparse_point_uncached "$path"; then
        return 1
    else
        reparse_status=$?
    fi
    [[ "$reparse_status" -eq 1 ]] || return 1

    # Git for Windows chmod/stat do not expose POSIX mode bits reliably; the
    # private directory created by mktemp inherits the current user's ACL.
    if [[ -z "${GITSETU_OS:-}" ]] && declare -f detect_os >/dev/null 2>&1; then
        detect_os
    fi
    if [[ "${GITSETU_OS:-}" == "gitbash" ]]; then
        return 0
    fi

    local mode permissions
    mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions="${mode#"${mode%???}"}"
    [[ "${permissions:1:2}" == "00" ]]
}

_gitsetu_remove_owned_tree_entry() {
    [[ $# -eq 1 ]] || return 1
    local entry="$1"
    local reparse_status=0

    if _gitsetu_is_reparse_point_uncached "$entry"; then
        # unlinking a symlink/junction removes the directory entry itself and
        # never traverses its target.
        rm -f "$entry" 2>/dev/null
        return
    else
        reparse_status=$?
    fi
    [[ "$reparse_status" -eq 1 ]] || return 1
    if [[ -d "$entry" ]]; then
        [[ -O "$entry" ]] || return 1
        _gitsetu_remove_private_directory "$entry" || return 1
        return
    fi
    if [[ -f "$entry" ]]; then
        [[ -O "$entry" ]] || return 1
        rm -f "$entry" 2>/dev/null
        return
    fi
    return 1
}

_gitsetu_remove_owned_file() {
    [[ $# -eq 1 ]] || return 1
    local path="$1"
    local parent="${path%/*}"
    local link_status=0
    [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
    [[ -f "$path" && ! -L "$path" && -O "$path" ]] || return 1
    local reparse_status=0
    if _gitsetu_is_reparse_point_uncached "$path"; then
        return 1
    else
        reparse_status=$?
    fi
    [[ "$reparse_status" -eq 1 ]] || return 1
    _gitsetu_path_has_symlink_component "$parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    rm -f "$path" 2>/dev/null
}

_gitsetu_remove_private_directory() {
    [[ $# -eq 1 ]] || return 1
    local path="$1"
    case "$path" in /|.|..|//|[a-zA-Z]:/) return 1 ;; esac
    local parent="${path%/*}"
    local link_status=0
    [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
    _gitsetu_private_directory "$path" || return 1
    _gitsetu_path_has_symlink_component "$parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1

    local entry
    for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        _gitsetu_remove_owned_tree_entry "$entry" || return 1
    done
    rmdir "$path" 2>/dev/null
}

track_temp_file() {
    if [[ $# -ne 1 || -z "$1" || "$1" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    case "$1" in
        /|.|..|//|[a-zA-Z]:/) return 1 ;;
        /*|[a-zA-Z]:/*) ;;
        *) return 1 ;;
    esac
    local parent="${1%/*}"
    local link_status=0
    [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
    [[ -f "$1" && ! -L "$1" && -O "$1" ]] || return 1
    _gitsetu_path_has_symlink_component "$parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    if declare -f canonicalize_path >/dev/null 2>&1; then
        parent=$(canonicalize_path "$parent") || return 1
        [[ "$parent" == "${1%/*}" || ( "${1%/*}" =~ ^[a-zA-Z]:$ && "$parent" == "${1%/*}/" ) ]] || return 1
    fi
    GITSETU_CLEANUP_FILES+=("$1")
}

track_temp_dir() {
    if [[ $# -ne 1 || -z "$1" || "$1" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    case "$1" in
        /|.|..|//|[a-zA-Z]:/) return 1 ;;
        /*|[a-zA-Z]:/*) ;;
        *) return 1 ;;
    esac
    local parent="${1%/*}"
    local link_status=0
    [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
    _gitsetu_private_directory "$1" || return 1
    _gitsetu_path_has_symlink_component "$parent" || link_status=$?
    [[ "$link_status" -eq 1 ]] || return 1
    GITSETU_CLEANUP_DIRS+=("$1")
}

cleanup_temp_resources() {
    local path parent status=0 link_status reparse_status
    for path in "${GITSETU_CLEANUP_FILES[@]+"${GITSETU_CLEANUP_FILES[@]}"}"; do
        [[ -n "$path" ]] || continue
        case "$path" in /|.|..|//|[a-zA-Z]:/) status=1; continue ;; esac
        [[ -e "$path" || -L "$path" ]] || continue
        parent="${path%/*}"
        [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
        link_status=0
        if [[ ! -f "$path" || -L "$path" || ! -O "$path" ]]; then
            status=1
            continue
        fi
        reparse_status=0
        if _gitsetu_is_reparse_point_uncached "$path"; then
            status=1
            continue
        else
            reparse_status=$?
        fi
        if [[ "$reparse_status" -ne 1 ]]; then
            status=1
            continue
        fi
        _gitsetu_path_has_symlink_component "$parent" || link_status=$?
        if [[ "$link_status" -ne 1 ]]; then
            status=1
            continue
        fi
        rm -f "$path" 2>/dev/null || status=1
    done
    for path in "${GITSETU_CLEANUP_DIRS[@]+"${GITSETU_CLEANUP_DIRS[@]}"}"; do
        [[ -n "$path" ]] || continue
        case "$path" in /|.|..|//|[a-zA-Z]:/) status=1; continue ;; esac
        [[ -e "$path" || -L "$path" ]] || continue
        parent="${path%/*}"
        [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
        link_status=0
        _gitsetu_path_has_symlink_component "$parent" || link_status=$?
        if [[ "$link_status" -ne 1 ]] ||
           ! _gitsetu_remove_private_directory "$path"; then
            status=1
        fi
    done
    GITSETU_CLEANUP_FILES=()
    GITSETU_CLEANUP_DIRS=()
    GITSETU_TMP_FILE=""
    GITSETU_TMP_DIR=""
    GITSETU_PRIVATE_DIR=""
    return "$status"
}

# ------------------------------------------------------------------------------
# v2 registry field encoding
#
# Every byte is encoded as an uppercase %HH token. This deliberately leaves no
# raw tabs, newlines, percent signs, backslashes, colons, or other controls in a
# field. Records are therefore exactly six encoded fields joined by five ':'.
# NUL is not representable because Bash strings cannot contain NUL safely.
# ------------------------------------------------------------------------------
escape_registry_field() {
    if [[ $# -ne 1 ]]; then
        return 1
    fi

    local value="$1"
    local LC_ALL=C
    local output=""
    local char hex
    local i
    if [[ ${#value} -gt 4096 ]]; then
        return 1
    fi
    for (( i=0; i<${#value}; i++ )); do
        char="${value:i:1}"
        printf -v hex '%02X' "'$char"
        output="${output}%${hex}"
    done
    printf '%s' "$output"
}

unescape_registry_field() {
    if [[ $# -ne 1 ]]; then
        return 1
    fi

    local encoded="$1"
    if [[ -z "$encoded" ]]; then
        return 0
    fi
    if [[ ${#encoded} -gt "$_GITSETU_REGISTRY_MAX_FIELD_LENGTH" ||
          ! "$encoded" =~ ^%[0-9A-F]{2}(%[0-9A-F]{2})*$ ]]; then
        return 1
    fi
    if [[ "$encoded" == *"%00"* ]]; then
        return 1
    fi

    local LC_ALL=C
    local decoded=""
    local hex octal char
    local code
    local i
    for (( i=1; i<${#encoded}; i+=3 )); do
        hex="${encoded:i:2}"
        code=$((16#$hex))
        printf -v octal '%03o' "$code"
        printf -v char '\\%s' "$octal"
        decoded="${decoded}${char}"
    done
    printf '%b' "$decoded"
}

encode_registry_field() {
    escape_registry_field "$@"
}
decode_registry_field() {
    unescape_registry_field "$@"
}

# Command substitution strips trailing newlines. This internal form appends a
# removable sentinel so strict semantic validators still see those newlines.
_unescape_registry_field_preserve_newlines() {
    unescape_registry_field "$1" || return 1
    printf 'x'
}


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
# Strict v2 registry helpers
# ------------------------------------------------------------------------------
_gitsetu_registry_error() {
    GITSETU_REGISTRY_ERROR="$1"
    printf 'gitsetu: %s\n' "$1" >&2
    return 0
}

_clear_profile_state() {
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
}

# Registry writes are intentionally not a general "write anywhere" API. The
# destination must be the active canonical config file, its parent must already
# exist without symlink/reparse redirection, and an existing target must be a
# regular non-symlink file. Read-only archive/custom destinations use load only.
_gitsetu_validate_registry_write_destination() {
    local registry="$1"
    local config_root="${GITSETU_CONFIG_DIR:-}"
    local expected="${config_root%/}/profiles.conf"
    local parent canonical_config canonical_parent canonical_registry
    local link_status=0 reparse_status

    if [[ -z "$registry" || "$registry" =~ [[:cntrl:]] ]]; then
        _gitsetu_registry_error "registry destination is invalid"
        return 1
    fi
    if [[ "$registry" != "${GITSETU_PROFILES_CONF:-}" ]] ||
       [[ "$config_root" != "${_gitsetu_registry_write_root:-}" ]] ||
       [[ "$registry" != "${_gitsetu_registry_write_conf:-}" ]] ||
       [[ "$registry" != "$expected" ]]; then
        _gitsetu_registry_error "registry writes are restricted to the canonical config root"
        return 1
    fi
    case "$registry" in
        /*|[a-zA-Z]:/*) ;;
        *)
            _gitsetu_registry_error "registry destination must be absolute"
            return 1
            ;;
    esac
    if ! declare -f canonicalize_path >/dev/null 2>&1; then
        _gitsetu_registry_error "canonical path resolution is unavailable"
        return 1
    fi

    parent="${registry%/*}"
    [[ "$parent" =~ ^[a-zA-Z]:$ ]] && parent="${parent}/"
    if [[ "${parent##*/}" != "gitsetu" || "$parent" == "/" || "$parent" =~ ^[a-zA-Z]:/$ ]]; then
        _gitsetu_registry_error "registry config root has an unsafe name"
        return 1
    fi
    if [[ ! -d "$parent" || -L "$parent" || ! -O "$parent" ]]; then
        _gitsetu_registry_error "registry config root is missing or redirected"
        return 1
    fi
    _gitsetu_path_has_symlink_component "$parent" || link_status=$?
    if [[ "$link_status" -ne 1 ]]; then
        _gitsetu_registry_error "registry config root contains a symlink or reparse component"
        return 1
    fi
    reparse_status=0
    if _gitsetu_is_reparse_point_uncached "$parent"; then
        _gitsetu_registry_error "registry config root is a reparse point"
        return 1
    else
        reparse_status=$?
    fi
    if [[ "$reparse_status" -ne 1 ]]; then
        _gitsetu_registry_error "registry reparse detection was indeterminate"
        return 1
    fi

    canonical_config=$(canonicalize_path "$config_root") || return 1
    canonical_parent=$(canonicalize_path "$parent") || return 1
    canonical_registry=$(canonicalize_path "$registry") || return 1
    if [[ "$canonical_config" != "$config_root" ||
          "$canonical_parent" != "$parent" ||
          "$canonical_registry" != "$registry" ]]; then
        _gitsetu_registry_error "registry destination is not canonical"
        return 1
    fi

    if [[ -e "$registry" || -L "$registry" ]]; then
        if [[ -L "$registry" ]] || [[ ! -f "$registry" ]]; then
            _gitsetu_registry_error "existing registry destination is not a safe regular file"
            return 1
        fi
        reparse_status=0
        if _gitsetu_is_reparse_point_uncached "$registry"; then
            _gitsetu_registry_error "existing registry destination is a reparse point"
            return 1
        else
            reparse_status=$?
        fi
        if [[ "$reparse_status" -ne 1 ]]; then
            _gitsetu_registry_error "registry reparse detection was indeterminate"
            return 1
        fi
        [[ -O "$registry" ]] || {
            _gitsetu_registry_error "existing registry destination is not owned by this user"
            return 1
        }
    fi
    return 0
}

# write_profiles_registry atomically writes the six-field v2 registry.
# Field order: label, directory, provider, sign_commits, key_path, provider_user.
# Email and display name intentionally remain sourced only from profile gitconfig.
write_profiles_registry() {
    GITSETU_REGISTRY_ERROR=""
    if [[ $# -gt 1 ]]; then
        _gitsetu_registry_error "invalid registry writer arguments"
        return 1
    fi

    local registry="${1:-${GITSETU_PROFILES_CONF:-}}"
    if ! declare -f validate_profile_record >/dev/null 2>&1 ||
       ! declare -f validate_nonnegative_integer >/dev/null 2>&1; then
        _gitsetu_registry_error "registry validators are unavailable"
        return 1
    fi
    if ! _gitsetu_validate_registry_write_destination "$registry"; then
        return 1
    fi
    local registry_parent="${registry%/*}"
    if [[ "$registry_parent" =~ ^[a-zA-Z]:$ ]]; then
        registry_parent="${registry_parent}/"
    fi

    local count_text="${PROFILE_COUNT:-0}"
    validate_nonnegative_integer "$count_text" ||
        { _gitsetu_registry_error "invalid profile count"; return 1; }
    validate_bounded_uint "$count_text" 0 "$_GITSETU_REGISTRY_MAX_PROFILES" ||
        { _gitsetu_registry_error "profile count exceeds registry limit"; return 1; }
    local count="$count_text"

    local labels_len=${#PROFILE_LABELS[@]}
    local names_len=${#PROFILE_NAMES[@]}
    local emails_len=${#PROFILE_EMAILS[@]}
    local dirs_len=${#PROFILE_DIRS[@]}
    local providers_len=${#PROFILE_PROVIDERS[@]}
    local signs_len=${#PROFILE_SIGNS[@]}
    local keys_len=${#PROFILE_KEYS[@]}
    local users_len=${#PROFILE_USERS[@]}
    if [[ "$labels_len" -ne "$count" || "$names_len" -ne "$count" ||
          "$emails_len" -ne "$count" || "$dirs_len" -ne "$count" ||
          "$providers_len" -ne "$count" || "$signs_len" -ne "$count" ||
          "$keys_len" -ne "$count" || "$users_len" -ne "$count" ]]; then
        _gitsetu_registry_error "profile arrays do not match profile count"
        return 1
    fi

    local i j
    local label directory provider sign_commits key_path provider_user
    local encoded_label encoded_directory encoded_provider encoded_sign
    local encoded_key encoded_user
    local encoded_labels=()
    local encoded_directories=()
    local encoded_providers=()
    local encoded_signs=()
    local encoded_keys=()
    local encoded_users=()
    if [[ "$count" -gt 0 && "${PROFILE_LABELS[0]}" != "global" ]]; then
        _gitsetu_registry_error "the first v2 profile must be global"
        return 1
    fi

    for (( i=0; i<count; i++ )); do
        label="${PROFILE_LABELS[$i]}"
        directory="${PROFILE_DIRS[$i]}"
        provider="${PROFILE_PROVIDERS[$i]}"
        sign_commits="${PROFILE_SIGNS[$i]}"
        key_path="${PROFILE_KEYS[$i]}"
        provider_user="${PROFILE_USERS[$i]}"

        if ! validate_user_name "${PROFILE_NAMES[$i]}" ||
           ! validate_email "${PROFILE_EMAILS[$i]}"; then
            _gitsetu_registry_error "profile identity at index ${i} failed strict validation"
            return 1
        fi
        if ! validate_profile_record "$label" "$directory" "$provider" \
            "$sign_commits" "$key_path" "$provider_user"; then
            _gitsetu_registry_error "profile at index ${i} failed strict validation"
            return 1
        fi
        for (( j=0; j<i; j++ )); do
            if [[ "$label" == "${PROFILE_LABELS[$j]}" ]]; then
                _gitsetu_registry_error "duplicate profile label: ${label}"
                return 1
            fi
        done

        encoded_label=$(escape_registry_field "$label") || return 1
        encoded_directory=$(escape_registry_field "$directory") || return 1
        encoded_provider=$(escape_registry_field "$provider") || return 1
        encoded_sign=$(escape_registry_field "$sign_commits") || return 1
        encoded_key=$(escape_registry_field "$key_path") || return 1
        encoded_user=$(escape_registry_field "$provider_user") || return 1
        if ! validate_registry_field "$encoded_label" ||
           ! validate_registry_field "$encoded_directory" ||
           ! validate_registry_field "$encoded_provider" ||
           ! validate_registry_field "$encoded_sign" ||
           ! validate_registry_field "$encoded_key" ||
           ! validate_registry_field "$encoded_user"; then
            _gitsetu_registry_error "profile at index ${i} could not be encoded canonically"
            return 1
        fi

        encoded_labels+=("$encoded_label")
        encoded_directories+=("$encoded_directory")
        encoded_providers+=("$encoded_provider")
        encoded_signs+=("$encoded_sign")
        encoded_keys+=("$encoded_key")
        encoded_users+=("$encoded_user")
    done

    if [[ "${GITSETU_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    local tmp_file reparse_status
    if ! secure_mktemp "${registry}.tmp.XXXXXX" >/dev/null; then
        _gitsetu_registry_error "could not create a secure registry temporary file"
        return 1
    fi
    tmp_file="$GITSETU_TMP_FILE"
    local tmp_parent="${tmp_file%/*}"
    if [[ ! -f "$tmp_file" || -L "$tmp_file" || ! -O "$tmp_file" ||
          "$tmp_parent" != "$registry_parent" ]]; then
        _gitsetu_remove_owned_file "$tmp_file" 2>/dev/null || true
        _gitsetu_registry_error "secure registry temporary file failed validation"
        return 1
    fi

    if ! {
        printf '%s\n' "$_GITSETU_REGISTRY_HEADER"
        for (( i=0; i<count; i++ )); do
            printf '%s:%s:%s:%s:%s:%s\n' \
                "${encoded_labels[$i]}" "${encoded_directories[$i]}" \
                "${encoded_providers[$i]}" "${encoded_signs[$i]}" \
                "${encoded_keys[$i]}" "${encoded_users[$i]}"
        done
    } > "$tmp_file"; then
        _gitsetu_remove_owned_file "$tmp_file" 2>/dev/null || true
        _gitsetu_registry_error "could not write the v2 registry"
        return 1
    fi

    if ! _gitsetu_validate_registry_write_destination "$registry"; then
        _gitsetu_remove_owned_file "$tmp_file" 2>/dev/null || true
        return 1
    fi
    if ! mv -f "$tmp_file" "$registry" 2>/dev/null; then
        _gitsetu_remove_owned_file "$tmp_file" 2>/dev/null || true
        _gitsetu_registry_error "could not atomically install the v2 registry"
        return 1
    fi
    if [[ ! -f "$registry" || -L "$registry" || ! -O "$registry" ]]; then
        _gitsetu_registry_error "installed registry failed final safety validation"
        return 1
    fi
    reparse_status=0
    if _gitsetu_is_reparse_point_uncached "$registry"; then
        _gitsetu_registry_error "installed registry is a reparse point"
        return 1
    else
        reparse_status=$?
    fi
    if [[ "$reparse_status" -ne 1 ]]; then
        _gitsetu_registry_error "installed registry reparse detection was indeterminate"
        return 1
    fi
    return 0
}

write_profile_registry() {
    write_profiles_registry "$@"
}

# load_profiles accepts only the exact v2 header and strict six-field records.
# Any legacy, unversioned, partially escaped, malformed, or mixed file is an error.
load_profiles() {
    _clear_profile_state
    GITSETU_REGISTRY_ERROR=""

    local registry="${1:-${GITSETU_PROFILES_CONF:-}}"
    case "$registry" in
        /*|[a-zA-Z]:/*) ;;
        *) _gitsetu_registry_error "registry path must be absolute"; return 1 ;;
    esac
    if [[ ! -e "$registry" ]]; then
        return 0
    fi
    if [[ ! -f "$registry" || -L "$registry" || ! -r "$registry" ]]; then
        _gitsetu_registry_error "registry is not a readable, non-symlink regular file"
        return 1
    fi
    if ! declare -f validate_profile_record >/dev/null 2>&1 ||
       ! declare -f validate_registry_line >/dev/null 2>&1; then
        _gitsetu_registry_error "registry validators are unavailable"
        return 1
    fi

    local labels=()
    local names=()
    local emails=()
    local directories=()
    local providers=()
    local signs=()
    local keys=()
    local users=()
    local line_number=0
    local raw_line header_seen=0
    local encoded_label encoded_directory encoded_provider encoded_sign
    local encoded_key encoded_user
    local label directory provider sign_commits key_path provider_user
    local profile_path loaded_name loaded_email
    local i j

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line_number=$((line_number + 1))
        if [[ "${#raw_line}" -gt "$_GITSETU_REGISTRY_MAX_LINE_LENGTH" ]]; then
            _gitsetu_registry_error "registry line ${line_number} exceeds the size limit"
            return 1
        fi

        if [[ "$line_number" -eq 1 ]]; then
            if [[ "$raw_line" != "$_GITSETU_REGISTRY_HEADER" ]]; then
                _gitsetu_registry_error "unsupported or legacy registry format"
                return 1
            fi
            header_seen=1
            continue
        fi
        if [[ -z "$raw_line" || "$raw_line" == "#"* ]]; then
            _gitsetu_registry_error "blank and comment records are not allowed in v2"
            return 1
        fi

        if ! validate_registry_line "$raw_line"; then
            _gitsetu_registry_error "registry line ${line_number} has an invalid six-field envelope"
            return 1
        fi
        IFS=: read -r encoded_label encoded_directory encoded_provider \
            encoded_sign encoded_key encoded_user <<< "$raw_line"

        # The sentinel prevents Bash command substitution from stripping
        # decoded trailing newlines before semantic validation can reject them.
        label=$(_unescape_registry_field_preserve_newlines "$encoded_label") || return 1
        directory=$(_unescape_registry_field_preserve_newlines "$encoded_directory") || return 1
        provider=$(_unescape_registry_field_preserve_newlines "$encoded_provider") || return 1
        sign_commits=$(_unescape_registry_field_preserve_newlines "$encoded_sign") || return 1
        key_path=$(_unescape_registry_field_preserve_newlines "$encoded_key") || return 1
        provider_user=$(_unescape_registry_field_preserve_newlines "$encoded_user") || return 1
        label=${label%x}
        directory=${directory%x}
        provider=${provider%x}
        sign_commits=${sign_commits%x}
        key_path=${key_path%x}
        provider_user=${provider_user%x}

        if ! validate_profile_record "$label" "$directory" "$provider" \
            "$sign_commits" "$key_path" "$provider_user"; then
            _gitsetu_registry_error "registry line ${line_number} failed strict field validation"
            return 1
        fi
        if [[ "${#labels[@]}" -eq 0 && "$label" != "global" ]]; then
            _gitsetu_registry_error "the first v2 profile must be global"
            return 1
        fi
        for (( j=0; j<${#labels[@]}; j++ )); do
            if [[ "$label" == "${labels[$j]}" ]]; then
                _gitsetu_registry_error "duplicate profile label on registry line ${line_number}"
                return 1
            fi
        done

        profile_path="${GITSETU_PROFILES_DIR:-${GITSETU_CONFIG_DIR:-${HOME:-}/.config/gitsetu}/profiles}/${label}.gitconfig"
        if [[ ! -f "$profile_path" || -L "$profile_path" ]]; then
            _gitsetu_registry_error "profile gitconfig is missing or unsafe for ${label}"
            return 1
        fi
        loaded_name=$(git config -f "$profile_path" --get user.name 2>/dev/null) || loaded_name=""
        loaded_email=$(git config -f "$profile_path" --get user.email 2>/dev/null) || loaded_email=""
        if ! validate_user_name "$loaded_name" || ! validate_email "$loaded_email"; then
            _gitsetu_registry_error "profile gitconfig identity is invalid for ${label}"
            return 1
        fi

        labels+=("$label")
        names+=("$loaded_name")
        emails+=("$loaded_email")
        directories+=("$directory")
        providers+=("$provider")
        signs+=("$sign_commits")
        keys+=("$key_path")
        users+=("$provider_user")
        if [[ "${#labels[@]}" -gt "$_GITSETU_REGISTRY_MAX_PROFILES" ]]; then
            _gitsetu_registry_error "registry exceeds the profile limit"
            return 1
        fi
    done < "$registry"

    if [[ "$header_seen" -ne 1 ]]; then
        _gitsetu_registry_error "registry header is missing"
        return 1
    fi

    PROFILE_LABELS=("${labels[@]+"${labels[@]}"}")
    PROFILE_NAMES=("${names[@]+"${names[@]}"}")
    PROFILE_EMAILS=("${emails[@]+"${emails[@]}"}")
    PROFILE_DIRS=("${directories[@]+"${directories[@]}"}")
    PROFILE_PROVIDERS=("${providers[@]+"${providers[@]}"}")
    PROFILE_SIGNS=("${signs[@]+"${signs[@]}"}")
    PROFILE_KEYS=("${keys[@]+"${keys[@]}"}")
    PROFILE_USERS=("${users[@]+"${users[@]}"}")
    PROFILE_PATS=()
    PROFILE_COUNT=${#PROFILE_LABELS[@]}
    return 0
}

load_profile_registry() {
    load_profiles "$@"
}
GITSETU_SCRIPT_DIR="${GITSETU_SCRIPT_DIR:-}"   # Preserve value set by main script
GITSETU_DIR="${GITSETU_DIR:-${GITSETU_SCRIPT_DIR:-}}"
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
    local target_idx="${1:-}"
    local profile_count="${PROFILE_COUNT:-0}"

    if ! validate_nonnegative_integer "$profile_count" ||
       ! validate_array_index "$target_idx" "$profile_count"; then
        return 1
    fi
    # Index zero is the mandatory v2 global profile. Removing it would make the
    # in-memory profile set unwritable under the strict registry contract.
    if [[ "$target_idx" == "0" ]]; then
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
    for (( i=0; i<profile_count; i++ )); do
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
    
    PROFILE_LABELS=("${new_labels[@]+"${new_labels[@]}"}")
    PROFILE_NAMES=("${new_names[@]+"${new_names[@]}"}")
    PROFILE_EMAILS=("${new_emails[@]+"${new_emails[@]}"}")
    PROFILE_DIRS=("${new_dirs[@]+"${new_dirs[@]}"}")
    PROFILE_PROVIDERS=("${new_providers[@]+"${new_providers[@]}"}")
    PROFILE_SIGNS=("${new_signs[@]+"${new_signs[@]}"}")
    PROFILE_KEYS=("${new_keys[@]+"${new_keys[@]}"}")
    PROFILE_USERS=("${new_users[@]+"${new_users[@]}"}")
    PROFILE_PATS=("${new_pats[@]+"${new_pats[@]}"}")
    
    PROFILE_COUNT=$((profile_count - 1))
    return 0
}
