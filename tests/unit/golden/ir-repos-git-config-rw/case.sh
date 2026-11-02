# AI_SANDBOX_GIT_CONFIG=rw: .git/config is not locked (spec §12).
setup() {
  mkdir -p "$WORK/.git/hooks" "$WORK/.git/info"
  touch "$WORK/.git/config"
  printf 'AI_SANDBOX_GIT_CONFIG=rw\n' >>"$CONF/config"
}
