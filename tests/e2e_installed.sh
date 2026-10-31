#!/usr/bin/env bash
# tests/e2e_installed.sh — end-to-end checks of GitSetu as users run it.
# Every case runs in its own throwaway HOME; your real ~/.gitconfig and ~/.ssh are never touched.
# Usage: bash tests/e2e_installed.sh [--source] [case-name ...]
#   default   install with `bash install.sh` (the README path) and run ~/.local/bin/gitsetu
#   --source  run a copy of the checkout's ./gitsetu directly (shows each defect in isolation)
# Needs: bash, git, ssh, ssh-keygen, openssl, perl (no-TTY runs), node (scripts/bundle.sh). Tag v1.0.0 must exist
#        (CI: actions/checkout with fetch-depth: 0). Nothing here uses the network.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=installed
if [[ "${1:-}" == "--source" ]]; then MODE=source; shift; fi
ONLY=" $* "
ORIG_PATH=$PATH
REAL_SSH=$(command -v ssh) || { echo "ssh not found"; exit 1; }
REAL_OPENSSL=$(command -v openssl) || REAL_OPENSSL=""
command -v perl >/dev/null 2>&1 || { echo "perl is required (it ships with Git for Windows and macOS)"; exit 1; }
git -C "$REPO" rev-parse -q --verify 'v1.0.0^{commit}' >/dev/null 2>&1 || { echo "tag v1.0.0 missing: check out with fetch-depth: 0"; exit 1; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gs-e2e.XXXXXX") || exit 1   # no "gitsetu" in test paths: checks grep for it
ROOT=$(cd "$ROOT" && pwd -P)   # macOS: /tmp and $TMPDIR sit behind symlinks, which install.sh refuses
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0; FAILED=""

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$CASE"; }
bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED $CASE"; printf 'FAIL  %s: %s\n' "$CASE" "$1"; }
want() { [[ "$ONLY" == "  " || "$ONLY" == *" $1 "* ]]; }

# Run without a controlling terminal (what CI, scripts and most agents have).
notty() { perl -MPOSIX -e 'if (my $p = fork) { waitpid($p, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV or die "exec: $!"' -- "$@" </dev/null; }
# A step the case depends on: on failure, the case fails with the step's first error line.
must() { notty "$@" >> "$T/out" 2>&1 || { bad "step failed: ${*:2:2}: $(grep -m1 -E '✗|Error|error' "$T/out" 2>/dev/null | sed 's/^[[:space:]]*//')"; return 1; }; }
# Hashes of the user state GitSetu may touch (missing files are listed as such).
snap() { local f; for f in "$HOME/.gitconfig" "$HOME/.ssh/config" "$HOME/.ssh/known_hosts" "$XDG_CONFIG_HOME/gitsetu/profiles.conf"; do
  if [[ -f "$f" ]]; then printf '%s %s\n' "$(git hash-object "$f")" "$f"; else printf 'missing %s\n' "$f"; fi; done
  find "$HOME/.ssh" "$XDG_CONFIG_HOME/gitsetu" -type f 2>/dev/null | LC_ALL=C sort; }

# Committed copy of the checkout (install.sh refuses a dirty one).
copy_repo() {
  rm -rf "$1"
  cp -a "$REPO" "$1"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=e2e -c user.email=e2e@example.com commit -qm e2e --allow-empty >/dev/null 2>&1
}

# Isolated environment for case $1: throwaway HOME, no system config, no agent, a fake `ssh` that logs
# its arguments to $T/ssh.log and never connects (`ssh -G`, which only parses config, goes to the real
# ssh), and a fake `ssh-keyscan` that logs to $T/keyscan.log and never connects.
bare_home() {
  CASE="$1"; T="$ROOT/$1"; mkdir -p "$T/home" "$T/bin"; : > "$T/out"
  export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state"
  export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  unset SSH_AUTH_SOCK GITSETU_TEST GITSETU_OS GIT_CONFIG_GLOBAL XDG_DATA_HOME CI GITSETU_VAULT_PASSWORD
  printf '#!/bin/sh\ncase " $* " in *" -G "*) exec "%s" "$@";; esac\nprintf "%%s\\n" "$*" >> "%s/ssh.log"\nexit 128\n' "$REAL_SSH" "$T" > "$T/bin/ssh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/keyscan.log"\nexit 1\n' "$T" > "$T/bin/ssh-keyscan"
  chmod +x "$T/bin/ssh" "$T/bin/ssh-keyscan"
  export PATH="$T/bin:$HOME/.local/bin:$ORIG_PATH"
}

# bare_home + a global identity + the GitSetu under test in $GS.
new_home() {
  bare_home "$1"
  git config --global user.name "Pat Example"
  git config --global user.email "pat.personal@example.com"
  copy_repo "$T/src"
  if [[ "$MODE" == "source" ]]; then GS="$T/src/gitsetu"; return 0; fi
  if ! (cd "$T/src" && bash install.sh) > "$T/install.out" 2>&1; then
    bad "install.sh failed: $(tail -n1 "$T/install.out")"; return 1
  fi
  GS="$HOME/.local/bin/gitsetu"
}

repo() { mkdir -p "$1" && git -C "$1" init -q; }        # repo DIR
commit_in() { (cd "$1" && echo "$RANDOM" >> f && git add f && git commit -qm "c $RANDOM") >/dev/null 2>&1; }
author_in() { git -C "$1" log -1 --format=%ae 2>/dev/null; }
hook_repo() { # repo with logging hooks + local bare remote
  repo "$1"
  local h; for h in pre-commit commit-msg post-commit pre-push; do
    printf '#!/bin/sh\necho "%s %s" >> "%s/hooks.log"\n' "$h" "$1" "$T" > "$1/.git/hooks/$h"; chmod +x "$1/.git/hooks/$h"
  done
  git init -q --bare "$1.remote.git" && git -C "$1" remote add origin "$1.remote.git"
}
add_work() { must "$GS" add work "Pat Example" pat.work@example.com "$HOME/work"; }
v1_tree() { [[ -d "$T/v1" ]] || { mkdir -p "$T/v1" && git -C "$REPO" archive v1.0.0 | tar -x -C "$T/v1"; }; }   # v1.0.0's own code

# CRIT-03: README quick start and headless add work without a TTY on the installed copy.
case_crit03_quickstart() {
  new_home crit03-quickstart || return
  must "$GS" setup --auto || return
  [[ -f "$XDG_CONFIG_HOME/gitsetu/profiles.conf" ]] && ok || bad "setup exited 0 but wrote no registry"
}
case_crit03_add() {
  new_home crit03-add || return
  repo "$HOME/work/r"; add_work || return
  commit_in "$HOME/work/r"
  [[ "$(author_in "$HOME/work/r")" == "pat.work@example.com" ]] && ok || bad "author=$(author_in "$HOME/work/r")"
}

# CRIT-04: the guard keeps every other hook working and never locks unmanaged repos.
case_crit04_hooks() {
  new_home crit04-hooks || return
  hook_repo "$HOME/work/acme"; hook_repo "$HOME/else/oss"
  add_work || return; must "$GS" guard --install || return
  : > "$T/hooks.log"
  local d; for d in "$HOME/work/acme" "$HOME/else/oss"; do commit_in "$d"; git -C "$d" push -q origin HEAD >/dev/null 2>&1; done
  local n; n=$(grep -c . "$T/hooks.log" 2>/dev/null)
  (cd "$HOME/work/acme" && echo x >> f && git add f && git -c user.email=wrong@example.com commit -qm wrong) >/dev/null 2>&1; local wrong=$?
  [[ "$n" == "8" && $wrong -ne 0 ]] && ok || bad "hooks fired=$n/8 (expected all 4 in both repos); wrong-identity commit rc=$wrong (expected non-zero)"
}
case_crit04_prior_hookspath() {
  new_home crit04-prior-hookspath || return
  mkdir -p "$HOME/.githooks"
  printf '#!/bin/sh\necho scanner >> "%s/hooks.log"\n' "$T" > "$HOME/.githooks/pre-commit"; chmod +x "$HOME/.githooks/pre-commit"
  git config --global core.hooksPath "$HOME/.githooks"
  repo "$HOME/work/r"; add_work || return
  must "$GS" guard --install || return
  local hp; hp=$(git -C "$HOME/work/r" config --get core.hooksPath 2>/dev/null)
  case "$hp" in */gitsetu/hooks) ;; *) bad "guard not active in the managed repo (effective core.hooksPath='$hp')"; return ;; esac
  : > "$T/hooks.log"; commit_in "$HOME/work/r"
  grep -q scanner "$T/hooks.log" 2>/dev/null && ok || bad "the previous global pre-commit hook did not run"
}
case_crit04_moved() {
  new_home crit04-moved || return
  repo "$HOME/work/r"; repo "$HOME/else/r"
  add_work || return; must "$GS" guard --install || return
  if [[ "$MODE" == "source" ]]; then mv "$T/src" "$T/src.moved"; else rm -rf "$HOME/.local/share/gitsetu"; fi
  commit_in "$HOME/else/r"; local urc=$?
  commit_in "$HOME/work/r"; local mrc=$?
  [[ $urc -eq 0 && $mrc -eq 0 ]] && ok || bad "after the install moved/was removed: unmanaged commit rc=$urc, managed commit rc=$mrc (both must be 0; managed with a warning)"
}
# CRIT-04 (failure policy): a GitSetu that fails for any reason other than an identity decision (exit 65)
# must not block commits.
case_crit04_crash() {
  new_home crit04-crash || return
  repo "$HOME/work/r"; add_work || return; must "$GS" guard --install || return
  printf '#!/bin/sh\necho "simulated GitSetu failure" >&2\nexit 1\n' > "$T/bin/broken"; chmod +x "$T/bin/broken"
  printf '%s\n' "$T/bin/broken" > "$XDG_CONFIG_HOME/gitsetu/hooks/entrypoint"
  (cd "$HOME/work/r" && echo x >> f && git add f && git commit -qm c) > "$T/commit.out" 2>&1; local rc=$?
  [[ $rc -eq 0 ]] && ok || bad "managed commit rc=$rc when the entrypoint exits 1 (must be 0 with a warning): $(grep -m1 -i 'gitsetu' "$T/commit.out")"
}

# CRIT-05: the user's own includeIf identity still wins.
case_crit05_includeif() {
  new_home crit05-includeif || return
  git config --global includeIf.gitdir:~/oss/.path "~/.gitconfig-oss"
  printf '[user]\n\temail = pat.oss@example.com\n' > "$HOME/.gitconfig-oss"
  repo "$HOME/oss/proj"
  must "$GS" setup --auto || return
  commit_in "$HOME/oss/proj"
  local a; a=$(author_in "$HOME/oss/proj")
  [[ "$a" == "pat.oss@example.com" ]] && ok || bad "commit in ~/oss authored $a (expected pat.oss@example.com)"
}

# CRIT-06: gitsetu run pins the profile key.
case_crit06_run() {
  new_home crit06-run || return
  add_work || return
  : > "$T/ssh.log"; notty "$GS" run work -- git ls-remote git@github.com:example-org/r.git >/dev/null 2>&1
  grep -q 'IdentitiesOnly=yes' "$T/ssh.log" 2>/dev/null && ok || bad "run ssh argv: $(head -n1 "$T/ssh.log" 2>/dev/null)"
}

# CRIT-07: an existing default key keeps working; no new key forced on every host.
case_crit07_existing_key() {
  new_home crit07-existing-key || return
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C pat.personal@example.com -f "$HOME/.ssh/id_ed25519"
  repo "$HOME/code/app"; git -C "$HOME/code/app" remote add origin git@gitlab.corp.example:team/app.git
  must "$GS" setup --auto || return
  : > "$T/ssh.log"; git -C "$HOME/code/app" fetch -q origin >/dev/null 2>&1
  [[ -s "$T/ssh.log" ]] || { bad "git did not call ssh at all"; return; }
  if grep -qE 'IdentitiesOnly|id_ed25519_global' "$T/ssh.log" || [[ -e "$HOME/.ssh/id_ed25519_global" ]]; then
    bad "unmanaged repo ssh argv: $(head -n1 "$T/ssh.log")"
  else ok; fi
}
# CRIT-07 (agent): profile keys stay out of the agent; generated Host blocks must not add them.
case_crit07_agent() {
  new_home crit07-agent || return
  add_work || return
  local f="$XDG_CONFIG_HOME/gitsetu/profiles/ssh_config" n
  [[ -f "$f" ]] || { bad "no generated ssh_config"; return; }
  n=$(grep -ci 'AddKeysToAgent' "$f" || true)
  [[ "$n" == "0" ]] && ok || bad "generated ssh_config has $n AddKeysToAgent line(s)"
}

# CRIT-09: generated ssh_config (macOS output) has no UseKeychain and parses with portable OpenSSH.
case_crit09_usekeychain() {
  new_home crit09-usekeychain || return
  GITSETU_OS=macos notty "$GS" status > "$T/os.out" 2>&1
  grep -qE 'OS:[[:space:]]+macos' "$T/os.out" || { bad "GITSETU_OS=macos is not honoured, so this case can't produce macOS output (CRIT-01): $(grep -m1 'OS:' "$T/os.out" | sed 's/^ *//')"; return; }
  export GITSETU_OS=macos; add_work; local rc=$?; unset GITSETU_OS; [[ $rc -eq 0 ]] || return
  local f="$XDG_CONFIG_HOME/gitsetu/profiles/ssh_config" kc prc
  [[ -f "$f" ]] || { bad "no generated ssh_config"; return; }
  kc=$(grep -ci 'usekeychain' "$f" || true)
  "$REAL_SSH" -F "$f" -G unrelated.example.org >/dev/null 2>&1; prc=$?
  [[ "$kc" == "0" && $prc -eq 0 ]] && ok || bad "UseKeychain lines=$kc; ssh -F <generated> -G rc=$prc"
}

# CRIT-10 (D2 = remove the broker): no GitSetu helper; git sends nothing GitSetu rejects.
case_crit10_credential() {
  new_home crit10-credential || return
  repo "$HOME/work/r"; add_work || return
  printf '#!/bin/sh\ncat > "%s/helper.in"\n' "$T" > "$T/bin/git-credential-log"; chmod +x "$T/bin/git-credential-log"
  local err helper
  err=$(cd "$HOME/work/r" && printf 'protocol=https\nhost=github.com\n\n' | git -c credential.helper=log credential fill 2>&1 >/dev/null)
  helper=$(git config --global --get-all credential.helper 2>/dev/null || true)
  [[ "$helper" != *gitsetu* && "$err" != *Malformed* ]] && ok || bad "global helper='$helper' stderr='$(printf '%s' "$err" | head -n1)'"
}

# CRIT-11 (D1 = B: keep the vault): restore works on a fresh machine and on a machine whose path to the
# source HOME crosses a symlink, never replaces newer state without --force (keys, profiles, remote routes),
# and keeps what it replaces. The password comes from the documented GITSETU_VAULT_PASSWORD (CRIT-01).
case_crit11_vault() {
  bare_home crit11-vault
  copy_repo "$T/src"
  if [[ "$MODE" == "source" ]]; then GS="$T/src/gitsetu"; else
    (cd "$T/src" && bash install.sh) > "$T/install.out" 2>&1 || { bad "install.sh failed: $(tail -n1 "$T/install.out")"; return; }
    GS="$HOME/.local/bin/gitsetu"; fi
  # The source machine's HOME sits under $T/m1/home (a real directory for now).
  export HOME="$T/m1/home/pat" XDG_CONFIG_HOME="$T/m1/home/pat/.config"; mkdir -p "$HOME"
  git config --global user.name "Pat Example"; git config --global user.email pat.personal@example.com
  repo "$HOME/work/r"; add_work || return
  export GITSETU_VAULT_PASSWORD="example-vault-password-12345"
  local vault="$T/backup.vault" why=""
  must "$GS" backup "$vault" || { unset GITSETU_VAULT_PASSWORD; return; }
  # 1. Fresh machine: a new HOME without ~/.config, no --force.
  local h1="$HOME" x1="$XDG_CONFIG_HOME"
  export HOME="$T/fresh/pat" XDG_CONFIG_HOME="$T/fresh/pat/.config"; mkdir -p "$HOME"
  git config --global user.name "Pat Example"; git config --global user.email pat.personal@example.com
  notty "$GS" restore "$vault" >> "$T/out" 2>&1; local rc=$?
  grep -qE 'work|%77%6F%72%6B' "$XDG_CONFIG_HOME/gitsetu/profiles.conf" 2>/dev/null || rc="$rc/no-profile"
  [[ "$rc" == "0" ]] || why="$why fresh-home restore rc=$rc;"
  # 2. The path to the source HOME now crosses a symlink (Linux vault restored on macOS, where /home is one).
  mv "$T/m1/home" "$T/m1/home.real" && ln -s home.real "$T/m1/home"
  export HOME="$T/m2/Users/pat" XDG_CONFIG_HOME="$T/m2/Users/pat/.config"; mkdir -p "$HOME"
  git config --global user.name "Pat Example"; git config --global user.email pat.personal@example.com
  notty "$GS" restore "$vault" >> "$T/out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] || why="$why restore where the source HOME path crosses a symlink rc=$rc ($(tail -n1 "$T/out" | sed 's/^ *//'));"
  rm "$T/m1/home" && mv "$T/m1/home.real" "$T/m1/home"
  export HOME="$h1" XDG_CONFIG_HOME="$x1"
  # 3. A rotated (newer) key: refused without --force; with --force the replaced key is kept.
  rm -f "$HOME/.ssh/id_ed25519_work" "$HOME/.ssh/id_ed25519_work.pub"
  ssh-keygen -q -t ed25519 -N '' -C rotated@example.com -f "$HOME/.ssh/id_ed25519_work"
  local newer; newer=$(git hash-object "$HOME/.ssh/id_ed25519_work")
  notty "$GS" restore "$vault" >> "$T/out" 2>&1; rc=$?
  [[ $rc -ne 0 && "$(git hash-object "$HOME/.ssh/id_ed25519_work")" == "$newer" ]] || why="$why restore over a newer key without --force rc=$rc;"
  notty "$GS" restore "$vault" --force >> "$T/out" 2>&1; rc=$?
  local kept=0 f
  while IFS= read -r f; do
    [[ -n "$f" && "$(git hash-object "$f")" == "$newer" ]] && kept=1
  done < <(find "$XDG_CONFIG_HOME/gitsetu/backups" -type f -path '*restore-*' 2>/dev/null)
  [[ $rc -eq 0 && $kept -eq 1 ]] || why="$why --force rc=$rc, replaced key kept under backups/restore-*=$kept;"
  # 4. A remote route added after the backup is not dropped without --force.
  must "$GS" profile edit work --remote=git@github.com:acme/* || { unset GITSETU_VAULT_PASSWORD; return; }
  local routes; routes=$(cat "$XDG_CONFIG_HOME/gitsetu/remotes/work.remotes" 2>/dev/null)
  notty "$GS" restore "$vault" >> "$T/out" 2>&1; rc=$?
  [[ $rc -ne 0 && "$(cat "$XDG_CONFIG_HOME/gitsetu/remotes/work.remotes" 2>/dev/null)" == "$routes" && -n "$routes" ]] || \
    why="$why restore without --force over a newer remote route rc=$rc, route kept=$([[ -f $XDG_CONFIG_HOME/gitsetu/remotes/work.remotes ]] && echo yes || echo no);"
  unset GITSETU_VAULT_PASSWORD
  [[ -z "$why" ]] && ok || bad "$why"
}
# CRIT-11 (D1 = B): Ctrl-C during restore leaves every file as it was, with no stray key copies.
# A PATH shim pauses the restore inside the window under test; the case then sends SIGINT, as Ctrl-C does.
case_crit11_interrupt() {
  new_home crit11-interrupt || return
  istate() { local f; for f in "$HOME/.gitconfig" "$HOME/.ssh/config" "$XDG_CONFIG_HOME/gitsetu/profiles.conf" "$HOME"/.ssh/id_*; do
    if [[ -f "$f" ]]; then printf '%s %s\n' "$(git hash-object "$f")" "$f"; else printf 'missing %s\n' "$f"; fi; done; }
  repo "$HOME/work/r"; add_work || return
  mkdir -p "$HOME/.ssh" && printf 'Host myserver\n    HostName 192.0.2.10\n' >> "$HOME/.ssh/config"
  export GITSETU_VAULT_PASSWORD="example-vault-password-12345"
  local vault="$T/backup.vault" why="" tool window
  must "$GS" backup "$vault" || { unset GITSETU_VAULT_PASSWORD; return; }
  for window in "chmod:old-global/" "mv:.gitsetu-restore."; do
    tool=${window%%:*}
    rm -f "$HOME/.ssh/id_ed25519_work" "$HOME/.ssh/id_ed25519_work.pub"          # newer state than the vault
    ssh-keygen -q -t ed25519 -N '' -C "rotated-$tool@example.com" -f "$HOME/.ssh/id_ed25519_work"
    local before; before=$(istate)
    rm -f "$T/in-window"
    printf '#!/bin/sh\ncase "$*" in *"%s"*) : > "%s/in-window"; sleep 5;; esac\nexec "%s" "$@"\n' \
      "${window#*:}" "$T" "$(PATH="$ORIG_PATH" command -v "$tool")" > "$T/bin/$tool"; chmod +x "$T/bin/$tool"
    perl -e '$SIG{INT}="DEFAULT"; exec @ARGV or die' -- "$GS" restore "$vault" --force </dev/null >> "$T/out" 2>&1 &
    local pid=$! i=0
    while [[ ! -e "$T/in-window" && $i -lt 300 ]]; do sleep 0.1; i=$((i+1)); done
    kill -INT "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; local rc=$?
    rm -f "$T/bin/$tool"
    local after; after=$(istate)
    local stray=0 sf
    for sf in "$HOME/.ssh"/*gitsetu-restore*; do
      [[ -e "$sf" ]] && ((stray++))
    done
    [[ -e "$T/in-window" ]] || { why="$why $tool window never reached;"; continue; }
    [[ "$before" == "$after" && "$stray" == "0" && $rc -ne 0 ]] || \
      why="$why Ctrl-C in the $tool window: rc=$rc, state unchanged=$([[ "$before" == "$after" ]] && echo yes || echo "NO: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^[<>]' | head -n2 | tr '\n' ' ')"), stray key copies=$stray;"
  done
  unset GITSETU_VAULT_PASSWORD
  [[ -z "$why" ]] && ok || bad "$why"
}
# CRIT-11 (D1 = B): vaults move between OpenSSL families, and v1.0.0 vaults import (D8 = A).
# Fixtures in tests/fixtures/vault/: openssl3.vault (made on Linux), libressl.vault (made on a Mac with
# /usr/bin/openssl) and, when D8 = A, v1.0.0.vault; the password in PASSWORD; each vault holds profile "work".
case_crit11_compat() {
  bare_home crit11-compat
  local fx="$REPO/tests/fixtures/vault" v n=0 failed=""
  [[ -f "$fx/openssl3.vault" && -f "$fx/libressl.vault" && -f "$fx/PASSWORD" ]] || { bad "missing fixtures: tests/fixtures/vault/ needs openssl3.vault, libressl.vault and PASSWORD"; return; }
  copy_repo "$T/src"; GS="$T/src/gitsetu"
  for v in "$fx"/*.vault; do
    n=$((n+1)); export HOME="$T/h$n" XDG_CONFIG_HOME="$T/h$n/.config"; mkdir -p "$HOME"
    git config --global user.name "Pat Example"; git config --global user.email pat.personal@example.com
    GITSETU_VAULT_PASSWORD="$(cat "$fx/PASSWORD")" notty "$GS" restore "$v" >> "$T/out" 2>&1 || failed="$failed $(basename "$v")"
    grep -qE 'work|%77%6F%72%6B' "$XDG_CONFIG_HOME/gitsetu/profiles.conf" 2>/dev/null || failed="$failed $(basename "$v")(no-profile)"
  done
  [[ -z "$failed" ]] && ok || bad "fixtures that did not restore:$failed"
}

# CRIT-12: v1.0.0 state keeps working after upgrading.
case_crit12_v1_registry() {
  new_home crit12-v1-registry || return
  v1_tree
  repo "$HOME/work/r"
  must bash "$T/v1/gitsetu" add work "Pat Example" pat.work@example.com "$HOME/work" || return
  notty "$GS" status > "$T/status" 2>&1; local rc=$?
  [[ $rc -eq 0 ]] && grep -q work "$T/status" && ok || bad "status after v1.0.0 setup rc=$rc: $(grep -m1 -E 'legacy|✗' "$T/status" 2>/dev/null)"
}

# CRIT-13: the installer upgrades a v1.0.0 install; a piped installer gives guidance.
case_crit13_installer() {
  [[ "$MODE" == "installed" ]] || return
  bare_home crit13-installer
  git clone -q "$REPO" "$HOME/.local/share/gitsetu" && git -C "$HOME/.local/share/gitsetu" checkout -q v1.0.0
  mkdir -p "$HOME/.local/bin" && ln -sf "$HOME/.local/share/gitsetu/gitsetu" "$HOME/.local/bin/gitsetu"
  copy_repo "$T/src"
  (cd "$T/src" && bash install.sh) > "$T/out" 2>&1; local rc=$?
  local piped ver
  piped=$(cd "$T" && bash < "$T/src/install.sh" 2>&1 | head -n2)
  ver=$("$HOME/.local/bin/gitsetu" --version 2>&1)
  [[ $rc -eq 0 && "$ver" == *1.1.* && "$piped" != *unbound* ]] && ok || bad "install over v1.0.0 rc=$rc ($(tail -n1 "$T/out")); version='${ver%%$'\n'*}'; piped='${piped%%$'\n'*}'"
}
# CRIT-13: declining (or being unable to confirm) an uninstall changes nothing.
case_crit13_uninstall_decline() {
  [[ "$MODE" == "installed" ]] || return
  new_home crit13-uninstall-decline || return
  repo "$HOME/work/r"; add_work || return
  local before; before=$(snap)
  notty bash "$T/src/uninstall.sh" > "$T/un.out" 2>&1; local rc=$?
  local after; after=$(snap)
  [[ $rc -eq 3 && "$before" == "$after" && "$(git -C "$HOME/work/r" config user.email)" == "pat.work@example.com" ]] && ok || \
    bad "uninstall without TTY and without --force: rc=$rc, state unchanged=$([[ "$before" == "$after" ]] && echo yes || echo no), work email now $(git -C "$HOME/work/r" config user.email)"
}
# CRIT-13: `gitsetu update` on a git checkout never moves to an older version.
case_crit13_update_no_downgrade() {
  bare_home crit13-update-no-downgrade
  git clone -q "$REPO" "$T/clone" && git -C "$T/clone" checkout -q "$(git -C "$REPO" rev-parse HEAD)" || { bad "clone failed"; return; }
  local before; before=$(git -C "$T/clone" rev-parse HEAD)
  notty bash "$T/clone/gitsetu" update > "$T/out" 2>&1; local rc=$?
  local after; after=$(git -C "$T/clone" rev-parse HEAD)
  [[ $rc -eq 0 && "$before" == "$after" ]] && ok || bad "update rc=$rc moved the checkout from ${before:0:8} to $(git -C "$T/clone" describe --tags --always "$after") ($(tail -n1 "$T/out" | sed 's/^ *//'))"
}

# HIGH-01: no unrelated global settings are changed.
case_high01_globals() {
  new_home high01-globals || return
  git config --global init.defaultBranch trunk
  add_work || return
  local db sd; db=$(git config --global init.defaultBranch); sd=$(git config --global --get-all safe.directory 2>/dev/null || true)
  [[ "$db" == "trunk" && -z "$sd" ]] && ok || bad "init.defaultBranch=$db safe.directory=$(printf '%s' "$sd" | tr '\n' ' ')"
}

# CRIT-08: the user's own SSH host aliases keep their settings, and GitSetu's own alias still works.
case_crit08_alias() {
  new_home crit08-alias || return
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  printf 'Host github-work\n    HostName ghe.corp.example\n    Port 2222\n' > "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  add_work || return
  # OpenSSH takes ~ from the account database, not $HOME: resolve both files against this HOME first.
  local gen="$HOME/.config/gitsetu/profiles/ssh_config"
  if [[ -f "$gen" ]]; then sed "s#~#$HOME#g" "$gen" > "$T/gen.view"; else : > "$T/gen.view"; fi
  sed -e "s#~#$HOME#g" -e "s#$gen#$T/gen.view#g" "$HOME/.ssh/config" > "$T/main.view"
  local h g; h=$("$REAL_SSH" -F "$T/main.view" -G github-work 2>/dev/null | awk '$1 == "hostname" {print $2}')
  g=$("$REAL_SSH" -F "$T/main.view" -G gitsetu-work 2>/dev/null | awk '$1 == "hostname" {print $2}')
  [[ "$h" == "ghe.corp.example" && "$g" == "github.com" ]] && ok || bad "Host github-work resolves to '$h' (expected ghe.corp.example); gitsetu-work resolves to '$g' (expected github.com)"
}

# HIGH-02: verify agrees with the guard.
case_high02_verify_guard() {
  new_home high02-verify-guard || return
  add_work || return
  must "$GS" guard --install || return
  repo "$HOME/work/r"; git -C "$HOME/work/r" config user.name "Someone Else"
  local g v
  commit_in "$HOME/work/r"; g=$?
  notty "$GS" verify > "$T/verify.out" 2>&1; v=$?
  if { [[ $g -ne 0 ]] && [[ $v -ne 0 ]]; } || { [[ $g -eq 0 ]] && [[ $v -eq 0 ]]; }; then ok
  else bad "guard commit rc=$g but verify rc=$v: they disagree ($(grep -m1 -iE 'passed|fail|error' "$T/verify.out" 2>/dev/null | sed 's/^[[:space:]]*//'))"; fi
}

# HIGH-10: setup never fetches or trusts an SSH host key on its own.
case_high10_keyscan() {
  new_home high10-keyscan || return
  local before; before=$(snap)
  add_work || return
  local calls; calls=$(cat "$T/keyscan.log" 2>/dev/null | head -n1)
  [[ -z "$calls" && ! -s "$HOME/.ssh/known_hosts" ]] && ok || bad "ssh-keyscan called with '$calls'; known_hosts lines=$(grep -c . "$HOME/.ssh/known_hosts" 2>/dev/null)"
}

# HIGH-11: a user who signs every commit keeps signing in managed folders unless they choose otherwise.
case_high11_signing() {
  new_home high11-signing || return
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C pat.personal@example.com -f "$HOME/.ssh/id_ed25519"
  git config --global gpg.format ssh; git config --global user.signingkey "$HOME/.ssh/id_ed25519.pub"
  git config --global commit.gpgsign true; git config --global tag.gpgsign true
  repo "$HOME/work/r"; add_work || return
  local c t; c=$(git -C "$HOME/work/r" config commit.gpgsign); t=$(git -C "$HOME/work/r" config tag.gpgsign)
  [[ "$c" == "true" && "$t" == "true" ]] && ok || bad "in ~/work/r commit.gpgsign=$c tag.gpgsign=$t (global: true/true)"
}

# HIGH-12: the documented post-setup check doesn't report a correctly registered key as the wrong account.
case_high12_verify_login() {
  new_home high12-verify-login || return
  add_work || return
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLzapDVasmAcS9le6AHbqMW/\n' >> "$HOME/.ssh/known_hosts"
  printf '#!/bin/sh\ncase " $* " in *" -G "*) exec "%s" "$@";; esac\nprintf "Hi pat-example! You'"'"'ve successfully authenticated, but GitHub does not provide shell access.\\n" >&2\nexit 1\n' "$REAL_SSH" > "$T/bin/ssh"
  GITSETU_VERIFY_NETWORK=1 notty "$GS" verify > "$T/v.out" 2>&1; local rc=$?
  ! grep -qi 'expects account' "$T/v.out" && [[ $rc -eq 0 ]] && ok || bad "verify rc=$rc: $(grep -m1 -iE 'expects account|✗' "$T/v.out" | sed 's/^ *//')"
}

# HIGH-13: import adopts existing routes without generating a new key (any key it pins existed before),
# keeps the route's email, and never writes without consent.
case_high13_import() {
  new_home high13-import || return
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C pat.personal@example.com -f "$HOME/.ssh/id_ed25519"
  git config --global includeIf.gitdir:~/client/.path "~/.gitconfig-client"
  printf '[user]\n\tname = Pat Example\n\temail = pat.client@example.com\n' > "$HOME/.gitconfig-client"
  repo "$HOME/client/r"; git -C "$HOME/client/r" remote add origin git@github.com:client-org/r.git
  local keys1="" kf1
  for kf1 in "$HOME/.ssh"/id_*; do
    [[ -e "$kf1" ]] && keys1="${keys1}${kf1##*/}"$'\n'
  done
  keys1=$(printf '%s' "$keys1" | LC_ALL=C sort)
  local before; before=$(snap)
  notty "$GS" import > "$T/i1.out" 2>&1; local r1=$?
  local mid; mid=$(snap)
  must "$GS" import --yes || return
  local keys2="" kf2
  for kf2 in "$HOME/.ssh"/id_*; do
    [[ -e "$kf2" ]] && keys2="${keys2}${kf2##*/}"$'\n'
  done
  keys2=$(printf '%s' "$keys2" | LC_ALL=C sort)
  : > "$T/ssh.log"; git -C "$HOME/client/r" ls-remote origin >/dev/null 2>&1; local argv2; argv2=$(head -n1 "$T/ssh.log")
  local ikey; ikey=$(printf '%s\n' "$argv2" | sed -n 's/.* -i \([^ ]*\).*/\1/p' | tr -d "'\""); ikey=${ikey/#\~/$HOME}
  local email; email=$(git -C "$HOME/client/r" config user.email)
  [[ $r1 -eq 3 && "$before" == "$mid" && "$keys1" == "$keys2" && ( -z "$ikey" || -f "$ikey" ) && "$email" == "pat.client@example.com" ]] && ok || \
    bad "import without TTY/--yes rc=$r1 (wrote=$([[ "$before" == "$mid" ]] && echo no || echo yes)); new key files=$([[ "$keys1" == "$keys2" ]] && echo none || comm -13 <(printf '%s\n' "$keys1") <(printf '%s\n' "$keys2") | tr '\n' ' '); ssh argv after='$argv2'; email=$email"
}

# FUT-01: remote-URL routing outside the profile folders.
case_fut01_remote() {
  new_home fut01-remote || return
  repo "$HOME/work/r"; add_work || return
  must "$GS" add acme "Acme Dev" acme@example.com "$HOME/acme" --remote "git@github.com:acme/*" || return
  repo "$HOME/unmanaged/project"
  git -C "$HOME/unmanaged/project" remote add origin git@github.com:acme/sample.git
  local a; a=$(git -C "$HOME/unmanaged/project" config user.email 2>/dev/null)
  [[ "$a" == "acme@example.com" ]] && ok || bad "remote URL routing email=$a (expected acme@example.com)"
}
# FUT-02: verify names both accounts when a key authenticates as a different account than the profile's.
case_fut02_greeting() {
  new_home fut02-greeting || return
  must "$GS" add work "Pat Example" pat.work@example.com "$HOME/work" --provider-user=pat-work || return
  mkdir -p "$HOME/.ssh"
  printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLzapDVasmAcS9le6AHbqMW/\n' >> "$HOME/.ssh/known_hosts"
  printf '#!/bin/sh\ncase " $* " in *" -G "*) exec "%s" "$@";; esac\nprintf "Hi pat-personal! You have successfully authenticated.\\n" >&2\nexit 1\n' "$REAL_SSH" > "$T/bin/ssh"
  GITSETU_VERIFY_NETWORK=1 notty "$GS" verify > "$T/v.out" 2>&1; local rc=$?
  [[ $rc -ne 0 ]] && grep -q 'pat-personal' "$T/v.out" && grep -q 'pat-work' "$T/v.out" && ok || bad "verify rc=$rc did not name both accounts"
}
# FUT-04: explain shows where the identity comes from.
case_fut04_explain() {
  new_home fut04-explain || return
  repo "$HOME/work/r"; add_work || return
  notty "$GS" explain "$HOME/work/r" > "$T/explain.out" 2>&1; local rc=$?
  [[ $rc -eq 0 ]] && grep -q "work" "$T/explain.out" && ok || bad "explain command failed rc=$rc"
}

# CRIT-11 (D1 = B): a profile whose folder is outside HOME (a second drive, /Volumes/…, /data/…) survives a backup and
# restore on the same machine after ~/.config/gitsetu is lost. Passes at ba64267; dad9ff2 backs up but refuses to restore.
case_crit11_external_dir() {
  new_home crit11-external-dir || return
  local ext="$T/drive/code/work"; mkdir -p "$ext/r" && git -C "$ext/r" init -q
  must "$GS" add work "Pat Example" pat.work@example.com "$ext" || return
  export GITSETU_VAULT_PASSWORD="example-vault-password-12345"
  must "$GS" backup "$T/b.vault" || { unset GITSETU_VAULT_PASSWORD; return; }
  rm -rf "$XDG_CONFIG_HOME/gitsetu"
  notty "$GS" restore "$T/b.vault" --force > "$T/r.out" 2>&1; local rc=$?
  unset GITSETU_VAULT_PASSWORD
  commit_in "$ext/r"
  [[ $rc -eq 0 && "$(author_in "$ext/r")" == "pat.work@example.com" ]] && ok || \
    bad "restore rc=$rc ($(grep -m1 '✗' "$T/r.out" | sed 's/^ *//')); author in the external folder afterwards: $(author_in "$ext/r")"
}
# CRIT-15: the release assets install. Offline, the rendered installer must accept its own embedded metadata and stop
# only at the download, both piped and run beside the assets, and the bundle must report the tag's version.
case_crit15_render_install() {
  [[ "$MODE" == "installed" ]] || return
  bare_home crit15-render-install
  copy_repo "$T/src"
  (cd "$T/src" && bash scripts/render_release.sh v1.1.0-rc.1 https://example.invalid/dl "$T/rel") > "$T/render.out" 2>&1 || \
    { bad "render_release.sh failed: $(tail -n1 "$T/render.out")"; return; }
  local piped beside ver
  piped=$(cd "$T" && bash < "$T/rel/install.sh" 2>&1 | grep -m1 -E 'Error|error')
  beside=$(cd "$T/rel" && bash ./install.sh 2>&1 | grep -m1 -E 'Error|error')
  ver=$(bash "$T/rel/gitsetu" --version 2>&1 | head -n1)
  [[ "$piped" == *"artifact download failed"* && "$beside" == *"artifact download failed"* && "$ver" == "gitsetu v1.1.0-rc.1" ]] && ok || \
    bad "piped: '$piped'; beside the assets: '$beside'; bundle --version: '$ver' (only the download may fail offline; the version must be v1.1.0-rc.1)"
}

CASES="crit03-quickstart crit03-add crit04-hooks crit04-prior-hookspath crit04-moved crit04-crash crit05-includeif
  crit06-run crit07-existing-key crit07-agent crit08-alias crit09-usekeychain crit10-credential crit11-vault crit11-interrupt crit11-compat
  crit11-external-dir crit12-v1-registry crit13-installer crit13-uninstall-decline crit13-update-no-downgrade crit15-render-install
  high01-globals high02-verify-guard high10-keyscan high11-signing high12-verify-login high13-import
  fut01-remote fut02-greeting fut04-explain"
for c in $CASES; do
  want "$c" && "case_${c//-/_}"
done

printf '\nmode=%s  PASS=%d FAIL=%d%s\n' "$MODE" "$PASS" "$FAIL" "${FAILED:+  failed:$FAILED}"
[[ $FAIL -eq 0 ]]
