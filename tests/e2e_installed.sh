#!/usr/bin/env bash
# shellcheck disable=SC2015
# tests/e2e_installed.sh — end-to-end checks of GitSetu as users run it.
# Every case runs in its own throwaway HOME; your real ~/.gitconfig and ~/.ssh are never touched.
# Usage: bash tests/e2e_installed.sh [--source] [case-name ...]
#   default   install with `bash install.sh` (the README path) and run ~/.local/bin/gitsetu
#   --source  run a copy of the checkout's ./gitsetu directly (shows each defect in isolation today)
# Needs: bash, git, ssh-keygen, perl (no-TTY runs), node (only while install.sh still builds the
#        bundle with Node). Tag v1.0.0 must exist (CI: actions/checkout with fetch-depth: 0).
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=installed
if [[ "${1:-}" == "--source" ]]; then MODE=source; shift; fi
ONLY=" $* "
ORIG_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gs-e2e.XXXXXX") || exit 1   # no "gitsetu" in test paths: checks grep for it
ROOT=$(cd "$ROOT" && (pwd -W 2>/dev/null || pwd -P))   # macOS: /tmp and $TMPDIR sit behind symlinks; Windows: needs Windows drive path
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0; FAILED=""

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$CASE"; }
bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED $CASE"; printf 'FAIL  %s: %s\n' "$CASE" "$1"; }
want() { [[ "$ONLY" == "  " || "$ONLY" == *" $1 "* ]]; }
real_ssh() { PATH="$ORIG_PATH" ssh "$@"; }

# Run without a controlling terminal (what CI, scripts and most agents have).
notty() {
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'if (my $p = fork) { waitpid($p, 0); exit($? >> 8) } eval { POSIX::setsid(); }; exec @ARGV or die "exec: $!"' -- "$@" </dev/null
  else
    "$@" </dev/null
  fi
}

# A step the case depends on: on failure, the case fails with the step's first error line.
must() { notty "$@" >> "$T/out" 2>&1 || { bad "step failed: ${*:2:2}: $(grep -m1 -E '✗|Error|error' "$T/out" 2>/dev/null | sed 's/^[[:space:]]*//')"; return 1; }; }

# Committed copy of the checkout (install.sh refuses a dirty one).
copy_repo() {
  rm -rf "$1"
  cp -a "$REPO" "$1"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=e2e -c user.email=e2e@example.com commit -qm e2e --allow-empty >/dev/null 2>&1
}

# Isolated environment for case $1: throwaway HOME, no system config, no agent, and a fake `ssh`
# that logs its arguments to $T/ssh.log and never connects.
bare_home() {
  CASE="$1"; T="$ROOT/$1"; mkdir -p "$T/home" "$T/bin"; : > "$T/out"
  export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state"
  export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  unset SSH_AUTH_SOCK GITSETU_TEST GITSETU_OS GIT_CONFIG_GLOBAL XDG_DATA_HOME CI
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/ssh.log"\nexit 128\n' "$T" > "$T/bin/ssh"; chmod +x "$T/bin/ssh"
  local tbin_posix
  tbin_posix=$(cd "$T/bin" 2>/dev/null && pwd -P) || tbin_posix="$T/bin"
  export PATH="$tbin_posix:$HOME/.local/bin:$ORIG_PATH"
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
  local n; n=$(grep -c . "$T/hooks.log" 2>/dev/null || echo 0)
  (cd "$HOME/work/acme" && echo x >> f && git add f && git -c user.email=wrong@example.com commit -qm wrong) >/dev/null 2>&1; local wrong=$?
  [[ $n -eq 8 && $wrong -ne 0 ]] && ok || bad "hooks fired=$n/8 (expected all 4 in both repos); wrong-identity commit rc=$wrong (expected non-zero)"
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

# CRIT-09: generated ssh_config (macOS output) has no UseKeychain and parses with portable OpenSSH.
case_crit09_usekeychain() {
  new_home crit09-usekeychain || return
  export GITSETU_OS=macos; add_work; local rc=$?; unset GITSETU_OS; [[ $rc -eq 0 ]] || return
  local f="$XDG_CONFIG_HOME/gitsetu/profiles/ssh_config" kc prc
  [[ -f "$f" ]] || { bad "no generated ssh_config"; return; }
  kc=$(grep -ci 'usekeychain' "$f" || true)
  real_ssh -F "$f" -G unrelated.example.org >/dev/null 2>&1; prc=$?
  [[ $kc -eq 0 && $prc -eq 0 ]] && ok || bad "UseKeychain lines=$kc; ssh -F <generated> -G rc=$prc"
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

# CRIT-11 (D1 = Option B: fix & retain vault): backup & restore work in fresh home.
case_crit11_vault() {
  new_home crit11-vault || return
  add_work || return
  export GITSETU_VAULT_PASSWORD="test-vault-password-12345"
  local vault_file="$T/backup.vault"
  must "$GS" backup "$vault_file" || return
  [[ -f "$vault_file" ]] || { bad "backup file not created"; return; }

  bare_home crit11-vault-restore
  export GITSETU_VAULT_PASSWORD="test-vault-password-12345"
  must "$GS" restore "$vault_file" --force || return
  [[ -f "$HOME/.config/gitsetu/profiles.conf" ]] && grep -q -E 'work|%77%6F%72%6B' "$HOME/.config/gitsetu/profiles.conf" && ok || bad "restore in fresh home failed to restore profiles"
}

# CRIT-12: v1.0.0 state keeps working after upgrading.
case_crit12_v1_registry() {
  new_home crit12-v1-registry || return
  mkdir -p "$T/v1" && git -C "$REPO" archive v1.0.0 | tar -x -C "$T/v1"
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

# HIGH-01: no unrelated global settings are changed.
case_high01_globals() {
  new_home high01-globals || return
  git config --global init.defaultBranch trunk
  add_work || return
  local db sd; db=$(git config --global init.defaultBranch); sd=$(git config --global --get-all safe.directory 2>/dev/null || true)
  [[ "$db" == "trunk" && -z "$sd" ]] && ok || bad "init.defaultBranch=$db safe.directory=$(printf '%s' "$sd" | tr '\n' ' ')"
}

# CRIT-08: the user's own SSH host aliases keep their settings.
case_crit08_alias() {
  new_home crit08-alias || return
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  printf 'Host github-work\n    HostName ghe.corp.example\n    Port 2222\n' > "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  add_work || return
  local gen="$HOME/.config/gitsetu/profiles/ssh_config"
  if [[ -f "$gen" ]]; then sed "s#~#$HOME#g" "$gen" > "$T/gen.view"; else : > "$T/gen.view"; fi
  sed -e "s#~#$HOME#g" -e "s#$gen#$T/gen.view#g" "$HOME/.ssh/config" > "$T/main.view"
  local h; h=$(real_ssh -F "$T/main.view" -G github-work 2>/dev/null | awk '$1 == "hostname" {print $2}')
  [[ "$h" == "ghe.corp.example" ]] && ok || bad "Host github-work now resolves to '$h' (expected ghe.corp.example)"
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

# FUT-01: remote URL routing.
case_fut01_remote() {
  new_home fut01-remote || return
  repo "$HOME/work/r"; add_work || return
  must "$GS" add acme "Acme Dev" acme@example.com "$HOME/acme" --remote "git@github.com:acme/*" || return
  repo "$HOME/unmanaged/project"
  git -C "$HOME/unmanaged/project" remote add origin git@github.com:acme/sample.git
  local a; a=$(git -C "$HOME/unmanaged/project" config user.email 2>/dev/null)
  [[ "$a" == "acme@example.com" ]] && ok || bad "remote URL routing email=$a (expected acme@example.com)"
}

# FUT-02: SSH greeting check.
case_fut02_greeting() {
  new_home fut02-greeting || return
  add_work || return
  mkdir -p "$HOME/.ssh"
  printf 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLzapDVasmAcS9le6AHbqMW/\n' >> "$HOME/.ssh/known_hosts"
  printf '#!/bin/sh\nprintf "Hi wronguser! You have successfully authenticated.\n" >&2\nexit 1\n' > "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
  notty "$GS" verify --network >> "$T/out" 2>&1
  local rc=$?
  [[ $rc -ne 0 ]] && grep -qi "Key authenticated as" "$T/out" && ok || bad "greeting mismatch check did not detect mismatch (rc=$rc)"
}

# FUT-04: explain & import.
case_fut04_explain() {
  new_home fut04-explain || return
  repo "$HOME/work/r"; add_work || return
  notty "$GS" explain "$HOME/work/r" > "$T/explain.out" 2>&1
  local rc=$?
  [[ $rc -eq 0 ]] && grep -q "work" "$T/explain.out" && ok || bad "explain command failed rc=$rc"
}

CASES=(
  crit03-quickstart crit03-add crit04-hooks crit04-prior-hookspath crit04-moved crit05-includeif
  crit06-run crit07-existing-key crit09-usekeychain crit10-credential crit11-vault
  crit12-v1-registry crit13-installer high01-globals crit08-alias high02-verify-guard
  fut01-remote fut02-greeting fut04-explain
)

for c in "${CASES[@]}"; do
  want "$c" && "case_${c//-/_}"
done

printf '\nmode=%s  PASS=%d FAIL=%d%s\n' "$MODE" "$PASS" "$FAIL" "${FAILED:+  failed:$FAILED}"
[[ $FAIL -eq 0 ]]
