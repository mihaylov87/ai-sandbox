# lib/gates.sh — verification gates and --check (spec §4 step 5, §13, §15).
# Bash 3.2 compatible.
#
# The gates file holds one line per gate: "<gate> pass|fail <date> <os version>".
# Results recorded under another OS version count as unchecked.
# A failed gate runs gate_fallback_<gate> if a backend or profile defines it; a fallback
# that returns non-zero cannot mitigate, and the launcher then refuses with exit 123
# unless the gate is listed in AI_SANDBOX_ACCEPT.

gates_file() { printf '%s\n' "$HOME/.local/state/ai-sandbox/gates"; }

gates_os_version() {
  case "$AIS_PLATFORM" in
    macos) printf 'macOS-%s\n' "$(sw_vers -productVersion 2>/dev/null || uname -r)" ;;
    *) printf '%s-%s\n' "$(uname -s)" "$(uname -r)" ;;
  esac
}

gates_record() { # gate pass|fail
  local f tmp
  f=$(gates_file)
  mkdir -p "$(dirname "$f")"
  tmp=$(mktemp "$f.XXXXXX")
  if [ -f "$f" ]; then grep -v "^$1 " "$f" >"$tmp" || true; fi
  printf '%s %s %s %s\n' "$1" "$2" "$(date +%Y-%m-%d)" "$(gates_os_version)" >>"$tmp"
  mv "$tmp" "$f"
}

gates_read() {
  local f g status date os current
  f=$(gates_file)
  for g in $CFG_GATES; do eval "_AIS_GATE_$g="; done
  # --check measures the defaults, so its sandboxes see no recorded results.
  [ "${_AIS_CHECK_NO_GATES-}" = 1 ] && return 0
  [ -f "$f" ] || return 0
  current=$(gates_os_version)
  while read -r g status date os; do
    case " $CFG_GATES " in *" $g "*) ;; *) continue ;; esac
    case "$status" in pass | fail) ;; *) continue ;; esac
    if [ "$os" = "$current" ]; then eval "_AIS_GATE_$g=\$status"; fi
  done <"$f"
}

gates_status() { # gate -> pass | fail | unchecked
  local v
  eval "v=\${_AIS_GATE_$1-}"
  printf '%s\n' "${v:-unchecked}"
}

_gates_refuse() { # gate
  case " $AI_SANDBOX_ACCEPT " in
    *" $1 "*)
      ais_warn "gate $1 failed and its fallback cannot mitigate it; starting anyway because AI_SANDBOX_ACCEPT lists $1"
      return 0
      ;;
  esac
  ais_die 123 "gate $1 failed on this system and its fallback cannot mitigate it (spec section 15); set AI_SANDBOX_ACCEPT=$1 to accept the risk"
}

# Run-sequence step 5.
gates_check() {
  local g
  gates_read
  [ -f "$(gates_file)" ] || ais_warn "verification gates not checked on this system yet; run: ai-sandbox --check"
  if [ -z "$AI_SANDBOX_DNS" ]; then
    if [ "$(gates_status G3)" = fail ]; then AI_SANDBOX_DNS=allow; else AI_SANDBOX_DNS=deny; fi
  fi
  [ "${_AIS_CHECK_NO_GATES-}" = 1 ] && return 0
  for g in $CFG_GATES; do
    [ "$(gates_status "$g")" = fail ] || continue
    if declare -F "gate_fallback_$g" >/dev/null; then
      "gate_fallback_$g" || _gates_refuse "$g"
    fi
  done
}

# --check: list skipped paths, then run the matrix (tests/matrix.sh).
check_run() {
  local m
  for m in ${POLICY_MISSING[@]+"${POLICY_MISSING[@]}"}; do
    printf 'NOTE missing %s path skipped: %s\n' "${m%% *}" "${m#* }"
  done
  AIS_INSTALL_DIR=$AIS_INSTALL_DIR AIS_PLATFORM=$AIS_PLATFORM CHK_WORK_DIR=$POLICY_WORK_DIR \
    CHK_PROJECT=$CLI_PROJECT CHK_HOME=$HOME CHK_RO_PATHS=$AI_SANDBOX_RO_PATHS \
    CHK_TEST_RO_DIR=$AI_SANDBOX_TEST_RO_DIR CHK_TEST_RW_DIR=$AI_SANDBOX_TEST_RW_DIR \
    CHK_STATE=$AI_SANDBOX_STATE CHK_HOST_SSH_SOCK=${SSH_AUTH_SOCK-} \
    bash "$AIS_INSTALL_DIR/tests/matrix.sh"
}
