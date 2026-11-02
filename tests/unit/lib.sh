# Test helpers for tests/unit. Sourced by run.sh; Bash 3.2 compatible.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

fail() {
  printf '    %s\n' "$@" >&2
  return 1
}

assert_eq() { # expected actual [message]
  if [ "$1" != "$2" ]; then
    fail "${3:-values differ}" "expected: $1" "actual:   $2"
  fi
}

assert_contains() { # haystack needle [message]
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  fail "${3:-missing substring}" "needle:   $2" "haystack: $1"
}

assert_not_contains() { # haystack needle [message]
  case "$1" in
    *"$2"*) fail "${3:-unexpected substring}" "needle:   $2" "haystack: $1" ;;
  esac
  return 0
}

# Run a command, capture stdout, stderr and status into OUT, ERR, RC.
capture() {
  local _o _e
  _o=$(mktemp) _e=$(mktemp)
  set +e
  "$@" >"$_o" 2>"$_e"
  RC=$?
  set -e
  OUT=$(cat "$_o")
  ERR=$(cat "$_e")
  rm -f "$_o" "$_e"
}

# Fresh temp dir per test, removed by run.sh.
mk_tmp() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/ais-test.XXXXXX")
  TMP=$(cd "$TMP" && pwd -P)
  printf '%s\n' "$TMP" >>"$AIS_TEST_CLEANUP"
}
