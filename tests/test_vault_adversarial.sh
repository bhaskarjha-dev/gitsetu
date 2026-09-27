#!/usr/bin/env bash
# Focused, hermetic adversarial coverage for authenticated v2 vault restore.
# All salts, keys, identities, and payloads below are disposable test data.
set -euo pipefail

# This suite reads and rewrites binary vault files. BSD sed and grep abort with
# "RE error: illegal byte sequence" when they meet ciphertext under a UTF-8
# locale, so the whole suite runs in the C locale like the product's own byte
# handling does.
export LC_ALL=C

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
setup_test_home

# This suite intentionally changes HOME-local fixture state and keeps one
# already-derived cryptographic fixture key across cases. Individual test
# functions reset all live restore targets explicitly.
_TEST_SKIP_ENV_SNAPSHOT=1
source_gitsetu_libs

_ADV_PASSWORD='fixture-only-vault-password'
_ADV_LAST_RESTORE_OUTPUT=""
export GITSETU_TEST_VAULT_MODE=1
export GITSETU_TEST_VAULT_PASS="$_ADV_PASSWORD"

_ADV_WORK="$TEST_HOME/vault-adversarial"
# GNU tar treats a drive-letter archive argument as a remote host unless it is
# in the current MSYS/Cygwin mount namespace. Keep fixture tar paths native to
# Bash while leaving the manifest's source HOME in canonical product spelling.
if command -v cygpath >/dev/null 2>&1; then
    _ADV_WORK=$(cygpath -u "$_ADV_WORK")
fi
_ADV_SOURCE_HOME="$TEST_HOME/vault-adversarial/source-home"
_ADV_TMP="$_ADV_WORK/tmp"
rm -rf "$_ADV_WORK"
mkdir -p "$_ADV_SOURCE_HOME/.ssh" "$_ADV_SOURCE_HOME/work" "$_ADV_TMP"
chmod 700 "$_ADV_WORK" "$_ADV_SOURCE_HOME" "$_ADV_SOURCE_HOME/.ssh" "$_ADV_TMP"
export TMPDIR="$_ADV_TMP"

_vault_ensure_runtime_constants

# Derive the expensive v2 key hierarchy once. Reusing this test-only hierarchy
# does not weaken the assertions: every payload is encrypted and tagged with
# the exact v2 algorithms, while avoiding dozens of redundant 600k PBKDF2 runs.
_ADV_KDF_SALT='00112233445566778899aabbccddeeff'
_ADV_ENC_SALT='102233445566778899aabbccddeeff00'
_ADV_IV='ffeeddccbbaa99887766554433221100'
_ADV_ROOT_KEY=$(_vault_derive_root_key "$_ADV_PASSWORD" "$_ADV_KDF_SALT") || {
    printf '  [FATAL] could not derive adversarial v2 root key\n' >&2
    exit 1
}
_ADV_MAC_KEY=$(_vault_derive_mac_key "$_ADV_ROOT_KEY") || {
    printf '  [FATAL] could not derive adversarial v2 authentication key\n' >&2
    exit 1
}
_ADV_ENC_DERIVED=$(
    printf 'gitsetu-v2-encryption:%s:%s\n' "$_ADV_ROOT_KEY" "${_ADV_ENC_SALT:16}" |
        openssl enc -aes-256-cbc -P -salt -pbkdf2 -iter "$GITSETU_VAULT_ITERATIONS" \
            -S "${_ADV_ENC_SALT:0:16}" -pass stdin 2>/dev/null
) || {
    printf '  [FATAL] could not derive adversarial v2 encryption key\n' >&2
    exit 1
}
_ADV_ENC_KEY=$(printf '%s\n' "$_ADV_ENC_DERIVED" | sed -n 's/^key=//p' | head -n 1)
unset _ADV_ENC_DERIVED
[[ "$_ADV_ENC_KEY" =~ ^[0-9A-Fa-f]{64}$ ]] || {
    printf '  [FATAL] invalid adversarial v2 encryption key\n' >&2
    exit 1
}

# The fixture builder is intentionally independent of cmd_backup's payload
# allowlist. That permits malicious tar members to be wrapped in envelopes
# which are otherwise indistinguishable from authentic v2 vaults.
_adv_build_payload_tree() {
    local tree_root="${1%/}"
    local archive_root="$tree_root/gitsetu-v2"
    local state_root="$archive_root/state"
    local profiles_root="$state_root/profiles"
    local hooks_root="$state_root/hooks"
    local keys_root="$archive_root/keys"
    local source_key="$_ADV_SOURCE_HOME/.ssh/id_ed25519_global"

    mkdir -p "$profiles_root" "$hooks_root" "$keys_root" || return 1
    cat > "$state_root/profiles.conf" <<EOF || return 1
$(test_v2_registry_header)
$(test_v2_registry_line global '' github.com 0 "$source_key" fixture-user)
EOF
    cat > "$profiles_root/global.gitconfig" <<'EOF' || return 1
[user]
    name = Adversarial Fixture
    email = adversarial@example.invalid
EOF
    printf '%s\n' 'disposable fixture private key; not a secret' > "$keys_root/0" || return 1
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURE fixture@example.invalid' \
        > "$keys_root/0.pub" || return 1
    cat > "$archive_root/manifest" <<EOF || return 1
format=2
profiles=1
source_home=$_ADV_SOURCE_HOME
profile.0.config=state/profiles/global.gitconfig
profile.0.key=keys/0
profile.0.public=keys/0.pub
EOF
    chmod 700 "$tree_root" "$archive_root" "$state_root" "$profiles_root" \
        "$hooks_root" "$keys_root" || return 1
    chmod 600 "$state_root/profiles.conf" "$profiles_root/global.gitconfig" \
        "$keys_root/0" "$keys_root/0.pub" "$archive_root/manifest" || return 1
}

# Build a valid two-profile payload whose final private/public destination set
# can be made ambiguous in the authenticated payload itself.  The caller
# controls the second private destination relative to the source ~/.ssh root.
_adv_build_collision_payload_tree() {
    local tree_root="${1%/}"
    local second_key_relative="${2:-}"
    local archive_root="$tree_root/gitsetu-v2"
    local state_root="$archive_root/state"
    local profiles_root="$state_root/profiles"
    local hooks_root="$state_root/hooks"
    local keys_root="$archive_root/keys"
    local first_key="$_ADV_SOURCE_HOME/.ssh/id_primary"
    local second_key="$_ADV_SOURCE_HOME/.ssh/$second_key_relative"

    [[ -n "$second_key_relative" && "$second_key_relative" != */* ]] || return 1
    mkdir -p "$profiles_root" "$hooks_root" "$keys_root" || return 1
    cat > "$state_root/profiles.conf" <<EOF || return 1
$(test_v2_registry_header)
$(test_v2_registry_line global '' github.com 0 "$first_key" fixture-user)
$(test_v2_registry_line collision "$_ADV_SOURCE_HOME/work" github.com 0 "$second_key" fixture-user)
EOF
    cat > "$profiles_root/global.gitconfig" <<'EOF' || return 1
[user]
    name = Adversarial Global
    email = global@example.invalid
EOF
    cat > "$profiles_root/collision.gitconfig" <<'EOF' || return 1
[user]
    name = Adversarial Collision
    email = collision@example.invalid
EOF
    printf '%s\n' 'disposable duplicate-destination private fixture' > "$keys_root/0" || return 1
    printf '%s\n' 'disposable duplicate-destination private fixture' > "$keys_root/1" || return 1
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURE collision@example.invalid' \
        > "$keys_root/0.pub" || return 1
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURE collision@example.invalid' \
        > "$keys_root/1.pub" || return 1
    cat > "$archive_root/manifest" <<EOF || return 1
format=2
profiles=2
source_home=$_ADV_SOURCE_HOME
profile.0.config=state/profiles/global.gitconfig
profile.0.key=keys/0
profile.0.public=keys/0.pub
profile.1.config=state/profiles/collision.gitconfig
profile.1.key=keys/1
profile.1.public=keys/1.pub
EOF
    chmod 700 "$tree_root" "$archive_root" "$state_root" "$profiles_root" \
        "$hooks_root" "$keys_root" || return 1
    chmod 600 "$state_root/profiles.conf" "$profiles_root/global.gitconfig" \
        "$profiles_root/collision.gitconfig" "$keys_root/0" "$keys_root/1" \
        "$keys_root/0.pub" "$keys_root/1.pub" "$archive_root/manifest" || return 1
}

_adv_tar_tree() {
    local tree_root="${1%/}"
    local archive="$2"
    (cd "$tree_root" && tar -czf "$archive" gitsetu-v2)
}

_adv_tar_tree_with_transform() {
    local tree_root="${1%/}"
    local archive="$2"
    local transform="$3"
    local tar_help=""

    # GNU tar is preferred. BSD/macOS tar has no --transform, so use a small
    # Python tarfile builder for the same authenticated fixture instead of
    # silently skipping the malicious archive on a supported runner.
    tar_help=$(tar --help 2>&1 || true)
    if printf '%s\n' "$tar_help" | grep -q -- '--transform'; then
        (cd "$tree_root" && tar -czf "$archive" --transform="$transform" gitsetu-v2)
        return $?
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        return 2
    fi
    python3 - "$tree_root" "$archive" "$transform" <<'PY'
import os
import re
import stat
import sys
import tarfile

root, archive, transform = sys.argv[1:]
match = re.match(r"^s\|(.+)\|(.+)\|$", transform)
if not match:
    raise SystemExit(2)
pattern, replacement = match.groups()
pattern = pattern.replace("$", r"\Z")
with tarfile.open(archive, "w:gz") as output:
    for directory, dirs, files in os.walk(root):
        dirs.sort()
        files.sort()
        for name in ["."] if directory == root else []:
            relative = "."
            arcname = re.sub(pattern, replacement, relative)
            info = output.gettarinfo(directory, arcname=arcname)
            output.addfile(info)
        for name in dirs + files:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            arcname = re.sub(pattern, replacement, relative)
            info = output.gettarinfo(path, arcname=arcname)
            if stat.S_ISREG(info.mode):
                with open(path, "rb") as stream:
                    output.addfile(info, stream)
            elif stat.S_ISDIR(info.mode):
                output.addfile(info)
            else:
                raise SystemExit(2)
PY
}

_adv_compute_tag_hex() {
    local header_core="$1"
    local ciphertext="$2"
    local payload_length="$3"
    local inner_file tag_file
    inner_file=$(umask 077 && mktemp "$_ADV_WORK/tag-inner.XXXXXX") || return 1
    tag_file=$(umask 077 && mktemp "$_ADV_WORK/tag-output.XXXXXX") || {
        rm -f "$inner_file"
        return 1
    }
    {
        _vault_hmac_pad "$_ADV_MAC_KEY" 54
        cat "$header_core"
        printf 'payload_length=%s\n\nPAYLOAD\n' "$payload_length"
        cat "$ciphertext"
    } | openssl dgst -sha256 -binary > "$inner_file" 2>/dev/null || {
        rm -f "$inner_file" "$tag_file"
        return 1
    }
    {
        _vault_hmac_pad "$_ADV_MAC_KEY" 92
        cat "$inner_file"
    } | openssl dgst -sha256 -binary > "$tag_file" 2>/dev/null || {
        rm -f "$inner_file" "$tag_file"
        return 1
    }
    od -An -tx1 "$tag_file" 2>/dev/null | tr -d ' \r\n'
    local tag_status=$?
    rm -f "$inner_file" "$tag_file"
    return "$tag_status"
}

_adv_write_authenticated_envelope() {
    local plaintext_tar="$1"
    local output_vault="$2"
    local tag_text="${3:-}"
    local work_dir header_core header_full ciphertext payload_length tag_hex
    work_dir=$(umask 077 && mktemp -d "$_ADV_WORK/envelope.XXXXXX") || return 1
    header_core="$work_dir/header.core"
    header_full="$work_dir/header.full"
    ciphertext="$work_dir/ciphertext.bin"

    {
        printf '%s\n' "$GITSETU_VAULT_FORMAT"
        printf 'kdf=%s\n' "$GITSETU_VAULT_KDF"
        printf 'iterations=%s\n' "$GITSETU_VAULT_ITERATIONS"
        printf 'cipher=%s\n' "$GITSETU_VAULT_CIPHER"
        printf 'mac=%s\n' "$GITSETU_VAULT_MAC"
        printf 'kdf_salt=%s\n' "$_ADV_KDF_SALT"
        printf 'encryption_salt=%s\n' "$_ADV_ENC_SALT"
        printf 'iv=%s\n' "$_ADV_IV"
    } > "$header_core" || {
        rm -rf "$work_dir"
        return 1
    }

    openssl enc -aes-256-ctr -K "$_ADV_ENC_KEY" -iv "$_ADV_IV" \
        -in "$plaintext_tar" -out "$ciphertext" 2>/dev/null || {
        rm -rf "$work_dir"
        return 1
    }
    payload_length=$(_vault_file_size "$ciphertext") || {
        rm -rf "$work_dir"
        return 1
    }
    [[ "$payload_length" -gt 0 ]] || {
        rm -rf "$work_dir"
        return 1
    }
    if [[ -n "$tag_text" ]]; then
        [[ "$tag_text" =~ ^[0-9a-f]{64}$ ]] || {
            rm -rf "$work_dir"
            return 1
        }
        tag_hex="$tag_text"
    else
        tag_hex=$(_adv_compute_tag_hex "$header_core" "$ciphertext" "$payload_length") || {
            rm -rf "$work_dir"
            return 1
        }
    fi
    {
        cat "$header_core"
        printf 'tag=%s\n' "$tag_hex"
        printf 'payload_length=%s\n\n' "$payload_length"
    } > "$header_full" || {
        rm -rf "$work_dir"
        return 1
    }
    cat "$header_full" "$ciphertext" > "$output_vault" || {
        rm -rf "$work_dir"
        return 1
    }
    chmod 600 "$output_vault" || {
        rm -rf "$work_dir"
        return 1
    }
    rm -rf "$work_dir"
}

_adv_reset_live_target() {
    rm -rf "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.gitconfig" \
        "$HOME/.gitsetu-test-runtime"
    mkdir -p "$GITSETU_CONFIG_DIR" "$HOME/.ssh" "$HOME/.config"
    printf '%s\n' 'live-profiles-sentinel' > "$GITSETU_PROFILES_CONF"
    printf '%s\n' 'live-gitconfig-sentinel' > "$HOME/.gitconfig"
    printf '%s\n' 'live-key-sentinel' > "$HOME/.ssh/id_ed25519_global"
    printf '%s\n' 'live-unmanaged-sentinel' > "$GITSETU_CONFIG_DIR/unmanaged.conf"
    chmod 700 "$GITSETU_CONFIG_DIR" "$HOME/.ssh"
    chmod 600 "$GITSETU_PROFILES_CONF" "$HOME/.gitconfig" \
        "$HOME/.ssh/id_ed25519_global" "$GITSETU_CONFIG_DIR/unmanaged.conf"
    _clear_profile_state
    _VAULT_ROOT_KEY=""
    _VAULT_ACTIVE_TEMP=""
    GITSETU_VAULT_ACTIVE_TRANSACTION=""
}

_adv_assert_no_transaction_marker() {
    local candidate found=0
    for candidate in "$(dirname "$GITSETU_CONFIG_DIR")"/.gitsetu-restore.*; do
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            found=1
            assert_file_not_exists "$candidate" \
                "failed vault validation leaves no restore transaction" || return 1
        fi
    done
    [[ "$found" -eq 0 ]]
}

_adv_assert_live_untouched() {
    local context="$1"
    assert_file_contains "$GITSETU_PROFILES_CONF" "live-profiles-sentinel" \
        "$context leaves the registry untouched" || return 1
    assert_file_contains "$HOME/.gitconfig" "live-gitconfig-sentinel" \
        "$context leaves global Git configuration untouched" || return 1
    assert_file_contains "$HOME/.ssh/id_ed25519_global" "live-key-sentinel" \
        "$context leaves the target key untouched" || return 1
    assert_file_contains "$GITSETU_CONFIG_DIR/unmanaged.conf" "live-unmanaged-sentinel" \
        "$context leaves unrelated config untouched" || return 1
    _adv_assert_no_transaction_marker
}

_adv_expect_restore_rejected() {
    local context="$1"
    local archive="$2"
    local vault="$_ADV_WORK/rejected.vault"
    local status=0 output=""

    _adv_reset_live_target
    _adv_write_authenticated_envelope "$archive" "$vault" || {
        printf '    FAIL: could not authenticate adversarial fixture: %s\n' "$context"
        return 1
    }
    output=$(cmd_restore "$vault" 2>&1) || status=$?
    _ADV_LAST_RESTORE_OUTPUT="$output"
    if [[ "$status" -ne 1 ]]; then
        printf '    FAIL: %s should be rejected with status 1 (got %s)\n' "$context" "$status"
        printf '      Restore output: %s\n' "$output"
        mark_test_failure
        return 1
    fi
    _adv_assert_live_untouched "$context" || return 1
    rm -f "$vault"
    return 0
}

_adv_replace_header_line() {
    local input="$1"
    local output="$2"
    local line_number="$3"
    local replacement="$4"
    local payload_length header temporary
    payload_length=$(sed -n 's/^payload_length=//p' "$input" | head -n 1) || return 1
    [[ "$payload_length" =~ ^[0-9]+$ ]] || return 1
    header=$(umask 077 && mktemp "$_ADV_WORK/header.XXXXXX") || return 1
    temporary=$(umask 077 && mktemp "$_ADV_WORK/envelope.XXXXXX") || {
        rm -f "$header"
        return 1
    }
    head -n 11 "$input" > "$header" || {
        rm -f "$header" "$temporary"
        return 1
    }
    {
        head -n "$((line_number - 1))" "$header"
        printf '%s\n' "$replacement"
        tail -n "+$((line_number + 1))" "$header"
        tail -c "$payload_length" "$input"
    } > "$temporary" || {
        rm -f "$header" "$temporary"
        return 1
    }
    mv -f "$temporary" "$output" || {
        rm -f "$header" "$temporary"
        return 1
    }
    rm -f "$header"
    chmod 600 "$output"
}

_adv_flip_ciphertext_byte() {
    local input="$1"
    local output="$2"
    local header_size byte octal
    cp -f "$input" "$output" || return 1
    header_size=$(head -n 11 "$input" | wc -c | tr -d '[:space:]') || return 1
    byte=$(od -An -tu1 -j "$header_size" -N 1 "$input" 2>/dev/null | tr -d '[:space:]') || return 1
    [[ "$byte" =~ ^[0-9]+$ ]] || return 1
    if [[ "$byte" -eq 0 ]]; then byte=1; else byte=0; fi
    printf -v octal '\\%03o' "$byte"
    printf '%b' "$octal" | dd of="$output" bs=1 seek="$header_size" conv=notrunc 2>/dev/null
}

# --- Test cases ---

test_vault_adversarial_authenticated_baseline_is_valid() {
    local tree="$_ADV_WORK/baseline-tree"
    local archive="$_ADV_WORK/baseline.tar.gz"
    local vault="$_ADV_WORK/baseline.vault"
    local status=0

    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_write_authenticated_envelope "$archive" "$vault" || return 1
    _adv_reset_live_target

    cmd_restore "$vault" >/dev/null 2>&1 || status=$?
    assert_equals "0" "$status" "authenticated v2 adversarial baseline restores" || return 1
    assert_file_contains "$GITSETU_PROFILES_DIR/global.gitconfig" "Adversarial Fixture" \
        "baseline restores the strict registry and profile payload" || return 1
    assert_file_contains "$HOME/.ssh/id_ed25519_global" "disposable fixture private key" \
        "baseline maps the key into the target HOME" || return 1
    assert_file_not_contains "$GITSETU_PROFILES_CONF" "$_ADV_SOURCE_HOME" \
        "restored registry does not retain source-home paths" || return 1
}

test_vault_adversarial_rejects_traversal_and_absolute_members() {
    local traversal_tree="$_ADV_WORK/traversal-tree"
    local traversal_archive="$_ADV_WORK/traversal.tar.gz"
    local absolute_tree="$_ADV_WORK/absolute-tree"
    local absolute_archive="$_ADV_WORK/absolute.tar.gz"
    local listing=""

    rm -rf "$traversal_tree" "$absolute_tree"
    _adv_build_payload_tree "$traversal_tree" || return 1
    local transform_status=0
    _adv_tar_tree_with_transform "$traversal_tree" "$traversal_archive" \
        's|^gitsetu-v2/state/profiles.conf$|gitsetu-v2/../../escape.conf|' || transform_status=$?
    if [[ "$transform_status" -eq 2 ]]; then
        skip_test "authenticated traversal/absolute archive fixtures" "no portable tar transform or python3 builder is available"
        return 0
    fi
    [[ "$transform_status" -eq 0 ]] || return 1
    listing=$(tar -tzf "$traversal_archive" 2>/dev/null) || return 1
    assert_contains "$listing" "gitsetu-v2/../../escape.conf" \
        "traversal fixture really stores ../ members" || return 1
    _adv_expect_restore_rejected "authenticated traversal archive" "$traversal_archive" || return 1

    _adv_build_payload_tree "$absolute_tree" || return 1
    transform_status=0
    _adv_tar_tree_with_transform "$absolute_tree" "$absolute_archive" \
        's|^gitsetu-v2|/gitsetu-v2|' || transform_status=$?
    if [[ "$transform_status" -eq 2 ]]; then
        skip_test "authenticated absolute archive fixture" "no portable tar transform or python3 builder is available"
        return 0
    fi
    [[ "$transform_status" -eq 0 ]] || return 1
    listing=$(tar --absolute-names -tzf "$absolute_archive" 2>/dev/null) || return 1
    assert_contains "$listing" "/gitsetu-v2/state/profiles.conf" \
        "absolute-path fixture really stores rooted members" || return 1
    _adv_expect_restore_rejected "authenticated absolute-path archive" "$absolute_archive"
}

test_vault_adversarial_rejects_duplicate_members() {
    local tree="$_ADV_WORK/duplicate-tree"
    local archive="$_ADV_WORK/duplicate.tar.gz"

    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    (cd "$tree" && tar -czf "$archive" gitsetu-v2 gitsetu-v2/state/profiles.conf) 2>/dev/null || return 1
    _adv_expect_restore_rejected "authenticated duplicate-member archive" "$archive"
}

test_vault_adversarial_rejects_duplicate_restore_destinations() {
    local same_tree="$_ADV_WORK/duplicate-destination-tree"
    local same_archive="$_ADV_WORK/duplicate-destination.tar.gz"
    local cross_tree="$_ADV_WORK/cross-kind-destination-tree"
    local cross_archive="$_ADV_WORK/cross-kind-destination.tar.gz"

    # Equal private/public payloads do not make duplicate writes deterministic:
    # every destination is required to be unique even when the bytes agree.
    rm -rf "$same_tree"
    _adv_build_collision_payload_tree "$same_tree" id_primary || return 1
    _adv_tar_tree "$same_tree" "$same_archive" || return 1
    _adv_expect_restore_rejected \
        "authenticated duplicate private/public destinations" "$same_archive" || return 1
    assert_contains "$_ADV_LAST_RESTORE_OUTPUT" "duplicate key restore destination" \
        "identical key mappings are rejected specifically as duplicate destinations" || return 1

    # A private destination can equal another mapping's derived public path.
    # This cross-kind collision is not discoverable by comparing only private
    # destinations, but would otherwise overwrite one key kind with the other.
    rm -rf "$cross_tree"
    _adv_build_collision_payload_tree "$cross_tree" id_primary.pub || return 1
    _adv_tar_tree "$cross_tree" "$cross_archive" || return 1
    _adv_expect_restore_rejected \
        "authenticated private/public destination collision" "$cross_archive" || return 1
    assert_contains "$_ADV_LAST_RESTORE_OUTPUT" "duplicate key restore destination" \
        "cross-kind key mappings are rejected specifically as duplicate destinations"
}

test_vault_adversarial_rejects_symlink_member() {
    local tree="$_ADV_WORK/symlink-tree"
    local archive="$_ADV_WORK/symlink.tar.gz"
    local link_path="$tree/gitsetu-v2/state/profiles/linked.gitconfig"

    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    if ! ln -s ../profiles.conf "$link_path" 2>/dev/null; then
        skip_test "authenticated symlink archive rejection" "filesystem cannot create test symlinks"
        return 0
    fi
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated symlink archive" "$archive"
}

test_vault_adversarial_rejects_hardlink_member() {
    local tree="$_ADV_WORK/hardlink-tree"
    local archive="$_ADV_WORK/hardlink.tar.gz"
    local link_path="$tree/gitsetu-v2/state/profiles/hardlinked.gitconfig"

    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    if ! ln "$tree/gitsetu-v2/state/profiles/global.gitconfig" "$link_path" 2>/dev/null; then
        skip_test "authenticated hardlink archive rejection" "filesystem cannot create test hardlinks"
        return 0
    fi
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated hardlink archive" "$archive"
}

test_vault_adversarial_rejects_fifo_member() {
    local tree="$_ADV_WORK/fifo-tree"
    local archive="$_ADV_WORK/fifo.tar.gz"
    local fifo_path="$tree/gitsetu-v2/state/profiles/pipe.gitconfig"

    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    if ! mkfifo "$fifo_path" 2>/dev/null; then
        skip_test "authenticated FIFO archive rejection" "filesystem cannot create test FIFOs"
        return 0
    fi
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated FIFO archive" "$archive"
}

test_vault_adversarial_rejects_unmanifested_and_malformed_payloads() {
    local tree
    local archive
    local status=0

    tree="$_ADV_WORK/unmanifested-tree"
    archive="$_ADV_WORK/unmanifested.tar.gz"
    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    printf '%s\n' 'not declared by manifest' > "$tree/gitsetu-v2/state/profiles/extra.gitconfig" || return 1
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated unmanifested-file archive" "$archive" || return 1

    tree="$_ADV_WORK/bad-count-tree"
    archive="$_ADV_WORK/bad-count.tar.gz"
    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    printf '%s\n' 'profile.0.config=state/profiles/global.gitconfig' \
        >> "$tree/gitsetu-v2/manifest" || return 1
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated manifest record-count mismatch" "$archive" || return 1

    tree="$_ADV_WORK/bad-key-tree"
    archive="$_ADV_WORK/bad-key.tar.gz"
    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    {
        head -n 4 "$tree/gitsetu-v2/manifest"
        printf '%s\n' 'profile.0.key=keys/9'
        tail -n 1 "$tree/gitsetu-v2/manifest"
    } > "$tree/gitsetu-v2/manifest.fixed" || return 1
    mv -f "$tree/gitsetu-v2/manifest.fixed" "$tree/gitsetu-v2/manifest" || return 1
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated manifest missing-key reference" "$archive" || return 1

    tree="$_ADV_WORK/bad-home-tree"
    archive="$_ADV_WORK/bad-home.tar.gz"
    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    {
        head -n 2 "$tree/gitsetu-v2/manifest"
        printf '%s\n' 'source_home=relative/source/home'
        tail -n +4 "$tree/gitsetu-v2/manifest"
    } > "$tree/gitsetu-v2/manifest.fixed" || return 1
    mv -f "$tree/gitsetu-v2/manifest.fixed" "$tree/gitsetu-v2/manifest" || return 1
    _adv_tar_tree "$tree" "$archive" || return 1
    _adv_expect_restore_rejected "authenticated nonportable manifest source_home" "$archive" || return 1

    # Ensure a failed case did not leave the test process authenticated as the
    # fixture source and able to bypass subsequent precommit checks.
    _clear_profile_state
    [[ "$status" -eq 0 ]]
}

test_vault_adversarial_rejects_nonportable_registry_paths() {
    local key_tree="$_ADV_WORK/external-key-tree"
    local key_archive="$_ADV_WORK/external-key.tar.gz"
    local dir_tree="$_ADV_WORK/external-dir-tree"
    local dir_archive="$_ADV_WORK/external-dir.tar.gz"
    local external_key="$_ADV_WORK/outside-source-home"
    local external_dir="$_ADV_WORK/outside-work"

    printf '%s\n' 'disposable external key fixture' > "$external_key" || return 1
    rm -rf "$key_tree"
    _adv_build_payload_tree "$key_tree" || return 1
    {
        test_v2_registry_header
        test_v2_registry_line global '' github.com 0 "$external_key" fixture-user
    } > "$key_tree/gitsetu-v2/state/profiles.conf" || return 1
    _adv_tar_tree "$key_tree" "$key_archive" || return 1
    _adv_expect_restore_rejected "authenticated key path outside source HOME" "$key_archive" || return 1

    rm -rf "$dir_tree"
    _adv_build_payload_tree "$dir_tree" || return 1
    {
        test_v2_registry_header
        test_v2_registry_line global "$external_dir" github.com 0 \
            "$_ADV_SOURCE_HOME/.ssh/id_ed25519_global" fixture-user
    } > "$dir_tree/gitsetu-v2/state/profiles.conf" || return 1
    _adv_tar_tree "$dir_tree" "$dir_archive" || return 1
    _adv_expect_restore_rejected "authenticated profile directory outside source HOME" "$dir_archive"
}

test_vault_adversarial_rejects_envelope_mutations() {
    local tree="$_ADV_WORK/mutation-tree"
    local base_archive="$_ADV_WORK/mutation-base.tar.gz"
    local base_vault="$_ADV_WORK/mutation-base.vault"
    local mutation="${_ADV_PENDING_MUTATION:-}"
    local mutated="$_ADV_WORK/mutated.vault"
    local context="authenticated envelope mutation: $mutation"
    local expected=1

    rm -rf "$tree"
    _adv_build_payload_tree "$tree" || return 1
    _adv_tar_tree "$tree" "$base_archive" || return 1
    if [[ ! -f "$base_vault" ]]; then
        _adv_write_authenticated_envelope "$base_archive" "$base_vault" || return 1
    fi
    case "$mutation" in
        magic)
            _adv_replace_header_line "$base_vault" "$mutated" 1 'GITSETU_VAULT_V1' || return 1
            ;;
        algorithm)
            _adv_replace_header_line "$base_vault" "$mutated" 4 'cipher=aes-256-cbc' || return 1
            ;;
        salt)
            _adv_replace_header_line "$base_vault" "$mutated" 6 \
                'kdf_salt=ffffffffffffffffffffffffffffffff' || return 1
            ;;
        tag)
            _adv_replace_header_line "$base_vault" "$mutated" 9 \
                'tag=0000000000000000000000000000000000000000000000000000000000000000' || return 1
            ;;
        length)
            local actual_length
            actual_length=$(sed -n 's/^payload_length=//p' "$base_vault" | head -n 1) || return 1
            _adv_replace_header_line "$base_vault" "$mutated" 10 \
                "payload_length=$((actual_length + 1))" || return 1
            ;;
        payload)
            _adv_flip_ciphertext_byte "$base_vault" "$mutated" || return 1
            ;;
        append)
            cp -f "$base_vault" "$mutated" || return 1
            printf '%s' 'x' >> "$mutated" || return 1
            ;;
        truncate)
            local size
            size=$(_vault_file_size "$base_vault") || return 1
            head -c "$((size - 1))" "$base_vault" > "$mutated" || return 1
            ;;
        password)
            cp -f "$base_vault" "$mutated" || return 1
            GITSETU_TEST_VAULT_PASS='wrong-fixture-password' \
                cmd_restore "$mutated" >/dev/null 2>&1 || expected=$?
            _adv_reset_live_target
            ;;
        *)
            printf '    FAIL: unknown envelope mutation: %s\n' "$mutation" >&2
            return 1
            ;;
    esac

    if [[ "$mutation" == "password" ]]; then
        _adv_reset_live_target
        if [[ "$expected" -ne 1 ]]; then
            printf '    FAIL: wrong password should be rejected (got %s)\n' "$expected"
            mark_test_failure
            return 1
        fi
        _adv_assert_live_untouched "$context" || return 1
        return 0
    fi
    _adv_expect_restore_rejected "$context" "$mutated"
}

test_vault_adversarial_rejects_count_and_size_boundaries() {
    local tree="$_ADV_WORK/count-tree"
    local exact_archive="$_ADV_WORK/count-exact.tar.gz"
    local over_archive="$_ADV_WORK/count-over.tar.gz"
    local list_dir="$_ADV_WORK/count-list"
    local base_count needed i status=0
    local size_tree="$_ADV_WORK/size-tree"
    local size_archive="$_ADV_WORK/size.tar.gz"

    rm -rf "$tree" "$list_dir"
    mkdir -p "$list_dir"
    _adv_build_payload_tree "$tree" || return 1
    base_count=$(find "$tree/gitsetu-v2" -print | wc -l | tr -d '[:space:]') || return 1
    needed=$((GITSETU_VAULT_MAX_MEMBERS - base_count))
    [[ "$needed" -ge 0 ]] || return 1
    for (( i=0; i<needed; i++ )); do
        : > "$tree/gitsetu-v2/state/profiles/boundary$(printf '%04d' "$i").gitconfig" || return 1
    done
    _adv_tar_tree "$tree" "$exact_archive" || return 1
    _vault_validate_archive_listing "$exact_archive" "$list_dir" || {
        printf '    FAIL: archive at the exact member limit was rejected by listing validation\n'
        mark_test_failure
        return 1
    }

    : > "$tree/gitsetu-v2/state/profiles/one-too-many.gitconfig" || return 1
    _adv_tar_tree "$tree" "$over_archive" || return 1
    _adv_expect_restore_rejected "authenticated archive above the member limit" "$over_archive" || return 1

    rm -rf "$size_tree"
    _adv_build_payload_tree "$size_tree" || return 1
    if ! truncate -s "$((GITSETU_VAULT_MAX_MEMBER_BYTES + 1))" \
        "$size_tree/gitsetu-v2/state/profiles/oversize.gitconfig" 2>/dev/null; then
        skip_test "member-size boundary rejection" "filesystem cannot create a sparse boundary fixture"
        return 0
    fi
    _adv_tar_tree "$size_tree" "$size_archive" || return 1
    _adv_expect_restore_rejected "authenticated member above the byte limit" "$size_archive" || return 1

    # A 256 MiB+1 archive and exact-limit successes are intentionally omitted:
    # they add large temporary I/O without testing a distinct parser boundary.
    [[ "$status" -eq 0 ]]
}

printf '\n%btest_vault_adversarial.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "authenticated v2 adversarial baseline is valid" \
    test_vault_adversarial_authenticated_baseline_is_valid
run_test "traversal and absolute archive paths are rejected" \
    test_vault_adversarial_rejects_traversal_and_absolute_members
run_test "duplicate archive members are rejected" \
    test_vault_adversarial_rejects_duplicate_members
run_test "duplicate private and public destinations are rejected" \
    test_vault_adversarial_rejects_duplicate_restore_destinations
run_test "symlink archive members are rejected" \
    test_vault_adversarial_rejects_symlink_member
run_test "hardlink archive members are rejected" \
    test_vault_adversarial_rejects_hardlink_member
run_test "FIFO archive members are rejected" \
    test_vault_adversarial_rejects_fifo_member
run_test "unmanifested files and malformed manifests are rejected" \
    test_vault_adversarial_rejects_unmanifested_and_malformed_payloads
run_test "nonportable registry paths are rejected" \
    test_vault_adversarial_rejects_nonportable_registry_paths

for _mutation in magic algorithm salt tag length payload append truncate password; do
    case "$_mutation" in
        magic) _description="magic header mutation" ;;
        algorithm) _description="algorithm header mutation" ;;
        salt) _description="KDF salt header mutation" ;;
        tag) _description="authentication tag mutation" ;;
        length) _description="declared length mutation" ;;
        payload) _description="ciphertext payload mutation" ;;
        append) _description="appended payload mutation" ;;
        truncate) _description="truncated payload mutation" ;;
        password) _description="wrong password rejection" ;;
    esac
    _ADV_PENDING_MUTATION="$_mutation"
    run_test "$_description is rejected before mutation" \
        test_vault_adversarial_rejects_envelope_mutations
done
unset _ADV_PENDING_MUTATION _mutation _description

run_test "member-count and member-size boundaries fail closed" \
    test_vault_adversarial_rejects_count_and_size_boundaries

print_results "Adversarial vault tests"
