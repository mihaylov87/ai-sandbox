# Step 4: locked > hidden > rw > ro on the same path; overridden user entries warn,
# overridden defaults and same-class repeats do not.
setup() {
  mkdir -p "$WORK/docs"
  cat >>"$CONF/config" <<'CONF'
AI_SANDBOX_RO_PATHS=~:~/src/app
AI_SANDBOX_RW_PATHS=~/src/app
AI_SANDBOX_HIDE_PATHS=~/.cache/ai-sandbox
AI_SANDBOX_LOCKED_PATHS=~/src/app/docs
CONF
}
CASE_ARGS=(--rw "$HOME/src/app/docs")
