#!/usr/bin/env bash
# Self-test matrix (spec §13). Run by `ai-sandbox --check`, which sets AIS_INSTALL_DIR,
# AIS_PLATFORM, CHK_WORK_DIR and CHK_PROJECT. Bash 3.2 compatible.
#
# Each check is a `row` call:
#   row <id> <linux|macos|both> <gate|-> <allowed|denied|skip:reason> <description> \
#       [--raw] [launcher options...] -- <command> [args...]
# --raw execs the command directly instead of through `sh -c` (which adds PWD to the
# environment); it must then exit 0 or 1 itself. `hostrow` runs a check on the host:
#   hostrow <id> <linux|macos|both> <gate|-> <description> -- <command> [args...]
# The command runs in a sandbox built from the active config (launcher -H <profile>
# -- command), once per installed profile with the stub command in place of the harness;
# rows whose id starts with N run once per network mode instead, with CHK_NET set.
# Exit 0 inside = allowed, exit non-zero = denied; a launcher exit code (123-127) or a
# signal is a FAIL whatever was expected. Rows are evaluated per run, so they can use
# CHK_PROFILE, CHK_NET, CHK_WORK_DIR.
set -uo pipefail

. "$AIS_INSTALL_DIR/lib/config.sh"
. "$AIS_INSTALL_DIR/lib/gates.sh"

LAUNCHER="$AIS_INSTALL_DIR/ai-sandbox"
CHK_PASS=0 CHK_FAIL=0 CHK_SKIP=0
CHK_PROFILE= CHK_NET=
CHK_ERRF=$(mktemp)

# Children: no secrets needed (stub command), and gates are measured, not applied.
export _AIS_NO_SECRETS=1 _AIS_CHECK_NO_GATES=1

_chk_gate() { # gate pass|fail
  local cur
  [ "$1" = - ] && return 0
  eval "cur=\${_CHK_GATE_$1-}"
  if [ "$2" = fail ] || [ -z "$cur" ]; then eval "_CHK_GATE_$1=\$2"; fi
}

row() {
  local id=$1 plat=$2 gate=$3 expect=$4 desc=$5 label rc got
  shift 5
  local largs=() raw=0
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    if [ "$1" = --raw ]; then raw=1; else largs[${#largs[@]}]=$1; fi
    shift
  done
  [ "$#" -gt 0 ] && shift
  if [ "$raw" = 0 ]; then set -- sh -c '"$@" >/dev/null 2>&1 && exit 0; exit 1' chk "$@"; fi

  case "$id" in
    N*) [ -n "$CHK_NET" ] || return 0 ;;
    *) [ -z "$CHK_NET" ] || return 0 ;;
  esac
  label="[$CHK_PROFILE${CHK_NET:+/$CHK_NET}]"

  if [ "$plat" != both ] && [ "$plat" != "$AIS_PLATFORM" ]; then
    printf 'SKIP %s %s %s (%s only)\n' "$id" "$label" "$desc" "$plat"
    CHK_SKIP=$((CHK_SKIP + 1))
    return 0
  fi
  case "$expect" in
    skip:*)
      printf 'SKIP %s %s %s (%s)\n' "$id" "$label" "$desc" "${expect#skip:}"
      CHK_SKIP=$((CHK_SKIP + 1))
      return 0
      ;;
  esac

  "$LAUNCHER" -H "$CHK_PROFILE" -w "$CHK_WORK_DIR" ${CHK_PROJECT:+-p "$CHK_PROJECT"} \
    ${CHK_NET:+--net "$CHK_NET"} ${largs[@]+"${largs[@]}"} \
    -- "$@" </dev/null >/dev/null 2>"$CHK_ERRF"
  rc=$?
  case "$rc" in
    0) got=allowed ;;
    1) got=denied ;;
    *) got="launcher exit $rc" ;;
  esac
  if [ "$got" = "$expect" ]; then
    printf 'PASS %s %s %s\n' "$id" "$label" "$desc"
    CHK_PASS=$((CHK_PASS + 1))
    _chk_gate "$gate" pass
  else
    case "$got" in
      launcher*) printf 'FAIL %s %s %s (%s)\n' "$id" "$label" "$desc" "$got" ;;
      *) printf 'FAIL %s %s %s (expected %s, got %s)\n' "$id" "$label" "$desc" "$expect" "$got" ;;
    esac
    [ -s "$CHK_ERRF" ] && sed -n '1,3s/^/     /p' "$CHK_ERRF"
    CHK_FAIL=$((CHK_FAIL + 1))
    _chk_gate "$gate" fail
  fi
}

hostrow() {
  local id=$1 plat=$2 gate=$3 desc=$4 label
  shift 4
  [ "${1-}" = -- ] && shift
  [ -z "$CHK_NET" ] || return 0
  label="[$CHK_PROFILE]"
  if [ "$plat" != both ] && [ "$plat" != "$AIS_PLATFORM" ]; then
    printf 'SKIP %s %s %s (%s only)\n' "$id" "$label" "$desc" "$plat"
    CHK_SKIP=$((CHK_SKIP + 1))
    return 0
  fi
  if "$@" >/dev/null 2>&1; then
    printf 'PASS %s %s %s\n' "$id" "$label" "$desc"
    CHK_PASS=$((CHK_PASS + 1))
    _chk_gate "$gate" pass
  else
    printf 'FAIL %s %s %s (host check failed)\n' "$id" "$label" "$desc"
    CHK_FAIL=$((CHK_FAIL + 1))
    _chk_gate "$gate" fail
  fi
}

# ---------------------------------------------------------------------------
# Helpers for rows (host side).

# Locked paths of the current profile, resolved against its state dir.
_chk_profile_locked() {
  (
    PROFILE_LOCKED=() PROFILE_STATE_DIR=
    . "$AIS_INSTALL_DIR/profiles/$CHK_PROFILE.sh" >/dev/null 2>&1 || exit 0
    if [ "$CHK_STATE" = shared ]; then st=$PROFILE_STATE_DIR; else st="$CHK_HOME/.local/state/ai-sandbox/$CHK_PROFILE"; fi
    for p in ${PROFILE_LOCKED[@]+"${PROFILE_LOCKED[@]}"}; do printf '%s/%s\n' "$st" "$p"; done
  )
}

# Variable names the launcher sets for the current profile (from --dry-run).
_chk_expected_env() {
  "$LAUNCHER" -H "$CHK_PROFILE" -w "$CHK_WORK_DIR" ${CHK_PROJECT:+-p "$CHK_PROJECT"} --dry-run -- true 2>/dev/null |
    sed -n '/^# environment$/,/^cwd: /p' | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

_chk_split() { # colon-list -> lines
  printf '%s\n' "$1" | tr ':' '\n' | sed '/^$/d; s/?$//'
}

# Scratch Git repo inside the work dir (found by repo detection, depth 2); F9, F10.
CHK_REPO=
_chk_make_repo() {
  [ -n "$CHK_REPO" ] && return 0
  command -v git >/dev/null 2>&1 || return 1
  CHK_REPO="$CHK_WORK_DIR/.ai-sandbox-check/repo"
  rm -rf "$CHK_WORK_DIR/.ai-sandbox-check"
  mkdir -p "$CHK_REPO" && git init -q "$CHK_REPO" && mkdir -p "$CHK_REPO/.git/hooks" "$CHK_REPO/.git/info"
}
trap 'rm -f "$CHK_ERRF"; [ -n "$CHK_REPO" ] && rm -rf "$CHK_WORK_DIR/.ai-sandbox-check"' EXIT

# ---------------------------------------------------------------------------
# Rows (spec §13). macOS-only rows: WP3. N rows: WP11. I9: WP12. H1: WP6. P1: WP8.
matrix_rows() {
  local h=$CHK_HOME w=$CHK_WORK_DIR d f n found

  row F1 both - allowed "write a file in the work dir" -- sh -c 'f="$1/.ais-chk-f1.$$"; : >"$f" && rm -f "$f"' _ "$w"

  for d in "$h/.cache/ai-sandbox/cache" $(_chk_split "$CHK_TEST_RW_DIR"); do
    row F2 both - allowed "write $d" -- sh -c 'f="$1/.ais-chk-f2.$$"; : >"$f" && rm -f "$f"' _ "$d"
  done

  found=0
  for d in $(_chk_split "$CHK_TEST_RO_DIR"); do
    found=1
    row F3 both - allowed "read $d" -- ls "$d"
    row F3 both - denied "write $d" -- sh -c ': >"$1/.ais-chk-f3"' _ "$d"
  done
  [ "$found" = 1 ] || row F3 both - skip:"no AI_SANDBOX_TEST_RO_DIR set" "read and write test RO dirs" -- true

  found=0
  for f in "$h"/.ssh/id_* "$h/.aws/credentials" "$h/Library/Keychains" \
           $(ls -A "$h/.cache" 2>/dev/null | grep -vx ai-sandbox | head -n 1 | sed "s|^|$h/.cache/|") \
           $(ls -A "$(dirname "$w")" 2>/dev/null | grep -vx "$(basename "$w")" | head -n 1 | sed "s|^|$(dirname "$w")/|"); do
    [ -e "$f" ] || continue
    found=1
    row F4 both - denied "read $f" -- sh -c 'cat "$1" || ls "$1"' _ "$f"
  done
  [ "$found" = 1 ] || row F4 both - skip:"no secrets, caches or sibling projects on this host" "read hidden host paths" -- true

  for f in "$h/.gitconfig" "$h/.ssh/known_hosts"; do
    if [ -e "$f" ] && _chk_split "$CHK_RO_PATHS" | grep -qx "$f"; then
      row F5 both - allowed "read $f (listed RO)" -- cat "$f"
    else
      row F5 both - skip:"not listed in AI_SANDBOX_RO_PATHS" "read $f" -- true
    fi
  done

  row F6 both - denied "write \$HOME top level" -- sh -c ': >"$1/.ais-chk-f6"' _ "$h"
  row F6 both - denied "write ~/.bashrc" -- sh -c ': >>"$1/.bashrc"' _ "$h"
  row F6 both - denied "write ~/.config" -- sh -c ': >"$1/.config/.ais-chk-f6"' _ "$h"
  row F6 both - denied "write ~/.local/bin" -- sh -c 'mkdir -p "$1/.local/bin" && : >"$1/.local/bin/.ais-chk-f6"' _ "$h"

  row F7 both - denied "write /etc" -- sh -c ': >/etc/.ais-chk-f7'
  row F7 both - denied "write /usr/local" -- sh -c ': >/usr/local/.ais-chk-f7'
  found=0
  for d in /mnt /media /Volumes; do
    f=$(ls -A "$d" 2>/dev/null | head -n 1)
    [ -n "$f" ] || continue
    found=1
    row F7 both - denied "read $d/$f" -- ls "$d/$f"
  done
  [ "$found" = 1 ] || row F7 both - skip:"nothing mounted under /mnt, /media or /Volumes" "read mounts" -- true

  # Removes its file if the write wrongly succeeds, so later rows still run.
  row F8 both - denied "write the install dir" -- sh -c ': >"$1/.ais-chk-f8" && rm -f "$1/.ais-chk-f8"' _ "$AIS_INSTALL_DIR"
  row F8 both - denied "write the config" -- sh -c ': >>"$1/.config/ai-sandbox/config"' _ "$h"
  for f in $(_chk_profile_locked); do
    [ -e "$f" ] || continue
    if [ -d "$f" ]; then
      row F8 both - denied "write locked $f" -- sh -c ': >"$1/.ais-chk-f8"' _ "$f"
    else
      row F8 both - denied "write locked $f" -- sh -c ': >>"$1"' _ "$f"
    fi
  done

  if _chk_make_repo; then
    row F9 both - denied "write .git/hooks/x" -- sh -c ': >"$1/.git/hooks/x"' _ "$CHK_REPO"
    row F9 both - denied "write .git/info/x" -- sh -c ': >"$1/.git/info/x"' _ "$CHK_REPO"
    row F9 both G5 denied "rename a file onto .git/config" -- \
      sh -c 't="$1/.git/ais-chk.$$"; : >"$t" || exit 0; mv -f "$t" "$1/.git/config"; r=$?; rm -f "$t"; exit $r' _ "$CHK_REPO"
    row F10 both - allowed "git add and git commit" -- \
      sh -c 'cd "$1" && echo "$$" >f && git add f && git -c user.name=chk -c user.email=chk@invalid commit -qm chk' _ "$CHK_REPO"
  else
    row F9 both - skip:"git not installed" "write Git internals" -- true
    row F10 both - skip:"git not installed" "git add and commit" -- true
  fi

  n=/tmp/.ais-chk-f11.$$
  row F11 both - allowed "write /tmp/x" -- sh -c ': >"$1"' _ "$n"
  hostrow F11 linux - "/tmp/x is absent on the host" -- sh -c '! test -e "$1"' _ "$n"
  hostrow F11 macos - "/tmp/x is present on the host" -- sh -c 'test -e "$1" && rm -f "$1"' _ "$n"

  row I1 both - denied "docker ps" -- docker ps
  row I2 linux - denied "D-Bus session bus: org.freedesktop.secrets" -- sh -c \
    'dbus-send --session --print-reply --dest=org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.DBus.Peer.Ping ||
     dbus-send --bus="unix:path=/run/user/$(id -u)/bus" --print-reply --dest=org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.DBus.Peer.Ping'
  row I6 both G4 denied "kill -0 a host process" -- kill -0 "$$"
  row I7 both - denied "write a crontab" -- sh -c 't=$(mktemp); crontab -l >"$t" 2>/dev/null; crontab "$t"; r=$?; rm -f "$t"; exit $r'
  row I8 linux - denied "nested bwrap" -- bwrap --ro-bind / / true
  row I8 linux - denied "unshare -U" -- unshare -U true

  if [ -n "$CHK_HOST_SSH_SOCK" ] && [ -S "$CHK_HOST_SSH_SOCK" ]; then
    row I10 both - allowed "SSH agent usable when enabled" --ssh-agent -- sh -c 'ssh-add -l; [ $? -ne 2 ]'
  else
    row I10 both - skip:"no SSH agent on the host" "SSH agent usable when enabled" -- true
  fi
  row I10 both - denied "SSH agent socket absent when disabled" -- \
    sh -c '[ -n "$SSH_AUTH_SOCK" ] || [ -S /tmp/.ai-sandbox/ssh-agent.sock ] || { [ -n "$1" ] && [ -S "$1" ]; }' _ "$CHK_HOST_SSH_SOCK"

  row E1 both - allowed "environment contains only the allowed set" --raw -- \
    python3 -I -c 'import os,sys; sys.exit(0 if " ".join(sorted(os.environ)) == sys.argv[1] else 1)' "$(_chk_expected_env)"
}

if [ -n "${_AIS_MATRIX_ROWS-}" ]; then
  matrix_rows() { . "$_AIS_MATRIX_ROWS"; }
fi

for prof in "$AIS_INSTALL_DIR"/profiles/*.sh; do
  [ -f "$prof" ] || continue
  CHK_PROFILE=$(basename "$prof" .sh)
  CHK_NET=
  matrix_rows
  for CHK_NET in allowlist none open; do matrix_rows; done
done

for g in $CFG_GATES; do
  eval "res=\${_CHK_GATE_$g-}"
  [ -n "$res" ] && gates_record "$g" "$res"
done

printf '%d passed, %d failed, %d skipped\n' "$CHK_PASS" "$CHK_FAIL" "$CHK_SKIP"
[ "$CHK_FAIL" -eq 0 ]
