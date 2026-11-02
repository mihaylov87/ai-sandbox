# Hint when the harness command is not reachable inside (hidden $HOME). Stub backend.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

hint_fixture() {
  launcher_fixture
  mkdir -p "$HOME/.local/share/tool/versions" "$HOME/.local/bin"
  printf '#!/bin/sh\necho tool-ran\n' >"$HOME/.local/share/tool/versions/1.0"
  chmod 755 "$HOME/.local/share/tool/versions/1.0"
  ln -s "$HOME/.local/share/tool/versions/1.0" "$HOME/.local/bin/tool"
  export PATH="$HOME/.local/bin:$PATH"
}

test_hidden_command_on_path_gets_a_full_path_hint() {
  hint_fixture
  capture "$LAUNCHER" -- tool
  assert_contains "$ERR" "tool resolves to $HOME/.local/share/tool/versions/1.0, which is hidden" || return 1
  assert_contains "$ERR" "AI_SANDBOX_RO_PATHS" || return 1
  assert_contains "$ERR" "full path"
}

test_bare_name_with_listed_target_still_gets_a_full_path_hint() {
  hint_fixture
  printf 'AI_SANDBOX_RO_PATHS=%s\n' "$HOME/.local/share/tool" >>"$CONF/config"
  capture "$LAUNCHER" -- tool
  assert_contains "$ERR" "$HOME/.local/bin is hidden" || return 1
  assert_contains "$ERR" "$HOME/.local/share/tool/versions/1.0"
}

test_full_path_to_listed_target_gets_no_hint() {
  hint_fixture
  printf 'AI_SANDBOX_RO_PATHS=%s\n' "$HOME/.local/share/tool" >>"$CONF/config"
  capture "$LAUNCHER" -- "$HOME/.local/share/tool/versions/1.0"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq tool-ran "$OUT" || return 1
  assert_not_contains "$ERR" "hidden"
}

test_system_command_gets_no_hint() {
  hint_fixture
  capture "$LAUNCHER" -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$ERR" "hidden"
}
