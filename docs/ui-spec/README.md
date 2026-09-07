# The UI spec

`rust-120x40.txt` is the Rust editor's screen — every cell, glyphs
included — on the fixture workspace with the author's real config, at
120×40, after the first-run overlay is dismissed. It is what mnml-zig
must look like. `rust-80x24.txt` is the same screen at 80×24 — the
statusline's overflow rule (the branch chip clipped to `main …`). Both
are embedded into the test binary (`build.zig`, `ui_spec_rust_*`) so
the statusline tests compare the painted row with the spec's. Colours are not in the dump; for those the Rust source
under `src/ui/` is the reference, and a side-by-side screenshot in
ghostty is the final check.

Regenerate and compare with `tools/ui-diff.sh WS RS_DATA ZIG_DATA
STEPS` (see the script header). Out of scope until the Zig integrations
exist: the pinned integration launcher icons in the rail and palette
bar. Cut: now-playing / Sonos chips.

Glyphs are codepoints, not looks. The author's ghostty runs
`font-family = JetBrainsMono Nerd Font` with `font-codepoint-map =
U+F1B00-U+F20FF=MnmlSymbols` (mnml's own baked glyphs: integration
chips, spinners, the claude/codex marks, tree connectors). Paint the
exact codepoint the Rust painter uses — never a lookalike from another
Nerd Font family — and put nothing in U+F1B00–U+F20FF the Rust side does
not already bake (`mnml/assets/glyphs/`, the Rust glyph tables), or it
renders as a box.

Same look, Zig internals: the Rust modules are a behaviour reference,
not a template. Build on the component system (`Ui`, `HitMap`,
`Canvas`, `ListPanel`), register every click target in the same
statement that paints it, and add nothing the Rust screen does not show.

`rust-git-120x40.txt` / `rust-git-80x24.txt` are git mode (`steps-graph2.jsonl`).

`rust-git-status-120x40.txt` / `rust-git-status-80x24.txt` are the
staging pane (`steps-status.jsonl`: `git.status_pane` from the resting
screen), re-cut 2026-09-07 on the fixture's two untracked entries
(`.gitignore`, `requests/`). The 80×24 cut shows the hint row clipped
at the pane's edge (`⏎ di█`), not dropped word by word.

`rust-80x24.txt` is the same screen at 80×24 — the narrow rule: only
the brand menu fits before the ` » `, the browser chip is dropped from
the gap, the right cluster is the compact one. `src/ui/menu_bar.zig`
pins row 0 of both dumps as `rust_row_120` / `rust_row_80`.

## Overlays (2026-09-07)

Each `rust-<name>-120x40.txt` below is the Rust screen after the
matching `steps-<name>.jsonl`, on the fixture workspace (which now has
`requests/demo.http`; `rust-palette` / `rust-picker` were re-cut on it):

- `palette` — `ctrl+shift+p`, type `git`: the command palette.
- `picker` — `ctrl+p`, type `ma`: the `Open file` picker.
- `rename` / `delete` — three arrows down the tree (Rust previews the
  row under the cursor, so `.gitignore` is open behind the box), then
  `file.rename` / `file.delete`. The delete steps only OPEN the
  confirm; nothing in the fixture is ever deleted.
- `goto` — `src/main.rs` open, `ctrl+g`: the go-to-line prompt.
- `whichkey` — `ctrl+k`: the leader popup (standard profile).
- `help` — `f1`: the help overlay (the keymap reference).
- `discovery` — `view.discovery`: the click-discovery panel.
- `close` — `src/main.rs` open, type `x`, `ctrl+w`: the unsaved-changes
  prompt (the buffer is never saved; the quit discards it).

## Sections and their sides (2026-09-07)

Every activity section has a side (`src/app/side.zig`); these are the
Rust screens the columns are measured against, on the fixture
workspace at 120×40:

- `todos` / `notes` / `findings` — `view.activity_<x>`: the section in
  the sidebar's 26 cells (rail 3 + border + 26, the divider at 30), the
  info box titled with it, the mode chip `TREE`. The Zig columns match,
  and the `+ New todo` / `+ New note` / `+ New finding` row is Rust's
  (`ListPanel.Props.new_label`). The rest of the rows are Zig's by the
  user's decision (2026-09-07), so these three stay at residue —
  todos 24, notes 26, findings 26 differing lines — and the hunks are
  the accepted ones: a blank row directly under the filter (the user's
  ask; Rust has none, so every row below sits one lower), the filter
  pill (`󰍉 / filter` vs `󰍉 type to filter…▏`), the header's count
  spacing (`TODOS (0)` vs `TODOS  (0)`), the empty state's `…` clip
  (Rust clips hard), the info box's copy, the version line, and the
  statusline's stock / now-playing chips.
- `outline` — `src/main.rs` open, `view.toggle_right_panel`,
  `outline.show`: the outline in the right panel at Rust's 32 cells (the
  divider at 87), a strip row above it (`main.rs ⌥1   󰐕 … ×`,
  `ui/side_strip.zig`), the keys left in the editor (`EDIT`), the rail
  still marking the explorer. At residue: 8 differing lines, all the
  LSP toast (no server for Zig in the fixture) and the statusline's
  stock / now-playing / `LSP 1` chips.

## The debugger (Zig-authored, 2026-09-07)

The debug UI is the one deliberate departure from same-look: the Rust
debug pane was never driven by anyone, so these screens are the spec
and there is no Rust side to diff against. `tools/zig-spec.sh NAME
[COLSxROWS]` seeds a throwaway workspace with `prog.dbg` (the program
`src/app/dap.zig`'s integration test debugs), names `mnml-fake-dap` as
the `.dbg` adapter in a throwaway data root (the home layer is trusted,
so no dialog), feeds `steps-NAME.jsonl` over IPC and keeps the screen:

- `zig-debug-stopped-120x40.txt` — `steps-debug-stopped.jsonl`: a
  breakpoint on line 4, `dap.run`, `dap.show`. The DEBUG section in the
  left column (the status row's narrow form `● prog.dbg:4 · main`,
  VARIABLES with both scopes, WATCH, CALL STACK, BREAKPOINTS with the
  adapter's two exception filters), the editor with the ▶ and its band,
  the step toolbar strip under the breadcrumb, `  x = 1` inline values,
  the hover tooltip over `x` (`ui.hover_tooltip`), and the Debug pane —
  toolbar, `── started prog.dbg ──`, `hello`, the input row.
- `zig-debug-stopped-80x24.txt` — the same at 80×24: the toolbar drops
  to icons, the section scrolls, nothing overflows.
- `zig-debug-console-120x40.txt` — `steps-debug-console.jsonl`: three
  evaluations in the console (`2 : int`, a foldable struct, an error)
  and a Tab completion.
- `zig-debug-breakpoints-120x40.txt` — `steps-debug-breakpoints.jsonl`:
  no session; a conditional (◐), a logpoint (◆), a plain (●) and a
  disabled (○) breakpoint in the gutter, the BREAKPOINTS rows, and the
  row menu opened with `view.context_menu_at_focus`.

## The branches panel (Zig-authored, 2026-09-07)

The git column is the second deliberate departure from same-look: the
Rust sidebar's `GIT` header, `⎇ branch` row, folder-grouped LOCAL and
PULL REQUESTS are replaced by a branches panel, so the sidebar rows of
`rust-git-120x40.txt` / `rust-git-80x24.txt` are the accepted
difference and only the PANE (cols 31+) is still measured against
them. `tools/zig-spec-git.sh NAME [COLSxROWS]` seeds a throwaway repo
— two locals (`main` one commit ahead of its upstream, `feature`), a
remote `origin` with three branches whose URL names github.com, two
linked worktrees (`wt-locked` on feature, locked; `wt-dirty` detached
with an untracked file), one stash, two tags — feeds
`steps-NAME.jsonl` over IPC and keeps the screen; the shared fixture
is never touched.

- `zig-git-palette-120x40.txt` — `steps-git-palette.jsonl` (the
  graph2 steps): the repo pill with the refresh chip at its edge,
  `Viewing 11`, the list panels' filter row, a blank, then LOCAL (the
  check, the green ground and `1↑` on main), REMOTE (`origin` with the
  GitHub glyph, its three branches indented without the prefix),
  WORKTREES (the house on the main tree with `1↑`, the lock in the
  gutter of `wt-locked`, the blue dot at the edge of `wt-dirty`),
  STASHES (`sha message`), TAGS newest first. The cursor rests on
  LOCAL with the muted marker, as every list panel's does.
- `zig-git-palette-80x24.txt` — the same at 80×24: the column is 12
  cells, labels and names clip with `…` before the counts and the
  right-edge cells, the list scrolls with the scrollbar in its last
  column, nothing overflows.
