# Self-test framework: chk, tests/matrix.sh, --check (spec §13). WP10.
# Uses the stub backend and a rows file given by _AIS_MATRIX_ROWS.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

matrix_fixture() { # rows
  launcher_fixture
  cp "$REPO_ROOT/tests/matrix.sh" "$INSTALL/tests/"
  chmod go-w "$INSTALL/tests/matrix.sh"
  printf '%s\n' "$1" >"$TMP/rows.sh"
  export _AIS_MATRIX_ROWS=$TMP/rows.sh
}

gates_file() { cat "$HOME/.local/state/ai-sandbox/gates" 2>/dev/null || true; }

test_check_runs_rows_and_reports_pass_fail_skip() {
  matrix_fixture '
row X1 both - allowed "true succeeds" -- true
row X2 both - denied "false is denied" -- false
row X3 both - skip:needs-a-thing "not run" -- false
row X4 macos - allowed "macOS only" -- false
row X5 linux - allowed "linux only" -- true'
  capture "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "PASS X1 [stub] true succeeds" || return 1
  assert_contains "$OUT" "PASS X2 [stub] false is denied" || return 1
  assert_contains "$OUT" "SKIP X3 [stub] not run (needs-a-thing)" || return 1
  assert_contains "$OUT" "SKIP X4 [stub] macOS only (macos only)" || return 1
  assert_contains "$OUT" "PASS X5 [stub] linux only" || return 1
  assert_contains "$OUT" "3 passed, 0 failed, 2 skipped"
}

test_failing_row_makes_check_exit_1() {
  matrix_fixture '
row Y1 both - allowed "should succeed" -- false
row Y2 both - denied "should fail" -- true'
  capture "$LAUNCHER" --check
  assert_eq 1 "$RC" || return 1
  assert_contains "$OUT" "FAIL Y1 [stub] should succeed (expected allowed, got denied)" || return 1
  assert_contains "$OUT" "FAIL Y2 [stub] should fail (expected denied, got allowed)"
}

test_launcher_error_is_a_failure_even_when_denied_expected() {
  matrix_fixture '
row Z1 both - denied "error is not denial" --rw /nonexistent-ais-path -- true'
  capture "$LAUNCHER" --check
  assert_eq 1 "$RC" || return 1
  assert_contains "$OUT" "FAIL Z1 [stub] error is not denial (launcher exit 125)"
}

test_command_output_is_hidden_and_shell_syntax_works() {
  matrix_fixture '
row S1 both - allowed "pipes and quotes" -- sh -c "echo noisy-output; test \"a b\" = \"a b\""'
  capture "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "PASS S1" || return 1
  assert_not_contains "$OUT" "noisy-output"
}

test_gate_results_are_recorded() {
  matrix_fixture '
row G-a both G5 allowed "gate 5 ok" -- true
row G-b both G4 allowed "gate 4 ok" -- true
row G-c both G4 allowed "gate 4 broken" -- false
row G-d both G6 skip:no-token "gate 6 untested" -- true'
  capture "$LAUNCHER" --check
  assert_eq 1 "$RC" || return 1
  assert_contains "$(gates_file)" "G5 pass" || return 1
  assert_contains "$(gates_file)" "G4 fail" || return 1
  assert_not_contains "$(gates_file)" "G6"
}

test_rows_run_once_per_installed_profile() {
  matrix_fixture '
row P1x both - allowed "per profile" -- true'
  : >"$INSTALL/profiles/other.sh"
  chmod 0644 "$INSTALL/profiles/other.sh"
  capture "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "PASS P1x [other] per profile" || return 1
  assert_contains "$OUT" "PASS P1x [stub] per profile"
}

test_n_rows_run_once_per_network_mode_with_mode_visible() {
  matrix_fixture '
row N9 both - allowed "mode check" -- sh -c "test \"\$AI_SANDBOX_NET\" = \"$CHK_NET\""'
  capture "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "PASS N9 [stub/allowlist] mode check" || return 1
  assert_contains "$OUT" "PASS N9 [stub/none] mode check" || return 1
  assert_contains "$OUT" "PASS N9 [stub/open] mode check"
}

test_check_lists_missing_policy_paths() {
  matrix_fixture '
row X1 both - allowed "ok" -- true'
  printf 'AI_SANDBOX_RO_PATHS=%s/not-there\n' "$HOME" >>"$CONF/config"
  capture "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "missing ro path skipped: $HOME/not-there"
}

test_check_does_not_need_profile_secrets() {
  matrix_fixture '
row X1 both - allowed "ok" -- true'
  printf 'PROFILE_SECRETS=(STUB_TOKEN=stub)\n' >"$INSTALL/profiles/stub.sh"
  capture "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "PASS X1 [stub] ok"
}

test_p1_over_target_warns_and_does_not_fail() {
  # Stand-in launchers: one that starts the harness after 0.3 s (over the 200 ms Linux
  # target), one that never starts it (no measurement).
  matrix_fixture '
LAUNCHER=$FAKE_SLOW; _chk_p1
CHK_PROFILE=broken; LAUNCHER=$FAKE_BROKEN; _chk_p1'
  printf '#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done; shift; sleep 0.3; exec "$@"\n' >"$TMP/slow"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/broken"
  chmod +x "$TMP/slow" "$TMP/broken"
  capture env FAKE_SLOW="$TMP/slow" FAKE_BROKEN="$TMP/broken" "$LAUNCHER" --check
  assert_eq 1 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "WARN P1 [stub] start-up to the harness exec: median 3" || return 1
  assert_contains "$OUT" "(target 200 ms; R10 is a SHOULD)" || return 1
  assert_contains "$OUT" "FAIL P1 [broken] start-up to the harness exec: median -1 ms" || return 1
  assert_contains "$OUT" "0 passed, 1 failed, 0 skipped" || return 1
  assert_contains "$OUT" "1 warning(s)"
}

test_check_rows_see_config_from_the_calling_environment() {
  # Spec §6 source 5: AI_SANDBOX_* in the environment of `--check` apply to its rows too.
  matrix_fixture '
row Z1 both - allowed "network mode from the environment" -- sh -c "[ \"\$AI_SANDBOX_NET\" = open ]"'
  capture env AI_SANDBOX_NET=open "$LAUNCHER" --check
  assert_eq 0 "$RC" "$OUT $ERR" || return 1
  assert_contains "$OUT" "PASS Z1 [stub] network mode from the environment"
}
