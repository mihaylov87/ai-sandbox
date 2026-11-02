#!/usr/bin/env bash
# Runs `ai-sandbox --check` with the real backend against a throwaway install and HOME,
# with planted secrets, caches, a sibling project and dotfiles, so the matrix exercises
# every row without touching the real home.
# Usage: tests/fixture-check.sh [--keep] [--net MODE] [--no-sandbox]
# --no-sandbox runs the same matrix with the stub backend (commands run unsandboxed on the
# host) as a negative control: every protection row must then FAIL.
# Bash 3.2 compatible.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
keep=0 net=allowlist stub=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep) keep=1 ;;
    --net) net=$2; shift ;;
    --no-sandbox) stub=1 ;;
    *) echo "usage: $0 [--keep] [--net MODE] [--no-sandbox]" >&2; exit 2 ;;
  esac
  shift
done

fx=$(mktemp -d "${TMPDIR:-/tmp}/ais-fixture.XXXXXX")
fx=$(cd "$fx" && pwd -P)
agent_pid=
cleanup() {
  [ -n "$agent_pid" ] && kill "$agent_pid" 2>/dev/null
  [ "$keep" = 1 ] || rm -rf "$fx"
}
trap cleanup EXIT

# A throwaway SSH agent, so I10 can check forwarding (no keys needed).
if command -v ssh-agent >/dev/null 2>&1; then
  eval "$(ssh-agent -a "$fx/agent.sock" -s)" >/dev/null
  agent_pid=$SSH_AGENT_PID
else
  unset SSH_AUTH_SOCK
fi

inst=$fx/install
h=$fx/home
mkdir -p "$inst/lib" "$inst/profiles" "$inst/tests"
cp "$root/ai-sandbox" "$root/ai-sandbox-init" "$inst/"
[ -f "$root/ai-sandbox-net" ] && cp "$root/ai-sandbox-net" "$inst/"
cp "$root"/lib/*.sh "$inst/lib/"
cp "$root/tests/matrix.sh" "$inst/tests/"
if [ "$stub" = 1 ]; then
  mkdir -p "$inst/tests/unit"
  cp "$root/tests/unit/backend-stub.sh" "$inst/tests/unit/"
  export _AIS_TEST_BACKEND=stub
fi
cp "$root"/profiles/*.sh "$inst/profiles/"
cp -R "$root/seeds" "$inst/"
cat >"$inst/profiles/fixture.sh" <<'EOF'
# Test profile: isolated state dir with one locked guardrail file.
PROFILE_RW=(".")
PROFILE_LOCKED=(settings.json)
EOF

mkdir -p "$h/.ssh" "$h/.aws" "$h/.cache/pip" "$h/.config/ai-sandbox/projects" "$h/src/app" "$h/src/other" \
  "$h/scratch-rw" "$h/.local/state/ai-sandbox/fixture"
echo 'PRIVATE KEY' >"$h/.ssh/id_ed25519"
echo 'github.com ssh-ed25519 AAAA' >"$h/.ssh/known_hosts"
printf '[aws]\nsecret=1\n' >"$h/.aws/credentials"
echo cached >"$h/.cache/pip/x"
printf '[user]\n\tname = fixture\n' >"$h/.gitconfig"
echo '# bashrc' >"$h/.bashrc"
echo '{}' >"$h/.local/state/ai-sandbox/fixture/settings.json"
cat >"$h/.config/ai-sandbox/config" <<EOF
AI_SANDBOX_WORK_DIR=$h/src/app
AI_SANDBOX_HARNESS=fixture
AI_SANDBOX_NET=$net
AI_SANDBOX_RO_PATHS=$h/.gitconfig:$h/.ssh/known_hosts
AI_SANDBOX_RW_PATHS=$h/scratch-rw
AI_SANDBOX_TEST_RO_DIR=/usr/share
AI_SANDBOX_TEST_RW_DIR=$h/scratch-rw
EOF
chmod -R go-w "$inst" "$h"
chmod 0700 "$h/.config/ai-sandbox"
chmod 0600 "$h/.config/ai-sandbox/config"

echo "fixture: $fx"
cd "$h/src/app"
set +e
HOME=$h "$inst/ai-sandbox" --check
rc=$?
set -e
exit "$rc"
