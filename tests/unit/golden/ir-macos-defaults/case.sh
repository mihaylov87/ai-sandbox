# macOS defaults: /Users, $HOME, /Volumes, /private/tmp/tmux-$UID hidden; session tmp rw.
setup() {
  export AIS_PLATFORM=macos
  mkdir -p "$SYS/Users" "$SYS/Volumes" "$SYS/private/tmp/tmux-$(id -u)"
}
