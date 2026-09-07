# Contributing to mnml-zig

The working rules, in the order you meet them. The design rationale is
`docs/DESIGN.md`; the conventions a diff is checked against are
`docs/CONVENTIONS.md`; this page is the process around both.

## The shape of the project

mnml-zig is the successor to the Rust `mnml`, not a port of it. Full
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
describes mnml-zig on its own terms — what the change does for a user
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
394 `.test` files at the time of writing, 393 of which run at 120×40
(`http/http-bench-running-toast.test` is `# requires: network`), plus
three parked `.test.*-skip` beside them. The corpus is a regression net,
not a pixel oracle: `expect screen contains`
is substring-tolerant, so a re-skin survives it, and a script that
breaks on a deliberate cosmetic change is updated as normal maintenance
— the commit says so.

```sh
zig build                              # the binary
./zig-out/bin/mnml-zig test            # the whole corpus at 120x40 (~2.5 min)
./zig-out/bin/mnml-zig test --gate     # the 47-file Phase-0 gate
./zig-out/bin/mnml-zig test tests/e2e/defaults.test
./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60   # the width sweep
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

The corpus number must not go down. 393/393 is the current line
(2026-09-07); a change that drops it is not finished. A file that is
re-aimed at a deliberate change says so in the commit.

## Tests

- Unit tests run on `std.testing.allocator` only; a leak is a failure.
  `page_allocator` is for pty ring buffers and nothing else.
- Test the shipped default, not values around it. `tests/e2e/defaults.test`
  and the `"defaults are the shipped values"` test in
  `src/config/Config.zig` pin `Config{}`; a default that changes on
  purpose changes there in the same commit.
- Two optimize modes: `zig build test -Doptimize=Debug` and
  `-Doptimize=ReleaseSafe` (what ships). A test that passes in one and
  not the other is a bug in the code, not the test.
- `-Dtest-filter=<substring>` runs the matching tests only.
- `zig build test --summary all` prints one line per test binary; the
  total is 1205 tests (1203 pass, 2 skip) at the time of writing.
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

`tools/break-check.sh` does this mechanically and refuses the two false
passes:

```sh
tools/break-check.sh "isNewer" src/app/update.zig 's/\.eq => l\.pre and !r\.pre,/.eq => false,/'
```

It applies the break to a scratch copy, swaps it in, runs the named test,
asserts the run fails, and restores the file on every exit path. Exit 2
means the sed expression changed nothing; exit 3 means the broken copy
did not compile (a compile error is not the test failing); exit 4 means
no test matched the name. Put the invocation, or its output, in the
commit body or the PR.

## The gate — the verification sequence

Before a branch is offered, in this order (each step runs on what the
step before it proved):

1. `zig fmt --check src build.zig tools`;
2. `zig build test -Doptimize=Debug`, then `zig build test -Doptimize=ReleaseSafe`;
3. `zig build -Doptimize=ReleaseSafe` — the binary the next two steps
   run on, the one that ships;
4. the sweep: `./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60`
   — the Phase-0 gate (`tools/gate.txt`, 47 files) at three sizes;
   content assertions hold at 120x40, the other sizes assert no panic,
   no leak, no rect painted outside its parent;
5. the corpus: `./zig-out/bin/mnml-zig test` (393/393);
6. the Windows gate: `zig build gate-build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe`
   — the exe and every test binary compiled, not run (Zig's lazy
   analysis only checks target-gated code when that target is built);
7. `zig build glyph-audit` — every Nerd Font literal in `src/` against
   `data/nerd-glyphnames.json`, with its `--ascii` twin;
8. `tools/pty-mouse-check.py` — the real binary in a pty answering the
   probes like ghostty; one click opens a file, a right-click opens the
   row menu, a wheel notch reaches the app;
9. `tools/ui-diff.sh` on every `docs/ui-spec/steps-*.jsonl` when the
   change touches chrome (see *Spec dumps* below) — the diff counts must
   not grow.

`zig build check` runs 1, 2, the gate, the sweep, `tests/e2e/defaults.test`
and the full corpus in one step on the exe of that invocation — so
`zig build check -Doptimize=ReleaseSafe` is steps 1–5 in one line; 6–9
are run by hand.

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
    # the same seed on a real screen, deleted when mnml-zig exits
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

## Subagents

Leaves are delegated by default; the serial trunk design is the one
exception. Brief an agent with the file list it may touch, the tests it
must run in the foreground (a backgrounded check that "waits for the
notification" is a check that never ran), and the break-check it owes.
Verify its claims by grepping the source before repeating them: a report
that says "done" is a claim, `pub const table = .{ .@"ns.verb" = &fn }`
is evidence.
