# lib/env.sh — environment and secrets (spec §10). Bash 3.2 compatible.
#
# env_build fills AIS_ENV_K / AIS_ENV_V / AIS_ENV_SECRET (parallel arrays; secret = 1
# marks values that are never printed). env_print prints them for --dry-run with secrets
# redacted. env_apply runs in the child's subshell: it un-exports everything, exports the
# built set and names it in _AIS_KEEP_ENV, which the launcher's exec step uses to drop
# anything else (bash's "_", locale coercion) before the final exec.
# Secret values live only in these arrays and the child's environment: never in argv,
# never in a file.

AIS_ENV_K=() AIS_ENV_V=() AIS_ENV_SECRET=()

ENV_PROXY_NAMES="HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy NO_PROXY no_proxy"

env_set() { # name value [secret]
  local i=0
  while [ "$i" -lt "${#AIS_ENV_K[@]}" ]; do
    if [ "${AIS_ENV_K[$i]}" = "$1" ]; then
      AIS_ENV_V[$i]=$2 AIS_ENV_SECRET[$i]=${3:-0}
      return 0
    fi
    i=$((i + 1))
  done
  AIS_ENV_K[$i]=$1 AIS_ENV_V[$i]=$2 AIS_ENV_SECRET[$i]=${3:-0}
}

# Names that never cross the boundary from the caller (spec §10).
env_is_never_forwarded() {
  case "$1" in
    SSH_AUTH_SOCK | DOCKER_HOST | DBUS_SESSION_BUS_ADDRESS | XDG_RUNTIME_DIR | DISPLAY | \
      WAYLAND_DISPLAY | AWS_* | GOOGLE_APPLICATION_CREDENTIALS | AZURE_* | KUBECONFIG | \
      NPM_TOKEN | GH_TOKEN | GITHUB_TOKEN) return 0 ;;
  esac
  return 1
}

_env_is_proxy_name() {
  case " $ENV_PROXY_NAMES " in *" $1 "*) return 0 ;; esac
  return 1
}

_env_profile_secret_vars() {
  local e
  for e in ${PROFILE_SECRETS[@]+"${PROFILE_SECRETS[@]}"}; do printf '%s\n' "${e%%=*}"; done
}

_env_forward() { # name source
  local n=$1
  [ -n "${!n+x}" ] || return 0
  if _env_is_proxy_name "$n"; then
    ais_warn "host proxy variable $n (from $2) is not forwarded; set AI_SANDBOX_UPSTREAM_PROXY instead"
    return 0
  fi
  env_set "$n" "${!n}"
}

# Proxy variables inside (spec §9), all modes except open.
env_proxy() { # port
  local url="http://127.0.0.1:$1" n
  for n in HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy; do env_set "$n" "$url"; done
  env_set NO_PROXY localhost,127.0.0.1,::1
  env_set no_proxy localhost,127.0.0.1,::1
  env_set NODE_USE_ENV_PROXY 1
  env_set GIT_SSH_COMMAND "ssh -o ProxyCommand='nc -X connect -x 127.0.0.1:$1 %h %p'"
}

# Resolve one secret on the host. Prints nothing; sets the variable via env_set.
_env_secret() { # var secret-name optional(0|1)
  local var=$1 name=$2 opt=$3 cmdvar="AI_SANDBOX_SECRET_CMD_$1" file val rc
  file="$HOME/$AIS_CONFIG_DIR_REL/secrets/$name"
  if [ -n "${!cmdvar-}" ]; then
    set +e
    val=$(bash -c "${!cmdvar}")
    rc=$?
    set -e
    [ "$rc" = 0 ] || ais_die 125 "$cmdvar failed (exit $rc)"
  elif [ -e "$file" ]; then
    [ -n "$(find -H "$file" -prune -type f -perm 600 -user "$(id -u)" 2>/dev/null)" ] ||
      ais_die 125 "secret file $file must be a regular file owned by you with mode 0600"
    val=$(cat "$file")
  else
    val=
  fi
  if [ -z "$val" ]; then
    [ "$opt" = 1 ] && return 0
    ais_die 125 "missing secret $var for profile $AI_SANDBOX_HARNESS: set $cmdvar or create $file (mode 0600)"
  fi
  env_set "$var" "$val" 1
}

env_secrets() {
  local e var name opt done_vars=" " v
  # Matrix checks run a stub command and need no credentials (tests/matrix.sh).
  [ "${_AIS_NO_SECRETS-}" = 1 ] && return 0
  for e in ${PROFILE_SECRETS[@]+"${PROFILE_SECRETS[@]}"}; do
    var=${e%%=*} name=${e#*=} opt=0
    case "$name" in *\?) name=${name%\?} opt=1 ;; esac
    _env_secret "$var" "$name" "$opt"
    done_vars="$done_vars$var "
  done
  # Any other AI_SANDBOX_SECRET_CMD_<VAR> sets <VAR> too (spec §6).
  for v in $(compgen -v AI_SANDBOX_SECRET_CMD_); do
    var=${v#AI_SANDBOX_SECRET_CMD_}
    case "$done_vars" in *" $var "*) continue ;; esac
    _env_secret "$var" "-" 0
  done
}

env_build() {
  local n d path= secret_vars e
  AIS_ENV_K=() AIS_ENV_V=() AIS_ENV_SECRET=()
  secret_vars=" $(_env_profile_secret_vars | tr '\n' ' ') "

  for n in $AI_SANDBOX_PASS_ENV ${PROFILE_PASS_ENV[@]+"${PROFILE_PASS_ENV[@]}"}; do
    env_is_never_forwarded "$n" && ais_die 125 "$n must never be forwarded into the sandbox (remove it from AI_SANDBOX_PASS_ENV)"
    case "$secret_vars" in *" $n "*) ais_die 125 "$n is a secret of profile $AI_SANDBOX_HARNESS and is never copied from the calling shell" ;; esac
  done

  # Forwarded if set (spec §10).
  for n in COLORTERM EDITOR VISUAL GH_HOST $(compgen -e | grep '^HERDR_' || true); do _env_forward "$n" default; done
  for n in ${PROFILE_PASS_ENV[@]+"${PROFILE_PASS_ENV[@]}"}; do _env_forward "$n" PROFILE_PASS_ENV; done
  for n in $AI_SANDBOX_PASS_ENV; do _env_forward "$n" AI_SANDBOX_PASS_ENV; done

  # Copied if set.
  for n in TERM LANG TZ $(compgen -e | grep '^LC_' || true); do
    [ -n "${!n+x}" ] && env_set "$n" "${!n}"
  done

  # Set by the launcher; these win over forwarded values.
  env_set HOME "$HOME"
  d=$(id -un)
  env_set USER "$d"
  env_set LOGNAME "$d"
  env_set SHELL /bin/bash
  for d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
    [ -d "$d" ] && path=${path:+$path:}$d
  done
  for d in ${PROFILE_PATH_ADD[@]+"${PROFILE_PATH_ADD[@]}"}; do path=${path:+$path:}$d; done
  env_set PATH "$path"
  if [ "$AIS_PLATFORM" = macos ]; then env_set TMPDIR "$AIS_SESSION_DIR/tmp"; else env_set TMPDIR /tmp; fi
  mkdir -p "$HOME/.cache/ai-sandbox/cache/npm" "$HOME/.cache/ai-sandbox/cache/pip"
  env_set XDG_CACHE_HOME "$HOME/.cache/ai-sandbox/cache"
  env_set npm_config_cache "$HOME/.cache/ai-sandbox/cache/npm"
  env_set PIP_CACHE_DIR "$HOME/.cache/ai-sandbox/cache/pip"
  env_set AI_SANDBOX 1
  env_set AI_SANDBOX_HARNESS "$AI_SANDBOX_HARNESS"
  env_set AI_SANDBOX_NET "$AI_SANDBOX_NET"

  # Proxy: fixed bridge port on Linux; on macOS net_start adds it once the port is known.
  if [ "$AI_SANDBOX_NET" != open ] && [ "$AIS_PLATFORM" = linux ]; then env_proxy 3128; fi

  if [ "$AI_SANDBOX_SSH_AGENT" = 1 ]; then
    [ -n "${SSH_AUTH_SOCK-}" ] && [ -S "$SSH_AUTH_SOCK" ] ||
      ais_die 125 "AI_SANDBOX_SSH_AGENT=1 but SSH_AUTH_SOCK is not set to a socket on the host"
    if [ "$AIS_PLATFORM" = linux ]; then
      env_set SSH_AUTH_SOCK /tmp/.ai-sandbox/ssh-agent.sock
    else
      env_set SSH_AUTH_SOCK "$(realpath "$SSH_AUTH_SOCK")"
    fi
  fi

  if [ -n "$PROFILE_STATE_ENV" ] && [ "$AI_SANDBOX_STATE" = isolated ]; then
    env_set "$PROFILE_STATE_ENV" "$AIS_STATE_DIR"
  fi
  for e in ${PROFILE_ENV[@]+"${PROFILE_ENV[@]}"}; do env_set "${e%%=*}" "${e#*=}"; done
  env_secrets
}

env_print() {
  local i=0
  while [ "$i" -lt "${#AIS_ENV_K[@]}" ]; do
    if [ "${AIS_ENV_SECRET[$i]}" = 1 ]; then
      printf '%s=<redacted>\n' "${AIS_ENV_K[$i]}"
    else
      printf '%s=%s\n' "${AIS_ENV_K[$i]}" "${AIS_ENV_V[$i]}"
    fi
    i=$((i + 1))
  done
}

# In the child's subshell only.
env_apply() {
  local v i=0 keep=
  for v in $(compgen -e); do export -n "$v" 2>/dev/null || true; done
  while [ "$i" -lt "${#AIS_ENV_K[@]}" ]; do
    export "${AIS_ENV_K[$i]}=${AIS_ENV_V[$i]}"
    keep="$keep ${AIS_ENV_K[$i]}"
    i=$((i + 1))
  done
  export _AIS_KEEP_ENV="$keep"
}
