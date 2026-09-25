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

# Establish a valid global identity before adding mapped profiles. The current
# strict-v2 contract requires the first registry record to be a complete global
# profile; a clean Sandbox HOME must not be treated as an implicit fixture.
if [[ ! -f "$HOME/.config/gitsetu/profiles.conf" ]]; then
    git config --global user.name "Sandbox User"
    git config --global user.email "sandbox@example.invalid"
    "$GITSETU" setup --auto
fi

echo -e "\n${BOLD}[1/6] Adding 'personal' profile...${RESET}"
mkdir -p "$HOME/workspace/personal"
"$GITSETU" add personal "Sandbox Personal" "personal@example.com" "$HOME/workspace/personal"

echo -e "\n${BOLD}[2/6] Adding 'work' profile...${RESET}"
mkdir -p "$HOME/workspace/work"
"$GITSETU" add work "Sandbox Corp" "work@company.com" "$HOME/workspace/work"

# Assert the state the later phases claim to exercise.
for key in id_ed25519_global id_ed25519_personal id_ed25519_work; do
    if [[ ! -f "$HOME/.ssh/$key" || ! -f "$HOME/.ssh/$key.pub" ]]; then
        echo -e "${RED}FAIL: expected SSH key pair is missing: $key${RESET}" >&2
        exit 1
    fi
done

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
doctor_status=0
verify_status=0
"$GITSETU" doctor || doctor_status=$?
"$GITSETU" verify || verify_status=$?
if [[ "$doctor_status" -ne 0 || "$verify_status" -ne 0 ]]; then
    echo -e "${RED}FAIL: doctor/verify returned doctor=$doctor_status verify=$verify_status${RESET}" >&2
    exit 1
fi

echo -e "\n${BOLD}[6/6] Checking SSH config inclusion & aliases...${RESET}"
if [[ ! -f "$HOME/.ssh/config" ]]; then
    echo -e "${RED}FAIL: SSH config was not created${RESET}" >&2
    exit 1
fi
for alias in github-global github-personal github-work; do
    if ! grep -q "Host $alias" "$HOME/.ssh/config" && ! grep -q "Host $alias" "$HOME/.config/gitsetu/profiles/ssh_config" 2>/dev/null; then
        echo -e "${RED}FAIL: expected SSH alias is missing: $alias${RESET}" >&2
        exit 1
    fi
done

echo "  ~/.ssh/config content:"
cat "$HOME/.ssh/config"

echo -e "\n${BOLD}${GREEN}✔ ALL LIVE TESTS PASSED IN WINDOWS SANDBOX!${RESET}"
echo -e "${BOLD}GitSetu successfully configured multiple profiles, SSH keys, and Git includeIf on Windows!${RESET}\n"
