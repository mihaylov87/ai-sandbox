# lib/backend-bwrap.sh — IR -> bwrap argument list (spec §7). Bash 3.2 compatible.
#
# Implements the backend interface (see the launcher). All options, including --setenv
# values, reach bwrap through `--args 3` (NUL-separated on a pipe); only the command line
# (init, mode, host ports, harness command) is on argv, so secrets never appear in argv. $SESSION/bwrap.argv records the arguments one per line,
# display-quoted, with secret values redacted.
#
# Test seams: _AIS_TIOCSTI_FILE (default /proc/sys/dev/tty/legacy_tiocsti) and
# _AIS_DOCKER_SOCKETS (space-separated socket paths to mask).

AIS_BWRAP=
BW_POLICY=()
AIS_BW_FULL=()

_BW_DOCKER_SOCKETS_DEFAULT="/var/run/docker.sock /run/docker.sock /run/containerd/containerd.sock /run/podman/podman.sock"

backend_preflight() {
  local v
  AIS_BWRAP=$(command -v bwrap 2>/dev/null) || ais_die 126 "bwrap not found; install bubblewrap 0.8.0 or later"
  [ -u "$AIS_BWRAP" ] && ais_die 126 "$AIS_BWRAP is setuid; ai-sandbox needs an unprivileged bwrap 0.8.0+"
  v=$("$AIS_BWRAP" --version 2>/dev/null | sed -n 's/^bubblewrap \([0-9][0-9.]*\).*/\1/p')
  case "$v" in
    0.[0-7] | 0.[0-7].*) ais_die 126 "bwrap $v is too old; 0.8.0 or later is needed for --disable-userns" ;;
    '') ais_die 126 "cannot determine the bwrap version of $AIS_BWRAP" ;;
  esac
  if [ -n "$AI_SANDBOX_LIMITS" ] && ! command -v systemd-run >/dev/null 2>&1; then
    ais_die 126 "AI_SANDBOX_LIMITS is set but systemd-run is not available"
  fi
  return 0
}

_bw() { # append args to BW_POLICY
  local a
  for a in "$@"; do BW_POLICY[${#BW_POLICY[@]}]=$a; done
}

_bw_new_session_needed() {
  local f=${_AIS_TIOCSTI_FILE:-/proc/sys/dev/tty/legacy_tiocsti} v
  [ -r "$f" ] || return 0
  v=$(cat "$f")
  [ "$v" != 0 ]
}

# Sections 1-5 of the §7 argument list.
_bw_policy() { # ir-file
  local ir=$1 class kind path hidden_dirs=() s seen=" " real
  BW_POLICY=()

  # 1. namespaces and process
  _bw --unshare-user
  if [ "${PROFILE_ALLOW_USERNS:-0}" = 1 ]; then
    ais_warn "profile $AI_SANDBOX_HARNESS sets PROFILE_ALLOW_USERNS=1: nested user namespaces are allowed (gate G9)"
  else
    _bw --disable-userns
  fi
  _bw --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
  case "$AI_SANDBOX_NET" in allowlist | none) _bw --unshare-net ;; esac
  _bw --die-with-parent
  _bw_new_session_needed && _bw --new-session
  _bw --hostname ai-sandbox

  # 2. base filesystem
  _bw --ro-bind / / --dev /dev --proc /proc --perms 1777 --tmpfs /tmp

  # 3. runtime dir for sockets
  _bw --perms 0700 --tmpfs /tmp/.ai-sandbox
  [ -n "${AIS_PROXY_SOCK-}" ] && _bw --bind "$AIS_PROXY_SOCK" /tmp/.ai-sandbox/proxy.sock
  if [ "$AI_SANDBOX_SSH_AGENT" = 1 ]; then
    _bw --bind "$(realpath "$SSH_AUTH_SOCK")" /tmp/.ai-sandbox/ssh-agent.sock
  fi
  _bw --remount-ro /tmp/.ai-sandbox

  # 4. IR lines in file order, then hidden dirs read-only
  while IFS="$_BW_TAB" read -r class kind path; do
    case "$class" in '' | '#'*) continue ;; esac
    case "$class:$kind" in
      hidden:dir) _bw --perms 0700 --tmpfs "$path"; hidden_dirs[${#hidden_dirs[@]}]=$path ;;
      hidden:file) _bw --ro-bind /dev/null "$path" ;;
      ro:* | locked:*) _bw --ro-bind "$path" "$path" ;;
      rw:*) _bw --bind "$path" "$path" ;;
      *) ais_die 125 "invalid IR line in $ir: $class $kind $path" ;;
    esac
  done <"$ir"
  for path in ${hidden_dirs[@]+"${hidden_dirs[@]}"}; do
    case "$seen" in *" $path "*) continue ;; esac # phase C repeats a path
    seen="$seen$path "
    _bw --remount-ro "$path"
  done

  # 5. masks
  if [ "$AI_SANDBOX_DOCKER" != 1 ]; then
    seen=" "
    for s in ${_AIS_DOCKER_SOCKETS-$_BW_DOCKER_SOCKETS_DEFAULT}; do
      [ -e "$s" ] || continue
      real=$(realpath "$s")
      case "$seen" in *" $real "*) continue ;; esac
      seen="$seen$real "
      _bw --ro-bind /dev/null "$real"
    done
  fi
}
_BW_TAB=$(printf '\t')

_bw_write_argv() { # file args...
  local f=$1 a
  shift
  {
    printf 'bwrap\n'
    for a in "$@"; do ais_shquote "$a"; printf '\n'; done
  } >"$f"
}

backend_compile() { # ir-file session-dir
  _bw_policy "$1"
  _bw_write_argv "$2/bwrap.argv" "${BW_POLICY[@]}"
}

backend_print() { # session-dir
  cat "$1/bwrap.argv"
}

# Section 6, and the argv to exec on the host.
backend_command() { # session-dir cwd -- command...
  local session=$1 cwd=$2 i shown=()
  shift 3
  AIS_BW_FULL=("${BW_POLICY[@]}" --clearenv)
  shown=("${BW_POLICY[@]}" --clearenv)
  i=0
  while [ "$i" -lt "${#AIS_ENV_K[@]}" ]; do
    AIS_BW_FULL[${#AIS_BW_FULL[@]}]=--setenv
    AIS_BW_FULL[${#AIS_BW_FULL[@]}]=${AIS_ENV_K[$i]}
    AIS_BW_FULL[${#AIS_BW_FULL[@]}]=${AIS_ENV_V[$i]}
    shown[${#shown[@]}]=--setenv
    shown[${#shown[@]}]=${AIS_ENV_K[$i]}
    if [ "${AIS_ENV_SECRET[$i]}" = 1 ]; then shown[${#shown[@]}]='<redacted>'; else shown[${#shown[@]}]=${AIS_ENV_V[$i]}; fi
    i=$((i + 1))
  done
  AIS_BW_FULL=("${AIS_BW_FULL[@]}" --chdir "$cwd")
  shown=("${shown[@]}" --chdir "$cwd" "$AIS_INSTALL_DIR/ai-sandbox-init" "$AI_SANDBOX_NET" "$AI_SANDBOX_HOST_PORTS" -- "$@")
  _bw_write_argv "$session/bwrap.argv" "${shown[@]}"

  [ -n "$AIS_BWRAP" ] || AIS_BWRAP=$(command -v bwrap)
  AIS_RUN_CWD=
  AIS_RUN_ENV=0
  if [ -n "$AI_SANDBOX_LIMITS" ]; then
    AIS_RUN_ARGV=(systemd-run --user --scope --quiet)
    for a in $AI_SANDBOX_LIMITS; do AIS_RUN_ARGV[${#AIS_RUN_ARGV[@]}]=-p; AIS_RUN_ARGV[${#AIS_RUN_ARGV[@]}]=$a; done
    AIS_RUN_ARGV=("${AIS_RUN_ARGV[@]}" -- "$AIS_BWRAP")
  else
    AIS_RUN_ARGV=("$AIS_BWRAP")
  fi
  # Options (with every --setenv value) come from fd 3; only the command is on argv.
  AIS_RUN_ARGV=("${AIS_RUN_ARGV[@]}" --args 3 -- "$AIS_INSTALL_DIR/ai-sandbox-init" \
    "$AI_SANDBOX_NET" "$AI_SANDBOX_HOST_PORTS" -- "$@")
}

# Runs in the child's subshell, right before the exec: feed the arguments on fd 3.
backend_child_setup() {
  exec 3< <(printf '%s\0' "${AIS_BW_FULL[@]}")
}
