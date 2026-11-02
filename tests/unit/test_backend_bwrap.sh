# Linux backend: IR -> bwrap argv (spec §7). WP2. Golden files in golden/bwrap/.
# Host-dependent inputs come from test seams: _AIS_TIOCSTI_FILE, _AIS_DOCKER_SOCKETS.

GOLDEN_BW="$REPO_ROOT/tests/unit/golden/bwrap"

# Compile golden/bwrap/input.ir with the given shell setup; OUT = bwrap.argv.
bw_compile() { # setup-code [code-after-compile]
  mk_tmp
  mkdir -p "$TMP/session"
  touch "$TMP/docker.sock"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMP/agent.sock"
  printf '0\n' >"$TMP/tiocsti"
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/backend-bwrap.sh"
    TMP=$2 SESSION=$2/session
    AIS_INSTALL_DIR=/inst AIS_PLATFORM=linux AI_SANDBOX_NET=allowlist AI_SANDBOX_SSH_AGENT=0
    AI_SANDBOX_DOCKER=0 AI_SANDBOX_HOST_PORTS= PROFILE_ALLOW_USERNS=0 AI_SANDBOX_LIMITS= AI_SANDBOX_HARNESS=claude
    AIS_PROXY_SOCK=$SESSION/proxy.sock
    _AIS_TIOCSTI_FILE=$TMP/tiocsti _AIS_DOCKER_SOCKETS=$TMP/docker.sock
    eval "$3"
    backend_compile "$1/tests/unit/golden/bwrap/input.ir" "$SESSION"
    eval "$4"
    cat "$SESSION/bwrap.argv"
  ' _ "$REPO_ROOT" "$TMP" "$1" "${2-}"
}

bw_expected() { # golden-file
  sed -e "s|@SESSION@|$TMP/session|g" -e "s|@SOCK@|$TMP/docker.sock|g" -e "s|@AGENT@|$TMP/agent.sock|g" \
    "$GOLDEN_BW/$1"
}

test_allowlist_argv_matches_golden() {
  bw_compile ''
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$(bw_expected allowlist.argv)" "$OUT"
}

test_open_mode_ssh_agent_new_session_and_userns_allowed() {
  bw_compile 'AI_SANDBOX_NET=open AIS_PROXY_SOCK= AI_SANDBOX_SSH_AGENT=1 SSH_AUTH_SOCK=$TMP/agent.sock
              PROFILE_ALLOW_USERNS=1 _AIS_DOCKER_SOCKETS=; printf "1\n" >"$TMP/tiocsti"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$(bw_expected open-ssh-newsession.argv)" "$OUT" || return 1
  assert_contains "$ERR" "PROFILE_ALLOW_USERNS"
}

test_missing_legacy_tiocsti_file_means_new_session() {
  bw_compile '_AIS_TIOCSTI_FILE=$TMP/does-not-exist'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "--new-session"
}

test_none_mode_unshares_net() {
  bw_compile 'AI_SANDBOX_NET=none AIS_PROXY_SOCK='
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "--unshare-net" || return 1
  assert_not_contains "$OUT" "proxy.sock"
}

test_docker_exposed_skips_socket_masks() {
  bw_compile 'AI_SANDBOX_DOCKER=1'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$OUT" "$TMP/docker.sock"
}

test_missing_docker_sockets_are_not_masked() {
  bw_compile '_AIS_DOCKER_SOCKETS="$TMP/nope.sock $TMP/docker.sock"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$OUT" "nope.sock" || return 1
  assert_contains "$OUT" "$TMP/docker.sock"
}

test_command_argv_has_env_chdir_init_and_redacted_secrets() {
  bw_compile '' '
    AIS_ENV_K=(HOME TOKEN) AIS_ENV_V=(/home/u sekrit-VALUE) AIS_ENV_SECRET=(0 1)
    backend_command "$SESSION" /w/app -- claude --flag "a b"
    printf "run=%s\n" "${AIS_RUN_ARGV[@]}" >"$TMP/run"
    printf "%s\0" "${AIS_BW_FULL[@]}" | tr "\0" "\n" >"$TMP/full"'
  assert_eq 0 "$RC" "$ERR" || return 1
  local tail
  tail=$(printf '%s\n' "$OUT" | sed -n '/^--clearenv$/,$p')
  assert_eq "--clearenv
--setenv
HOME
/home/u
--setenv
TOKEN
'<redacted>'
--chdir
/w/app
/inst/ai-sandbox-init
allowlist
''
--
claude
--flag
'a b'" "$tail" || return 1
  assert_not_contains "$OUT" "sekrit-VALUE" "secret in bwrap.argv" || return 1
  # bwrap reads options from fd 3; the command itself stays on argv (no secrets in it).
  assert_eq "run=$(command -v bwrap)
run=--args
run=3
run=--
run=/inst/ai-sandbox-init
run=allowlist
run=
run=--
run=claude
run=--flag
run=a b" "$(cat "$TMP/run")" || return 1
  assert_not_contains "$(cat "$TMP/full")" "ai-sandbox-init" "fd-3 args hold options only" || return 1
  assert_contains "$(cat "$TMP/full")" "sekrit-VALUE" "the fd-3 argv carries the real value" || return 1
  assert_eq --unshare-user "$(head -n 1 "$TMP/full")" "fd-3 args start after the program name"
}

test_socket_masks_use_the_resolved_path() {
  bw_compile 'mkdir -p "$TMP/run"; touch "$TMP/run/d.sock"; ln -s run "$TMP/varrun"
              _AIS_DOCKER_SOCKETS="$TMP/varrun/d.sock $TMP/run/d.sock"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$OUT" "$TMP/varrun" || return 1
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c "^$TMP/run/d.sock\$")"
}
