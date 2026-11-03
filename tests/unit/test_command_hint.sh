# The harness command must be reachable inside (hidden $HOME, spec §6). Stub backend.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

hint_fixture() {
  launcher_fixture
  mkdir -p "$HOME/.local/share/tool/versions" "$HOME/.local/bin"
  printf '#!/bin/sh\necho "tool-ran as $0"\n' >"$HOME/.local/share/tool/versions/1.0"
  chmod 755 "$HOME/.local/share/tool/versions/1.0"
  ln -s "$HOME/.local/share/tool/versions/1.0" "$HOME/.local/bin/tool"
  export PATH="$HOME/.local/bin:$PATH"
}

test_hidden_command_on_path_exits_127_with_a_hint() {
  hint_fixture
  capture "$LAUNCHER" -- tool
  assert_eq 127 "$RC" "$OUT" || return 1
  assert_not_contains "$OUT" "tool-ran" || return 1
  assert_contains "$ERR" "tool resolves to $HOME/.local/share/tool/versions/1.0, which is hidden" || return 1
  assert_contains "$ERR" "AI_SANDBOX_RO_PATHS"
}

test_bare_name_with_listed_target_runs_by_its_real_path() {
  hint_fixture
  printf 'AI_SANDBOX_RO_PATHS=%s\n' "$HOME/.local/share/tool" >>"$CONF/config"
  capture "$LAUNCHER" -- tool
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "tool-ran as $HOME/.local/share/tool/versions/1.0" "$OUT" || return 1
  assert_not_contains "$ERR" "hidden" || return 1
  # -v says so; --dry-run shows the resolved command.
  capture "$LAUNCHER" -v -- tool
  assert_contains "$ERR" "running tool by its real path: $HOME/.local/share/tool/versions/1.0" || return 1
  capture "$LAUNCHER" --dry-run -- tool --flag
  assert_contains "$OUT" "command: $HOME/.local/share/tool/versions/1.0 --flag"
}

test_full_path_to_listed_target_runs_unchanged() {
  hint_fixture
  printf 'AI_SANDBOX_RO_PATHS=%s\n' "$HOME/.local/share/tool" >>"$CONF/config"
  capture "$LAUNCHER" -- "$HOME/.local/share/tool/versions/1.0"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "tool-ran as $HOME/.local/share/tool/versions/1.0" "$OUT" || return 1
  assert_not_contains "$ERR" "hidden"
}

test_dry_run_only_warns_when_unreachable() {
  hint_fixture
  capture "$LAUNCHER" --dry-run -- tool
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "which is hidden"
}

test_system_command_runs_unchanged() {
  hint_fixture
  capture "$LAUNCHER" -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$ERR" "hidden"
}
