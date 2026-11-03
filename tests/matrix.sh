#!/usr/bin/env bash
# Self-test matrix (spec §13). Run by `ai-sandbox --check`, which sets AIS_INSTALL_DIR,
# AIS_PLATFORM, CHK_WORK_DIR and CHK_PROJECT. Bash 3.2 compatible.
#
# Each check is a `row` call:
#   row <id> <linux|macos|both> <gate|-> <allowed|denied|skip:reason> <description> \
#       [--raw] [--with-secrets] [launcher options...] -- <command> [args...]
# --with-secrets resolves the profile's secrets for this row (H1); others run without.
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
# Rows that expect a denial exit non-zero; their session dirs are not kept.
export _AIS_NO_SECRETS=1 _AIS_CHECK_NO_GATES=1 _AIS_CHECK_NO_KEEP=1

_chk_gate() { # gate[,gate...] pass|fail
  local cur g
  [ "$1" = - ] && return 0
  for g in $(printf '%s' "$1" | tr ',' ' '); do
    eval "cur=\${_CHK_GATE_$g-}"
    if [ "$2" = fail ] || [ -z "$cur" ]; then eval "_CHK_GATE_$g=\$2"; fi
  done
}

row() {
  local id=$1 plat=$2 gate=$3 expect=$4 desc=$5 label rc got
  shift 5
  local largs=() raw=0 nosecrets=1
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
      --raw) raw=1 ;;
      --with-secrets) nosecrets=0 ;;
      *) largs[${#largs[@]}]=$1 ;;
    esac
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

  _AIS_NO_SECRETS=$nosecrets "$LAUNCHER" -H "$CHK_PROFILE" -w "$CHK_WORK_DIR" ${CHK_PROJECT:+-p "$CHK_PROJECT"} \
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
trap 'rm -f "$CHK_ERRF"; [ -n "$CHK_REPO" ] && rm -rf "$CHK_WORK_DIR/.ai-sandbox-check"; [ -n "$CHK_SRV_PID" ] && kill "$CHK_SRV_PID" 2>/dev/null' EXIT

# Inside: run argv with a 10 s limit; exit 0 if it succeeded or timed out, 1 if it failed.
_chk_timeout='import subprocess, sys
try:
    sys.exit(1 if subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode else 0)
except subprocess.TimeoutExpired:
    sys.exit(0)
except OSError:
    sys.exit(1)'

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
      sh -c 'cd "$1" && echo "$2" >f && git add f && git -c user.name=chk -c user.email=chk@invalid commit -qm chk' \
      _ "$CHK_REPO" "$CHK_PROFILE-$(date +%s)-$RANDOM"
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
  # macOS IPC (WP3). I3: find-generic-password exits 44 ("not found") on the host as well,
  # so show-keychain-info (0 on the host) is the row that can show the deny.
  row I3 macos - denied "security find-generic-password -s x" -- security find-generic-password -s x
  row I3 macos - denied "security show-keychain-info (default keychain)" -- security show-keychain-info
  # I4: `tell app "Finder" to name` is answered locally without an AppleEvent, so the probe
  # sends a real one. A run that does not finish in 10 s (waiting on an Automation prompt)
  # was not refused by the sandbox, so it counts as allowed.
  row I4 macos G1 denied "osascript sends an AppleEvent to Finder" --raw -- python3 -I -c "$_chk_timeout" \
    osascript -e 'tell application "Finder" to count windows'
  row I4 macos G1 denied "open -a TextEdit (hidden, in the background)" --raw -- python3 -I -c "$_chk_timeout" \
    open -g -j -a TextEdit
  row I5 macos - denied "pbpaste" -- pbpaste
  row I6 both G4 denied "kill -0 a host process" -- kill -0 "$$"
  # Removes the job if the submit wrongly succeeds.
  row I7 macos G1 denied "launchctl submit" -- \
    sh -c 'l=ais.chk.$$; launchctl submit -l "$l" -- /usr/bin/true; r=$?; launchctl remove "$l" 2>/dev/null; exit $r'
  row I7 both - denied "write a crontab" -- sh -c 't=$(mktemp); crontab -l >"$t" 2>/dev/null; crontab "$t"; r=$?; rm -f "$t"; exit $r'
  row I8 linux - denied "nested bwrap" -- bwrap --ro-bind / / true
  row I8 linux - denied "unshare -U" -- unshare -U true

  if [ -n "$CHK_HOST_SSH_SOCK" ] && [ -S "$CHK_HOST_SSH_SOCK" ]; then
    row I10 both - allowed "SSH agent usable when enabled" --ssh-agent -- sh -c 'ssh-add -l; [ $? -ne 2 ]'
  else
    row I10 both - skip:"no SSH agent on the host" "SSH agent usable when enabled" -- true
  fi
  # macOS has no mount namespace: an agent socket in a visible path (launchd puts it under
  # /private/tmp) stays visible, so there the check is that it cannot be reached.
  row I10 both - denied "SSH agent socket absent (macOS: unreachable) when disabled" -- \
    sh -c '[ -n "$SSH_AUTH_SOCK" ] && exit 0; [ -S /tmp/.ai-sandbox/ssh-agent.sock ] && exit 0
           [ -n "$1" ] || exit 1
           if [ "$2" = macos ]; then SSH_AUTH_SOCK=$1 ssh-add -l; [ $? -ne 2 ]; else [ -S "$1" ]; fi' \
    _ "$CHK_HOST_SSH_SOCK" "$AIS_PLATFORM"

  # macOS itself adds __CF_USER_TEXT_ENCODING (uid and text encoding) to the child.
  row E1 both - allowed "environment contains only the allowed set" --raw -- \
    python3 -I -c 'import os,sys
names = [n for n in os.environ if not (sys.platform == "darwin" and n == "__CF_USER_TEXT_ENCODING")]
sys.exit(0 if " ".join(sorted(names)) == sys.argv[1] else 1)' "$(_chk_expected_env)"

  # I9: TIOCSTI pushes one space into the controlling terminal's input; allowed = injected.
  # Needs a controlling terminal on the host (run --check from a terminal).
  if (: </dev/tty) 2>/dev/null; then
    row I9 both "$([ "$AIS_PLATFORM" = macos ] && echo G2 || echo -)" denied "TIOCSTI injection into the controlling terminal" --raw -- python3 -I -c '
import fcntl, os, sys, termios
req = getattr(termios, "TIOCSTI", 0x5412 if sys.platform.startswith("linux") else 0x80017472)
try:
    fd = os.open("/dev/tty", os.O_RDWR)
    fcntl.ioctl(fd, req, b" ")
except OSError:
    sys.exit(1)
sys.exit(0)'
  else
    row I9 both G2 skip:"no controlling terminal; run --check from a terminal" "TIOCSTI injection" -- true
  fi

  _chk_h1
  _chk_p1
  _chk_net_rows
}

# P1 (spec §13, R10): start-up to the harness exec, median of 5, under 200 ms on Linux and
# 300 ms on macOS. The stand-in harness prints the time as soon as it runs (its own Python
# start-up, about 10 ms, is counted too). Uses the configured network mode.
_chk_p1() {
  [ -z "$CHK_NET" ] || return 0
  local limit=200 ms
  [ "$AIS_PLATFORM" = macos ] && limit=300
  ms=$(python3 -I -S - "$LAUNCHER" "$CHK_PROFILE" "$CHK_WORK_DIR" "$CHK_PROJECT" <<'PY'
import subprocess, sys, time
launcher, prof, work, project = sys.argv[1:5]
cmd = [launcher, "-H", prof, "-w", work] + (["-p", project] if project else [])
cmd += ["--", "python3", "-I", "-S", "-c", "import time; print(repr(time.time()))"]
runs = []
for _ in range(5):
    t0 = time.time()
    out = subprocess.run(cmd, capture_output=True, text=True,
                         env=dict(__import__("os").environ, _AIS_NO_SECRETS="1")).stdout.strip()
    try:
        runs.append((float(out.splitlines()[-1]) - t0) * 1000)
    except (ValueError, IndexError):
        runs.append(float("inf"))
print(int(sorted(runs)[2]) if sorted(runs)[2] != float("inf") else -1)
PY
)
  hostrow P1 both - "start-up to the harness exec: median ${ms} ms (limit ${limit} ms)" -- \
    sh -c '[ "$1" -ge 0 ] && [ "$1" -lt "$2" ]' _ "$ms" "$limit"
}

# H1 (spec §13): the real harness, with a real token, once per profile. Runs only when the
# profile's secrets resolve; otherwise SKIP and the profile counts as untested.
_chk_h1() {
  local bin gates prompt
  case "$CHK_PROFILE" in
    claude) gates=G7,G8,G9,G10; prompt=(claude --dangerously-skip-permissions -p "Reply with the single word OK") ;;
    copilot) gates=G6,G8,G9,G10; prompt=(copilot --autopilot --allow-all -p "Reply with the single word OK") ;;
    generic)
      row H1 both - skip:"generic has no harness; set AI_SANDBOX_COMMAND and smoke-test it by hand" "harness smoke test" -- true
      return 0
      ;;
    *) return 0 ;;
  esac
  bin=${prompt[0]}
  if ! _AIS_NO_SECRETS=0 "$LAUNCHER" -H "$CHK_PROFILE" -w "$CHK_WORK_DIR" ${CHK_PROJECT:+-p "$CHK_PROJECT"} \
      --dry-run -- true >/dev/null 2>&1; then
    row H1 both "$gates" skip:"secrets of profile $CHK_PROFILE do not resolve; profile untested" "harness smoke test" -- true
    return 0
  fi
  row H1 both "$gates" allowed "$bin --version" --with-secrets -- "$bin" --version
  row H1 both "$gates" allowed "one prompt round trip" --with-secrets -- "${prompt[@]}"
}

# Expected result for the current network mode: _chk_mode <allowlist> <none> <open>
_chk_mode() {
  case "$CHK_NET" in allowlist) echo "$1" ;; none) echo "$2" ;; open) echo "$3" ;; esac
}

# N rows (spec §13), once per network mode. The allowlist column is the spec's table;
# none and open follow from §9 (none: no egress but host ports and local servers work;
# open: unfiltered).
_chk_net_rows() {
  [ -n "$CHK_NET" ] || return 0
  local get noproxy tcp lan dns srv g3=- inet
  get='import sys,urllib.request; urllib.request.urlopen(sys.argv[1], timeout=15)'
  noproxy='import sys,urllib.request; urllib.request.build_opener(urllib.request.ProxyHandler({})).open(sys.argv[1], timeout=15)'
  tcp='import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5).close()'
  lan='import sys,urllib.request
for u in sys.argv[1:]:
    try:
        urllib.request.urlopen(u, timeout=8)
        sys.exit(0)
    except Exception:
        pass
sys.exit(1)'
  dns='import socket,sys; socket.getaddrinfo(sys.argv[1], 443)'
  srv='import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); socket.create_connection(s.getsockname(), 5).close()'
  srv_port='import socket,sys; s=socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); socket.create_connection(s.getsockname(), 5).close()'
  [ "$AIS_PLATFORM" = macos ] && g3=G3

  if [ "$CHK_INET" = 1 ]; then
    row N1 both - "$(_chk_mode allowed denied allowed)" "HTTPS to an allowlisted host" \
      --allow-host example.com --raw -- python3 -I -c "$get" https://example.com/
    row N3 both - "$(_chk_mode denied denied allowed)" "HTTPS to an allowlisted host bypassing the proxy" \
      --allow-host example.com --raw -- python3 -I -c "$noproxy" https://example.com/
  else
    row N1 both - skip:"the host cannot reach https://example.com" "HTTPS to an allowlisted host" -- true
    row N3 both - skip:"the host cannot reach https://example.com" "HTTPS bypassing the proxy" -- true
  fi
  row N2 both - "$(_chk_mode denied denied "$([ "$CHK_INET" = 1 ] && echo allowed || echo skip:no-internet)")" \
    "HTTPS to a host that is not listed" --raw -- python3 -I -c "$get" https://example.com/
  row N4 both - "$(_chk_mode denied denied allowed)" "host localhost port that is not listed" \
    --raw -- python3 -I -c "$tcp" "$CHK_SRV_PORT"
  row N5 both - allowed "listed host port" --host-port "$CHK_SRV_PORT" --raw -- python3 -I -c "$tcp" "$CHK_SRV_PORT"
  row N6 both - "$(_chk_mode denied denied skip:"open mode does not filter")" \
    "CONNECT to a LAN address and to 169.254.169.254 (even when listed)" \
    --allow-host 192.168.1.1 --allow-host 169.254.169.254:80 --raw -- \
    python3 -I -c "$lan" https://192.168.1.1/ http://169.254.169.254/
  row N7 both "$g3" "$(_chk_mode denied denied "$([ "$CHK_INET" = 1 ] && echo allowed || echo skip:no-internet)")" \
    "resolve example.com directly" --raw -- python3 -I -c "$dns" example.com
  row N8 linux - allowed "start a server on a localhost port and connect to it" --raw -- python3 -I -c "$srv"
  # macOS (spec §8 Localhost): only listed ports; the server binds a free port listed here.
  row N8 macos - allowed "start a server on a listed localhost port and connect to it" \
    --host-port "$CHK_FREE_PORT" --raw -- python3 -I -c "$srv_port" "$CHK_FREE_PORT"
  row N8 macos - "$(_chk_mode denied denied allowed)" "connect to an own server on a port that is not listed" \
    --raw -- python3 -I -c "$srv"
}

# Host-side TCP server for N4/N5 (accepts and closes), and an internet probe for N1-N3.
CHK_SRV_PID= CHK_SRV_PORT=0 CHK_FREE_PORT=0 CHK_INET=0
_chk_start_host_server() {
  local f
  f=$(mktemp)
  python3 -I -c 'import socket,sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16)
print(s.getsockname()[1], flush=True)
while True:
    c, _ = s.accept(); c.close()' >"$f" &
  CHK_SRV_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$f" ] && break; sleep 0.1; done
  CHK_SRV_PORT=$(cat "$f")
  rm -f "$f"
  # A port that is free now, for N8 on macOS.
  CHK_FREE_PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
}

if [ -n "${_AIS_MATRIX_ROWS-}" ]; then
  matrix_rows() { . "$_AIS_MATRIX_ROWS"; }
fi

if [ -z "${_AIS_MATRIX_ROWS-}" ]; then
  _chk_start_host_server
  python3 -I -c 'import urllib.request; urllib.request.urlopen("https://example.com/", timeout=10)' \
    >/dev/null 2>&1 && CHK_INET=1
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
