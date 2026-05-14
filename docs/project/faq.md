# Frequently Asked Questions

## General

**Why not just use `git config --local`?**
Local configuration requires manual intervention for every single repository you clone. It is error-prone. GitSetu automates this at the global routing layer, meaning you never have to remember to configure an identity again.

**Do I need Node.js or Python to run this?**
No. GitSetu is written entirely in POSIX-compliant Bash 3.2. It runs natively on your system without any package managers.

**Can I still use global Git aliases?**
Yes. GitSetu only manages the `[user]`, `[core]`, and `[credential]` blocks for its profiles. Your global `~/.gitconfig` aliases (`[alias]`) are completely untouched and will continue to work perfectly.

## Security

**Where are my credentials stored?**
HTTPS Personal Access Tokens are stored securely in your operating system's native keychain (macOS Keychain Access, or Linux Secret Service via `secret-tool`). They are never stored in plain-text on your filesystem unless you explicitly disable keychain support.

**Does GitSetu phone home?**
No. There is zero telemetry, analytics, or background daemon activity.

## Troubleshooting

**My pre-commit guard is blocking my commits. Why?**
The Identity Guard prevents you from committing if the email Git is about to use does not match the email assigned to the GitSetu profile for that directory. This usually happens if you manually ran `git config user.email` inside the local repository, overriding GitSetu. Remove the local override to fix this.

**I use Windows. Does this work in PowerShell?**
GitSetu is a Bash script. On Windows, it must be run within **Git Bash** or **Windows Subsystem for Linux (WSL)**.
