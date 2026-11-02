# Stub backend for launcher tests: implements the backend interface without a sandbox.
# Selected with _AIS_TEST_BACKEND=stub. Runs the command directly on the host.

backend_preflight() { :; }

backend_compile() { # ir-file session-dir
  { printf 'stub-policy\n'; cat "$1"; } >"$2/stub.policy"
}

backend_print() { # session-dir
  cat "$1/stub.policy"
}

# Sets AIS_RUN_ARGV (what to exec) and AIS_RUN_CWD (host cwd for the exec, or empty).
backend_command() { # session-dir cwd -- command...
  AIS_RUN_CWD=$2
  shift 3
  AIS_RUN_ARGV=("$@")
  # _AIS_STUB_PGRP=1: run the child in its own process group, as the macOS backend does.
  [ "${_AIS_STUB_PGRP-}" = 1 ] && AIS_RUN_PGRP=1
  return 0
}
