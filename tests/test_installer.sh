#!/usr/bin/env bash
# Regression tests for the pinned installer/uninstaller contract.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_posix_pinned_installer() {
    local sandbox root artifact digest output
    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/gitsetu-installer-test.XXXXXX")"
    root="$sandbox/install"
    artifact="$sandbox/gitsetu"
    mkdir -p "$sandbox/home"

    if ! bash "$REPO_ROOT/scripts/bundle.sh" "$artifact" >/dev/null 2>&1; then
        rm -rf -- "$sandbox"
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "$artifact" | cut -d' ' -f1)"
    else
        digest="$(shasum -a 256 "$artifact" | cut -d' ' -f1)"
    fi

    if ! output="$(HOME="$sandbox/home" GITSETU_TEST_MODE=1 \
        GITSETU_TEST_ARTIFACT="$artifact" GITSETU_TEST_ARTIFACT_SHA256="$digest" \
        GITSETU_INSTALL_DIR="$root" GITSETU_TEST_BIN_DIR="$root/bin" \
        bash "$REPO_ROOT/install.sh" 2>&1)"; then
        printf 'installer failed: %s\n' "$output" >&2
        rm -rf -- "$sandbox"
        return 1
    fi
    [[ -x "$root/bin/gitsetu" && -x "$root/bin/git-setu" && -f "$root/install.marker" ]] || {
        rm -rf -- "$sandbox"
        return 1
    }
    [[ "$("$root/bin/gitsetu" --version 2>&1)" == *"gitsetu v1.1.0"* ]] || {
        rm -rf -- "$sandbox"
        return 1
    }

    # Reinstallation is an atomic pointer update over the same verified bytes.
    HOME="$sandbox/home" GITSETU_TEST_MODE=1 \
        GITSETU_TEST_ARTIFACT="$artifact" GITSETU_TEST_ARTIFACT_SHA256="$digest" \
        GITSETU_INSTALL_DIR="$root" GITSETU_TEST_BIN_DIR="$root/bin" \
        bash "$REPO_ROOT/install.sh" >/dev/null 2>&1 || {
        rm -rf -- "$sandbox"
        return 1
    }

    if ! HOME="$sandbox/home" GITSETU_TEST_MODE=1 GITSETU_INSTALL_DIR="$root" \
        GITSETU_TEST_BIN_DIR="$root/bin" bash "$REPO_ROOT/uninstall.sh" --force >/dev/null 2>&1; then
        rm -rf -- "$sandbox"
        return 1
    fi
    [[ ! -e "$root" ]] || {
        rm -rf -- "$sandbox"
        return 1
    }
    rm -rf -- "$sandbox"
    return 0
}

test_windows_delegates_to_powershell_suite() {
    if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || "${OSTYPE:-}" == win* ]]; then
        return 0
    fi
    skip_test "Windows installer contract" "covered by test_powershell_installer_e2e.ps1 on Windows"
    return 0
}

printf '\n%btest_installer.sh%b\n' "$T_BOLD" "$T_RESET"
run_test "pinned POSIX installer and marker-verified uninstaller" test_posix_pinned_installer
run_test "Windows installer suite routing" test_windows_delegates_to_powershell_suite
print_results "Installer pipeline tests"
