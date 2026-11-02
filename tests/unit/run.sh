#!/usr/bin/env bash
# Runs every tests/unit/test_*.sh. Each test_* function runs in its own subshell.
# Usage: tests/unit/run.sh [file-pattern] [function-pattern]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
file_pat=${1:-}
func_pat=${2:-}

AIS_TEST_CLEANUP=$(mktemp)
export AIS_TEST_CLEANUP
cleanup() {
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "$d"
  done <"$AIS_TEST_CLEANUP"
  rm -f "$AIS_TEST_CLEANUP"
}
trap cleanup EXIT

pass=0
failed=0
failures=""

for f in "$here"/test_*.sh; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in *"$file_pat"*) ;; *) continue ;; esac
  funcs=$(bash -c '. "$1"; . "$2"; declare -F | sed -n "s/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p"' _ "$here/lib.sh" "$f")
  for t in $funcs; do
    case "$t" in *"$func_pat"*) ;; *) continue ;; esac
    if (set -euo pipefail; . "$here/lib.sh"; . "$f"; "$t"); then
      pass=$((pass + 1))
    else
      failed=$((failed + 1))
      failures="$failures $(basename "$f"):$t"
      printf 'FAIL %s:%s\n' "$(basename "$f")" "$t"
    fi
  done
done

printf '%d passed, %d failed\n' "$pass" "$failed"
[ "$failed" -eq 0 ] || { printf 'failed:%s\n' "$failures"; exit 1; }
