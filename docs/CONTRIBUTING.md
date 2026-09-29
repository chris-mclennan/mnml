# Contributing to mnml

The working rules, in the order you meet them. The design rationale is
`docs/DESIGN.md`; the conventions a diff is checked against are
`docs/CONVENTIONS.md`; this page is the process around both.

## The shape of the project

mnml 0.3 is the successor to mnml 0.2.x (Rust), not a port of it. Full
parity of capability is the target (`docs/PARITY.md` is the ledger);
structure, internals and formats are free to change where Zig or a
better design warrants it. Two consequences you will feel every day:

- **Config and every persisted file is ZON.** There is no TOML reader
  anywhere in the tree, and none will be accepted. `std.zon.parse` on the
  way in, `std.zon.Serializer` (or the AST-guided splice in
  `src/config/persist.zig`) on the way out.
- **The external surfaces that protect the test oracle are kept.** The
  key-spec grammar (`ctrl+p`, `space f f`), the command ids, the
  `.mnml/ipc/` JSONL protocol and the `.test` directive vocabulary are
  byte-compatible with the Rust build. Everything else is designed fresh.

ghostty is the first-class terminal (kitty keyboard, modes 2026 / 2027 /
2048, OSC 52, kitty graphics), but Windows and Linux users without it
must be fully served: detect at runtime, degrade gracefully, and do not
call a terminal feature done until it has run on all three platforms.

## Worktrees, always

Every task lives in its own worktree under `../mnml-zig-worktrees/<task>/`
on a branch of the same name. Nothing is committed on `main` directly;
the maintainer merges. A worktree that another session might share is a
worktree you do not type into.

```sh
git worktree add ../mnml-zig-worktrees/session-restore -b session-restore
```

## Commits

History is a deliverable. Small commits, one concern each, followable in
`git log --oneline`; a branch is never squashed into a blob. The subject
describes mnml on its own terms — what the change does for a user
or a reader of the code — and the body says why, including any
`// changed:` note where the change departs from `docs/DESIGN.md`. Do
not describe work as "porting"; the Rust code is reference material, not
the thing being built.

Every commit builds and passes the unit tests. Work-in-progress
checkpoints are allowed on a branch (a `wip:` prefix), but they are
rewritten into clean commits before the branch is offered for merge.

Commit messages end with the trailer
`Co-Authored-By: Claude <model> <noreply@anthropic.com>` when a model
wrote the change.

## The oracle

`tests/e2e` is the `.test` corpus: the scripts inherited from the Rust
repo and the ones written here, one real folder (a copy, not a symlink):
1012 `.test` files at the time of writing, every one of which runs at
120×40 but `http/http-bench-running-toast.test` (`# requires: network`)
and, off macOS, the seven that say `# requires: macos`, plus three
parked `.test.*-skip` beside them. The corpus is a regression net,
not a pixel oracle: `expect screen contains`
is substring-tolerant, so a re-skin survives it, and a script that
breaks on a deliberate cosmetic change is updated as normal maintenance
— the commit says so.

```sh
zig build                              # the binary (`./run.sh build`)
./zig-out/bin/mnml-zig test            # the whole corpus at 120x40
./zig-out/bin/mnml-zig test --gate     # the 52-file Phase-0 gate (tools/gate.txt)
./zig-out/bin/mnml-zig test tests/e2e/defaults.test
./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60   # the width sweep (see below: it does NOT check content at 80x24 / 200x60)
zig build e2e -- --filter dap_                                   # the corpus through the build, args passed on
```

The debugger has a real oracle too: `tools/fake_dap/` is
`mnml-fake-dap`, a deterministic Debug Adapter that runs the launched
file as a tiny line-oriented program (its `README.md` has the language
and the requests). `zig build` installs it, `mnml-zig test` exports its
path as `MNML_FAKE_DAP`, and the `dap_session_*.test` scripts seed
`.mnml/config.zon` with `.dap.dbg.cmd = "$MNML_FAKE_DAP"` and a
`prog.dbg` to stop, step, watch, evaluate and set variables through the
real client and panes — no toolchain, the same events on every platform.
A debug-UI change is tested against it, not against a hand-written reply;
`tools/debug-demo.sh [vim|standard]` opens the same seed on a real screen.

The corpus number must not go down: a file that passed before a change
passes after it, and a change that drops one is not finished. A file that is
re-aimed at a deliberate change says so in the commit.

## The sweep and what it proves

`--sizes` runs each file at several screen sizes. It is easy to read a
green sweep as "the chrome is fine at every one of these"; it is not
that, and the report now says so out loud.

**A run's content assertions count only at the size the file was written
at.** That is 120x40 by default — every `expect screen` in the corpus was
written there — or the file's own `# width:` / `# height:` when it names
one. At every OTHER rung of a sweep the checks are evaluated and their
verdict ignored, because a string that fits at 120 columns legitimately
reflows at 80 and a file that asserted on it would fail for no reason.

What a non-asserting rung *does* prove: the App started at that size,
nothing panicked, nothing leaked, no hit rect overlaps another and no
rect was painted outside its parent. That is worth running — it is not
worth calling `ok`:

```
  ok   picker_width.test                          ← checks ran, checks passed
  ok*  picker_width.test @80x24 (structure only)  ← no content was checked
  FAIL picker_width.test @200x60 — line 12: …     ← a real miss at its own size

28/30 passed (10 content, 20 structure-only)
```

The tally keeps `N/M passed` as its first bytes (scripts grep for it) and
then splits M: `content` runs evaluated the file's assertions,
`structure-only` runs did not. `10 content` in a 30-run sweep means
twenty of those thirty runs said nothing about what was on the screen.

### Writing a test that asserts AT a size

Two ways, and they answer different questions.

* **A size-specific content test** — "the dock's labels are gone at 80
  columns", "this menu does not fit a 14-row screen". Give the file its
  own header:

  ```
  # width: 80
  # height: 24
  ```

  The file then runs at that size and no other, a sweep does not move it,
  and every assertion in it counts. This is the one to reach for when the
  bug you are pinning IS the size.

* **A size-independent test you want run everywhere** — every assertion
  in the file would hold at any width (a `status.json` flag, a file on
  disk, a pane title, a short label that cannot reflow). Say:

  ```
  # sizes: all
  ```

  and a sweep evaluates its checks at every rung instead of only at
  120x40, so each rung tests behaviour rather than merely proving nothing
  crashed. Only use it when that is really true: one assertion that
  reflows turns the whole sweep red. `# width:` wins over it — a file
  that names its own size is already asserting at exactly one.

## Quitting inside a `.test`

`expect quit true` / `expect quit false` reads the App's own quit flag —
the same one `status.json` publishes and the headless loop stops on.

Once the App has quit, the runner **stops stepping it**: no more ticks,
no more frames. It used to keep rendering, so a script that quit and then
failed showed a screen belonging to a session that no longer existed, and
`status.json` was the only honest oracle in the room. Any step after a
quit, and any check that needs a fresh frame, now fails with `app has
quit`. `expect quit`, `expect status` and `expect file` still work there —
they read App state and the disk, neither of which needs another frame.

The corpus had one of these already. `quit_prompt.test` pressed the quit
box's **Save all**, which writes every dirty buffer *and ends the
session*, and then went on to assert `expect screen lacks "Quit mnml?"`
and `expect dirty false` — both read off a session that was already over.
The file now ends on the quit, with the two checks that survive it: the
flag, and the files on disk. A quitting action is therefore the LAST
thing a `.test` can do; a second way out of the same box needs a second
file (or a unit test in `cmd_app.zig`, which is where the other three
live).

## Strings that outlive the frame

`FrameArena.begin` is `reset(.retain_capacity)`, so the next frame hands
the same bytes back from offset zero. A slice built on
`app.frame.allocator()` — or a slice of a local `[N]u8` — is therefore
correct for exactly as long as the frame that made it. Give it to
something that keeps it and it paints as garbage on the NEXT frame, only
sometimes: the corpus file passes alone and fails in a full run. Six bugs
of that one shape shipped before the audit existed — a menu's labels, a
graph's date column, a prompt's title, a confirm dialog's strings, a chip
menu's labels, a palette's row menus.

The consumers that keep a slice: a context menu (`MenuItem.label`,
`.copy_text`, `.open_url`), a prompt or confirm overlay's title and
message, a pane or overlay `.title`, a toast that does not expire, a
decoration, a session row, and the screen itself — `putStr` hands
`Canvas.put` the grapheme bytes and vaxis keeps that slice until the
frame is flushed.

Three sanctioned patterns, in the order you should reach for them:

1. **An arena the consumer owns.** Build the strings on a fresh
   `std.heap.ArenaAllocator` and hand it over with the rows:
   `context_menus.openOwned(app, title, rows, x, y, mem)` puts it on
   `MenuState.mem`, which the close frees. Every menu whose labels are
   not literals goes through `openOwned`; `App.openMenu` is for rows
   whose labels are string literals (it dupes only the title).
   `git.openPromptOwned(app, kind, title)` is the same move for a
   prompt.
2. **`gpa.dupe` + free on close.** When the consumer already owns a
   field (`openConfirm`'s `message: []u8`, `Prompt.title_owned`), dupe
   on the gpa at the boundary and free it where the overlay closes.
   `[]u8` in a field means owned; `[]const u8` means borrowed.
3. **`arena.dupe` for the same frame only.** `ui.fmt`, `ui.clipStr` and
   a `dupe` onto `ui.arena` are exactly right for a string the same
   frame paints and nobody keeps. That is what the frame arena is for —
   it is never a finding.

`zig build arena-audit` walks `src/` for the shape and names every site;
`zig build test` runs the same audit as a unit test (`tools/arena_audit.zig`),
and CI runs the step so the hit list is in the log. A test for one of
these fixes must back the frame arena with a `FixedBufferAllocator` —
a `DebugAllocator`-backed `reset(.retain_capacity)` moves the arena's
node, so the dead bytes stay readable and the test passes while the app
paints tofu. Open the thing, swap `app.frame` to the fixed buffer,
`app.frame.begin()`, scribble 1024 × 16 bytes of `'X'`, then assert the
text (`openDiffRowMenu` in `src/app/git.zig` is the model).

## Things a task holds the address of

A worker started with `group.concurrent(io, fn, args)` runs past the
call that started it, and so does everything whose ADDRESS it was given.
`Io.Group` is the sharpest case: the running task holds the group's
address, so a group that MOVES after it has a task is a group whose
`cancel` waits on a task it can no longer see — forever. That is a
wedged quit, with every pool thread idle and the main thread parked in
`Group.cancel`, and it reproduces only when something moved.

The storage that moves in this tree is `PaneStore.slots` — an
`ArrayList(?Pane)`. Opening ANY pane can reallocate it, and every open
pane moves with it. So a pane's group living inside the pane is a bug
waiting for a second pane, and it shipped three times:

- **`GrepPane`** (2026-09-21) — found restoring a Search pane from the
  session file, which opens a pane and then keeps opening panes behind
  it, so the move was the ordinary case rather than a rare race. Its
  `abort` was already heap-allocated, with the reason in a comment; the
  group beside it was not.
- **`SpendPane`** and **`TestsPane`** — the same shape, found by reading
  for it rather than by hitting it.

The rule: **anything a task holds the address of lives on the heap, or
in storage that never moves.** In practice that means a `*Io.Group`
created in `init` and destroyed after the `cancel` in `deinit` (the
`GrepPane` / `SpendPane` / `TestsPane` idiom), a `*Job` in an
`ArrayList(*Job)` rather than an `ArrayList(Job)`, a heap `*Shared` for
a `std.Thread`'s context, or a module-level `var`. `App` itself moves
exactly once — `initWith` returns it by value — so nothing started
inside `initWith` may hold an address into it; every worker starts from
the `startup` hook, after the App is in place (`App.script` re-points
the Lua states for the same reason).

`zig build arena-audit` walks the `Pane` payload types and fails on an
`Io.Group` / `Io.Queue` / `Io.Event` / `Io.Mutex` declared inline in one
of them; `zig build test` runs the same rule as a unit test.

Testing it needs two things the ordinary test does not:

1. **A move that really happens.** Appending until `capacity` changes is
   not enough — the real allocators extend the mapping in place most of
   the time and the pane stays put, so the test passes against the bug.
   `alloc.NoRemap` (`src/core/alloc.zig`) wraps the test allocator and
   declines every in-place grow, which makes the move a fact of the run.
2. **A watchdog.** Call `deinit` on a `std.Thread` and wait on an
   `Io.Event.waitTimeout`; a regression then FAILS in ten seconds
   instead of hanging the suite. Leave the worker parked — do not close
   the pipe it is blocked on — on the failure path: letting it return
   would have it touch the group it was started with, which the moved
   pane no longer owns, and the segfault would land before the runner
   printed its verdict.

`app.spend.test."the spend pane's group survives the pane store moving
it under a live worker"` is the model.

## Child processes

Zig 0.16's `std.process.Child` is not the `Command` you remember from
Rust, and the difference is a crash, not a leak. `child.kill(io)` sends
SIGTERM, **blocks until the child is gone, reaps it**, closes its pipes
and leaves `child.id == null`; it is idempotent. `child.wait(io)` asserts
`child.id != null` on entry. So `kill` followed by `wait` aborts the
process every single time — that was the browser pane's tab-close crash
(`Launch.kill` did exactly that; `Abort trap: 6` through
`debug.assert → Child.wait`). Three rules:

- **Kill reaps. Never `wait` after `kill`.** A child you are done with
  and never waited on is `child.kill(io)` and nothing more.
- **`wait` only on a child you did not kill.** `defer child.kill(io)`
  above a `wait` is fine — after the wait the kill sees a null id and
  does nothing — and is the right shape for an early return.
- **A cancelled `wait` reaps nothing.** It clears `child.id` and returns
  `error.Canceled` with the process untouched, so the `kill` that looks
  like it covers that path is a no-op. Take `child.id` before the wait
  and hand it to `core/child.zig`'s `reapAbandoned` on the error path
  (`integration_poll.zig`'s worker and `bridge/host.zig`'s reader are the
  models). `core/child.zig`'s `goneWithin(io, pid, deadline)` is how a
  test holds that a child was really taken down.
- **A child you do not control is stopped with `core/child.zig`'s
  `terminate`, not `kill`.** `kill` waits for the SIGTERM to be acted on;
  a Chrome wedged on a keychain prompt never acts on it, and closing its
  pane froze the app for good. `terminate` sends SIGTERM, gives it a
  bounded grace (polling `waitpid(WNOHANG)`), then SIGKILLs and reaps;
  with `.group = true` it signals the child's own process group (spawn
  it with `.pgid = 0`), so the helpers it started go too.

A cancelled task is still being signalled. `Io.Group.cancel` keeps
sending SIGIO to a worker's thread until the task is seen to finish —
`Io.Threaded`'s no-op handler turns each into an EINTR in whatever
syscall the thread is in — and one of them lands after the `wait` has
already come back `Canceled`, in the `waitpid` of the reap that
follows. `reapAbandoned` took that EINTR for done: the SIGKILL had been
sent, the child died, nobody reaped it, and a zombie is a pid
`kill(pid, 0)` still calls there. Two tests failed on it only under
load (`integration_poll.zig`'s "reaps its child" and `bridge/host.zig`'s
"outlives goodbye"), one run in twenty at a load average past 20, and
a 10 s deadline on the check did not help — the child was dead the
whole time. Any raw `waitpid` on this path retries EINTR
(`core/child.zig`'s `reap`); `Child.kill` already does.

A test that holds a child was taken down asserts through
`core/child.zig`'s `goneWithin(io, pid, .fromSeconds(10))`, not `gone`
after a fixed sleep. `Child.kill` and `reapAbandoned` both return
reaped, so a healthy run pays nothing — `gone` is true the instant they
return — and the deadline is only what a wrong answer costs: a real
orphan, or a zombie, is still there when it runs out. Do not tune the
deadline down to make a test faster; it is not the cost.

## Tests

- Unit tests run on `std.testing.allocator` only; a leak is a failure.
  `page_allocator` is for pty ring buffers and nothing else. The one
  exception is a property test's oracle: its copies and scratch views
  may come from a local `DebugAllocator(.{ .stack_trace_frames = 0 })`
  that the test checks for leaks itself (the undo property) — the code
  under test stays on `testing.allocator`. In Debug the per-allocation
  stack capture is a DWARF unwind on macOS, and an oracle that allocates
  per entry per step spends minutes in it.
- Test the shipped default, not values around it. `tests/e2e/defaults.test`
  and the `"defaults are the shipped values"` test in
  `src/config/Config.zig` pin `Config{}`; a default that changes on
  purpose changes there in the same commit.
- Two optimize modes: `zig build test -Doptimize=Debug` and
  `-Doptimize=ReleaseSafe` (what ships). A test that passes in one and
  not the other is a bug in the code, not the test.
- `zig build unit` runs every unit test binary and nothing else; `test`
  is `unit` plus the e2e gate. `zig build unit-debug` is `unit` in
  Debug whatever `-Doptimize` says, and `tools/debug-suite-check.sh`
  runs it with a last line a chain can stop on — `unit debug: ok (Ns)`
  or `UNIT DEBUG FAILED (exit N, Ns)`; `./run.sh check` runs it beside
  the ReleaseSafe suite. The Debug suite is sized to a few minutes and
  no test in it should take 30 s: a test whose work explodes at -O0 or
  under the testing allocator's per-allocation stack capture scales
  its input for `builtin.mode == .Debug` (and says so) rather than
  dropping the check, and the optimized run keeps the full size.
- One test: `MNML_TEST_FILTER=<substring> zig build unit -Dtest-trace`
  — see "Running one test" below for why not `-Dtest-filter`.
- `zig build test --summary all` prints one line per test binary and
  the total — read the count there rather than from a page that
  cannot keep up with it.
- `docs/CONFIG.md`'s `zon` block is decoded by a test
  (`docs config example parses clean`), so a new `Config` field goes
  into the block in the same commit, at its default with one line of
  meaning.

## Break-checks

A test only counts once it has been seen to fail. For every behaviour
test, revert or break the fix, watch the test fail, and confirm the break
really landed — a `zig fmt` reflow has moved the line under a sed
expression before, and the "failing" test was then passing against
untouched code.

`tools/break-check.sh` does this mechanically and refuses the four false
passes:

```sh
tools/break-check.sh "isNewer" src/app/update.zig 's/\.eq => l\.pre and !r\.pre,/.eq => false,/'
```

It applies the break to a scratch copy, swaps it in, runs the named
tests (`MNML_TEST_FILTER=<name> zig build unit -Dtest-trace`), asserts
the run fails, restores the file on every exit path, and runs the same
tests once more to see them pass on the untouched file. Exit 2 means
the sed expression changed nothing; exit 3 means the broken copy did
not compile (a compile error is not the test failing); exit 4 means the
filter matched no named test — "filter matched no test — vacuous" — in
either run; exit 5 means the test fails on the restored file too. It
reads the runner's `filter <name>: K of M tests matched` lines and
needs K to reach 1 across the binaries, plus at least one named test
printed, before it believes a run. Put the invocation, or its output,
in the commit body or the PR. `tools/break-check-selftest.sh` replays
canned runner output through a fake `zig` and checks every verdict.

## Running one test

```sh
MNML_TEST_FILTER=<substring> zig build unit -Dtest-trace
```

`-Dtest-trace` swaps in `tools/test_runner.zig`, which prints each
test's name before it runs and filters at run time: the substring is
matched against the fully qualified name, `<module>.test.<name>` —
`app.update.test.isNewer: semver order …` — so a module or file name
narrows it as well as words from the test's name. Every test binary
prints `filter <substring>: K of M tests matched`; a `K` of 0 in all
of them is a filter that hit nothing, not a pass. There are around
twenty binaries and most hold nothing a given filter matches, so a wall
of `0 of M` above the one that matched is the normal shape — read the
last summary, not the first.

The verdict lines name their test, so `grep -E "FAIL|passed;"` over a
trace reads straight. Do not attribute a failure to the `▶` start line
nearest it in a *filtered* stream: the two can be thousands of lines
apart in the real output. Exactly one test name contains the word FAIL
(`runPath: skips, sizes, names, and the ok/ok*/FAIL/N-M report`), so it was
the name every such grep window kept pairing with somebody else's
failure.

A test that fails is run once more, afresh (its own testing allocator
and `Io` again): a pass on the retry prints `FLAKY <test> — first run:
<error>` where it happens and again under the summary, which ends
`N passed; S skipped; F failed; K FLAKY.` — a flake is counted and
named, never folded into `passed`, and does not fail the run. It is
still a bug to go and find. `MNML_TEST_STRICT=1` retries nothing
(`tools/break-check.sh` runs under it: a break has to fail the first
time); a test that panics takes the process down and is not retried.
`tools/debug-suite-check.sh` and `./run.sh check`'s ReleaseSafe step
both run the suite under this runner, so both modes report alike.

Under `zig build`, the trace binaries run in parallel with their output
captured, and a last step (`tools/trace_report.zig`) prints each one's
trace when all are done; a failing binary's trace is printed by the
build runner as it fails. (A run that inherits the terminal holds the
build runner's stderr lock for its whole run: streamed live, the
binaries ran one after another and the ReleaseSafe suite took half as
long again.) To watch a hang name its test as it happens, add
`-Dtest-trace-live`: the old live stream, one binary at a time.

Do not reach for `-Dtest-filter=<substring>` to run one test. It is
the compiler's own filter and it is applied while files are scanned,
and the compiler only scans a file something references: with no
filter, every test's body is analysed and the files they use come
along, but under a filter the analysis roots shrink to the unnamed
`test { _ = @import(…); }` reference blocks plus the tests that
matched. A test in a file no reference block names — `app/git_palette.zig`,
`ui/git_palette.zig`, `ui/help_overlay.zig` are three — is then never
scanned, its name is never compared, and the run reports the reference
blocks alone as passing. That is why `-Dtest-filter="colors on screen"`
ran nothing while `-Dtest-filter=colors` found the same test: other
matching tests happened to pull its file in. `-Dtest-filter` still
narrows the e2e corpus by file name, which is what it is for.

A seeded test reads `std.testing.random_seed`. Under the default
runner that is the build's `--seed` (`zig build unit --seed 0x6fc0c5a4`);
the build never hands a seed to the trace runner, so there it is 0
unless `MNML_TEST_SEED=<n>` names one, and the runner prints
`seed 0x…` once per binary when it is set. The undo property prints
its round's seed and the run's seed when a round fails:

```sh
MNML_TEST_SEED=0x6fc0c5a4 MNML_TEST_FILTER="undo property" zig build unit -Dtest-trace
```

## Running it

`./run.sh` is the launcher: it builds ReleaseSafe only when a file under
`src/`, `sdk/`, `integrations/`, `tools/` or `build.zig*` is newer than
`zig-out/bin/mnml-zig` (one line says which, or that the binary is
current), runs the binary on the directory you invoked it from, and
relaunches it on exit 75 — the restart handshake the `app.restart`
command and `./run.sh restart` both use. Any other exit ends the loop.

```sh
./run.sh [WS] [--input vim|standard] [--ascii] [--config PATH] [--sandbox]
./run.sh restart | stop | status       # the running instance, through its marker + IPC
./run.sh fresh [WS]                    # --no-session: skip the session restore
./run.sh headless [WS]                 # the loop with --headless
./run.sh shot [OUT.png]                # scripts/shot.sh — the real ghostty window
./run.sh build | release | test | check | stale | clean [incremental|all] | menu
```

The app writes `${TMPDIR:-/tmp}/mnml-zig-running-$USER.workspace` when the
terminal loop starts (the workspace's real path, no trailing newline) and
removes it on a clean exit — not on a restart. A `--sandbox` launch writes
no marker (docs/CONFIG.md, *Sandbox*), so these verbs never reach it. `restart` and `stop` drop
`{"cmd":"restart"}` / `{"cmd":"quit"}` in `<ws>/.mnml/ipc-zig/command`;
the terminal loop tails that file for those two lines only (the headless
loop takes the whole command set). `MNML_BIN`, `MNML_IPC_SUBDIR`,
`MNML_IPC_DIR`, `MNML_ZIG`, `MNML_OPTIMIZE` and `MNML_PROFILE`
parameterize the wrapper (a launch defaults to the dev profile — see
below; the build / test / check / install verbs never set it);
`tools/run-sh-check.sh` exercises every non-interactive verb on a
throwaway workspace with all of them pointed at a tempdir, and
`tools/pty-lifecycle.py` proves the marker on a real pty.

## Daily driver + development on one machine

You want to *use* mnml all day and *change* it on the same laptop,
without a rebuild yanking the editor out from under you. Two things
make that work: an install, and a profile.

**Live in the install.** `./run.sh install` copies a verified
ReleaseSafe build to `~/.local/bin` (`PREFIX` to move it) — the host as
`mnml`, the shipped integrations beside it, `share/mnml/…` — and points
the stable profile's integration links at `PREFIX/bin` instead of a
repo's `zig-out`. That last part is why the verb exists: the links used
to point into this tree, so a rebuild here swapped the integrations
under the running copy.

```sh
./run.sh install --dry-run       # every copy, manifest and link; changes nothing
./run.sh install                 # the real thing
./run.sh installed-status        # what is installed, against this tree's HEAD
```

It refuses to install from a dirty tree or a Debug build
(`--allow-dirty` overrides both), and refuses to overwrite a
`PREFIX/bin/mnml` that does not answer `--version` as an mnml-zig
(`--force` overrides that) — on a machine that still has the Rust
`mnml` at `~/.local/bin/mnml`, that refusal is the point.

**The symbols font is its own verb.** mnml paints its own block out of
`MnmlSymbols.ttf` — the tree connectors, the terminal mark, the
unfocused pty pane's hollow cursor — and a terminal only finds that
file in the OS font directory. `install` puts it under
`PREFIX/share/mnml/fonts/` and PRINTS the next step; it never writes
outside `PREFIX`.

```sh
./run.sh install-font --dry-run  # the backup and the merge; changes nothing
./run.sh install-font            # ~/Library/Fonts, or ~/.local/share/fonts
```

It MERGES rather than copies over. An already-installed MnmlSymbols may
carry codepoints this repo has no source for — the Rust-era integration
chips around `U+F1C03…F1F00` — so the file is read back
(`src/glyph/ttf.zig`'s reader), folded into what this build bakes
(`builder.merge`: keep theirs, replace ours, add the new, drop an
outline no cmap reaches), and written through a temp file, with the old
one copied to `~/Backups/mnml-zig/fonts/` first.

**A mark is placed by its own `Fit`, and the shipped boxes are pinned.**
`place` scales each SVG uniformly — aspect always kept — to the tighter
of a height band and a width cap, centred on 0.36 em; the art decides
which binds. One `Fit` for every mark did not work: the ghost is taller
than it is wide, so it stops at the height band, while the wide Claude
figure runs into the width cap and comes out not much over half the
ghost's height. So the ghost carries `builder.ghost_fit` (a 0.72 em
band) and the figure `builder.figure_fit` (a 1.30-advance cap); the
square marks keep the default. `builder.placedBox` measures where a
mark lands and `builder.pins` holds every shipped box in em to ±3 % —
run `MNML_TEST_FILTER="placed box is pinned" zig build unit -Dtest-trace`
to print the table (the trace runner is what turns the print on;
`MNML_GLYPH_BOXES=1` does the same under the default runner). A new
mark needs a pin of its own, and a `Fit` edit needs its pins moved on
purpose. Terminals read the
font directory at launch, so restart yours. Without the face the
affected glyphs fall back — the hollow cursor to `▯` — rather than
rendering as `?`; `:integrations.audit_glyphs` says which are at risk.

**Develop in the dev profile.** `./run.sh` launches with
`MNML_PROFILE=dev`, which moves every name the two copies could fight
over: `~/.config/mnml-dev` for state, `.mnml/session-dev.zon` for the
session (so the same workspace open in both keeps two layouts), the
`ipc-zig` mailbox, the `mnml-zig-running-…` marker. The first dev
launch seeds itself from your stable config and says so; see
`docs/CONFIG.md`, "Profiles", for exactly what travels and what never
does.

**Which one am I in?** The statusline paints a `dev` chip beside the
mode and the window title reads `mnml [dev] — work`. From a shell,
`mnml profile` prints the profile, its data root, session file, mailbox
and marker. Nothing is painted in the stable profile: that one you are
meant to forget is a choice.

**The loop.** Live in `mnml`. Work in `./run.sh`. When a change has
been through the gate below, `./run.sh install` and the daily driver
catches up — the running stable instance keeps running the binary it
started with until you quit it.

**Windows: `run.ps1`, the same four verbs.** `run.sh` is bash, so the
daily-driver half of it has a PowerShell twin — `install`,
`install-font`, `installed-status`, `profile` — with the same
semantics, the same three refusals and the same `-DryRun` plan.
PowerShell 5.1 and 7 both run it; no modules.

```powershell
.\run.ps1 install -DryRun        # every copy, manifest and plan step
.\run.ps1 install                # default prefix %LOCALAPPDATA%\Programs\mnml
.\run.ps1 install-font           # per-user font dir + the HKCU registration
.\run.ps1 installed-status
.\run.ps1 profile                # data root, session, mailbox, %TEMP% marker
```

Three differences, all because Windows differs: the prefix default,
`<data root>\bin\<name>.exe` being a copy rather than a symlink (a
symlink needs Developer Mode; `linkBeside` already falls back to
copying for the same reason), and `install-font` having to register the
face under HKCU as well as write the file — a file alone is not an
installed font there. The restart loop, `headless`, `shot`, `clean` and
the IPC verbs stay bash-only.

`run.ps1` has **never been executed**: there is no PowerShell on the
author's Mac. `tools/run-ps1-check.py` (a structure check — balance,
quoting, the 5.1-incompatible spellings, every verb reachable, the
refusals and plan phrases present) runs in `./run.sh check`;
`tools/run-ps1-check.ps1` is the real one and waits for a Windows
guest. `docs/INSTALL-CHECKLIST.md` → *Windows 11* step W-0 runs it
first thing. `docs/WINDOWS.md` has the rest of the Windows picture.

**A clean machine.** `docs/INSTALL-CHECKLIST.md` is the per-OS
first-run checklist — macOS, Ubuntu, Windows 11, one numbered list
each, with what a pass looks like per step, and the UTM
pristine-snapshot routine the guests are kept on. Walk it after
anything that touches install, the font, the first-launch wizard or a
platform backend.

## The gate — the verification sequence

Before a branch is offered, in this order. The maintainer's chain runs
exactly these steps, one after the other, before every merge:

1. `tools/work-data-audit.sh` — no tracked file holds text from anyone's
   day job (the patterns live outside the repo; with none configured it
   says so and passes);
2. `zig fmt --check build.zig build.zig.zon src themes tools integrations sdk`;
3. `zig build arena-audit` — three walks, all `--strict`: frame-arena
   and stack strings reaching a consumer that outlives the frame, over
   `src/`; a job result's arena let go by a consumer that kept a slice
   out of it, over `integrations/` and `sdk/`; and an `Io.Group` /
   `Io.Queue` / `Io.Event` / `Io.Mutex` declared by value in a `Pane`
   payload, over `src/` (*Strings that outlive the frame* and *Things a
   task holds the address of*, above);
4. `zig build -Dpartial=false` — every command id has a runner (a spec
   without one is a compile error);
5. `zig build test -Doptimize=ReleaseSafe -Dtest-trace` — every unit
   test binary plus the e2e gate, in the mode that ships, naming each
   test as it runs so a hang names its test (only the exit code is
   evidence; `-Doptimize=Debug` is worth a run too — a test that passes
   in one mode and not the other is a bug in the code);
6. every shipped target's compile: `zig build gate-targets` —
   `gate-build` (the exe, every test binary, the integrations) for all
   five targets, one after another. Zig's lazy analysis only checks
   target-gated code when that target is built: a Windows arm, a
   Windows-skipped test, or a libc call Linux needs spelled out is
   invisible to a native build (`docs/PORTABILITY.md`). One target:
   `zig build gate-build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe`;
7. `zig build glyph-audit` — every Nerd Font literal in `src/`, the SDK
   and `integrations/` against `data/nerd-glyphnames.json`, with its
   `--ascii` twin;
8. `zig build -Doptimize=ReleaseSafe` — the binary the next three steps
   run on, the one that ships;
9. the sweep: `./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60`
   — the Phase-0 gate (`tools/gate.txt`) at three sizes.
   **A sweep rung other than the file's own size checks no content**: it
   asserts no panic, no leak, no overlapping hit rect and no rect painted
   outside its parent, and nothing about what was on the screen. Those
   runs report `ok*  <name> @80x24 (structure only)`, never plain `ok`,
   and the tally says how many of each (*The sweep and what it proves*,
   below);
10. the corpus: `./zig-out/bin/mnml-zig test` — no file that passed
    before may fail;
11. `tools/pty-mouse-check.py` — the real binary in a pty answering the
    probes like ghostty; one click opens a file, a right-click opens the
    row menu, a wheel notch reaches the app;
12. the two integrations' own suites: `zig build test` inside
    `integrations/bitbucket` and inside `integrations/jira`;
13. `tools/run-sh-check.sh` — the launcher's verbs on a throwaway
    workspace, the marker and the IPC lifecycle included;
14. `zig build docs` leaves `docs/commands.md` unchanged — a new or
    renamed command id is committed with the regenerated file.

Beyond the chain, run these when the change reaches what they check:

- `zig build chrome-audit` — chrome a component owns, drawn by hand
  somewhere else: a box-drawing glyph as a whole literal outside the
  frame modules, an `if (ascii) "…" else "…"` pair `clip` / `border` /
  `overlay.hintText` already answers, over `src/`, `sdk/` and
  `integrations/` (`docs/CONVENTIONS.md` → *If a thing has a component,
  draw it through the component*; the same walk is a unit test, so
  step 5 fails on a new fork before this names it);
- `zig build hover-audit` — every hoverable target against the info
  view's dictionary; fails on a new target with no entry that
  `docs/hover-help-todo.txt` does not list, on a shortcut row naming an
  unbound command, and on a `docsSection` link to a heading
  `docs/CONFIG.md` lacks (*Adding hover help for a control*, below);
- `tools/pty-cursor-check.py` (and `MNML_INPUT_STYLE=vim` again) when
  the change touches the cursor — the same pty, reading the show/hide,
  the DECSCUSR and the CUP mnml writes: headless draws no cursor, so
  nothing in the corpus can see those bytes;
- `tools/ui-diff.sh` on every `docs/ui-spec/steps-*.jsonl` when the
  change touches chrome (see *Spec dumps* below) — the diff counts must
  not grow;
- `tools/run-ps1-check.py` — what can be checked about `run.ps1`
  without a PowerShell: balance, quoting, the 5.1-incompatible
  spellings, every verb reachable, and the refusals, build lines and
  plan phrases present by name. `tools/run-ps1-check.ps1` is the real
  check and runs on the Windows guest
  (`docs/INSTALL-CHECKLIST.md` → *Windows 11*, step W-0).

`./run.sh check` is a one-line subset on this machine: `zig fmt --check
src build.zig tools`, the unit suite in Debug (`tools/debug-suite-check.sh`),
the e2e gate in Debug, the unit suite in ReleaseSafe, the ReleaseSafe build, the sweep, the corpus (with `MNML_E2E_ALLOW_SHELL=1`),
glyph-audit, chrome-audit, hover-audit, `zig build gate-targets`,
`tools/run-sh-check.sh` and `tools/run-ps1-check.py`. `zig build check` is the older one-step form
(fmt, Debug + ReleaseSafe unit tests, the gate, the sweep,
`tests/e2e/defaults.test` and the whole corpus on the exe of that
invocation).

## Running the gate on Linux

Everything above runs on the author's Mac. The Linux and Windows targets
are otherwise only ever *compiled* (`gate-build`), and a target that
compiles is not a target that runs: the first Linux run of this gate found
a `pthread_create` that refused the pty reader's stack — every terminal
pane aborted the process — plus a `@constCast` const global written
through, a double free, a test that only passes on a case-insensitive
filesystem, and four more.

`tools/linux/run.sh` is that run, in a container, from a Mac or from
Linux:

```sh
tools/linux/run.sh all        # build · -Dpartial=false · glyph-audit · arena-audit · chrome-audit
                              #   · ReleaseSafe · the unit suite · the gate · the corpus
tools/linux/run.sh build      # the builds (debug, -Dpartial=false, ReleaseSafe) and the three audits
tools/linux/run.sh unit       # zig build test -Doptimize=ReleaseSafe
tools/linux/run.sh gate       # the sweep at 80x24,120x40,200x60
tools/linux/run.sh corpus     # the whole .test corpus (~12 min)
tools/linux/run.sh mouse      # tools/pty-mouse-check.py, on a real pty
tools/linux/run.sh fmt        # zig fmt --check
tools/linux/run.sh shell      # a prompt in the container
tools/linux/run.sh raw CMD…   # anything, in the container
```

It needs `docker` (or `podman`, via `MNML_LINUX_ENGINE=podman`). The image
is a current Debian with the pinned Zig, `git`, `python3`, `bash`,
`nodejs`/`npm` — the corpus drives `npm test` — and both font sets the
glyph checks want. The repo is mounted **read-only** and rsync'd into a
container-local copy, so a Linux run never touches the host's
`.zig-cache` or `zig-out`; the package cache and the build cache are
docker volumes, so only the first run pays for fetching dependencies.

For the whole sequence unattended on a commit — `git archive HEAD` into
a fresh container, both unit modes, the gate, the corpus,
`tools/run-sh-check.sh`, the integrations, each step's exit code and log
in `.verify/linux/` — use `tools/linux-verify.sh` (`docs/CONVENTIONS.md`,
"Verification on Linux"; what its first run found is in
`docs/PORTABILITY-linux.md`).

Give the VM room. A single `-Doptimize=ReleaseSafe` compile of
`mnml-zig` is OOM-killed under 8 GB (`error: process terminated with
signal KILL`), and the two build caches together want ~15 GB of disk:

```sh
colima stop && colima start --cpu 8 --memory 24 --disk 85   # or Docker Desktop's Resources pane
```

A file whose screen only one platform can paint carries
`# requires: macos` (or `linux` / `windows`) in its header block and is
announced as skipped elsewhere, the way `# requires: network` already is.

**Run the corpus against an optimized build.** `zig build e2e` and
`zig build check` take `-Doptimize` from the command line and default to
Debug, where the app is an order of magnitude slower — and every timing
in the corpus is the shipped build's. The runner scales its own
deadlines (`debug_slowdown`) and prints that it is a Debug build, but a
script's `wait <ms>`, and the `--lifetime-secs` it gives its offline
server, are written into the file and cannot move. A file pinned that
way carries `# requires: optimized` and is announced as skipped against
a Debug build rather than failing on the clock. No file carries it
today. So:

```sh
zig build e2e -Doptimize=ReleaseSafe      # the run whose green means something
```

**Wait on a condition, not a clock.** An `expect` polls — up to 3 s,
answering the moment it holds — and a `wait <ms>` sleeps its full
count whether or not it was needed and then asks once. A step that is
slow for a reason (an integration child's startup, a refetch against
an offline server) gets `expect within <ms> <expectation>`: the same
check with its own, longer budget, so a loaded machine gets the time
and an idle one pays nothing. A fixed `wait` before a plain `expect`
is only honest for something with no observable end.

A timing failure from a Debug run is not a finding until it reproduces
there. It has now read as "fails only in a worktree" three times over;
it was never the path.

**But "only in Debug" is not the same as "only about the clock."** The
twenty-four `integrations_*` and `statusline_hover_*` files — real
integration children against offline servers they start themselves —
carried `# requires: optimized` for exactly one release, on the reading
that they were timing-marginal: which member fell over moved between
runs, and every one passed against ReleaseSafe. They were not
timing-marginal. The child was dying, and the host, which can only see
its end of the socket, could only say `[connection closed]`; the
child's own stderr went to `/dev/null`, so its reason was never read.
Two bugs, each of which a shipped build hides:

- The Bitbucket pane stored the statusline values by value and let the
  result's arena go with `commit`. The chip is published later and
  reads those titles again, so it read freed memory — bytes that
  usually still say what they said, and sometimes a segfault.
- The Jira pane closed the mount socket while its inbox task was still
  parked in a read on it. The read then fails `EBADF`, which a Debug
  build treats as a programmer bug and panics on; a shipped build
  returns the error.

So when a Debug e2e run says `[connection closed]`, read the child
before reaching for the clock:

```sh
MNML_CHILD_STDERR=/tmp/child zig build e2e -- tests/e2e/some.test
cat /tmp/child.*       # one file per mounted child, in spawn order
```

`MNML_CHILD_STDERR` (`src/bridge/host.zig`) is off unless set, and a
normal run is unchanged: a sibling's stderr goes to `/dev/null` because
writing to the terminal would scribble over the screen mnml is
painting.

CI runs the corpus optimized: the Linux full-corpus leg builds
ReleaseSafe, and the macOS/Windows job installs ReleaseSafe before its
`--gate` sweep. The Debug compile stays covered there by `zig build
test -Doptimize=Debug`.

## Spec dumps

The same-look tracks are measured against the Rust editor's screen,
not described from memory. `docs/ui-spec/README.md` lists every dump
and the steps file that produced it.

```sh
tools/ui-diff.sh WS RS_DATA ZIG_DATA docs/ui-spec/steps-palette.jsonl 120x40
    # both binaries headless on one workspace + config, one JSONL of IPC
    # commands each, a row-by-row diff; the session is snapshotted around it
tools/zig-spec.sh debug-stopped 120x40
    # a Zig-only screen (the debugger — nothing on the Rust side to diff
    # against): headless on a throwaway workspace wired to the fake
    # adapter, kept as docs/ui-spec/zig-<name>-<size>.txt — the dump IS the spec
tools/debug-demo.sh vim
    # the same seed on a real screen, deleted when mnml exits
```

`MNML_RUST_BIN` / `MNML_ZIG_BIN` point the scripts at other binaries.

## Docs

`docs/commands.md` is generated: `zig build docs` regenerates it from
`src/commands/specs.zig`, and the generator's own test asserts every id
and every group appears. Do not edit it by hand; add the id to the spec
table and rebuild. `docs/PARITY.md` is the parity ledger the cutover
decision reads — a row moves from `missing` to `done` in the commit that
lands the runner, never before, and its pointer column names the file
and the test. `docs/DESIGN.md` is the plan: it is annotated with dated
`*// changed:*` notes where the tree departs from it, never rewritten.
`docs/KEYMAP_PROFILES.md` lists every chord that differs between the
profiles; the debugger's and the section-move chords are pinned by
tests (`src/app/cmd_dap.zig`, `src/app/side.zig`).

## Adding a shipped integration

An integration mnml ships is three things, and all three are in this
repo:

1. **`integrations/<id>/`** — a `build.zig`, a `manifest.zon` (plus
   `manifest_*.zon` for each extra chip the one binary registers) and
   the source. `<binary> --install` writes those manifests into the
   data root; that file is the interface (`docs/SDK.md`).
2. **`build.zig`** — the executable, and a `build_options` path to it
   for the corpus (`sample_integration_exe`, `jira_integration_exe`, …)
   when a `.test` needs to point a manifest at a prebuilt binary.
3. **`data/marketplace.zon`** — one entry, so the INTEGRATIONS
   section's Marketplace tab lists it out of the box. One entry per
   BINARY, not per manifest: `mnml-jira` writes three manifests and is
   one row.

```zig
.{
    .id = "jira",                 // a file name; the row's id, not a manifest id
    .label = "Jira",
    .description = "…",
    .category = "tracker",
    .version = "0.2.0",           // MUST match the folder's manifests
    .binary = "mnml-jira",        // MUST match the folder's manifests
    .docs = "https://…",
    .chip = .{ .glyph = "\u{f0303}", .fallback = "J", .color = "blue" },
},
```

The `version` and `binary` are held against the folder's own manifests
by a test in `src/app/marketplace_catalogue.zig` — a drift there is
what would make a freshly-installed row say `update available` forever
— and the same test pins the number of entries, so a new one is a
deliberate edit in two places.

`run.sh install` reads `integrations/*/manifest.zon` for the binary
name, installs each binary to `PREFIX/bin`, runs `--install` and
relinks `<data root>/bin/<name>`. Nothing there needs editing; an entry
whose `.category` is `sample` is installed as a binary but not
registered (a fixture is not a chip on anyone's rail).

## Adding hover help for a control

Every hoverable control has an entry in the info view's dictionary
(`docs/CONVENTIONS.md` → *Hover help*). When you add a chip, a button, a
menu row or a Settings row:

1. Run `zig build hover-audit`. It walks every target and fails with the
   new one's key — `button:my_chip`, `menu:tests/Run twice`,
   `settings:row:ui.my_flag`.
2. Write the entry in the area module under `src/app/info_view_copy/`
   (`chrome.zig` for a `render.Button`, `menus.zig` for a menu row keyed by
   the menu's title and the row's label, `statusline.zig` for a segment,
   …). Title, two to four sentences about this control in this state, the
   click and the right button, the caveat; `keys` as `CommandId`s (the
   lint rejects an unbound one); one to three typed `links` — the next
   command, a `settingsRow("…")`, a URL, `comptime copy.docsSection("…")`
   for the docs/CONFIG.md section that explains the thing (the lint
   rejects a heading the manual lacks), or `copy.ask_link` where a user is
   likely stuck (a failure, a conflict, a rate limit). Every `&.{ … }`
   links array must be comptime-known — a runtime call in one is a stack
   temporary the entry outlives, which is why the helpers are called with
   `comptime`.
3. A Settings row needs nothing: its entry is generated from its label,
   docs/CONFIG.md's comment for the key, its choices and its value. Add a
   `hand_written` row in `info_view_copy/settings.zig` when the generated
   words are not enough.
4. Run `zig build hover-audit` again (and `zig build unit
   -Dtest-filter="the audit"`). If the entry is deliberately deferred,
   add the key to `docs/hover-help-todo.txt` instead — the audit then
   passes and the backlog shows it.

Check the words in the app: hover the control and read the box; hover a
`✦ Ask Claude about this` row and read the prompt it sends
(`info_view_copy.askPrompt`) — it should name the state, not define the
control.

## Subagents

Leaves are delegated by default; the serial trunk design is the one
exception. Brief an agent with the file list it may touch, the tests it
must run in the foreground (a backgrounded check that "waits for the
notification" is a check that never ran), and the break-check it owes.
Verify its claims by grepping the source before repeating them: a report
that says "done" is a claim, `pub const table = .{ .@"ns.verb" = &fn }`
is evidence.
