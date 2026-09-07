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
repo and the ones written here, one folder (366 files at the time of
writing). The corpus is a regression net, not a pixel oracle: `expect screen contains`
is substring-tolerant, so a re-skin survives it, and a script that
breaks on a deliberate cosmetic change is updated as normal maintenance
— the commit says so.

```sh
zig build                              # the binary
./zig-out/bin/mnml-zig test            # the whole corpus at 120x40 (~2.5 min)
./zig-out/bin/mnml-zig test --gate     # the 47-file Phase-0 gate
./zig-out/bin/mnml-zig test tests/e2e/defaults.test
./zig-out/bin/mnml-zig test --gate --sizes 80x24,120x40,200x60   # the width sweep
```

The debugger has a real oracle too: `tools/fake_dap/` is
`mnml-fake-dap`, a deterministic Debug Adapter that runs the launched
file as a tiny line-oriented program (its `README.md` has the language
and the requests). `zig build` installs it, `mnml-zig test` exports its
path as `MNML_FAKE_DAP`, and the `dap_session_*.test` scripts seed
`.mnml/config.zon` with `.dap.dbg.cmd = "$MNML_FAKE_DAP"` and a
`prog.dbg` to stop, step, watch, evaluate and set variables through the
real client and panes — no toolchain, the same events on every platform.
A debug-UI change is tested against it, not against a hand-written reply.

The corpus number must not go down. 225/226 is the current line (the
one failure asserts TOML in a workspace config, by design); a change
that drops it is not finished.

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

## The gate

`zig build check` runs the safety gates in one step — what CI runs:

1. `zig fmt --check` over `src`, `build.zig`, `tools`;
2. the unit tests in Debug, then in ReleaseSafe;
3. the Phase-0 gate (`tools/gate.txt`) at 120x40;
4. the same gate swept at 80x24 / 120x40 / 200x60 — content assertions
   hold at 120x40, the other sizes assert no panic, no leak, no rect
   painted outside its parent;
5. `tests/e2e/defaults.test`.

Run the full corpus as well before offering a branch that touches the
editor, the input layer or the frame.

## Docs

`docs/commands.md` is generated: `zig build docs` regenerates it from
`src/commands/specs.zig`, and the generator's own test asserts every id
and every group appears. Do not edit it by hand; add the id to the spec
table and rebuild. `docs/PARITY.md` is the parity ledger the cutover
decision reads — a row moves from `missing` to `done` in the commit that
lands the runner, never before.

## Subagents

Leaves are delegated by default; the serial trunk design is the one
exception. Brief an agent with the file list it may touch, the tests it
must run in the foreground (a backgrounded check that "waits for the
notification" is a check that never ran), and the break-check it owes.
Verify its claims by grepping the source before repeating them: a report
that says "done" is a claim, `pub const table = .{ .@"ns.verb" = &fn }`
is evidence.
