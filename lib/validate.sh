#!/usr/bin/env bash
# lib/validate.sh — Strict input and v2 registry field validation
#
# All validators return 0 for valid and 1 for invalid.
# Untrusted values are checked lexically before any arithmetic expansion or
# integer comparison. Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# Safe integer validation
# ------------------------------------------------------------------------------

# Only canonical non-negative decimal integers are accepted. In particular,
# leading-zero values such as 08 are rejected because both $((08 + 0)) and
# [[ "08" -eq 0 ]] can fail or be interpreted as octal on Bash builds.
validate_nonnegative_integer() {
    [[ $# -eq 1 ]] || return 1
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

validate_uint() {
    validate_nonnegative_integer "$@"
}

validate_positive_integer() {
    [[ $# -eq 1 ]] || return 1
    validate_nonnegative_integer "$1" || return 1
    [[ "$1" != "0" ]]
}

validate_integer() {
    [[ $# -eq 1 ]] || return 1
    [[ "$1" =~ ^(0|-?[1-9][0-9]*)$ ]]
}

# Compare already-validated canonical decimal strings without expanding either
# operand in an arithmetic context.
_gitsetu_uint_lte() {
    [[ $# -eq 2 ]] || return 1
    local left="$1"
    local right="$2"
    local LC_ALL=C

    if [[ "${#left}" -lt "${#right}" ]]; then
        return 0
    fi
    if [[ "${#left}" -gt "${#right}" ]]; then
        return 1
    fi
    [[ "$left" < "$right" || "$left" == "$right" ]]
}

validate_bounded_uint() {
    [[ $# -eq 3 ]] || return 1
    validate_nonnegative_integer "$1" || return 1
    validate_nonnegative_integer "$2" || return 1
    validate_nonnegative_integer "$3" || return 1
    _gitsetu_uint_lte "$2" "$1" || return 1
    _gitsetu_uint_lte "$1" "$3"
}

validate_uint_range() {
    validate_bounded_uint "$@"
}

# Return the decimal predecessor of a validated positive integer without using
# that integer as an arithmetic expression.
_gitsetu_uint_predecessor() {
    [[ $# -eq 1 ]] || return 1
    validate_positive_integer "$1" || return 1

    local value="$1"
    local result="" digit carry=1
    local i
    for (( i=${#value}-1; i>=0; i-- )); do
        digit="${value:i:1}"
        if [[ "$carry" -eq 1 ]]; then
            case "$digit" in
                0) digit=9 ;;
                1) digit=0; carry=0 ;;
                2) digit=1; carry=0 ;;
                3) digit=2; carry=0 ;;
                4) digit=3; carry=0 ;;
                5) digit=4; carry=0 ;;
                6) digit=5; carry=0 ;;
                7) digit=6; carry=0 ;;
                8) digit=7; carry=0 ;;
                9) digit=8; carry=0 ;;
            esac
        fi
        result="${digit}${result}"
    done
    while [[ "${#result}" -gt 1 && "$result" == 0* ]]; do
        result="${result#0}"
    done
    printf '%s' "$result"
}

# Array indexes are zero based. A count of zero intentionally has no valid
# index, and target values are never fed to [[ -eq/-ge ]] or $(( )) until after
# lexical validation.
validate_array_index() {
    [[ $# -eq 2 ]] || return 1
    validate_nonnegative_integer "$1" || return 1
    validate_nonnegative_integer "$2" || return 1
    [[ "$2" != "0" ]] || return 1

    local last
    last=$(_gitsetu_uint_predecessor "$2") || return 1
    _gitsetu_uint_lte "$1" "$last"
}

# Predicate aliases retained for simple call sites.
is_valid_nonnegative_integer() { validate_nonnegative_integer "$@"; }
is_valid_integer() { validate_integer "$@"; }
is_valid_uint() { validate_nonnegative_integer "$@"; }
is_safe_uint() { validate_nonnegative_integer "$@"; }
is_safe_integer() { validate_integer "$@"; }
is_safe_arithmetic_integer() { validate_integer "$@"; }
is_safe_comparison_integer() { validate_integer "$@"; }
is_safe_arithmetic_uint() { validate_nonnegative_integer "$@"; }
is_safe_comparison_uint() { validate_nonnegative_integer "$@"; }
is_safe_test_uint() { validate_nonnegative_integer "$@"; }
validate_profile_index() { validate_array_index "$@"; }

# ------------------------------------------------------------------------------
# Versioned registry syntax
# ------------------------------------------------------------------------------
validate_registry_version() {
    [[ $# -eq 1 ]] || return 1
    validate_nonnegative_integer "$1" || return 1
    [[ "$1" == "2" ]]
}

validate_registry_header() {
    [[ $# -eq 1 ]] || return 1
    [[ "$1" == "${GITSETU_REGISTRY_HEADER:-# gitsetu-registry-v2}" ]]
}

# v2 fields are fully percent-encoded as uppercase %HH byte tokens. This check
# is intentionally separate from semantic field validation: a syntactically
# valid field may decode to a value later rejected by a profile field rule.
validate_registry_field() {
    [[ $# -eq 1 ]] || return 1
    if [[ -z "$1" ]]; then
        return 0
    fi
    [[ "${#1}" -le "${GITSETU_REGISTRY_MAX_FIELD_LENGTH:-12288}" ]] || return 1
    [[ "$1" != *"%00"* ]] || return 1
    [[ "$1" =~ ^%[0-9A-F]{2}(%[0-9A-F]{2})*$ ]] || return 1
    if declare -f unescape_registry_field >/dev/null 2>&1; then
        unescape_registry_field "$1" >/dev/null
    fi
}

# Validate one unversioned data line's exact six-field envelope. Header/version
# validation remains the caller's responsibility.
validate_registry_line() {
    [[ $# -eq 1 ]] || return 1
    local line="$1"
    [[ -n "$line" && "${#line}" -le "${GITSETU_REGISTRY_MAX_LINE_LENGTH:-131072}" ]] || return 1
    [[ "$line" != "${GITSETU_REGISTRY_HEADER:-# gitsetu-registry-v2}" ]] || return 1

    local tail="$line"
    local colons=0
    while [[ "$tail" == *:* ]]; do
        colons=$((colons + 1))
        tail="${tail#*:}"
    done
    [[ "$colons" -eq 5 ]] || return 1

    local field_1 field_2 field_3 field_4 field_5 field_6 extra
    IFS=: read -r field_1 field_2 field_3 field_4 field_5 field_6 extra <<< "$line"
    [[ -z "$extra" ]] || return 1
    validate_registry_field "$field_1" || return 1
    validate_registry_field "$field_2" || return 1
    validate_registry_field "$field_3" || return 1
    validate_registry_field "$field_4" || return 1
    validate_registry_field "$field_5" || return 1
    validate_registry_field "$field_6"
}

validate_registry_record_line() {
    validate_registry_line "$@"
}

# ------------------------------------------------------------------------------
# Email validation
# ------------------------------------------------------------------------------

# Conservative dot-atom validation. It is intentionally not a parser for RFC
# 5322 quoted local parts, comments, Unicode SMTPUTF8, or address literals.
validate_email() {
    [[ $# -eq 1 ]] || return 1
    local email="$1"

    [[ -n "$email" && "${#email}" -le 254 ]] || return 1
    _gitsetu_reject_ascii_controls "email" "$email" || return 1
    [[ ! "$email" =~ [[:space:]] ]] || return 1
    [[ "$email" == *"@"* ]] || return 1

    local local_part="${email%%@*}"
    local domain_part="${email#*@}"
    [[ "$domain_part" != *@* ]] || return 1
    [[ -n "$local_part" && "${#local_part}" -le 64 ]] || return 1
    [[ "$domain_part" == *.* && "${#domain_part}" -le 253 ]] || return 1
    [[ "$local_part" != .* && "$local_part" != *. && "$local_part" != *..* ]] || return 1
    [[ "$domain_part" != .* && "$domain_part" != *. && "$domain_part" != *..* ]] || return 1

    local atom_re='^[A-Za-z0-9!#$%&*/=?^_`{|}~+.-]+$'
    [[ "$local_part" =~ $atom_re ]] || return 1

    local rest="$domain_part"
    local label final_label
    local label_count=0
    while :; do
        if [[ "$rest" == *.* ]]; then
            label="${rest%%.*}"
            rest="${rest#*.}"
        else
            label="$rest"
            rest=""
        fi
        [[ "${#label}" -ge 1 && "${#label}" -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
        final_label="$label"
        label_count=$((label_count + 1))
        [[ -n "$rest" ]] || break
    done
    [[ "$label_count" -ge 2 ]] || return 1
    [[ "$final_label" =~ ^[A-Za-z]{2,63}$ ]]
}

validate_github_noreply_email() {
    [[ $# -eq 1 ]] || return 1
    validate_email "$1" || return 1
    local github_regex='^[0-9]+\+[a-zA-Z0-9_-]+@users\.noreply\.github\.com$'
    [[ "$1" =~ $github_regex ]]
}

# ------------------------------------------------------------------------------
# Profile labels, providers, flags, users, and names
# ------------------------------------------------------------------------------
validate_label() {
    [[ $# -eq 1 ]] || return 1
    local label="$1"
    [[ -n "$label" && "${#label}" -le 20 ]] || return 1
    _gitsetu_reject_ascii_controls "profile label" "$label" || return 1
    [[ "$label" =~ ^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$ ]]
}

validate_profile_label() {
    validate_label "$@"
}

validate_provider() {
    [[ $# -eq 1 ]] || return 1
    local provider="$1"
    [[ -n "$provider" && "${#provider}" -le 253 ]] || return 1
    [[ "$provider" == *.* ]] || return 1
    [[ "$provider" != .* && "$provider" != *. && "$provider" != *..* ]] || return 1
    _gitsetu_reject_ascii_controls "provider" "$provider" || return 1

    local rest="$provider"
    local part
    while :; do
        if [[ "$rest" == *.* ]]; then
            part="${rest%%.*}"
            rest="${rest#*.}"
        else
            part="$rest"
            rest=""
        fi
        [[ "${#part}" -ge 1 && "${#part}" -le 63 ]] || return 1
        [[ "$part" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
        [[ -n "$rest" ]] || break
    done
}

validate_provider_host() {
    validate_provider "$@"
}

validate_sign_flag() {
    [[ $# -eq 1 ]] || return 1
    [[ "$1" == "0" || "$1" == "1" ]]
}

validate_sign_commits() {
    validate_sign_flag "$@"
}

validate_provider_user() {
    [[ $# -eq 1 ]] || return 1
    local user="$1"
    [[ -z "$user" ]] && return 0
    [[ "${#user}" -le 128 ]] || return 1
    [[ "$user" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
    [[ "$user" != *. && "$user" != *- && "$user" != *..* ]]
}

validate_user_name() {
    [[ $# -eq 1 ]] || return 1
    local name="$1"
    [[ -n "$name" && "${#name}" -le 256 ]] || return 1
    _gitsetu_reject_ascii_controls "user name" "$name" || return 1
    [[ ! "$name" =~ ^[[:space:]] && ! "$name" =~ [[:space:]]$ ]]
}

# ------------------------------------------------------------------------------
# Path field validation
# ------------------------------------------------------------------------------
validate_absolute_path() {
    [[ $# -eq 1 ]] || return 1
    local path="$1"
    [[ -n "$path" ]] || return 1
    _gitsetu_reject_ascii_controls "path" "$path" || return 1
    # v2 persisted paths must already be canonical. Generic normalize_path
    # still resolves these forms for callers that need lexical normalization,
    # but a profile/key field must not smuggle separators or traversal through.
    case "$path" in
        *\\*|*//*|../*|*/../*|*/..|*/./*|*/.) return 1 ;;
    esac
    case "$path" in
        /*) ;;
        [a-zA-Z]:/*) ;;
        *) return 1 ;;
    esac
    if [[ "$path" =~ ^[a-zA-Z]:[^/]$ ]] || [[ "$path" =~ ^[a-zA-Z]:[^/][^/]*$ ]]; then
        return 1
    fi
    [[ "$path" != */ || "$path" == "/" || "$path" =~ ^[a-zA-Z]:/$ ]]
}

validate_canonical_path() {
    [[ $# -eq 1 ]] || return 1
    validate_absolute_path "$1" || return 1
    local normalized
    normalized=$(normalize_path "$1") || return 1
    [[ "$normalized" == "$1" ]]
}

validate_profile_directory() {
    [[ $# -ge 1 && $# -le 2 ]] || return 1
    local path="$1"
    local allow_empty="${2:-0}"
    if [[ -z "$path" ]]; then
        [[ "$allow_empty" == "1" ]]
        return
    fi
    validate_canonical_path "$path"
}

validate_directory_path() {
    validate_profile_directory "$@"
}

validate_key_path() {
    [[ $# -eq 1 ]] || return 1
    validate_canonical_path "$1" || return 1
    [[ ! -d "$1" ]]
}

# validate_path checks whether a canonical directory can be used now. Existing
# directories need not be writable (they may only need read access); a missing
# directory is valid only when its nearest existing ancestor is writable.
validate_path() {
    [[ $# -eq 1 ]] || return 1
    local path
    path=$(normalize_path "$1") || return 1
    [[ -n "$path" ]] || return 1

    if [[ -e "$path" ]]; then
        [[ -d "$path" ]]
        return
    fi

    local current="$path"
    local parent
    while [[ "$current" != "/" && "$current" != "." && ! "$current" =~ ^[a-zA-Z]:/$ ]]; do
        parent=$(dirname "$current") || return 1
        if [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
        if [[ -d "$current" ]]; then
            [[ -w "$current" ]]
            return
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# Complete v2 profile record (decoded fields)
# ------------------------------------------------------------------------------
validate_profile_record() {
    [[ $# -eq 6 ]] || return 1
    local label="$1"
    local directory="$2"
    local provider="$3"
    local sign_commits="$4"
    local key_path="$5"
    local provider_user="$6"

    validate_label "$label" || return 1
    validate_provider "$provider" || return 1
    validate_sign_flag "$sign_commits" || return 1
    validate_key_path "$key_path" || return 1
    validate_provider_user "$provider_user" || return 1

    if [[ "$label" == "global" ]]; then
        [[ -z "$directory" ]] || return 1
    else
        validate_profile_directory "$directory" 0 || return 1
    fi
}

validate_profile_fields() {
    validate_profile_record "$@"
}

# ------------------------------------------------------------------------------
# SSH key filename validation
# ------------------------------------------------------------------------------
validate_key_name() {
    [[ $# -eq 1 ]] || return 1
    local name="$1"
    [[ -n "$name" && "${#name}" -le 128 ]] || return 1
    _gitsetu_reject_ascii_controls "SSH key name" "$name" || return 1
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}
