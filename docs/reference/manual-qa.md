# GitSetu Manual QA Playbook

A step-by-step integration test checklist for verifying that every GitSetu feature works on a real machine. Run this before every release to ensure the README claims are true.

> **Release-state boundary:** This checklist validates the current v1.1.0
> publication-ready release candidate. It does not authorize publication. A
> public release requires a clean source commit, immutable tag, detached
> release manifest, signed artifacts, provenance, and a separately reviewed
> publish-only workflow as described in `packaging/README.md`.

> **Prerequisites:** A machine with `bash`, `git`, and `ssh-keygen`. On
> Windows, install Git for Windows so the native PowerShell installer and the
> `gitsetu`/`git-setu` shims can find trusted `git.exe` and `bash.exe`. Two
> GitHub/GitLab accounts are ideal but not required — you can verify most
> features with one account.

---

## Pre-Flight

- [ ] Fresh terminal session (no leftover env vars from previous runs)
- [ ] Confirm bash version: `bash --version` (must be 3.2+)
- [ ] Confirm git version: `git --version`
- [ ] Confirm ssh-keygen exists: `which ssh-keygen`

> **Format note:** The current profile registry and vault format are v2-only. Do not use old colon-delimited registries or unauthenticated/CBC vaults as test fixtures; they must be rejected.

---

## 1. Installation

> Verifies: README "Install" section

### macOS & Linux (POSIX Bash)
From a reviewed checkout or verified release artifact:
```bash
bash install.sh
```

- [ ] Installer completes without errors
- [ ] `~/.local/share/gitsetu/` directory exists
- [ ] `gitsetu` command is available: `gitsetu --help`
- [ ] The hyphenated executable works: `git-setu --help`; a Git installation
      may also resolve it through Git's external-command lookup as
      `git setu --help`

### Windows (PowerShell)
From a reviewed checkout or verified release artifact:
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

- [ ] Installer completes without errors
- [ ] `%LOCALAPPDATA%\gitsetu\` is the installation root, with `bin\` and
      `releases\`
- [ ] `%LOCALAPPDATA%\gitsetu\bin\gitsetu.cmd` and `gitsetu.ps1` exist
- [ ] `%LOCALAPPDATA%\gitsetu\bin\git-setu.cmd` and `git-setu.ps1` exist
- [ ] `%LOCALAPPDATA%\gitsetu\current.txt` points to the current versioned
      release directory
- [ ] `gitsetu --version` prints exactly `gitsetu v1.1.0` (it does not print
      a release channel)
- [ ] `git-setu --version` prints the same line in PowerShell, CMD, and
      Windows Terminal

> **Windows layout:** `%LOCALAPPDATA%\gitsetu` contains the installed
> executables and versioned releases; it is not GitSetu's managed state
> directory. The native launcher invokes Git for Windows and, by default,
> managed state is under `%USERPROFILE%\.config\gitsetu` (or an explicit
> `XDG_CONFIG_HOME`). For QA, keep these locations distinct:
>
> ```powershell
> $GitSetuInstall = Join-Path $env:LOCALAPPDATA 'gitsetu'
> $GitSetuState   = Join-Path $env:USERPROFILE '.config\gitsetu'
> ```
>
> Use Git Bash for the Bash examples below; do not interpret PowerShell `~`
> paths as the native installation layout.

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
- [ ] Isolated SSH config has host alias: `grep -A3 'Host github-personal' ~/.config/gitsetu/profiles/ssh_config`
- [ ] Registry file exists and starts with the v2 header: `head -n 1 ~/.config/gitsetu/profiles.conf`

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
gitsetu status >status.stdout 2>status.stderr
```

- [ ] The report is written to stderr; `status.stdout` is empty
- [ ] Current directory, Git name/email, guard policy, and hook-path state
      are shown
- [ ] Configured profiles show label, email, provider, and path
- [ ] The active profile shows a checkmark when the current canonical
      directory matches; unmanaged repositories are explicitly fail-open
- [ ] No SSH alias inventory is claimed by `status`

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
cd ~/work && gitsetu prompt    # Should output: work
cd ~/personal && gitsetu prompt # Should output: personal
cd /tmp && gitsetu prompt       # Should output nothing (no mapped profile)
```

- [ ] Output matches active profile for current directory
- [ ] Empty output when outside any profile directory
- [ ] Execution is fast (no visible lag)

**Speed test:**
```bash
time (for i in $(seq 100); do gitsetu prompt > /dev/null; done)
```

- [ ] Record the measured result; no fixed latency guarantee is implied

---

## 8. Credential Broker (HTTPS PATs)

> Verifies: `gitsetu credential` store/get/erase cycle

```bash
# During setup, provide a GitHub username and PAT when prompted.
# Or test the native backend with a disposable value:

printf 'protocol=https\nhost=github.com\nusername=testuser\npassword=dummy-token-not-a-secret\n\n' | gitsetu credential store
printf 'protocol=https\nhost=github.com\n\n' | gitsetu credential get
```

- [ ] `credential store` exits cleanly (no hang, no error)
- [ ] `credential get` returns `username=testuser` and
      `password=dummy-token-not-a-secret`
- [ ] With no explicit backend, the native store is used: macOS Keychain,
      Linux Secret Service, or Windows Git Credential Manager
- [ ] The native store is not silently replaced by a plaintext file
- [ ] Git's `path=` field is part of the exact credential tuple; verify empty,
      `/`, and a repository path do not cross-match
- [ ] `GITSETU_CREDENTIAL_PATH` explicitly overrides the protocol path for a
      wrapper or controlled test

To test the deliberately selected zero-dependency backend, opt in on the
GitSetu command (the environment assignment must be on the right side of the
pipe):

```bash
printf 'protocol=https\nhost=github.com\nusername=testuser\npassword=dummy-token-not-a-secret\n\n' \
  | GITSETU_CREDENTIAL_BACKEND=file gitsetu credential store
cat "${XDG_CONFIG_HOME:-$HOME/.config}/gitsetu/.tokens"
```

- [ ] The file backend warns that the store is plaintext
- [ ] Its directory is `0700`, its file is `0600`, and it is not described as
      encrypted or OS-keychain storage

After the file-backend check, clean up both the native test record and the
matching file-backend record:

```bash
printf 'protocol=https\nhost=github.com\nusername=testuser\npassword=dummy-token-not-a-secret\n\n' \
  | gitsetu credential erase
```

```bash
printf 'protocol=https\nhost=github.com\nusername=testuser\npassword=dummy-token-not-a-secret\n\n' \
  | GITSETU_CREDENTIAL_BACKEND=file gitsetu credential erase
printf 'protocol=https\nhost=github.com\n\n' \
  | GITSETU_CREDENTIAL_BACKEND=file gitsetu credential get
```

- [ ] `credential erase` exits cleanly for the selected backend
- [ ] `credential get` returns empty after the matching erase

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
gitsetu backup
# With no output argument, the v2 vault is created in the current directory:
# gitsetu_vault_YYYYMMDD_HHMMSS.gitsetu-v2.vault
# Enter a password of at least 12 characters when prompted.
```

- [ ] Exactly one new `gitsetu_vault_*.gitsetu-v2.vault` file is created in
      the current directory, and an existing path is not overwritten
- [ ] The file is an authenticated v2 vault, not the old CBC format
- [ ] The vault contains the v2 registry, profile configs, managed SSH state,
      registered key pairs, and any present hook/file-backend token state

To exercise the same lifecycle in Windows PowerShell, keep the installation
and state roots separate:

```powershell
$vault = Get-ChildItem -File -Filter 'gitsetu_vault_*.gitsetu-v2.vault' |
    Select-Object -First 1
$vault.FullName
$GitSetuState = Join-Path $env:USERPROFILE '.config\gitsetu'
```

```bash
# Git Bash restore simulation
mv "$HOME/.config/gitsetu" "$HOME/.config/gitsetu-bak"
gitsetu restore "$HOME"/gitsetu_vault_*.gitsetu-v2.vault
# Enter the same password
```

- [ ] Restore completes without errors and validates before replacing live
      state
- [ ] Profiles are restored: `gitsetu status`
- [ ] The registry matches the saved v2 registry (use `diff` in Bash or
      `Compare-Object` in PowerShell)
- [ ] A failed transaction is rolled back; if rollback is incomplete, only a
      private `.gitsetu-restore.*` directory with `RECOVERY_REQUIRED` remains
- [ ] No `gitsetu_vault_pre_restore_*.enc` or `.password` sidecar is created

```bash
# Cleanup after the test
rm -rf "$HOME/.config/gitsetu-bak" "$HOME"/gitsetu_vault_*.gitsetu-v2.vault
```

---

## 11. Profile Removal

> Verifies: `gitsetu remove` cleanup

```bash
gitsetu remove freelance
```

- [ ] Profile removed from registry: `grep freelance ~/.config/gitsetu/profiles.conf` (should return nothing)
- [ ] `includeIf` block removed from `~/.gitconfig`
- [ ] SSH host alias removed from `~/.config/gitsetu/profiles/ssh_config`
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
- [ ] `~/.config/gitsetu/profiles/ssh_config` has exactly ONE host block per profile
- [ ] SSH keys are NOT overwritten (prompted to skip/keep)

---

## 13. Doctor

> Verifies: `gitsetu doctor` diagnostic tool

```bash
gitsetu doctor >doctor.stdout 2>doctor.stderr
```

- [ ] All required offline checks pass on a healthy setup and the exit status
      is 0
- [ ] Output goes to stderr; stdout is empty
- [ ] A missing/invalid v2 registry, managed marker, SSH include/config, key,
      or effective identity produces a nonzero status
- [ ] The SSH-agent section is informational and no network request occurs
- [ ] `gitsetu doctor --repair --dry-run` previews repairs without taking the
      mutation lock or changing files

---

## 14. Verify

> Verifies: `gitsetu verify` infrastructure check

```bash
gitsetu verify >verify.stdout 2>verify.stderr
```

- [ ] stdout is empty and the report is on stderr
- [ ] Strict v2 registry, global/profile config, expected email, and effective
      author/committer identities are checked
- [ ] Private/public SSH key existence, ownership, permissions, and fingerprint
      correspondence are checked
- [ ] No hook-installation, SSH-agent, or network check is implied by default
- [ ] Required failures return nonzero; network verification is only run when
      explicitly requested with `GITSETU_VERIFY_NETWORK=1`

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
bash uninstall.sh
```

- [ ] `~/.local/share/gitsetu/` removed
- [ ] `gitsetu` symlink removed
- [ ] `git-setu` no longer works

On Windows, uninstall the native installation separately and keep its layout
in mind:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
$GitSetuInstall = Join-Path $env:LOCALAPPDATA 'gitsetu'
Test-Path $GitSetuInstall
```

- [ ] The versioned Windows installation and both `gitsetu`/`git-setu` shims
      are removed or reported as retained according to the uninstaller prompt
- [ ] Managed state under `%USERPROFILE%\.config\gitsetu` is not confused with
      the `%LOCALAPPDATA%` installation directory; run `gitsetu teardown` first
      when intentionally removing managed configuration

---

## 16. Cross-Platform Spot Checks

> Run on each supported platform if available

### macOS
- [ ] `detect_os` returns `macos`
- [ ] Credential broker uses `security` (Keychain)
- [ ] SSH key generation works with macOS `ssh-keygen`

### Linux
- [ ] `detect_os` returns `linux`
- [ ] Credential broker uses Secret Service by default; the plaintext file
      backend is used only when explicitly selected
- [ ] SSH key generation works

### Windows (Git Bash)
- [ ] `detect_os` returns `gitbash`
- [ ] CRLF self-healing activates (check for `\r` in config files)
- [ ] `safe.directory` rules injected for shared mounts
- [ ] The installation root is `%LOCALAPPDATA%\gitsetu` while managed state
      defaults to `%USERPROFILE%\.config\gitsetu` (or explicit
      `XDG_CONFIG_HOME`)
- [ ] PowerShell shims and Git Bash invocation both use the same versioned
      `gitsetu.exe`; `gitsetu` and `git-setu` are separate executable names

### WSL
- [ ] `detect_os` returns `wsl`
- [ ] Correctly distinguishes from native Linux

---

## Release Checklist

### Candidate validation

After all manual tests pass:

- [ ] `bash tests/run_all.sh` (or `make test` where `make` is available) — every required suite passes; explicit skips are documented
- [ ] Experimental Windows Sandbox verification — when available, record
      `COMPLETED_SUCCESS`, `COMPLETED_ENVIRONMENT_BLOCK`, or
      `COMPLETED_FAILURE`; it is supplemental while its legacy fixtures are
      being reconciled, and no terminal status is inconclusive
- [ ] `bash -n`/ShellCheck or the repository lint target passes
- [ ] `CHANGELOG.md`, README, installation, security, and packaging documents describe the same candidate state
- [ ] Website documentation is synchronized only from an immutable source commit
- [ ] Candidate artifacts are rebuilt and their hashes are recorded

### Public release gate

Do not mark the release public until all of these are complete:

- [ ] Create the clean release source commit and immutable annotated `v1.1.0` tag; do not put the tag commit's own hash in a tracked file
- [ ] Build the source archive and every exact artifact from the resolved source commit
- [ ] Generate the detached release manifest only after all asset bytes exist
- [ ] Sign and attest every primary asset and the manifest, then reverify signatures, checksums, and attestations
- [ ] Add and review a protected, publish-only workflow; the current preparation workflow must remain non-publishing
- [ ] Render package-manager manifests from the detached manifest without feeding generated digests back into hashed source inputs
- [ ] Convert the changelog entry to a dated public release with immutable links
- [ ] Synchronize and test the website from the immutable released source commit
- [ ] Publish only after the publish-only workflow verifies every asset and provenance record and resumes idempotently
