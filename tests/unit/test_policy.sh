# IR algorithm error exits and side outputs (spec §5 steps 2, 3, 5). WP1.

. "$(dirname "${BASH_SOURCE[0]}")/policy_fixture.sh"

# Append config lines, build, expect exit 125 with a message containing $2.
expect_policy_error() { # config-lines needle [cli args...]
  local lines=$1 needle=$2
  shift 2
  golden_fixture
  printf '%s\n' "$lines" >>"$CONF/config"
  build_ir "$@"
  assert_eq 125 "$RC" "config: $lines; out: $OUT; err: $ERR" || return 1
  assert_contains "$ERR" "$needle"
}

test_empty_path_in_list_exits_125() {
  expect_policy_error 'AI_SANDBOX_RO_PATHS=/usr::/opt' "empty path in AI_SANDBOX_RO_PATHS"
}

test_relative_path_exits_125() {
  expect_policy_error 'AI_SANDBOX_RW_PATHS=src/x' "src/x" || return 1
  assert_contains "$ERR" "not absolute"
}

test_relative_cli_path_exits_125() {
  expect_policy_error '' "./x" --ro ./x
}

test_tilde_user_form_is_rejected_as_relative() {
  expect_policy_error "AI_SANDBOX_RO_PATHS='~root/x'" "~root/x"
}

test_tab_newline_and_quote_in_path_exit_125() {
  expect_policy_error "AI_SANDBOX_HIDE_PATHS=\$'/tmp/a\\tb'" "tab, newline or" || return 1
  expect_policy_error "AI_SANDBOX_HIDE_PATHS=\$'/tmp/a\\nb'" "tab, newline or" || return 1
  expect_policy_error "AI_SANDBOX_HIDE_PATHS='/tmp/a\"b'" "tab, newline or"
}

test_symlink_resolving_to_forbidden_character_exits_125() {
  golden_fixture
  mkdir -p "$HOME/we\"ird"
  ln -s "we\"ird" "$HOME/link"
  printf 'AI_SANDBOX_RO_PATHS=~/link\n' >>"$CONF/config"
  build_ir
  assert_eq 125 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "tab, newline or"
}

test_missing_rw_path_exits_125_and_suggests_optional() {
  expect_policy_error 'AI_SANDBOX_RW_PATHS=~/nope' "/sys/home/jordan/nope" || return 1
  assert_contains "$ERR" "?"
}

test_missing_work_dir_path_exits_125() {
  golden_fixture
  rm -rf "$WORK"
  build_ir
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "@ROOT@/sys/home/jordan/src/app"
}

test_rw_under_locked_exits_125() {
  expect_policy_error 'AI_SANDBOX_LOCKED_PATHS=~/src' "@ROOT@/sys/home/jordan/src/app" || return 1
  assert_contains "$ERR" "under locked"
}

test_rw_under_repo_locked_dir_exits_125() {
  golden_fixture
  mkdir -p "$WORK/.git/hooks/sub"
  build_ir --rw "$WORK/.git/hooks/sub"
  assert_eq 125 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "under locked"
}

test_missing_non_rw_paths_are_recorded_for_check() {
  golden_fixture
  printf 'AI_SANDBOX_RO_PATHS=~/gone-ro\nAI_SANDBOX_HIDE_PATHS=~/gone-hidden\nAI_SANDBOX_RW_PATHS=~/gone-rw?\n' >>"$CONF/config"
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/policy.sh"
    cfg_load; cfg_load_profile; policy_build /dev/null
    printf "%s\n" "${POLICY_MISSING[@]}"
  ' _ "$REPO_ROOT"
  assert_eq 0 "$RC" "$ERR" || return 1
  OUT=$(printf '%s' "$OUT" | sed "s|$ROOT|@ROOT@|g")
  assert_eq "rw @ROOT@/sys/home/jordan/gone-rw
ro @ROOT@/sys/home/jordan/gone-ro
hidden @ROOT@/sys/home/jordan/gone-hidden" "$OUT"
}

test_missing_profile_exits_125() {
  golden_fixture
  build_ir -H nosuch
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "nosuch"
}

test_cache_and_isolated_state_dirs_are_created_0700() {
  golden_fixture
  printf 'PROFILE_RW=(".")\n' >"$INSTALL/profiles/copilot.sh"
  build_ir
  assert_eq 0 "$RC" "$ERR" || return 1
  local d
  for d in "$HOME/.cache/ai-sandbox" "$HOME/.local/state/ai-sandbox/copilot"; do
    [ -n "$(find "$d" -prune -perm 700)" ] || fail "$d is not mode 0700" || return 1
  done
}
