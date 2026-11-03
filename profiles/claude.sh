# Claude Code (spec §11). Sourced by the launcher; Bash 3.2 compatible.
# CLAUDE_CODE_OAUTH_TOKEN comes from `claude setup-token` (valid about one year).
# CLAUDE_CONFIG_DIR holds settings, transcripts and .claude.json. The seeded settings.json
# switches Claude Code's own sandbox off (the outer sandbox is the boundary); add any hooks
# you want enforced to your seed in ~/.config/ai-sandbox/seed/claude/.
# `shared` state is discouraged: ~/.claude.json must then be RW and holds user-scope MCP
# servers that unsandboxed sessions would run.
PROFILE_COMMAND=(claude --dangerously-skip-permissions)
PROFILE_STATE_ENV=CLAUDE_CONFIG_DIR
PROFILE_STATE_DIR="$HOME/.claude"
PROFILE_RW=("." "$HOME/.cache/ai-sandbox/claude?")
PROFILE_LOCKED=(settings.json CLAUDE.md agents commands skills hooks plugins output-styles)
PROFILE_SECRETS=(CLAUDE_CODE_OAUTH_TOKEN=claude? ANTHROPIC_API_KEY=anthropic?)
PROFILE_ENV=(DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
PROFILE_PASS_ENV=(ANTHROPIC_BASE_URL ANTHROPIC_MODEL CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX)
PROFILE_NET_ALLOW=(api.anthropic.com platform.claude.com) # platform: interactive start-up check (G10)
PROFILE_HERDR_AGENT=claude   # herdr agent name, set as HERDR_AGENT inside a herdr pane
profile_preflight() {   # exactly one credential
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]
}

# Gate G7: if Claude Code does not start unattended with a fresh config dir, also seed
# .claude.json (once; Claude Code writes it afterwards).
profile_seed_extra() {
  if profile_gate_failed G7 && [ ! -e "$AIS_STATE_DIR/.claude.json" ]; then
    printf '{"hasCompletedOnboarding": true}\n' >"$AIS_STATE_DIR/.claude.json"
  fi
}
# Gate G9: a harness that refuses to start under --disable-userns.
if profile_gate_failed G9; then PROFILE_ALLOW_USERNS=1; fi
