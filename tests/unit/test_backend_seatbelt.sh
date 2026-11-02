# macOS backend: IR -> SBPL (spec §8). WP3. Golden files in golden/seatbelt/.
# Host-dependent inputs come from test seams: _AIS_DARWIN_TEMP_DIR, _AIS_DARWIN_CACHE_DIR.
# Compilation only: runs on any platform (sandbox-exec is not needed).

GOLDEN_SB="$REPO_ROOT/tests/unit/golden/seatbelt"

# Compile golden/seatbelt/input.ir (or $SB_IR) with the given setup; OUT = profile.sb.
sb_compile() { # setup-code [code-after-compile]
  mk_tmp
  mkdir -p "$TMP/session"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMP/agent.sock"
  capture bash -c '
    set -euo pipefail
    . "$1/lib/config.sh"; . "$1/lib/backend-seatbelt.sh"
    TMP=$2 SESSION=$2/session IR=$1/tests/unit/golden/seatbelt/input.ir
    AIS_INSTALL_DIR=/opt/ai-sandbox AIS_PLATFORM=macos AI_SANDBOX_NET=allowlist AI_SANDBOX_SSH_AGENT=0
    AI_SANDBOX_HOST_PORTS= AI_SANDBOX_KEYCHAIN=deny AI_SANDBOX_DNS=deny AI_SANDBOX_LOCALHOST=isolated
    AIS_PROXY_PORT=52000
    _AIS_DARWIN_TEMP_DIR=/private/var/folders/xy/abc/T/ _AIS_DARWIN_CACHE_DIR=/private/var/folders/xy/abc/C/
    eval "$3"
    backend_compile "$IR" "$SESSION"
    eval "$4"
    cat "$SESSION/profile.sb"
  ' _ "$REPO_ROOT" "$TMP" "$1" "${2-}"
}

sb_expected() { # golden-file
  sed -e "s|@AGENT@|$TMP/agent.sock|g" "$GOLDEN_SB/$1"
}

# The block of the profile that starts with ";; <n>." (up to the next blank line).
sb_block() { # n
  printf '%s\n' "$OUT" | sed -n "/^;; $1\\./,/^\$/p" | sed '/^$/d'
}

test_allowlist_profile_matches_golden() {
  sb_compile ''
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$(sb_expected allowlist.sb)" "$OUT"
}

test_open_mode_with_ssh_agent_keychain_allowed_and_fallbacks() {
  sb_compile 'AI_SANDBOX_NET=open AI_SANDBOX_SSH_AGENT=1 SSH_AUTH_SOCK=$TMP/agent.sock AI_SANDBOX_KEYCHAIN=allow
              gate_fallback_G1; gate_fallback_G5; SB_G4_SOCKET_FORM=literal'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq "$(sb_expected open-fallbacks.sb)" "$OUT"
}

test_none_mode_host_ports_dns_allow_and_ssh_agent() {
  sb_compile 'AI_SANDBOX_NET=none AI_SANDBOX_HOST_PORTS="11434 8080" AI_SANDBOX_DNS=allow
              AI_SANDBOX_SSH_AGENT=1 SSH_AUTH_SOCK=$TMP/agent.sock'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq ";; 4. network (section 9)
(deny network-outbound)
(allow network-outbound (remote ip \"localhost:11434\"))
(allow network-outbound (remote ip \"localhost:8080\"))
(allow network-bind network-inbound (local ip \"localhost:*\"))
(allow network-outbound (remote unix-socket (path-literal \"$TMP/agent.sock\")))
(allow network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))" "$(sb_block 4)"
}

test_shared_localhost_replaces_the_port_rules() {
  sb_compile 'AI_SANDBOX_LOCALHOST=shared AI_SANDBOX_HOST_PORTS=11434'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq ';; 4. network (section 9)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-bind network-inbound (local ip "localhost:*"))' "$(sb_block 4)"
}

test_unknown_proxy_port_is_shown_as_a_comment() {
  sb_compile 'AIS_PROXY_PORT='
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_contains "$(sb_block 4)" ';; (allow network-outbound (remote ip "localhost:<PROXY_PORT>"))' || return 1
  assert_not_contains "$(sb_block 4)" '
(allow network-outbound (remote ip "localhost:'
}

test_g4_fallback_without_signal_form_omits_the_signal_rule() {
  sb_compile 'SB_G4_SIGNAL=0'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_not_contains "$OUT" "signal"
}

test_control_character_in_path_exits_125() {
  sb_compile 'printf "rw\tdir\t/Users/jordan/a\001b\n" >"$TMP/bad.ir"; IR=$TMP/bad.ir'
  assert_eq 125 "$RC" "$OUT" || return 1
  assert_contains "$ERR" "control character"
}

test_metadata_ancestors_follow_the_hidden_lines_that_cover_them() {
  # Every file-read-metadata rule must come after each hidden subpath that contains one
  # of its literals (later rules win).
  sb_compile ''
  assert_eq 0 "$RC" "$ERR" || return 1
  printf '%s\n' "$OUT" | awk '
    /^\(deny file-read\* file-write\* \(subpath "/ { p = $0; sub(/^[^"]*"/, "", p); sub(/".*/, "", p); hidden[p] = NR }
    /^\(allow file-read-metadata/ {
      line = $0
      while (match(line, /literal "[^"]*"/)) {
        a = substr(line, RSTART + 9, RLENGTH - 10); line = substr(line, RSTART + RLENGTH)
        for (h in hidden) if ((a == h || index(a, h "/") == 1) && hidden[h] > NR) bad = bad " " a
      }
    }
    END { if (bad != "") { print "metadata before its hidden line:" bad; exit 1 } }' ||
    fail "ordering"
}

test_command_checks_the_profile_and_runs_sandbox_exec() {
  sb_compile '' '
    printf "#!/bin/sh\n[ \"\$3\" = /usr/bin/true ] && echo checked >>\"$TMP/log\"; exit 0\n" >"$TMP/sbx"
    chmod +x "$TMP/sbx"; AIS_SANDBOX_EXEC=$TMP/sbx
    backend_command "$SESSION" /w/app -- claude --flag "a b"
    printf "run=%s\n" "${AIS_RUN_ARGV[@]}" >"$TMP/run"
    printf "cwd=%s pgrp=%s env=%s\n" "$AIS_RUN_CWD" "$AIS_RUN_PGRP" "$AIS_RUN_ENV" >>"$TMP/run"'
  assert_eq 0 "$RC" "$ERR" || return 1
  assert_eq checked "$(cat "$TMP/log")" || return 1
  assert_eq "run=$TMP/sbx
run=-f
run=$TMP/session/profile.sb
run=--
run=claude
run=--flag
run=a b
cwd=/w/app pgrp=1 env=1" "$(cat "$TMP/run")"
}

test_profile_that_sandbox_exec_rejects_exits_125() {
  sb_compile '' '
    printf "#!/bin/sh\necho \"bad rule\" >&2; exit 65\n" >"$TMP/sbx"; chmod +x "$TMP/sbx"; AIS_SANDBOX_EXEC=$TMP/sbx
    backend_command "$SESSION" /w/app -- true'
  assert_eq 125 "$RC" || return 1
  assert_contains "$ERR" "does not pass sandbox-exec: bad rule"
}

test_generated_profiles_compile_with_sandbox_exec() {
  [ -x /usr/bin/sandbox-exec ] || return 0 # macOS only
  local setup
  for setup in '' 'AI_SANDBOX_NET=open AI_SANDBOX_SSH_AGENT=1 SSH_AUTH_SOCK=$TMP/agent.sock' \
               'AI_SANDBOX_NET=none AI_SANDBOX_DNS=allow; gate_fallback_G1; gate_fallback_G4; gate_fallback_G5'; do
    sb_compile "$setup"
    assert_eq 0 "$RC" "$ERR" || return 1
    printf '%s\n' "$OUT" >"$TMP/p.sb"
    /usr/bin/sandbox-exec -f "$TMP/p.sb" /usr/bin/true || fail "profile does not compile: $setup" || return 1
  done
}
