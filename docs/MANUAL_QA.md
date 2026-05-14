# GitSetu Manual QA Playbook

A step-by-step integration test checklist for verifying that every GitSetu feature works on a real machine. Run this before every release to ensure the README claims are true.

> **Prerequisites:** A machine with `bash`, `git`, and `ssh-keygen`. Two GitHub/GitLab accounts are ideal but not required — you can verify most features with one account.

---

## Pre-Flight

- [ ] Fresh terminal session (no leftover env vars from previous runs)
- [ ] Confirm bash version: `bash --version` (must be 3.2+)
- [ ] Confirm git version: `git --version`
- [ ] Confirm ssh-keygen exists: `which ssh-keygen`

---

## 1. Installation

> Verifies: README "Install" section

```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-com/gitsetu/main/install.sh | bash
```

- [ ] Installer completes without errors
- [ ] `~/.local/share/gitsetu/` directory exists
- [ ] `gitsetu` command is available: `gitsetu --help`
- [ ] `git setu` alias works: `git setu --help`

---

## 2. Interactive Setup

> Verifies: `gitsetu setup` wizard, SSH key generation, gitconfig injection

```bash
gitsetu setup
# Create profile "personal" with your personal email and ~/personal directory
# Create profile "work" with your work email and ~/work directory
```

- [ ] Wizard prompts for label, name, email, directory
- [ ] Wizard prompts for SSH key type (ED25519 default)
- [ ] SSH keypair generated: `ls ~/.ssh/id_ed25519_personal*` (private + .pub)
- [ ] SSH keypair generated: `ls ~/.ssh/id_ed25519_work*` (private + .pub)
- [ ] Key permissions are 600: `stat -c %a ~/.ssh/id_ed25519_personal` (or `stat -f %Lp` on macOS)
- [ ] `~/.gitconfig` contains `includeIf` block: `grep -A2 'includeIf' ~/.gitconfig`
- [ ] Profile gitconfig exists: `cat ~/.config/gitsetu/profiles/personal.gitconfig`
- [ ] SSH config has Include directive: `grep 'Include' ~/.ssh/config`
- [ ] Isolated SSH config has host alias: `grep -A3 'Host github-personal' ~/.config/gitsetu/ssh_config`
- [ ] Registry file exists: `cat ~/.config/gitsetu/profiles.conf`

---

## 3. Headless Add (Non-Interactive)

> Verifies: `gitsetu add` CLI mode

```bash
gitsetu add freelance "Your Name" freelance@example.com ~/freelance
```

- [ ] Command exits cleanly
- [ ] SSH key generated: `ls ~/.ssh/id_ed25519_freelance*`
- [ ] Profile appears in registry: `grep freelance ~/.config/gitsetu/profiles.conf`
- [ ] `~/.gitconfig` has new `includeIf` for `~/freelance/`

---

## 4. Status

> Verifies: `gitsetu status` display, active identity detection

```bash
cd ~/work && mkdir -p test-repo && cd test-repo && git init
gitsetu status
```

- [ ] All profiles listed with label, email, directory
- [ ] Active profile shows ✓ checkmark
- [ ] Correct profile is active for current directory

---

## 5. Directory-Scoped Identity (The "Magical Clone")

> Verifies: `includeIf` auto-switching (core README claim)

```bash
# In work directory
cd ~/work/test-repo
git config user.email   # Should show work email
git config user.name    # Should show work name

# In personal directory
cd ~/personal && mkdir -p test-repo && cd test-repo && git init
git config user.email   # Should show personal email
git config user.name    # Should show personal name
```

- [ ] Work directory returns work email
- [ ] Personal directory returns personal email
- [ ] No manual switching required

---

## 6. Identity Guard (Pre-Commit Hook)

> Verifies: `gitsetu guard` blocks wrong-identity commits

```bash
gitsetu guard --install
```

- [ ] Guard installs without errors
- [ ] `git config --global core.hooksPath` returns a valid path

```bash
# Force a mismatch
cd ~/work/test-repo
git config user.email "wrong@email.com"  # local override
echo "test" > testfile.txt && git add .
git commit -m "test"
```

- [ ] Commit is BLOCKED with "Identity mismatch detected!"
- [ ] Error shows expected vs actual email

```bash
# Fix and retry
git config --unset user.email
git commit -m "test"
```

- [ ] Commit succeeds with correct identity
- [ ] `git log --format="%ae" -1` shows work email

---

## 7. Shell Prompt Integration

> Verifies: `gitsetu prompt` output and speed

```bash
cd ~/work && gitsetu prompt    # Should output "[work]" or similar
cd ~/personal && gitsetu prompt # Should output "[personal]"
cd /tmp && gitsetu prompt       # Should output nothing (no profile)
```

- [ ] Output matches active profile for current directory
- [ ] Empty output when outside any profile directory
- [ ] Execution is fast (no visible lag)

**Speed test:**
```bash
time (for i in $(seq 100); do gitsetu prompt > /dev/null; done)
```

- [ ] 100 invocations complete in under 1 second

---

## 8. Credential Broker (HTTPS PATs)

> Verifies: `gitsetu credential` store/get/erase cycle

```bash
# During setup, provide a GitHub username and PAT when prompted
# Or manually test with dummy credentials:

printf 'protocol=https\nhost=github.com\nusername=testuser\npassword=ghp_test123\n\n' | gitsetu credential store

printf 'protocol=https\nhost=github.com\n\n' | gitsetu credential get
```

- [ ] `credential store` exits cleanly (no hang, no error)
- [ ] `credential get` returns `username=testuser` and `password=ghp_test123`
- [ ] Credentials stored in OS keychain (macOS: check Keychain Access; Linux: `secret-tool search service gitsetu`)
  - OR in file fallback: `cat ~/.config/gitsetu/.tokens`

```bash
printf 'protocol=https\nhost=github.com\nusername=testuser\npassword=ghp_test123\n\n' | gitsetu credential erase
printf 'protocol=https\nhost=github.com\n\n' | gitsetu credential get
```

- [ ] `credential erase` exits cleanly
- [ ] `credential get` returns empty (credentials removed)

---

## 9. Shell Autocompletion

> Verifies: TAB completion

```bash
source ~/.local/share/gitsetu/lib/completion.sh
gitsetu <TAB><TAB>
```

- [ ] Completion script sources without errors
- [ ] Subcommands are listed on TAB (setup, add, remove, status, etc.)
- [ ] Profile names complete on `gitsetu remove <TAB>`

---

## 10. Encrypted Backup & Restore

> Verifies: `gitsetu backup` / `gitsetu restore` lifecycle

```bash
gitsetu backup ~/test-vault.enc
# Enter encryption password when prompted
```

- [ ] Vault file created: `ls -la ~/test-vault.enc`
- [ ] File is encrypted (not readable): `file ~/test-vault.enc`

```bash
# Simulate restore on "new machine" by wiping config
mv ~/.config/gitsetu ~/.config/gitsetu-bak
gitsetu restore ~/test-vault.enc
# Enter same password
```

- [ ] Restore completes without errors
- [ ] Profiles restored: `gitsetu status`
- [ ] Registry matches original: `diff ~/.config/gitsetu/profiles.conf ~/.config/gitsetu-bak/profiles.conf`

```bash
# Cleanup
rm -rf ~/.config/gitsetu-bak ~/test-vault.enc
```

---

## 11. Profile Removal

> Verifies: `gitsetu remove` cleanup

```bash
gitsetu remove freelance
```

- [ ] Profile removed from registry: `grep freelance ~/.config/gitsetu/profiles.conf` (should return nothing)
- [ ] `includeIf` block removed from `~/.gitconfig`
- [ ] SSH host alias removed from `~/.config/gitsetu/ssh_config`
- [ ] SSH keys preserved on disk: `ls ~/.ssh/id_ed25519_freelance*` (still exists)

---

## 12. Idempotency

> Verifies: Safe to run multiple times (core claim)

```bash
gitsetu setup
# Re-add the same profiles with same settings
```

- [ ] No errors, no duplicates
- [ ] `~/.gitconfig` has exactly ONE `includeIf` per profile (not duplicated)
- [ ] `~/.config/gitsetu/ssh_config` has exactly ONE host block per profile
- [ ] SSH keys are NOT overwritten (prompted to skip/keep)

---

## 13. Doctor

> Verifies: `gitsetu doctor` diagnostic tool

```bash
gitsetu doctor
```

- [ ] All checks pass on a healthy setup
- [ ] Output goes to stderr (not stdout): `gitsetu doctor > /dev/null` (should still see output)

---

## 14. Verify

> Verifies: `gitsetu verify` infrastructure check

```bash
gitsetu verify
```

- [ ] SSH key existence and permissions verified
- [ ] Git config verified
- [ ] All checks report OK

---

## 15. Teardown & Uninstall

> Verifies: Clean removal (README "Uninstallation" section)

```bash
gitsetu teardown
```

- [ ] Managed blocks removed from `~/.gitconfig`
- [ ] Include directive removed from `~/.ssh/config`
- [ ] Custom user content in both files preserved
- [ ] SSH keys intentionally preserved

```bash
gitsetu teardown --deep
```

- [ ] Local repo identity overrides also cleaned

```bash
curl -sL https://raw.githubusercontent.com/bhaskarjha-com/gitsetu/main/uninstall.sh | bash
```

- [ ] `~/.local/share/gitsetu/` removed
- [ ] `gitsetu` symlink removed
- [ ] `git setu` no longer works

---

## 16. Cross-Platform Spot Checks

> Run on each supported platform if available

### macOS
- [ ] `detect_os` returns `macos`
- [ ] Credential broker uses `security` (Keychain)
- [ ] SSH key generation works with macOS `ssh-keygen`

### Linux
- [ ] `detect_os` returns `linux`
- [ ] Credential broker uses `secret-tool` or file fallback
- [ ] SSH key generation works

### Windows (Git Bash)
- [ ] `detect_os` returns `gitbash`
- [ ] CRLF self-healing activates (check for `\r` in config files)
- [ ] `safe.directory` rules injected for shared mounts

### WSL
- [ ] `detect_os` returns `wsl`
- [ ] Correctly distinguishes from native Linux

---

## Release Checklist

After all manual tests pass:

- [ ] `make test` — all 168 automated tests pass
- [ ] `make lint` — ShellCheck clean
- [ ] CHANGELOG.md updated
- [ ] Version bumped in `gitsetu` (if applicable)
- [ ] README claims match actual behavior
- [ ] Tag and release
