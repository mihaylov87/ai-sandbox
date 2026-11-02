# lib/net.sh — egress allowlist and network helper lifecycle (spec §9). Bash 3.2 compatible.
#
# net_write_allow FILE writes $SESSION/allow, merged in this order with duplicates removed:
# profile baseline (PROFILE_NET_ALLOW); the host of COPILOT_PROVIDER_BASE_URL, COPILOT_API_URL
# or ANTHROPIC_BASE_URL if set; presets (AI_SANDBOX_NET_PRESETS); AI_SANDBOX_NET_ALLOW (which
# already holds --allow-host entries, appended by the CLI). Entries are validated by the proxy.

net_preset() { # name -> entries, one per line
  case "$1" in
    npm) printf '%s\n' registry.npmjs.org ;;
    pypi) printf '%s\n' pypi.org files.pythonhosted.org ;;
    github) printf '%s\n' github.com api.github.com codeload.github.com objects.githubusercontent.com \
      raw.githubusercontent.com github.com:22 ;;
    crates) printf '%s\n' crates.io static.crates.io index.crates.io ;;
    go) printf '%s\n' proxy.golang.org sum.golang.org ;;
  esac
}

# Host (with an explicit port, if the URL has one) of an http(s) URL.
net_url_host() {
  local u=$1
  u=${u#*://}
  u=${u%%/*}
  u=${u%%\?*}
  u=${u##*@}
  printf '%s\n' "$u"
}

net_write_allow() { # file
  local f=$1 e v seen=" " entries
  entries=$(
    for e in ${PROFILE_NET_ALLOW[@]+"${PROFILE_NET_ALLOW[@]}"}; do printf '%s\n' "$e"; done
    for v in COPILOT_PROVIDER_BASE_URL COPILOT_API_URL ANTHROPIC_BASE_URL; do
      [ -n "${!v-}" ] && net_url_host "${!v}"
    done
    for e in $AI_SANDBOX_NET_PRESETS; do net_preset "$e"; done
    set -f
    for e in $AI_SANDBOX_NET_ALLOW; do printf '%s\n' "$e"; done
  )
  {
    printf '# ai-sandbox allowlist, generated for this session (spec section 9)\n'
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      case "$seen" in *" $e "*) continue ;; esac
      seen="$seen$e "
      printf '%s\n' "$e"
    done <<EOF
$entries
EOF
  } >"$f"
}

# ---------------------------------------------------------------------------
# Helper lifecycle (run sequence steps 7 and 10).
#
# allowlist mode, and none mode on Linux with host ports: ai-sandbox-net proxy (Linux on
# $SESSION/proxy.sock, bound into the sandbox; macOS on tcp:127.0.0.1:0). Otherwise the
# helper runs as watchdog only. Either way it exits when the launcher's PID is gone.

AIS_NET_PID=
AIS_PROXY_SOCK=
AIS_PROXY_PORT=

_net_needs_proxy() {
  [ "$AI_SANDBOX_NET" = allowlist ] && return 0
  [ "$AI_SANDBOX_NET" = none ] && [ "$AIS_PLATFORM" = linux ] && [ -n "$AI_SANDBOX_HOST_PORTS" ] && return 0
  return 1
}

# Sets what the compiled policy refers to; used for output-only modes too.
net_prepare() {
  AIS_PROXY_SOCK=
  if _net_needs_proxy && [ "$AIS_PLATFORM" = linux ]; then AIS_PROXY_SOCK="$AIS_SESSION_DIR/proxy.sock"; fi
  return 0
}

# net_launch starts the helper early (right after the session dir exists) so its start-up
# overlaps with building the policy; net_wait then waits for the proxy's READY line (at most
# 5 s) before the policy is compiled. The watchdog is not waited for: it listens on nothing,
# and on Linux bwrap's --die-with-parent covers a launcher that dies.
AIS_NET_FIFO_FD=

net_launch() {
  local fifo="$AIS_SESSION_DIR/net.ready" errf="$AIS_SESSION_DIR/net.err" kill_pgid=0 listen
  net_prepare
  [ "$AI_SANDBOX_NET" = open ] && ais_warn "network is open (AI_SANDBOX_NET=open): egress is not restricted"
  [ -x "$AIS_INSTALL_DIR/ai-sandbox-net" ] || ais_die 126 "ai-sandbox-net not found in $AIS_INSTALL_DIR"
  [ -n "${AIS_KILL_PGID-}" ] && kill_pgid=$AIS_KILL_PGID
  if _net_needs_proxy; then
    net_write_allow "$AIS_SESSION_DIR/allow"
    if [ "$AIS_PLATFORM" = linux ]; then listen="unix:$AIS_PROXY_SOCK"; else listen="tcp:127.0.0.1:0"; fi
    mkfifo -m 0600 "$fifo"
    "$AIS_PYTHON" -I -S "$AIS_INSTALL_DIR/ai-sandbox-net" proxy --listen "$listen" \
      --allow-file "$AIS_SESSION_DIR/allow" --host-ports "$AI_SANDBOX_HOST_PORTS" \
      ${AI_SANDBOX_UPSTREAM_PROXY:+--upstream "$AI_SANDBOX_UPSTREAM_PROXY"} \
      --log "$AIS_SESSION_DIR/net.log" --watch-pid "$$" --kill-pgid "$kill_pgid" \
      </dev/null >"$fifo" 2>"$errf" &
    AIS_NET_PID=$!
    # Open the read end now (the helper holds the write end), so net_wait cannot block.
    exec 4<"$fifo"
    AIS_NET_FIFO_FD=4
    rm -f "$fifo"
  else
    "$AIS_PYTHON" -I -S "$AIS_INSTALL_DIR/ai-sandbox-net" watchdog --watch-pid "$$" --kill-pgid "$kill_pgid" \
      </dev/null >/dev/null 2>"$errf" &
    AIS_NET_PID=$!
  fi
}

net_wait() {
  local line= rc errf="$AIS_SESSION_DIR/net.err"
  [ -n "$AIS_NET_FIFO_FD" ] || return 0
  read -r -t 5 line <&4 || true
  exec 4<&-
  AIS_NET_FIFO_FD=
  case "$line" in
    "READY tcp:127.0.0.1:"*) AIS_PROXY_PORT=${line##*:} ;;
    READY*) ;;
    *)
      kill "$AIS_NET_PID" 2>/dev/null || true
      rc=126
      grep -q 'allow file' "$errf" 2>/dev/null && rc=125
      ais_die "$rc" "network helper did not start: $(cat "$errf" 2>/dev/null)"
      ;;
  esac
  # macOS: the proxy port is known only now.
  if [ -n "$AIS_PROXY_PORT" ] && [ "$AI_SANDBOX_NET" != open ] && declare -F env_proxy >/dev/null; then
    env_proxy "$AIS_PROXY_PORT"
  fi
}

net_start() {
  net_launch
  net_wait
}

net_stop() {
  [ -n "$AIS_NET_PID" ] || return 0
  kill "$AIS_NET_PID" 2>/dev/null || true
  wait "$AIS_NET_PID" 2>/dev/null || true
  AIS_NET_PID=
  [ -n "$AIS_PROXY_SOCK" ] && rm -f "$AIS_PROXY_SOCK"
  return 0
}
