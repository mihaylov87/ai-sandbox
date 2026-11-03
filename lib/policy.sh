# lib/policy.sh — paths -> IR (spec §5). Bash 3.2 compatible.
#
# Inputs: AI_SANDBOX_* (lib/config.sh), CLI_RW/CLI_RO/CLI_HIDE, PROFILE_RW/RO/LOCKED and
# AIS_STATE_DIR (cfg_load_profile), AIS_PLATFORM (linux|macos), AIS_INSTALL_DIR,
# AIS_SESSION_DIR, HOME. _AIS_SYSROOT prefixes the system default paths (tests only).
# Output: policy_build FILE writes the IR; POLICY_MISSING lists skipped missing paths
# as "<class> <path>"; POLICY_WORK_DIR is the resolved work dir.

_AIS_TAB=$(printf '\t')
_AIS_NL='
'

# Hot paths avoid $(...) subshells and forks: these set _PRIO, _DEPTH, _REAL.
_policy_prio() {
  case "$1" in
    ro) _PRIO=1 ;;
    rw) _PRIO=2 ;;
    hidden) _PRIO=3 ;;
    locked) _PRIO=4 ;;
  esac
}

# Resolve symlinks of an existing path into _REAL. Directories are resolved with the
# cd -P builtin (no fork); a file is resolved through its directory, and only a file that
# is itself a symlink costs a realpath call.
_policy_realpath() {
  local p=$1 here=$PWD d b
  if [ -d "$p" ]; then
    cd -P -- "$p" 2>/dev/null || return 1
    _REAL=$PWD
  else
    d=${p%/*} b=${p##*/}
    [ -n "$d" ] || d=/
    cd -P -- "$d" 2>/dev/null || return 1
    if [ -L "$b" ]; then
      _REAL=$(realpath "$b") || { cd -- "$here"; return 1; }
    elif [ "$PWD" = / ]; then
      _REAL=/$b
    else
      _REAL=$PWD/$b
    fi
  fi
  cd -- "$here"
}

_policy_is_user_src() {
  case "$1" in default | repo | profile:*) return 1 ;; esac
  return 0
}

_policy_check_chars() { # path source
  case "$1" in
    *"$_AIS_TAB"* | *"$_AIS_NL"* | *'"'*)
      ais_die 125 "path from $2 contains a tab, newline or '\"': $1" ;;
  esac
}

# Steps 2-4 for one entry: normalise, existence, duplicates.
_policy_add() { # class source raw-path
  local class=$1 src=$2 p=$3 opt=0 kind i newprio oldprio
  case "$p" in *\?) p=${p%\?} opt=1 ;; esac
  [ -n "$p" ] || ais_die 125 "empty path in $src"
  _policy_check_chars "$p" "$src"
  case "$p" in
    "~") p=$HOME ;;
    "~/"*) p="$HOME/${p#??}" ;;
  esac
  case "$p" in
    /*) ;;
    *) ais_die 125 "path '$3' from $src is not absolute" ;;
  esac
  if [ -e "$p" ] && _policy_realpath "$p"; then
    p=$_REAL
    _policy_check_chars "$p" "$src"
  else
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
    if [ "$class" = rw ] && [ "$opt" = 0 ]; then
      ais_die 125 "rw path $p (from $src) does not exist; append '?' to make it optional"
    fi
    POLICY_MISSING[${#POLICY_MISSING[@]}]="$class $p"
    return 0
  fi
  if [ -d "$p" ]; then kind=dir; else kind=file; fi

  _policy_prio "$class"
  newprio=$_PRIO
  i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    if [ "${K_PATH[$i]}" = "$p" ]; then
      _policy_prio "${K_CLASS[$i]}"
      oldprio=$_PRIO
      if [ "$newprio" -gt "$oldprio" ]; then
        _policy_is_user_src "${K_SRC[$i]}" &&
          ais_warn "$p from ${K_SRC[$i]} (${K_CLASS[$i]}) is overridden by $class from $src"
        K_CLASS[$i]=$class K_SRC[$i]=$src
      elif [ "$newprio" -lt "$oldprio" ]; then
        _policy_is_user_src "$src" &&
          ais_warn "$p from $src ($class) is overridden by ${K_CLASS[$i]} from ${K_SRC[$i]}"
      fi
      return 0
    fi
    i=$((i + 1))
  done
  i=${#K_PATH[@]}
  K_PATH[$i]=$p K_CLASS[$i]=$class K_SRC[$i]=$src K_KIND[$i]=$kind
}

_policy_add_list() { # class source colon-list
  local class=$1 src=$2 rest=$3 p
  [ -n "$rest" ] || return 0
  while :; do
    p=${rest%%:*}
    _policy_add "$class" "$src" "$p"
    [ "$p" = "$rest" ] && break
    rest=${rest#*:}
  done
}

_policy_add_array() { # class source items...
  local class=$1 src=$2 p
  shift 2
  for p in "$@"; do _policy_add "$class" "$src" "$p"; done
}

# Profile paths: PROFILE_LOCKED always, PROFILE_RW when relative, are under the state dir.
_policy_state_path() { # path
  case "$1" in
    /* | "~" | "~/"*) printf '%s\n' "$1" ;;
    .) printf '%s\n' "$AIS_STATE_DIR" ;;
    *) printf '%s/%s\n' "$AIS_STATE_DIR" "${1#./}" ;;
  esac
}

_policy_needs_state_dir() {
  local p
  [ "${#PROFILE_LOCKED[@]}" -gt 0 ] && return 0
  for p in ${PROFILE_RW[@]+"${PROFILE_RW[@]}"}; do
    case "$p" in /* | "~" | "~/"*) ;; *) return 0 ;; esac
  done
  return 1
}

# Step 1: collect, in a fixed order (defaults, config, profile, CLI).
_policy_collect() {
  local s=${_AIS_SYSROOT-} uid p
  uid=$(id -u)
  case "$AIS_PLATFORM" in
    linux)
      _policy_add_array hidden default "$s/home" "$HOME" "$s/mnt" "$s/media" "$s/run/user/$uid"
      ;;
    macos)
      _policy_add_array hidden default "$s/Users" "$HOME" "$s/Volumes" "$s/private/tmp/tmux-$uid"
      ;;
    *) ais_die 126 "unsupported platform '$AIS_PLATFORM'" ;;
  esac

  _policy_add rw AI_SANDBOX_WORK_DIR "$AI_SANDBOX_WORK_DIR"
  POLICY_WORK_DIR=${K_PATH[$((${#K_PATH[@]} - 1))]}
  if [ "$AIS_PLATFORM" = macos ] && [ -n "${AIS_SESSION_DIR-}" ]; then
    _policy_add rw default "$AIS_SESSION_DIR/tmp"
  fi
  mkdir -p "$HOME/.cache/ai-sandbox" && chmod 0700 "$HOME/.cache/ai-sandbox"
  _policy_add rw default "$HOME/.cache/ai-sandbox"

  _policy_add locked default "$AIS_INSTALL_DIR"
  _policy_add locked default "$HOME/$AIS_CONFIG_DIR_REL/config"
  _policy_add locked default "$HOME/$AIS_CONFIG_DIR_REL/projects"

  _policy_add_list rw AI_SANDBOX_RW_PATHS "$AI_SANDBOX_RW_PATHS"
  _policy_add_list ro AI_SANDBOX_RO_PATHS "$AI_SANDBOX_RO_PATHS"
  _policy_add_list hidden AI_SANDBOX_HIDE_PATHS "$AI_SANDBOX_HIDE_PATHS"
  _policy_add_list locked AI_SANDBOX_LOCKED_PATHS "$AI_SANDBOX_LOCKED_PATHS"

  if _policy_needs_state_dir; then
    [ -n "${AIS_STATE_DIR-}" ] || ais_die 125 "profile $AI_SANDBOX_HARNESS uses state-dir paths but has no state dir (PROFILE_STATE_DIR) for AI_SANDBOX_STATE=$AI_SANDBOX_STATE"
    if [ "$AI_SANDBOX_STATE" = isolated ]; then
      mkdir -p "$AIS_STATE_DIR" && chmod 0700 "$AIS_STATE_DIR"
    fi
  fi
  for p in ${PROFILE_RW[@]+"${PROFILE_RW[@]}"}; do
    _policy_add rw "profile:$AI_SANDBOX_HARNESS" "$(_policy_state_path "$p")"
  done
  _policy_add_array ro "profile:$AI_SANDBOX_HARNESS" ${PROFILE_RO[@]+"${PROFILE_RO[@]}"}
  for p in ${PROFILE_LOCKED[@]+"${PROFILE_LOCKED[@]}"}; do
    _policy_add locked "profile:$AI_SANDBOX_HARNESS" "$AIS_STATE_DIR/$p"
  done

  _policy_add_array rw --rw ${CLI_RW[@]+"${CLI_RW[@]}"}
  _policy_add_array ro --ro ${CLI_RO[@]+"${CLI_RO[@]}"}
  _policy_add_array hidden --hide ${CLI_HIDE[@]+"${CLI_HIDE[@]}"}
}

# Step 5: no rw path below a locked path.
_policy_validate() {
  local i j r l
  i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    if [ "${K_CLASS[$i]}" = rw ]; then
      r=${K_PATH[$i]}
      j=0
      while [ "$j" -lt "${#K_PATH[@]}" ]; do
        if [ "${K_CLASS[$j]}" = locked ]; then
          l=${K_PATH[$j]}
          case "$r" in "$l"/*) ais_die 125 "rw path $r (from ${K_SRC[$i]}) is under locked path $l" ;; esac
        fi
        j=$((j + 1))
      done
    fi
    i=$((i + 1))
  done
}

# Step 6: Git repos (repo dir at depth <= 3) under each rw dir lock their internals.
_policy_repos() {
  local rw_dirs=() i g d
  i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    [ "${K_CLASS[$i]}" = rw ] && [ "${K_KIND[$i]}" = dir ] && rw_dirs[${#rw_dirs[@]}]=${K_PATH[$i]}
    i=$((i + 1))
  done
  for d in ${rw_dirs[@]+"${rw_dirs[@]}"}; do
    while IFS= read -r -d '' g; do
      _policy_add locked repo "$g/hooks"
      [ "$AI_SANDBOX_GIT_CONFIG" = rw ] || _policy_add locked repo "$g/config"
      _policy_add locked repo "$g/info"
    done < <(find "$d" -maxdepth 4 -name .git -type d -prune -print0 2>/dev/null)
  done
}

_policy_depth() {
  local slashes
  if [ "$1" = / ]; then _DEPTH=0; return; fi
  slashes=${1//[!\/]/}
  _DEPTH=${#slashes}
}

# Steps 7-8: order (phases A, B, C) and emit.
_policy_emit() { # file
  local i p c a b phase_c
  a= b= phase_c=
  i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    p=${K_PATH[$i]} c=${K_CLASS[$i]}
    if [ "$c" = locked ]; then
      _policy_depth "$p"
      b="$b$_DEPTH$_AIS_TAB$p$_AIS_TAB${K_KIND[$i]}$_AIS_NL"
    else
      _policy_depth "$p"
      _policy_prio "$c"
      a="$a$_DEPTH$_AIS_TAB$_PRIO$_AIS_TAB$p$_AIS_TAB$c$_AIS_TAB${K_KIND[$i]}$_AIS_NL"
    fi
    i=$((i + 1))
  done
  {
    printf '# ai-sandbox-ir 1\n'
    printf '# platform=%s harness=%s work=%s\n' "$AIS_PLATFORM" "$AI_SANDBOX_HARNESS" "$POLICY_WORK_DIR"
    printf '%s' "$a" | LC_ALL=C sort -t "$_AIS_TAB" -k1,1n -k2,2n -k3,3 |
      awk -F '\t' '{ printf "%s\t%s\t%s\n", $4, $5, $3 }'
    printf '%s' "$b" | LC_ALL=C sort -t "$_AIS_TAB" -k1,1n -k2,2 |
      awk -F '\t' '{ printf "locked\t%s\t%s\n", $3, $2 }'
    # Phase C: hidden entries below a locked entry, again.
    printf '%s' "$a" | LC_ALL=C sort -t "$_AIS_TAB" -k1,1n -k3,3 |
      while IFS="$_AIS_TAB" read -r _ _ p c k; do
        [ "$c" = hidden ] || continue
        i=0
        while [ "$i" -lt "${#K_PATH[@]}" ]; do
          if [ "${K_CLASS[$i]}" = locked ]; then
            case "$p" in "${K_PATH[$i]}"/*) printf 'hidden\t%s\t%s\n' "$k" "$p"; break ;; esac
          fi
          i=$((i + 1))
        done
      done
  } >"$1"
}

policy_build() { # output-file
  K_PATH=() K_CLASS=() K_SRC=() K_KIND=() POLICY_MISSING=() POLICY_WORK_DIR=
  _policy_collect
  _policy_validate
  _policy_repos
  _policy_validate
  _policy_emit "$1"
}

# Class of a path under the built policy (spec §5): the longest matching prefix decides,
# except that a locked prefix wins over deeper ro/rw entries (phase B is mounted after
# phase A), while hidden entries under a locked one stay hidden (phase C). Paths that
# match nothing are under the read-only base.
policy_class_of() { # resolved-path
  local p=$1 i k best= bestlen=-1 locked=0
  i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    k=${K_PATH[$i]}
    case "$p" in
      "$k" | "$k"/*)
        [ "${K_CLASS[$i]}" = locked ] && locked=1
        if [ "${#k}" -gt "$bestlen" ]; then best=${K_CLASS[$i]} bestlen=${#k}; fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$best" = hidden ]; then echo hidden
  elif [ "$locked" = 1 ]; then echo locked
  else echo "${best:-ro}"
  fi
}

# --print-policy --ir PATH...: which entry decides a path's class (spec §14).
policy_explain() { # path
  local p=$1 i k best=-1 bestlen=-1 lock=-1 locklen=-1 d
  local rest=
  # Resolve the deepest existing ancestor too (macOS: /tmp/new-file is /private/tmp/new-file).
  while [ ! -e "$p" ] && [ "$p" != / ] && [ -n "$p" ]; do
    rest="/${p##*/}$rest"
    p=${p%/*}
    [ -n "$p" ] || p=/
  done
  if [ -e "$p" ]; then p=$(realpath "$p"); fi
  p=${p%/}$rest
  [ -n "$p" ] || p=/
  i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    k=${K_PATH[$i]}
    case "$p" in
      "$k" | "$k"/*)
        if [ "${K_CLASS[$i]}" = locked ] && [ "${#k}" -gt "$locklen" ]; then lock=$i locklen=${#k}; fi
        if [ "${#k}" -gt "$bestlen" ]; then best=$i bestlen=${#k}; fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$best" -ge 0 ] && [ "${K_CLASS[$best]}" != hidden ] && [ "$lock" -ge 0 ]; then best=$lock; fi
  if [ "$best" -lt 0 ]; then
    printf '%s: ro (base)\n' "$1"
  else
    d=${K_CLASS[$best]}
    printf '%s: %s (%s %s, from %s)\n' "$1" "$d" "$d" "${K_PATH[$best]}" "${K_SRC[$best]}"
  fi
}

# The command to run inside (spec §6 "Harness binaries under $HOME"). Symlinks under hidden
# dirs are not recreated inside, so a harness installed in $HOME needs its real install dir
# listed in AI_SANDBOX_RO_PATHS.
#
# policy_command_resolve sets POLICY_CMD to the command word to run and returns 0, or sets
# POLICY_CMD_ERR and returns 1 when the command cannot be reached inside (exit 127):
# - a bare name found on the inside PATH through visible dirs runs unchanged;
# - a bare name the host finds only through a hidden dir (a symlink such as
#   ~/.local/bin/claude) runs by its real path when that is visible, i.e. listed RO;
# - a real path that is hidden, or a name found nowhere, is unreachable.
POLICY_CMD= POLICY_CMD_ERR=
policy_command_resolve() { # command-word
  local c=$1 host dir real inside_path= i=0 d
  POLICY_CMD=$c POLICY_CMD_ERR=
  case "$c" in
    */*) host=$c ;;
    *)
      while [ "$i" -lt "${#AIS_ENV_K[@]}" ]; do
        [ "${AIS_ENV_K[$i]}" = PATH ] && inside_path=${AIS_ENV_V[$i]}
        i=$((i + 1))
      done
      local IFS=:
      for d in $inside_path; do
        if [ -x "$d/$c" ] && _policy_realpath "$d/$c" && [ "$(policy_class_of "$_REAL")" != hidden ] &&
           _policy_realpath "$d" && [ "$(policy_class_of "$_REAL")" != hidden ]; then
          return 0
        fi
      done
      unset IFS
      if ! host=$(command -v -- "$c" 2>/dev/null); then
        POLICY_CMD_ERR="command not found: $c (not on the PATH inside the sandbox: $inside_path)"
        return 1
      fi
      ;;
  esac
  case "$host" in /*) ;; *) return 0 ;; esac # a shell builtin or function: leave it to the shell
  [ -e "$host" ] && _policy_realpath "$host" || return 0 # missing path: the exec reports it
  real=$_REAL
  if [ "$(policy_class_of "$real")" = hidden ]; then
    POLICY_CMD_ERR="$c resolves to $real, which is hidden in the sandbox; list its install dir in AI_SANDBOX_RO_PATHS"
    return 1
  fi
  case "$c" in */*) return 0 ;; esac
  dir=${host%/*}
  _policy_realpath "$dir" || return 0
  if [ "$(policy_class_of "$_REAL")" = hidden ]; then
    # Found only through a hidden dir, but the real file is visible: run it by that path.
    POLICY_CMD=$real
  fi
  return 0
}
