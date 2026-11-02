# Config loading and validation (spec §6). WP1.

# Fixture: fake HOME with a config dir and a work dir.
cfg_fixture() {
  mk_tmp
  export HOME="$TMP/home"
  CONF="$HOME/.config/ai-sandbox"
  WORK="$HOME/src/app"
  mkdir -p "$CONF/projects" "$WORK"
  chmod 0700 "$CONF"
  # Drop any AI_SANDBOX_* inherited from the developer's shell.
  local v
  for v in $(compgen -v AI_SANDBOX_); do unset "$v"; done
}

write_conf() { # file content
  printf '%s\n' "$2" >"$1"
  chmod 0600 "$1"
}

# Run cfg_load in a fresh bash, then print the named variables.
# Usage: run_cfg "VAR1 VAR2" [cli args...]
run_cfg() {
  local vars=$1
  shift
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"
    vars=$2; shift 2
    cfg_load "$@"
    for v in $vars; do
      eval "printf \"%s=%s\\n\" \"\$v\" \"\${$v-<unset>}\""
    done
  ' _ "$REPO_ROOT" "$vars" "$@"
}

test_defaults_apply_when_only_work_dir_set() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK"
  run_cfg "AI_SANDBOX_HARNESS AI_SANDBOX_NET AI_SANDBOX_STATE AI_SANDBOX_GIT_CONFIG AI_SANDBOX_EXIT_REPORT AI_SANDBOX_SSH_AGENT AI_SANDBOX_LOCALHOST AI_SANDBOX_KEYCHAIN"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_HARNESS=copilot
AI_SANDBOX_NET=allowlist
AI_SANDBOX_STATE=isolated
AI_SANDBOX_GIT_CONFIG=locked
AI_SANDBOX_EXIT_REPORT=1
AI_SANDBOX_SSH_AGENT=0
AI_SANDBOX_LOCALHOST=isolated
AI_SANDBOX_KEYCHAIN=deny" "$OUT"
}

test_global_config_values_taken_over() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_HARNESS=claude
AI_SANDBOX_NET_PRESETS=\"github npm\""
  run_cfg "AI_SANDBOX_WORK_DIR AI_SANDBOX_HARNESS AI_SANDBOX_NET_PRESETS"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_HARNESS=claude
AI_SANDBOX_NET_PRESETS=github npm" "$OUT"
}

test_tilde_in_config_is_expanded_by_bash() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=~/src/app
AI_SANDBOX_RO_PATHS=~/.gitconfig:~/.ssh/known_hosts"
  run_cfg "AI_SANDBOX_WORK_DIR AI_SANDBOX_RO_PATHS"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_WORK_DIR=$HOME/src/app
AI_SANDBOX_RO_PATHS=$HOME/.gitconfig:$HOME/.ssh/known_hosts" "$OUT"
}

test_non_ai_sandbox_assignments_are_not_taken_over() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
PATH=/nowhere
FOO=bar"
  run_cfg "FOO"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "FOO=<unset>" "$OUT"
}

test_missing_global_config_is_fine_with_env_work_dir() {
  cfg_fixture
  export AI_SANDBOX_WORK_DIR="$WORK"
  run_cfg "AI_SANDBOX_WORK_DIR"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_WORK_DIR=$WORK" "$OUT"
}

test_missing_work_dir_exits_125() {
  cfg_fixture
  run_cfg ""
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_WORK_DIR"
}

test_project_by_name_overrides_global() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_HARNESS=copilot"
  write_conf "$CONF/projects/p1.conf" "AI_SANDBOX_HARNESS=claude"
  run_cfg "AI_SANDBOX_HARNESS" --project p1
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_HARNESS=claude" "$OUT"
}

test_unknown_project_name_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK"
  run_cfg "" --project nope
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "nope"
}

test_project_chosen_by_matching_work_dir() {
  cfg_fixture
  mkdir -p "$HOME/src/other"
  write_conf "$CONF/projects/a.conf" "AI_SANDBOX_WORK_DIR=$HOME/src/other
AI_SANDBOX_HARNESS=generic"
  write_conf "$CONF/projects/b.conf" "AI_SANDBOX_WORK_DIR=~/src/app/
AI_SANDBOX_HARNESS=claude"
  run_cfg "AI_SANDBOX_HARNESS" -w "$WORK"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_HARNESS=claude" "$OUT"
}

test_project_matching_uses_resolved_work_dir() {
  cfg_fixture
  ln -s "$WORK" "$HOME/link"
  write_conf "$CONF/projects/b.conf" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_HARNESS=claude"
  run_cfg "AI_SANDBOX_HARNESS" -w "$HOME/link"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_HARNESS=claude" "$OUT"
}

test_env_overrides_config_files() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_NET=none"
  export AI_SANDBOX_NET=open
  run_cfg "AI_SANDBOX_NET"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_NET=open" "$OUT"
}

test_cli_overrides_env() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK"
  export AI_SANDBOX_NET=open AI_SANDBOX_HARNESS=copilot
  run_cfg "AI_SANDBOX_NET AI_SANDBOX_HARNESS" --net none -H claude
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_NET=none
AI_SANDBOX_HARNESS=claude" "$OUT"
}

test_unknown_variable_in_file_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_NETT=open"
  run_cfg ""
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_NETT"
}

test_unknown_variable_in_env_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK"
  export AI_SANDBOX_RW_PATH="$WORK"
  run_cfg ""
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_RW_PATH"
}

test_invalid_enum_exits_125_naming_variable() {
  local spec
  for spec in AI_SANDBOX_NET=allow-all AI_SANDBOX_STATE=private AI_SANDBOX_SSH_AGENT=yes \
              AI_SANDBOX_GIT_CONFIG=unlocked AI_SANDBOX_EXIT_REPORT=2 AI_SANDBOX_DOCKER=true \
              AI_SANDBOX_LOCALHOST=open AI_SANDBOX_DNS=maybe AI_SANDBOX_KEYCHAIN=yes; do
    cfg_fixture
    write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
$spec"
    run_cfg ""
    assert_eq 125 "$RC" "$spec" || return 1
    assert_contains "$ERR" "${spec%%=*}" || return 1
  done
}

test_invalid_list_items_exit_125() {
  local spec
  for spec in 'AI_SANDBOX_HOST_PORTS="80 abc"' 'AI_SANDBOX_HOST_PORTS=70000' 'AI_SANDBOX_HOST_PORTS=0' \
              'AI_SANDBOX_NET_PRESETS="github cargo"' 'AI_SANDBOX_ACCEPT="G1 G11"' \
              'AI_SANDBOX_HARNESS=../evil' 'AI_SANDBOX_PASS_ENV="FOO 1BAR"'; do
    cfg_fixture
    write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
$spec"
    run_cfg ""
    assert_eq 125 "$RC" "$spec" || return 1
    assert_contains "$ERR" "$(printf '%s' "$spec" | sed 's/=.*//')" || return 1
  done
}

test_valid_lists_accepted() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_HOST_PORTS=\"11434 8080\"
AI_SANDBOX_NET_PRESETS=\"npm pypi github crates go\"
AI_SANDBOX_ACCEPT=\"G1 G10\"
AI_SANDBOX_PASS_ENV=\"FOO BAR_2\""
  run_cfg "AI_SANDBOX_HOST_PORTS"
  assert_eq 0 "$RC" "$ERR"
}

test_group_writable_config_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK"
  chmod 0620 "$CONF/config"
  run_cfg ""
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "config file $CONF/config is group- or world-writable" || return 1
  assert_not_contains "$ERR" "AI_SANDBOX_WORK_DIR is not set"
}

test_world_writable_project_file_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK"
  write_conf "$CONF/projects/p.conf" "AI_SANDBOX_HARNESS=claude"
  chmod 0602 "$CONF/projects/p.conf"
  run_cfg "" --project p
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "p.conf is group- or world-writable"
}

test_bad_permissions_on_auto_matched_project_exit_125() {
  cfg_fixture
  write_conf "$CONF/projects/p.conf" "AI_SANDBOX_WORK_DIR=$WORK"
  chmod 0660 "$CONF/projects/p.conf"
  run_cfg "" -w "$WORK"
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "p.conf is group- or world-writable"
}

test_unbound_variable_in_config_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=\$NOT_SET_ANYWHERE/x"
  run_cfg ""
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "$CONF/config"
}

test_array_assignment_in_config_exits_125() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_RW_PATHS=(a b)"
  run_cfg ""
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_RW_PATHS"
}

test_config_output_does_not_leak_into_values() {
  cfg_fixture
  write_conf "$CONF/config" "echo noise
AI_SANDBOX_WORK_DIR=$WORK"
  run_cfg "AI_SANDBOX_WORK_DIR"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_WORK_DIR=$WORK" "$OUT"
}

test_values_with_spaces_and_quotes_survive() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_COMMAND='claude --model \"x y\" \$HOME'"
  run_cfg "AI_SANDBOX_COMMAND"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq 'AI_SANDBOX_COMMAND=claude --model "x y" $HOME' "$OUT"
}

test_secret_cmd_variables_are_accepted() {
  cfg_fixture
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN=\"cat x\""
  run_cfg "AI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "AI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN=cat x" "$OUT"
}

test_v1_extra_rw_alias_warns_and_adds_rw() {
  cfg_fixture
  mkdir -p "$HOME/lib1" "$HOME/lib2"
  write_conf "$CONF/config" "AI_SANDBOX_WORK_DIR=$WORK
AI_SANDBOX_EXTRA_RW=$HOME/lib1:$HOME/lib2
AI_SANDBOX_EXTRA_RO=$HOME/lib1"
  capture bash -c '. "$1/lib/config.sh"; cfg_load; printf "rw=%s\n" "${CLI_RW[@]}"; printf "ro=%s\n" "${CLI_RO[@]}"' _ "$REPO_ROOT"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$ERR" "AI_SANDBOX_EXTRA_RW" || return 1
  assert_contains "$ERR" "deprecated" || return 1
  assert_eq "rw=$HOME/lib1
rw=$HOME/lib2
ro=$HOME/lib1" "$OUT"
}

test_config_example_loads_cleanly() {
  cfg_fixture
  cp "$REPO_ROOT/config.example" "$CONF/config"
  chmod 0600 "$CONF/config"
  run_cfg "AI_SANDBOX_WORK_DIR AI_SANDBOX_HARNESS AI_SANDBOX_NET_PRESETS"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "" "$ERR" "no warnings expected" || return 1
  assert_eq "AI_SANDBOX_WORK_DIR=$HOME/src/app
AI_SANDBOX_HARNESS=claude
AI_SANDBOX_NET_PRESETS=github npm pypi" "$OUT"
}
