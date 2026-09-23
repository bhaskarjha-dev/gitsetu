#!/usr/bin/env bash
# lib/completion.sh — Bash and Zsh autocompletion for GitSetu
#
# Usage:
# Add the following line to your ~/.bashrc or ~/.zshrc:
#   source /path/to/gitsetu/lib/completion.sh

# Enable bash completion compatibility in Zsh
if [[ -n "${ZSH_VERSION-}" ]]; then
    autoload -U +X compinit && compinit
    autoload -U +X bashcompinit && bashcompinit
fi

_gitsetu() {
    local cur prev opts profiles conf_file
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="setup init status verify run teardown guard add remove profile backup restore credential prompt doctor update --help --version"

    # Suggest subcommands if we are at the first argument
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        return 0
    fi

    # Read profiles dynamically
    conf_file="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu/profiles.conf"
    if [[ -f "$conf_file" ]]; then
        # Awk extracts the first field (label) of any line that doesn't start with '#' and is not empty
        profiles=$(awk -F: '!/^#/ && NF>0 {print $1}' "$conf_file" 2>/dev/null)
    fi

    # Subcommand specific completions
    case "${prev}" in
        run|remove|profile)
            # Suggest profile labels
            if [[ -n "$profiles" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "${profiles}" -- "${cur}") )
            fi
            ;;
        guard)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--install --uninstall" -- "${cur}") )
            ;;
        teardown)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--force --dry-run --deep" -- "${cur}") )
            ;;
        setup)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--dry-run --auto" -- "${cur}") )
            ;;
        doctor)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--repair --dry-run" -- "${cur}") )
            ;;
    esac
}

complete -F _gitsetu gitsetu
complete -F _gitsetu git-setu
