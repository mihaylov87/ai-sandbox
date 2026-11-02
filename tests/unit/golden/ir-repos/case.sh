# Step 6: repos found to depth 3 under each rw dir lock .git/hooks, .git/config, .git/info;
# missing ones are skipped; a repo dir at depth 4 is not searched.
setup() {
  mkdir -p "$WORK/.git/hooks" "$WORK/.git/info" "$WORK/a/b/c/.git/hooks" "$WORK/a/b/c/.git/info" \
    "$WORK/a/b/c/d/.git/hooks" "$HOME/src/lib/.git/hooks"
  touch "$WORK/.git/config" "$WORK/a/b/c/.git/config" "$WORK/a/b/c/d/.git/config"
  printf 'AI_SANDBOX_RW_PATHS=~/src/lib\n' >>"$CONF/config"
}
