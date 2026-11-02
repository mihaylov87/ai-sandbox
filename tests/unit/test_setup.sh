# setup.sh (spec §13 setup steps, §16 migration). WP8.
# _AIS_SETUP_CHECK replaces the final `ai-sandbox --check` (the matrix has its own tests).

setup_fixture() {
  mk_tmp
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  INST=$TMP/install
  mkdir -p "$INST/tests"
  cp -R "$REPO_ROOT/ai-sandbox" "$REPO_ROOT/ai-sandbox-init" "$REPO_ROOT/ai-sandbox-net" "$REPO_ROOT/setup.sh" \
    "$REPO_ROOT/config.example" "$REPO_ROOT/lib" "$REPO_ROOT/profiles" "$REPO_ROOT/seeds" "$REPO_ROOT/apparmor" "$INST/"
  cp "$REPO_ROOT/tests/matrix.sh" "$INST/tests/"
  chmod -R g+w "$INST" # as a fresh checkout under umask 002 would be
  CONF=$HOME/.config/ai-sandbox
  export _AIS_SETUP_CHECK="echo matrix-ran"
  local v
  for v in $(compgen -v AI_SANDBOX_); do unset "$v"; done
}

run_setup() { # [stdin text]
  capture bash -c 'printf "%s" "$2" | "$1/setup.sh"' _ "$INST" "${1-}"
}

perm_is() { [ -n "$(find "$1" -prune -perm "$2")" ]; }

test_first_run_creates_config_from_example_and_stops() {
  setup_fixture
  run_setup
  assert_eq 1 "$RC" "$OUT $ERR" || return 1
  assert_eq "$(cat "$REPO_ROOT/config.example")" "$(cat "$CONF/config")" || return 1
  perm_is "$CONF/config" 600 || fail "config not 0600" || return 1
  perm_is "$CONF" 700 || fail "config dir not 0700" || return 1
  assert_contains "$OUT$ERR" "edit" || return 1
  assert_not_contains "$OUT" "matrix-ran"
}

test_v1_env_is_offered_and_copied() {
  setup_fixture
  printf 'AI_SANDBOX_WORK_DIR=~/proj\nAI_SANDBOX_EXTRA_RW=/opt/x\nAI_SANDBOX_OLDTHING=1\n' >"$INST/.env"
  run_setup y
  assert_eq 1 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "v1" || return 1
  local c
  c=$(cat "$CONF/config")
  assert_contains "$c" "AI_SANDBOX_WORK_DIR=$HOME/proj" || return 1
  assert_contains "$c" "AI_SANDBOX_EXTRA_RW=/opt/x" || return 1
  assert_contains "$c" "# AI_SANDBOX_OLDTHING=1" "unknown v1 names are kept commented out"
}

test_v1_env_declined_uses_example() {
  setup_fixture
  printf 'AI_SANDBOX_WORK_DIR=~/proj\n' >"$INST/.env"
  run_setup n
  assert_eq 1 "$RC" || return 1
  assert_eq "$(cat "$REPO_ROOT/config.example")" "$(cat "$CONF/config")"
}

configured_fixture() {
  setup_fixture
  mkdir -p -m 0700 "$CONF"
  mkdir -p "$HOME/src/app"
  printf 'AI_SANDBOX_WORK_DIR=%s\n' "$HOME/src/app" >"$CONF/config"
  chmod 0600 "$CONF/config"
}

test_second_run_installs_and_runs_the_matrix() {
  configured_fixture
  run_setup
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "matrix-ran" || return 1
  assert_contains "$OUT" "All checks passed" || return 1
  [ "$(readlink "$HOME/.local/bin/ai-sandbox")" = "$INST/ai-sandbox" ] || fail "launcher not linked" || return 1
  [ -z "$(find "$INST" ! -type l \( -perm -020 -o -perm -002 \) -print -quit)" ] || fail "install still writable" || return 1
  perm_is "$INST" 755 || fail "install dir not 0755" || return 1
  [ -x "$INST/ai-sandbox" ] && [ -x "$INST/ai-sandbox-net" ] && [ -x "$INST/ai-sandbox-init" ] || fail "not executable" || return 1
  [ -d "$CONF/projects" ] || fail "projects dir missing" || return 1
  perm_is "$CONF/secrets" 700 || fail "secrets dir not 0700" || return 1
  [ -f "$CONF/seed/claude/settings.json" ] && [ -f "$CONF/seed/copilot/settings.json" ] || fail "seeds not copied" || return 1
  assert_contains "$OUT" "COPILOT_GITHUB_TOKEN" || return 1
  assert_contains "$OUT" "CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY"
}

test_setup_is_idempotent_and_keeps_user_seeds() {
  configured_fixture
  run_setup
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  echo '{"mine": true}' >"$CONF/seed/claude/settings.json"
  run_setup
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_eq '{"mine": true}' "$(cat "$CONF/seed/claude/settings.json")" || return 1
  [ "$(readlink "$HOME/.local/bin/ai-sandbox")" = "$INST/ai-sandbox" ] || fail "link changed"
}

test_resolved_secret_is_not_reported_as_missing() {
  configured_fixture
  printf 'AI_SANDBOX_SECRET_CMD_COPILOT_GITHUB_TOKEN="echo t"\n' >>"$CONF/config"
  mkdir -p -m 0700 "$CONF/secrets"
  printf 'tok\n' >"$CONF/secrets/claude"
  chmod 0600 "$CONF/secrets/claude"
  run_setup
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_not_contains "$OUT" "needs COPILOT_GITHUB_TOKEN" || return 1
  assert_not_contains "$OUT" "CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY"
}

test_copilot_guardrails_are_copied_into_the_seed_on_first_setup() {
  configured_fixture
  mkdir -p "$HOME/.copilot/hooks"
  echo '{"user": 1}' >"$HOME/.copilot/settings.json"
  echo 'hook' >"$HOME/.copilot/hooks/h.sh"
  echo 'session' >"$HOME/.copilot/history"
  run_setup
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_eq '{"user": 1}' "$(cat "$CONF/seed/copilot/settings.json")" || return 1
  [ -f "$CONF/seed/copilot/hooks/h.sh" ] || fail "hooks not copied" || return 1
  [ ! -e "$CONF/seed/copilot/history" ] || fail "non-guardrail state copied" || return 1
  assert_contains "$OUT" "review"
}

test_failing_matrix_reports_and_exits_1() {
  configured_fixture
  export _AIS_SETUP_CHECK=false
  run_setup
  assert_eq 1 "$RC" || return 1
  assert_contains "$OUT$ERR" "Some checks failed"
}

test_existing_foreign_launcher_file_is_not_clobbered() {
  configured_fixture
  mkdir -p "$HOME/.local/bin"
  echo 'v1 script' >"$HOME/.local/bin/ai-sandbox"
  run_setup
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_eq 'v1 script' "$(cat "$HOME/.local/bin/ai-sandbox")" || return 1
  assert_contains "$OUT$ERR" "$HOME/.local/bin/ai-sandbox"
}
