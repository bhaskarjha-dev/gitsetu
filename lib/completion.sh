#!/usr/bin/env bash
# lib/completion.sh — Bash and Zsh completion for GitSetu
#
# Add one of the following to ~/.bashrc or ~/.zshrc:
#   source /path/to/gitsetu/lib/completion.sh

# Zsh initializes its completion system lazily. A guard keeps repeated sourcing
# from resetting an already configured completion database.
if [[ -n "${ZSH_VERSION-}" ]]; then
    if [[ -z "${GITSETU_COMPLETION_INITIALIZED:-}" ]]; then
        autoload -Uz compinit
        compinit -i
        autoload -Uz bashcompinit
        bashcompinit
        GITSETU_COMPLETION_INITIALIZED=1
    fi
fi

_gitsetu_completion_decode_field() {
    local encoded="${1:-}"
    [[ -z "$encoded" || "$encoded" =~ ^%[0-9A-F]{2}(%[0-9A-F]{2})*$ ]] || return 1
    [[ "$encoded" != *%00* ]] || return 1
    local decoded="" hex octal char i
    for (( i=1; i<${#encoded}; i+=3 )); do
        hex="${encoded:i:2}"
        printf -v octal '%03o' "$((16#$hex))"
        printf -v char '\\%s' "$octal"
        decoded="${decoded}${char}"
    done
    printf '%b' "$decoded"
}

_gitsetu_completion_labels() {
    local home="${HOME:-}"
    local conf_file="${XDG_CONFIG_HOME:-$home/.config}/gitsetu/profiles.conf"
    local raw_line encoded_label encoded_dir encoded_provider encoded_sign encoded_key encoded_user extra
    [[ -n "$home" ]] || return 0
    local label directory provider sign key_path provider_user seen_labels=""
    local line_number=0 header_seen=0

    [[ -f "$conf_file" && ! -L "$conf_file" ]] || return 0
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line_number=$((line_number + 1))
        if [[ "$line_number" -eq 1 ]]; then
            [[ "$raw_line" == "# gitsetu-registry-v2" ]] || return 1
            header_seen=1
            continue
        fi
        [[ "$header_seen" -eq 1 && -n "$raw_line" && "${#raw_line}" -le 131072 ]] || return 1
        IFS=: read -r encoded_label encoded_dir encoded_provider encoded_sign encoded_key encoded_user extra <<< "$raw_line"
        [[ -z "$extra" ]] || return 1
        _gitsetu_completion_decode_field "$encoded_label" >/dev/null || return 1
        _gitsetu_completion_decode_field "$encoded_dir" >/dev/null || return 1
        _gitsetu_completion_decode_field "$encoded_provider" >/dev/null || return 1
        _gitsetu_completion_decode_field "$encoded_sign" >/dev/null || return 1
        _gitsetu_completion_decode_field "$encoded_key" >/dev/null || return 1
        _gitsetu_completion_decode_field "$encoded_user" >/dev/null || return 1

        label=$(_gitsetu_completion_decode_field "$encoded_label") || return 1
        directory=$(_gitsetu_completion_decode_field "$encoded_dir") || return 1
        provider=$(_gitsetu_completion_decode_field "$encoded_provider") || return 1
        sign=$(_gitsetu_completion_decode_field "$encoded_sign") || return 1
        key_path=$(_gitsetu_completion_decode_field "$encoded_key") || return 1
        provider_user=$(_gitsetu_completion_decode_field "$encoded_user") || return 1
        if declare -f _gitsetu_contains_ascii_control >/dev/null 2>&1; then
            _gitsetu_contains_ascii_control "$label" && return 1
            _gitsetu_contains_ascii_control "$directory" && return 1
            _gitsetu_contains_ascii_control "$provider" && return 1
            _gitsetu_contains_ascii_control "$key_path" && return 1
            _gitsetu_contains_ascii_control "$provider_user" && return 1
        else
            [[ "$label" != *[[:cntrl:]]* && "$directory" != *[[:cntrl:]]* && \
               "$provider" != *[[:cntrl:]]* && "$key_path" != *[[:cntrl:]]* && \
               "$provider_user" != *[[:cntrl:]]* ]] || return 1
        fi
        [[ "$label" =~ ^[a-z][a-z0-9-]{0,19}$ && "$label" != *- ]] || return 1
        [[ "$provider" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$provider" == *.* && "$provider" != *..* ]] || return 1
        [[ "$sign" == "0" || "$sign" == "1" ]] || return 1
        [[ -n "$key_path" && ( "$key_path" == /* || "$key_path" =~ ^[A-Za-z]:/ ) ]] || return 1
        case "$key_path" in *\\*|*//*|*/../*|*/./*) return 1 ;; esac
        if [[ -n "$provider_user" ]]; then
            [[ "$provider_user" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$provider_user" != *. && \
               "$provider_user" != *- && "$provider_user" != *..* ]] || return 1
        fi
        if [[ "$label" == "global" ]]; then
            [[ -z "$directory" ]] || return 1
        else
            [[ -n "$directory" && ( "$directory" == /* || "$directory" =~ ^[A-Za-z]:/ ) ]] || return 1
            case "$directory" in *\\*|*//*|*/../*|*/./*) return 1 ;; esac
        fi
        case $'\n'"$seen_labels"$'\n' in
            *$'\n'"$label"$'\n'*) return 1 ;;
        esac
        seen_labels="${seen_labels}${label}"$'\n'
        printf '%s\n' "$label"
    done < "$conf_file"
    [[ "$header_seen" -eq 1 ]]
}

_gitsetu() {
    local cur prev command subcommand opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]:-}"
    prev="${COMP_WORDS[COMP_CWORD-1]:-}"
    command="${COMP_WORDS[1]:-}"
    subcommand="${COMP_WORDS[2]:-}"
    opts="setup init add remove status verify doctor run teardown guard profile backup restore credential prompt update --help --version -h -v"

    if [[ ${COMP_CWORD:-0} -eq 1 ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        return 0
    fi

    case "$command" in
        setup|init)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--auto --yes --dry-run" -- "$cur") )
            ;;
        profile)
            if [[ ${COMP_CWORD:-0} -eq 2 ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "add edit remove" -- "$cur") )
            else
                case "$subcommand" in
                    add)
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "--name= --email= --dir= --provider= --key= --fido2 --sign --no-sign" -- "$cur") )
                        ;;
                    edit|remove)
                        local profile_words="--force"
                        local labels
                        labels=$(_gitsetu_completion_labels) || labels=""
                        if [[ -n "$labels" ]]; then
                            profile_words="$profile_words $labels"
                        fi
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$profile_words" -- "$cur") )
                        ;;
                    *)
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "add edit remove" -- "$cur") )
                        ;;
                esac
            fi
            ;;
        run|remove)
            local labels
            labels=$(_gitsetu_completion_labels) || labels=""
            if [[ -n "$labels" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$labels" -- "$cur") )
            fi
            ;;
        add)
            # Positional fields are intentionally completed as filenames only
            # where the shell can provide them; no profile label is guessed.
            ;;
        guard)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--install --uninstall" -- "$cur") )
            ;;
        teardown)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--force --deep --dry-run" -- "$cur") )
            ;;
        doctor)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--repair --dry-run" -- "$cur") )
            ;;
        update)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--development --dev" -- "$cur") )
            ;;
        credential)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "get store erase" -- "$cur") )
            ;;
        backup|restore)
            # Let the shell's filename completion handle the optional path.
            COMPREPLY=()
            ;;
        *)
            COMPREPLY=()
            ;;
    esac

    return 0
}

# Do not replace a user's existing binding when this file is sourced repeatedly.
if ! complete -p gitsetu 2>/dev/null | grep -q '_gitsetu'; then
    complete -F _gitsetu gitsetu
fi
if ! complete -p git-setu 2>/dev/null | grep -q '_gitsetu'; then
    complete -F _gitsetu git-setu
fi
