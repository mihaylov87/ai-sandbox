# Golden IR tests (spec §5). WP1.
#
# Each tests/unit/golden/ir-<name>/ holds:
#   case.sh       defines setup() (runs in the fixture) and may set CASE_ARGS=(...)
#   expected.ir   the exact policy.ir, with @ROOT@ for the fixture root and @UID@
#   expected.err  optional: exact stderr (default: empty)
# Fixture: see policy_fixture.sh.
# Golden files are written by hand from the spec; never regenerate them to make a test pass.

. "$(dirname "${BASH_SOURCE[0]}")/policy_fixture.sh"

run_golden_case() { # case-dir
  local dir=$1 expected_err=""
  golden_fixture
  CASE_ARGS=()
  . "$dir/case.sh"
  cd "$ROOT"
  setup # in this shell, so it can export (e.g. AIS_PLATFORM)
  build_ir ${CASE_ARGS[@]+"${CASE_ARGS[@]}"}
  assert_eq 0 "$RC" "$(basename "$dir"): exit status; stderr: $ERR" || return 1
  [ -f "$dir/expected.err" ] && expected_err=$(cat "$dir/expected.err")
  assert_eq "$expected_err" "$ERR" "$(basename "$dir"): stderr" || return 1
  assert_eq "$(cat "$dir/expected.ir")" "$OUT" "$(basename "$dir"): policy.ir"
}

test_golden_ir_cases() {
  local d n=0
  for d in "$REPO_ROOT"/tests/unit/golden/ir-*/; do
    [ -f "$d/case.sh" ] || continue
    run_golden_case "${d%/}" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || fail "no golden IR cases found"
}

