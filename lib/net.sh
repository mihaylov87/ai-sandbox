# lib/net.sh — egress allowlist and network helper lifecycle (spec §9). Bash 3.2 compatible.
#
# net_write_allow FILE writes $SESSION/allow, merged in this order with duplicates removed:
# profile baseline (PROFILE_NET_ALLOW); the host of COPILOT_PROVIDER_BASE_URL, COPILOT_API_URL
# or ANTHROPIC_BASE_URL if set; presets (AI_SANDBOX_NET_PRESETS); AI_SANDBOX_NET_ALLOW (which
# already holds --allow-host entries, appended by the CLI). Entries are validated by the proxy.

net_preset() { # name -> entries, one per line
  case "$1" in
    npm) printf '%s\n' registry.npmjs.org ;;
    pypi) printf '%s\n' pypi.org files.pythonhosted.org ;;
    github) printf '%s\n' github.com api.github.com codeload.github.com objects.githubusercontent.com \
      raw.githubusercontent.com github.com:22 ;;
    crates) printf '%s\n' crates.io static.crates.io index.crates.io ;;
    go) printf '%s\n' proxy.golang.org sum.golang.org ;;
  esac
}

# Host (with an explicit port, if the URL has one) of an http(s) URL.
net_url_host() {
  local u=$1
  u=${u#*://}
  u=${u%%/*}
  u=${u%%\?*}
  u=${u##*@}
  printf '%s\n' "$u"
}

net_write_allow() { # file
  local f=$1 e v seen=" " entries
  entries=$(
    for e in ${PROFILE_NET_ALLOW[@]+"${PROFILE_NET_ALLOW[@]}"}; do printf '%s\n' "$e"; done
    for v in COPILOT_PROVIDER_BASE_URL COPILOT_API_URL ANTHROPIC_BASE_URL; do
      [ -n "${!v-}" ] && net_url_host "${!v}"
    done
    for e in $AI_SANDBOX_NET_PRESETS; do net_preset "$e"; done
    set -f
    for e in $AI_SANDBOX_NET_ALLOW; do printf '%s\n' "$e"; done
  )
  {
    printf '# ai-sandbox allowlist, generated for this session (spec section 9)\n'
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      case "$seen" in *" $e "*) continue ;; esac
      seen="$seen$e "
      printf '%s\n' "$e"
    done <<EOF
$entries
EOF
  } >"$f"
}
