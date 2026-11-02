# Step 7: hidden entries under a locked entry are repeated after phase B.
setup() {
  mkdir -p "$WORK/vendor/keys" "$WORK/other"
  cat >>"$CONF/config" <<'CONF'
AI_SANDBOX_LOCKED_PATHS=~/src/app/vendor
AI_SANDBOX_HIDE_PATHS=~/src/app/vendor/keys:~/src/app/other
CONF
}
