# CLI parsing (spec §6). WP1.

# Parse args in a fresh bash and dump the parse result.
run_cli() {
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; shift
    cli_parse "$@"
    printf "mode=%s\n" "$CLI_MODE"
    printf "ir=%s keep=%s netlog=%s verbose=%s\n" "$CLI_IR" "$CLI_KEEP_SESSION" "$CLI_NET_LOG" "$CLI_VERBOSE"
    printf "work=%s harness=%s project=%s net=%s ssh=%s\n" "$CLI_WORK_DIR" "$CLI_HARNESS" "$CLI_PROJECT" "$CLI_NET" "$CLI_SSH_AGENT"
    for x in ${CLI_RW[@]+"${CLI_RW[@]}"}; do printf "rw=%s\n" "$x"; done
    for x in ${CLI_RO[@]+"${CLI_RO[@]}"}; do printf "ro=%s\n" "$x"; done
    for x in ${CLI_HIDE[@]+"${CLI_HIDE[@]}"}; do printf "hide=%s\n" "$x"; done
    for x in ${CLI_ALLOW_HOST[@]+"${CLI_ALLOW_HOST[@]}"}; do printf "allow=%s\n" "$x"; done
    for x in ${CLI_HOST_PORT[@]+"${CLI_HOST_PORT[@]}"}; do printf "port=%s\n" "$x"; done
    printf "cmdset=%s\n" "$CLI_CMD_SET"
    for x in ${CLI_CMD[@]+"${CLI_CMD[@]}"}; do printf "cmd=[%s]\n" "$x"; done
  ' _ "$REPO_ROOT" "$@"
}

test_no_args_runs_profile_command() {
  run_cli
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "mode=run" || return 1
  assert_contains "$OUT" "cmdset=0"
}

test_all_value_options_parsed() {
  run_cli -w /w -H claude -p proj --net none --ssh-agent \
    --work-dir /w2 --harness generic --project p2
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "work=/w2 harness=generic project=p2 net=none ssh=1"
}

test_repeatable_options_accumulate_in_order() {
  run_cli --rw /a --rw '/b c' --ro /r --hide /h1 --hide /h2 \
    --allow-host x.com --allow-host 'y.com:22' --host-port 11434 --host-port 8080
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "rw=/a
rw=/b c
ro=/r
hide=/h1
hide=/h2
allow=x.com
allow=y.com:22
port=11434
port=8080"
}

test_command_after_double_dash_replaces_profile_command() {
  run_cli --net open -- bash -c 'echo "a b"' --rw x
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "cmdset=1
cmd=[bash]
cmd=[-c]
cmd=[echo \"a b\"]
cmd=[--rw]
cmd=[x]"
}

test_first_non_option_starts_command() {
  run_cli -v copilot --help
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "verbose=1" || return 1
  assert_contains "$OUT" "cmd=[copilot]
cmd=[--help]"
}

test_shell_mode_takes_remaining_args() {
  run_cli --shell -c 'make test'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "mode=shell" || return 1
  assert_contains "$OUT" "cmd=[-c]
cmd=[make test]"
}

test_print_policy_with_ir() {
  run_cli --print-policy --ir
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "mode=print-policy" || return 1
  assert_contains "$OUT" "ir=1"
}

test_modes_and_flags() {
  run_cli --dry-run --keep-session --net-log
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "mode=dry-run" || return 1
  assert_contains "$OUT" "keep=1 netlog=1"
  run_cli --check
  assert_contains "$OUT" "mode=check"
}

test_ir_without_print_policy_exits_125() {
  run_cli --ir
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "--ir"
}

test_unknown_option_exits_125() {
  run_cli --frobnicate
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "--frobnicate"
}

test_missing_option_value_exits_125() {
  run_cli --rw
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "--rw"
}

test_help_prints_usage_and_exits_0() {
  run_cli -h
  assert_eq 0 "$RC" || return 1
  assert_contains "$OUT" "ai-sandbox [options] [--] [command [args...]]"
}

test_cli_rw_paths_are_kept_for_policy_not_config() {
  mk_tmp
  export HOME="$TMP"
  mkdir -p "$TMP/w"
  capture bash -c '. "$1/lib/config.sh"; cfg_load -w "$2" --rw /x --allow-host a.com --host-port 99 --ssh-agent;
    printf "%s|%s|%s|%s\n" "$AI_SANDBOX_RW_PATHS" "$AI_SANDBOX_NET_ALLOW" "$AI_SANDBOX_HOST_PORTS" "$AI_SANDBOX_SSH_AGENT"' \
    _ "$REPO_ROOT" "$TMP/w"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "|a.com|99|1" "$OUT"
}
