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
# normalize_path — Normalize a filesystem path
#
# Handles:
#   - Tilde expansion (~/ → $HOME/)
#   - Backslash → forward slash (Windows)
#   - Removes trailing slash (we add it explicitly where needed)
#   - Resolves to absolute path if relative
#
# Usage: normalized=$(normalize_path "/some//path/")
# ------------------------------------------------------------------------------
normalize_path() {
    local path="$1"

    # Expand tilde (SC2088: intentional literal comparison, not expansion)
    # shellcheck disable=SC2088
    if [[ "$path" == "~/"* ]]; then
        path="$HOME/${path:2}"
    elif [[ "$path" == "~" ]]; then
        path="$HOME"
    fi

    # Backslash → forward slash (Git Bash on Windows)
    path="${path//\\//}"

    # On Windows / Git Bash, convert /c/path to C:/path for Git/OpenSSH compatibility
    [[ -z "${GITSETU_OS:-}" ]] && detect_os
    if [[ "$GITSETU_OS" == "gitbash" ]]; then
        if [[ "$path" =~ ^/([a-zA-Z])/(.*) ]]; then
            local drive="${BASH_REMATCH[1]}"
            local rest="${BASH_REMATCH[2]}"
            drive=$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')
            path="${drive}:/${rest}"
        elif [[ "$path" =~ ^/([a-zA-Z])$ ]]; then
            local drive="${BASH_REMATCH[1]}"
            drive=$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')
            path="${drive}:"
        elif [[ "$path" =~ ^([a-zA-Z]):/(.*) ]]; then
            local drive="${BASH_REMATCH[1]}"
            local rest="${BASH_REMATCH[2]}"
            drive=$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')
            path="${drive}:/${rest}"
        fi
    fi

    # Remove trailing slash (unless it's just "/" or "C:/")
    if [[ "${#path}" -gt 1 ]]; then
        if [[ ! "$path" =~ ^[a-zA-Z]:/$ ]]; then
            path="${path%/}"
        fi
    fi

    # Collapse double slashes (tr -s avoids bash escaping ambiguity on Git Bash)
    path=$(printf '%s' "$path" | tr -s '/')

    printf '%s' "$path"
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
# is_shared_mount — Detects if a path is on a VirtualBox/VMware shared folder
#
# These mounts have permission issues (everything is 0777) that prevent
# SSH keys from having the required 0600 permissions.
#
# Returns: 0 if shared mount, 1 if not
# ------------------------------------------------------------------------------
is_shared_mount() {
    local path="$1"

    # Check mount table for vboxsf (VirtualBox) or vmhgfs-fuse (VMware)
    if command -v mount >/dev/null 2>&1; then
        local mount_output
        mount_output=$(mount 2>/dev/null) || true

        # Check if any vboxsf/vmhgfs mount contains this path
        if printf '%s' "$mount_output" | grep -E "vboxsf|vmhgfs-fuse" | grep -q "${path%/}"; then
            return 0
        fi

        # Broader check: is the path under any vboxsf mount point?
        local mount_point
        mount_point=$(printf '%s' "$mount_output" | grep -E "vboxsf|vmhgfs-fuse" | awk '{print $3}' | head -n1)
        if [[ -n "$mount_point" ]] && [[ "$path" == "$mount_point"* ]]; then
            return 0
        fi
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
# get_ssh_agent_advice — Returns platform-specific ssh-agent setup instructions
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
