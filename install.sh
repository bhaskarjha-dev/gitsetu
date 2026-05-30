#!/usr/bin/env bash
# GitSetu Installer
#
# Clones the GitSetu repository to ~/.local/share/gitsetu
# and symlinks the executable to ~/.local/bin/gitsetu.
#
# Usage: curl -sL https://raw.githubusercontent.com/bhaskarjha-com/gitsetu/main/install.sh | bash

set -euo pipefail

REPO_URL="${GITSETU_REPO_URL:-https://github.com/bhaskarjha-com/gitsetu.git}"
SHARE_DIR="$HOME/.local/share/gitsetu"
BIN_DIR="$HOME/.local/bin"

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

# Prerequisite checks
if [[ -z "${HOME:-}" ]]; then
    die "HOME is not set. Please run the installer from a normal user shell."
fi

if ! command -v git >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: git is required to install GitSetu, but it was not found in PATH.

Install Git first, then rerun the installer:
  Debian/Ubuntu: sudo apt update && sudo apt install -y git
  Fedora:        sudo dnf install -y git
  Arch:          sudo pacman -S git
EOF
    exit 1
fi

# UI Helpers
BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "\n${BOLD}--- Installing GitSetu ---${RESET}\n"

# 1. Clone or update repository
if [[ -d "$SHARE_DIR/.git" ]]; then
    echo -e "  Updating existing installation at ${CYAN}$SHARE_DIR${RESET}..."
    cd "$SHARE_DIR" || die "could not enter existing installation at $SHARE_DIR"
    if ! git fetch --quiet origin; then
        die "could not fetch updates from origin. Check your internet connection and GitHub access, then rerun the installer."
    fi
    if ! git reset --quiet --hard origin/main; then
        die "could not update the local GitSetu checkout to origin/main."
    fi
else
    if [[ -e "$SHARE_DIR" ]]; then
        cat >&2 <<EOF
Error: $SHARE_DIR already exists but is not a GitSetu git checkout.

Move or remove that directory, then rerun the installer:
  mv "$SHARE_DIR" "${SHARE_DIR}.backup"
EOF
        exit 1
    fi

    echo -e "  Cloning repository to ${CYAN}$SHARE_DIR${RESET}..."
    mkdir -p "$HOME/.local/share" || die "could not create $HOME/.local/share"
    if ! git clone --quiet "$REPO_URL" "$SHARE_DIR"; then
        die "could not clone $REPO_URL. Check your internet connection and GitHub access, then rerun the installer."
    fi
fi

chmod +x "$SHARE_DIR/gitsetu" || die "could not make $SHARE_DIR/gitsetu executable"

# 2. Setup symlinks
echo -e "  Configuring executables in ${CYAN}$BIN_DIR${RESET}..."
mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    # MSYS2/Cygwin often fall back to copying files instead of symlinking if Windows Developer Mode
    # is off. A copied gitsetu binary fails to locate its lib/ directory. Use a wrapper instead.
    echo '#!/usr/bin/env bash' > "$BIN_DIR/gitsetu"
    echo "exec \"$SHARE_DIR/gitsetu\" \"\$@\"" >> "$BIN_DIR/gitsetu"
    chmod +x "$BIN_DIR/gitsetu"
    cp "$BIN_DIR/gitsetu" "$BIN_DIR/git-setu"
else
    ln -sf "$SHARE_DIR/gitsetu" "$BIN_DIR/gitsetu" || die "could not create $BIN_DIR/gitsetu"
    ln -sf "$SHARE_DIR/gitsetu" "$BIN_DIR/git-setu" || die "could not create $BIN_DIR/git-setu"
fi

echo -e "\n  ${GREEN}[OK] GitSetu successfully installed!${RESET}"

# 3. Path Warning
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "\n  ${BOLD}Warning:${RESET} $BIN_DIR is not in your PATH."
    echo -e "  Please add the following line to your ~/.bashrc or ~/.zshrc:"
    echo -e "    ${CYAN}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
fi

echo -e "\n  You can now run '${BOLD}gitsetu setup${RESET}' to begin bootstrapping your identity."
echo ""
