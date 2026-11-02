# The worked example from spec §5: user jordan, work dir ~/src/app, harness claude,
# ~/.gitconfig and ~/.ssh/known_hosts listed RO, isolated state dir rw.
setup() {
  mkdir -p "$HOME/.ssh" "$WORK/.git/hooks" "$HOME/src/other" "$SYS/mnt/data"
  touch "$HOME/.gitconfig" "$HOME/.ssh/known_hosts" "$HOME/.ssh/id_ed25519" "$WORK/main.py" \
    "$WORK/.git/config" "$WORK/.git/hooks/pre-commit"
  cat >"$INSTALL/profiles/claude.sh" <<'PROF'
PROFILE_STATE_ENV=CLAUDE_CONFIG_DIR
PROFILE_STATE_DIR="$HOME/.claude"
PROFILE_RW=(".")
PROF
  cat >>"$CONF/config" <<'CONF'
AI_SANDBOX_HARNESS=claude
AI_SANDBOX_RO_PATHS=~/.gitconfig:~/.ssh/known_hosts
CONF
}
