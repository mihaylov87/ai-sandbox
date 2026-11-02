# Gates file and start-up gate check (spec §4 step 5, §15). WP10.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

GATES_REL=.local/state/ai-sandbox/gates

# Run gates functions in a fresh bash with config loaded; extra code in $1.
run_gates() { # code [cli args...]
  local code=$1
  shift
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/gates.sh"
    AIS_PLATFORM=linux
    code=$2; shift 2
    cfg_load "$@"
    eval "$code"
  ' _ "$REPO_ROOT" "$code" "$@"
}

test_record_writes_gate_status_date_and_os_version() {
  launcher_fixture
  run_gates 'gates_record G2 fail; gates_record G5 pass; cat "$HOME/'"$GATES_REL"'"'
  assert_eq 0 "$RC" "$ERR" || return 1
  local os
  os=$(uname -s)-$(uname -r)
  printf '%s\n' "$OUT" | grep -qE "^G2 fail [0-9]{4}-[0-9]{2}-[0-9]{2} $os\$" || fail "bad G2 line: $OUT" || return 1
  printf '%s\n' "$OUT" | grep -qE "^G5 pass [0-9]{4}-[0-9]{2}-[0-9]{2} $os\$" || fail "bad G5 line: $OUT"
}

test_record_replaces_previous_result_for_same_gate() {
  launcher_fixture
  run_gates 'gates_record G2 fail; gates_record G3 pass; gates_record G2 pass; cut -d" " -f1,2 "$HOME/'"$GATES_REL"'"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "G2 pass
G3 pass" "$(printf '%s\n' "$OUT" | sort)"
}

test_status_of_unrecorded_gate_is_unchecked() {
  launcher_fixture
  run_gates 'gates_read; gates_status G7'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq unchecked "$OUT"
}

test_result_from_another_os_version_counts_as_unchecked() {
  launcher_fixture
  mkdir -p "$HOME/.local/state/ai-sandbox"
  printf 'G7 fail 2026-01-01 Linux-0.0.1\n' >"$HOME/$GATES_REL"
  run_gates 'gates_read; gates_status G7'
  assert_eq unchecked "$OUT"
}

test_missing_gates_file_prints_hint_and_applies_defaults() {
  launcher_fixture
  run_gates 'gates_check; echo "dns=$AI_SANDBOX_DNS"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "--check" || return 1
  assert_eq dns=deny "$OUT"
}

test_failed_g3_makes_dns_default_allow_but_explicit_value_wins() {
  launcher_fixture
  run_gates 'gates_record G3 fail; gates_check; echo "dns=$AI_SANDBOX_DNS"'
  assert_eq dns=allow "$OUT" "$ERR" || return 1
  printf 'AI_SANDBOX_DNS=deny\n' >>"$CONF/config"
  run_gates 'gates_record G3 fail; gates_check; echo "dns=$AI_SANDBOX_DNS"'
  assert_eq dns=deny "$OUT"
}

test_failed_gate_runs_its_fallback_hook() {
  launcher_fixture
  run_gates 'gate_fallback_G5() { echo "fallback G5"; }; gates_record G5 fail; gates_record G4 pass
             gate_fallback_G4() { echo "fallback G4"; }; gates_check'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "fallback G5" "$OUT"
}

test_gate_fallback_that_cannot_mitigate_refuses_with_123() {
  launcher_fixture
  run_gates 'gate_fallback_G1() { return 1; }; gates_record G1 fail; gates_check; echo started'
  assert_eq 123 "$RC" || return 1
  assert_contains "$ERR" "G1" || return 1
  assert_contains "$ERR" "AI_SANDBOX_ACCEPT" || return 1
  assert_not_contains "$OUT" started
}

test_accepted_gate_starts_with_warning() {
  launcher_fixture
  export AI_SANDBOX_ACCEPT=G1
  run_gates 'gate_fallback_G1() { return 1; }; gates_record G1 fail; gates_check; echo started'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq started "$OUT" || return 1
  assert_contains "$ERR" "G1"
}

test_launcher_refuses_with_123_on_unmitigated_gate() {
  launcher_fixture
  printf 'gate_fallback_G1() { return 1; }\n' >>"$INSTALL/tests/unit/backend-stub.sh"
  mkdir -p "$HOME/.local/state/ai-sandbox"
  printf 'G1 fail 2026-11-02 %s-%s\n' "$(uname -s)" "$(uname -r)" >"$HOME/$GATES_REL"
  capture "$LAUNCHER" -- echo started
  assert_eq 123 "$RC" || return 1
  assert_not_contains "$OUT" started
}
