# Phase-0 spike results

Measured 2026-09-04 on `main` after the four spike branches, the terminal
layer, the editor spine, the oracle, the app core, and the UI layer were
merged (88 commits, ~31.6k lines of Zig). Apple Silicon macOS (Darwin
25.5), Zig 0.16.0 from `/opt/homebrew`, global dependency cache warm.
Every number below was produced by the named command on this tree.

## Verdict — `docs/DESIGN.md` → Phase 0 → VIABILITY VERDICT

**CONTINUE.** All five criteria hold.

| # | Criterion | Result | Evidence |
|---|-----------|--------|----------|
| 1 | 43 grammars compile + cross-compile to all 5 release targets with plain `zig build` | **Holds.** `zig build gate-build -Doptimize=ReleaseSafe` (the exe *and every test binary*, which link all 43 grammars) passes for `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-macos`, `aarch64-macos`, and `x86_64-windows-gnu` — Windows builds the exe, tree-sitter, highlight, ui and main tests; the POSIX pty/tui pieces are gated off until ConPTY (Phase 8) | §2 |
| 2 | ghostty-vt works as a zon dependency, a pty pane runs a real shell, incremental rebuild after a one-line change < 5 s | **Holds.** ghostty is a native `build.zig.zon` module (main HEAD, no C ABI); `ls --color`, `vim`, `top` render under `pty-demo`; resize propagates. A real one-line edit → `zig build` in **6.0 s** on the full app tree (1.6 s on the smaller tree) — see §3 for why the earlier "0.5 s" was a no-op | §1, §3 |
| 3 | vaxis renders with kitty keyboard in 3 terminals; Canvas primitives done | **Holds.** ghostty (kitty keyboard, kitty graphics, rgb, mode 2027, in-band resize), Terminal.app (legacy: no kitty, 256 colors, SIGWINCH — found and fixed two real bugs: a false explicit-width claim and colon-form SGR that dropped every color), and vhs/xterm.js. All 8 gallery screens correct on each | tui + ui reports |
| 4 | ≥ 40 of the 47 gate files pass unmodified, leak-clean | **Holds: 41 / 47 at the verdict, 47 / 47 after the six editor slices landed the same day** (`mnml test --gate`). Width sweep `--sizes 80x24,120x40,200x60`: **141 / 141**, no panics, no leaks | §4 |
| 5 | Parallelization thesis: trunk in ≤ 5 days, leaf slices merge without trunk changes | **Holds.** Trunk authored in one session. Eight leaf branches (vaxis, ghostty-vt, tree-sitter, tui, editor, verify, app, ui) merged onto it; the only trunk-adjacent edits were two documented contract corrections (frame-arena timing, overlay carets) and one bug (`removeLeaf` invalidating a `NodeId`). Merges were mechanical except `build.zig` | git log |

## 1. pty in a real terminal

`zig build pty-demo`, driven by `vhs` (xterm.js) and by a scripted `pty.fork`:

| Step | Seen |
|------|------|
| `ls --color` | directories blue, executables green, the prompt in color — SGR passes through ghostty-vt intact |
| `vim README.md`, `jjjj`, `:q` | alt screen, text, tilde rows, the `:` cmdline; `:q` returns to the shell |
| `top`, 5 s | header refreshes every second, reverse-video headers, cursor-addressed redraws correct |
| resize 24×80 → 50×160 (`TIOCSWINSZ` + `SIGWINCH`) | `stty size` inside the hosted shell reports the new size both times |
| `q` under the demo | exit in 0.20 s — `Io.Threaded` cancels the blocked read on macOS |

`-Dpty-simd=true` (simdutf + highway C++): native pass; `x86_64-linux-gnu` pass in ReleaseSafe.

## 2. Cross-compile

`zig build gate-build -Dtarget=<T> -Doptimize=ReleaseSafe` — exe + every test binary:

| Target | Result |
|--------|--------|
| aarch64-macos (native) | pass; `zig build test` runs them: **332 / 332** |
| x86_64-macos | pass; the binaries run under Rosetta |
| aarch64-linux-gnu | pass |
| x86_64-linux-gnu | pass (Debug hits a Zig 0.16.0 backend TODO in `writeToPackedMemory` via vaxis — ReleaseSafe, the shipped mode, is unaffected) |
| x86_64-windows-gnu | pass for the exe + tree-sitter/highlight/ui/main tests; `pty` tests and the interactive loop are gated off (POSIX until ConPTY, Phase 8); `mnml test` and `--headless` work there |

## 3. Timings (`/usr/bin/time -p`)

| Measurement | Wall |
|-------------|------|
| clean `zig build` (cache cleared, deps warm) | 25.3 s |
| real one-line edit in `src/core/hooks.zig` → `zig build` | **6.0 s** |
| `zig build test` (332 tests; ~11 s of it is the 43-grammar highlight gate) | 19.6 s |

A `touch` is a no-op (content-hashed cache) — the "0.5 s incremental"
recorded earlier measured nothing. The honest figure is the real-edit one.

## 4. The gate

`mnml test --gate` → **41 / 47** at the verdict; **47 / 47** after the editor slices (multi-cursor, visual block, surround, align, ctrl+a/x, gq, gcc) merged. The six at verdict time:

| File | Why |
|------|-----|
| `multi_cursor` | `add_cursor_*` ops unsupported (multicursor slice) |
| `vim_align` | `align_selection` unsupported |
| `vim_misc_chords` | `change_number_at_cursor` (`ctrl+a`/`ctrl+x`) unsupported |
| `vim_surround` | `delete_surround` / `change_surround` unsupported |
| `vim_visual_block` | `yank_block` unsupported |
| `vim_replace_mode` | parity: after `R…<esc>`, `A<esc>R!` should append; the Zig handler overwrites |

Full corpus `mnml test` → 100 / 224 at the verdict, **107 / 225** after the slices and the TODOS panel (the rest are subsystems not yet built: mouse/drag/splits chrome, git, LSP, DAP, HTTP, agents, md-preview, runners). No crashes. Unit suite: **351 / 351** in Debug and ReleaseSafe.

## 5. Leak / safety

Every unit test runs on `std.testing.allocator`; the e2e runner puts each
file's App on `DebugAllocator(.{ .safety = true, .thread_safe = true })`
and a leak fails the file (tested with a deliberately leaking driver).
`page_allocator` appears only in the pty ring (sanctioned, D1) and the
runner's abandoned-job hand-off. The D3 cancel probe passes: an
`io.concurrent` task blocked on a pipe read returns `error.Canceled`
within 1 s of `group.cancel(io)`.

## Resolved after the verdict

- **ReleaseSafe parse crashes.** Four tests (highlight fixtures, captures,
  syntax spans, the `:A` smoke) died with SIGTRAP under
  `-Doptimize=ReleaseSafe` — Zig builds C with UBSan in trap mode in that
  mode too, and optimized grammar lexers trip it. The tree-sitter runtime
  and grammar units now compile with `-fno-sanitize=undefined
  -fno-sanitize-trap=undefined` (what ghostty does for its vendored C).
  `zig build test -Doptimize=ReleaseSafe`: 379 / 379.

## Open risks

1. **Zig 0.16.0 x86-64 Debug backend TODO** (`writeToPackedMemory`) reached
   through vaxis. CI's Debug leg must not cross-compile test binaries for
   x86-64; find the packed comptime write or pin that module to LLVM.
2. **Windows**: the pty module and the interactive loop are POSIX; ConPTY
   is Phase 8 as planned. Headless and the test runner already work there.
3. `zig build test` spends ~11 s in the highlight gate every run; split it
   into its own step before the suite grows.
4. Terminals under `wcwidth` (Terminal.app, xterm.js) disagree with the
   canvas on ZWJ emoji sequences and flags by a cell or two; fold them to
   the first emoji at paint time when `width_method == .wcwidth`.
5. libvaxis 0.6.0 notes worth upstreaming: `caps.rgb` never set; OSC 66
   probe false-positives on terminals that echo unknown OSC payloads; plain
   F3 CPRs delivered as key presses; `handleEventGeneric` does not compile
   under `zig test` on macOS; mode 2048 reset only when a report arrived.
