#!/usr/bin/env bash
# GitSetu Uninstaller
#
# Removes the ~/.local/share/gitsetu directory and symlinks.
#
# Usage: curl -sL https://raw.githubusercontent.com/bhaskarjha-dev/gitsetu/main/uninstall.sh | bash

set -euo pipefail

SHARE_DIR="$HOME/.local/share/gitsetu"
BIN_DIR="$HOME/.local/bin"

BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

echo -e "\n${BOLD}─── Uninstalling GitSetu ───${RESET}\n"

# Check if user wants to teardown configs first
echo -e "  ${BOLD}Wait!${RESET} If you have active GitSetu configurations in your global ~/.gitconfig,"
echo -e "  you should run ${CYAN}gitsetu teardown --deep${RESET} before proceeding to remove them safely."
echo ""
if [[ -n "${CI:-}" ]] || [[ ! -t 0 ]]; then
    echo "  Non-interactive environment detected. Proceeding..."
else
    echo -n "  Are you sure you want to remove the GitSetu executables? [y/N] "
    read -r response </dev/tty || true
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "  ${RED}Uninstallation aborted.${RESET}\n"
        exit 0
    fi
fi

# 1. Remove symlinks
echo -e "\n  Removing executables from ${CYAN}$BIN_DIR${RESET}..."
rm -f "$BIN_DIR/gitsetu"
rm -f "$BIN_DIR/git-setu"

# 2. Remove repository
if [[ -d "$SHARE_DIR" ]]; then
    echo -e "  Removing cloned repository at ${CYAN}$SHARE_DIR${RESET}..."
    rm -rf "$SHARE_DIR"
fi

echo -e "\n  ${GREEN}✓ GitSetu has been successfully removed.${RESET}"
echo -e "  (Note: Your generated ~/.ssh/id_ed25519_* keys were NOT deleted for safety)\n"
