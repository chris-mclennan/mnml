# Phase-0 spike results

Measured 2026-09-04 on the `verify` branch (main `a5c9022` + the e2e/ipc/headless
commits), Apple Silicon macOS (Darwin 25.5), Zig 0.16.0 from `/opt/homebrew`,
global dependency cache warm. Every command below was run from the repo root;
`SP` is the session scratchpad where screenshots and logs landed (not committed).

## Verdict table — `docs/DESIGN.md` → Phase 0 → VIABILITY VERDICT

| # | Criterion | Result | Evidence |
|---|-----------|--------|----------|
| 1 | 43 grammars compile + cross-compile to all 5 release targets with plain `zig build` | **Holds for ReleaseSafe** (the mode every shipped artifact uses) on all five; Debug x86_64-linux hits a compiler TODO; Windows minus the pty module | §2 |
| 2 | ghostty-vt works as a zon dependency, a pty pane runs a real shell, incremental rebuild after a one-line change < 5 s | **Holds.** `ls --color`, `vim`, `top` render under `pty-demo`; resize propagates; one-line edit → `zig build` 1.6 s, exe + all test binaries 2.2 s | §1, §3 |
| 3 | vaxis renders with kitty keyboard in 3 terminals; Canvas primitives done | **Not measured on this branch** (the vaxis spike's own deliverable). Canvas primitives exist with 19 tests, which also pass as x86-64 code under Rosetta | §2 |
| 4 | ≥ 40 of the 47 gate files pass unmodified, leak-clean | **Not yet measurable** — no App/editor exists on `main`. The oracle is ready: all 47 gate files (all 225) parse; runner semantics have 21 tests; leak = FAIL per file is tested; `mnml-zig test --gate` fails every file out loud until an App driver lands | §6 |
| 5 | Parallelization thesis: trunk in ≤ 5 days, three leaf slices merged without trunk changes | **This slice needed no trunk change**: `src/core/*`, `src/app.zig`, `src/commands/*` untouched; the seam is `src/e2e/driver.zig`. Trunk authoring time is not this branch's to assess | §6 |

## 1. pty in a real terminal

Built with `zig build pty` (5.5 s). Driven by `vhs` (xterm.js via ttyd — the
user's ghostty window is shared with another session, so it was not driven) from
`$SP/pty-demo.tape`, screenshots `$SP/pty-ls.png`, `$SP/pty-vim.png`,
`$SP/pty-top.png`, gif `$SP/pty-demo.gif`:

| Step | Seen |
|------|------|
| `ls --color` | directories blue, executables green, `.sh` magenta, the starship prompt in colour — SGR passes through ghostty-vt → painter intact |
| `vim README.md`, `jjjj`, `:q` | alt screen, README text, tilde rows, the `:` cmdline; `:q` returned to the shell |
| `top`, 5 s | header refreshed every 1 s, reverse-video column headers, 24 process rows — cursor-addressed redraws correct |

Resize: `$SP/resize.py` forks `pty-demo` under Python's `pty`, sets the outer
window to 24×80 with `TIOCSWINSZ` + `SIGWINCH`, runs `stty size` in the hosted
shell, then 50×160 and again:

```
before resize: stty size -> 24 80 seen = True
after  resize: stty size -> 50 160 seen = True
RESIZE_RESULT PASS
```

simd (`-Dpty-simd=true`, pulls simdutf + highway C++):

| Build | Result | Wall |
|-------|--------|------|
| `zig build -Dpty-simd=true` (native) | pass; 844 `simdutf`/`hwy` symbols in the binary (0 without the flag) | 7.8 s |
| `zig build gate-build -Dpty-simd=true` (native, exe + 5 test binaries) | pass | 5.1 s |
| `zig build -Dpty-simd=true -Dtarget=x86_64-linux-gnu` | pass | 8.1 s |
| `zig build gate-build -Dpty-simd=true -Dtarget=x86_64-linux-gnu` (Debug) | **compiler TRAP** — the same self-hosted-backend crash as §2 | 3.0 s |
| `zig build gate-build -Dpty-simd=true -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe` | pass | — |

## 2. tree-sitter: compile + cross-compile

**A plain `zig build -Dtarget=…` is not a grammar gate today.** All four cross
builds of the exe passed in ~5 s each, but `nm` finds zero `tree_sitter_*`
symbols in any of them: `src/main.zig` references none of the vaxis / ghostty /
tree-sitter Zig code yet, so lazy analysis never compiles it. The grammar and
runtime C static libs are still built for each target, but nothing links them.
The test binaries do reference every grammar (`src/highlight/root.zig` gates
all 43), so this branch adds `zig build gate-build`: compile the exe and all
five test binaries without running them, installed under `zig-out/gate/`.

`zig build gate-build -Dtarget=<T> [-Doptimize=ReleaseSafe] -p zig-out/gate-<T>`:

| Target | Debug | ReleaseSafe | Notes |
|--------|-------|-------------|-------|
| aarch64-macos (native) | pass — and `zig build test` runs them: 145/145 | pass (clean build 23.0 s) | |
| x86_64-macos | pass | — | the three cross binaries **run under Rosetta**: `test-highlight` 8/8 (every grammar loads, every query compiles, every fixture parses), `test-main` 19/19, `test-tree-sitter` 2/2 |
| aarch64-linux-gnu | pass (5.3 s) | — | |
| x86_64-linux-gnu | **compiler crash**, deterministic (2/2): `panic: TODO implement writeToPackedMemory for more types` while compiling `test-ui` (`src/ui/ui.zig` + vaxis). Only this target and only Debug. | **pass**, all 6 binaries | shipped artifacts are ReleaseSafe |
| x86_64-windows-gnu | 5/6: `test-pty` fails — `src/pty/session.zig` uses `openpty`/`fork`/`poll` (POSIX), and `std.c.pollfd` has no Windows definition. Expected: ConPTY is Phase 8. `mnml-zig.exe`, `test-main`, `test-ui`, `test-highlight`, `test-tree-sitter` build | 5/6, same | the pty module needs an `os.tag != .windows` gate before Phase 8 |

Reading: the 43 grammars and the tree-sitter runtime compile for all five
targets; the two failures are outside them (a Zig 0.16.0 x86-64 Debug backend
TODO reached through vaxis, and a POSIX-only pty module).

## 3. Timings

`/usr/bin/time -p`, quiet machine, from `$SP/timings.txt`:

| Measurement | Wall |
|-------------|------|
| clean `zig build` (`rm -rf .zig-cache zig-out`; global dep cache warm) | **15.8 s** (user 38.9 s) |
| clean `zig build -Doptimize=ReleaseSafe` | 23.0 s |
| no-op `zig build` | 0.29 s |
| `touch src/core/hooks.zig` then `zig build` | 0.27 s — **a no-op**: the cache is content-hashed, so the "0.5 s incremental" figure recorded on `main` measured nothing |
| real one-line edit to `src/core/hooks.zig`, `zig build` (exe) | **1.57 s** (×3, warm) |
| real one-line edit to `src/e2e/runner.zig`, `zig build` | 1.60 s |
| real one-line edit to `src/core/hooks.zig` or `src/ui/canvas.zig`, `zig build gate-build` (exe + 5 test binaries compiled, not run) | **2.2–2.3 s** |
| `zig build test`, first run (compiles the 5 test binaries) | 13.1 s |
| `zig build test`, no-op or after a one-line edit | **11.2–11.5 s** — tests always run |
| `zig-out/gate/test-highlight` alone | 11.3 s, MaxRSS 99 MB |

The suite's wall time is the highlight gate (43 grammars loaded, 43 query sets
compiled, 43 fixtures parsed) running every time; compilation is ~1.5–2 s.

## 4. Leak / safety

`grep -rn "page_allocator\|c_allocator" src/` (non-comment hits):

| Site | Why |
|------|-----|
| `src/pty/ring.zig:43,55` | the pty ring buffer — the one sanctioned use (D1) |
| `src/e2e/runner.zig:496,499,509,484` | the per-file worker's `Job`: it outlives the call when a hung file is abandoned on timeout, so it cannot come from the leak-checked gpa. Freed by whichever side finishes last (atomic hand-off) |

Neither is inside a `test` block. Every test module runs on
`std.testing.allocator` (`std.testing.tmpDir` for files); the harness's own
tests use short timings and `quiet_leak_report` so the leak-path test does not
trip the test runner's "any logged error fails" rule. The e2e runner puts each
file's driver on `DebugAllocator(.{ .safety = true, .thread_safe = true,
.enable_memory_limit = true })` and a `.leak` result fails the file — tested
with a driver that leaks 16 bytes (`runner.zig`, "a leaking App fails the file").

## 5. Io.Group cancel (D3 shutdown model)

`src/e2e/cancel_probe.zig`: an `io.concurrent` task inside an `Io.Group` blocks
in `Io.File.readStreaming` on a pipe nobody writes to; the test waits for the
task to enter the read, sleeps 50 ms, calls `group.cancel(io)` and asserts the
task returned `error.Canceled` within 1 s. **Passes on macOS** (`zig build test`,
part of the 145). Mechanism confirmed in `std/Io/Threaded.zig`: cancel sends the
worker thread `SIGIO` via `pthread_kill`, the read fails with `EINTR`, and
`fileReadStreamingPosix` calls `checkCancel()` on `.INTR` — this is why the exe
links libc (`have_sig_io`). Linux not run here (no Linux host); the code path is
the same POSIX one.

## 6. The oracle: runner, headless, IPC

| Piece | Status | Tests |
|-------|--------|-------|
| `src/e2e/parser.zig` — the full directive vocabulary, `unescape`, header directives (`requires: network`, `width:`, `zig-only`/`rust-only`), errors that name the line | done; **225/225 corpus files parse** (`mnml-zig test --parse /path/to/mnml/tests/e2e`) | 9 |
| `src/e2e/runner.zig` — 120×40, tick → 50 ms → expire chords → tick → draw per step, expect polled ≤ 3000 ms at 40 ms, `wait` ticking every ≤ 25 ms, per-file tempdir + isolated data root, shell gate, path rejection, 120 s per-file deadline (`MNML_E2E_FILE_TIMEOUT_SECS`) on an abandonable worker, leak = FAIL, `--sizes` sweep asserting content only at 120×40, `# width:` pinning, the ▶ / ⊘ SKIP / `  ok   ` / `  FAIL … — ` / `N/M passed` report, exit 1 | done; shipped defaults have their own test | 14 |
| `src/e2e/driver.zig` — the `Driver` vtable (open/key/mouse/command/ex/snippet/ghost/tick/expireChords/render/screen/status/rectsJson/dirty/paneTitle/highlightCount/ipcCommand/pluginInvocations/requestQuit/deinit), `Factory`, recording `Stub` | done; `main.app_factory` is `null` until the App lands | 2 |
| `src/ipc/command.zig` — `RawCommand` via `std.json`, all fields optional, integers required to be bare numbers, the 30-entry `cmd` table, unknown → raw line | done | 4 |
| `src/ipc/channel.zig` — init truncation at 0600, symlink unlink, `ipc_init_truncated`, `.gitignore` append (`.mnml/` always, `.rqst/` once present), byte-offset tail reader, death certificate | done | 8 |
| `src/ipc/screen.zig` — `toScreenTxt` (right-trim + `\n` incl. last), `toTestText` (no trim, no trailing), `status.json` in key order, `jsonStr`/`jsonEvent` | done; goldens pinned to bytes captured from `target/debug/mnml` today | 6 |
| `src/headless.zig` — the loop, every ack line, key-chain rules, `MNML_COLS`/`MNML_ROWS` (≥ 10, default 120×40), `MNML_IPC_DIR`, `-Dipc-subdir` (default `ipc-zig`), exit 75 on restart, signal death certificate | done; one test feeds 30 commands through a real channel and pins the whole `events.jsonl` | 3 |
| `mnml-zig test [PATH…] [--gate] [--sizes …] [--parse] [--stub]`, `mnml-zig [WS] --headless [--stub]` | done; without an App every file FAILs / exit 2 — never a vacuous pass | 1 |
| `tools/gate.txt` (47 names, all present in the corpus), `tests/e2e -> ../../mnml/tests/e2e` | done | — |

Unit tests on the branch: **145/145** (`zig build test`, Debug); 42 on `main`.

## Open risks

1. **Zig 0.16.0 x86-64 Debug backend TODO** (`writeToPackedMemory`) reached
   through vaxis when compiling `src/ui` tests for x86_64-linux-gnu. Native
   Debug builds on x86-64 Linux use the same backend, so a Linux contributor
   may hit it in plain `zig build test`; CI's Debug leg must not cross-compile
   test binaries for that target. Find the comptime packed write (vaxis or
   uucode) or pin the affected module to LLVM.
2. **Windows**: `src/pty` is POSIX-only and ungated, and `std.c.pollfd` is
   undefined for Windows in 0.16.0 — the pty module needs an `os.tag` gate now,
   ConPTY in Phase 8 as planned.
3. The exe references no foreign code yet; `gate-build` is the cross gate until
   the App links vaxis/ghostty/tree-sitter, at which point the plain exe build
   becomes meaningful again.
4. `zig build test` costs ~11 s regardless of the change, all of it the
   highlight gate's runtime; split it into its own step (or cache the
   parse) before the suite grows.
5. Criteria 3 and 4 remain open on this branch (no terminals driven, no
   editor); criterion 5's trunk-time half is for the trunk author.
6. The `.test` corpus is reached through a symlink that is correct at
   `Projects/mnml-zig/` and dangles in a worktree one level deeper; pass an
   absolute path there.
7. Two deliberate deviations from the Rust host, both documented in code:
   `mouse_move` decides drag-vs-hover from a held-button flag instead of the
   App's tree-drag state, and the harness's own tests use `quiet_leak_report`.
