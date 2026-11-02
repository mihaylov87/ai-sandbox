#!/usr/bin/env bash
# Self-test matrix (spec §13). Run by `ai-sandbox --check`, which sets AIS_INSTALL_DIR,
# AIS_PLATFORM, CHK_WORK_DIR and CHK_PROJECT. Bash 3.2 compatible.
#
# Each check is a `row` call:
#   row <id> <linux|macos|both> <gate|-> <allowed|denied|skip:reason> <description> \
#       [launcher options...] -- <command> [args...]
# The command runs in a sandbox built from the active config (launcher -H <profile>
# -- command), once per installed profile with the stub command in place of the harness;
# rows whose id starts with N run once per network mode instead, with CHK_NET set.
# Exit 0 inside = allowed, exit non-zero = denied; a launcher exit code (123-127) or a
# signal is a FAIL whatever was expected. Rows are evaluated per run, so they can use
# CHK_PROFILE, CHK_NET, CHK_WORK_DIR.
set -uo pipefail

. "$AIS_INSTALL_DIR/lib/config.sh"
. "$AIS_INSTALL_DIR/lib/gates.sh"

LAUNCHER="$AIS_INSTALL_DIR/ai-sandbox"
CHK_PASS=0 CHK_FAIL=0 CHK_SKIP=0
CHK_PROFILE= CHK_NET=
CHK_ERRF=$(mktemp)
trap 'rm -f "$CHK_ERRF"' EXIT

# Children: no secrets needed (stub command), and gates are measured, not applied.
export _AIS_NO_SECRETS=1 _AIS_CHECK_NO_GATES=1

_chk_gate() { # gate pass|fail
  local cur
  [ "$1" = - ] && return 0
  eval "cur=\${_CHK_GATE_$1-}"
  if [ "$2" = fail ] || [ -z "$cur" ]; then eval "_CHK_GATE_$1=\$2"; fi
}

row() {
  local id=$1 plat=$2 gate=$3 expect=$4 desc=$5 label rc got
  shift 5
  local largs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do largs[${#largs[@]}]=$1; shift; done
  [ "$#" -gt 0 ] && shift

  case "$id" in
    N*) [ -n "$CHK_NET" ] || return 0 ;;
    *) [ -z "$CHK_NET" ] || return 0 ;;
  esac
  label="[$CHK_PROFILE${CHK_NET:+/$CHK_NET}]"

  if [ "$plat" != both ] && [ "$plat" != "$AIS_PLATFORM" ]; then
    printf 'SKIP %s %s %s (%s only)\n' "$id" "$label" "$desc" "$plat"
    CHK_SKIP=$((CHK_SKIP + 1))
    return 0
  fi
  case "$expect" in
    skip:*)
      printf 'SKIP %s %s %s (%s)\n' "$id" "$label" "$desc" "${expect#skip:}"
      CHK_SKIP=$((CHK_SKIP + 1))
      return 0
      ;;
  esac

  "$LAUNCHER" -H "$CHK_PROFILE" -w "$CHK_WORK_DIR" ${CHK_PROJECT:+-p "$CHK_PROJECT"} \
    ${CHK_NET:+--net "$CHK_NET"} ${largs[@]+"${largs[@]}"} \
    -- sh -c '"$@" >/dev/null 2>&1 && exit 0; exit 1' chk "$@" </dev/null >/dev/null 2>"$CHK_ERRF"
  rc=$?
  case "$rc" in
    0) got=allowed ;;
    1) got=denied ;;
    *) got="launcher exit $rc" ;;
  esac
  if [ "$got" = "$expect" ]; then
    printf 'PASS %s %s %s\n' "$id" "$label" "$desc"
    CHK_PASS=$((CHK_PASS + 1))
    _chk_gate "$gate" pass
  else
    case "$got" in
      launcher*) printf 'FAIL %s %s %s (%s)\n' "$id" "$label" "$desc" "$got" ;;
      *) printf 'FAIL %s %s %s (expected %s, got %s)\n' "$id" "$label" "$desc" "$expect" "$got" ;;
    esac
    [ -s "$CHK_ERRF" ] && sed -n '1,3s/^/     /p' "$CHK_ERRF"
    CHK_FAIL=$((CHK_FAIL + 1))
    _chk_gate "$gate" fail
  fi
}

# ---------------------------------------------------------------------------
# Rows (added per work package; see docs for check ids).
matrix_rows() {
  :
}

if [ -n "${_AIS_MATRIX_ROWS-}" ]; then
  matrix_rows() { . "$_AIS_MATRIX_ROWS"; }
fi

for prof in "$AIS_INSTALL_DIR"/profiles/*.sh; do
  [ -f "$prof" ] || continue
  CHK_PROFILE=$(basename "$prof" .sh)
  CHK_NET=
  matrix_rows
  for CHK_NET in allowlist none open; do matrix_rows; done
done

for g in $CFG_GATES; do
  eval "res=\${_CHK_GATE_$g-}"
  [ -n "$res" ] && gates_record "$g" "$res"
done

printf '%d passed, %d failed, %d skipped\n' "$CHK_PASS" "$CHK_FAIL" "$CHK_SKIP"
[ "$CHK_FAIL" -eq 0 ]
