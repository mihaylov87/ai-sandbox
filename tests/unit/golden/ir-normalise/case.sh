# Step 2-3: ~ expansion (config and CLI), symlinks resolved, trailing / stripped,
# trailing ? optional, missing optional rw and missing ro skipped.
setup() {
  touch "$HOME/.gitconfig" "$HOME/notes"
  mkdir -p "$HOME/dotfiles" "$HOME/src/lib2" "$WORK/secret"
  ln -s dotfiles "$HOME/dotlink"
  cat >>"$CONF/config" <<'CONF'
AI_SANDBOX_RO_PATHS=~/.gitconfig:~/dotlink/:~/missing-ro
AI_SANDBOX_RW_PATHS=~/src/shared-lib?:~/src/lib2/?
CONF
}
CASE_ARGS=(--hide "$HOME/src/app/secret/" --ro '~/notes')
