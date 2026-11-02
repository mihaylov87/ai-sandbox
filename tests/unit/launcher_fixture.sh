# Shared fixture for launcher tests (WP9 onwards). Not a test file.
#
# Copies the launcher, lib/ and the stub backend into a mode-0755 install dir under a
# fake HOME (the checkout itself may be group-writable, which the launcher refuses),
# writes a minimal config and an empty "stub" profile, and selects the stub backend.

launcher_fixture() {
  mk_tmp
  export HOME="$TMP/home"
  WORK=$HOME/src/app
  CONF=$HOME/.config/ai-sandbox
  INSTALL=$TMP/install
  SESSIONS=$HOME/.local/state/ai-sandbox/sessions
  mkdir -p "$WORK" "$CONF/projects" "$INSTALL/lib" "$INSTALL/profiles" "$INSTALL/tests/unit"
  unset _AIS_NO_SECRETS _AIS_CHECK_NO_GATES _AIS_MATRIX_ROWS
  cp "$REPO_ROOT/ai-sandbox" "$REPO_ROOT/ai-sandbox-net" "$INSTALL/"
  cp "$REPO_ROOT"/lib/*.sh "$INSTALL/lib/"
  cp "$REPO_ROOT/tests/unit/backend-stub.sh" "$INSTALL/tests/unit/"
  : >"$INSTALL/profiles/stub.sh"
  chmod -R go-w "$INSTALL" "$HOME"
  chmod 0700 "$CONF"
  printf 'AI_SANDBOX_WORK_DIR=%s\nAI_SANDBOX_HARNESS=stub\n' "$WORK" >"$CONF/config"
  chmod 0600 "$CONF/config"
  local v
  for v in $(compgen -v AI_SANDBOX_); do unset "$v"; done
  unset AI_SANDBOX
  export _AIS_TEST_BACKEND=stub
  LAUNCHER=$INSTALL/ai-sandbox
}

# Directories currently in the sessions dir, one per line.
session_dirs() {
  [ -d "$SESSIONS" ] || return 0
  find "$SESSIONS" -mindepth 1 -maxdepth 1 -type d | sort
}
