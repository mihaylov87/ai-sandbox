# GitHub Copilot CLI (spec §11). Sourced by the launcher; Bash 3.2 compatible.
# COPILOT_GITHUB_TOKEN must be a fine-grained PAT with the Copilot Requests permission
# (classic ghp_ PATs are not accepted). COPILOT_HOME replaces the whole ~/.copilot tree.
# Copilot's own local sandboxing stays off (its default); the seeded settings.json keeps it
# that way and is locked.
PROFILE_COMMAND=(copilot --autopilot --allow-all)
PROFILE_STATE_ENV=COPILOT_HOME
PROFILE_STATE_DIR="$HOME/.copilot"
PROFILE_RW=("." "$HOME/.cache/ai-sandbox/copilot")
PROFILE_LOCKED=(hooks settings.json mcp-config.json lsp-config.json
                agents skills copilot-instructions.md)   # + config.json per gate G6
PROFILE_SECRETS=(COPILOT_GITHUB_TOKEN=copilot COPILOT_PROVIDER_API_KEY=copilot-byok?)
PROFILE_ENV=(COPILOT_CACHE_HOME="$HOME/.cache/ai-sandbox/copilot" COPILOT_AUTO_UPDATE=false)
PROFILE_PASS_ENV=(COPILOT_API_URL COPILOT_PROVIDER_BASE_URL COPILOT_MODEL
                  COPILOT_GH_HOST COPILOT_ALLOW_ALL)
PROFILE_NET_ALLOW=(api.githubcopilot.com '*.githubcopilot.com' api.github.com)

# Gate G6: config.json is locked unless Copilot was seen rewriting it at runtime; then it
# stays RW and the exit report always diffs it.
if profile_gate_failed G6; then
  EXITREPORT_ALWAYS_DIFF=(${EXITREPORT_ALWAYS_DIFF[@]+"${EXITREPORT_ALWAYS_DIFF[@]}"} config.json)
else
  PROFILE_LOCKED=("${PROFILE_LOCKED[@]}" config.json)
fi
# Gate G9: a harness that refuses to start under --disable-userns.
if profile_gate_failed G9; then PROFILE_ALLOW_USERNS=1; fi
