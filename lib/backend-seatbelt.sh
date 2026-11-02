# lib/backend-seatbelt.sh — IR -> SBPL profile for sandbox-exec (spec §8). Bash 3.2 compatible.
#
# Implements the backend interface (see the launcher). The profile is written to
# $SESSION/profile.sb, self-contained (no -D parameters), and must pass
# `sandbox-exec -f profile.sb /usr/bin/true` before the real start. The child runs as a
# foreground job in its own process group; a watchdog started right after it ends the
# group when the launcher is gone.
#
# Test seams: _AIS_DARWIN_TEMP_DIR, _AIS_DARWIN_CACHE_DIR (instead of getconf),
# _AIS_SANDBOX_EXEC (default /usr/bin/sandbox-exec), _AIS_NO_SANDBOX_CHECK=1 (skip the
# already-sandboxed check).

AIS_SANDBOX_EXEC=${_AIS_SANDBOX_EXEC:-/usr/bin/sandbox-exec}

# Gate fallbacks (spec §15), switched on by gate_fallback_* below.
SB_G1_EXEC_DENY=0 # deny exec of launchctl, open, osascript
SB_G4_SOCKET_FORM=path-literal
SB_G4_SIGNAL=1
SB_G5_SIDE_FILES=0 # also deny <file>.lock and <file>.tmp next to locked files

_SB_TAB=$(printf '\t')
_SB_NL='
'

backend_preflight() {
  local v major
  [ -x "$AIS_SANDBOX_EXEC" ] || ais_die 126 "$AIS_SANDBOX_EXEC not found; the macOS backend needs sandbox-exec"
  v=${_AIS_MACOS_VERSION:-$(sw_vers -productVersion 2>/dev/null)}
  major=${v%%.*}
  case "$major" in '' | *[!0-9]*) ais_die 126 "cannot determine the macOS version" ;; esac
  [ "$major" -ge 14 ] || ais_die 126 "macOS $v is not supported; macOS 14 or later is needed"
  "$AIS_PYTHON" -I -S -c 'import sys; sys.exit(sys.version_info < (3, 9))' ||
    ais_die 126 "$AIS_PYTHON is older than Python 3.9"
  # Run-sequence step 2: macOS refuses sandbox_apply inside a sandbox, so refuse first.
  if [ "${_AIS_NO_SANDBOX_CHECK-}" != 1 ] && ! "$AIS_PYTHON" -I -S -c '
import ctypes, os, sys
sys.exit(1 if ctypes.CDLL(None).sandbox_check(os.getpid(), None, 0) == 1 else 0)'; then
    ais_die 126 "the launcher is already running inside a sandbox; nesting is refused"
  fi
  return 0
}

# Control characters exit 125. Called directly (not in $(...)): the profile is built with
# errexit off (out=$(_sb_profile) || ...), so a failure in a substitution would be lost.
_sb_check() { # string
  case "$1" in *[[:cntrl:]]*) ais_die 125 "path contains a control character: $(printf '%q' "$1")" ;; esac
  return 0
}

# An SBPL string literal: \ and " escaped (control characters are refused by _sb_check).
_sb_str() { # string
  local s=$1
  case "$s" in
    *\\* | *\"*) s=$(printf '%s' "$s" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g') ;;
  esac
  printf '"%s"' "$s"
}

# Resolved Darwin per-user dir without the trailing slash.
_sb_darwin_dir() { # TEMP|CACHE
  local d
  eval "d=\${_AIS_DARWIN_$1_DIR-}"
  [ -n "$d" ] || d=$(getconf "DARWIN_USER_$1_DIR" 2>/dev/null) || d=
  [ -n "$d" ] || return 0
  d=$(ais_resolve_maybe "$d")
  printf '%s\n' "$d"
}

# Is $1 equal to or below one of the hidden dirs seen so far (newline-separated list)?
_sb_in_hidden() { # path
  local h rest=$_sb_hidden
  while [ -n "$rest" ]; do
    h=${rest%%"$_SB_NL"*}
    rest=${rest#*"$_SB_NL"}
    case "$1" in "$h" | "$h"/*) return 0 ;; esac
  done
  return 1
}

# (allow file-read-metadata ...) for each ancestor of $1 inside a hidden tree, root first,
# each ancestor once per profile. Emitted right before the line that exposes $1, after
# every hidden line that could cover the ancestor (IR order is by depth), so it wins.
_sb_ancestors() { # path
  local a=$1 list= out=
  [ -n "$_sb_hidden" ] || return 0
  while :; do
    a=${a%/*}
    [ -n "$a" ] || a=/
    list="$a$_SB_NL$list"
    [ "$a" = / ] && break
  done
  while [ -n "$list" ]; do
    a=${list%%"$_SB_NL"*}
    list=${list#*"$_SB_NL"}
    case "$_sb_meta_seen" in *"$_SB_NL$a$_SB_NL"*) continue ;; esac
    _sb_in_hidden "$a" || continue
    _sb_meta_seen="$_sb_meta_seen$a$_SB_NL"
    out="$out (literal $(_sb_str "$a"))"
  done
  [ -z "$out" ] || printf '(allow file-read-metadata%s)\n' "$out"
}

_sb_filter() { # kind path -> (subpath "p") or (literal "p")
  if [ "$1" = dir ]; then printf '(subpath %s)' "$(_sb_str "$2")"; else printf '(literal %s)' "$(_sb_str "$2")"; fi
}

_sb_unix_socket() { # path
  if [ "$SB_G4_SOCKET_FORM" = literal ]; then
    printf '(allow network-outbound (literal %s))\n' "$(_sb_str "$1")"
  else
    printf '(allow network-outbound (remote unix-socket (path-literal %s)))\n' "$(_sb_str "$1")"
  fi
}

# Block 2: IR lines in file order (spec §5 compilation table).
_sb_ir() { # ir-file
  local class kind path f
  _sb_hidden= _sb_meta_seen=$_SB_NL
  while IFS="$_SB_TAB" read -r class kind path; do
    case "$class" in '' | '#'*) continue ;; esac
    case "$kind" in dir | file) ;; *) ais_die 125 "invalid IR line: $class $kind $path" ;; esac
    _sb_check "$path"
    f=$(_sb_filter "$kind" "$path")
    case "$class" in
      hidden)
        printf '(deny file-read* file-write* %s)\n' "$f"
        [ "$kind" = dir ] && _sb_hidden="$_sb_hidden$path$_SB_NL"
        ;;
      ro | locked)
        _sb_ancestors "$path"
        printf '(allow file-read* %s)\n(deny file-write* %s)\n' "$f" "$f"
        if [ "$class" = locked ] && [ "$kind" = file ] && [ "$SB_G5_SIDE_FILES" = 1 ]; then
          printf '(deny file-write* (literal %s) (literal %s))\n' "$(_sb_str "$path.lock")" "$(_sb_str "$path.tmp")"
        fi
        ;;
      rw)
        _sb_ancestors "$path"
        printf '(allow file-read* file-write* %s)\n' "$f"
        ;;
      *) ais_die 125 "invalid IR line: $class $kind $path" ;;
    esac
  done <"$1"
}

_sb_profile() { # ir-file
  local d p ssh=
  printf '(version 1)\n(allow default)\n'

  printf '\n;; 1. writes: deny all, then devices and Darwin per-user dirs\n'
  printf '(deny file-write*)\n'
  printf '(allow file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/ptmx")\n'
  printf '  (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$") (literal "/dev/dtracehelper"))\n'
  d=
  for p in "$(_sb_darwin_dir TEMP)" "$(_sb_darwin_dir CACHE)"; do
    _sb_check "$p"
    [ -n "$p" ] && d="$d (subpath $(_sb_str "$p"))"
  done
  [ -z "$d" ] || printf '(allow file-write*%s)\n' "$d"
  printf '(allow file-write* (subpath "/private/tmp"))\n'

  printf '\n;; 2. IR lines in order, compiled per section 5\n'
  _sb_ir "$1"

  printf '\n;; 3. IPC that leads outside the sandbox\n'
  [ "$AI_SANDBOX_KEYCHAIN" = allow ] ||
    printf '(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd"))\n'
  printf '(deny mach-lookup (global-name "com.apple.pasteboard.1"))\n'
  printf '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))\n'
  printf '(deny appleevent-send)\n'
  [ "$SB_G4_SIGNAL" = 1 ] && printf '(deny signal) (allow signal (target same-sandbox))\n'
  if [ "$SB_G1_EXEC_DENY" = 1 ]; then
    printf '(deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/open") (literal "/usr/bin/osascript"))\n'
  fi

  printf '\n;; 4. network (section 9)\n'
  [ "$AI_SANDBOX_SSH_AGENT" = 1 ] && ssh=$(realpath "$SSH_AUTH_SOCK")
  _sb_check "$ssh"
  printf '(deny network-outbound)\n'
  if [ "$AI_SANDBOX_NET" = open ]; then
    # Any IP; Unix sockets stay denied (Docker, OrbStack, Colima, tmux) except the SSH
    # agent and mDNSResponder, which direct connections need for DNS.
    printf '(allow network-outbound (remote ip))\n'
    [ -n "$ssh" ] && _sb_unix_socket "$ssh"
    _sb_unix_socket /private/var/run/mDNSResponder
    return 0
  fi
  if [ "${AI_SANDBOX_LOCALHOST:-isolated}" = shared ]; then
    printf '(allow network-outbound (remote ip "localhost:*"))\n'
  else
    if [ "$AI_SANDBOX_NET" = allowlist ]; then
      if [ -n "${AIS_PROXY_PORT-}" ]; then
        printf '(allow network-outbound (remote ip "localhost:%s"))\n' "$AIS_PROXY_PORT"
      else
        printf ';; the proxy port is assigned at start:\n'
        printf ';; (allow network-outbound (remote ip "localhost:<PROXY_PORT>"))\n'
      fi
    fi
    for p in $AI_SANDBOX_HOST_PORTS; do
      printf '(allow network-outbound (remote ip "localhost:%s"))\n' "$p"
    done
  fi
  printf '(allow network-bind network-inbound (local ip "localhost:*"))\n'
  [ -n "$ssh" ] && _sb_unix_socket "$ssh"
  [ "${AI_SANDBOX_DNS:-deny}" = allow ] && _sb_unix_socket /private/var/run/mDNSResponder
  return 0
}

backend_compile() { # ir-file session-dir
  local out
  out=$(_sb_profile "$1") || exit $?
  printf '%s\n' "$out" >"$2/profile.sb"
}

backend_print() { # session-dir
  cat "$1/profile.sb"
}

# The argv to exec on the host. Checks the profile first (spec §8 string safety).
backend_command() { # session-dir cwd -- command...
  local session=$1 cwd=$2 err
  shift 3
  if ! err=$("$AIS_SANDBOX_EXEC" -f "$session/profile.sb" /usr/bin/true 2>&1); then
    ais_die 125 "generated profile $session/profile.sb does not pass sandbox-exec: $err"
  fi
  AIS_RUN_CWD=$cwd
  AIS_RUN_ENV=1
  AIS_RUN_PGRP=1 # own process group, foreground on the terminal (set -m)
  AIS_RUN_ARGV=("$AIS_SANDBOX_EXEC" -f "$session/profile.sb" -- "$@")
}

# Runs once the child is started: the watchdog ends its process group when the
# launcher's PID is gone (SIGTERM, SIGKILL after 5 s).
backend_spawned() { # child-pid (= its process group)
  "$AIS_PYTHON" -I -S "$AIS_INSTALL_DIR/ai-sandbox-net" watchdog --watch-pid "$$" --kill-pgid "$1" \
    </dev/null >/dev/null 2>>"$AIS_SESSION_DIR/net.err" &
  AIS_WATCHDOG_PID=$!
  disown "$AIS_WATCHDOG_PID" 2>/dev/null || true # no job notice when the launcher stops it
}

# ---------------------------------------------------------------------------
# Gate fallbacks (spec §15). Called by gates_check for each failed gate; non-zero
# means the fallback cannot mitigate (the launcher then refuses with 123).

# G1: deny exec of the tools. Whether that suffices is not measured yet (see the WP3
# notes), so the fallback counts as mitigating.
gate_fallback_G1() {
  SB_G1_EXEC_DENY=1
}

# G4: socket rules as (literal path); the signal rule only if its form compiles.
gate_fallback_G4() {
  SB_G4_SOCKET_FORM=literal
  "$AIS_SANDBOX_EXEC" -p '(version 1)(allow default)(deny signal)(allow signal (target same-sandbox))' \
    /usr/bin/true >/dev/null 2>&1 || SB_G4_SIGNAL=0
  return 0
}

# G5: also deny creating <file>.lock and <file>.tmp next to each locked file.
gate_fallback_G5() {
  SB_G5_SIDE_FILES=1
}
