#!/usr/bin/env bash
# lib/platform.sh — OS detection, path normalization, and prerequisite checks
#
# Bash 3.2 compatible.

# ------------------------------------------------------------------------------
# detect_os — Determines the current operating system/environment
#
# Sets GITSETU_OS to one of: linux, macos, wsl, gitbash, unknown
#
# Detection order matters:
#   1. WSL first (reports as "linux" in $OSTYPE but has /proc/version marker)
#   2. Git Bash on Windows (MSYS/MINGW in $OSTYPE)
#   3. macOS (darwin in $OSTYPE)
#   4. Native Linux (linux-gnu in $OSTYPE)
#   5. Fallback to uname -s
# ------------------------------------------------------------------------------
detect_os() {
    # Allow tests/callers to override detection by pre-setting GITSETU_OS.
    # This is critical for CI: macOS `security` commands hang in headless environments.
    # Check env var first, then fall back to marker file (env vars don't propagate
    # through pipelines in background subshells on macOS bash 3.2).
    if [[ -n "${GITSETU_OS:-}" ]]; then
        return 0
    fi
    local _os_file="${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu/.test_os"
    if [[ -f "$_os_file" ]]; then
        GITSETU_OS=$(cat "$_os_file" 2>/dev/null)
        if [[ -n "$GITSETU_OS" ]]; then
            return 0
        fi
    fi

    # Check WSL first — it masquerades as Linux
    if [[ -f /proc/version ]]; then
        local proc_version
        proc_version=$(cat /proc/version 2>/dev/null || true)
        case "$proc_version" in
            *[Mm]icrosoft*|*WSL*)
                GITSETU_OS="wsl"
                return 0
                ;;
        esac
    fi

    # Check OSTYPE (fastest, available in bash)
    case "${OSTYPE:-}" in
        darwin*)
            GITSETU_OS="macos"
            return 0
            ;;
        msys*|mingw*|cygwin*)
            GITSETU_OS="gitbash"
            return 0
            ;;
        linux-gnu*|linux*)
            GITSETU_OS="linux"
            return 0
            ;;
    esac

    # Fallback to uname
    local uname_out
    uname_out=$(uname -s 2>/dev/null || true)
    case "$uname_out" in
        Darwin)   GITSETU_OS="macos" ;;
        Linux)    GITSETU_OS="linux" ;;
        MINGW*|MSYS*|CYGWIN*)
                  GITSETU_OS="gitbash" ;;
        *)        GITSETU_OS="unknown" ;;
    esac
}

# ------------------------------------------------------------------------------
# ASCII control-byte validation
# ------------------------------------------------------------------------------
# Bash 3.2 has no portable Unicode-aware [[:cntrl:]] implementation: in the C
# locale valid UTF-8 continuation bytes can be classified as controls. Inspect
# bytes under C and reject only ASCII C0 (0x00..0x1F) and DEL (0x7F). CR, LF,
# and tab are therefore still rejected, while UTF-8 path bytes remain valid.
_gitsetu_contains_ascii_control() {
    [[ $# -eq 1 ]] || return 1
    local value="$1" char ordinal
    local LC_ALL=C

    while [[ -n "$value" ]]; do
        char="${value:0:1}"
        value="${value:1}"
        printf -v ordinal '%d' "'$char" || return 1
        [[ "$ordinal" =~ ^[0-9]+$ ]] || return 1
        if [[ "$ordinal" -le 31 || "$ordinal" -eq 127 ]]; then
            return 0
        fi
    done
    return 1
}

# Validate a field without changing the caller's locale. Return zero only
# when the value contains no ASCII C0/DEL byte.
_gitsetu_reject_ascii_controls() {
    [[ $# -eq 2 ]] || return 1
    ! _gitsetu_contains_ascii_control "$2"
}

# ------------------------------------------------------------------------------
# _gitsetu_lexical_path — Collapse separators and resolve . / .. without I/O
# ------------------------------------------------------------------------------
_gitsetu_lexical_path() {
    local path="$1"
    local prefix=""
    local body
    local components=()
    local stack=()
    local component relative=""
    local i

    # Preserve a leading // as a UNC root. Three or more leading slashes are
    # ordinary duplicate separators and collapse to a POSIX root.
    if { [[ "$path" == "//" || "$path" == //?* ]]; } &&
       [[ "$path" != ///* ]]; then
        prefix="//"
        body="${path:2}"
    elif [[ "$path" =~ ^[a-zA-Z]:(/|$) ]]; then
        prefix="${path:0:1}:/"
        body="${path:3}"
    else
        prefix="/"
        body="${path#/}"
    fi

    IFS='/' read -r -a components <<< "$body"
    for (( i=0; i<${#components[@]}; i++ )); do
        component="${components[$i]}"
        case "$component" in
            ""|".") continue ;;
            "..")
                if [[ ${#stack[@]} -gt 0 ]]; then
                    unset 'stack[${#stack[@]}-1]'
                fi
                ;;
            *) stack+=("$component") ;;
        esac
    done

    for (( i=0; i<${#stack[@]}; i++ )); do
        relative="${relative}/${stack[$i]}"
    done
    path="${prefix}${relative#/}"
    printf '%s' "$path"
}

# ------------------------------------------------------------------------------
# _gitsetu_current_absolute — Return the canonical current directory
# ------------------------------------------------------------------------------
_gitsetu_current_absolute() {
    local current

    if [[ "${GITSETU_OS:-}" == "gitbash" ]]; then
        current=$(pwd -W 2>/dev/null || pwd -P 2>/dev/null) || return 1
        current=${current%$'\r'}
        if [[ "$current" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
            local drive
            drive=$(printf '%s' "${BASH_REMATCH[1]-}" | tr '[:lower:]' '[:upper:]')
            current="${drive}:${BASH_REMATCH[2]-}"
        fi
    else
        current=$(pwd -P 2>/dev/null) || return 1
    fi
    current=${current%$'\r'}
    _gitsetu_lexical_path "$current"
}

# ------------------------------------------------------------------------------
# canonicalize_path — Resolve a path to an absolute canonical representation
#
# Expands only ~ and ~/ (never ~user), translates Windows/MSYS drive paths,
# makes relative paths absolute, resolves existing symlink prefixes physically,
# and lexically resolves . and .. for paths that do not exist yet.
#
# Usage: canonical=$(canonicalize_path "../work")
# ------------------------------------------------------------------------------
canonicalize_path() {
    if [[ $# -ne 1 ]]; then
        return 1
    fi

    local path="$1"
    if [[ -z "$path" ]] || ! _gitsetu_reject_ascii_controls "canonical path" "$path"; then
        return 1
    fi

    # Expand tilde (SC2088: intentional literal comparison, not expansion).
    # shellcheck disable=SC2088
    if [[ "$path" == "~/"* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            return 1
        fi
        path="$HOME/${path:2}"
    elif [[ "$path" == "~" ]]; then
        if [[ -z "${HOME:-}" ]]; then
            return 1
        fi
        path="$HOME"
    elif [[ "$path" == "~"* ]]; then
        return 1
    fi

    path="${path//\\//}"
    if [[ "$path" =~ ^[a-zA-Z]:[^/] ]]; then
        # Drive-relative paths (C:foo) are process-dependent and non-canonical.
        return 1
    fi

    [[ -z "${GITSETU_OS:-}" ]] && detect_os

    if [[ "${GITSETU_OS:-}" == "gitbash" ]]; then
        if [[ "$path" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
            local drive rest
            drive=$(printf '%s' "${BASH_REMATCH[1]-}" | tr '[:lower:]' '[:upper:]')
            rest="${BASH_REMATCH[2]-}"
            [[ -n "$rest" ]] || rest="/"
            path="${drive}:${rest}"
        elif [[ "$path" =~ ^([a-zA-Z]):(/.*)?$ ]]; then
            local drive rest
            drive=$(printf '%s' "${BASH_REMATCH[1]-}" | tr '[:lower:]' '[:upper:]')
            rest="${BASH_REMATCH[2]-}"
            [[ -n "$rest" ]] || rest="/"
            path="${drive}:${rest}"
        fi
    elif [[ "${GITSETU_OS:-}" == "wsl" ]]; then
        local wsl_path=""
        if command -v wslpath >/dev/null 2>&1 &&
           [[ "$path" =~ ^([a-zA-Z]:|/([a-zA-Z])(/.*)?$) ]]; then
            wsl_path=$(wslpath -u "$path" 2>/dev/null || true)
            wsl_path=${wsl_path%$'\r'}
        fi
        if [[ -n "$wsl_path" && "$wsl_path" == /* ]]; then
            path="$wsl_path"
        elif [[ "$path" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
            local drive rest
            drive=$(printf '%s' "${BASH_REMATCH[1]-}" | tr '[:upper:]' '[:lower:]')
            rest="${BASH_REMATCH[2]-}"
            path="/mnt/${drive}${rest}"
        elif [[ "$path" =~ ^([a-zA-Z]):(/.*)?$ ]]; then
            local drive rest
            drive=$(printf '%s' "${BASH_REMATCH[1]-}" | tr '[:upper:]' '[:lower:]')
            rest="${BASH_REMATCH[2]-}"
            if [[ -n "$rest" ]]; then
                path="/mnt/${drive}${rest}"
            else
                path="/mnt/${drive}"
            fi
        fi
    fi

    if [[ "$path" != /* && ! "$path" =~ ^[a-zA-Z]:/ ]]; then
        local base
        base=$(_gitsetu_current_absolute) || return 1
        path="${base%/}/${path}"
    fi

    # A forced Git Bash drive path may not exist on the host running tests. In
    # that case lexical canonicalization is the only safe result.
    local can_resolve=1
    if [[ "${GITSETU_OS:-}" == "gitbash" ]] && [[ "$path" == /* ]]; then
        # POSIX-style MSYS roots are already absolute. Keep them stable when a
        # forced test platform differs from this host.
        can_resolve=0
    elif [[ "${GITSETU_OS:-}" == "gitbash" ]] && [[ "$path" =~ ^[a-zA-Z]:/ ]]; then
        local drive_root="${path:0:2}/"
        # Real Git Bash can physically resolve explicit drive paths. A forced
        # cross-platform test on Linux/WSL cannot, so retain lexical output.
        [[ -d "$drive_root" ]] || can_resolve=0
    fi

    if [[ "$can_resolve" -eq 1 ]]; then
        local resolved=""
        if [[ -d "$path" ]]; then
            if [[ "${GITSETU_OS:-}" == "gitbash" ]]; then
                resolved=$(cd -P "$path" 2>/dev/null && pwd -W 2>/dev/null) || resolved=""
            else
                resolved=$(cd -P "$path" 2>/dev/null && pwd -P 2>/dev/null) || resolved=""
            fi
            resolved=${resolved%$'\r'}
        elif [[ -e "$path" ]]; then
            local parent base
            parent=$(dirname "$path") || return 1
            base="${path##*/}"
            if [[ "${GITSETU_OS:-}" == "gitbash" ]]; then
                resolved=$(cd -P "$parent" 2>/dev/null && pwd -W 2>/dev/null) || resolved=""
            else
                resolved=$(cd -P "$parent" 2>/dev/null && pwd -P 2>/dev/null) || resolved=""
            fi
            resolved=${resolved%$'\r'}
            if [[ -n "$resolved" ]]; then
                resolved="${resolved%/}/${base}"
            fi
        fi

        if [[ -n "$resolved" ]]; then
            path=$(_gitsetu_lexical_path "$resolved") || return 1
        else
            local ancestor="$path"
            local suffix=""
            while [[ ! -d "$ancestor" ]]; do
                local up
                up=$(dirname "$ancestor") || return 1
                if [[ "$up" == "$ancestor" ]]; then
                    break
                fi
                local ancestor_component="${ancestor%/}"
                if [[ -n "$suffix" ]]; then
                    suffix="${ancestor_component##*/}/${suffix}"
                else
                    suffix="${ancestor_component##*/}"
                fi
                ancestor="$up"
            done

            if [[ -d "$ancestor" ]]; then
                if [[ "${GITSETU_OS:-}" == "gitbash" ]]; then
                    resolved=$(cd -P "$ancestor" 2>/dev/null && pwd -W 2>/dev/null) || resolved=""
                else
                    resolved=$(cd -P "$ancestor" 2>/dev/null && pwd -P 2>/dev/null) || resolved=""
                fi
                resolved=${resolved%$'\r'}
                if [[ -n "$resolved" ]]; then
                    if [[ -n "$suffix" ]]; then
                        path="${resolved%/}/${suffix}"
                    else
                        path="$resolved"
                    fi
                    path=$(_gitsetu_lexical_path "$path") || return 1
                else
                    path=$(_gitsetu_lexical_path "$path") || return 1
                fi
            else
                path=$(_gitsetu_lexical_path "$path") || return 1
            fi
        fi
    else
        path=$(_gitsetu_lexical_path "$path") || return 1
    fi

    printf '%s' "$path"
}

# normalize_path is retained as the public compatibility entry point. It now
# has the stronger canonical-path semantics rather than textual rewriting only.
normalize_path() {
    canonicalize_path "$@"
}

# Common semantic aliases for new callers.
resolve_path() {
    canonicalize_path "$@"
}
absolute_path() {
    canonicalize_path "$@"
}

# ------------------------------------------------------------------------------
# get_gitdir_keyword — Returns the correct includeIf keyword for the OS
#
# Windows/Git Bash uses case-insensitive matching: gitdir/i:
# Everything else uses case-sensitive: gitdir:
# ------------------------------------------------------------------------------
get_gitdir_keyword() {
    # Note: lib/guard.sh also handles macos case-insensitivity consistently
    case "$GITSETU_OS" in
        gitbash|macos) printf 'gitdir/i:' ;;
        *)             printf 'gitdir:' ;;
    esac
}

# ------------------------------------------------------------------------------
# is_shared_mount — Detects if a path is on a VirtualBox/VMware/WSL shared folder
#
# These mounts have permission issues (everything is 0777) that prevent
# SSH keys from having the required 0600 permissions.
#
# Returns: 0 if shared mount, 1 if not
# ------------------------------------------------------------------------------
is_shared_mount() {
    local path="$1"

    # Check mount table for vboxsf (VirtualBox), vmhgfs-fuse (VMware), drvfs/9p (WSL)
    if command -v mount >/dev/null 2>&1; then
        local mount_output
        mount_output=$(mount 2>/dev/null) || true

        # Compare exact mount-point prefixes; never treat the untrusted path as
        # a grep regular expression or match /mnt/foo against /mnt/foobar.
        local mp path_prefix mount_prefix
        path_prefix="${path%/}/"
        if [[ "${GITSETU_OS:-}" == "gitbash" || "${GITSETU_OS:-}" == "macos" ]]; then
            path_prefix=$(printf '%s' "$path_prefix" | tr '[:upper:]' '[:lower:]')
        fi
        while read -r mp; do
            [[ -n "$mp" ]] || continue
            mount_prefix="${mp%/}/"
            if [[ "${GITSETU_OS:-}" == "gitbash" || "${GITSETU_OS:-}" == "macos" ]]; then
                mount_prefix=$(printf '%s' "$mount_prefix" | tr '[:upper:]' '[:lower:]')
            fi
            if [[ "$path_prefix" == "$mount_prefix"* ]]; then
                return 0
            fi
        done < <(printf '%s\n' "$mount_output" | grep -E "vboxsf|vmhgfs-fuse|drvfs|9p" | awk '{print $3}')
    fi

    return 1
}

# ------------------------------------------------------------------------------
# check_prerequisites — Verify required tools are available
#
# Checks for: bash version, git, ssh-keygen
# Prints helpful install instructions on failure.
#
# Returns: 0 if all OK, exits 1 on failure
# ------------------------------------------------------------------------------
check_prerequisites() {
    local errors=0

    # Check bash version (need 3.2+)
    local bash_major="${BASH_VERSINFO[0]:-0}"
    local bash_minor="${BASH_VERSINFO[1]:-0}"
    if [[ "$bash_major" -lt 3 ]] || { [[ "$bash_major" -eq 3 ]] && [[ "$bash_minor" -lt 2 ]]; }; then
        print_error "Bash 3.2+ is required (found ${BASH_VERSION:-unknown})"
        errors=$((errors + 1))
    fi

    # Check git
    if ! command -v git >/dev/null 2>&1; then
        print_error "git is not installed"
        case "$GITSETU_OS" in
            linux|wsl) print_info "  Install: sudo apt install git" ;;
            macos)     print_info "  Install: xcode-select --install  OR  brew install git" ;;
            gitbash)   print_info "  Install: download from https://git-scm.com/downloads" ;;
        esac
        errors=$((errors + 1))
    fi

    # Check ssh-keygen
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        print_error "ssh-keygen is not installed"
        case "$GITSETU_OS" in
            linux|wsl) print_info "  Install: sudo apt install openssh-client" ;;
            macos)     print_info "  Should be pre-installed. Try: xcode-select --install" ;;
            gitbash)   print_info "  Should be included with Git for Windows" ;;
        esac
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        print_error "Prerequisites check failed ($errors error(s)). Please install the missing tools."
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# get_ssh_agent_advice — [DEPRECATED in v1.1.0 in favor of auto_register_ssh_keys]
# Returns platform-specific ssh-agent setup instructions. Retained for backward compat.
# ------------------------------------------------------------------------------
get_ssh_agent_advice() {
    case "$GITSETU_OS" in
        macos)
            cat >&2 <<'EOF'
  macOS: Add to ~/.ssh/config:
    Host *
        AddKeysToAgent yes
        UseKeychain yes

  Then run: ssh-add --apple-use-keychain ~/.ssh/id_ed25519_<label>
EOF
            ;;
        linux)
            cat >&2 <<'EOF'
  Linux: Start ssh-agent and add your key:
    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519_<label>

  To auto-start, add the eval line to your ~/.bashrc or ~/.profile
EOF
            ;;
        wsl)
            cat >&2 <<'EOF'
  WSL: Start ssh-agent in your shell:
    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519_<label>

  Add to ~/.bashrc for persistence. Note: WSL does not share the
  Windows ssh-agent. Keys must be added in the WSL session.
EOF
            ;;
        gitbash)
            cat >&2 <<'EOF'
  Git Bash: The ssh-agent should auto-start. If not, run:
    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519_<label>

  Or enable the Windows OpenSSH Agent service:
    Get-Service ssh-agent | Set-Service -StartupType Automatic
    Start-Service ssh-agent
EOF
            ;;
        *)
            cat >&2 <<'EOF'
  Start the SSH agent and add your key:
    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519_<label>
EOF
            ;;
    esac
}

# ------------------------------------------------------------------------------
# copy_to_clipboard — Opportunistically copies text to the system clipboard
# ------------------------------------------------------------------------------
copy_to_clipboard() {
    # Skip clipboard in headless CI or test environments
    if [[ -n "${CI:-}" || -n "${GITSETU_TEST:-}" ]]; then
        return 1
    fi

    local text="$1"
    
    if command -v pbcopy >/dev/null 2>&1; then
        if printf "%s" "$text" | pbcopy >/dev/null 2>&1; then
            return 0
        fi
        return 1
    elif command -v clip.exe >/dev/null 2>&1; then
        if printf "%s" "$text" | clip.exe >/dev/null 2>&1; then
            return 0
        fi
        return 1
    elif command -v xclip >/dev/null 2>&1; then
        if printf "%s" "$text" | xclip -selection clipboard >/dev/null 2>&1; then
            return 0
        fi
        return 1
    elif command -v xsel >/dev/null 2>&1; then
        if printf "%s" "$text" | xsel --clipboard --input >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    
    return 1
}
