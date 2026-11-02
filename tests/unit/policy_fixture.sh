# Shared fixture for policy tests (golden and error cases). Not a test file.
#
# Fixture: $ROOT/sys stands in for / (via _AIS_SYSROOT), HOME=$ROOT/sys/home/jordan,
# work dir ~/src/app, install dir ~/.local/share/ai-sandbox (with an empty copilot profile),
# session dir $ROOT/session.

golden_fixture() {
  mk_tmp
  ROOT=$TMP
  SYS=$ROOT/sys
  export HOME="$SYS/home/jordan"
  WORK=$HOME/src/app
  CONF=$HOME/.config/ai-sandbox
  INSTALL=$HOME/.local/share/ai-sandbox
  mkdir -p "$SYS/mnt" "$SYS/media" "$SYS/run/user/$(id -u)" "$WORK" "$INSTALL" "$CONF/projects" \
    "$ROOT/session/tmp"
  chmod 0700 "$CONF"
  mkdir -p "$INSTALL/profiles"
  : >"$INSTALL/profiles/copilot.sh" # empty profile: adds nothing
  printf 'AI_SANDBOX_WORK_DIR=~/src/app\n' >"$CONF/config"
  chmod 0600 "$CONF/config"
  export _AIS_SYSROOT=$SYS AIS_INSTALL_DIR=$INSTALL AIS_PLATFORM=linux AIS_SESSION_DIR=$ROOT/session
  local v
  for v in $(compgen -v AI_SANDBOX_); do unset "$v"; done
}

# Build the IR for the current fixture; prints it with placeholders.
build_ir() {
  local uid
  uid=$(id -u)
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/policy.sh"; shift
    cfg_load "$@"
    cfg_load_profile
    policy_build /dev/stdout
  ' _ "$REPO_ROOT" "$@"
  OUT=$(printf '%s' "$OUT" | sed -e "s|$ROOT|@ROOT@|g" -e "s|/$uid\$|/@UID@|" -e "s|tmux-$uid\$|tmux-@UID@|")
  ERR=$(printf '%s' "$ERR" | sed -e "s|$ROOT|@ROOT@|g")
}

