#!/usr/bin/env bash
# Flags constructs that Bash 3.2 does not support (spec §4, CLAUDE.md).
# Usage: tests/lint-bash32.sh [file...]   (default: all launcher-side Bash files)
# A static check only; it does not replace running the suite under Bash 3.2.
# lint-bash32: ignore-file
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)

if [ "$#" -eq 0 ]; then
  set --
  for f in "$root/ai-sandbox" "$root/setup.sh" "$root"/lib/*.sh "$root"/profiles/*.sh \
           "$root"/tests/*.sh "$root"/tests/unit/*.sh; do
    [ -f "$f" ] && set -- "$@" "$f"
  done
fi

patterns='
declare -[a-zA-Z]*[An] ## associative array or nameref (declare -A / -n)
local -[a-zA-Z]*[An] ## associative array or nameref (local -A / -n)
(^|[;&|[:space:]])(mapfile|readarray)([[:space:]]|$) ## mapfile / readarray
\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)[^}]*\} ## case modification ${v,,} / ${v^^}
\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAaKkUuL]\} ## parameter transformation ${v@Q}
\|& ## pipe stderr |&
&>> ## append redirection &>>
\[\[ +-v  ## [[ -v ]] (Bash 4.2)
\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]\} ## negative array index (Bash 4.3)
(^|[;&|[:space:]])wait +-n ## wait -n (Bash 4.3)
(^|[;&|[:space:]])coproc([[:space:]]|$) ## coproc
;;& ## case fall-through ;;&
\$(EPOCHSECONDS|EPOCHREALTIME|BASHPID) ## Bash 4+/5 variable
'

status=0
for f in "$@"; do
  # Files that hold these constructs as data (this script, its test) opt out.
  if grep -q '^# lint-bash32: ignore-file' "$f"; then continue; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    re=${line% ## *}
    what=${line##* ## }
    # Ignore full-line comments.
    hits=$(grep -nE -- "$re" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [ -n "$hits" ]; then
      printf '%s: %s\n' "$f" "$what"
      printf '%s\n' "$hits" | sed 's/^/  /'
      status=1
    fi
  done <<EOF
$patterns
EOF
done
exit "$status"
