# Linux portability — what running the full sequence on Linux found

`docs/PORTABILITY.md` is the static audit (every POSIX-ism outside a
guard) and `zig build gate-targets` proves all five targets *compile*.
This page is the other half for Linux: what happened when the whole
verification sequence — both unit modes, the gate sweep, the full
corpus, `tools/run-sh-check.sh`, the integrations' and SDK's own
suites — was *run* on Linux, which it had not been end to end.

`tools/linux-verify.sh` is the run (`docs/CONVENTIONS.md`, "Verification
on Linux"). Every number here is from a native `linux/arm64` container
on Apple Silicon — Debian 12 base, the aarch64 Zig 0.16.0 tarball, no
emulation — offline (`--network none`), as an unprivileged user.
`MNML_LINUX_ARCH=amd64` runs the x86_64 twin; it has not been run.

## The runs

| Step | First run (`c886d11d`) | Branch on `23ee8c78` |
|---|---|---|
| `zig build -Dpartial=false` | exit 1 — 68/75 steps; 4 exes did not compile | exit 0 |
| `zig build unit -Doptimize=ReleaseSafe` | exit 1 — the main suite never compiled | exit 0 — 2972/2974 (2 skipped) |
| `zig build unit` (Debug) | exit 1 — the same | exit 0 — 2972/2974 (2 skipped) |
| `zig build -Doptimize=ReleaseSafe` | exit 1 — the same | exit 0 |
| gate `--sizes 80x24,120x40,200x60` | exit 0 — 148/148 | exit 0 — 148/148 |
| full corpus (`MNML_E2E_ALLOW_SHELL=1`) | exit 1 — 819/876 | exit 1 — 914/919 (7 skipped: 6 `requires: macos`, 1 network) |
| `tools/run-sh-check.sh` | exit 1 — 25/87 | exit 0 — 87/87 |
| integrations + SDK `zig build test` | exit 1 | exit 0 — 2 + 146 + 162 + 158 tests |

Main moved underneath this work, and several of the things the first
run found were fixed there in parallel (below). A run of the branch on
`8aebbc0f` (after `winaudit` and `flaky`) found four more corpus files
main had added with the same shapes, and one unit-test race main's
line-blame fix introduced — all fixed here. The run on the branch as
merged is in the `linuxrun` merge report.

## Found and fixed

On main, in parallel with this work (the Linux run reproduced each):

- **`std.c` without libc** (`winaudit`, `0dedff3e`): the SDK's
  `warm.zig` and the fake Bitbucket call `std.c.getpid` / `std.c.kill`;
  macOS always links libc, Linux needs it spelled out. Every step that
  installs the integrations failed on it — most of the first run's
  numbers are this one cause.
- **Line blame before the first status** (`flaky`, `9f2af0b5`): the
  blame could answer before HEAD was known, be cached against no HEAD,
  and never be asked again. The Mac's worker happened to finish the
  status first; on Linux the blame won and `line_blame` failed every
  run.
- **The host's environment in the corpus** (`flaky`, `e9c5747b`): seven
  files read `$TERM_PROGRAM` (a shell pane is `Terminal (sh)` only under
  Apple's Terminal) and `split_preview_keys` needed `claude` on PATH.
  The runner's allowlisted environment closes the class.

On the `linuxrun` branch:

- **`mktemp -d -t NAME`** is BSD's prefix form; GNU mktemp fails on it.
  `tools/run-sh-check.sh` then ran with an empty TMP — its TMPDIR, data
  root and binary copy at `/tmp`, `/data`, `/bin` — and 62 of 87 checks
  failed. `tools/break-check-selftest.sh` had the same line.
- **`Dir.iterate()` on a handle opened without `.iterate`.** macOS reads
  it; on Linux the handle is `O_PATH` and `getdents` is `EBADF` — a
  panic in Debug (`broker_cli.zig`'s socket-length test).
- **Shell steps written for the Mac's tools:**
  - `printf '\x..'` — dash (Debian's `/bin/sh`) has no `\x`. Octal
    escapes are byte-identical under bash, zsh and dash.
    `files_picker_folds_accents` had been *passing* on Linux without
    ever making the accented name — vacuous, not green.
  - `dd … seek=300m` — GNU dd has no lowercase `m`.
  - `git init --bare` without `-b main` — the Mac's git 2.54 defaults to
    `main`, Debian's 2.39 to `master`, and the clone checks out nothing.
- **Text that depended on the temp dir.** `lua_budget_pattern` and
  `lua_budget_pcall` asked for a phrase inside a toast that starts with
  an absolute path; where it word-wraps moves with `$TMPDIR`'s length.
  `git_palette_filter` typed `fea`, which a `mnml-e2e-<6 hex>` name
  contains about one run in a thousand.
- **Four files main added meanwhile**, the same shapes again:
  `git_diff_binary_verbs` (`printf '\x'`), `git_worktree_remove_delete_branch`
  (a toast phrase split by the wrap), `sessions_picker_names` (BSD
  `date -v-2H`), and `git_remote_head_not_a_branch`, whose precondition
  pinned git 2.4x's `origin` for `refs/remotes/origin/HEAD` — 2.39
  prints `origin/HEAD`; the parser already drops both.
- **A unit-test race** (`app.git`, "line blame: the cursor's line gets
  its commit…"): since the status handler re-asks the blame when a
  snapshot lands, a blame that beat the open's snapshot was cached
  twice. On Linux it won every run. The test settles the snapshot first.
- **A real network error as the assertion.**
  `env-resolution-mnml-overrides-rqst` read the host out of a DNS
  failure, on screen in time only where DNS answers at once. It sends
  to a `serve 0 … @echo` server now.

## What still needs something

### The pty files that start zsh, and the pager test

`pty_osc7_cwd_saved`, `pty_paste_sanitized` and `pty_prompt_script` set
`# env: SHELL=/bin/zsh`; `pty_wheel_pager` runs `less`. The offline
run's base (`node:20`) has neither, and there was no network to add
them, so the four failed for the missing binary (`less: not found`; a
blank `terminal (zsh)` pane), not for anything in mnml. The script
installs zsh and less whenever it may use apt (its default, and CI), so
a networked run exercises them; none has yet.

What they need: a networked run to say whether they pass on Linux. And
a file that needs a binary the box may lack would be better announced
as skipped — a `# requires: zsh`, the way `# requires: network` works —
than failed with a screen that does not say why.

### `usage_reset_clock_dst` reads the machine's zone, not the file's

The file sets `# env: TZ=America/New_York`, but that fills the App's
environment map; the offset comes from libc's `localtime_r`
(`src/core/localtime.zig`), which reads the *process's* `TZ`. It passes
on a Mac in US Eastern and fails everywhere else — on the Mac too:
`TZ=UTC mnml test tests/e2e/usage_reset_clock_dst.test` reads the
resets as `3pm` / `5am`.

What it needs: `localtime` taking the zone from the App's environment,
or the runner applying a file's `TZ` to the process for that file. A
harness decision, not a port fix, so not made here.

### cdp: "orphaned Chrome" assumes launchd

`src/cdp/profile.zig` calls a Chrome on the profile an orphan when its
parent is PID 1 — true on macOS, where launchd adopts every orphan. On
a Linux desktop an orphan goes to the nearest *subreaper* (`systemd
--user`, often the terminal), so its parent is not 1: a Chrome left by
a `kill -9` of mnml is reported as `held`, never stopped, and the
browser pane falls back to `chrome-profile-1`. The two unit tests pass
in the container only because `docker run --init` makes a reaping PID 1
the adopter (without `--init` they fail: nothing reaps, and the killed
orphan stays a zombie that `kill(pid, 0)` still answers for).

What it needs: an orphan test that does not name PID 1 — "its parent is
not a live mnml", say. Not changed here: a behaviour decision, and the
Mac's answer is right.

### Zig 0.16: `ECONNREFUSED` from a Unix-socket `connect`

`std.Io.Threaded.posixConnectUnix` does not map `ECONNREFUSED`, which
Linux returns for a socket path nobody listens on (a broker that died,
or a regular file). The SDK broker's `talk` catches it and answers "no
broker", so behaviour is right, but a Debug build prints an
`unexpected errno: 111` stack trace each time (the SDK suite's "no
broker at the path" test shows it). Needs a std fix, or an `S_IFSOCK`
check before connecting.

### mnml-jira: "`d` and `t` fetch off the loop" can hang the unit step

New on main after `8aebbc0f` (`e72b0032`). In one Linux ReleaseSafe
unit run the mnml-jira test binary sat for 53 minutes in that test: the
main thread blocked in a socket read, six Io workers parked on futexes,
and — in `/proc/net/tcp` — the harness's fake Jira listening on
loopback with the test's own connection and its 238-byte request still
in the accept backlog: nothing was accepting. Killed, the step reported
the test `terminated with signal TERM`. The same binary then passed 16
times in a row alone in the container, so it takes load (the build runs
test binaries in parallel) to show.

The shape reads as starvation: the fetches the test starts on the
group, and the fake server's accept, all want the same small Io pool;
when the fetches hold every worker blocking on replies, no worker is
left to accept them. What it needs: the harness server on a thread of
its own (not a pool task), or a request timeout the test can fail on
rather than a read that waits forever. Not changed here — the code is a
day old on main and its owner is better placed.

### A shell pane whose `$SHELL` does not exist is blank

With `SHELL=/bin/zsh` and no zsh the pane opens as `terminal (zsh)` and
stays empty — no "not found", no exit notice. Not Linux-specific (any
bad `$SHELL`).

### Timing tests on a loaded Mac

`app.pty_pane`'s "focus reports" test failed twice, and `app.lsp`'s
fake-LSP end-to-end test once, in macOS Debug unit runs during this
work, with the machine at a load of ~10 from other builds. Both passed
in every Linux run and in the next Mac run; noted because a loaded Mac
is where they showed.
