#!/usr/bin/env bash
# lib/doctor.sh — Required offline diagnostics and serialized repair
# Bash 3.2 compatible.

_doctor_safe_display() {
    if declare -f escape_terminal_text >/dev/null 2>&1; then
        escape_terminal_text "${1:-}"
    else
        printf '%s' "${1:-}"
    fi
}

_doctor_count_marker() {
    local file="${1:-}"
    local marker="${2:-}"
    local count
    [[ -f "$file" ]] || {
        printf '0'
        return 0
    }
    count=$(grep -F -c "$marker" "$file" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s' "$count"
}

_doctor_canonical_dir() {
    local raw="${1:-}"
    local normalized
    [[ -n "$raw" ]] || return 1
    normalized=$(normalize_path "$raw" 2>/dev/null || true)
    [[ -d "$normalized" ]] || {
        printf '%s' "$normalized"
        return 0
    }
    (cd -P -- "$normalized" 2>/dev/null && pwd -P) || printf '%s' "$normalized"
}

_doctor_profile_email() {
    local label="${1:-}"
    local config_file="$GITSETU_PROFILES_DIR/${label}.gitconfig"
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 1
    git config --file "$config_file" user.email 2>/dev/null || true
}

_doctor_ssh_include_present() {
    local ssh_config="$HOME/.ssh/config"
    [[ -f "$ssh_config" ]] || return 1
    grep -qF 'Include ~/.config/gitsetu/profiles/ssh_config' "$ssh_config" 2>/dev/null || \
        grep -qF "Include $GITSETU_PROFILES_DIR/ssh_config" "$ssh_config" 2>/dev/null || \
        grep -qF "Include \"$GITSETU_PROFILES_DIR/ssh_config\"" "$ssh_config" 2>/dev/null
}

# Parse the effective OpenSSH configuration without opening a network
# connection. A file that cannot be parsed is repair state, not a healthy
# configuration merely because it contains the managed Include line.
_doctor_ssh_config_valid() {
    local ssh_config="$HOME/.ssh/config"
    local mode target="$ssh_config"
    if [[ -L "$ssh_config" ]]; then
        if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
            target=$(_gitconfig_resolve_symlink_target "$ssh_config" 2>/dev/null) || return 1
        else
            return 1
        fi
    fi
    [[ -d "$HOME/.ssh" && ! -L "$HOME/.ssh" && -O "$HOME/.ssh" ]] || return 1
    [[ -f "$target" && -O "$target" ]] || return 1
    if declare -f _ssh_assert_private_directory >/dev/null 2>&1; then
        _ssh_assert_private_directory "$HOME/.ssh" || return 1
    fi
    mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)
    [[ "$mode" == "600" ]] || {
        case "${GITSETU_OS:-}:${OSTYPE:-}" in
            gitbash:*|cygwin:*|msys:*|mingw:*) [[ "$mode" == "644" ]] || return 1 ;;
            *) return 1 ;;
        esac
    }
    local isolated="$GITSETU_PROFILES_DIR/ssh_config"
    if [[ -e "$isolated" || -L "$isolated" ]]; then
        [[ -f "$isolated" && ! -L "$isolated" && -O "$isolated" ]] || return 1
        mode=$(stat -c '%a' "$isolated" 2>/dev/null || stat -f '%Lp' "$isolated" 2>/dev/null || true)
        [[ "$mode" == "600" ]] || {
            case "${GITSETU_OS:-}:${OSTYPE:-}" in
                gitbash:*|cygwin:*|msys:*|mingw:*) [[ "$mode" == "644" ]] || return 1 ;;
                *) return 1 ;;
            esac
        }
    fi
    command -v ssh >/dev/null 2>&1 || return 1
    ssh -G -F "$ssh_config" -o BatchMode=yes github.com >/dev/null 2>&1
}

_doctor_active_profile() {
    local current_raw="${1:-}"
    local current lower_current
    local i dir candidate lower_candidate
    local matched_label="global" matched_dir="[Global Fallback]" longest=0
    local case_insensitive=0

    current=$(_doctor_canonical_dir "$current_raw")
    case "${GITSETU_OS:-${OSTYPE:-}}" in
        gitbash|macos|msys*|mingw*|cygwin*|darwin*) case_insensitive=1 ;;
    esac
    lower_current=$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')

    for (( i=1; i<PROFILE_COUNT; i++ )); do
        dir="${PROFILE_DIRS[$i]:-}"
        [[ -n "$dir" ]] || continue
        candidate=$(_doctor_canonical_dir "$dir")
        lower_candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
        if [[ "$candidate" == "$dir" && ( "$current/" == "$candidate/"* || "$current" == "$candidate" ) ]] || \
           [[ "$case_insensitive" -eq 1 && ( "$lower_current/" == "$lower_candidate/"* || "$lower_current" == "$lower_candidate" ) ]]; then
            if [[ "${#candidate}" -gt "$longest" ]]; then
                longest=${#candidate}
                matched_label="${PROFILE_LABELS[$i]:-}"
                matched_dir="$candidate"
            fi
        fi
    done

    ACTIVE_DOCTOR_PROFILE="$matched_label"
    ACTIVE_DOCTOR_DIR="$matched_dir"
}

# ------------------------------------------------------------------------------
# Diagnostic Environment Check Helpers
# ------------------------------------------------------------------------------

doctor_check_clipboard() {
    local tool="None"
    if command -v pbcopy >/dev/null 2>&1; then
        tool="pbcopy"
    elif command -v clip.exe >/dev/null 2>&1; then
        tool="clip.exe"
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
        tool="wl-copy"
    elif command -v xclip >/dev/null 2>&1; then
        tool="xclip"
    elif command -v xsel >/dev/null 2>&1; then
        tool="xsel"
    fi
    printf '%s' "$tool"
}

doctor_check_known_hosts() {
    local kh="$HOME/.ssh/known_hosts"
    if [[ ! -f "$kh" || ! -s "$kh" ]]; then
        printf 'missing'
        return 1
    fi
    local found=()
    if grep -q "github\.com" "$kh" 2>/dev/null; then
        found+=("github.com")
    fi
    if grep -q "gitlab\.com" "$kh" 2>/dev/null; then
        found+=("gitlab.com")
    fi
    if grep -q "bitbucket\.org" "$kh" 2>/dev/null; then
        found+=("bitbucket.org")
    fi
    if grep -q "^|1|" "$kh" 2>/dev/null; then
        found+=("hashed")
    fi
    if [[ ${#found[@]} -eq 0 ]]; then
        printf 'no-major-hosts'
        return 1
    fi
    local IFS=", "
    printf '%s' "${found[*]}"
    return 0
}

doctor_check_git_version() {
    if ! command -v git >/dev/null 2>&1; then
        printf 'missing'
        return 1
    fi
    local ver_str major minor
    ver_str=$(git --version 2>/dev/null || true)
    if [[ "$ver_str" =~ ([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        if [[ "$major" -gt 2 || ( "$major" -eq 2 && "$minor" -ge 36 ) ]]; then
            printf '%s' "$ver_str"
            return 0
        else
            printf '%s (< 2.36)' "$ver_str"
            return 2
        fi
    fi
    printf '%s' "${ver_str:-unknown}"
    return 0
}

doctor_check_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        printf 'missing'
        return 1
    fi
    local ver
    ver=$(openssl version 2>/dev/null || true)
    if ! openssl enc -ciphers 2>/dev/null | grep -qi "aes-256-ctr" && ! openssl enc -aes-256-ctr -help >/dev/null 2>&1; then
        printf '%s (missing aes-256-ctr)' "$ver"
        return 1
    fi
    printf '%s' "$ver"
    return 0
}

# ------------------------------------------------------------------------------
# run_doctor — required offline checks determine the exit status
# ------------------------------------------------------------------------------

run_doctor() {
    if [[ -z "${GITSETU_OS:-}" ]] && declare -f detect_os >/dev/null 2>&1; then
        local detect_status=0
        detect_os || detect_status=$?
        if [[ "$detect_status" -ne 0 ]]; then
            print_error "Unable to detect the host platform; diagnostics cannot continue."
            return "$detect_status"
        fi
    fi
    print_section "GitSetu Diagnostics (Doctor)"

    local issues_found=0
    local current_dir current_display active_profile expected_email actual_email
    local loaded_keys="" loaded_count=0 key_path fp
    local i label

    current_dir=$(pwd -P 2>/dev/null || printf '%s' "$PWD")
    _doctor_active_profile "$current_dir"
    active_profile="$ACTIVE_DOCTOR_PROFILE"
    current_display=$(_doctor_safe_display "$current_dir")

    printf >&2 "  %bDirectory Context:%b\n" "$BOLD" "$RESET"
    printf >&2 "    Current PWD: %s\n" "$current_display"
    printf >&2 "    Active Profile: %b%s%b\n" "$GREEN" "$(_doctor_safe_display "$active_profile")" "$RESET"
    if [[ "$active_profile" == "global" ]]; then
        printf >&2 "    Matched Rule: No mapped profile directory; using global fallback.\n"
    else
        printf >&2 "    Matched Rule: %s\n" "$(_doctor_safe_display "$ACTIVE_DOCTOR_DIR")"
    fi
    printf >&2 '\n'

    printf >&2 "  %bSystem & Cryptographic Environment:%b\n" "$BOLD" "$RESET"
    local git_ver git_ver_status=0
    git_ver=$(doctor_check_git_version) || git_ver_status=$?
    if [[ "$git_ver_status" -eq 1 ]]; then
        printf >&2 "    Git Version: %bERROR (not installed or in PATH)%b\n" "$RED" "$RESET"
        issues_found=1
    elif [[ "$git_ver_status" -eq 2 ]]; then
        printf >&2 "    Git Version: %bWARNING (%s; version >= 2.36 recommended)%b\n" "$YELLOW" "$git_ver" "$RESET"
    else
        printf >&2 "    Git Version: OK (%s)\n" "$git_ver"
    fi

    local openssl_ver openssl_status=0
    openssl_ver=$(doctor_check_openssl) || openssl_status=$?
    if [[ "$openssl_status" -ne 0 ]]; then
        printf >&2 "    OpenSSL / Ciphers: %bWARNING (%s)%b\n" "$YELLOW" "$openssl_ver" "$RESET"
    else
        printf >&2 "    OpenSSL / Ciphers: OK (%s)\n" "$openssl_ver"
    fi

    local clip_tool
    clip_tool=$(doctor_check_clipboard)
    if [[ "$clip_tool" == "None" ]]; then
        printf >&2 "    Clipboard Tool: None (auto-copy disabled)\n"
    else
        printf >&2 "    Clipboard Tool: OK (%s)\n" "$clip_tool"
    fi

    local kh_status=0 kh_info
    kh_info=$(doctor_check_known_hosts) || kh_status=$?
    if [[ "$kh_status" -ne 0 ]]; then
        printf >&2 "    Known Hosts: %bWARNING (%s)%b\n" "$YELLOW" "$kh_info" "$RESET"
    else
        printf >&2 "    Known Hosts: OK (%s)\n" "$kh_info"
    fi
    printf >&2 '\n'

    printf >&2 "  %bGuard Policy:%b\n" "$BOLD" "$RESET"
    printf >&2 "    Unmanaged repositories: fail-open (GitSetu does not enforce an identity).\n"
    printf >&2 "    Managed repositories: fail-closed when the expected identity is unresolved or differs.\n"
    printf >&2 "    Opt out explicitly with: gitsetu guard --uninstall\n\n"

    printf >&2 "  %bGit Identity Resolution:%b\n" "$BOLD" "$RESET"
    if command -v git >/dev/null 2>&1; then
        actual_email=$(git config user.email 2>/dev/null || true)
        [[ -n "$actual_email" ]] || actual_email="(Not Configured)"
        printf >&2 "    Configured Email: %s\n" "$(_doctor_safe_display "$actual_email")"

        if [[ "$active_profile" != "global" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            local active_conf="$GITSETU_PROFILES_DIR/${active_profile}.gitconfig"
            if ! _guard_validate_effective_identity "$active_profile" "$active_conf"; then
                printf >&2 "    %bERROR: Effective repository identity differs from managed profile '%s'.%b\n" \
                    "$RED" "$(_doctor_safe_display "$active_profile")" "$RESET"
                printf >&2 "      Expected: %s <%s>%s\n" "${GUARD_EXPECTED_NAME:-<unset>}" "${GUARD_EXPECTED_EMAIL:-<unset>}" "${GUARD_EXPECTED_ORIGIN:+ (from $GUARD_EXPECTED_ORIGIN)}"
                printf >&2 "      Actual:   %s <%s>%s\n" "${GUARD_ACTUAL_NAME:-<unset>}" "${GUARD_ACTUAL_EMAIL:-<unset>}" "${GUARD_ACTUAL_NAME_ORIGIN:+ (from $GUARD_ACTUAL_NAME_ORIGIN)}"
                issues_found=1
            else
                print_success "Managed repository resolves to the expected profile."
            fi
        fi
    else
        printf >&2 "    %bERROR: Git is not installed or not in PATH.%b\n" "$RED" "$RESET"
        issues_found=1
    fi
    printf >&2 '\n'

    printf >&2 "  %bSSH Agent (informational):%b\n" "$BOLD" "$RESET"
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        printf >&2 "    %bWARNING: SSH_AUTH_SOCK is not set; commits can still use configured keys.%b\n" "$YELLOW" "$RESET"
    elif ! command -v ssh-add >/dev/null 2>&1; then
        printf >&2 "    %bWARNING: ssh-add is unavailable.%b\n" "$YELLOW" "$RESET"
    else
        loaded_keys=$(ssh-add -l 2>/dev/null || true)
        if [[ -z "$loaded_keys" ]]; then
            loaded_count=0
            printf >&2 "    %bWARNING: The agent reports no loaded identities.%b\n" "$YELLOW" "$RESET"
        else
            while IFS= read -r line; do
                [[ -n "$line" ]] && loaded_count=$((loaded_count + 1))
            done <<< "$loaded_keys"
            printf >&2 "    Loaded identities: %s\n" "$loaded_count"
        fi
    fi
    printf >&2 '\n'

    printf >&2 "  %bRequired Configuration Integrity:%b\n" "$BOLD" "$RESET"
    if [[ -z "${HOME:-}" ]]; then
        printf >&2 "    %bERROR: HOME is not set.%b\n" "$RED" "$RESET"
        issues_found=1
    else
        if [[ -L "$GITSETU_PROFILES_CONF" || ! -f "$GITSETU_PROFILES_CONF" ]]; then
            printf >&2 "    %bERROR: Registry missing or unsafe at %s%b\n" \
                "$RED" "$(_doctor_safe_display "$GITSETU_PROFILES_CONF")" "$RESET"
            issues_found=1
        elif [[ "$(head -n 1 "$GITSETU_PROFILES_CONF" 2>/dev/null || true)" != "# gitsetu-registry-v2" ]]; then
            printf >&2 "    %bERROR: Registry header is missing or unsupported.%b\n" "$RED" "$RESET"
            issues_found=1
        elif [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
            printf >&2 "    %bERROR: Registry contains no complete profiles.%b\n" "$RED" "$RESET"
            issues_found=1
        else
            printf >&2 "    Registry: OK (%s profile(s))\n" "$PROFILE_COUNT"
        fi

        local gitconfig_target="$HOME/.gitconfig"
        if [[ -L "$gitconfig_target" ]]; then
            if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
                gitconfig_target=$(_gitconfig_resolve_symlink_target "$gitconfig_target" 2>/dev/null) || gitconfig_target=""
            else
                gitconfig_target=""
            fi
        fi

        if [[ -z "$gitconfig_target" || ! -f "$gitconfig_target" ]]; then
            printf >&2 "    ~/.gitconfig: %bERROR (missing or unsafe)%b\n" "$RED" "$RESET"
            issues_found=1
        else
            local head_start head_end tail_start tail_end
            head_start=$(_doctor_count_marker "$gitconfig_target" "${GITSETU_MANAGED_HEAD_START:-# [gitsetu:managed:head:start]}")
            head_end=$(_doctor_count_marker "$gitconfig_target" "${GITSETU_MANAGED_HEAD_END:-# [gitsetu:managed:head:end]}")
            tail_start=$(_doctor_count_marker "$gitconfig_target" "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}")
            tail_end=$(_doctor_count_marker "$gitconfig_target" "${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}")
            if [[ "$tail_start" == "1" && "$tail_end" == "1" && ( ( "$head_start" == "1" && "$head_end" == "1" ) || ( "$head_start" == "0" && "$head_end" == "0" ) ) ]]; then
                printf >&2 "    ~/.gitconfig: OK (managed blocks valid)\n"
            else
                printf >&2 "    ~/.gitconfig: %bERROR (managed markers missing or duplicated)%b\n" "$RED" "$RESET"
                issues_found=1
            fi
            local stale_cred
            stale_cred=$(git config --global --get-all credential.helper 2>/dev/null | grep -E "gitsetu.*credential" || true)
            if [[ -n "$stale_cred" ]]; then
                printf >&2 "    ~/.gitconfig: %bWARNING (stale GitSetu credential helper detected)%b\n" "$YELLOW" "$RESET"
            fi
        fi

        local sshconfig_target="$HOME/.ssh/config"
        if [[ -L "$sshconfig_target" ]]; then
            if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
                sshconfig_target=$(_gitconfig_resolve_symlink_target "$sshconfig_target" 2>/dev/null) || sshconfig_target=""
            else
                sshconfig_target=""
            fi
        fi

        if [[ -L "$HOME/.ssh" || -z "$sshconfig_target" || ! -f "$sshconfig_target" ]] || \
           ! _doctor_ssh_include_present || ! _doctor_ssh_config_valid; then
            printf >&2 "    ~/.ssh/config: %bERROR (GitSetu include missing or unsafe)%b\n" "$RED" "$RESET"
            issues_found=1
        elif [[ -L "$GITSETU_PROFILES_DIR" || -L "$GITSETU_PROFILES_DIR/ssh_config" || ! -f "$GITSETU_PROFILES_DIR/ssh_config" ]]; then
            printf >&2 "    ~/.ssh/config: %bERROR (included GitSetu config missing)%b\n" "$RED" "$RESET"
            issues_found=1
        else
            printf >&2 "    ~/.ssh/config: OK (GitSetu include present)\n"
        fi

        for (( i=0; i<PROFILE_COUNT; i++ )); do
            label="${PROFILE_LABELS[$i]:-}"
            expected_email=$(_doctor_profile_email "$label" 2>/dev/null || true)
            if [[ -z "$expected_email" ]]; then
                printf >&2 "    %bERROR: Profile '%s' has no resolvable expected email.%b\n" \
                    "$RED" "$(_doctor_safe_display "$label")" "$RESET"
                issues_found=1
            fi
        done

        # Guard integrity check
        if [[ -f "$GITSETU_HOOKS_DIR/enabled" ]]; then
            local entrypoint_file="$GITSETU_HOOKS_DIR/entrypoint"
            local entrypoint_val=""
            if [[ -f "$entrypoint_file" ]]; then
                entrypoint_val=$(cat "$entrypoint_file" 2>/dev/null || true)
                entrypoint_val="${entrypoint_val%$'\r'}"
            fi
            if [[ -z "$entrypoint_val" || ! -x "$entrypoint_val" ]]; then
                printf >&2 "    %bERROR: Guard entrypoint is missing or not executable: %s%b\n" \
                    "$RED" "$(_doctor_safe_display "${entrypoint_val:-<empty>}")" "$RESET"
                issues_found=1
            else
                local stub_name stub_file missing_stubs=0
                for stub_name in "${GITSETU_GUARD_HOOK_NAMES[@]}"; do
                    stub_file="$GITSETU_HOOKS_DIR/$stub_name"
                    if [[ ! -f "$stub_file" || ! -x "$stub_file" ]] || ! grep -qF "# [gitsetu:managed] gitsetu-hook v3" "$stub_file" 2>/dev/null; then
                        printf >&2 "    %bERROR: Guard hook stub '%s' is missing, stale, or not executable.%b\n" \
                            "$RED" "$(_doctor_safe_display "$stub_name")" "$RESET"
                        issues_found=1
                        missing_stubs=1
                    fi
                done
                if [[ "$missing_stubs" -eq 0 ]]; then
                    printf >&2 "    Guard hooks: OK (entrypoint and 17 stubs valid)\n"
                fi
            fi

            local prof_dir eff_hp
            for (( i=0; i<PROFILE_COUNT; i++ )); do
                label="${PROFILE_LABELS[$i]:-}"
                prof_dir="${PROFILE_DIRS[$i]:-}"
                if [[ -n "$prof_dir" && "$label" != "global" && -d "$prof_dir" ]]; then
                    eff_hp=$(git -C "$prof_dir" config --get core.hooksPath 2>/dev/null || true)
                    if [[ -n "$eff_hp" ]] && ! _guard_paths_equal "$eff_hp" "$GITSETU_HOOKS_DIR"; then
                        printf >&2 "    %bWARNING: Profile '%s' effective core.hooksPath does not point to GitSetu hooks: %s%b\n" \
                            "$YELLOW" "$(_doctor_safe_display "$label")" "$(_doctor_safe_display "$eff_hp")" "$RESET"
                    fi
                fi
            done
        fi
    fi
    printf >&2 '\n'

    printf >&2 "  %bGit Configuration Validation:%b\n" "$BOLD" "$RESET"
    if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        if declare -f verify_git_config >/dev/null 2>&1; then
            if verify_git_config; then
                printf >&2 "    Profile configs and effective identities: OK\n"
            else
                printf >&2 "    %bERROR: Profile config or effective identity validation failed.%b\n" "$RED" "$RESET"
                issues_found=1
            fi
        else
            printf >&2 "    %bERROR: Required Git configuration validator is unavailable.%b\n" "$RED" "$RESET"
            issues_found=1
        fi
    else
        printf >&2 "    %bSKIP: No profiles; Git identity cannot be verified.%b\n" "$YELLOW" "$RESET"
    fi
    printf >&2 '\n'

    printf >&2 "  %bSSH Key Validation:%b\n" "$BOLD" "$RESET"
    if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
        if declare -f verify_ssh_keys >/dev/null 2>&1; then
            if verify_ssh_keys; then
                printf >&2 "    SSH keys: OK\n"
            else
                printf >&2 "    %bERROR: One or more SSH keys are missing, unsafe, or invalid.%b\n" "$RED" "$RESET"
                issues_found=1
            fi
        else
            printf >&2 "    %bERROR: Required SSH key validator is unavailable.%b\n" "$RED" "$RESET"
            issues_found=1
        fi
    else
        printf >&2 "    %bSKIP: No profiles; SSH keys cannot be verified.%b\n" "$YELLOW" "$RESET"
    fi
    printf >&2 '\n'

    if [[ "$issues_found" -ne 0 ]]; then
        print_info "Required checks failed. Repair with: gitsetu doctor --repair"
        printf >&2 '\n'
        return 1
    fi

    print_success "All required offline diagnostics passed."
    return 0
}

# ------------------------------------------------------------------------------
# run_doctor_json — Machine-readable diagnostics in JSON format
# ------------------------------------------------------------------------------
run_doctor_json() {
    local issues=0
    local checks=()

    # 1. git_version
    local git_ver git_status="pass" git_ver_rc=0
    git_ver=$(doctor_check_git_version) || git_ver_rc=$?
    if [[ "$git_ver_rc" -eq 1 ]]; then
        git_status="fail"
        issues=$((issues + 1))
    elif [[ "$git_ver_rc" -eq 2 ]]; then
        git_status="warn"
    fi
    checks+=("{\"name\": \"git_version\", \"status\": \"$git_status\", \"details\": \"$git_ver\"}")

    # 2. openssl
    local openssl_ver openssl_status="pass" openssl_rc=0
    openssl_ver=$(doctor_check_openssl) || openssl_rc=$?
    if [[ "$openssl_rc" -ne 0 ]]; then
        openssl_status="warn"
    fi
    checks+=("{\"name\": \"openssl\", \"status\": \"$openssl_status\", \"details\": \"$openssl_ver\"}")

    # 3. clipboard
    local clip_tool clip_status="pass"
    clip_tool=$(doctor_check_clipboard)
    if [[ "$clip_tool" == "None" ]]; then
        clip_status="warn"
    fi
    checks+=("{\"name\": \"clipboard\", \"status\": \"$clip_status\", \"details\": \"$clip_tool\"}")

    # 4. known_hosts
    local kh_info kh_status="pass" kh_rc=0
    kh_info=$(doctor_check_known_hosts) || kh_rc=$?
    if [[ "$kh_rc" -ne 0 ]]; then
        kh_status="warn"
    fi
    checks+=("{\"name\": \"known_hosts\", \"status\": \"$kh_status\", \"details\": \"$kh_info\"}")

    # 5. profiles_registry
    local reg_status="pass" reg_details="v2 registry valid (${PROFILE_COUNT:-0} profiles)"
    if [[ ! -f "$GITSETU_PROFILES_CONF" || -L "$GITSETU_PROFILES_CONF" ]]; then
        reg_status="fail"
        reg_details="registry missing or unsafe"
        issues=$((issues + 1))
    elif [[ "$(head -n 1 "$GITSETU_PROFILES_CONF" 2>/dev/null || true)" != "# gitsetu-registry-v2" ]]; then
        reg_status="fail"
        reg_details="registry header missing or unsupported"
        issues=$((issues + 1))
    elif [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        reg_status="fail"
        reg_details="registry contains no complete profiles"
        issues=$((issues + 1))
    fi
    checks+=("{\"name\": \"profiles_registry\", \"status\": \"$reg_status\", \"details\": \"$reg_details\"}")

    # 6. gitconfig
    local gc_status="pass" gc_details="managed blocks valid"
    local gc_target="$HOME/.gitconfig"
    if [[ -L "$gc_target" ]]; then
        if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
            gc_target=$(_gitconfig_resolve_symlink_target "$gc_target" 2>/dev/null) || gc_target=""
        else
            gc_target=""
        fi
    fi
    if [[ -z "$gc_target" || ! -f "$gc_target" ]]; then
        gc_status="fail"
        gc_details="gitconfig missing or unsafe"
        issues=$((issues + 1))
    else
        local head_start head_end tail_start tail_end
        head_start=$(_doctor_count_marker "$gc_target" "${GITSETU_MANAGED_HEAD_START:-# [gitsetu:managed:head:start]}")
        head_end=$(_doctor_count_marker "$gc_target" "${GITSETU_MANAGED_HEAD_END:-# [gitsetu:managed:head:end]}")
        tail_start=$(_doctor_count_marker "$gc_target" "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}")
        tail_end=$(_doctor_count_marker "$gc_target" "${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}")
        if ! [[ "$tail_start" == "1" && "$tail_end" == "1" && ( ( "$head_start" == "1" && "$head_end" == "1" ) || ( "$head_start" == "0" && "$head_end" == "0" ) ) ]]; then
            gc_status="fail"
            gc_details="managed markers missing or duplicated"
            issues=$((issues + 1))
        fi
    fi
    checks+=("{\"name\": \"gitconfig\", \"status\": \"$gc_status\", \"details\": \"$gc_details\"}")

    # 7. ssh_config
    local sc_status="pass" sc_details="gitsetu include present"
    local sc_target="$HOME/.ssh/config"
    if [[ -L "$sc_target" ]]; then
        if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
            sc_target=$(_gitconfig_resolve_symlink_target "$sc_target" 2>/dev/null) || sc_target=""
        else
            sc_target=""
        fi
    fi
    if [[ -L "$HOME/.ssh" || -z "$sc_target" || ! -f "$sc_target" ]] || ! _doctor_ssh_include_present || ! _doctor_ssh_config_valid; then
        sc_status="fail"
        sc_details="gitsetu include missing or invalid"
        issues=$((issues + 1))
    fi
    checks+=("{\"name\": \"ssh_config\", \"status\": \"$sc_status\", \"details\": \"$sc_details\"}")

    local overall_status="healthy"
    if [[ "$issues" -gt 0 ]]; then
        overall_status="unhealthy"
    fi

    printf '{\n'
    printf '  "schema_version": "1.0.0",\n'
    printf '  "status": "%s",\n' "$overall_status"
    printf '  "issues_found": %d,\n' "$issues"
    printf '  "issuesFound": %d,\n' "$issues"
    printf '  "checks": [\n'
    local ci
    for (( ci=0; ci<${#checks[@]}; ci++ )); do
        if [[ "$ci" -lt $((${#checks[@]} - 1)) ]]; then
            printf '    %s,\n' "${checks[$ci]}"
        else
            printf '    %s\n' "${checks[$ci]}"
        fi
    done
    printf '  ]\n'
    printf '}\n'

    if [[ "$issues" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Doctor repair rollback helpers
# ------------------------------------------------------------------------------
_doctor_snapshot_file() {
    local target="${1:-}"
    local backup mode parent
    [[ -n "$target" ]] || return 1
    parent="${target%/*}"
    [[ "$parent" =~ ^[A-Za-z]:$ ]] && parent="${parent}/"
    if [[ -e "$parent" || -L "$parent" ]]; then
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
    fi
    if [[ -L "$target" ]]; then
        return 1
    fi
    if [[ -e "$target" ]]; then
        [[ -f "$target" && ! -L "$target" && -O "$target" ]] || return 1
        mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)
        backup=$(umask 077; mktemp "${target}.rollback.XXXXXX" 2>/dev/null) || return 1
        cp -p "$target" "$backup" 2>/dev/null || {
            rm -f "$backup" 2>/dev/null || true
            return 1
        }
        chmod 600 "$backup" 2>/dev/null || {
            rm -f "$backup" 2>/dev/null || true
            return 1
        }
        doctor_rollback_paths+=("$backup")
        doctor_rollback_targets+=("$target")
        doctor_rollback_exists+=(1)
        doctor_rollback_modes+=("$mode")
    else
        doctor_rollback_paths+=("")
        doctor_rollback_targets+=("$target")
        doctor_rollback_exists+=(0)
        doctor_rollback_modes+=("")
    fi
    return 0
}

_doctor_rollback_files() {
    local i
    for (( i=${#doctor_rollback_targets[@]}-1; i>=0; i-- )); do
        if [[ "${doctor_rollback_exists[$i]}" == "1" ]]; then
            mv -f "${doctor_rollback_paths[$i]}" "${doctor_rollback_targets[$i]}" 2>/dev/null || return 1
            if [[ -n "${doctor_rollback_modes[$i]:-}" ]]; then
                chmod "${doctor_rollback_modes[$i]}" "${doctor_rollback_targets[$i]}" 2>/dev/null || return 1
            fi
        else
            rm -f "${doctor_rollback_targets[$i]}" 2>/dev/null || return 1
        fi
    done
    return 0
}

_doctor_discard_rollbacks() {
    local path
    for path in ${doctor_rollback_paths[@]+"${doctor_rollback_paths[@]}"}; do
        [[ -n "$path" ]] && rm -f "$path" 2>/dev/null || true
    done
    doctor_rollback_paths=()
    doctor_rollback_targets=()
    doctor_rollback_exists=()
    doctor_rollback_modes=()
}

# ------------------------------------------------------------------------------
# run_doctor_repair
# ------------------------------------------------------------------------------

run_doctor_repair() {
    print_section "GitSetu Repair (Doctor)"

    if [[ -z "${HOME:-}" || -L "$GITSETU_PROFILES_CONF" || ! -f "$GITSETU_PROFILES_CONF" ]]; then
        print_error "GitSetu has not been configured yet (profiles.conf not found at $GITSETU_PROFILES_CONF). Run 'gitsetu setup' first."
        return 1
    fi
    if declare -f load_profiles >/dev/null 2>&1; then
        local registry_status=0
        load_profiles || registry_status=$?
        if [[ "$registry_status" -ne 0 ]]; then
            return "$registry_status"
        fi
    fi

    local header
    header=$(head -n 1 "$GITSETU_PROFILES_CONF" 2>/dev/null || true)
    if [[ "$header" != "# gitsetu-registry-v2" && "${GITSETU_REGISTRY_WAS_V1:-0}" -ne 1 ]]; then
        print_error "The profile registry header is missing or unsupported; refusing repair."
        return 1
    fi
    if [[ "${PROFILE_COUNT:-0}" -eq 0 ]]; then
        print_error "The registry contains no complete profiles; repair cannot infer an identity."
        return 1
    fi
    if [[ -z "${GITSETU_OS:-}" ]] && declare -f detect_os >/dev/null 2>&1; then
        local detect_status=0
        detect_os || detect_status=$?
        if [[ "$detect_status" -ne 0 ]]; then
            print_error "Unable to detect the host platform; repair was not started."
            return "$detect_status"
        fi
    fi

    local i label expected
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        label="${PROFILE_LABELS[$i]:-}"
        expected=$(_doctor_profile_email "$label" 2>/dev/null || true)
        if [[ -z "$expected" ]]; then
            print_error "Cannot repair managed profile '$label': expected identity is unresolved. Run setup/profile edit first."
            return 1
        fi
    done

    local gitconfig_needs_repair=0
    local ssh_needs_repair=0
    local ssh_agent_needs_repair=0
    local planned=0 failed=0
    local start_count end_count

    local repair_gc_target="$HOME/.gitconfig"
    if [[ -L "$repair_gc_target" ]]; then
        if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
            repair_gc_target=$(_gitconfig_resolve_symlink_target "$repair_gc_target" 2>/dev/null) || repair_gc_target=""
        else
            repair_gc_target=""
        fi
    fi

    if [[ -z "$repair_gc_target" || ! -f "$repair_gc_target" ]]; then
        gitconfig_needs_repair=1
    else
        local head_start head_end tail_start tail_end
        head_start=$(_doctor_count_marker "$repair_gc_target" "${GITSETU_MANAGED_HEAD_START:-# [gitsetu:managed:head:start]}")
        head_end=$(_doctor_count_marker "$repair_gc_target" "${GITSETU_MANAGED_HEAD_END:-# [gitsetu:managed:head:end]}")
        tail_start=$(_doctor_count_marker "$repair_gc_target" "${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}")
        tail_end=$(_doctor_count_marker "$repair_gc_target" "${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}")
        [[ "$tail_start" == "1" && "$tail_end" == "1" && ( ( "$head_start" == "1" && "$head_end" == "1" ) || ( "$head_start" == "0" && "$head_end" == "0" ) ) ]] || gitconfig_needs_repair=1
    fi

    local repair_sc_target="$HOME/.ssh/config"
    if [[ -L "$repair_sc_target" ]]; then
        if declare -f _gitconfig_resolve_symlink_target >/dev/null 2>&1; then
            repair_sc_target=$(_gitconfig_resolve_symlink_target "$repair_sc_target" 2>/dev/null) || repair_sc_target=""
        else
            repair_sc_target=""
        fi
    fi

    if [[ -L "$HOME/.ssh" || -z "$repair_sc_target" || ! -f "$repair_sc_target" ]] || \
       ! _doctor_ssh_include_present || ! _doctor_ssh_config_valid || \
       [[ -L "$GITSETU_PROFILES_DIR" || -L "$GITSETU_PROFILES_DIR/ssh_config" || ! -f "$GITSETU_PROFILES_DIR/ssh_config" ]]; then
        ssh_needs_repair=1
    fi

    if [[ -n "${SSH_AUTH_SOCK:-}" ]] && command -v ssh-add >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
        local agent_status=0
        local agent_keys=""
        ssh-add -l >/dev/null 2>&1 || agent_status=$?
        if [[ "$agent_status" -eq 0 ]]; then
            agent_keys=$(ssh-add -l 2>/dev/null || true)
        fi
        if [[ "$agent_status" -ne 2 ]]; then
            local kp fp
            for (( i=0; i<PROFILE_COUNT; i++ )); do
                kp="${PROFILE_KEYS[$i]-}"
                [[ -n "$kp" && -f "$kp" && ! -L "$kp" ]] || continue
                fp=$(_verify_key_fingerprint "$kp" 2>/dev/null || true)
                if [[ -n "$fp" ]] && { [[ -z "$agent_keys" ]] || ! printf '%s\n' "$agent_keys" | grep -qF "$fp"; }; then
                    ssh_agent_needs_repair=1
                    break
                fi
            done
        fi
    fi

    local cred_needs_repair=0
    local stale_cred
    stale_cred=$(git config --global --get-all credential.helper 2>/dev/null | grep -E "gitsetu.*credential" || true)
    if [[ -n "$stale_cred" ]]; then
        cred_needs_repair=1
    fi

    local v1_registry_needs_repair=0
    if [[ "${GITSETU_REGISTRY_WAS_V1:-0}" -eq 1 ]]; then
        v1_registry_needs_repair=1
    fi

    if [[ "${GITSETU_DRY_RUN:-0}" -eq 1 ]]; then
        [[ "$v1_registry_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would migrate legacy v1.0.0 profile registry to v2."
        [[ "$gitconfig_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would restore managed blocks in ~/.gitconfig."
        [[ "$ssh_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would restore SSH configuration and Include directive."
        [[ "$ssh_agent_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would register missing profile keys with ssh-agent."
        [[ "$cred_needs_repair" -eq 1 ]] && print_step "[DRY RUN] Would remove stale GitSetu credential helper from gitconfig."
        planned=$((gitconfig_needs_repair + ssh_needs_repair + ssh_agent_needs_repair + cred_needs_repair + v1_registry_needs_repair))
        if [[ "$planned" -eq 0 ]]; then
            print_info "Nothing to repair. All required configuration is intact."
        else
            print_info "[DRY RUN] Dry run complete. $planned issue(s) would be repaired; no lock or file was changed."
        fi
        return 0
    fi

    if [[ "$gitconfig_needs_repair" -eq 0 && "$ssh_needs_repair" -eq 0 && "$ssh_agent_needs_repair" -eq 0 && "$cred_needs_repair" -eq 0 && "$v1_registry_needs_repair" -eq 0 ]]; then
        print_info "Nothing to repair. All required configuration and managed blocks are intact."
        return 0
    fi

    if ! declare -f acquire_lock >/dev/null 2>&1 || ! acquire_lock; then
        print_error "Could not acquire the GitSetu mutation lock; repair was not started."
        return 1
    fi
    local lock_held=1
    local doctor_rollback_paths=()
    local doctor_rollback_targets=()
    local doctor_rollback_exists=()
    local doctor_rollback_modes=()

    # shellcheck disable=SC2329
    _doctor_emergency_rollback() {
        _doctor_rollback_files 2>/dev/null || true
        _doctor_discard_rollbacks 2>/dev/null || true
        if [[ "${lock_held:-0}" -eq 1 ]]; then
            release_lock 2>/dev/null || true
            lock_held=0
        fi
    }
    trap '_doctor_emergency_rollback; gitsetu_early_cleanup' INT TERM HUP EXIT

    if [[ "$gitconfig_needs_repair" -eq 1 || "$cred_needs_repair" -eq 1 || "$v1_registry_needs_repair" -eq 1 ]] && ! _doctor_snapshot_file "$HOME/.gitconfig"; then
        print_error "Unable to create a rollback snapshot for ~/.gitconfig; repair was not started."
        release_lock || true
        return 1
    fi
    if [[ "$ssh_needs_repair" -eq 1 ]]; then
        if ! _doctor_snapshot_file "$HOME/.ssh/config" || ! _doctor_snapshot_file "$GITSETU_PROFILES_DIR/ssh_config"; then
            print_error "Unable to create SSH rollback snapshots; repair was not started."
            _doctor_discard_rollbacks
            release_lock || true
            return 1
        fi
    fi

    if [[ "$v1_registry_needs_repair" -eq 1 ]]; then
        print_step "Migrating legacy v1.0.0 profile registry to v2..."
        if write_profiles_registry "$GITSETU_PROFILES_CONF"; then
            print_success "Profile registry migrated to v2 format"
            gitconfig_needs_repair=1
        else
            print_error "Failed to migrate profile registry to v2 format"
            failed=1
        fi
    fi

    if [[ "$cred_needs_repair" -eq 1 ]]; then
        print_step "Removing stale GitSetu credential helper..."
        git config --global --unset-all credential.helper ".*gitsetu.*credential" 2>/dev/null || true
        print_success "Removed stale GitSetu credential helper from ~/.gitconfig"
    fi

    if [[ "$gitconfig_needs_repair" -eq 1 ]]; then
        print_step "Repairing ~/.gitconfig managed blocks..."
        if write_global_gitconfig; then
            print_success "Restored managed blocks in ~/.gitconfig"
        else
            print_error "Failed to restore managed blocks in ~/.gitconfig"
            failed=1
        fi
    fi

    if [[ "$failed" -eq 0 && "$ssh_needs_repair" -eq 1 ]]; then
        print_step "Repairing SSH configuration and Include directive..."
        if write_ssh_config; then
            print_success "Restored SSH configuration in ~/.ssh/config"
        else
            print_error "Failed to restore SSH configuration"
            failed=1
        fi
    fi

    if [[ "$failed" -eq 0 && "$ssh_agent_needs_repair" -eq 1 ]]; then
        print_step "Registering profile SSH keys with ssh-agent..."
        if auto_register_ssh_keys; then
            :
        else
            print_error "Failed to register one or more profile SSH keys"
            failed=1
        fi
    fi

    if [[ "$failed" -ne 0 ]]; then
        if ! _doctor_rollback_files; then
            print_error "Rollback could not fully restore the pre-repair configuration."
        else
            print_warning "Repair changes were rolled back after a failed validation/write."
        fi
    else
        _doctor_discard_rollbacks
    fi

    if [[ "$lock_held" -eq 1 ]]; then
        release_lock || failed=1
        lock_held=0
    fi

    if [[ "$failed" -ne 0 ]]; then
        print_error "Repair completed with errors; no success is being reported."
        return 1
    fi

    trap - INT TERM HUP
    trap gitsetu_early_cleanup EXIT
    print_success "Repair complete. Required configuration was regenerated successfully."
    return 0
}

# ------------------------------------------------------------------------------
# cmd_explain — Origin trace diagnostic (FUT-04)
# Usage: gitsetu explain [path]
# ------------------------------------------------------------------------------
cmd_explain() {
    local target="${1:-.}"
    if [[ ! -d "$target" ]]; then
        print_error "Directory does not exist: $target"
        return 1
    fi

    local target_norm
    target_norm=$(normalize_path "$target" 2>/dev/null || true)
    [[ -n "$target_norm" ]] || target_norm="$target"

    local matched_profile="none"
    load_profiles 2>/dev/null || true

    # 1. Check directory matching
    local i best_len=-1 prof_dir prof_norm
    for (( i=0; i<PROFILE_COUNT; i++ )); do
        prof_dir="${PROFILE_DIRS[$i]:-}"
        [[ -n "$prof_dir" ]] || continue
        prof_norm=$(normalize_path "$prof_dir" 2>/dev/null || true)
        [[ -n "$prof_norm" ]] || continue
        if [[ "$target_norm" == "$prof_norm" || "$target_norm" == "$prof_norm"/* ]]; then
            if [[ ${#prof_norm} -gt $best_len ]]; then
                best_len=${#prof_norm}
                matched_profile="${PROFILE_LABELS[$i]}"
            fi
        fi
    done

    # 2. Check remote matching if not matched and target is in a git repo
    if [[ "$matched_profile" == "none" ]] && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local remote_url
        remote_url=$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)
        if [[ -n "$remote_url" ]]; then
            local remotes_dir="${GITSETU_CONFIG_DIR:-$HOME/.config/gitsetu}/remotes"
            local rf pat
            if [[ -d "$remotes_dir" ]]; then
                for rf in "$remotes_dir"/*.remotes; do
                    [[ -f "$rf" ]] || continue
                    local r_label
                    r_label=$(basename "$rf" .remotes)
                    while IFS= read -r pat || [[ -n "$pat" ]]; do
                        [[ -n "$pat" && "$pat" != \#* ]] || continue
                        # shellcheck disable=SC2254 # pat is intentionally a glob pattern
                        case "$remote_url" in
                            $pat)
                                matched_profile="$r_label"
                                break 2
                                ;;
                        esac
                    done < "$rf"
                done
            fi
        fi
    fi

    if [[ "$matched_profile" == "none" && "$PROFILE_COUNT" -gt 0 ]]; then
        matched_profile="${PROFILE_LABELS[0]} (fallback)"
    fi

    printf '%bGitSetu Identity Origin Explanation%b\n' "$BOLD" "$RESET"
    printf '  Target directory: %s\n' "$target_norm"
    printf '  Matched profile:  %b%s%b\n\n' "$GREEN" "$matched_profile" "$RESET"

    printf '  %-20s %-25s %s\n' "KEY" "VALUE" "ORIGIN (SCOPE & FILE)"
    printf '  %-20s %-25s %s\n' "---" "-----" "---------------------"

    local key origin_out val origin
    for key in user.name user.email core.sshCommand core.hooksPath; do
        val=$(git -C "$target" config "$key" 2>/dev/null || true)
        origin_out=$(git -C "$target" config --show-origin --show-scope "$key" 2>/dev/null || true)
        if [[ -n "$origin_out" ]]; then
            origin=$(printf '%s' "$origin_out" | head -n1 | sed -e 's/'"$key"'.*//')
        else
            origin="(unset)"
        fi
        [[ -n "$val" ]] || val="(unset)"
        printf '  %-20s %-25s %s\n' "$key" "$val" "$origin"
    done
    printf '\n'
    return 0
}

# ------------------------------------------------------------------------------
# cmd_import — Adopt existing unmanaged includeIf rules (FUT-04)
# Usage: gitsetu import [--yes|-y]
# ------------------------------------------------------------------------------
cmd_import() {
    local yes_flag=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) yes_flag=1 ;;
            *)
                print_error "Unknown import option: $1"
                printf >&2 'Usage: gitsetu import [--yes|-y]\n'
                return 1
                ;;
        esac
        shift
    done

    local global_gitconfig="$HOME/.gitconfig"
    if [[ ! -f "$global_gitconfig" ]]; then
        print_info "No ~/.gitconfig found to import from."
        return 0
    fi

    local in_managed=0 line current_gitdir="" inc_path
    local imported_count=0
    local raw_gitdir raw_path
    local adopted_dirs=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"${GITSETU_MANAGED_START:-# [gitsetu:managed:start]}"* || \
              "$line" == *"${GITSETU_MANAGED_HEAD_START:-# [gitsetu:managed:head:start]}"* || \
              "$line" == *"# [gitsetu:managed"* || \
              "$line" == *"[gitsetu:managed:start]"* || \
              "$line" == *"[gitsetu:managed:head:start]"* || \
              "$line" == *"# --- GitSetu Identity Routing (Managed) ---"* || \
              "$line" == *"# --- GitSetu Global Setup (Managed) ---"* ]]; then
            in_managed=1
            continue
        elif [[ "$line" == *"${GITSETU_MANAGED_END:-# [gitsetu:managed:end]}"* || \
              "$line" == *"${GITSETU_MANAGED_HEAD_END:-# [gitsetu:managed:head:end]}"* || \
              "$line" == *"[gitsetu:managed:end]"* || \
              "$line" == *"[gitsetu:managed:head:end]"* || \
              "$line" == *"# --- End GitSetu"* ]]; then
            in_managed=0
            continue
        fi
        [[ "$in_managed" -eq 0 ]] || continue

        if [[ "$line" =~ ^\[includeIf[[:space:]]+\"gitdir(/i)?:(.+)\"\] ]]; then
            raw_gitdir="${BASH_REMATCH[2]}"
            raw_gitdir="${raw_gitdir%/\*\*}"
            raw_gitdir="${raw_gitdir%/\*}"
            raw_gitdir="${raw_gitdir%/}"
            current_gitdir="$raw_gitdir"
        elif [[ -n "$current_gitdir" && "$line" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.+) ]]; then
            raw_path="${BASH_REMATCH[1]}"
            raw_path="${raw_path#\"}"
            raw_path="${raw_path%\"}"
            inc_path="$raw_path"
            
            local full_inc_path="$inc_path"
            if [[ "$full_inc_path" == "~/"* ]]; then
                full_inc_path="$HOME/${full_inc_path#\~/}"
            fi

            if [[ -f "$full_inc_path" ]]; then
                local imp_name imp_email imp_label
                imp_name=$(git config -f "$full_inc_path" user.name 2>/dev/null || true)
                imp_email=$(git config -f "$full_inc_path" user.email 2>/dev/null || true)
                
                local fname
                fname=$(basename "$full_inc_path")
                if [[ "$fname" =~ ^\.?gitconfig-(.+)$ ]]; then
                    imp_label="${BASH_REMATCH[1]}"
                else
                    imp_label=$(basename "$current_gitdir")
                fi
                imp_label=$(printf '%s' "$imp_label" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/^-*//' -e 's/-*$//')
                imp_label="${imp_label:0:20}"
                if [[ -z "$imp_label" || ! "$imp_label" =~ ^[a-z] ]]; then
                    imp_label="p-${imp_label:0:18}"
                fi
                while [[ "$imp_label" == *- ]]; do
                    imp_label="${imp_label%-}"
                done

                if [[ -n "$imp_email" ]]; then
                    print_info "Discovered unmanaged identity route:"
                    printf '  Profile:   %s\n' "$imp_label"
                    printf '  Directory: %s\n' "$current_gitdir"
                    printf '  Name:      %s\n' "${imp_name:-[Inherited]}"
                    printf '  Email:     %s\n' "$imp_email"

                    local proceed=0
                    if [[ "$yes_flag" -eq 1 ]] || ! _ui_tty_available; then
                        proceed=1
                    elif confirm "Adopt this profile into GitSetu?" "y"; then
                        proceed=1
                    fi

                    if [[ "$proceed" -eq 1 ]]; then
                        local cmd_args=("$imp_label" "--email=$imp_email" "--dir=$current_gitdir")
                        [[ -n "$imp_name" ]] && cmd_args+=("--name=$imp_name")
                        if cmd_profile add "${cmd_args[@]}"; then
                            print_success "Imported profile '$imp_label'."
                            imported_count=$((imported_count + 1))
                            adopted_dirs+=("$current_gitdir")
                        else
                            print_error "Failed to import profile '$imp_label'."
                        fi
                    fi
                fi
            fi
            current_gitdir=""
        fi
    done < "$global_gitconfig"

    # Deactivate unmanaged includeIf blocks for adopted profiles to prevent duplicates
    if [[ ${#adopted_dirs[@]} -gt 0 ]]; then
        local tmp_cfg
        tmp_cfg=$(mktemp "${global_gitconfig}.tmp.XXXXXX" 2>/dev/null)
        if [[ -n "$tmp_cfg" ]]; then
            local in_m=0 in_tgt=0
            while IFS= read -r l || [[ -n "$l" ]]; do
                if [[ "$l" == *"[gitsetu:managed:start]"* || "$l" == *"# [gitsetu:managed"* ]]; then
                    in_m=1
                elif [[ "$l" == *"[gitsetu:managed:end]"* || "$l" == *"# --- End GitSetu"* ]]; then
                    in_m=0
                fi
                local match_dir=""
                if [[ "$in_m" -eq 0 && "$l" =~ ^\[includeIf[[:space:]]+\"gitdir(/i)?:(.*)\"\] ]]; then
                    local matched_gitdir="${BASH_REMATCH[2]}"
                    for ad in "${adopted_dirs[@]}"; do
                        if [[ "$matched_gitdir" == *"$ad"* ]]; then
                            match_dir="$ad"
                            break
                        fi
                    done
                fi
                if [[ -n "$match_dir" ]]; then
                    in_tgt=1
                    printf '# [imported-by-gitsetu] %s\n' "$l"
                elif [[ "$in_tgt" -eq 1 && "$l" =~ ^[[:space:]]*path[[:space:]]*= ]]; then
                    in_tgt=0
                    printf '# [imported-by-gitsetu] %s\n' "$l"
                else
                    in_tgt=0
                    printf '%s\n' "$l"
                fi
            done < "$global_gitconfig" > "$tmp_cfg"
            mv -f "$tmp_cfg" "$global_gitconfig" 2>/dev/null || rm -f "$tmp_cfg"
        fi
    fi

    if [[ "$imported_count" -eq 0 ]]; then
        print_info "No unmanaged includeIf profiles were found in ~/.gitconfig."
    else
        print_success "Successfully imported $imported_count profile(s)."
    fi
    return 0
}
