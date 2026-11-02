# Bash 3.2 compatibility lint (CLAUDE.md constraints).
# lint-bash32: ignore-file

test_lint_flags_bash4_constructs() {
  mk_tmp
  local bad
  for bad in 'declare -A m' 'local -A m' 'mapfile -t a <f' 'readarray a' \
             'echo ${v,,}' 'echo ${v^^}' 'declare -n r=x' 'local -n r=x' \
             'cmd |& tee' 'cmd &>> log' '[[ -v x ]]' 'echo ${a[-1]}' 'wait -n' \
             'echo ${v@Q}' 'coproc foo'; do
    printf '#!/bin/bash\n%s\n' "$bad" >"$TMP/bad.sh"
    capture "$REPO_ROOT/tests/lint-bash32.sh" "$TMP/bad.sh"
    assert_eq 1 "$RC" "lint must reject: $bad" || return 1
  done
}

test_lint_accepts_portable_code() {
  mk_tmp
  printf '#!/bin/bash\nset -euo pipefail\na=(x y)\nfor i in ${a[@]+"${a[@]}"}; do printf "%%s\\n" "$i"; done\n' >"$TMP/ok.sh"
  capture "$REPO_ROOT/tests/lint-bash32.sh" "$TMP/ok.sh"
  assert_eq 0 "$RC" "$OUT $ERR"
}

test_lint_repo_launcher_files_clean() {
  capture "$REPO_ROOT/tests/lint-bash32.sh"
  assert_eq 0 "$RC" "$OUT $ERR"
}
