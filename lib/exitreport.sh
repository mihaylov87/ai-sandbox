# lib/exitreport.sh — exit report, sessions.log, --net-log (spec §12, §14). Bash 3.2 compatible.
#
# exitreport_start  (step 6) manifest of the user's rw dirs (work dir, AI_SANDBOX_RW_PATHS,
#                   --rw) in $SESSION/manifest.start, plus snapshots of files whose diff is
#                   always shown (.git/config with AI_SANDBOX_GIT_CONFIG=rw, and any path a
#                   profile lists in EXITREPORT_ALWAYS_DIFF).
# exitreport_finish (step 10) compares with the end state and prints only changed entries in
#                   the reported classes, to stderr and $SESSION/exit-report.txt; then the
#                   --net-log summary.
# sessionlog_append RC  one line per session in ~/.local/state/ai-sandbox/sessions.log:
#                   start, end, harness, exit code, net mode, denied requests, work dir[, flags]
#                   (tab-separated).
# The manifest walk skips the contents of .git and node_modules directories.

EXITREPORT_ALWAYS_DIFF=()

_EXITREPORT_PY='
import difflib, json, os, shutil, stat, sys

def walk(roots):
    out = []
    for ri, root in enumerate(roots):
        for dirpath, dirnames, filenames in os.walk(root):
            keep = []
            for d in dirnames:
                if d == ".git":
                    out.append([ri, os.path.relpath(os.path.join(dirpath, d), root), "g", 0, 0, 0, ""])
                elif d == "node_modules":
                    pass
                else:
                    keep.append(d)
            dirnames[:] = keep
            for name in keep + filenames:
                p = os.path.join(dirpath, name)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                kind = "l" if stat.S_ISLNK(st.st_mode) else "d" if stat.S_ISDIR(st.st_mode) else "f"
                target = os.readlink(p) if kind == "l" else ""
                out.append([ri, os.path.relpath(p, root), kind, stat.S_IMODE(st.st_mode), st.st_size,
                            st.st_mtime_ns, target])
    return out

WATCHED_NAMES = {".envrc", ".tool-versions", "mise.toml", "Makefile", "package.json", "pyproject.toml",
                 ".pre-commit-config.yaml"}
WATCHED_DIRS = {".vscode", ".idea", ".devcontainer"}

def watched(rel):
    parts = rel.split(os.sep)
    base = parts[-1]
    if base in WATCHED_NAMES or base.startswith(".env"):
        return True
    if any(p in WATCHED_DIRS for p in parts[:-1]):
        return True
    for i in range(len(parts) - 2):
        if parts[i] == ".github" and parts[i + 1] == "workflows":
            return True
    return False

def outside(root, rel, target):
    base = os.path.dirname(os.path.join(root, rel))
    t = os.path.normpath(os.path.join(base, target))
    r = os.path.normpath(root)
    return not (t == r or t.startswith(r + os.sep)), t

def cmd_start(manifest, snapdir, roots, always):
    with open(manifest, "w") as f:
        json.dump({"roots": roots, "entries": walk(roots)}, f)
    snaps = []
    for i, p in enumerate(always):
        dst = os.path.join(snapdir, "snapshot.%d" % i)
        if os.path.isfile(p):
            shutil.copyfile(p, dst)
        else:
            open(dst, "w").close()
        snaps.append([p, dst])
    with open(os.path.join(snapdir, "snapshots.json"), "w") as f:
        json.dump(snaps, f)

def cmd_finish(manifest, snapdir):
    with open(manifest) as f:
        m = json.load(f)
    roots = m["roots"]
    start = dict(((e[0], e[1]), e) for e in m["entries"])
    lines = []
    for e in walk(roots):
        ri, rel, kind, mode, size, mtime, target = e
        old = start.get((ri, rel))
        new = old is None
        changed = not new and (old[2] != kind or old[3] != mode or old[4] != size or old[5] != mtime or old[6] != target)
        shown = rel if ri == 0 else os.path.join(roots[ri], rel)
        if kind == "g":
            if new:
                lines.append((shown, "new repo  %s" % shown))
            continue
        if kind == "l":
            if new or changed:
                out, t = outside(roots[ri], rel, target)
                if out:
                    lines.append((shown, "symlink   %s -> %s" % (shown, target)))
            continue
        if kind == "f" and mode & 0o111:
            if new:
                lines.append((shown, "new exec  %s" % shown))
                continue
            if not old[3] & 0o111:
                lines.append((shown, "now exec  %s" % shown))
                continue
        if kind != "d" and watched(rel) and (new or changed):
            lines.append((shown, "%s %s" % ("new      " if new else "modified ", shown)))
    for shown, line in sorted(lines):
        print("  " + line)
    try:
        with open(os.path.join(snapdir, "snapshots.json")) as f:
            snaps = json.load(f)
    except OSError:
        snaps = []
    for path, snap in snaps:
        with open(snap, errors="replace") as f:
            a = f.read().splitlines()
        try:
            with open(path, errors="replace") as f:
                b = f.read().splitlines()
        except OSError:
            b = []
        print("  diff %s:" % path)
        diff = list(difflib.unified_diff(a, b, "start", "end", lineterm=""))
        if not diff:
            print("    (unchanged)")
        for d in diff:
            print("    " + d)

def cmd_netlog(log):
    counts, total = {}, 0
    try:
        with open(log) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if str(e.get("verdict", "")).startswith("deny"):
                    total += 1
                    hp = "%s:%s" % (e.get("host", ""), e.get("port", ""))
                    counts[hp] = counts.get(hp, 0) + 1
    except OSError:
        pass
    if sys.argv[1] == "netlog-count":
        print(total)
        return
    if not counts:
        return
    print("ai-sandbox: denied hosts (%d distinct, %d requests):" % (len(counts), total))
    for hp, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print("%6d  %s" % (n, hp))

if sys.argv[1] == "start":
    n = int(sys.argv[4])
    cmd_start(sys.argv[2], sys.argv[3], sys.argv[5:5 + n], sys.argv[5 + n:])
elif sys.argv[1] == "finish":
    cmd_finish(sys.argv[2], sys.argv[3])
else:
    cmd_netlog(sys.argv[2])
'

_exitreport_roots() {
  local i=0
  while [ "$i" -lt "${#K_PATH[@]}" ]; do
    if [ "${K_CLASS[$i]}" = rw ] && [ "${K_KIND[$i]}" = dir ]; then
      case "${K_SRC[$i]}" in AI_SANDBOX_WORK_DIR | AI_SANDBOX_RW_PATHS | --rw) printf '%s\n' "${K_PATH[$i]}" ;; esac
    fi
    i=$((i + 1))
  done
}

exitreport_start() {
  AIS_START_TS=${AIS_START_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  [ "$AI_SANDBOX_EXIT_REPORT" = 1 ] || return 0
  local roots=() always=() r g
  while IFS= read -r r; do [ -n "$r" ] && roots[${#roots[@]}]=$r; done <<EOF
$(_exitreport_roots)
EOF
  if [ "$AI_SANDBOX_GIT_CONFIG" = rw ]; then
    for r in ${roots[@]+"${roots[@]}"}; do
      while IFS= read -r -d '' g; do always[${#always[@]}]="$g/config"; done \
        < <(find "$r" -maxdepth 4 -name .git -type d -prune -print0 2>/dev/null)
    done
  fi
  always=(${always[@]+"${always[@]}"} ${EXITREPORT_ALWAYS_DIFF[@]+"${EXITREPORT_ALWAYS_DIFF[@]}"})
  "$AIS_PYTHON" -I -c "$_EXITREPORT_PY" start "$AIS_SESSION_DIR/manifest.start" "$AIS_SESSION_DIR" \
    "${#roots[@]}" ${roots[@]+"${roots[@]}"} ${always[@]+"${always[@]}"}
}

exitreport_finish() {
  local report
  if [ "$AI_SANDBOX_EXIT_REPORT" = 1 ] && [ -f "$AIS_SESSION_DIR/manifest.start" ]; then
    report=$("$AIS_PYTHON" -I -c "$_EXITREPORT_PY" finish "$AIS_SESSION_DIR/manifest.start" "$AIS_SESSION_DIR")
    if [ -n "$report" ]; then
      {
        printf 'ai-sandbox: exit report: files that run automatically outside the sandbox changed;\n'
        printf 'review them before running builds, tests or the editor unsandboxed:\n'
        printf '%s\n' "$report"
      } | tee "$AIS_SESSION_DIR/exit-report.txt" >&2
    fi
  fi
  if [ "$CLI_NET_LOG" = 1 ] && [ -f "$AIS_SESSION_DIR/net.log" ]; then
    "$AIS_PYTHON" -I -c "$_EXITREPORT_PY" netlog "$AIS_SESSION_DIR/net.log" >&2
  fi
  return 0
}

sessionlog_append() { # child-exit-code
  local f="$HOME/.local/state/ai-sandbox/sessions.log" denied=0 flags=
  [ -f "$AIS_SESSION_DIR/net.log" ] &&
    denied=$("$AIS_PYTHON" -I -c "$_EXITREPORT_PY" netlog-count "$AIS_SESSION_DIR/net.log")
  [ "$AI_SANDBOX_NET" = open ] && flags="unsandboxed:net-open"
  [ "$AI_SANDBOX_DOCKER" = 1 ] && flags="${flags:+$flags,}unsandboxed:docker"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "${AIS_START_TS:-?}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$AI_SANDBOX_HARNESS" "$1" "$AI_SANDBOX_NET" "$denied" "$POLICY_WORK_DIR" "${flags:+	$flags}" >>"$f"
}
