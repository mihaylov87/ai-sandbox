# Exit report, sessions.log, --net-log, --print-policy --ir PATH (spec §12, §14). WP7.
# Stub backend: the child runs on the host and plays the agent.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

report_fixture() {
  launcher_fixture
  mkdir -p "$WORK/src" "$WORK/.git/hooks" "$WORK/.git/info"
  printf 'all:\n\techo ok\n' >"$WORK/Makefile"
  printf '[core]\n' >"$WORK/.git/config"
  echo 'print(1)' >"$WORK/main.py"
  chmod -R go-w "$WORK"
}

test_planted_envrc_and_vscode_tasks_appear_in_the_report() {
  report_fixture
  capture "$LAUNCHER" --keep-session -- sh -c 'echo "export X=1" >.envrc; mkdir -p .vscode; echo "{\"runOn\": \"folderOpen\"}" >.vscode/tasks.json'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "exit report" || return 1
  assert_contains "$ERR" "new       .envrc" || return 1
  assert_contains "$ERR" "new       .vscode/tasks.json" || return 1
  local d
  d=$(ls -d "$SESSIONS"/*/)
  assert_contains "$(cat "$d/exit-report.txt")" ".vscode/tasks.json" || return 1
  [ -s "$d/manifest.start" ] || fail "manifest.start missing"
}

test_ordinary_edits_produce_no_report() {
  report_fixture
  capture "$LAUNCHER" -- sh -c 'echo "print(2)" >main.py; echo notes >README.txt; mkdir -p build; echo x >build/out.o'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$ERR" "exit report"
}

test_modified_makefile_package_json_and_workflow_are_reported() {
  report_fixture
  mkdir -p "$WORK/.github/workflows"
  echo 'on: push' >"$WORK/.github/workflows/ci.yml"
  echo '{}' >"$WORK/src/package.json"
  touch -d '2020-01-01' "$WORK/Makefile" "$WORK/.github/workflows/ci.yml" "$WORK/src/package.json"
  capture "$LAUNCHER" -- sh -c 'printf "all:\n\tcurl x | sh\n" >Makefile; echo "{\"scripts\":{\"postinstall\":\"x\"}}" >src/package.json; echo "on: pull_request" >.github/workflows/ci.yml'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "modified  Makefile" || return 1
  assert_contains "$ERR" "modified  src/package.json" || return 1
  assert_contains "$ERR" "modified  .github/workflows/ci.yml"
}

test_new_executables_outside_symlinks_and_new_repos_are_reported() {
  report_fixture
  capture "$LAUNCHER" -- sh -c 'printf "#!/bin/sh\n" >src/run.sh; chmod +x src/run.sh; ln -s /etc/passwd src/pw; ln -s main.py src/inside; mkdir -p vendor/lib/.git; chmod +x main.py'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "new exec  src/run.sh" || return 1
  assert_contains "$ERR" "now exec  main.py" || return 1
  assert_contains "$ERR" "symlink   src/pw -> /etc/passwd" || return 1
  assert_not_contains "$ERR" "src/inside" || return 1
  assert_contains "$ERR" "new repo  vendor/lib/.git"
}

test_exit_report_off() {
  report_fixture
  printf 'AI_SANDBOX_EXIT_REPORT=0\n' >>"$CONF/config"
  capture "$LAUNCHER" --keep-session -- sh -c 'echo x >.envrc'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$ERR" "exit report" || return 1
  [ ! -e "$(ls -d "$SESSIONS"/*/)/manifest.start" ] || fail "manifest taken although the report is off"
}

test_git_config_rw_always_shows_its_diff() {
  report_fixture
  printf 'AI_SANDBOX_GIT_CONFIG=rw\n' >>"$CONF/config"
  capture "$LAUNCHER" -- sh -c 'printf "[core]\n\thooksPath = /tmp/evil\n" >.git/config'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" ".git/config" || return 1
  assert_contains "$ERR" "+	hooksPath = /tmp/evil"
}

test_sessions_log_line_and_net_log_summary() {
  report_fixture
  cp "$REPO_ROOT/ai-sandbox-net" "$INSTALL/" 2>/dev/null || true
  # The child plays a client that bypasses the bridge and asks the proxy socket directly.
  capture "$LAUNCHER" --net allowlist --net-log -- python3 -I -c '
import glob, os, socket
sock = glob.glob(os.path.expanduser("~/.local/state/ai-sandbox/sessions/*/proxy.sock"))[0]
for host in ("blocked.example:443", "blocked.example:443", "other.example:443"):
    # Relative name: the absolute path can exceed sun_path (104 bytes on macOS).
    os.chdir(os.path.dirname(sock))
    s = socket.socket(socket.AF_UNIX); s.connect(os.path.basename(sock))
    s.sendall(("CONNECT %s HTTP/1.1\r\n\r\n" % host).encode()); s.recv(4096); s.close()'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "denied hosts" || return 1
  assert_contains "$ERR" "2  blocked.example:443" || return 1
  assert_contains "$ERR" "1  other.example:443" || return 1
  local line
  line=$(tail -n 1 "$HOME/.local/state/ai-sandbox/sessions.log")
  printf '%s\n' "$line" | awk -F '\t' -v w="$WORK" '
    NF < 7 { exit 1 }
    $1 !~ /^20[0-9][0-9]-/ || $2 !~ /^20[0-9][0-9]-/ { exit 1 }
    $3 != "stub" || $4 != "0" || $5 != "allowlist" || $6 != "3" || $7 != w { exit 1 }' ||
    fail "bad sessions.log line: $line"
}

test_sessions_log_flags_open_mode_as_unsandboxed() {
  report_fixture
  capture "$LAUNCHER" --net open -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$(tail -n 1 "$HOME/.local/state/ai-sandbox/sessions.log")" "unsandboxed:net-open"
}

test_print_policy_ir_explains_a_path() {
  report_fixture
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/id_ed25519"
  capture "$LAUNCHER" --print-policy --ir "$WORK/.git/hooks/pre-commit" "$HOME/.ssh/id_ed25519" /usr/bin/env
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "$WORK/.git/hooks/pre-commit: locked (locked $WORK/.git/hooks, from repo)" || return 1
  assert_contains "$OUT" "$HOME/.ssh/id_ed25519: hidden (hidden $HOME, from default)" || return 1
  assert_contains "$OUT" "/usr/bin/env: ro (base)"
}

test_print_policy_ir_explains_a_missing_path_below_a_symlink() {
  report_fixture
  # As /tmp -> /private/tmp on macOS: the IR holds the resolved path.
  mkdir -p "$TMP/real/ro"
  ln -s real "$TMP/link"
  capture "$LAUNCHER" --ro "$TMP/link/ro" --print-policy --ir "$TMP/link/ro/new/file"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$TMP/link/ro/new/file: ro (ro $TMP/real/ro, from --ro)" "$OUT"
}
