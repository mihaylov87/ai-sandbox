# lib/config.sh — load and validate configuration, parse the CLI (spec §6).
# Bash 3.2 compatible. Sourced by the launcher; defines functions only.

AIS_CONFIG_DIR_REL=".config/ai-sandbox"

ais_warn() { printf 'ai-sandbox: warning: %s\n' "$*" >&2; }
ais_die() { # code message...
  local code=$1
  shift
  printf 'ai-sandbox: error: %s\n' "$*" >&2
  exit "$code"
}

# Quote a word for display: bare when it is plainly safe, otherwise in single quotes.
ais_shquote() {
  case "$1" in
    *[!A-Za-z0-9_./:=@%+,-]* | '') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Resolve an existing path through symlinks; print it unchanged if it is missing.
# Strips trailing slashes (keeps "/").
ais_resolve_maybe() {
  local p=$1
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  if [ -e "$p" ]; then
    realpath "$p"
  else
    printf '%s\n' "$p"
  fi
}

# ---------------------------------------------------------------------------
# Variables (spec §6 table)

CFG_SCALARS="WORK_DIR HARNESS COMMAND RW_PATHS RO_PATHS HIDE_PATHS LOCKED_PATHS STATE NET
NET_ALLOW NET_PRESETS HOST_PORTS UPSTREAM_PROXY SSH_AGENT DOCKER PASS_ENV GIT_CONFIG
EXIT_REPORT LOCALHOST DNS KEYCHAIN LIMITS ACCEPT TEST_RO_DIR TEST_RW_DIR"
CFG_ALIASES="EXTRA_RW EXTRA_RO"
CFG_PRESETS="npm pypi github crates go"
CFG_GATES="G1 G2 G3 G4 G5 G6 G7 G8 G9 G10"

# Is $1 (full AI_SANDBOX_* name) a variable we accept?
cfg_is_known() {
  local short=${1#AI_SANDBOX_} k
  case "$short" in
    SECRET_CMD_*)
      case "${short#SECRET_CMD_}" in
        '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
      esac
      return 0
      ;;
  esac
  for k in $CFG_SCALARS $CFG_ALIASES; do
    [ "$k" = "$short" ] && return 0
  done
  return 1
}

cfg_set_defaults() {
  local k
  for k in $CFG_SCALARS; do eval "AI_SANDBOX_$k="; done
  AI_SANDBOX_HARNESS=copilot
  AI_SANDBOX_STATE=isolated
  AI_SANDBOX_NET=allowlist
  AI_SANDBOX_SSH_AGENT=0
  AI_SANDBOX_DOCKER=0
  AI_SANDBOX_GIT_CONFIG=locked
  AI_SANDBOX_EXIT_REPORT=1
  AI_SANDBOX_LOCALHOST=isolated
  AI_SANDBOX_DNS= # empty: decided by gate G3 (spec §6, §15)
  AI_SANDBOX_KEYCHAIN=deny
}

cfg_unset_all() {
  local v
  for v in $(compgen -v AI_SANDBOX_); do unset "$v"; done
}

# ---------------------------------------------------------------------------
# Config files

# Owner and permission checks: owned by us, not group- or world-writable.
cfg_check_file() {
  local f=$1
  [ -n "$(find -H "$f" -prune -user "$(id -u)" 2>/dev/null)" ] ||
    ais_die 125 "config file $f is not owned by you"
  [ -z "$(find -H "$f" -prune \( -perm -020 -o -perm -002 \) 2>/dev/null)" ] ||
    ais_die 125 "config file $f is group- or world-writable"
}

# Source a config file in a subshell with set -u and print its AI_SANDBOX_*
# assignments as NAME=<shell-quoted value> lines (or "ARRAY NAME").
cfg_read_file() {
  local f=$1 out
  cfg_check_file "$f"
  out=$(
    cfg_unset_all
    set -u
    . "$f" >&2 || exit 1
    for v in $(compgen -v AI_SANDBOX_); do
      case "$(declare -p "$v" 2>/dev/null)" in
        "declare -"[aA]*) printf 'ARRAY %s\n' "$v" ;;
        *) printf '%s=%q\n' "$v" "${!v}" ;;
      esac
    done
  ) || ais_die 125 "error while reading config file $f"
  printf '%s\n' "$out"
}

# Apply NAME=<quoted> lines (from cfg_read_file or the env snapshot).
cfg_apply_lines() { # lines source-description
  local lines=$1 src=$2 line name val
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "ARRAY "*) ais_die 125 "${line#ARRAY } in $src: arrays are not supported, use a ':' or ' ' separated string" ;;
    esac
    name=${line%%=*}
    cfg_is_known "$name" || ais_die 125 "unknown variable $name in $src"
    case "$name" in
      AI_SANDBOX_EXTRA_RW | AI_SANDBOX_EXTRA_RO)
        eval "val=${line#*=}"
        cfg_alias_paths "$name" "$val" "$src"
        ;;
      *) eval "$line" ;;
    esac
  done <<EOF
$lines
EOF
}

# v1 aliases: AI_SANDBOX_EXTRA_RW / _RO behave like --rw / --ro (spec §6).
cfg_alias_paths() { # name value source
  local name=$1 val=$2 src=$3 p rest
  ais_warn "$name (in $src) is deprecated; use AI_SANDBOX_${name#AI_SANDBOX_EXTRA_}_PATHS or --${name#AI_SANDBOX_EXTRA_}"
  rest=$val
  while [ -n "$rest" ]; do
    p=${rest%%:*}
    if [ "$p" = "$rest" ]; then rest=; else rest=${rest#*:}; fi
    [ -n "$p" ] || continue
    case "$name" in
      AI_SANDBOX_EXTRA_RW) CLI_RW[${#CLI_RW[@]}]=$p ;;
      *) CLI_RO[${#CLI_RO[@]}]=$p ;;
    esac
  done
}

# Note: ais_die inside $(...) only ends the subshell, so every command
# substitution that can die is followed by "|| exit $?".
cfg_load_file() { # file
  local lines
  lines=$(cfg_read_file "$1") || exit $?
  cfg_apply_lines "$lines" "$1"
}

# Print the resolved AI_SANDBOX_WORK_DIR a config file sets, or nothing.
cfg_file_work_dir() {
  local lines line
  lines=$(cfg_read_file "$1") || exit $?
  while IFS= read -r line; do
    case "$line" in
      AI_SANDBOX_WORK_DIR=*)
        eval "line=${line#*=}"
        [ -n "$line" ] && ais_resolve_maybe "$line"
        return 0
        ;;
    esac
  done <<EOF
$lines
EOF
}

# ---------------------------------------------------------------------------
# Validation

cfg_check_enum() { # var allowed...
  local var=$1 val a
  shift
  eval "val=\${$var}"
  for a in "$@"; do [ "$val" = "$a" ] && return 0; done
  ais_die 125 "$var='$val' is invalid; expected one of: $*"
}

cfg_validate() {
  local p g ok n
  [ -n "$AI_SANDBOX_WORK_DIR" ] || ais_die 125 "AI_SANDBOX_WORK_DIR is not set (config file, environment or --work-dir)"
  cfg_check_enum AI_SANDBOX_STATE isolated shared
  cfg_check_enum AI_SANDBOX_NET allowlist none open
  cfg_check_enum AI_SANDBOX_SSH_AGENT 0 1
  cfg_check_enum AI_SANDBOX_DOCKER 0 1
  cfg_check_enum AI_SANDBOX_GIT_CONFIG locked rw
  cfg_check_enum AI_SANDBOX_EXIT_REPORT 0 1
  cfg_check_enum AI_SANDBOX_LOCALHOST isolated shared
  cfg_check_enum AI_SANDBOX_DNS '' deny allow
  cfg_check_enum AI_SANDBOX_KEYCHAIN deny allow

  case "$AI_SANDBOX_HARNESS" in
    '' | *[!a-z0-9_-]* | [_-]*) ais_die 125 "AI_SANDBOX_HARNESS='$AI_SANDBOX_HARNESS' is not a valid profile name" ;;
  esac

  for p in $AI_SANDBOX_HOST_PORTS; do
    case "$p" in
      '' | *[!0-9]* | 0*) ok=0 ;;
      *) if [ "${#p}" -le 5 ] && [ "$p" -le 65535 ]; then ok=1; else ok=0; fi ;;
    esac
    [ "$ok" = 1 ] || ais_die 125 "AI_SANDBOX_HOST_PORTS: '$p' is not a port number (1-65535)"
  done

  for p in $AI_SANDBOX_NET_PRESETS; do
    case " $CFG_PRESETS " in *" $p "*) ;; *) ais_die 125 "AI_SANDBOX_NET_PRESETS: unknown preset '$p'; known: $CFG_PRESETS" ;; esac
  done

  for g in $AI_SANDBOX_ACCEPT; do
    case " $CFG_GATES " in *" $g "*) ;; *) ais_die 125 "AI_SANDBOX_ACCEPT: unknown gate '$g'; known: G1-G10" ;; esac
  done

  for n in $AI_SANDBOX_PASS_ENV; do
    case "$n" in
      [A-Za-z_]*) case "$n" in *[!A-Za-z0-9_]*) ais_die 125 "AI_SANDBOX_PASS_ENV: '$n' is not a variable name" ;; esac ;;
      *) ais_die 125 "AI_SANDBOX_PASS_ENV: '$n' is not a variable name" ;;
    esac
  done

  case "$AI_SANDBOX_UPSTREAM_PROXY" in
    '' | http://?* | https://?*) ;;
    *) ais_die 125 "AI_SANDBOX_UPSTREAM_PROXY='$AI_SANDBOX_UPSTREAM_PROXY' must be an http:// or https:// URL" ;;
  esac
}

# ---------------------------------------------------------------------------
# CLI (spec §6)

cli_usage() {
  cat <<'EOF'
ai-sandbox [options] [--] [command [args...]]

  -w, --work-dir DIR        override AI_SANDBOX_WORK_DIR
  -H, --harness NAME        copilot | claude | generic
  -p, --project NAME        load projects/NAME.conf
      --rw PATH             add RW path (repeatable)
      --ro PATH             add RO path (repeatable)
      --hide PATH           add hidden path (repeatable)
      --net MODE            allowlist | none | open
      --allow-host H[:P]    add egress host (repeatable)
      --host-port PORT      expose host localhost port (repeatable)
      --ssh-agent           forward the SSH agent
      --shell [args]        sandboxed bash instead of the harness
      --check               run the self-test matrix and record gate results
      --print-policy [--ir] print compiled policy and exit
      --dry-run             print policy, environment and command, then exit
      --keep-session        keep the session dir
      --net-log             print denied hosts at exit
  -v, --verbose
  -h, --help
EOF
}

_cli_mode() {
  if [ "$CLI_MODE" != run ] && [ "$CLI_MODE" != "$1" ]; then
    ais_die 125 "--$CLI_MODE and --$1 cannot be combined"
  fi
  CLI_MODE=$1
}

cli_parse() {
  CLI_MODE=run CLI_IR=0 CLI_KEEP_SESSION=0 CLI_NET_LOG=0 CLI_VERBOSE=0
  CLI_WORK_DIR= CLI_HARNESS= CLI_PROJECT= CLI_NET= CLI_SSH_AGENT=
  CLI_RW=() CLI_RO=() CLI_HIDE=() CLI_ALLOW_HOST=() CLI_HOST_PORT=()
  CLI_CMD=() CLI_CMD_SET=0
  local opt val takes
  while [ "$#" -gt 0 ]; do
    opt=$1 val=
    case "$opt" in
      --*=*) val=${opt#*=} opt=${opt%%=*}; shift; set -- "$opt" "$val" "$@" ;;
    esac
    case "$opt" in
      -w | --work-dir | -H | --harness | -p | --project | --rw | --ro | --hide | --net | --allow-host | --host-port) takes=1 ;;
      *) takes=0 ;;
    esac
    if [ "$takes" = 1 ]; then
      [ "$#" -ge 2 ] || ais_die 125 "option $opt needs a value"
      val=$2
      shift 2
    fi
    case "$opt" in
      -w | --work-dir) CLI_WORK_DIR=$val ;;
      -H | --harness) CLI_HARNESS=$val ;;
      -p | --project) CLI_PROJECT=$val ;;
      --rw) CLI_RW[${#CLI_RW[@]}]=$val ;;
      --ro) CLI_RO[${#CLI_RO[@]}]=$val ;;
      --hide) CLI_HIDE[${#CLI_HIDE[@]}]=$val ;;
      --net) CLI_NET=$val ;;
      --allow-host) CLI_ALLOW_HOST[${#CLI_ALLOW_HOST[@]}]=$val ;;
      --host-port) CLI_HOST_PORT[${#CLI_HOST_PORT[@]}]=$val ;;
      --ssh-agent) CLI_SSH_AGENT=1; shift ;;
      --check) _cli_mode check; shift ;;
      --print-policy) _cli_mode print-policy; shift ;;
      --ir) CLI_IR=1; shift ;;
      --dry-run) _cli_mode dry-run; shift ;;
      --keep-session) CLI_KEEP_SESSION=1; shift ;;
      --net-log) CLI_NET_LOG=1; shift ;;
      -v | --verbose) CLI_VERBOSE=1; shift ;;
      -h | --help) cli_usage; exit 0 ;;
      --shell)
        _cli_mode shell
        shift
        CLI_CMD=("$@")
        break
        ;;
      --)
        shift
        CLI_CMD=("$@") CLI_CMD_SET=1
        break
        ;;
      -*) ais_die 125 "unknown option $opt (see --help)" ;;
      *)
        CLI_CMD=("$@") CLI_CMD_SET=1
        break
        ;;
    esac
  done
  if [ "$CLI_IR" = 1 ] && [ "$CLI_MODE" != print-policy ]; then
    ais_die 125 "--ir is only valid with --print-policy"
  fi
}

_cfg_append_words() { # var words...
  local var=$1 cur
  shift
  eval "cur=\${$var}"
  for w in "$@"; do
    if [ -n "$cur" ]; then cur="$cur $w"; else cur=$w; fi
  done
  eval "$var=\$cur"
}

cfg_apply_cli() {
  [ -n "$CLI_WORK_DIR" ] && AI_SANDBOX_WORK_DIR=$CLI_WORK_DIR
  [ -n "$CLI_HARNESS" ] && AI_SANDBOX_HARNESS=$CLI_HARNESS
  [ -n "$CLI_NET" ] && AI_SANDBOX_NET=$CLI_NET
  [ -n "$CLI_SSH_AGENT" ] && AI_SANDBOX_SSH_AGENT=1
  _cfg_append_words AI_SANDBOX_NET_ALLOW ${CLI_ALLOW_HOST[@]+"${CLI_ALLOW_HOST[@]}"}
  _cfg_append_words AI_SANDBOX_HOST_PORTS ${CLI_HOST_PORT[@]+"${CLI_HOST_PORT[@]}"}
  return 0
}

# ---------------------------------------------------------------------------
# Entry point: all sources in order (spec §6), except the profile (lib/profile).

cfg_load() {
  local env_lines env_work conf_dir global candidate f pw
  # 5. Snapshot the calling environment before defaults overwrite it.
  env_lines=$(for v in $(compgen -v AI_SANDBOX_); do printf '%s=%q\n' "$v" "${!v}"; done)
  env_work=${AI_SANDBOX_WORK_DIR-}

  cli_parse "$@"
  cfg_unset_all
  cfg_set_defaults

  conf_dir="$HOME/$AIS_CONFIG_DIR_REL"
  global="$conf_dir/config"
  CFG_PROJECT_FILE=

  # 2. Global config.
  [ -e "$global" ] && cfg_load_file "$global"

  # 3. Project config: by name, or the first whose work dir matches.
  if [ -n "$CLI_PROJECT" ]; then
    case "$CLI_PROJECT" in
      '' | */* | .*) ais_die 125 "invalid project name '$CLI_PROJECT'" ;;
    esac
    CFG_PROJECT_FILE="$conf_dir/projects/$CLI_PROJECT.conf"
    [ -f "$CFG_PROJECT_FILE" ] || ais_die 125 "project '$CLI_PROJECT' not found: $CFG_PROJECT_FILE"
  else
    candidate=${CLI_WORK_DIR:-${env_work:-$AI_SANDBOX_WORK_DIR}}
    if [ -n "$candidate" ]; then
      candidate=$(ais_resolve_maybe "$candidate")
      for f in "$conf_dir"/projects/*.conf; do
        [ -f "$f" ] || continue
        pw=$(cfg_file_work_dir "$f") || exit $?
        if [ -n "$pw" ] && [ "$pw" = "$candidate" ]; then
          CFG_PROJECT_FILE=$f
          break
        fi
      done
    fi
  fi
  [ -n "$CFG_PROJECT_FILE" ] && cfg_load_file "$CFG_PROJECT_FILE"

  # 5. Environment.
  cfg_apply_lines "$env_lines" "the environment"
  # 6. CLI flags.
  cfg_apply_cli
  cfg_validate
}

# ---------------------------------------------------------------------------
# Harness profile (spec §11): one Bash file in $AIS_INSTALL_DIR/profiles/.
# Sets the PROFILE_* variables and AIS_STATE_DIR (effective state dir).

cfg_load_profile() {
  local f="${AIS_INSTALL_DIR:?AIS_INSTALL_DIR not set}/profiles/$AI_SANDBOX_HARNESS.sh"
  [ -f "$f" ] || ais_die 125 "harness profile '$AI_SANDBOX_HARNESS' not found: $f"
  PROFILE_COMMAND=() PROFILE_STATE_ENV= PROFILE_STATE_DIR= PROFILE_RW=() PROFILE_RO=()
  PROFILE_LOCKED=() PROFILE_SECRETS=() PROFILE_ENV=() PROFILE_PASS_ENV=() PROFILE_NET_ALLOW=()
  PROFILE_PATH_ADD=() PROFILE_ALLOW_USERNS=0
  . "$f" || ais_die 125 "error while loading harness profile $f"
  if [ "$AI_SANDBOX_STATE" = shared ]; then
    AIS_STATE_DIR=$PROFILE_STATE_DIR
  else
    AIS_STATE_DIR="$HOME/.local/state/ai-sandbox/$AI_SANDBOX_HARNESS"
  fi
}
