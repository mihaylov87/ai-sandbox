# ai-sandbox-net (spec §9). WP4. The tests are Python (net_test.py); this runs them.

test_ai_sandbox_net_python_suite() {
  capture python3 -I "$REPO_ROOT/tests/unit/net_test.py"
  [ "$RC" = 0 ] || fail "$ERR"
}
