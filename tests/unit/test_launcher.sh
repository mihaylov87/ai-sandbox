# Launcher core: run sequence, supervision, exit codes, session dir (spec §4). WP9.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

test_child_exit_code_is_returned() {
  launcher_fixture
  capture "$LAUNCHER" -- sh -c 'exit 7'
  assert_eq 7 "$RC" "$ERR"
}

test_child_killed_by_signal_gives_128_plus_n() {
  launcher_fixture
  capture "$LAUNCHER" -- sh -c 'kill -TERM $$'
  assert_eq 143 "$RC" "$ERR"
}

test_command_not_found_exits_127() {
  launcher_fixture
  capture "$LAUNCHER" -- no-such-command-xyz
  assert_eq 127 "$RC" || return 1
  assert_contains "$ERR" "no-such-command-xyz"
}

test_stdin_and_stdout_pass_through() {
  launcher_fixture
  OUT=$(printf 'hello\n' | "$LAUNCHER" -- cat)
  assert_eq hello "$OUT"
}

test_sigterm_to_launcher_is_forwarded_to_child() {
  launcher_fixture
  local pid rc
  "$LAUNCHER" -- sh -c 'trap "exit 42" TERM; : >"$1"; while :; do sleep 0.05; done' _ "$TMP/started" &
  pid=$!
  # Signal only once the child runs (and so the launcher's trap is set); a fixed delay
  # raced the launcher's start-up on a loaded machine.
  local i=0
  while [ ! -e "$TMP/started" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  kill -TERM "$pid"
  set +e
  wait "$pid"
  rc=$?
  set -e
  assert_eq 42 "$rc"
}

test_sighup_to_launcher_is_forwarded_to_child() {
  launcher_fixture
  local pid rc
  "$LAUNCHER" -- sh -c 'trap "exit 43" HUP; : >"$1"; while :; do sleep 0.05; done' _ "$TMP/started" &
  pid=$!
  local i=0
  while [ ! -e "$TMP/started" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  kill -HUP "$pid"
  set +e
  wait "$pid"
  rc=$?
  set -e
  assert_eq 43 "$rc"
}

test_ctrl_c_reaches_child_and_launcher_cleans_up() {
  launcher_fixture
  # SIGINT to the whole process group, as the terminal sends it.
  # A new session (setsid -w, portable to macOS), so the group holds only this test.
  capture python3 -I -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash -c 'trap : INT; "$1" -- sleep 5 & p=$!; sleep 0.5; kill -INT -$$; wait $p' _ "$LAUNCHER"
  assert_eq 130 "$RC" "$ERR" || return 1
  # Non-zero child exit keeps the session dir (spec §14).
  assert_eq 1 "$(session_dirs | wc -l | tr -d ' ')"
}

test_session_dir_removed_after_clean_run() {
  launcher_fixture
  capture "$LAUNCHER" -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "" "$(session_dirs)"
}

test_session_dir_kept_with_keep_session_and_mode_0700() {
  launcher_fixture
  capture "$LAUNCHER" --keep-session -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  local d
  d=$(session_dirs)
  [ -n "$d" ] || fail "no session dir kept" || return 1
  [ -n "$(find "$d" -prune -perm 700)" ] || fail "session dir not 0700" || return 1
  [ -f "$d/policy.ir" ] || fail "policy.ir missing" || return 1
  [ -f "$d/stub.policy" ] || fail "backend output missing"
}

test_session_dir_kept_when_child_fails() {
  launcher_fixture
  capture "$LAUNCHER" -- false
  assert_eq 1 "$RC" || return 1
  assert_eq 1 "$(session_dirs | wc -l | tr -d ' ')"
}

test_session_dir_removed_after_launcher_error() {
  launcher_fixture
  printf 'AI_SANDBOX_RW_PATHS=%s/missing\n' "$HOME" >>"$CONF/config"
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_eq "" "$(session_dirs)"
}

test_group_writable_install_dir_is_refused() {
  launcher_fixture
  chmod g+w "$INSTALL/lib"
  capture "$LAUNCHER" -- true
  assert_eq 126 "$RC" || return 1
  assert_contains "$ERR" "$INSTALL/lib"
}

test_symlinked_launcher_resolves_install_dir() {
  launcher_fixture
  mkdir -p "$HOME/bin"
  ln -s "$LAUNCHER" "$HOME/bin/ai-sandbox"
  capture "$HOME/bin/ai-sandbox" -- true
  assert_eq 0 "$RC" "$ERR"
}

test_config_error_exits_125() {
  launcher_fixture
  capture "$LAUNCHER" --bogus
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "--bogus"
}

test_refuses_to_run_inside_a_sandbox() {
  launcher_fixture
  AI_SANDBOX=1 capture "$LAUNCHER" -- true
  assert_eq 126 "$RC" || return 1
  assert_contains "$ERR" "inside"
}

test_print_policy_ir_prints_ir_and_runs_nothing() {
  launcher_fixture
  capture "$LAUNCHER" --print-policy --ir -- sh -c 'echo SHOULD-NOT-RUN'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "# ai-sandbox-ir 1" || return 1
  assert_contains "$OUT" "rw	dir	$WORK" || return 1
  assert_not_contains "$OUT" "SHOULD-NOT-RUN" || return 1
  assert_eq "" "$(session_dirs)"
}

test_print_policy_prints_backend_output() {
  launcher_fixture
  capture "$LAUNCHER" --print-policy
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "stub-policy"
}

test_dry_run_prints_policy_and_command() {
  launcher_fixture
  capture "$LAUNCHER" --dry-run -- echo 'a b'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "stub-policy" || return 1
  assert_contains "$OUT" "command: echo 'a b'" || return 1
  assert_not_contains "$OUT" "
a b"
}

test_cwd_inside_rw_path_is_kept() {
  launcher_fixture
  mkdir -p "$WORK/sub"
  OUT=$(cd "$WORK/sub" && "$LAUNCHER" -- pwd)
  assert_eq "$WORK/sub" "$OUT"
}

test_cwd_in_hidden_path_falls_back_to_work_dir() {
  launcher_fixture
  mkdir -p "$HOME/elsewhere"
  OUT=$(cd "$HOME/elsewhere" && "$LAUNCHER" -- pwd)
  assert_eq "$WORK" "$OUT"
}

test_cwd_in_base_ro_path_is_kept() {
  launcher_fixture
  OUT=$(cd /usr && "$LAUNCHER" -- pwd)
  assert_eq /usr "$OUT"
}

test_ai_sandbox_command_is_parsed_with_bash_word_rules() {
  launcher_fixture
  printf "AI_SANDBOX_COMMAND=\"printf '<%%s>' 'x y' z\"\n" >>"$CONF/config"
  capture "$LAUNCHER"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "<x y><z>" "$OUT"
}

test_profile_command_used_when_no_other_command() {
  launcher_fixture
  printf 'PROFILE_COMMAND=(echo from-profile)\n' >"$INSTALL/profiles/stub.sh"
  capture "$LAUNCHER"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq from-profile "$OUT"
}

test_cli_command_replaces_ai_sandbox_command() {
  launcher_fixture
  printf 'AI_SANDBOX_COMMAND="echo from-config"\n' >>"$CONF/config"
  capture "$LAUNCHER" -- echo from-cli
  assert_eq from-cli "$OUT"
}

test_no_command_anywhere_exits_125() {
  launcher_fixture
  capture "$LAUNCHER"
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_COMMAND"
}

test_shell_mode_runs_bash_with_args() {
  launcher_fixture
  capture "$LAUNCHER" --shell -c 'echo "in $0"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "in bash" "$OUT"
}

test_own_process_group_child_is_supervised_and_forwarded() {
  launcher_fixture
  # AIS_RUN_PGRP=1 (macOS): the child leads its own group; exit codes and SIGTERM still work.
  capture env _AIS_STUB_PGRP=1 "$LAUNCHER" -- python3 -I -c 'import os; print(os.getpgrp() == os.getpid())'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq True "$OUT" || return 1
  capture env _AIS_STUB_PGRP=1 "$LAUNCHER" -- sh -c 'exit 7'
  assert_eq 7 "$RC" "$ERR" || return 1
  capture bash -c '_AIS_STUB_PGRP=1 "$1" -- sh -c ": >\"\$1\"; exec sleep 5" _ "$2" & p=$!
    i=0; while [ ! -e "$2" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    kill -TERM $p; wait $p' _ "$LAUNCHER" "$TMP/started"
  assert_eq 143 "$RC" "$ERR" || return 1
  assert_not_contains "$ERR" "Terminated" "no job notice"
}

test_check_runs_do_not_keep_failed_sessions() {
  launcher_fixture
  capture env _AIS_CHECK_NO_KEEP=1 "$LAUNCHER" -- false
  assert_eq 1 "$RC" "$ERR" || return 1
  assert_eq "" "$(session_dirs)" || return 1
  capture env _AIS_CHECK_NO_KEEP=1 "$LAUNCHER" --keep-session -- false
  assert_eq 1 "$(session_dirs | wc -l | tr -d ' ')"
}
