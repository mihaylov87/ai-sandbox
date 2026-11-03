# ai-sandbox

Runs a coding-agent harness (GitHub Copilot CLI, Claude Code, or any other) with every
permission prompt off, inside a kernel-enforced sandbox: bubblewrap on Linux, Seatbelt on
macOS. The sandbox wraps the whole harness process, so built-in file tools, MCP servers,
hooks and plugins all sit behind one boundary, and the kernel is the only gate.

Status: v2 in development. Linux is implemented and tested (Ubuntu 25.04, bwrap 0.11);
macOS is implemented and tested on macOS 27.2 (see [macOS specifics](#macos-specifics)).

## What the sandbox does

| Area | Inside the sandbox |
| --- | --- |
| Files | `/` read-only; `$HOME`, `/mnt`, `/media` and `/run/user/$UID` hidden (and read-only); only the work dir, listed paths and a cache dir writable |
| Guardrails | The install dir, your config, the harness's guardrail files (settings, hooks, MCP config) and `.git/hooks`, `.git/config`, `.git/info` of every repo in a writable path are read-only |
| Network | Outbound only through a host proxy that allows listed `host:port` pairs; clients that ignore proxy variables fail; LAN, cloud metadata and host loopback refused |
| Environment | Starts empty; only listed variables cross; credentials only as scoped tokens you provide |
| Processes | Linux: own PID, IPC, UTS and network namespaces; nested user namespaces and inner sandboxes refused; Docker, containerd and Podman sockets masked. macOS: signals only within the sandbox; keychain, clipboard, LaunchServices and AppleEvents denied; Unix sockets unreachable except the SSH agent when forwarded |
| After the session | An exit report lists changed files that run automatically outside (`.envrc`, `.vscode/tasks.json`, `Makefile`, new executables, symlinks pointing out, new repos) |

Not protected: kernel or sandbox escapes, secrets you deliberately give the harness, and
code the agent writes that you later run unsandboxed. Treat agent output like a pull
request from a stranger: review the diff before running builds, tests or the editor
outside. Running them inside, with `ai-sandbox --shell -c 'make test'`, is the safe default.

## Requirements

- Linux: unprivileged bubblewrap 0.8.0+ with user namespaces (Ubuntu 24.04+: setup installs
  an AppArmor profile for `/usr/bin/bwrap` if needed). macOS: 14+ (tested on 27).
- Bash 3.2+, Python 3.9+ (stdlib only), `realpath`; `nc` with `-X` for Git over SSH.

## Install

```sh
git clone <this repo> ~/.local/share/ai-sandbox
~/.local/share/ai-sandbox/setup.sh        # creates ~/.config/ai-sandbox/config, then stops
$EDITOR ~/.config/ai-sandbox/config       # set AI_SANDBOX_WORK_DIR, harness, paths, secrets
~/.local/share/ai-sandbox/setup.sh        # installs, then runs the self-test matrix
```

`setup.sh` is idempotent. It links `ai-sandbox` into `~/.local/bin`, makes the install dir
0755 and not writable by others (the launcher refuses a writable install), creates
`~/.config/ai-sandbox/{projects,seed,secrets}`, copies default guardrail seeds, prints the
secrets each profile still needs, and ends with `ai-sandbox --check`.

## Use

```sh
ai-sandbox                         # the configured harness in the configured work dir
ai-sandbox -H claude -w ~/src/app  # pick harness and work dir
ai-sandbox -- npm test             # any command instead of the harness
ai-sandbox --shell                 # a sandboxed bash
ai-sandbox --check                 # self-test matrix; records verification gates
ai-sandbox --print-policy [--ir]   # the compiled bwrap arguments, or the portable policy
ai-sandbox --print-policy --ir ~/.ssh/id_ed25519   # which rule decides a path
ai-sandbox --dry-run               # policy, environment (secrets redacted) and command
ai-sandbox -v --net-log            # keep details; print denied hosts at exit
```

Exit codes: the child's code (128+n for signal n); 123 a verification gate failed and is not
accepted; 125 config or policy error (the message names the variable or path); 126 platform,
dependency or nesting problem; 127 command not found inside.

## Configuration

Config is read only from outside the work dir: `~/.config/ai-sandbox/config`, then
`projects/<name>.conf` (`--project <name>`, or the first whose `AI_SANDBOX_WORK_DIR` matches),
the harness profile, `AI_SANDBOX_*` in the environment, then CLI flags. Files are Bash
assignments, must be owned by you and not group- or world-writable; an unknown
`AI_SANDBOX_*` name or invalid value stops the launcher, so a typo never weakens the policy.
See `config.example` and spec section 6 for every variable. The most used:

| Variable | Meaning |
| --- | --- |
| `AI_SANDBOX_WORK_DIR` | Primary writable directory (required) |
| `AI_SANDBOX_HARNESS` | `copilot` (default), `claude` or `generic` |
| `AI_SANDBOX_RW_PATHS`, `AI_SANDBOX_RO_PATHS`, `AI_SANDBOX_HIDE_PATHS` | Colon-separated extra paths; a trailing `?` makes an RW path optional |
| `AI_SANDBOX_NET` | `allowlist` (default), `none`, `open` |
| `AI_SANDBOX_NET_PRESETS`, `AI_SANDBOX_NET_ALLOW` | `npm pypi github crates go`; extra `host[:port]` or `*.domain[:port]` |
| `AI_SANDBOX_HOST_PORTS` | Host loopback ports reachable inside, e.g. a local model on 11434 |
| `AI_SANDBOX_SECRET_CMD_<VAR>` | Host command whose output becomes `<VAR>` inside |
| `AI_SANDBOX_STATE` | `isolated` (default): harness state in `~/.local/state/ai-sandbox/<harness>/` |

Everything under `$HOME` is hidden unless listed. A harness or runtime installed in your
home must have its real install dir listed: symlinks such as `~/.local/bin/claude` are not
recreated inside, and hidden directories on `PATH` stay empty. When the command is a bare
name that the host finds only through such a symlink, the launcher runs it by its real path
(`-v` says so), so it keeps working after the harness updates itself. A command that cannot
be reached inside stops the launcher at start with exit 127 and says which dir to list.
Set each variable once, all paths on one line:

```sh
# Claude Code, native install (~/.local/bin/claude -> ~/.local/share/claude/versions/...)
AI_SANDBOX_RO_PATHS=~/.local/share/claude:~/.gitconfig
```

A runtime that the harness starts by name must be reachable too. Copilot installed with
nvm, for example, needs node's dir listed and the command given with its full path:

```sh
AI_SANDBOX_RO_PATHS=~/.nvm/versions/node/v22.23.3
AI_SANDBOX_COMMAND="$HOME/.nvm/versions/node/v22.23.3/bin/copilot --autopilot --allow-all"
```

## Credentials

Give each harness its own token with the narrowest scope and an expiry. Secrets are
resolved on the host before start, from `AI_SANDBOX_SECRET_CMD_<VAR>` (for example
`security find-generic-password -w -s ai-sandbox-claude`) or from
`~/.config/ai-sandbox/secrets/<name>` (mode 0600), and reach the harness only through its
environment, never a command line or a file.

- Copilot: `COPILOT_GITHUB_TOKEN`, a fine-grained PAT with the Copilot Requests permission
  (secret name `copilot`).
- Claude Code: `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` (secret `claude`) or
  `ANTHROPIC_API_KEY` (secret `anthropic`).

## Network

In `allowlist` mode the kernel blocks every connection except to the host proxy, and the
proxy forwards only to allowed `host:port` pairs (a bare host means 443 for HTTPS, 80 for
HTTP). It refuses names resolving to loopback, link-local, private, CGNAT or ULA addresses.
Each profile brings its API endpoints; add what a task needs with presets or
`AI_SANDBOX_NET_ALLOW`. `none` blocks egress but keeps host ports; `open` is for debugging
and is logged as unsandboxed. Git over SSH needs the `github` preset and
`AI_SANDBOX_SSH_AGENT=1`.

## Guardrails and seeds

With isolated state, the harness's guardrail files (Copilot: `hooks`, `settings.json`,
`mcp-config.json`, ...; Claude Code: `settings.json`, `CLAUDE.md`, `agents`, `hooks`, ...)
are copied at every start from `~/.config/ai-sandbox/seed/<harness>/`, falling back to the
defaults in `seeds/`, and are read-only inside. Edit your seeds on the host; the agent
cannot change them, and guardrail files it creates do not survive to the next session.

## macOS specifics

The Seatbelt backend runs the harness under `/usr/bin/sandbox-exec` with a generated
profile (`profile.sb` in the session dir). There are no mount namespaces, so paths inside
are the host paths, and hiding is done with read denies. Differences from Linux:

- Hidden paths fail with `Operation not permitted` instead of looking empty. Git treats
  that as fatal for `~/.gitconfig`, so when it is hidden the launcher sets
  `GIT_CONFIG_GLOBAL=/dev/null`; list `~/.gitconfig` in `AI_SANDBOX_RO_PATHS` to use yours.
- `/private/tmp` is shared with the host (`TMPDIR` points into the session dir), and the
  Darwin per-user temp and cache dirs are writable.
- Setuid programs cannot be started inside, so `ps` and `crontab` fail.
- Localhost: the agent reaches only the proxy and `--host-port` ports, including servers it
  starts itself; a test suite serving on 8080 needs `--host-port 8080` (or
  `AI_SANDBOX_LOCALHOST=shared`).
- Gate results on macOS 27.2: G1 failed (`open -a` and AppleEvents get through the
  LaunchServices and AppleEvent denies), so `open`, `osascript` and `launchctl` cannot be
  started inside; G2 failed (TIOCSTI injection into the terminal works), so the harness runs
  behind a host-side pty relay, or without a controlling terminal when stdin is not one.
- The harness runs in its own process group with the terminal handed to it, so Ctrl-C
  reaches it directly. Started in the background (`ai-sandbox ... &`), it stays in your
  shell's job: when it touches the terminal the job stops, and `fg` resumes it.

## Debugging and tuning

Each session leaves `~/.local/state/ai-sandbox/sessions/<id>/` (kept with `--keep-session`
or when the harness exits non-zero) with `policy.ir`, `bwrap.argv` or `profile.sb`,
`net.log` and the exit report, and appends a line to `~/.local/state/ai-sandbox/sessions.log`.
On Linux, denied writes show up as `EROFS` or `EACCES` and hidden paths look empty or
missing. On macOS every denial is `Operation not permitted`; with `-v` the session also
keeps `sandbox.log`, the Seatbelt denial stream (system-wide, so other apps' denials appear
too; lines name the process and PID).

Tuning loop: run once with `-v --net-log`, add the hosts and paths the task really needs to
the project config, re-run `--check`.

## Migrating from v1

- `setup.sh` offers to copy v1's `.env` values into `~/.config/ai-sandbox/config`;
  `AI_SANDBOX_EXTRA_RW` and `AI_SANDBOX_EXTRA_RO` keep working as aliases of `--rw` and `--ro`
  (with a deprecation warning).
- Network now defaults to `allowlist`. Set `AI_SANDBOX_NET=open` to get v1 behaviour while
  tuning the allowlist.
- `$HOME` listed in `AI_SANDBOX_RO_PATHS` no longer exposes the whole home: the default
  hidden entry wins on the same path (with a warning). List individual paths instead.
- `~/.cache` and `~/.ssh` are no longer exposed; `.git/config` is locked (set
  `AI_SANDBOX_GIT_CONFIG=rw` per project to unlock it; the exit report then shows its diff).
- Copilot state moves to `COPILOT_HOME`; on first setup your current `~/.copilot` guardrail
  files are copied into `~/.config/ai-sandbox/seed/copilot/` for review.

## Tests

```sh
tests/unit/run.sh               # unit and golden tests (stub backend; no sandbox needed)
python3 -I tests/unit/net_test.py
tests/lint-bash32.sh            # Bash 3.2 constructs check
tests/fixture-check.sh          # the full matrix against a throwaway home, real backend
tests/fixture-check.sh --no-sandbox   # negative control: protection rows must fail
```
