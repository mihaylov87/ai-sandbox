#!/usr/bin/env bash
# ai-sandbox setup (spec §13). Idempotent; ends by running the self-test matrix.
# Exit 0 when every check passed, 1 otherwise (and after creating the config on the
# first run, so you can edit it). Bash 3.2 compatible.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd -P)
. "$root/lib/config.sh"

conf=$HOME/$AIS_CONFIG_DIR_REL
say() { printf 'setup: %s\n' "$*"; }
warn() { printf 'setup: warning: %s\n' "$*" >&2; }
fail() { printf 'setup: %s\n' "$*" >&2; exit 1; }
ask() { # question -> 0 for yes (reads one line from stdin; EOF means no)
  local a=
  printf 'setup: %s [y/N] ' "$1"
  read -r a || true
  printf '\n'
  case "$a" in y | Y | yes | YES) return 0 ;; esac
  return 1
}

# 1. Platform.
case "$(uname -s)" in
  Linux)
    plat=linux
    command -v bwrap >/dev/null 2>&1 || fail "bubblewrap (bwrap) is not installed"
    ;;
  Darwin)
    plat=macos
    [ -x /usr/bin/sandbox-exec ] || fail "/usr/bin/sandbox-exec is missing"
    ;;
  *) fail "unsupported platform: $(uname -s)" ;;
esac

# 2. Dependencies.
if [ "$plat" = linux ]; then
  bw=$(command -v bwrap)
  [ -u "$bw" ] && fail "$bw is setuid; ai-sandbox needs an unprivileged bwrap 0.8.0+"
  v=$("$bw" --version | sed -n 's/^bubblewrap \([0-9][0-9.]*\).*/\1/p')
  case "$v" in 0.[0-7] | 0.[0-7].* | '') fail "bwrap ${v:-?} is too old; 0.8.0 or later is needed" ;; esac
fi
command -v python3 >/dev/null 2>&1 || fail "python3 (3.9+) is not installed"
python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 9))' || fail "python3 is older than 3.9"
command -v realpath >/dev/null 2>&1 || fail "realpath is not installed"
# The help text is captured first: with pipefail, `nc -h | grep -q` fails when grep exits
# early and nc gets SIGPIPE (macOS nc prints a long help).
nc_help=$(nc -h 2>&1 || true)
if ! { command -v nc >/dev/null 2>&1 && case "$nc_help" in *-X*) true ;; *) false ;; esac; }; then
  warn "nc with -X not found: Git over SSH through the proxy will not work (spec section 9)"
fi

# 3. Config: created on the first run (from v1's .env if wanted), then stop for editing.
if [ ! -f "$conf/config" ]; then
  mkdir -p "$conf"
  chmod 0700 "$conf"
  v1=
  for f in "${AI_SANDBOX_V1_DIR:+$AI_SANDBOX_V1_DIR/.env}" "$root/.env"; do
    [ -n "$f" ] && [ -f "$f" ] && { v1=$f; break; }
  done
  if [ -n "$v1" ] && ask "found v1 settings in $v1; copy them into $conf/config?"; then
    {
      printf '# Migrated from v1 (%s) by setup.sh. See config.example for all settings.\n' "$v1"
      printf '# AI_SANDBOX_EXTRA_RW / _RO still work as aliases of --rw / --ro (deprecated).\n'
      ( . "$v1" >/dev/null 2>&1
        for n in $(compgen -v AI_SANDBOX_); do
          if cfg_is_known "$n"; then printf '%s=%q\n' "$n" "${!n}"; else printf '# %s=%q   (unknown in v2)\n' "$n" "${!n}"; fi
        done )
    } >"$conf/config"
    say "copied v1 settings into $conf/config"
  else
    cp "$root/config.example" "$conf/config"
  fi
  chmod 0600 "$conf/config"
  say "created $conf/config: edit it (at least AI_SANDBOX_WORK_DIR), then run setup.sh again"
  exit 1
fi

# 4. Linux: allow bwrap to create user namespaces (Ubuntu 24.04+ AppArmor restriction).
if [ "$plat" = linux ] && ! bwrap --unshare-user --ro-bind / / true >/dev/null 2>&1; then
  say "bwrap cannot create a user namespace; installing the AppArmor profile (needs sudo)"
  sudo install -m 0644 "$root/apparmor/bwrap-ai-sandbox" /etc/apparmor.d/bwrap-ai-sandbox
  sudo apparmor_parser -r /etc/apparmor.d/bwrap-ai-sandbox
  bwrap --unshare-user --ro-bind / / true >/dev/null 2>&1 || fail "bwrap still cannot create a user namespace"
fi

# 5. Install dir: executable helpers, launcher on PATH, 0755 and not writable by others.
chmod u+rwx,go+rx,go-w "$root/ai-sandbox" "$root/ai-sandbox-net" "$root/ai-sandbox-init" "$root/setup.sh" \
  "$root/tests/matrix.sh"
chmod -R go-w "$root"
chmod 0755 "$root"
other=$(find "$root" ! -user "$(id -u)" -print 2>/dev/null | head -n 1)
[ -z "$other" ] || warn "install dir contains files not owned by you, e.g. $other"
mkdir -p "$HOME/.local/bin"
link=$HOME/.local/bin/ai-sandbox
if [ -L "$link" ] || [ ! -e "$link" ]; then
  ln -sfn "$root/ai-sandbox" "$link"
else
  warn "$link exists and is not a symlink (a v1 install?); not replacing it. Remove it and run setup.sh again."
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "$HOME/.local/bin is not on your PATH" ;; esac

# 6. Config dirs, seeds, missing secrets.
mkdir -p "$conf/projects" "$conf/seed" "$conf/secrets"
chmod 0700 "$conf/secrets"
profile_gate_failed() { return 1; }
profile_vars() { # profile-file -> sets PROFILE_* in a subshell and runs the given code
  ( PROFILE_LOCKED=() PROFILE_SECRETS=(); . "$1" >/dev/null 2>&1; eval "$2" )
}
for d in "$root"/seeds/*/; do
  h=$(basename "$d")
  [ -e "$conf/seed/$h" ] && continue
  if [ "$h" = copilot ] && [ -d "$HOME/.copilot" ]; then
    mkdir -p "$conf/seed/copilot"
    profile_vars "$root/profiles/copilot.sh" '
      for e in "${PROFILE_LOCKED[@]}" config.json; do
        [ -e "$HOME/.copilot/$e" ] && cp -R "$HOME/.copilot/$e" "'"$conf"'/seed/copilot/"
      done; :'
    for e in "$d"*; do [ -e "$conf/seed/copilot/$(basename "$e")" ] || cp -R "$e" "$conf/seed/copilot/"; done
    say "copied your ~/.copilot guardrail files into $conf/seed/copilot/: review them"
  else
    cp -R "$d" "$conf/seed/$h"
  fi
done

# Secrets each profile still needs (config values come from the global config only).
conf_lines=$(cfg_read_file "$conf/config") || exit 1
has_cmd() { printf '%s\n' "$conf_lines" | grep -q "^AI_SANDBOX_SECRET_CMD_$1="; }
for p in "$root"/profiles/*.sh; do
  h=$(basename "$p" .sh)
  missing=$(profile_vars "$p" 'for e in ${PROFILE_SECRETS[@]+"${PROFILE_SECRETS[@]}"}; do printf "%s\n" "$e"; done') || true
  optional_unresolved= any_resolved=0 any_optional=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    var=${e%%=*} name=${e#*=} opt=0
    case "$name" in *\?) name=${name%\?} opt=1 any_optional=1 ;; esac
    if has_cmd "$var" || [ -f "$conf/secrets/$name" ]; then
      any_resolved=1
    elif [ "$opt" = 0 ]; then
      say "profile $h needs $var: set AI_SANDBOX_SECRET_CMD_$var or create $conf/secrets/$name (mode 0600)"
    else
      optional_unresolved="${optional_unresolved:+$optional_unresolved or }$var"
    fi
  done <<EOF
$missing
EOF
  if [ "$any_optional" = 1 ] && [ "$any_resolved" = 0 ] && [ "$h" = claude ]; then
    say "profile claude needs $optional_unresolved (one of them; see profiles/claude.sh)"
  fi
done

# 7. The matrix.
say "running the self-test matrix"
if if [ -n "${_AIS_SETUP_CHECK-}" ]; then eval "$_AIS_SETUP_CHECK"; else "$root/ai-sandbox" --check; fi; then
  say "All checks passed"
else
  say "Some checks failed"
  exit 1
fi
