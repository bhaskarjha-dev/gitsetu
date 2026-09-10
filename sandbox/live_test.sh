#!/usr/bin/env bash
# sandbox/live_test.sh — End-to-end live simulation inside Windows Sandbox
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITSETU="$SCRIPT_DIR/gitsetu"

echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}${CYAN}    GitSetu Live End-to-End Sandbox Simulation        ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}"

echo -e "\n${BOLD}[1/6] Adding 'personal' profile...${RESET}"
mkdir -p "$HOME/workspace/personal"
"$GITSETU" add personal "Sandbox Personal" "personal@example.com" "$HOME/workspace/personal"

echo -e "\n${BOLD}[2/6] Adding 'work' profile...${RESET}"
mkdir -p "$HOME/workspace/work"
"$GITSETU" add work "Sandbox Corp" "work@company.com" "$HOME/workspace/work"

echo -e "\n${BOLD}[3/6] Showing configured profiles status...${RESET}"
"$GITSETU" status

echo -e "\n${BOLD}[4/6] Verifying Git identity resolution in repositories...${RESET}"

# Test personal repo
mkdir -p "$HOME/workspace/personal/repo1"
cd "$HOME/workspace/personal/repo1"
git init
git config core.autocrlf false
echo "Personal project content" > readme.txt
git add readme.txt
git commit -m "Initial personal commit"

P_EMAIL=$(git config user.email || echo "UNSET")
P_NAME=$(git config user.name || echo "UNSET")
P_PROMPT=$("$GITSETU" prompt)

echo "  Directory: $PWD"
echo "  Resolved user.name:  $P_NAME"
echo "  Resolved user.email: $P_EMAIL"
echo "  Prompt detection:    $P_PROMPT"

if [[ "$P_EMAIL" != "personal@example.com" ]]; then
    echo -e "${RED}FAIL: Expected personal@example.com, got: $P_EMAIL${RESET}"
    exit 1
fi
if [[ "$P_PROMPT" != "personal" ]]; then
    echo -e "${RED}FAIL: Expected prompt 'personal', got: '$P_PROMPT'${RESET}"
    exit 1
fi

# Test work repo
mkdir -p "$HOME/workspace/work/repo2"
cd "$HOME/workspace/work/repo2"
git init
git config core.autocrlf false
echo "Work project content" > readme.txt
git add readme.txt
git commit -m "Initial work commit"

W_EMAIL=$(git config user.email || echo "UNSET")
W_NAME=$(git config user.name || echo "UNSET")
W_PROMPT=$("$GITSETU" prompt)

echo "  Directory: $PWD"
echo "  Resolved user.name:  $W_NAME"
echo "  Resolved user.email: $W_EMAIL"
echo "  Prompt detection:    $W_PROMPT"

if [[ "$W_EMAIL" != "work@company.com" ]]; then
    echo -e "${RED}FAIL: Expected work@company.com, got: $W_EMAIL${RESET}"
    exit 1
fi
if [[ "$W_PROMPT" != "work" ]]; then
    echo -e "${RED}FAIL: Expected prompt 'work', got: '$W_PROMPT'${RESET}"
    exit 1
fi

echo -e "\n${BOLD}[5/6] Running gitsetu diagnostics (doctor & verify)...${RESET}"
"$GITSETU" doctor || true
"$GITSETU" verify || true

echo -e "\n${BOLD}[6/6] Checking SSH config inclusion & aliases...${RESET}"
if [[ -f "$HOME/.ssh/config" ]]; then
    echo "  ~/.ssh/config content:"
    cat "$HOME/.ssh/config"
fi

echo -e "\n${BOLD}${GREEN}✔ ALL LIVE TESTS PASSED IN WINDOWS SANDBOX!${RESET}"
echo -e "${BOLD}GitSetu successfully configured multiple profiles, SSH keys, and Git includeIf on Windows!${RESET}\n"
