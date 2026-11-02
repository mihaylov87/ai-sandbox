# Harness profiles and seeds (spec §11). WP6. Stub backend; the real profiles and seeds.

. "$(dirname "${BASH_SOURCE[0]}")/launcher_fixture.sh"

profile_fixture() { # harness
  launcher_fixture
  cp "$REPO_ROOT"/profiles/*.sh "$INSTALL/profiles/"
  cp -R "$REPO_ROOT/seeds" "$INSTALL/"
  chmod -R go-w "$INSTALL"
  printf 'AI_SANDBOX_WORK_DIR=%s\nAI_SANDBOX_HARNESS=%s\n' "$WORK" "$1" >"$CONF/config"
  STATE=$HOME/.local/state/ai-sandbox/$1
}

dump_profile() { # harness -> "NAME=value" lines for every PROFILE_* variable
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/gates.sh"
    AIS_INSTALL_DIR=$1 AI_SANDBOX_HARNESS=$2 AI_SANDBOX_STATE=isolated AIS_PLATFORM=linux
    AI_SANDBOX_ACCEPT=
    cfg_load_profile
    for v in PROFILE_COMMAND PROFILE_RW PROFILE_RO PROFILE_LOCKED PROFILE_SECRETS PROFILE_ENV PROFILE_PASS_ENV PROFILE_NET_ALLOW PROFILE_PATH_ADD; do
      eval "printf \"%s=%s\\n\" $v \"\${$v[*]-}\""
    done
    printf "PROFILE_STATE_ENV=%s\nPROFILE_STATE_DIR=%s\nPROFILE_ALLOW_USERNS=%s\n" "$PROFILE_STATE_ENV" "$PROFILE_STATE_DIR" "$PROFILE_ALLOW_USERNS"
  ' _ "$REPO_ROOT" "$1"
}

test_copilot_profile_matches_spec() {
  mk_tmp
  export HOME=$TMP
  dump_profile copilot
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "PROFILE_COMMAND=copilot --autopilot --allow-all
PROFILE_RW=. $HOME/.cache/ai-sandbox/copilot
PROFILE_RO=
PROFILE_LOCKED=hooks settings.json mcp-config.json lsp-config.json agents skills copilot-instructions.md config.json
PROFILE_SECRETS=COPILOT_GITHUB_TOKEN=copilot COPILOT_PROVIDER_API_KEY=copilot-byok?
PROFILE_ENV=COPILOT_CACHE_HOME=$HOME/.cache/ai-sandbox/copilot COPILOT_AUTO_UPDATE=false
PROFILE_PASS_ENV=COPILOT_API_URL COPILOT_PROVIDER_BASE_URL COPILOT_MODEL COPILOT_GH_HOST COPILOT_ALLOW_ALL
PROFILE_NET_ALLOW=api.githubcopilot.com *.githubcopilot.com api.github.com
PROFILE_PATH_ADD=
PROFILE_STATE_ENV=COPILOT_HOME
PROFILE_STATE_DIR=$HOME/.copilot
PROFILE_ALLOW_USERNS=0" "$OUT"
}

test_claude_profile_matches_spec() {
  mk_tmp
  export HOME=$TMP
  dump_profile claude
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "PROFILE_COMMAND=claude --dangerously-skip-permissions
PROFILE_RW=. $HOME/.cache/ai-sandbox/claude?
PROFILE_RO=
PROFILE_LOCKED=settings.json CLAUDE.md agents commands skills hooks plugins output-styles
PROFILE_SECRETS=CLAUDE_CODE_OAUTH_TOKEN=claude? ANTHROPIC_API_KEY=anthropic?
PROFILE_ENV=DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
PROFILE_PASS_ENV=ANTHROPIC_BASE_URL ANTHROPIC_MODEL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
PROFILE_NET_ALLOW=api.anthropic.com
PROFILE_PATH_ADD=
PROFILE_STATE_ENV=CLAUDE_CONFIG_DIR
PROFILE_STATE_DIR=$HOME/.claude
PROFILE_ALLOW_USERNS=0" "$OUT"
}

test_generic_profile_adds_nothing() {
  mk_tmp
  export HOME=$TMP
  dump_profile generic
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "PROFILE_COMMAND=
" || return 1
  assert_contains "$OUT" "PROFILE_LOCKED=
" || return 1
  assert_contains "$OUT" "PROFILE_NET_ALLOW=
" || return 1
  assert_contains "$OUT" "PROFILE_STATE_ENV=
"
}

test_failed_g6_leaves_copilot_config_json_rw_and_diffed() {
  mk_tmp
  export HOME=$TMP
  mkdir -p "$HOME/.local/state/ai-sandbox"
  printf 'G6 fail 2026-11-02 %s-%s\n' "$(uname -s)" "$(uname -r)" >"$HOME/.local/state/ai-sandbox/gates"
  dump_profile copilot
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$OUT" "config.json
" || return 1
  assert_contains "$OUT" "copilot-instructions.md
"
}

test_failed_g9_sets_allow_userns() {
  mk_tmp
  export HOME=$TMP
  mkdir -p "$HOME/.local/state/ai-sandbox"
  printf 'G9 fail 2026-11-02 %s-%s\n' "$(uname -s)" "$(uname -r)" >"$HOME/.local/state/ai-sandbox/gates"
  dump_profile claude
  assert_contains "$OUT" "PROFILE_ALLOW_USERNS=1"
}

test_isolated_state_is_seeded_and_exported() {
  profile_fixture claude
  mkdir -p "$CONF/seed/claude/hooks"
  echo '#!/bin/sh' >"$CONF/seed/claude/hooks/pre.sh"
  printf 'AI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN="echo tok"\nAI_SANDBOX_COMMAND="sh -c '"'"'echo \\$CLAUDE_CONFIG_DIR; cat \\$CLAUDE_CONFIG_DIR/settings.json'"'"'"\n' >>"$CONF/config"
  capture "$LAUNCHER"
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$STATE
$(cat "$REPO_ROOT/seeds/claude/settings.json")" "$OUT" || return 1
  [ -f "$STATE/hooks/pre.sh" ] || fail "user seed not copied"
}

test_user_seed_overrides_install_seed_and_reseeding_overwrites_changes() {
  profile_fixture claude
  mkdir -p "$CONF/seed/claude"
  echo '{"user": true}' >"$CONF/seed/claude/settings.json"
  printf 'AI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN="echo tok"\n' >>"$CONF/config"
  capture "$LAUNCHER" -- sh -c 'echo "{\"agent\": true}" >"$CLAUDE_CONFIG_DIR/settings.json"'
  assert_eq 0 "$RC" "$ERR" || return 1
  capture "$LAUNCHER" -- cat "$STATE/settings.json"
  assert_eq '{"user": true}' "$OUT"
}

test_locked_entries_missing_from_both_seeds_are_removed_from_state() {
  profile_fixture claude
  printf 'AI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN="echo tok"\n' >>"$CONF/config"
  capture "$LAUNCHER" -- sh -c 'mkdir -p "$CLAUDE_CONFIG_DIR/agents"; echo planted >"$CLAUDE_CONFIG_DIR/agents/evil.md"; echo keep >"$CLAUDE_CONFIG_DIR/notes.txt"'
  assert_eq 0 "$RC" "$ERR" || return 1
  capture "$LAUNCHER" -- true
  assert_eq 0 "$RC" "$ERR" || return 1
  [ ! -e "$STATE/agents" ] || fail "agent-created guardrail dir survived a restart" || return 1
  [ -f "$STATE/notes.txt" ] || fail "non-guardrail state was removed"
}

test_shared_mode_uses_normal_state_dir_without_seeding() {
  profile_fixture claude
  mkdir -p "$HOME/.claude"
  echo '{"mine": 1}' >"$HOME/.claude/settings.json"
  printf 'AI_SANDBOX_STATE=shared\nAI_SANDBOX_SECRET_CMD_CLAUDE_CODE_OAUTH_TOKEN="echo tok"\n' >>"$CONF/config"
  capture "$LAUNCHER" --print-policy --ir
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$OUT" "rw	dir	$HOME/.claude" || return 1
  assert_contains "$OUT" "locked	file	$HOME/.claude/settings.json" || return 1
  assert_eq '{"mine": 1}' "$(cat "$HOME/.claude/settings.json")" || return 1
  [ ! -d "$STATE" ] || fail "isolated state dir created in shared mode"
}

test_claude_preflight_requires_a_credential() {
  profile_fixture claude
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "preflight" || return 1
  assert_contains "$ERR" "claude"
}

test_copilot_requires_its_token_and_creates_its_cache_dir() {
  profile_fixture copilot
  capture "$LAUNCHER" -- true
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "COPILOT_GITHUB_TOKEN" || return 1
  printf 'AI_SANDBOX_SECRET_CMD_COPILOT_GITHUB_TOKEN="echo tok"\n' >>"$CONF/config"
  capture "$LAUNCHER" -- sh -c 'echo "$COPILOT_HOME $COPILOT_CACHE_HOME"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$STATE $HOME/.cache/ai-sandbox/copilot" "$OUT" || return 1
  [ -d "$HOME/.cache/ai-sandbox/copilot" ] || fail "copilot cache dir not created"
}

test_generic_requires_a_command() {
  profile_fixture generic
  capture "$LAUNCHER"
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "AI_SANDBOX_COMMAND"
}
