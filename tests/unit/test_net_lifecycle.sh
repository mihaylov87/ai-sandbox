# Network helper lifecycle in the launcher (spec §4 steps 7 and 10). WP11.
# Stub backend: the child runs on the host and reports what the launcher set up.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

net_fixture() {
  launcher_fixture
  cp "$REPO_ROOT/ai-sandbox-net" "$INSTALL/"
  chmod go-w "$INSTALL/ai-sandbox-net"
}

# Child: print session-dir facts and the helper processes of this launcher.
child_report='d=$(ls -d "$HOME"/.local/state/ai-sandbox/sessions/*/ | head -n 1)
  [ -S "$d/proxy.sock" ] && echo sock
  [ -f "$d/allow" ] && echo allow
  ps -A -o args= | sed -n -E "s/.*ai-sandbox-net (proxy|watchdog) .*/\1/p" | sort -u'

test_allowlist_mode_starts_proxy_on_session_socket() {
  net_fixture
  capture "$LAUNCHER" --net allowlist --allow-host example.org -- sh -c "$child_report"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "sock
allow
proxy" "$OUT"
}

test_proxy_is_stopped_after_the_child_exits() {
  net_fixture
  capture "$LAUNCHER" --net allowlist -- sh -c 'pgrep -f "ai-sandbox-net proxy .*$HOME/" >"$1"' _ "$TMP/pid"
  assert_eq 0 "$RC" "$ERR" || return 1
  local pid
  pid=$(cat "$TMP/pid")
  [ -n "$pid" ] || fail "no proxy was running during the child" || return 1
  sleep 0.3
  ! kill -0 "$pid" 2>/dev/null || fail "proxy $pid still running after the launcher exited"
}

test_open_mode_runs_watchdog_only_and_warns() {
  net_fixture
  capture "$LAUNCHER" --net open -- sh -c "$child_report"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "watchdog" "$OUT" || return 1
  assert_contains "$ERR" "network is open"
}

test_none_mode_without_host_ports_runs_watchdog_only() {
  net_fixture
  capture "$LAUNCHER" --net none -- sh -c "$child_report"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "watchdog" "$OUT"
}

test_none_mode_with_host_ports_starts_proxy_on_linux() {
  net_fixture
  capture "$LAUNCHER" --net none --host-port 11434 -- sh -c "$child_report"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "sock
allow
proxy" "$OUT"
}

test_invalid_allowlist_entry_exits_125() {
  net_fixture
  capture "$LAUNCHER" --net allowlist --allow-host 'bad*.example' -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "bad*.example"
}

test_print_policy_does_not_start_the_helper_but_shows_the_socket() {
  net_fixture
  printf 'backend_print() { cat "$1/stub.policy"; echo "proxy-sock=${AIS_PROXY_SOCK-}"; }\n' >>"$INSTALL/tests/unit/backend-stub.sh"
  capture "$LAUNCHER" --net allowlist --print-policy
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "proxy-sock=$SESSIONS/" || return 1
  assert_eq "" "$(pgrep -f "ai-sandbox-net proxy .*$HOME" || true)"
}
