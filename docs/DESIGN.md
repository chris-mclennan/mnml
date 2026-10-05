# mnml → Zig port plan

> Status: **Everything through the second hunt round is merged (2026-09-05, main `f40f30d`).** Phases 0–8, the nine-track parity wave (`docs/PARITY.md`: 464 done / 1 partial / 10 cut / 2 missing of 477), shared-buffer windows, and five persona hunt rounds (NvChad ×2, VS Code ×2, multi-language, API workflow) — **81 findings filed, 79 fixed, 2 rejected with vim probes, 0 open**. The two Rust corpus lines that pinned non-vim behaviour were corrected upstream (`vim_replace_mode.test`, `vim_case_ops.test`) and Rust mnml fixed the same bugs. Rust 0.2.x also gained `mnml export-config-zon`; the site has "Upgrading to 0.3" and the ZON config reference. Gate 47/47, sweep 141/141, **corpus 351/352** (the one failure asserts TOML, by design), 1095 unit tests in Debug + ReleaseSafe, all five targets. Next: the cutover checklist (E6/E7/E8) — a remote + first CI run, the `v0.3.0-rc` dry release, the docs move, the author's dogfood week. See `docs/WAVE3_CONTRACT.md` for the per-track `// changed:` notes.

*// changed 2026-09-07 (ledgers):* twelve more tracks are merged since — the same-look chrome tracks (rail, statusline, welcome, tree, menu-bar, editor-panes, git-mode, overlays, git-status, section-side), the fake adapter and the debug UI. `docs/PARITY.md` reads 485 done / 4 partial / 10 cut / 3 missing of 502; the corpus is **393/393** (the TOML-asserting file now asserts ZON), 1205 unit tests (1203 pass, 2 skip). The three cuts below (symlinked corpus, the right panel, same-look everywhere) each carry a dated note where the plan states them.

## Context

mnml (`~/Projects/mnml`) is a ~289k-LOC Rust/ratatui terminal IDE at v0.2.21 with a small existing user base (~70–140 asset downloads/release, 12 stars, 33 sibling integration crates depending on `mnml-bridge` 0.8.0). The user wants to port it to Zig 0.16.0 — not as a permanent parallel product, but as a **replacement**: full feature parity with the Rust version, then cut over on a version bump and let users pin 0.2.x if they need something that hasn't landed.

Decisions already made (by the user):
- **Full parity of capability is the target.** No feature floor. "If it's replacing the Rust mnml then it needs to have what it has."
- **Successor, not port.** "We don't have to try and port it exactly." Structure, internals, and formats are free to change where Zig or better design warrants it.
- **Config is ZON, not TOML — and there is NO TOML reader anywhere in mnml 0.3+.** `std.zon` (parse + `Serializer`) is in 0.16 std. Themes are converted once to ZON and committed. Integration manifests become ZON. User config migration is a courtesy `mnml export-config-zon` in the final Rust release, not Zig code. The TOML serde quirks and the textual in-place `persist_config_scalar` semantics are NOT contracts.
- **Integrations get re-issued.** "We can make new integrations." The 33 sibling crates and `mnml-bridge` 0.8 are NOT a compatibility constraint; a new SDK + bridge protocol v2 is designed alongside the Zig host.
- **Design a real component system.** The Rust `panel_chrome` / `action_button` / `empty_state` / `tree_connectors` modules are the proto-version; formalize it in Zig (comptime-generic, per-frame arena). Improvements discovered here should flow back to Rust mnml — the plan keeps a **backport list**.
- **Viability gate first.** "We will know in a few weeks if it will be viable." The plan front-loads a spike that answers that question cheaply.
- **New sibling repo `mnml-zig`** next to `mnml`. Own build cache/CI/release. Share `tests/e2e/` and themes by symlink.
  *// changed 2026-09-07:* `tests/e2e` is a real directory in this repo, not a symlink — the Rust corpus was copied here when Rust froze (`8f61d3c` dropped the host headers and the Rust file names), and the scripts written for this codebase sit in the same folder: 394 `.test` files (393 run, one `# requires: network`), plus three parked `.test.*-skip`. Themes were never symlinked (converted once, committed).
- Unlimited tokens + subagents available. The bottleneck is serial trunk design and the debugging tail, not translation volume.

Working rules (from plan approval, 2026-09-04):
- **History is a deliverable.** Small commits, one concern each, clean and followable; never squash a branch into a blob. Commit messages describe mnml on its own terms — do NOT say "port" repeatedly.
- **Worktrees exclusively** (`../.worktrees/mnml-zig/<task>/`, made and removed with `tools/wt.sh`); agents work there, I merge into main.
- **Subagents by default** for every leaf; serial trunk design is the one exception.
- **Ghostty is the first-class terminal** (user is on ghostty/macOS; ghostty is also the vt vendor). Look to ghostty for conventions and standardization — kitty keyboard, modes 2026/2027/2048, OSC 52, kitty graphics, shell integration. **But Windows/Linux users without ghostty must be fully served**: runtime capability detection, graceful degradation, test on all three platforms before calling a terminal feature done.

Strategy: **keep what's free to keep; redesign the rest.** External surfaces that cost nothing to preserve and that protect the test oracle are kept by default (key-spec grammar `ctrl+p`, the 797 command ids, the `.mnml/ipc/` JSONL protocol, the `.test` directive vocabulary + runner semantics). The bridge wire format is redesigned (v2) since integrations are being rewritten in Zig anyway. Everything else — config format, persisted-state formats, App/UI structure, concurrency, allocation, the render layer — is designed fresh in idiomatic Zig. The 225 `.test` files are a **regression net**, not a pixel oracle: `expect screen contains` is substring-tolerant, so most survive a re-skin; the ones that break on cosmetic changes get updated as normal test maintenance.

---

## Execution

### Phase 0 — Viability spike (2–3 weeks, hard stop)

Answers one question: *is Zig 0.16 + this dependency set a credible host for this IDE?* Attacks the things that could each kill the project alone, riskiest first, so a "stop" verdict arrives in week 1 not week 3. Repo: `~/Projects/mnml-zig`, binary `mnml-zig`.

**Week 1 — three foreign-code risks, in parallel (three agents, independent `build.zig` subtrees):**

- **(c) libghostty-vt as a native Zig dependency.** `zig fetch --save git+https://github.com/ghostty-org/ghostty#<newest ref building on 0.16.0>`; `b.dependency("ghostty", .{ .target, .optimize, .@"emit-lib-vt" = true, .simd = false }).module("ghostty-vt")`. Share ONE `uucode` module between vaxis and ghostty (ghostty's `SharedDeps.zig` documents the `uucode`/`uucode0` duplicate-module trap). Deliverable `src/pty/session.zig` (*// changed 2026-09-04:* split into `session_posix.zig` and `session_windows.zig`, with `Notify` / `Exit` in `common.zig`): `std.posix.openpty` + fork/execvp `$SHELL`; reader `std.Thread` → SPSC byte ring → `.pty_readable`; UI thread `Terminal.vtWrite`; grid → `Canvas.put`; DSR/DA responses written back. **Pass:** `ls --color`, `vim`, `top` render; resize works. Then flip `simd = true` and confirm the C++ builds on macOS arm64 + `x86_64-linux-gnu` cross. *Fallback:* `ghostty-vt-static` artifact + `@cImport(vt.h)` (the Rust path).
- **(a) tree-sitter from C, 43 grammars.** `build.zig` compiles upstream tree-sitter 0.26 `lib/src/lib.c` + each grammar's `parser.c` (+ `scanner.c`/`.cc`) as one static lib; grammar sources as `build.zig.zon` tarball deps at the versions `Cargo.toml` pins; reference neurocyte's `build.zig` for per-grammar quirks only. `src/highlight/table.zig` comptime table reproduces `highlight.rs:1009 build_config` layering (ts = js + ts queries; tsx adds JSX; md block + inline dual parser; 4 repo-local `queries/*.scm`). **Pass:** all 43 compile on macOS and cross to `x86_64-linux-gnu` + `x86_64-windows-gnu`; a test loads every `Language`, compiles every query (no error offset), parses a fixture each. *Fallback:* drop 1–2 exotic grammars (swift, kotlin C++ scanners) temporarily; or dep on neurocyte `master-a9680e3e…`.
- **(b) libvaxis 0.6.0 + primitives.** `Vaxis` on our own `std.Io.Writer`; `queryTerminal`, kitty keyboard, alt screen, mouse, bracketed paste. Then `Canvas.{text (Paragraph+wrap), border (Block), fill (Clear), clipCells}`. **Pass:** demo renders a bordered wrapped paragraph in ghostty, kitty, Terminal.app and reports `Capabilities` for each.

**Week 2 — the serial trunk (ONE agent; this is design, not volume):** `src/core/` per D1–D7 and D10 seams: `frame_arena`, `event.zig` (`AppEvent` + `EventQueue` + the wakeup loop), `command.zig` + `commands/specs.zig` (797 ids, comptime `CommandId`, `-Dpartial`), `ui/{rect,canvas,hit,ui,header,chip,scrollbar,filter_input,empty_state,list_panel}.zig`, `keymap.zig` (`parseKeySpec` exact, comptime-callable), editor spine (`Editor`, `EditOp` 131-variant union, `EditOutcome`, `Buffer.feedKey`, `InputHandler` union), `hooks.zig` (Zig subscribers only). Then **`src/todos.zig` as the reference module** (D8). Budget ≤ 5 working days.

**Week 2–3 — (e) oracle, then (f) volume:**
- **(e)** `src/e2e/runner.zig` reproducing `src/e2e/mod.rs` exactly (fixed 120×40 `vaxis.Screen`, no tty; step = tick→50ms→expire chord→tick→draw; expect polls ≤3000ms @40ms; `wait` ticks ≤25ms; tempdir + `MNML_DATA_ROOT` per file; `MNML_E2E_ALLOW_SHELL`; `# requires: network`; `breadcrumb=false`; `toTestText` flatten; `  ok   ` / `  FAIL … — ` / `N/M passed`), invoked `mnml-zig test [paths]`. Two deliberate divergences since: a sweep rung that asserted no content reports `  ok*  … (structure only)` and the trailer carries a `(K content, L structure-only)` breakdown after the byte-identical `N/M passed` prefix (docs/CONTRIBUTING.md, *The sweep and what it proves*). `src/headless.zig` + `src/ipc/` (byte-identical protocol, `toScreenTxt`). Runner on `DebugAllocator(.{.safety=true})`, leak = FAIL.
- **(f)** vim + standard handlers from `input/vim.rs` (5382) / `standard.rs` in ~10 parallel slices (motions / operators / text objects / registers+macros / visual-block / cmdline+ex-subset / search / marks / abbreviations / standard), each gated by its `.test` files, merged behind the frozen `EditOp` union. **Each slice PR shows its gate files passing AND its break-check.**

**Phase-0 gate — 47 `.test` files** that use only `write/open/key/type/expect screen|file|dirty|pane` + editor/find/buffer commands: `edit_and_save, standard_ctrl_l_selects_whole_line, bracket_match, fold_chord, folds, wrap, marks, goto_line, find, find_incremental, replace, substitute, multi_cursor, whichkey, alternate_file, buffers, buffer_reopen, close_prompt` + 29 `vim_*` (`abbreviations, align, case_ops, cgn, change_list, cmdline_cursor, cmdline_tab_complete, count_replace, delete_history, dot_repeat, find_char, first_nonws_motions, line_range_marks, literal_next_tab_aliases, macros, misc_chords, mode, named_macros, named_registers, percent_pipe, repeat_insert, replace_mode, search_chords, sort_retab, surround, text_objects, visual_block, visual_block_change, visual_block_insert`). Deferred to Phase 1/2: `vim_split_*` ×3, `vim_sticky_context`, `vim_treesitter_textobjects`. The 11 `expect highlights` files gate (a) once the editor opens files.

**VIABILITY VERDICT (end of week 3) — CONTINUE only if ALL hold:**
1. 43 grammars compile + cross-compile to all 5 release targets with plain `zig build`.
2. ghostty-vt works as a zon dependency and a pty pane runs a real shell; **incremental rebuild after a one-line editor change < 5 s**.
3. vaxis renders correctly with kitty keyboard in 3 terminals; Canvas primitives done. (Needing to fork vaxis is a note, not a stop.)
4. **≥ 40 of the 47 gate files pass unmodified**, leak-clean.
5. **The parallelization thesis holds:** trunk designed by one agent in ≤ 5 days, and three leaf slices merged **without trunk changes**.

**STOP (stay on Rust) if:** grammars need per-platform hacks `build.zig` can't express; ghostty's module drags in non-cross-compiling deps AND the C-ABI fallback fails; or the vim slices land < 30/47 — a signal that `EditOp`/`Editor` semantics couldn't be reproduced and the tail is worse than estimated.

### Phases 1–8 — the parity march

Ordered by trunk dependency and trunk-change risk, not size (translation is parallel). Each: what lands · `.test` gate · Rust source of truth · parallel shape.

| # | Lands | Gate (`tests/e2e/`) | Source | Parallel |
|---|---|---|---|---|
| **1 Layout, panes, chrome, mouse** (second trunk phase — 1 serial week for `Layout`/focus/`HitMap`, then fan out) | `Layout` split tree (translate — already a tagged union), `Pane` union (31, stubs), tab pages, bufferline, statusline, tree rail, which-key, palette + fuzzy, overlays, toasts, `HitMap` mouse routing + scroll coalescing, context menus, settings overlay, **themes as committed ZON**, ZON config load/merge/trust (E1) | `splits, tab_pages, multitab_split, tab_picker_and_chords, vim_split_*, drag_*`(5), `mouse_*`(23), `command_palette, overlays, toast_stack, theme_picker, recent_files_picker, settings_persist_to_workspace, first_launch_wizard, right_panel_*`(3), `tree_*`(4), `cheatsheet_*`(2), `activity_switch_clears_stale_click_rects, cmdline_history_and_quickfix` | `layout.rs`, `app/layout.rs`, `tui/mouse/*`, `ui/{statusline,bufferline,tree_view,tooltip,context_menus,panel_chrome,scrollbar,theme}.rs` | ~12 leaves |
| **2 Language layer** | ts highlight in editor (spans, injections, 120ms idle), sticky context, ts text objects, outline (+regex fallback via Oniguruma), ts folds, snippets, md preview, auto-md-preview | 11 highlight files + `vim_sticky_context, vim_treesitter_textobjects, outline_*`(3), `ts_outline_regex_fallback, go_outline_regex, markdown_preview, md_preview_*`(2), `auto_md_preview, snippet*`(3), `tsx_languageid_bug` | `highlight.rs`, `regex_outline.rs`, `snippet.rs`, `ui/md_preview.rs` | 6 |
| **3 Process backends** | `Pane.pty` on the spike session, tasks, cargo/npm/go/pytest runners + detection, gitignore matcher (~600 lines), file-change watcher, tools installer | the 41 `shell` files minus git: `go_*`(14), `npm_*`(5), `ts_*`(7), `py*/pytest_*`(13), `cargo_runner_toast_format, runners_dont_walk_up, tools_installer, shell_step_smoke` | `app/runners*.rs`, `pty_pane.rs`, `task.rs` | 5 |
| **4 Git** | status/blame/diff/graph/staging/branch rail/sync/undo-redo/AI commit msg/browse. **Redesign:** the 62 sync `git` calls + `git/status.rs tick()` on the UI thread → one git worker posting `.git` events | `git_*`(7), `multi_repo_switch` | `src/git/`, `app/git.rs`, `app/git_async.rs`, `ui/{diff_view,git_graph_view,git_status_view}.rs` | 6 |
| **5 LSP + DAP** (shared JSON-RPC-over-stdio core, 1 serial leaf ~2 days) | LSP client (reader/server → queue), completion, diagnostics, nav, rename, hover, semantic tokens, formatting, hierarchies; DAP client, breakpoints, variables, watches, REPL | `lsp_*`(5), `right_panel_diagnostics_ts, right_panel_outline_ts, peek_definition_overlay_no_lsp_leak, dap_*`(9) | `src/lsp/`, `src/dap/`, `app/lsp*.rs` | ~10 |
| **6 HTTP + WS + SSE + Browser/CDP** (widest, fewest trunk deps — almost pure leaf work; HTTP client wrapper + WebSocket are 2 serial leaves first) | `.http/.curl/.rest` parser, envs, request pane, send/stream/bench/mocks/history/chains/discover/sync/lookup, cookies, JWT, schema validate (subset), HAR/Postman import, captured traffic; CDP pane; `mnml run/chain/discover/sync/proxy` CLI | `tests/e2e/http/`(33) + `http_curl_multi_block_send_uses_cursor, http_multi_block_writeback, browser_commands_no_pane` | `src/http/`, `app/http.rs`, `ui/{request_view,http_panel}.rs`, `src/cdp/`, `websocket*.rs` | ~14 |
| **7 AI, dock, panels, images, misc panes** | AI panes/chat (claude CLI + Messages API + tool loop), ghost text (API), spend report, dock widgets (redesign as components), TODOS/NOTES/FINDINGS (`ListPanel`), image panes (kitty/iTerm2/sixel after draw), now-playing, sonos, cloud agents, glyph builder | `ai_ghost_text, ai_suggest_backend, agents_*`(2), `spend_*`(2) | `src/ai/`, `app/ai.rs`, `ui/{dock,*_panel,image_view}.rs`, `src/image/`, `src/sonos/`, `src/now_playing/` | ~12 |
| **8 Extensibility, trust, Lua, polish** | **Bridge v2 host** + Zig `mnml-sdk` (E5), manifest install/discovery/marketplace (ZON), workspace trust, update check, startup picker, session (ZON), persistent undo, `:messages`, stress meter, zen; **Lua** (zlua 5.4) on the D10 seams; Windows ConPTY + `UnixAddress` | new `.test` files for trust + IPC (`register-command`, `statusline-set-segment`, `open-pty`) + Lua | `mount.rs`, `crates/mnml-bridge/`, `trust.rs`, `app/discovery.rs` | 6 |

**Post-cutover:** integrations rewritten in Zig on `mnml-sdk` — **jira, bitbucket first**, then the rest of `mnml-integrations/apps/*`. Local FIM (llama.cpp binding) evaluated.

### Dependencies — decisions + fallbacks

| Need | Decision | Fallback |
|---|---|---|
| Terminal | libvaxis 0.6.0 upstream (tarballs already in `~/.cache/zig/p`); we own the `Io.Writer` | neurocyte fork as `deps/vaxis` path dep only on an unmerged 0.16 bug |
| tree-sitter | own `build.zig`, upstream C + grammar tarballs at Cargo-pinned versions, `@embedFile` queries | neurocyte `master-a9680e3e…`; drop swift/kotlin temporarily |
| libghostty-vt | zon git dep at newest 0.16-buildable ref, `.module("ghostty-vt")`, `emit-lib-vt=true`, `simd=false`→`true` before cutover; shared `uucode` | `ghostty-vt-static` + `@cImport(vt.h)` |
| HTTP/TLS | **`std.http.Client` + `std.crypto.tls`** (1.2/1.3, `Certificate.Bundle`); gzip/deflate via `std.compress.flate`; **brotli dropped** | bind mbedtls (~3 days) behind the same interface |
| WebSocket | hand-roll RFC 6455 client (~1k lines) over `std.Io.net.Stream` + TLS; serves CDP + WS pane | — |
| Images | zigimg (vaxis dep) PNG/JPEG/GIF/BMP → PNG for kitty/iTerm2; sixel encoder ported from `image/sixel.rs`; **WebP dropped** | — |
| SVG (9 glyph-builder assets) | pre-rasterize at build time (`resvg` CLI run step or checked-in PNGs); bake step shells out | drop glyph-builder preview in 0.3.0 |
| JSON-schema (1 file) | reimplement subset (~400 lines: type/required/properties/items/enum/const/min/max) | toast "not supported" |
| Regex (8 sites) | **Oniguruma via ghostty's vendored `pkg/oniguruma`** (already `zig build`-able; vim-pattern exact) | Pike-VM (~1.5k lines) |
| Local FIM | **API-only in 0.3.0**; `suggest_backend = "local"` toasts a migration note | llama.cpp post-cutover |
| Clipboard | OSC 52 via vaxis + `pbcopy/xclip/wl-copy/clip.exe` fallback + internal register | — |
| pty | `std.posix.openpty` + fork/execvp + SIGCHLD reaper; Windows ConPTY in Phase 8 | — |
| Lua | zlua, Lua 5.4, compiled from C in `build.zig` | Luau if sandboxing outweighs `sethook` parity |
| TOML | **none** | — |

**Known cuts at 0.3.0 (flagged now, not later):** local FIM → API-only · brotli · WebP · glyph-builder SVG preview · **no integrations until rewritten in Zig** (users needing them pin 0.2.x).

### Side-by-side mechanics
`mnml` (Rust) + `mnml-zig` on PATH until cutover. `MNML_IPC_SUBDIR` default `ipc` (Rust) / `ipc-zig` (Zig); `MNML_IPC_DIR` honored by the Zig host and passed to children. Marker `mnml-zig-running-${USER}.workspace`. `mnml-zig/tests/e2e -> ../mnml/tests/e2e` symlink; files that must diverge get a `# zig-only` / `# rust-only` header the runner honors; symlink becomes a copy when Rust freezes. *// changed 2026-09-07:* the copy happened; there is one folder and no host headers (none of the 394 files carries `# zig-only` / `# rust-only`), and a file that diverged from the Rust look was re-aimed in place with the commit saying so. Themes are NOT symlinked (converted once, committed). `mnml-zig/run.sh` with the same verbs, parameterized on binary/marker/IPC subdir. *// changed 2026-09-08:* landed — `run.sh` (build-if-stale, the exit-75 loop, restart/stop/status/headless/fresh/shot/check/clean/menu), `scripts/shot.sh`, and the app side it needed: the terminal loop writes the marker and tails `command` for `quit`/`restart` (the rest of the command set stays headless-only), `--no-session` is the `fresh` flag; `MNML_BIN` / `MNML_IPC_SUBDIR` / `MNML_IPC_DIR` are the wrapper's knobs; `tools/run-sh-check.sh` is the test. `watch`, `demo`, `sandbox` were not carried over. Zig writes `config.zon` beside `config.toml`, never touches the TOML. *// changed 2026-09-19:* the side-by-side pair is no longer Rust-vs-Zig but stable-vs-dev — a **profile** (`MNML_PROFILE=dev|stable`, `src/config/profile.zig`) owns the data root (`-dev` suffix), the session file (`session-dev.zon`), the IPC subdir and the marker prefix, so the installed `mnml` and a `run.sh` build coexist on one machine after cutover too. The stable profile's two names are the build's: `-Dinstall-names` (`zig build release`, `run.sh install`) spells them `ipc` / `mnml-running-…`; this tree's builds keep the `-zig` names for both profiles. `run.sh install` is the install step (`docs/CONTRIBUTING.md`, "Daily driver + development on one machine").

### Cutover → ship as `mnml` v0.3.0, freeze Rust at 0.2.22
1. Every FEATURES.md bullet checked in `PARITY.md`; the cut list above enumerated with a toast/doc path each.
2. `mnml-zig test` green on all 225 (post-maintenance) at 120×40; 80×24 + 200×60 sweeps free of panics/leaks/rect overflows; drift report reviewed.
3. `mnml export-config-zon` (Rust 0.2.22) run on the author's real config + a trust-keyed workspace config; migrate → load → serialize → equal.
4. Release pipeline: 5 targets from one runner + shell/ps1/msi + tap/winget/deb/rpm ≈ 22 assets; `gh release view --json assets` verified.
5. Docs site updated (E8).
6. One week of the author dogfooding `mnml-zig` with Rust `mnml` off PATH.

---

## Verification

- **Oracle first:** `mnml-zig test` runner lands in Phase 0 week 2, before any vim slice is generated. Every slice/leaf PR names its gate `.test` files and shows the run.
- **Leak = FAIL:** unit tests on `std.testing.allocator` only (CI greps `test` blocks for `page_allocator`/`c_allocator` and fails); e2e runner on `DebugAllocator(.{.safety=true,.thread_safe=true})`, `assert(deinit()==.ok)` per file.
- **Two optimize modes in CI:** `zig build test -Doptimize=Debug` and `-Doptimize=ReleaseSafe` (what ships).
- **Width sweep from Phase 1:** `mnml-zig test --sizes 80x24,120x40,200x60`. Content assertions at 120×40; other sizes assert no panic, no leak, no overlapping hits, and **every component's attempted rect ≤ parent** (the `HitMap` records attempted+drawn — this is what would have caught the 38-cells-at-30 chip). `--audit` headless flag dumps per-component rects.
- **Differential harness (Phase 0 week 3):** `tools/diff-test.sh <file.test>` drives the same file through `mnml --headless` and `mnml-zig --headless` via IPC verbs, snapshots `screen.txt` per step, emits whitespace-normalized `drift/<name>.diff`. Non-gating; weekly report ranked by diff size.
  *// changed 2026-09-07:* the harness that shipped is `tools/ui-diff.sh WS RS_DATA ZIG_DATA [STEPS] [COLSxROWS]` — both binaries headless on one workspace and config, one `steps-<name>.jsonl` of IPC commands, a row-by-row diff — and the Rust screens it produced are committed as the spec (`docs/ui-spec/rust-*.txt`, its README). Every chrome track is measured against them cell for cell. **The one deliberate departure from same-look is the debug UI**: the Rust debug pane was never driven by anyone, so the Zig screens are their own spec — `tools/zig-spec.sh NAME` runs mnml headless on a throwaway workspace wired to the fake adapter and keeps `docs/ui-spec/zig-<name>-<size>.txt`; `tools/debug-demo.sh [vim|standard]` opens the same seed on a real screen. The debugger's oracle is `mnml-fake-dap` (`tools/fake_dap/`, installed by `zig build`): a deterministic DAP server over stdio; `mnml-zig test` exports **`MNML_FAKE_DAP`** (the adapter beside the runner binary, else where `zig build` installs it — `src/main.zig`) into every App's environment, an adapter's `cmd` / args expand `$NAME`, and the `dap_session_*` / `debug_*` scripts write `.dap.dbg.cmd = "$MNML_FAKE_DAP"` into the workspace config. `zig build check` runs the full corpus after the gates (E7).
- **Break-check enforced:** every new `.test`/unit test lands with a mutation run showing it FAILING against a one-line revert; CI runs new `.test` files against the previous commit's binary and requires ≥1 FAIL.
- **Comptime replaces source-scanning:** menu ids resolve, default keyspecs parse, dup ids + chord collisions → `@compileError`; themes parse at comptime; `defaults.test` asserts shipped `Config{}`.
- **Cross-compile all 5 targets on every PR** (Zig's lazy analysis only checks target-gated code when that target is built).
- **Fuzz:** `std.testing.fuzz` on `parseKeySpec`, IPC `RawCommand`, ZON loader, bridge v2 frame parser.
- **Process (from the Rust repo's own lessons):** confirm a break really landed before trusting a passing test; test shipped defaults not values around them; cosmetic `.test` re-skins say so in the commit.

---

## Design — the trunk

Serial, hand-written, settled before any leaf is generated. Verified against Zig 0.16.0 std (`/opt/homebrew/lib/zig/std`) and libvaxis 0.6.0.

### D1. Allocation — three tiers, every allocation belongs to exactly one

| Tier | Type | Lifetime | Freed by |
|---|---|---|---|
| `app.gpa` | `std.heap.DebugAllocator(.{})` in Debug/ReleaseSafe (leak report at deinit); `std.heap.smp_allocator` in ReleaseFast | process | owner's `deinit` |
| snapshot arena | one `ArenaAllocator` per **replace-wholesale dataset** (LSP diagnostics per file, git status/graph, an HTTP response, a parse's highlight spans, marketplace listing) | until next snapshot | `arena.reset(.retain_capacity)` when the replacement lands |
| `app.frame` | one `ArenaAllocator` reset at top of every loop iteration | one iteration (dispatch + tick + render) | nobody |

`page_allocator` only for pty ring buffers. No per-buffer arenas (buffer allocations have independent lifetimes → gpa-owned `ArrayList`s in `Editor`/`Buffer`, freed in `Buffer.deinit`).

**String ownership by type:** `[]u8` field ⇒ owned, gpa, freed in deinit. `[]const u8` field ⇒ borrowed (literal / snapshot-arena / frame-arena), never freed by holder; `gpa.dupe` to keep past the iteration. Event payloads are owned by the event; the handler adopts or frees before returning — no third option.

Tests: every `test` block on `std.testing.allocator`; `.test` runner + headless on `DebugAllocator` so e2e leak-checks too.

*// changed 2026-09-20 (arena audit):* there is a **fourth tier the table
does not name, and it is where this family of bug keeps landing** — a
background job's **result arena**. The job runs off the loop, hands back
a struct carrying its own `ArenaAllocator`, and the consumer on the loop
either **takes that arena into a field** or lets it go on the way out.
Storing a slice out of the payload while letting the arena go is the
same mistake as keeping a frame-arena string, except the window is
minutes rather than one frame, so it reads correctly for a long time
first. Four instances have now shipped (the bitbucket chip's hover rows
being the fourth; see `docs/SDK.md` → "Results outlive the job").

Two things changed to stop the fifth:

- `zig build arena-audit` grew a `--job-results` rule and now walks
  `integrations/` and `sdk/` as well as `src/`. A prong of a result
  switch that stores the payload without taking the arena or duping is
  a finding; a unit test walks both roots.
- `sdk.testing.Scribble` — an allocator that writes `0xAA` over
  everything it frees, in every build mode. Put under a test rig's
  fetch side it is the **only** way a test can see this: `Allocator`'s
  own poison is `undefined` (skippable in a release build) and an arena
  returns pages through `rawFree`, which poisons nothing, so a test
  written without it passes whatever the code does.

Two adjacent shapes the same audit turned up, worth naming because
neither is a frame arena: an `ArenaAllocator`'s `allocator()` **binds to
the address it was taken from**, so a handle taken off a stack local and
then copied into a field points at a dead frame (harmless for plain
slices, not for a `std.json.Value`, whose arrays are
`std.array_list.Managed` and carry the handle); and a `FixedBufferAllocator`
over a stack buffer hands `std.json` somewhere to put an escaped string,
which then escapes the function.

### D2. Errors — error code + `Diag` side slot, owned by the dispatcher

```zig
pub const CommandError = error{ NoActivePane, NotAnEditor, NoWorkspace, NoRepo, NoSelection, Unsupported, Canceled, Failed }
    || std.mem.Allocator.Error || std.Io.Cancelable;
pub const CommandFn = *const fn (*App) CommandError!void;
pub const Diag = struct { msg: ?[]const u8 = null,   // frame-arena
    pub fn fail(d: *Diag, arena: Allocator, comptime f: []const u8, args: anytype) error{Failed} { … } };
```
`command.run` clears `app.diag`, calls, toasts `diag.msg orelse "<title>: <@errorName>"` on error (Canceled silent), and **returns the error** — so `.test`'s `command <id>` fails on `!void` and IPC `run-command` acks `ok:false`. Replaces `app.last_command_failed`. Conventions: `errdefer` after every acquire; multi-field mutations snapshot + `errdefer`-restore; no `catch unreachable` outside comptime/test; render fns return `Allocator.Error!void` (OOM ⇒ skip frame, log once); workers never toast — they post `.err`.

### D3. Events + concurrency — `Io.Threaded`, one inbound queue, real wakeups

Runtime is **`Io.Threaded`** (every worker is blocking I/O on a pipe/socket/child; fibers buy nothing). Workers are `io.concurrent` inside an **`Io.Group` per subsystem**; shutdown is `group.cancel(io)` (Threaded interrupts blocking reads via signal — **spike item: confirm on macOS + Linux for pipe reads**). Pty reader stays a raw `std.Thread.spawn` (lifetime = child's).

```zig
pub const AppEvent = union(enum) {          // comptime assert(@sizeOf(AppEvent) <= 64)
    key: vaxis.Key, mouse: vaxis.Mouse, winsize: vaxis.Winsize, paste: []u8, focus: bool,
    lsp: struct { server: lsp.ServerId, msg: *lsp.Event }, dap: struct { session: dap.SessionId, msg: *dap.Event },
    cdp: cdp.Event, git: *git.Result, http: *http.JobResult, sse: http.StreamChunk, ws: http.WsFrame,
    ai: struct { job: u64, msg: ai.Msg }, pty_readable: PtyId, sonos: sonos.Update, now_playing: *NowPlaying,
    statusline: StatuslineSegment, marketplace: *market.Result, ipc: ipc.Command,
    err: struct { source: Source, msg: []u8 }, timer: void,
};
pub const EventQueue = struct { q: std.Io.Queue(AppEvent), wake: std.Io.Event = .unset,
    pub fn post(self: *@This(), io: Io, ev: AppEvent) void { self.q.putOneUncancelable(io, ev) catch freeEvent(ev); self.wake.set(io); } };
```
**Terminal input is a worker too** (~60 lines: `tty.read` → `vaxis.Parser` → `post(.key)`), so the UI thread has exactly one wait:
```zig
while (!app.quit) {
    _ = app.frame.reset(.retain_capacity);
    app.events.wake.waitTimeout(io, .{ .deadline = app.timers.next() }) catch |e| switch (e) { error.Timeout => {}, error.Canceled => break };
    app.events.wake.reset();
    var buf: [256]AppEvent = undefined;
    while (try app.events.q.get(io, &buf, 0)) |n| { if (n == 0) break; for (buf[0..n]) |ev| try app.handle(ev); }   // min=0 ⇒ non-blocking drain
    try app.tick(io.now());                      // timers, pty ring pump, autosave
    if (app.needsRender() and frameBudgetElapsed()) try app.render();
}
```
Replaces the 40/120 ms adaptive poll: idle sleeps until the next timer; a pty burst wakes immediately; a 16 ms frame budget coalesces. `.test` runner / headless call `pumpEvents / tick / render` directly (no wait) — preserves "every step → render".

*// changed 2026-09-04 (app core):* `app.frame.reset` runs at the top of `App.render`, not the loop iteration — the hit map registered by a frame must survive until the next iteration's mouse event routes through it. The loop's deadline is `App.nextDeadlineMs()` (chord timeout, toast expiry) through `Io.Event.waitTimeout`. Terminal input keeps `Term`'s own reader worker; a bridge task in an `Io.Group` re-posts its events as `AppEvent`s so the UI thread still has exactly one wait. The 16 ms frame budget is not in the spike loop: a burst of events drains before one render.

*// changed 2026-09-08 (test-hang):* the spike item is settled: on macOS `Io.Threaded` does interrupt a blocked syscall — `pthread_kill(SIGIO)` against a do-nothing handler, `EINTR`, `error.Canceled`. The trap is the runtime's one-shot acknowledgement: a task is marked `canceled` at the first syscall that reports the cancel, every later wait of that task is uninterruptible, and `group.cancel` stops signalling it — so a worker that *drops* an `error.Canceled` (a `catch {}` on a file op) and then parks on its job queue wedges `cancel` for good. Rules: a queue-fed worker's owner closes the queue *before* cancelling the group (`git.client.Repo.destroy`), and a job path that cannot propagate `error.Canceled` calls `io.recancel()` (`keepCancel`). `zig build test -Dtest-trace` (`tools/test_runner.zig`) names each test as it runs and takes `MNML_TEST_FILTER` at run time.

*// changed 2026-09-21 (moved groups):* the rule the cancel model rests on — **anything a task holds the address of lives on the heap, or in storage that never moves.** A running task holds its `Io.Group`'s address, so a group that moves after it has a task makes `cancel` wait forever on a task the group at the new address cannot see. `PaneStore.slots` is an `ArrayList(?Pane)`, so opening ANY pane moves every open pane: a pane's group is a `*Io.Group` made in `init` and destroyed after the `cancel` in `deinit` (`GrepPane`, `SpendPane`, `TestsPane` — all three shipped with it inline). The same rule is why jobs live in `ArrayList(*Job)` (`ai`, `integration_poll`), why a `std.Thread`'s context is a heap `*Shared` (`ws_pane`, `browser_pane`, `pty`), and why `Term` is `gpa.create`d. `App` moves exactly once — `initWith` returns it by value — so no worker may start before it is in place; they all start from the `startup` hook. `zig build arena-audit` fails on an inline `Io.Group` in a `Pane` payload.

**Pty hot path:** per-session 256 KiB SPSC byte ring (`page_allocator`, atomic head/tail); reader writes into ring, posts `.pty_readable` only on empty→non-empty; `pump` drains ring → `vt_write`. Zero allocs (Rust: one `Vec` per 8 KiB). **Reverse channels** (AI confirm, CDP outbound): per-job/per-client `std.Io.Queue(T)` owned by the job struct — cancelable, no global `HashMap<u64, Sender>`.

### D4. Input — `union(enum)` + `inline else`, `EditOp` recursion into the frame arena

```zig
pub const InputHandler = union(enum) { standard: Standard, vim: Vim,
    pub fn handleKey(h: *InputHandler, key: Key, ctx: EditCtx, arena: Allocator) InputResult {
        return switch (h.*) { inline else => |*impl| impl.handleKey(key, ctx, arena) }; }
    // the 15 defaulted trait methods → optional decls: if (@hasDecl(@TypeOf(impl.*), "onBlur")) impl.onBlur();
};
```
Seam kept: `InputResult{ops: []const EditOp, consumed, ignored, app: AppCommand}`, `EditCtx` (13 scalars, by value), `BufferEvent`, `AppCommand` (with `run_command: CommandId` — enum, not string). `EditOp` = `union(enum)` 131 tags; `repeat: struct{count, inner: *const EditOp}` / `atomic: []const EditOp` point into **`app.frame`**; dot-repeat + macro registers (the only cross-iteration holders) call `EditOp.dupe(gpa)`/`free(gpa)`. `apply_one`: **one exhaustive `switch` in `editor/apply.zig`**, grouped prongs delegating to family modules (`motion/insert/delete/select/undo/fold/case/multicursor.zig`). Undo: snapshot arena + ring instead of `Vec<String>` with `remove(0)`.

*// changed 2026-09-04 (editor slice):* `handleKey` is `Allocator.Error!InputResult` — an op list is built on the frame arena, so building it can fail. `EditCtx` has 12 scalars, not 13 (the Rust struct has 12). `Editor.apply` takes the frame arena for `text_edits`; `Buffer.feedKey` takes it too and handles the buffer-local `AppCommand`s (marks, `.`, `q`/`@`) itself. The line index is patched incrementally in `splice` (O(lines) per edit, infallible reads) instead of lazily invalidated — a lazy rebuild would make every line read fallible. Undo snapshots own their text per entry on the gpa; an arena cannot release an evicted entry. `Buffer` keeps `folds` in an `AutoArrayHashMap`, shifted in place + `reIndex` after edits.

*// changed 2026-09-05 (split-buffers):* `Editor` is one window's **view** of a `Document`, not the text. `Document` (`editor/document.zig`) owns the bytes, the line index, the edit log, the undo history, the change list and the file (path, dirty, marks, save settings); `Editor` (a heap box) holds `doc: *Document` plus the cursor, anchor, goal column, multi-cursor extras, block state, replace stack and folds. `apply_one` runs on the view and every splice goes through `Document.spliceBy`, which shifts every other view's positions by the byte delta (vim's one buffer, N windows). Documents are refcounted by their views; the app's `DocStore` keeps the per-document syntax state beside each and drops both with the last view. `Buffer` is a window (`*Editor` + `InputHandler` + dot/macro state); `Buffer.initOn(doc)` is what `:vsplit` makes.

### D4b. Keymap profiles — vim and standard are first-class, each complete (added 2026-09-04)

User requirement: vim users get hotkeys/chords that match **Neovim + NvChad** exactly; standard users get **VS Code**. Segregate so each feels at home. Mechanism:
- `Spec.keys` becomes `Keys{ vim: []const []const u8 = &.{}, standard: []const []const u8 = &.{}, both: []const []const u8 = &.{} }`. A command declares its chord per profile (`picker.files`: vim `space f f`, standard `ctrl+p`). **No strip-list** — the vim profile simply never binds `ctrl+w/g/d/u/e/y/r/n/h/j/t/f/b/o` to non-vim things.
- The vim profile's defaults are derived from NvChad's `mappings.lua` (leader menus: `<leader>f*` find, `<leader>g*`/`cm` git, `<leader>t*` themes/terms, `<leader>x` close buffer, `<Tab>/<S-Tab>` bufferline, `<C-n>`/`<leader>e` tree, `<C-h/j/k/l>` window nav, `<leader>/` comment, `<leader>fm` format, `<leader>ra`/`ca`, `gd/gD/gr/K`, `[d ]d`, `<leader>ch` cheatsheet, `<leader>wK` which-key) plus Neovim defaults; the standard profile from VS Code (`ctrl+p`, `ctrl+shift+p`, `ctrl+b`, `` ctrl+` ``, `ctrl+shift+e/f/g/d`, `f12`, `ctrl+.`, `f2`, `ctrl+/`, `alt+↑↓`, `ctrl+d`, `ctrl+g`, …). A pinned test asserts the profile tables against a checked-in reference list so drift is a test failure.
- Comptime: chord collisions checked **per profile**; every spec parses; `[keys.global]` still applies to both, `[keys.vim]`/`[keys.standard]` overlay their profile.
- Which-key, cheatsheet, tooltips, and the palette's key hints render **per active profile**.
- **Kitty-keyboard fallbacks:** chords only distinguishable under the kitty keyboard protocol (`ctrl+shift+p`, `alt+i`, `ctrl+;`, `ctrl+enter`) declare an alternate for terminals without it (`Keys.standard_legacy` or a `fallback:` on the spec) — ghostty is first-class, Windows Terminal/xterm must still reach every command.
- Backport candidate: the same per-profile `keys` split in Rust `Command`.

### D5. Commands — comptime `CommandId` enum derived from a spec table

```zig
// commands/specs.zig — 797 literals, NO fn pointers
pub const Spec = struct { id: [:0]const u8, title: []const u8, group: []const u8, keys: []const []const u8 = &.{} };
pub const specs = [_]Spec{ .{ .id = "app.quit", .title = "Quit mnml", .group = "app", .keys = &.{"ctrl+q"} }, … };
// command.zig
pub const CommandId = blk: { @setEvalBranchQuota(100_000); /* @Type enum with field name == string id */ };
pub const by_name = std.StaticStringMap(CommandId).initComptime(…);     // "git.commit" ↔ CommandId.@"git.commit"; @tagName gives the external name
pub const runners: std.enums.EnumArray(CommandId, CommandFn) = /* merged from commands/<ns>.zig `pub const table = .{ .@"git.commit" = &commit, … }`; missing runner ⇒ @compileError */;
```
The four Rust source-scanning tests become comptime facts: `MenuAction{.command = CommandId}` cannot name a missing id; dead call sites impossible; chord-ownership + `group == namespace` are comptime loops ending in `@compileError`. *// changed 2026-09-04 (trunk):* the `group == namespace` check is scoped to the panel namespaces (`todos/notes/findings/sessions/http`), exactly as the Rust test is — 140 commands legitimately file under a finer palette group (`picker.files` → "go"). Zig 0.16 spells the enum construction `@Enum(u16, .exhaustive, names, values)`; `@Type` is gone. Dynamic commands (IPC/manifest/Lua): runtime `ArrayList(DynCommand)` + `StringHashMap`; string resolution = `by_name.get(s) orelse dyn.get(s)`. During the port, a `-Dpartial` build option gates the "every id has a runner" check.

### D6. Component system — immediate mode + first-class `HitMap`, `Ui` context instead of `*App`

Rust's flaw isn't immediate mode; it's the side channel (271-field `PaneRects`, hand-cleared, hand-routed in a 4558-line `down_left.rs`). Formalize the side channel:

```zig
pub const Rect = struct { x: u16, y: u16, w: u16, h: u16,  /* contains/inset/splitTop/splitRight/rightCells */ };
pub const Canvas = struct { screen: *vaxis.Screen, clip: Rect,      // we do NOT own a grid; vaxis.Screen is tty-free ⇒ headless/e2e/Mount all render into it
    pub fn sub(c, r: Rect) Canvas;  pub fn put(c, x, y, cell: Cell) void;   // clipped writeCell (pty/mount blits)
    pub fn fill(c, r, style) void;                                          // ratatui Clear
    pub fn text(c, r, segs: []const Segment, o: TextOpts) u16;              // ratatui Paragraph: wrap none|word|grapheme, align; returns rows used
    pub fn border(c, r, kind, style, title: ?[]const Segment) Rect;         // ratatui Block → inner rect
    pub fn clipCells(c, arena, s: []const u8, max: u16) []const u8;         // clip_to_cells, gwidth-aware
};
pub const HitTarget = union(enum) { pane: PaneId, divider: DividerId, tab: struct{leaf, idx}, row: struct{panel: PanelId, idx: u32},
    kebab: struct{panel, idx}, chip: struct{panel, kind: ChipKind}, filter_input: PanelId, scrollbar: ScrollbarHit, button: ButtonId,
    link: struct{url}, menu_item: struct{menu, idx}, statusline_seg: SegmentId, tree_node: u32, script_hit: struct{pane, id}, … };  // ~30 variants
pub const HitMap = struct { items: ArrayListUnmanaged(struct{rect: Rect, target: HitTarget}),   // frame arena
    pub fn add(h, r, t) void;  pub fn at(h, x, y) ?HitTarget { /* scan back-to-front: last painted wins ⇒ overlays win */ }
    pub fn writeRectsJson(h, w: *Io.Writer) !void; };                                            // ipc rects.json for free
pub const Ui = struct { canvas: Canvas, hits: *HitMap, theme: *const Theme, arena: Allocator, focus: FocusId, hover: ?struct{x,y}, ascii: bool, nerd_font: bool };
```
A component = `State` (persistent transient: scroll, hover_row, filter buf — owned by its subsystem's state in App) + `fn draw(state: *State, ui: Ui, area: Rect, props: Props) void`. Layout is the parent's job (`Rect.split*`); paint via `ui.canvas`; **hit-test registered in the same statement as the paint** (`ui.hits.add(rr, .{.row = …})`) — painted-but-unregistered rects become impossible. Mouse dispatch = one `switch (app.hits.at(x, y))` in `tui/mouse.zig`. Keyboard reaches a panel via `handleKey` on its state. Generic containers are comptime: `ListPanel(Row)` (caps header + sort/refresh chip ladder + filter row + scroll window + scrollbar + kebab-on-hover) — written once, called by TODOS/NOTES/FINDINGS/SESSIONS. vaxis: `Screen` as cell store, `Vaxis.render(tty)` for diff/output, `Window` NOT used (Canvas carries clip + theme). `theme::cur()` (global by-value, 1600 sites) → `ui.theme: *const Theme`.

### D6b. Strips — the activity bar is for panels, the launcher dock for launchers (added 2026-09-21)

Two strips, split by **kind**, never by taste. `ui/activity_bar.zig`'s
`StripKind = enum { panel, launcher, integration, terminal, pinned_panel }`
is the vocabulary: every rail row is `.panel` (`Section.kind`), every
dock item is `.launcher` / `.integration` / `.terminal`
(`launcher_dock.stripKind(Item.kind)`), and a section moved onto the
dock is `.pinned_panel` — still a panel, listed on the other strip.

Membership is two config knobs and nothing else. `ui.rail.hidden`
(`[]const Config.RailSection`, the eleven rail tags spelled in the config
layer so it does not import a painter; a unit test holds the two lists
together) is what the bar leaves out — the painter drops those rows
(`railOrder` / `defaultRows`) and lays out what it paints
(`layoutRows`), so the grip and band arithmetic never moves: hiding a
row hides a row, in the same three columns. `ui.dock.pins` is what the
dock carries besides its launchers, and a section's `view.activity_*`
command there is what "on the dock" means. The four menu rows (*Hide
from activity bar*, *Show on dock instead*, *Show hidden sections ▸*,
*Move back to activity bar*) are `MenuAction.rail_*` carrying the
section the menu was opened on; the three `view.rail_*` commands act on
the marked section. A hidden section keeps its command and keys.

A later "kinds per strip" config (say, terminals on the bar) is a
filter over `StripKind` at the two `items` / `props` builders — a small
step, which is why the kinds are on the model now with no behaviour
hanging off them.

### D7. App state — grouped by subsystem

```zig
pub const App = struct {
    gpa: Allocator, io: Io, frame: ArenaAllocator, events: EventQueue, diag: Diag, timers: Timers,
    cfg: Config, theme: Theme, ws: Workspace, quit: bool = false, restart: bool = false,
    panes: PaneStore, layouts: LayoutState, focus: Focus, hits: HitMap, screen: vaxis.Screen,
    git: git.State, lsp: lsp.State, dap: dap.State, cdp: cdp.State, http: http.State, ai: ai.State,
    todos: todos.State, notes: notes.State, findings: findings.State, sessions: sessions.State,
    overlays: Overlays, toasts: Toasts, statusline: statusline.State, ipc: ipc.State, hooks: Hooks, lua: ?Lua, …
};
```
Each `<sub>.State` lives in `src/<sub>.zig` with its `handle(app, ev)`, its commands `table`, and its panel `draw(app, ui, area)` glue. `*App` is the parameter for commands + event handlers (they cross subsystems); **components never see it**.

*// changed 2026-09-07 (section-side):* the frame has no sidebar-or-right-panel split and no `App.right_panel` slot. Every activity section has a **side** (`src/app/side.zig`: `State{ of, open, last, prev, right_width }` on `App.side`, `place` / `remove` the only writes); the frame is two columns — left with the rail down its edge, right — and each column shows one section (`render.frameRects` carves both under Rust's 21-column clamp). Rust's right-panel panes (outline, diagnostics) are sections with a side and no rail row; `view.move_section_left` / `_right`, `:sidebar left|right`, vim `Ctrl-W H` / `L` in a section and the rail menu move one; `ui.sidebar_side` / `ui.section_side` are the starting point and `session.zon` keeps the sides. The D6 `HitTarget` grew the same way — `rail`, `gutter`, `breadcrumb`, `tree_root`, `tree_chip`, `git_palette`, `info_view` — each registered in the statement that paints it.

*// changed 2026-09-14 (bottom-dock):* a section has THREE places to live, not two. `Config.Side` gained `.bottom` — the dock under the whole frame, Rust's bottom panel — so `State{ of, open, last, prev, came_from, right_width, bottom_height }` and every walk over the hosts (`sectionsOn`, `toggleColumn`, `step`, `move`, `dropFocus`) reach it without a branch; `side.size` / `setSize` read cells across for a column and rows down for the dock. `render.frameRects` carves it off `upper` BEFORE the columns (so they all sit above it, as Rust's does), capped at two thirds of `upper` with two rows left for the body. The dock also HOSTS A PANE (`src/app/bottom.zig`): the pane leaves the split tree and lives in `App.bottom.panes` — in `App.panes`, out of the layout, `outline_panel`'s shape — behind a tab strip, and `render.drawPaneContent` is the leaf's own per-kind painter, lifted out of `drawBody` so the dock does not get a second copy. `ui.bottom_panel_visible` / `_height`, `Ctrl-W J` / `K`, `:sidebar bottom`, and the dock's section + height in `session.zon`. The two command ids are Rust's own (`view.toggle_bottom_panel`, `view.host_active_in_bottom_panel`, both un-cut); no id was added, so the spec count is still 1068.

### D8. Reference module — `src/todos.zig` (~600 lines, hand-written first)

Smallest subsystem that exercises every convention: a scan worker in `todos.group` posting `.todos = *ScanResult` (payload ownership, errdefer, cancel-on-rescan); a snapshot arena for items; `handle(app, ev)` adopting the payload; three commands (`todos.refresh/new/cycle_sort`) with a `diag.fail` path; a right-click sort menu via `MenuAction{.command}`; the `ListPanel` draw with `paintRow`; mouse prongs for `.row/.kebab/.chip/.filter_input`; tests on `std.testing.allocator`; one `.test` e2e. It forces the minimal trunk into existence: `app.zig`, `event.zig`, `command.zig` + `commands/specs.zig` (797 ids, only todos runners, `-Dpartial`), `ui/{rect,canvas,hit,ui,header,chip,scrollbar,filter_input,empty_state,list_panel}.zig`, `tui/loop.zig`. Every later subsystem is generated against it as the template.

*// changed 2026-09-04 (todos):* the module landed as `src/todos.zig` (~1150 lines with its tests). The command is `todos.sort`, not `cycle_sort` (the spec table is Rust's), and three Zig-only ids — `todos.open` / `todos.copy_path` / `todos.ignore_file` — give the kebab menu rows a `MenuAction{ .command }` to name (spec count 800). The scanning spinner overpaints the refresh chip from `draw` because `ListPanel.Props` has no busy flag yet. `App.tick` drains the queue (`pumpEvents`) so the `.test` and headless drivers receive the worker's result without a vtable change. The right-panel slot (`App.right_panel`) and the context-menu overlay (`Overlay.menu`) were built alongside because the module needs somewhere to draw and something for the sort chip's right-click to open. The e2e lives in `tests/e2e/` — `tests/e2e` is a symlink into the Rust suite whose runner would run a Zig-only file. *// changed 2026-09-07:* both are gone — the slot became a side (section-side note under D7) and the folder is a real copy (the note at the top of the Context section). `docs/CONVENTIONS.md` → "The reference module" maps each convention to its lines.

### D9. Backport list → Rust mnml
- One `mpsc::Receiver<AppEvent>` + `enum AppEvent`; delete 31 receivers / 35 `drain_*`.
- Wakeup-driven loop: crossterm input on its own thread posting into that channel + `recv_timeout(next_deadline)`; idle CPU → 0.
- Pty: `ringbuf` + `AtomicBool` "readable" instead of `Sender<Vec<u8>>` per 8 KiB.
- `HitMap` + `HitTarget` enum: `Vec<(Rect, HitTarget)>` per frame; one `match` in `dispatch_mouse` replaces `down_left.rs` (4558 lines) + 271-field `PaneRects`; `rects.json` derived.
- `Ui<'a>` context (`frame, hits, theme, focus, hover, ascii`) instead of `&mut App` in painters.
- `ListPanel<Row>` widget: TODOS/NOTES/FINDINGS/SESSIONS collapse to one.
- `build.rs`-generated `enum CommandId` + `static SPECS`; `MenuAction::Command(CommandId)`; the four source-scanning tests become compile errors.
- `fn(&mut App) -> Result<(), CommandError>` + `Diag`; delete `last_command_failed`.
- Per-job `oneshot::Sender<bool>` for AI confirm instead of the global `HashMap<u64, Sender>`.
- `apply_one` prongs delegate to `editor/{motion,insert,delete,…}.rs`.
- Per-subsystem `CancellationToken` + joined `JoinHandle`s on drop, replacing "drop the Sender".

### D10. Scripting seams (Lua) — ZON for data, Lua for behavior; ships post-spike

Lua via `zlua` (ziglua; Lua **5.4** compiled from C inside `build.zig`). `LuaRef = u32` (registry ref) so the seams compile with Lua absent. Three seams fixed in the trunk:

**Commands.** `DynCommand{ id, title, group, keys (gpa-owned), runner: union(enum){ ex: []u8, ipc: void, lua: LuaRef }, owner: Owner{integration(id) | script | ipc} }`; `CommandRef = union(enum){ static: CommandId, dyn: u32 }`. `run` dispatches `.lua` → `L.rawGetIndex(registry, r)`, `armBudget`, `protectedCall`; error → `diag.fail` with the Lua message. `mnml.command{ id, title, group, keys, run = fn }` registers as `user.<id>` so it works unchanged in `.keys`, `.test`, IPC. `mnml.map(spec, fn)` = anon command + `keymap.bind`. Script reload = bulk-unregister `owner == .script` + keymap rebuild.

**Hooks.** Curated set: `Hook = enum{ startup, exit, open, save_pre, save_post, buffer_change (debounced 150ms), diagnostics, pane_focus, lsp_attach, git_status }`; `HookArgs = union(Hook)` with flat string/int/enum payloads (so `pushAny` needs no custom handlers); `Subscriber = union(enum){ zig: *const fn(*App, HookArgs) void, lua: LuaRef }`; `Hooks{ subs: EnumArray(Hook, ArrayListUnmanaged(Subscriber)) }.emit(app, args)`. Emit points are explicit lines (file open/save, `lsp.handle`, `focus.set`, tick debounce, `git.handle`). **Zig subscribers exist from day one** (statusline, todos rescan-on-save) so the seam is exercised before Lua. **UI thread only** (assert `getCurrentId() == app.ui_thread`); workers never see `*Lua`. **Budget:** `L.setHook(count=100_000)` + 20 ms deadline → `error.Failed` + toast; never called under a lock or inside render.

**Components.** `Pane.script: ScriptPane{ title, render: LuaRef, on_hit?, on_key?, state }` — Lua `render(w,h)` returns `{ { {text, fg="red", bold, hit=3}, … }, … }` → `toAny` into `[][]Segment` in `app.frame`; styles by theme-key name (scripts never see color values); painted via `Canvas`, hits registered as `.script_hit{pane, id}`; one mouse prong `.script_hit => callHit`. Smaller earlier wins on the same marshalling: `mnml.statusline.segment{id, side, fn}` (polled ≤250 ms) and `mnml.picker.source{id, items = fn(query)}` (picker `Source` union gains `.lua`).

**Must-nots.** No `*App` exposed; buffer mutation only via `mnml.buf.apply(pane, {op=…})` → `EditOp` → `Buffer.apply` (undo/dot-repeat/LSP didChange/tree-sitter all fire); reads are frame-arena copies; `os`/`io` libs not opened — shelling is `mnml.task.run{cmd, on_done}`; no threads. Strings: registration-time → `gpa.dupe`, transient → `app.frame`, never hold `L.toString` slices past the call.

**Spike checks:** zlua builds on 0.16.0 (the `std.Build` API is the risk, not the C); `pushAny` on `HookArgs` / `toAny` into `EditOp` + `[]Segment` with a frame-arena allocator; a `sethook` error propagates through `protectedCall`; `ref/unref` round-trips a reload leak-free under `std.testing.allocator`.

---

## Design — external surfaces, migration, release

### E1. ZON config

`std.zon.parse` honors struct defaults, tagged unions, enums, optionals, slices — but has **no map type and no custom-parse hook**. Six sections are user-keyed maps (`keys.<style>`, `snippets.<scope>`, `lsp.<name>`, `tasks`, `formatters`, `linters`, `dap`, `abbr`). Loader = two passes over `Zoir`: `std.zig.Ast.parse(.zon)` + `ZonGen` → walk top-level `struct_literal.names`; fixed sections → `fromZoirNode(Patch(Section))`; map sections → iterate names/vals → `fromZoirNode(ValueType)`. ~150 lines in `src/config/load.zig`. Buys `.@"ctrl+p" = "…"` map syntax, typed map values, duplicate-key rejection (ZonGen), **per-section failure isolation** with `file:line:col` diagnostics.

```zig
pub const Config = struct {
    editor: Editor = .{}, ui: Ui = .{}, session: struct { restore: bool = true } = .{}, ipc: struct { write_screen: bool = false } = .{},
    cloud_run: CloudRun = .{}, jira: Jira = .{}, cloud_agents: CloudAgents = .{}, keys: Keys = .{}, lsp: Map(LspServer) = .{},
    ai: Ai = .{}, tools: Tools = .{}, http: Http = .{}, ws: Ws = .{}, sonos: Sonos = .{}, git_graph: struct { lane_spacing: u16 = 2 } = .{},
    tasks: Map(Task) = .{}, startup: Startup = .{},   // tasks + layout + default_workspace collapse into one section
    snippets: Map(Map([]const u8)) = .{}, abbr: Map([]const u8) = .{}, formatters: Map(Formatter) = .{}, linters: Map(Linter) = .{},
    dap: Map(DapAdapter) = .{}, browser: Browser = .{}, ci: Ci = .{}, integrations: Integrations = .{}, workspaces: []const Workspace = &.{}, marketplace: Marketplace = .{},
};
pub const Editor = struct { input_style: enum { vim, standard } = .standard, tab_width: u8 = 4, breadcrumb: bool = true, chord_timeout_ms: u16 = 500,
    wheel_moves_cursor: enum { auto, always, never } = .auto, scroll_accel: enum { off, gentle, normal, fast } = .normal, /* …20 fields */ };
pub const ListSort = enum { newest, oldest, name, name_desc };
pub const MdEngine = union(enum) { builtin, glow, pandoc, custom: []const u8 };
```
**Real enums** for every field Rust validates with `matches!`: editor `input_style/wheel_moves_cursor/scroll_accel`; ui `*_sort: ListSort`, `picker_position{center,top}`, `now_playing_source`, `preferred_music_app`, `menu_bar{always,auto,hidden}`, `bufferline_diag_style{count,dot,off}`, `coverage_chip_mode`, `expand_indicator`, `top_bar_cluster_mode`, `tab_bar_ai_icon`, `ai_layout_mode{grid,tabs}`, `md_preview_engine → MdEngine`; browser `profile_mode`; http `collection_root{hidden,workspace}`; startup layout `kind{editor,pty}`, `split{right,down}`; marketplace source → `union(enum){crates_keyword, github_launcher_folder, github_monorepo_apps}`. Strings stay for `theme` (open set), colors, labels.

**Three-layer merge** via comptime-derived `Patch(T)` (leaves → `?Leaf`, nested → `?Patch(S)`, maps entry-merge, slices whole-replace): `apply(&cfg, parseLayer(home), .trusted); apply(…workspace…, trust); apply(…explicit…, .trusted)`. "Parse full + diff against default" rejected — can't distinguish "user set default value" from "omitted". **Workspace trust** = one comptime `exec_bearing` table (`ui.external_browser`, `ui.md_preview_engine .custom`, `lsp.*.cmd/args`, `startup.layout[] kind==.pty`, `formatters`, `linters`, `dap`) driving both the stripper and the trust-dialog fingerprint. **Keys stay map form** `.keys = .{ .global = .{ .@"ctrl+p" = "picker.files", .@"space f f" = …, .@"ctrl+shift+p" = "none" } }` (one line per binding; ZonGen rejects duplicates). **Free-form sections become typed**: `LspServer{cmd?, args, extensions, root_markers, settings: Dynamic, initialization_options: Dynamic}`, `DapAdapter{cmd, args, launch: Dynamic}`, `Ai{backend?, inline_suggestions, claude_show_all_accounts: bool, extra: Dynamic}` — `Dynamic` is a ~120-line ZON value tree with `toJson` used only for verbatim forwarding.

**Write path: AST-guided splice, not Serializer round-trip.** `persistScalar(path, literal)`: parse → locate node by walking struct-literal field names → replace value byte span; field missing → insert before section `}` preserving indent; section missing → append before top-level `}`. Comments/order survive. ~20 `persist_*` collapse to one fn + `std.zon.Serializer` for the literal. Full-file `Serializer` only for `mnml config export`.

Paths: `~/.config/mnml/config.zon`, `<ws>/.mnml/config.zon`, `--config`. `homeConfigPath()` keeps the 4-branch precedence incl. `MNML_DATA_ROOT`; `data_root()` unchanged. Backups `<root>/backups/config.<ts>.zon`, prune to 50 matching `config.*.zon`.

### E2. Migration — no TOML in Zig

- **User config:** final Rust release **0.2.22** adds `mnml export-config-zon [--out P]` (it has `toml` + typed `Config`; emits ZON with a `//` doc comment per key from a comptime doc table). Not automatic; documented in the 0.3.0 changelog + troubleshooting. Key transforms: `[abbr]`→`.abbr`; `[startup] tasks`+`[[startup.layout]]`+`default_workspace`→`.startup`; `[[marketplace.source]] type=`→tagged union; `[[ui.integration_icon]]`→`.ui.integration_icons`; `md_preview_engine="custom:x"`→`.{.custom="x"}`; formatter/linter string-or-list→list; `claude_show_all_accounts` bool-or-string→bool; legacy glyph remaps; `DEAD_INTEGRATION_IDS` dropped; unknown keys → trailing `// unmigrated:` block.
- **Themes:** one-time `toml2zon` over the 94 files (throwaway script or the Rust binary), committed to `mnml-zig/themes/*.zon`, `@import`ed at comptime as typed `Theme` — malformed theme = compile error. `--theme-dir` runtime override parses ZON.
- **Integration manifests:** ZON at `~/.config/mnml/integrations/<id>.zon`, written by the new SDK. Old `.toml` manifests ignored.
- `session.json`, `.rqst/history.jsonl`: JSON via `std.json`; session read best-effort with `ignore_unknown_fields`, written in the Zig format.

### E3. Key grammar + command ids — keep, plus `<C-p>` pre-pass
`parseKeySpec` reproduces `parse_key_spec` exactly and is **comptime-callable**, so every default `keys` in the spec table is validated at build. Addition: a normalizing pre-pass when the spec contains `<`: `<C-p>`→`ctrl+p`, `<S-Tab>`→`shift+tab`, `<M-x>|<A-x>`→`alt+x`, `<D-x>`→`super+x`, `<CR>`, `<Esc>`, `<Space>|<leader>`→`space`, `<F5>`; chars outside groups → one chord each (`<leader>ia` → `space i a`). Canonical form is stored/displayed. **All 797 ids unchanged**; future renames get an alias table.

### E4. IPC — keep byte-identical
Files, `RawCommand` JSONL schema, reader mechanics, init behavior all preserved. Two dumpers with golden tests: `toScreenTxt` (trim_end + trailing `\n`) and `toTestText` (no trim, no trailing). `status.json` via `std.json.Stringify` over a struct in the current key order, golden-tested against a captured 0.2.21 sample. `events.jsonl` string-valued as today. Additive changes OK; no removals/renames before 0.4. **Overlap namespacing:** Zig host honors `MNML_IPC_DIR` for itself (default `<ws>/.mnml/ipc`); dev builds `-Dipc-subdir=ipc-zig` + marker `mnml-zig-running-${USER}.workspace`; `run.sh` gains `MNML_BIN`/`MNML_IPC_SUBDIR`; 0.3.0 flips defaults back.

### E5. Bridge — protocol v2, integrations re-issued
Not a compat constraint. Keep the *shape* that works (Unix socket incl. Windows via `std.Io.net.UnixAddress` — `has_unix_sockets` true on Win10 RS4+; 4-byte LE length-prefixed JSON, ≤16 MiB; full frames; `Hello/Resize/Input/Goodbye` ↔ `Frame/Bye`) but design the encoding fresh: drop the untagged `RgbOrIndex` quirk, add `protocol: u8` to Hello, consider dirty-rect frames. **SDK is Zig-native** (`mnml-sdk` Zig package: Mount client, manifest writer, IPC tier-2 helpers) — integrations are **rewritten in Zig**, not re-issued in Rust. **First two: jira, bitbucket.** This is a post-cutover phase ("not now"); the Rust `mnml-bridge` 0.8 crate stays published for anyone on 0.2.x. Launcher TOMLs → ZON. Manifest path stays `~/.config/mnml/integrations/`.

### E6. Release pipeline
**Windows stays `x86_64-windows-gnu`** (ghostty msvc "doesn't work yet"; mingw-w64 is bundled; msvc cross needs a Windows SDK). `build.zig`: libghostty-vt as a `build.zig.zon` git dep at the **newest ghostty ref that builds on Zig 0.16.0 stable** (NOT the Rust repo's `6837d702` pin — that existed for the vendored-header C-ABI path; zon records a content hash regardless, bump with `zig fetch --save`); tree-sitter + 43 grammars in-tree; `-Dcpu=baseline`; **`-Doptimize=ReleaseSafe` for every shipped artifact**; asset filenames keep the Rust triple names (`mnml-aarch64-apple-darwin.tar.xz`) so tap/winget/nfpm scripts are unchanged. Workflows: **ci.yml** (ubuntu/macos/windows matrix; `zig fmt --check`; `zig build test` in Debug AND ReleaseSafe; `zig build e2e -- --widths 80,120,200`; ubuntu also cross-compiles all 5 targets — Zig's lazy analysis only type-checks target-gated code when you build that target); **release.yml** on `v*`: one ubuntu runner cross-compiles all 5, packages `.tar.xz`/`.zip` + sha256, renders `install.sh`/`install.ps1` from `dist/` templates, creates the release; `msi` job on windows-latest (WiX) for winget; then `bump-homebrew-tap.yml`, `winget-releaser.yml`, `package-linux.yml` (nfpm) copied over; `site.yml` unchanged. `release-plz` stays in the Rust repo; `mnml-rs` freezes at 0.2.22 (`publish = false` after). `mnml-zig` tags `v0.3.0` at cutover.

### E7. Safety gates
*// changed 2026-09-07:* `zig build check` = `zig fmt --check` → Debug unit tests → ReleaseSafe unit tests → the gate (`tools/gate.txt`) at 120×40 → the same gate swept at 80×24 / 120×40 / 200×60 → `defaults.test` → the full corpus; `zig build gate-build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe` is the cross-target gate (the exe and every test binary, not run); `zig build glyph-audit` and `tools/pty-mouse-check.py` are the two checks outside `check`. `std.testing.allocator` everywhere; e2e runner on `DebugAllocator(.{.safety=true,.thread_safe=true})` with `assert(deinit()==.ok)` per file; suite runs in Debug + ReleaseSafe; width sweep 80/120/200 (`# width: 120` header opts a file out); comptime: menu ids resolve, default keyspecs parse, dup ids + chord collisions = `@compileError`; themes parse at comptime; `defaults.test` asserts shipped `Config{}` values; cross-compile all 5 on every PR; `std.testing.fuzz` on `parseKeySpec`, IPC `RawCommand`, ZON loader, bridge frame parser. Process: every generated test ships its break-check (revert fix → show failure → grep the assertion) in the PR body; tests assert shipped defaults; cosmetic `.test` re-skins say so in the commit.

### E8. Docs
`manual-writer` keeps generating from `FEATURES.md` + source; `site/.docs-sync-marker` tracks the mnml-zig HEAD after the move. Config examples → ZON; `changelog.mdx` + `troubleshooting.md` get the 0.2.x→0.3.0 note (`mnml export-config-zon`); `commands.md` regenerated by `zig build docs` from the comptime table (fixes the 695-vs-797 drift); integration authoring page → SDK v2 + `<leader>` alias.

---

## Research findings (appendix — raw material for design)

### A. Spine (`src/input`, `src/edit_op.rs`, `src/editor`, `src/buffer.rs`, `src/command.rs`, `src/pane.rs`, `src/layout.rs`)

**InputHandler** — `src/input/mod.rs:252`. The ONLY trait in the spine. 2 implementors (`standard.rs:158`, `vim.rs:4212`). 17 methods, 15 defaulted; required: `handle_key(&mut self, KeyEvent, &EditCtx) -> InputResult`, `mode() -> EditingMode`, `name() -> &'static str`. Others: `pending_display`, `is_cmdline_open`, `is_op_pending`, `on_blur`, `set_ex_history/ex_history`, `operator_menu_hint`, `request_insert_mode/visual_mode`, `cmdline_get/set/caret/set_caret`. `Box<dyn>` at 4 sites: `make_handler_for`/`make_handler` (`mod.rs:333,342`) + `Buffer.input: Box<dyn InputHandler>` (`buffer.rs:236`, per-buffer).

```rust
pub enum InputResult { Ops(Vec<EditOp>), Consumed, Ignored, App(AppCommand) }   // mod.rs:206
pub struct EditCtx { /* 13 Copy fields: cursor, line_len, line_idx, line_count, at_line_start, at_line_end, has_selection, line_first_nonws_col, cursor_col, next_find_match, prev_find_match, wrap_width */ } // mod.rs:219
pub enum EditingMode { None, Normal, Insert, Replace, Visual, VisualLine, VisualBlock }  // mod.rs:21 — only handler fact render may read
pub enum AppCommand { /* 22 variants */ Save, ExCommand(String), RunCommand(String), DotRepeat(u32), SetMark(char), JumpToMarkLine(char), JumpToMarkExact(char), MacroRecordInto(char), MacroReplayFrom{reg,count}, BlockInsertStart{append}, BlockChangeStart, BlockReplaceWith{ch}, FilterLinesFromCursor{count}, FilterParagraphFromCursor{around}, RepeatInsertStart{count,above}, OperatorLinewiseTo{op,target}, CmdlineTabComplete, CmdlinePopupMove(i8), CmdlineEnter(String), CmdlineInsertCursorWord(bool), CmdlinePasteFromClipboard, FlashStart(char,char) } // mod.rs:180
```
`VimInputHandler` (`vim.rs:354`): 24 plain fields (mode, count, op: Option<PendingOp>, prefix: Prefix, cmdline, registers, macro flag, ex_history cap 100, …). `PendingOp` 11 variants, `Prefix` ~21. `handle_key` at `vim.rs:4223` dispatches on mode. `StandardInputHandler` (`standard.rs:106`): 2 fields (`tab_width`, `overrides: HashMap<Chord, StandardAction>`). Line counts: mod 352, standard 856, **vim 5382**, keymap 671.

**keymap.rs** — fully runtime. `Chord{code,mods}` (Copy), `Keymap{map: HashMap<Vec<Chord>,String>, prefixes: HashSet<Vec<Chord>>}`. `build(cfg)` order: registry defaults → vim strips `ctrl+w/g/d/u/e/y/r/n/h/j/t/f` → `[keys.global]` → `[keys.<style>]`. Collisions warn to stderr only. `resolve_seq -> SeqResolution<'a>{Run,Pending,PendingWithFallback,None}`. Rebuilt on config reload. Defaults side (`Command.keys: &'static [&'static str]`) is static → comptime-able; user overlay stays runtime.

**EditOp** — `src/edit_op.rs:7`, **131 variants**, 32 with payload. Only heap: `Repeat(u32, Box<EditOp>)` (:494), `Atomic(Vec<EditOp>)` (:510), `InsertStr(String)`, `ReplaceSelection(String)`, `ReplaceRange{start,end,text:String}`.
```rust
pub struct EditOutcome { buffer_changed: bool, cursor_moved: bool, clipboard_set: Option<String>, clipboard_linewise: bool, text_edits: Vec<TextEdit>, yanked_range: Option<(usize,usize)> } // edit_op.rs:634
// CONTRACT: buffer_changed && text_edits.is_empty() ⇒ drop parse tree
```
**Editor** — `src/editor/mod.rs:802`, 26 fields: `text: String`, `cursor: usize` (byte), `anchor: Option<usize>`, `goal_col`, `line_starts: RefCell<Option<Vec<usize>>>` (lazy), `undo/redo: Vec<Snapshot>` (**full-text snapshots**, `UNDO_LIMIT=2000`, `Vec::remove(0)` O(n) on overflow), `extra_cursors/extra_anchors`, `change_list` (cap 100), `ghost_suggestion`, etc. `apply(&mut self, op, viewport_rows, clip: &mut Clipboard) -> EditOutcome` at :2016 (77-line wrapper) → `apply_one` **:2094–4624, ~2530 lines, one match over 131 variants**. `atomic_undo<R>(impl FnOnce)` :1989. Persistent undo: `editor/persistent_undo.rs` (147 lines, serde-JSON of snapshot stacks).

**Buffer** — `src/buffer.rs:203`, ~43 fields: `editor`, `input: Box<dyn InputHandler>`, `parse_tree: Option<tree_sitter::Tree>`, `marks: HashMap<char,(usize,usize)>`, `folds: BTreeMap<usize,usize>`, `outline_cache: RefCell<…>`, 12 LSP-payload Vecs. **THE seam:** `feed_key(&mut self, key, clipboard, viewport_rows, wrap_width) -> BufferEvent` (:933) — the only place `InputResult` is destructured (:946, :1016). `BufferEvent { Edited, Redraw, Unhandled(KeyEvent), App(AppCommand), NoOp }` (:182).

**Command** — `src/command.rs` (8209 lines):
```rust
pub type CommandFn = fn(&mut App);                                   // :17 — plain fn ptr
pub struct Command { id: &'static str, title: &'static str, group: &'static str, keys: &'static [&'static str], run: CommandFn } // :53
pub struct Registry { commands: Vec<Command>, by_id: HashMap<&'static str, usize> }  // :106
pub fn registry() -> &'static Registry  // :151 — OnceLock, Registry::build debug_asserts dup ids
pub fn run(id: &str, app: &mut App) -> bool  // :157 — static → dynamic → toast "no such command"; failure via app.last_command_failed (out-of-band)
```
`builtin_commands()` (:329) = ONE `vec![]` of **797 `Command{}` literals** (lines 331–7893). No `register()` fn. 172 `command::run(` call sites. `DynCommand{id:String,title,group,keys:Vec<String>,ex_run:Option<String>,owner_integration_id}` (:84) for IPC/manifest-registered; 2 call sites. Structural tests (all source-text scanning): `every_menu_command_id_is_registered` (:8095, scans for `MenuAction::Command("` — 361 occurrences/13 files), `dead_call_site_tests` (:7909), `chord_ownership_tests` (:8005), `command_group_tests` (:8175). Ids: `<ns>.<snake_verb>`, 797 unique; top ns: view 125, http 77, ai 62, editor 61, git 57, lsp 33, browser 33. `commands.md` says 695 — STALE.

**Pane** — `src/pane.rs:29`, **31 variants, each a single owned newtype**: Editor(Buffer), MdPreview, Diff, GitGraph, GitStatus, Request, Pty(PtySession), Ai, Tests, Flaky, Outline, Files, Browser, Diagnostics, Grep, Quickfix, CmdlineHistory, Cheatsheet, Debug, DapRepl, Image, ClaudeAgents, Websocket, SpendReport, Mount, CloudAgentRun, NewCloudRunWizard, NewCloudAgentWizard, IntegrationDetail, +2. Already a tagged union. Only Rust-isms: `impl Drop for SpendReportPane` + its `Arc<AtomicBool>` + 3 mpsc.

**Layout** — `src/layout.rs:24`: `type PaneId = usize` (index into `App.panes`); `enum Layout { Empty, Leaf{active: PaneId, tabs: Vec<PaneId>}, Split{dir, ratio: u16 (10..=90), first: Box<Layout>, second: Box<Layout>} }`. Invariants (:1-7): no pane in two leaves across all tab pages; focused pane always in a leaf. `compute_rects(&self, Rect) -> (Vec<(PaneId,Rect)>, Vec<DividerRect>)` :754. Focus: `App.active: Option<PaneId>` + `App.focus: Focus{Tree,Pane,RightPanel,BottomPanel}` (`focus.rs:6`) + `App.layouts: Vec<Layout>` (one per vim tab page) + `active_layout` + `tab_actives`.

**Coupling census (spine):** `Box<dyn` 4 · `&dyn` 0 · `impl Trait` 9 (iterators/closures/Into<String>) · `Arc` 1 · `Rc` 0 · `Mutex` 0 · `RefCell` 2 (lazy caches) · `mpsc` 4 (SpendReport) · generics 4 (`<R>` closure returns) · lifetimes 1 (`SeqResolution<'a>`) · `OnceLock` 1.

### B. App / render / loop / concurrency

**App** — `src/app/mod.rs:4162–6430`, **~480 fields**, one flat struct, `!Send`. Census: `mpsc::Receiver` **31**, `mpsc::Sender` **18**, `Arc` 8 (6 `Arc<Mutex>`), `HashMap` 24, `HashSet` 7, `Instant` 26, `Rc/RefCell` **0**, `Box<dyn>` **0**, `JoinHandle` **0**. 65 files / 89,254 lines; largest: mod.rs 13592, http.rs 7550, ex_commands.rs 5659 (`run_ex_command` giant match), git.rs 4114, layout.rs 3765, context_menus.rs 3487, ai.rs 3447, dispatch.rs 3078, file_actions.rs 3052, picker.rs 2640, settings.rs 2551, tick_methods.rs 457 (**master `tick()`**), git_async.rs 267.

**Render** — `pub fn draw(frame: &mut Frame, app: &mut App)` (`src/ui/mod.rs:181`). Mutates App because it **records hit-test rects during paint**: `app.rects.reset_for_frame()` (:205) wipes ~256-field `PaneRects` each frame; painters repopulate; mouse routing reads next event. Dispatch: recursive `render_layout(frame, app, &Layout, Rect, path) -> Option<(u16,u16)>` (:1791); at leaf, a two-stage borrow workaround maps Pane→u8 kind then `match kind` (:1912–2020) → Zig: one switch. Per-pane sig uniform: `draw(frame, app, id: PaneId, area: Rect, focused: bool) -> Option<(u16,u16)>`. Overlays: flat `if app.<slot>.is_some() { module::draw }` sequence (:257–284).

**ratatui surface:** `Paragraph` 115, `Block` ~56, `Clear` 43 render sites. **Only 2 real direct-cell sites**: `ui/pty_view.rs:91,160` and `ui/mount_view.rs:64` (grid blits). Rest of `buf[(x,y)]` grep = tests.

**Helper seam to reimplement first:** `ui/panel_chrome.rs` (575 lines: `draw_caps_header_with_refresh` :75, `draw_caps_header_with_chips` :196, `mode_chip_text` :143, `mode_chip_style` :176, `list_scroll_window` :324, `filter_chip_bg` :38) · `ui/scrollbar.rs` (`paint_simple_scrollbar` :28, `paint_horizontal_scrollbar` :75) · `ui/mod.rs:6010 clip_to_cells(&str, max_cells) -> String` · `ui/theme.rs:237 cur() -> Theme` (**global, by value, ~1600 call sites**) · `ui/icons.rs:37 for_path(path, is_dir, is_expanded, nerd_font) -> Icon` · `ui/md_preview.rs:298 styled_line`.

**Hot per-frame alloc:** `editor_view.rs:367` `Vec<Line>` per visible line; 1639 `Span::styled` + 795 `.to_string()` in `src/ui/`; `format!` density: statusline 77, mod 71, tooltip 56; `theme::cur()` by value; `PaneRects` reset. → arena-per-frame.

`src/ui/`: 102 flat files, 138,766 lines. Largest: mod 7136, request_view 4309, info_view_copy 3530, git_graph_view 2931, statusline 2877, tree_view 2558, editor_view 2368, diff_view 2257, tooltip 1942, http_panel 1772.

**Event loop** — `src/tui/mod.rs:67 run(App) -> Result<bool,String>` (bool=restart); `run_loop` :199. Per-iter: `app.tick()` → `tick_chord_chain` (`tui/chord.rs:155`) → `term.draw(ui::draw)` → frame timing/notifications/image placements → IPC `dump_screen_status` (10 Hz, `IPC_DUMP_MIN_MS=100`) + `drain_commands` + `drain_plugin_events` every tick → `poll_transfers` → adaptive `event::poll` timeout **40ms** if pty/pending-ai/dap/transfers else **120ms** (:310) → dispatch. `dispatch_key(app, KeyEvent)` :1248, `dispatch_mouse` (`tui/mouse/mod.rs:62`), `coalesce_scroll` (`mouse/coalesce.rs:62`, macOS emits 30+/spin, leftover stash). **Resize is a no-op** (ratatui re-queries). Paste hand-routed through ~10 overlay slots. `src/tui/` 19,097 lines: mouse/down_left 4558, mod 4116, handlers/pane 3723, mouse/right_click 2515.

**No `AppEvent`, no single channel.** `App::tick()` (`app/tick_methods.rs:13–190`) calls **35 `drain_*` methods** unconditionally, each `try_recv()` on its own Receiver field: git, http_jobs, sse, websocket, ai_jobs, lsp_events, dap_events, cdp_events, statusline_segments, marketplace, sonos, now_playing, … + `pump()` on every `Pane::Pty`/`Pane::Mount` + timers (yank flash, `refresh_stale_highlights` @120ms idle, `check_external_file_changes` @2s, toast TTL).

**Concurrency census:** **76 `thread::spawn`** sites (75 src + 1 bridge). **Zero async** (reqwest `blocking`). Per subsystem:
| Subsystem | threads | channel/shared |
|---|---|---|
| LSP `lsp/client.rs` | 1 reader/server (named `mnml-lsp-{name}` :110) | `Sender<LspEvent>` (15+ variants, `lsp/mod.rs:87`); `Arc<Mutex<HashMap<i64,…>>>` pending, `Arc<Mutex<ChildStdin>>`, `Arc<Mutex<HashMap<PathBuf,SemState>>>` |
| Git | 1 loader (`app/git_async.rs`) | `git_loader_tx: Sender<GitJob>` / `rx: Receiver<GitResult>`; **but `git/status.rs:79 tick()` shells `git` SYNC on UI thread, 3s TTL; 62 sync `Command::new("git")` in `src/git/`** |
| AI | 7 (`mnml-suggest` `app/ai.rs:335`, streaming ×2, api_client ×2, ai/mod ×4) | `(u64, AiMsg)` pairs; `ai_confirm_senders: HashMap<u64, Sender<bool>>` (reverse channel into worker) |
| CDP `cdp/mod.rs:545` | 1 worker | bidirectional `Sender<CdpCommand{Send(String),Close}>` + `Receiver<CdpEvent{Connected,Message(Value),Closed}>` |
| DAP `dap/client.rs` | 1 reader | `Sender<DapEvent>` (12+ variants `dap/mod.rs:128`); `Arc<Mutex<ChildStdin>>`, `Arc<Mutex<HashMap<i64,PendingReq>>>` |
| HTTP `app/http.rs` + `http/` | 13 | 5 `(Sender,Receiver)` tuple fields; `Arc<AtomicU32>` progress; `Arc<Mutex<CookieJar>>` |
| Pty `pty_pane.rs` | 1/session (`mnml-pty-{exe}` :551) | `Sender<Vec<u8>>` (one Vec per 8KiB read) + `Arc<Mutex<bool>> exited` + `Arc<AtomicU64> bytes_seen`; owned by PtySession |
| claude_agents | 0 own | `Arc<Mutex<Option<Vec<AgentRow>>>>` prefetch slot |
Shutdown: drop Sender or explicit `Vec<Sender<()>>` pipes (`app/mod.rs:1080,1085`).

**Pty + libghostty-vt:** `portable-pty` opens pair; reader thread → `tx.send(chunk.to_vec())`; `Terminal` is `!Send`, lives on UI thread; `pump()` (:608) drains rx → `vt_write` → flushes `responses: Rc<RefCell<Vec<u8>>>` (DSR/DA replies from `on_pty_write` cb) → reaps child. `render_grid(&self, focused) -> Rc<RenderGrid>` two-tier cache (:~660). Drop **detaches** reader (:1787). Wrapper API (`crates/mnml-libghostty-vt/src/`, 1332 lines): `Terminal{new, on_pty_write, vt_write, resize, cols, rows, is_mouse_tracking, title, scroll_viewport}`; `render.rs` lending-iterator ladder `RenderState→Snapshot→RowIter→Row→CellIter→Cell{raw_cell,style,fg,bg,graphemes}`, every accessor `Result`. Sys build (`build.rs`, 614 lines): runs **`zig build libghostty-vt -Demit-lib-vt`** (:272), forces `-Dtarget=` when cross/Windows; **`GHOSTTY_COMMIT = "6837d7027f226355db661e8215a3ad24ffaf4eb5"`** (:68); needs zig 0.16.0 + git; vendored `vendor/include/ghostty/vt.h`; `GHOSTTY_SRC` env override. No `.zig-version`, no `build.zig` in mnml repo.

### C. Frozen contracts

**`.test` format** — grammar doc `src/e2e/mod.rs:8–29`; parser :161–261 (steps), :267–321 (expect). Directives: `write <rel> <content>` · `open <rel>` · `key <spec>` · `type <text>` · `command <id>` · `ex <cmdline>` · `wait <ms>` · `snippet <scope> <trigger> <exp>` · `shell <cmd>` · `ghost <text>` · `click|rightclick|doubleclick <x> <y>` · `scroll <x> <y> <up|down>` · `drag <fx> <fy> <tx> <ty>` · `expect screen <contains|lacks> <text>` · `expect dirty <bool>` · `expect pane <text>` · `expect highlights at_least <n>` · `expect file <rel> <contains|lacks> <text>`. Unknown → error. `unescape` (:344): strips one `"…"` layer, `\n \t \\ \"`. **`expect screen` = plain substring over flattened grid** (:821): rows = cell symbols concatenated, joined `\n`, **no trim, no trailing newline** (`screen_text` :904). **Size fixed `SCREEN_W=120, SCREEN_H=40`** (:45), `cfg.editor.breadcrumb=false` forced (row0=palette,row1=bufferline). Every step → `render!()`: tick → 50ms → expire chord → tick → draw (:496). Checks poll ≤3000ms @40ms (:550). `wait` ticks every ≤25ms. Per-file timeout 120s (`MNML_E2E_FILE_TIMEOUT_SECS`). Own tempdir per file; `MNML_DATA_ROOT` isolated. `shell` needs `MNML_E2E_ALLOW_SHELL=1` (set by `mnml test`); `# requires: network` header gate. Internals-leaking: `expect highlights` (11 uses, tree-sitter span count), `ghost` (4), `snippet`, `expect pane` (Pane::title). **225 files** (189 + 36 in `http/`). `cargo run -- test` → `main.rs:230 test_subcommand`; prints `  ok   <name>` / `  FAIL <name> — <msg>` / `N/M passed`.

*// changed 2026-09-13 (corpus-hang):* the runner prints each `  ok` / `  FAIL` the moment its file finishes, not after the whole root as Rust does — the 508-file corpus takes ~10 min, and four runs that night were killed as "hung" because ten minutes of nothing but `▶` lines is indistinguishable from a wedge (nothing was wedged: 508/508 on the same binary). While a file runs, every `MNML_E2E_HEARTBEAT_SECS` (60; 0 = off) the runner prints `  ⏳ <name> still running (Ns) — children: <pid name …>` (`pgrep -lP`, POSIX only, best-effort), so a real hang names its file and its child before the 120 s timeout fires. `Options.heartbeat_secs`; `runFileWithTimeout` takes the writer.

**Headless + IPC** — dir `<ws>/.mnml/ipc/`: `command`, `screen.txt`, `status.json`, `events.jsonl`, `rects.json`, `mounts/<pid>-<id>.sock`. Headless size `MNML_COLS`/`MNML_ROWS` (≥10, default 120×40; `headless.rs:123`). Loop (`headless.rs:70`): signal → tick → chord → draw → dump → quit? → drain_commands → drain_plugin_events → sleep 40ms if idle. **Command JSONL**: `RawCommand` (`ipc/mod.rs:19–119`), all `#[serde(default)]`, `cmd` required. `cmd` values (:521–711): `open{path}` `key{key}` `type{text}` `run-command{id}` `register-command{id,title?,group?="plugin",keys?}` `click{col,row,button?,mods?}` `hover` `scroll{dy?=1}` `drag{from_col,from_row,col,row}` `mouse_down/move/up` `wait_ms{ms}` `expect_screen{text,expect?="contains"|"lacks"}` `snapshot` `toast{text,level?}` `toast-persistent{id,text}` `toast-dismiss{id}` `progress-start/update/end` `statusline-set-segment{id,text,side?,color?,click_command?,priority?=100,min_width?=4,max_width?=30}` `statusline-clear-segment` `notify{text,title?="mnml",level?,sound?,source?}` `open-pty{command[],cwd?}` `set-activity-badge{section,count}` `dump-rects` `ghost{text}` `quit` `restart`. Reader: byte-offset tail, complete lines only, reset on truncation; init truncates all files 0600, unlinks symlinks, appends `.mnml/`+`.rqst/` to `.gitignore`. **`screen.txt`**: per row symbols concatenated, **`trim_end()`, then `\n` (incl. last)** (:1976) — DIFFERENT from `.test` flattening. Off when `[ipc] write_screen=false`. **`status.json`** (hand-rolled, :1991): `{"focus":"tree|pane|right_panel|bottom_panel","activePane":idx|null,"activeFile":"…"|"","cursor":{"line":1-based,"col":1-based},"mode":"<label>|none","treeCursor":n,"treeSelection":"…","treeVisible":b,"rightPanelVisible":b,"rightPanelPanes":[…],"rightPanelActiveIdx":n,"panes":[{"title","dirty","preview"}],"quit":b}`; `json_str` escapes `" \ \n \r \t` + `\u00XX` controls only. **`rects.json`**: `[{"label","x","y","w","h"}]` every frame. **`events.jsonl`**: flat objects, **all values strings** via `json_event` (:2057) except lifecycle lines (`start{mode,cols,rows,ipc}`, `exit`, `exit{restart:true}`, `shutdown{reason}`, `ipc_init_truncated{bytes,lines}`); per-command acks named after cmd (`expect_screen{mode,text,ok:"true"|"false"}`), `unknown{raw}`, `plugin-command{id}`. Marker: `${TMPDIR:-/tmp}/mnml-running-${USER}.workspace` = workspace path, no trailing newline (`run.sh:78,399`).

**Config** — `Config` 29 top-level fields (`config.rs:70–175`): editor(20), ui(**75**), session(1), ipc(1), cloud_run, jira(2), cloud_agents(13), `keys: BTreeMap<String,BTreeMap<String,String>>`, `lsp: BTreeMap<String,toml::Value>`, `ai: toml::Value`, `tools: toml::Value`, http(4, `collection_root: enum{Hidden,Workspace}`), ws(3), sonos(6), git_graph(1), `tasks: BTreeMap<String,TaskDef>`, startup_tasks, startup_layout: Vec<StartupLayoutEntry>, default_workspace, `snippets: BTreeMap<String,BTreeMap<String,String>>`, abbreviations, formatters, linters, `dap: BTreeMap<String,toml::Value>`, browser(3), ci(3), integrations(2), `workspaces: Vec<WorkspaceConfig>`, marketplace(5). Key↔field mismatches: `[abbr]`→abbreviations, `[startup] tasks`→startup_tasks, `[[startup.layout]]`→startup_layout. Many stringly-typed enums in ui/editor. **Non-default serde (config surface only):** `config.rs:1886` `rename="source"` (`[[marketplace.source]]`); `:1898` `tag="type", rename_all=snake_case` on `RawMarketplaceSource{crates_keyword, github_launcher_folder, github_monorepo_apps}`; `:2230` `rename="integration_icon"` (`[[ui.integration_icon]]`); `formatter.rs:168` + `linter.rs:80` `untagged One{S(String),Many(Vec<String>)}` (cmd = string-or-list); `bookmarks.rs:84` `flatten`; `marketplace.rs` tag/other/rename ×7; `http/captured.rs:20` `alias="requestId"`; `app/mod.rs:1134` `other` (session.json). **Load** (`Config::load_with_trust` :2540): default → home (`home_config_path` :4307: `MNML_DATA_ROOT`/config.toml → portable → `$XDG_CONFIG_HOME/mnml/` → `$HOME/.config/mnml/config.toml`) → `<ws>/.mnml/config.toml` (exec keys stripped if untrusted) → explicit `--config`. Bad TOML logged, not fatal. `data_root()` (`data_root.rs`) has its own precedence (MNML_DATA_ROOT → portable `<bin>/mnml-data/` w/ `.opted-in` → XDG only if it has state → HOME → `./mnml`). **Migrations:** `DEAD_INTEGRATION_IDS=[bitbucket,linear,gitlab,cypress,slack]` uninstalled on every load (:68, :2560); `[ai] claude_show_all_accounts` bool-or-string (:2480); legacy glyph remaps (:2979,:3020). **Persist:** all via `write_user_config` (:3648) → backup to `<root>/backups/config.YYYY-MM-DD-HHMMSS.toml`, prune >50. `persist_config_scalar(section,key,value)` (`app/discovery.rs:1201`): **textual in-place edit** — find `[section]`, replace first `key ` / `key=` line preserving indent, else insert under header, else append `\n[section]\nkey = value`; comments survive; no-op short-circuits. ~20 `persist_*` wrappers. `persist_workspace_setting` writes `<ws>/.mnml/config.toml`. Other state: `<ws>/.mnml/session.json` (`app/mod.rs:745–1145`), `<ws>/.rqst/history.jsonl`, `<ws>/.mnml/.welcomed`, `~/.config/mnml/integrations/<id>.toml`.

**Key grammar** — `parse_key_spec` (`input/keymap.rs:349`): prefixes case-insensitive, repeatable, any order: `ctrl+|c-`, `shift+|s-`, `alt+|a-|meta+`, `super+|cmd+|win+`. **Canonical `ctrl+p`; `<C-p>` does NOT parse.** Named keys (`key_code` :401): enter|return|cr, tab, backtab, esc|escape, space|leader, backspace|bs, delete|del, insert|ins, up/down/left/right, home, end, pageup|pgup, pagedown|pgdn|pgdown, f1–f12, minus|dash, underscore, plus, equal|equals, comma, period|dot, slash, backslash, semicolon, quote, grave|backtick, bracketleft, bracketright; single char → Char; else None. Sequences split on whitespace (`parse_key_seq` :337); `Chord::of` folds `'P'`→`'p'+SHIFT` (:530). Same grammar used by config `[keys.*]`, `.test` `key`, IPC `key`, bridge `InputEvent::Key{spec}`. `[keys.global]` always; `[keys.vim]`/`[keys.standard]` overlay; `"none"` unbinds; unknown ids tolerated.

**mnml-bridge 0.8.0** (`crates/mnml-bridge/`): tiers: env `MNML_WORKSPACE/MNML_THEME/MNML_IPC_DIR` → JSONL into `$MNML_IPC_DIR/command` → SDK → Mount. **Mount = Unix domain socket, 4-byte LE length-prefixed JSON**, cap 16 MiB. Host binds `<IPC_DIR>/mounts/<pid>-<id>.sock` (`src/mount.rs:115`), child gets `MNML_MOUNT_SOCKET`. All enums `tag="kind", rename_all=snake_case`: `HostMessage{Hello{geometry,theme}, Resize{geometry}, Input{event}, Goodbye}`, `SiblingMessage{Frame{cells: Vec<Vec<Cell>>}, Bye}`, `InputEvent{Key{spec}, Click{col,row,button}, Scroll{col,row,dy:i16}, Hover{col,row}}`. `Cell{symbol:String, fg?:RgbOrIndex, bg?, modifiers:u16 (skip if 0)}`; `RgbOrIndex` **untagged** `Rgb([u8;3])|Index(u8)` → array vs bare int. Modifier bits: BOLD 1, DIM 2, ITALIC 4, UNDERLINED 8, SLOW_BLINK 16, RAPID_BLINK 32, REVERSED 64, HIDDEN 128, CROSSED_OUT 256. Full frames, no diff; short rows right-padded. `ipc.rs`: `ToastLevel`, `ProgressStatus`, `SegmentSide` snake_case. Activity sections: explorer, search, git, debug, integrations, sessions, agents, cloud_agents. `install.rs`: manifest `~/.config/mnml/integrations/<id>.toml` (reads `HOME` directly), `IntegrationSpec{id,label,description?,version?,binary,category?,chip?,commands,context_menu,menu_bar,statusline?,settings,notifications?,requires?,auth,values_sources,statusline_segments}`. **33 crates** depend on it locally (31 in `mnml-integrations/apps/` + 2 private); +4 launcher TOMLs.

**Embedded data:** 94 theme TOMLs (`themes/`, ~450KB, via `build.rs` → `THEME_SOURCES`); `data/nerd-glyphnames.json` (545KB, `nerd_glyphs.rs:56`); 4 query files `queries/{hcl,proto,vue,vue.injections}.scm` (`highlight.rs:1226–1247`); 9 SVGs `assets/glyphs/` (`glyph_builder.rs:820–851`); `themes/mnml-prompt.sh` (`shell_prompt.rs:27`). No embedded default config (defaults in code). Build env: `MNML_TARGET`, `MNML_GIT_SHA`.

**highlight.rs** (1770 lines): `build_config(ext) -> Option<LangConfig>` (:1009), 43 languages; the quirk is per-grammar query-constant naming (`HIGHLIGHTS_QUERY` vs `HIGHLIGHT_QUERY` vs md `HIGHLIGHT_QUERY_BLOCK/INLINE`) and **layering** (ts = js HIGHLIGHT + ts HIGHLIGHTS; tsx adds JSX; md = block + inline dual parser). In Zig: `@embedFile` each grammar's `queries/highlights.scm`; the layering logic is behavior to keep.

**FEATURES.md** (625 lines, parity checklist): Editing&input 6 · Panes 4 · File manager 5 · Nav&search 6 · LSP 9 · Git 10 · TODOs/notes/findings 5 · AI 6 · Terminal panes 5 · Dock widgets 10 · **HTTP 23** · Browser/CDP 3 · DAP 2 · Testing 2 · **UI&theming 19** · Workspace trust 5 · Headless/IPC 11 · Languages (39+).

**Release pipeline:** cargo-dist (`dist-workspace.toml`): targets `aarch64-apple-darwin, x86_64-apple-darwin, aarch64-unknown-linux-gnu, x86_64-unknown-linux-gnu, x86_64-pc-windows-gnu`; installers `shell, powershell, msi`. Workflows: `ci.yml`, `release.yml`, `release-plz.yml` (crates.io on push to main), `bump-homebrew-tap.yml`, `winget-releaser.yml`, `package-linux.yml` (.deb/.rpm), `site.yml`. ~22 assets/release expected.

### D. Zig side (verified)

- **Local zig: 0.16.0** (`/opt/homebrew/bin/zig`, std at `/opt/homebrew/lib/zig/std`).
- **libvaxis 0.6.0**, `minimum_zig_version = "0.16.0"`, deps `zigimg` + `uucode`. `Window{x_off,y_off,width,height,screen}`: `child(ChildOptions{x_off,y_off,width?,height?,border})`, `writeCell(col,row,Cell)`, `readCell`, `clear`, `fill(Cell)`, `gwidth(str)`, `print([]Segment, PrintOptions{row_offset,col_offset,wrap: grapheme|word|none, commit}) PrintResult`, `printSegment`, `scroll(n)`, `hasMouse`, `showCursor/hideCursor/setCursorShape`. `Cell{char,style,link,image?,default,wrapped,scale}`; `Style{fg,bg,ul: Color, ul_style, bold,dim,italic,blink,reverse,invisible,strikethrough}`; `Color = union{default, index:u8, rgb:[3]u8}`; `Segment{text,style,link}`. `Vaxis`: **every fn takes `tty: *std.Io.Writer`** — we own the writer (raw sixel/iTerm2 bytes OK). `Capabilities{kitty_keyboard,kitty_graphics,no_color,rgb,unicode: gwidth.Method,sgr_pixels,color_scheme_updates,explicit_width,scaled_text,multi_cursor}`; `queryTerminal(tty, timeout)`, `render(tty)`, `resize(alloc,tty,winsize)`, `window()`, `enter/exitAltScreen`, `setMouseMode`, `setBracketedPaste`, `copyToSystemClipboard` (OSC 52), `transmitImage/loadImage/transmitPreEncodedImage` (kitty only). `Loop(Event)` generic; events `key_press: Key`, `winsize`, `focus_in`, mouse. Windows supported. Note: `neurocyte/libvaxis` is a fork — Flow's author didn't use upstream directly.
- **neurocyte/tree-sitter**: `minimum_zig_version = "0.17.0-dev.704"` on master (tracks Zig master). Tag `master-a9680e3e…` (2026-06-11, "Merge branch 'zig-0.16'") is the 0.16 candidate. 80+ grammars bundled, MIT. **Decision: write our own `build.zig` compiling tree-sitter runtime C + 43 grammar `parser.c`/`scanner.c` + `@embedFile` their `queries/*.scm`; use neurocyte's build.zig as reference only.**
- **Zig 0.16 std**: `std.Io{Threaded, Evented (fiber), Dispatch, Kqueue, Uring}`; **`Io.Queue(Elem)`** (typed, `QueueClosedError`), `Io.Mutex`, `Io.Condition`, `Io.Group`, `Io.Select`, `Io.async/concurrent/Future`, `Io.sleep`, `Io.Terminal`, `Io.File/Dir`, `Io.Reader/Writer`. `std.Thread{spawn, join, detach, setName}`. `std.json{parseFromSlice, parseFromSliceLeaky, Stringify, Value, jsonParse hook via std.meta.hasFn, ignore_unknown_fields}`; struct default field values honored. `std.zon` exists. **No TOML in std** — moot: the decision is NO TOML anywhere in mnml 0.3+ (ZON config, themes converted once, manifests ZON, user migration via the Rust 0.2.22 `export-config-zon`).
