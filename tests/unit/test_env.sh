# Environment and secrets (spec §10). WP5. Runs the launcher with the stub backend,
# so the child's environment is exactly what the launcher hands over.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

SENTINEL=s3cr3t-SENTINEL-value

env_fixture() {
  launcher_fixture
  mkdir -p "$HOME/bin"
  chmod go-w "$HOME/bin"
  # A controlled calling environment on top of whatever the test runner has.
  export TERM=xterm-test LANG=C.UTF-8 LC_TIME=C COLORTERM=truecolor EDITOR=vi HERDR_PANE=7
  export FOO=bar HTTPS_PROXY=http://host-proxy:1 https_proxy=http://host-proxy:1 GH_TOKEN=caller-token
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/x DISPLAY=:0
  unset TZ VISUAL GH_HOST LC_ALL SSH_AUTH_SOCK
  local v
  for v in $(compgen -e | grep -E '^(HERDR_|LC_)' || true); do
    case "$v" in HERDR_PANE | LC_TIME) ;; *) unset "$v" ;; esac
  done
}

# Run `env` inside; set ENV_OUT to its output (sorted).
run_env() {
  capture "$LAUNCHER" "$@" -- env
  ENV_OUT=$(printf '%s\n' "$OUT" | LC_ALL=C sort)
}

env_names() { printf '%s\n' "$ENV_OUT" | sed 's/=.*//' | LC_ALL=C sort | tr '\n' ' '; }

env_value() { # name
  printf '%s\n' "$ENV_OUT" | sed -n "s/^$1=//p"
}

test_environment_contains_only_the_allowed_set() {
  env_fixture
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX AI_SANDBOX_HARNESS AI_SANDBOX_NET ALL_PROXY COLORTERM EDITOR GIT_SSH_COMMAND HERDR_PANE HOME HTTPS_PROXY HTTP_PROXY LANG LC_TIME LOGNAME NODE_USE_ENV_PROXY NO_PROXY PATH PIP_CACHE_DIR SHELL TERM TMPDIR USER XDG_CACHE_HOME all_proxy http_proxy https_proxy no_proxy npm_config_cache " "$(env_names)"
}

test_launcher_set_values() {
  env_fixture
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  local expected_path= d
  for d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
    [ -d "$d" ] && expected_path=${expected_path:+$expected_path:}$d
  done
  assert_eq "$HOME" "$(env_value HOME)" || return 1
  assert_eq "$(id -un)" "$(env_value USER)" || return 1
  assert_eq "$(id -un)" "$(env_value LOGNAME)" || return 1
  assert_eq /bin/bash "$(env_value SHELL)" || return 1
  assert_eq "$expected_path" "$(env_value PATH)" || return 1
  assert_eq /tmp "$(env_value TMPDIR)" || return 1
  assert_eq "$HOME/.cache/ai-sandbox/cache" "$(env_value XDG_CACHE_HOME)" || return 1
  assert_eq "$HOME/.cache/ai-sandbox/cache/npm" "$(env_value npm_config_cache)" || return 1
  assert_eq "$HOME/.cache/ai-sandbox/cache/pip" "$(env_value PIP_CACHE_DIR)" || return 1
  [ -d "$HOME/.cache/ai-sandbox/cache/npm" ] && [ -d "$HOME/.cache/ai-sandbox/cache/pip" ] ||
    fail "cache dirs not created" || return 1
  assert_eq 1 "$(env_value AI_SANDBOX)" || return 1
  assert_eq stub "$(env_value AI_SANDBOX_HARNESS)" || return 1
  assert_eq allowlist "$(env_value AI_SANDBOX_NET)" || return 1
  assert_eq xterm-test "$(env_value TERM)" || return 1
  assert_eq truecolor "$(env_value COLORTERM)"
}

test_proxy_variables_on_linux() {
  env_fixture
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  local v
  for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy; do
    assert_eq http://127.0.0.1:3128 "$(env_value $v)" "$v" || return 1
  done
  assert_eq localhost,127.0.0.1,::1 "$(env_value NO_PROXY)" || return 1
  assert_eq localhost,127.0.0.1,::1 "$(env_value no_proxy)" || return 1
  assert_eq 1 "$(env_value NODE_USE_ENV_PROXY)" || return 1
  assert_eq "ssh -o ProxyCommand='nc -X connect -x 127.0.0.1:3128 %h %p'" "$(env_value GIT_SSH_COMMAND)"
}

test_no_proxy_variables_in_open_mode() {
  env_fixture
  run_env --net open
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$(env_names)" "PROXY" || return 1
  assert_not_contains "$(env_names)" "GIT_SSH_COMMAND"
}

test_pass_env_forwards_listed_names_only() {
  env_fixture
  export MYVAR=hello OTHER=no
  run_env
  assert_eq "" "$(env_value MYVAR)" || return 1
  printf 'AI_SANDBOX_PASS_ENV="MYVAR UNSET_ONE"\n' >>"$CONF/config"
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq hello "$(env_value MYVAR)" || return 1
  assert_eq "" "$(env_value OTHER)" || return 1
  assert_not_contains "$(env_names)" "UNSET_ONE"
}

test_never_forwarded_names_in_pass_env_exit_125() {
  local n
  for n in SSH_AUTH_SOCK DOCKER_HOST DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR DISPLAY WAYLAND_DISPLAY \
           AWS_SECRET_ACCESS_KEY GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET KUBECONFIG \
           NPM_TOKEN GH_TOKEN GITHUB_TOKEN; do
    env_fixture
    printf 'AI_SANDBOX_PASS_ENV="%s"\n' "$n" >>"$CONF/config"
    capture "$LAUNCHER" -- true
    assert_eq 125 "$RC" "$n" || return 1
    assert_contains "$ERR" "$n" || return 1
  done
}

test_host_proxy_variables_are_not_forwarded() {
  env_fixture
  printf 'AI_SANDBOX_PASS_ENV="HTTPS_PROXY https_proxy"\n' >>"$CONF/config"
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq http://127.0.0.1:3128 "$(env_value HTTPS_PROXY)" || return 1
  assert_contains "$ERR" "AI_SANDBOX_UPSTREAM_PROXY"
}

test_ssh_agent_socket_variable_when_enabled() {
  env_fixture
  export SSH_AUTH_SOCK="$TMP/agent.sock"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SSH_AUTH_SOCK"
  run_env --ssh-agent
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq /tmp/.ai-sandbox/ssh-agent.sock "$(env_value SSH_AUTH_SOCK)" || return 1
  run_env
  assert_eq "" "$(env_value SSH_AUTH_SOCK)"
}

test_ssh_agent_enabled_without_host_socket_exits_125() {
  env_fixture
  capture "$LAUNCHER" --ssh-agent -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "SSH_AUTH_SOCK"
}

test_profile_env_pass_env_and_path_add() {
  env_fixture
  mkdir -p "$TMP/tools"
  export PROF_PASS=yes
  cat >"$INSTALL/profiles/stub.sh" <<EOF
PROFILE_ENV=(STUB_MODE=on "STUB_DIR=\$HOME/x y")
PROFILE_PASS_ENV=(PROF_PASS PROF_MISSING)
PROFILE_PATH_ADD=("$TMP/tools")
EOF
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq on "$(env_value STUB_MODE)" || return 1
  assert_eq "$HOME/x y" "$(env_value STUB_DIR)" || return 1
  assert_eq yes "$(env_value PROF_PASS)" || return 1
  assert_contains "$(env_value PATH)" ":$TMP/tools"
}

stub_profile_with_secrets() {
  printf 'PROFILE_SECRETS=(STUB_TOKEN=stub STUB_OPT=stub-opt?)\n' >"$INSTALL/profiles/stub.sh"
}

test_secret_from_command() {
  env_fixture
  stub_profile_with_secrets
  printf "AI_SANDBOX_SECRET_CMD_STUB_TOKEN='echo %s'\n" "$SENTINEL" >>"$CONF/config"
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$SENTINEL" "$(env_value STUB_TOKEN)" || return 1
  assert_not_contains "$(env_names)" "STUB_OPT"
}

test_secret_from_file_mode_0600() {
  env_fixture
  stub_profile_with_secrets
  mkdir -p -m 0700 "$CONF/secrets"
  printf '%s\n' "$SENTINEL" >"$CONF/secrets/stub"
  chmod 0600 "$CONF/secrets/stub"
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$SENTINEL" "$(env_value STUB_TOKEN)"
}

test_secret_file_with_other_mode_exits_125() {
  env_fixture
  stub_profile_with_secrets
  mkdir -p -m 0700 "$CONF/secrets"
  printf '%s\n' "$SENTINEL" >"$CONF/secrets/stub"
  chmod 0640 "$CONF/secrets/stub"
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "$CONF/secrets/stub" || return 1
  assert_contains "$ERR" "0600"
}

test_missing_required_secret_exits_125_naming_variable_and_profile() {
  env_fixture
  stub_profile_with_secrets
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "STUB_TOKEN" || return 1
  assert_contains "$ERR" "profile stub"
}

test_failing_secret_command_exits_125() {
  env_fixture
  stub_profile_with_secrets
  printf 'AI_SANDBOX_SECRET_CMD_STUB_TOKEN="exit 3"\n' >>"$CONF/config"
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_SECRET_CMD_STUB_TOKEN"
}

test_secret_variable_is_never_copied_from_caller() {
  env_fixture
  stub_profile_with_secrets
  printf 'AI_SANDBOX_SECRET_CMD_STUB_TOKEN="echo from-secret"\nAI_SANDBOX_PASS_ENV=STUB_TOKEN\n' >>"$CONF/config"
  export STUB_TOKEN=from-caller
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "STUB_TOKEN"
}

test_secret_cmd_for_non_profile_variable() {
  env_fixture
  printf 'AI_SANDBOX_SECRET_CMD_GH_TOKEN="echo scoped-token"\n' >>"$CONF/config"
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq scoped-token "$(env_value GH_TOKEN)"
}

test_secret_never_in_argv_session_files_or_dry_run() {
  env_fixture
  stub_profile_with_secrets
  printf "AI_SANDBOX_SECRET_CMD_STUB_TOKEN='echo %s'\n" "$SENTINEL" >>"$CONF/config"
  # Child: wait for the marker, then exit 1 so the session dir is kept.
  "$LAUNCHER" --keep-session -- sh -c "touch '$TMP/started'; while [ ! -e '$TMP/go' ]; do sleep 0.05; done; exit 1" &
  local pid=$! n=0 p hits=
  while [ ! -e "$TMP/started" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  for p in $(pgrep -s 0 2>/dev/null; pgrep -P "$pid"; echo "$pid"); do
    [ -r "/proc/$p/cmdline" ] && tr '\0' ' ' <"/proc/$p/cmdline" | grep -q "$SENTINEL" && hits="$hits $p"
  done
  touch "$TMP/go"
  wait "$pid" || true
  assert_eq "" "$hits" "secret visible in argv of pid(s)" || return 1
  assert_eq "" "$(grep -rl "$SENTINEL" "$SESSIONS" 2>/dev/null)" "secret in session files" || return 1
  capture "$LAUNCHER" --dry-run -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$OUT" "$SENTINEL" || return 1
  assert_contains "$OUT" "STUB_TOKEN=<redacted>"
}

test_macos_hidden_gitconfig_gets_an_empty_global_git_config() {
  env_fixture
  export _AIS_TEST_PLATFORM=macos
  : >"$HOME/.gitconfig"
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq /dev/null "$(env_value GIT_CONFIG_GLOBAL)" || return 1
  # Listed RO: git reads it as usual.
  run_env --ro "$HOME/.gitconfig"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "" "$(env_value GIT_CONFIG_GLOBAL)" || return 1
  # A forwarded value wins.
  export GIT_CONFIG_GLOBAL=/etc/gitconfig.sandbox AI_SANDBOX_PASS_ENV=GIT_CONFIG_GLOBAL
  run_env
  assert_eq /etc/gitconfig.sandbox "$(env_value GIT_CONFIG_GLOBAL)" || return 1
  # Linux: not set.
  unset GIT_CONFIG_GLOBAL AI_SANDBOX_PASS_ENV
  export _AIS_TEST_PLATFORM=linux
  run_env
  assert_eq "" "$(env_value GIT_CONFIG_GLOBAL)"
}

test_macos_dry_run_lists_proxy_variables_with_a_placeholder_port() {
  env_fixture
  export _AIS_TEST_PLATFORM=macos
  capture "$LAUNCHER" --dry-run -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "HTTPS_PROXY=http://127.0.0.1:PROXY_PORT" || return 1
  assert_contains "$OUT" "NODE_USE_ENV_PROXY=1"
}

test_herdr_agent_is_set_inside_a_herdr_pane() {
  env_fixture
  printf 'PROFILE_HERDR_AGENT=claude\n' >"$INSTALL/profiles/stub.sh"
  run_env
  assert_eq "" "$(env_value HERDR_AGENT)" "not in a herdr pane" || return 1
  export HERDR_PANE_ID=p1
  run_env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq claude "$(env_value HERDR_AGENT)" || return 1
  assert_eq p1 "$(env_value HERDR_PANE_ID)" || return 1
  # A value the caller set wins.
  export HERDR_AGENT=other
  run_env
  assert_eq other "$(env_value HERDR_AGENT)"
}
