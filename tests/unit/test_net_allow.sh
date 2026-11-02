# Allowlist file generation (spec §9). WP4.

run_allow() { # setup-code
  mk_tmp
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/net.sh"
    AI_SANDBOX_NET_PRESETS= AI_SANDBOX_NET_ALLOW= PROFILE_NET_ALLOW=()
    unset COPILOT_PROVIDER_BASE_URL COPILOT_API_URL ANTHROPIC_BASE_URL
    eval "$3"
    net_write_allow "$2/allow"
    sed "/^#/d" "$2/allow"
  ' _ "$REPO_ROOT" "$TMP" "$1"
}

test_merge_order_and_dedupe() {
  run_allow '
    PROFILE_NET_ALLOW=(api.anthropic.com "*.githubcopilot.com")
    export ANTHROPIC_BASE_URL=https://gw.example.com:8443/v1
    AI_SANDBOX_NET_PRESETS="npm"
    AI_SANDBOX_NET_ALLOW="extra.example.org api.anthropic.com registry.npmjs.org x.example:22"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "api.anthropic.com
*.githubcopilot.com
gw.example.com:8443
registry.npmjs.org
extra.example.org
x.example:22" "$OUT"
}

test_presets_match_the_spec_table() {
  run_allow 'AI_SANDBOX_NET_PRESETS="npm pypi github crates go"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "registry.npmjs.org
pypi.org
files.pythonhosted.org
github.com
api.github.com
codeload.github.com
objects.githubusercontent.com
raw.githubusercontent.com
github.com:22
crates.io
static.crates.io
index.crates.io
proxy.golang.org
sum.golang.org" "$OUT"
}

test_base_url_hosts_default_ports() {
  run_allow 'export COPILOT_API_URL=https://api.corp.example/ COPILOT_PROVIDER_BASE_URL=http://llm.local.example:11434'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "llm.local.example:11434
api.corp.example" "$OUT"
}

test_empty_inputs_give_an_empty_allowlist() {
  run_allow ''
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "" "$OUT"
}
