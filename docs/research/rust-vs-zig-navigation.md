# Rust vs Zig: navigating a large file

*2026-09-09 · `tools/compare.sh` on `docs/ui-spec/steps-compare-*.jsonl` ·
Rust `~/Projects/mnml/target/release/mnml` (built 2026-09-03; the
`debug` binary is newer but the release one was present, so it was
used) · Zig `zig-out/bin/mnml-zig` from `compare` at `6a50d5a` ·
fixture `src/large.rs` from `tools/gen-large-fixture.py` (6000 lines,
314 KB, 8 lines over 300 cells, 981 tab-indented, 541 `needle`s) ·
both on a private copy of `chrome-fixture` (`wrap = true`,
`sticky_context = true` on both sides).*

The question was whether the two editors can be compared on a large
file under keyboard and mouse navigation. They can: the harness opens
the same file in both, feeds one steps file over the file-IPC
protocol, and keeps a screen and a `status.json` after every step
(`docs/research/compare/<run>/`). What follows is what the four runs
showed — three steps files at 120×40 and the vim keys file again at
200×60.

## Read this first

- **The cursor agrees.** Over 134 vim motions (`PageDown`, `Ctrl+D`,
  `G`, `gg`, `50%`, `/needle`, `n`, `w`, `b`, `}`, `$`, `0`, `zz`,
  `zt`, `zb`, `Ctrl+E`, `Ctrl+Y`) and the standard profile's arrows,
  page keys, `Ctrl+Home/End`, word steps and go-to-line, `status.json`
  reports the same `line:col` on both sides at every step — until the
  standard profile's find bar, where the two diverge (finding 3).
- **The screens never agree at 120×40, and it is mostly the wrap.**
  Rust hard-wraps a long line every `text_w` *chars* and marks the
  continuation `↪`; Zig word-wraps by *cell* width with a blank gutter.
  Every long line takes a different number of rows on each side, so
  every screen below one differs and the "top line" drifts with it. At
  200×60, where only the eight >300-cell lines wrap, the top line
  differs on none of the 134 steps instead of 84.
- **Timing:** the Zig binary starts in 0.15–0.4 s to Rust's 2–4 s and
  holds 47–68 MB to Rust's 94–116 MB, and its per-key latency is the
  same or better — but **opening the file paints 3–20× later on Zig**
  (0.36 / 1.32 / 2.49 s against Rust's 0.12–0.16 s) and the first
  key or click after the open can stall behind it (0.5 s, 1.8 s).
- **Two Zig navigation bugs** the mouse file surfaced: a click on a
  line with multi-byte characters lands to the right of the glyph
  clicked (bytes added to a char column), and the sticky-context row
  pins a function that does not enclose the viewport.

## The per-step tables

Each run's `diff.md` has the full table; `text` is the number to read
— body rows that still differ once the rail, the tree's cursor cell,
the last column (the Zig editor's scrollbar), a wide glyph's spacer
cell and trailing blanks are dropped. `top` is read off the gutter
(neither side's `status.json` has a scroll offset); `+N` is N pinned
scope rows above it, and the estimate is the first regular number
minus N, so a wrapped row under a pinned one puts it off by one.

### `steps-compare-keys` (vim, 120×40) — `docs/research/compare/compare-keys/`

134 steps (every key followed by a `wait_ms`). Cursor: identical on
all 134. Text rows differ on 134/134 (6–35 per step). Top line differs
on 84. Steps where the screens differ beyond the known rail /
statusline rows, by class — the wait steps repeat their key's row and
are folded in:

| steps | class | what |
|---|---|---|
| all (2–133) | wrap | line 18, 25, 100, … take 3 rows on Rust (`↪` hard wrap at 84 chars) and 3 on Zig (word wrap), broken at different places; rows below shift when the counts differ |
| 2, 4, 6, 8, 22, 26, 48–85 (the `w`/`b` run) | gutter | Rust's continuation rows carry `↪` in the gutter; Zig's are blank, indented 6 |
| 16–21, 24–31, 48–83, 92–97, 102–115, 118–127, 130–133 | scroll offset | the top line differs by 1–2 (`G`: 5973 vs 5974; `Ctrl+D`: 182 vs 183; `Ctrl+E`: 3093 vs 3094) — every one traces to a wrapped line above the cursor taking a different row count, not to a different scroll rule: `zz` (3103), `zt` (3120), `zb`, `50%` and the rest agree once the pinned rows are discounted, and at 200×60 nothing differs; see below |
| 10–17, 24–29, 32–89, 92–133 | sticky row (zig) | Zig pins 1–2 numbered scope rows (`3075 pub fn poll_span154…`, `3099 pub fn split_needle155…`); Rust pins one, numberless, on 98–101 and 118–127 only |
| 0–1 | other | the empty-pane splash sits one row lower on Zig |
| every step | highlight/other (dump-only) | Zig paints `█` down the whole last column (track and thumb are the same glyph, told apart by colour); Rust's bar is a styled space, invisible in the dump |

Worst three by `text`:

```
step 16 · ctrl+d · 35 rows · scroll offset, wrap
row  3 rust:  182     while selection.find(|registry| merge(scroll(), line, offset as usize)) {
row  3 zig:   179 pub fn draw_registry10<F: Fn(usize) -> bool>(gutter: bool, cursor: impl Iterator<It
row  4 rust:  183     }
row  4 zig:   184 }
row  8 rust:  187 pub fn commit_pane11<T: Clone + 'static>(scope: u64, command: &str, col: char, h
row  8 zig:       height: u16) -> String {

step 3 · open + wait · line 18 (the first >300-cell line)
rust:   18     let frame: i32 = snapshot(snapshot(true % None, merge(glyph.len())), split(t
rust:    ↪ rue, tick.len(), self.editor_scope) || scroll(needle_editor.len(), self.selectio
rust:    ↪ n), span_cursor?.dispatch());
zig:    18     let frame: i32 = snapshot(snapshot(true % None, merge(glyph.len())),
zig:           split(true, tick.len(), self.editor_scope) || scroll(needle_editor.len(),
zig:           self.selection), span_cursor?.dispatch());

step 100 · zt · cursor 3120 on both
rust: pub fn split_needle155<F: Fn(usize) -> bool>() -> u8 {        ← pinned, no number, encloses 3120
rust:  3121 /// Wide cells (CJK, emoji) take two columns; combining marks take none.
zig:   3075 pub fn poll_span154<T: Clone + 'static>(viewport: u32, col: u64) -> u64 {   ← pinned; ends at 3098
zig:   3121 /// Wide cells (CJK, emoji) take two columns; combining marks take none.
```

### `steps-compare-keys` at 200×60 — `docs/research/compare/compare-keys-200x60/`

Same 134 steps. Cursor identical on all. Top line identical on all
134 — the scroll rules agree; what differs at 120×40 is the wrap.
Text rows still differ on every step, but the classes collapse to:
wrap on the eight >300-cell lines (14 steps), gutter (46), and
**indent guides** (the 80 steps in the `highlight/other` bucket —
same cursor, same top, no wrapped row on screen): Rust paints `│` at each indent stop in leading whitespace,
Zig paints spaces. Zig also pins a scope row on 90 of the 134
steps here (6–21, 26–87, 98–101, 122–123) where Rust pins on 2
(100–101, the `zt`); see finding 5 —

```
row  7 rust:  254     │   │   let handler: u32 = flush(self.haystack_buffer, fold?.merge(), tick.all(|tick| col));
row  7 zig:   254             let handler: u32 = flush(self.haystack_buffer, fold?.merge(), tick.all(|tick| col));
```

At 120×40 the same rows exist but sit inside the wrap noise.

### `steps-compare-keys-standard` (standard, 120×40) — `docs/research/compare/compare-keys-standard/`

182 steps. Cursor identical on 172; the last 10 (140–149) are the
find bar. Top line differs on 44: steps 18–19 (the wrap, as above)
and 140–181 (the find bar, below — the cursors are on different
lines from step 140 on).

| steps | class | what |
|---|---|---|
| 4–17 | wrap, gutter | `PageDown`/`PageUp` land on the same line and the same top (36/8, 71/39, 106/77, 141/112, 176/149, back to 141, 106) |
| 18–19 | scroll offset, wrap | `Ctrl+End`: Rust top 5973, Zig 5974 — line 6000 is on the last row of both; the rows above wrap differently |
| 22–133 | wrap, gutter | `Down` ×20, `Right` ×20, `End`, `Home`, `Ctrl+Right` ×10, `Ctrl+Left` ×5: identical cursor every step (`22:53 … 22:26`) |
| 136–139 | wrap | `Ctrl+F`, type `needle⏎`: both at 25:50, the Zig bar still open (`Find  needle …`), the Rust one closed (statusline `/needle 2/547`) |
| **140–145** | **cursor placement, scroll offset** | `Enter` ×3: Zig steps to matches 50:12 → 67:24 → 67:41; **Rust inserts a newline each time** (26:5 → 27:5 → 28:5, `dirty: true` from step 140) |
| 146–149 | cursor placement | `Esc`, `Ctrl+G`: the cursors stay apart (28:5 vs 67:41) |
| 150–181 | wrap, gutter | `3000⏎` lands both at 3000:1; `Ctrl+Down` ×10 / `Ctrl+Up` ×5 agree on the cursor and — with the pinned-row adjustment — on the top |

```
step 140 · enter (after Ctrl+F needle ⏎)
rust:   25     while collect(palette_theme?.paint() << Some(
rust:   26     needle), viewport.any(|offset_event| 3566) == registry_fold as usize    ← line 25 split at col 50
zig:    40 pub struct Registry39 {                                                    ← scrolled to match 3 (50:12)
```

### `steps-compare-mouse` (standard, 120×40) — `docs/research/compare/compare-mouse/`

33 steps. Cursor differs on 21 — one divergence at step 6 that the
next 20 steps carry, and the click at 30. Top line differs on 12 (the
wheel runs).

| step | step | rust | zig | class |
|---|---|---|---|---|
| 4 | click (50,10) — text, line 8 | 8:14 | 8:14 | same |
| 6 | click (32,20) — gutter of the wrapped line 18 | **19:1** | **18:2** | cursor placement: Rust parks at the start of the *next* line, Zig at column `x − gutter.x` of the row's line |
| 8 | click (15,5) — tree row `main.rs` | opens main.rs | opens main.rs | same (Zig also moves the tree cursor `▌`; documented) |
| 10 | click (33,1) — the `large.rs` tab | back, 19:1 | back, 18:2 | carried |
| 12 | wheel down ×1 at (60,15) | top 5 | top 4 | scroll offset — *known: scroll tuning is a separate track* |
| 14 | wheel down ×3 | 23 | 14 | known |
| 16 | wheel down ×10 | 92 | 44 | known |
| 18 | wheel down ×30 | 311 | 134 | known |
| 20 | wheel up ×1 | 310 | 131 | known |
| 22 | wheel up ×3 | 290 | 122 | known |
| 24 | wheel up ×10 | 221 | 91 | known |
| 26 | wheel up ×30 | 1 | 1 | same |
| 28 | drag (40,6)→(60,8) | 6:17 | 6:17 | same cursor (the selection is not in the dump) |
| 30 | click (45,12) — the `ö` of `Ünïcödé` | **10:9** | **10:11** | cursor placement: Zig lands two chars right — one per multi-byte char before the cell |
| 31 | click (45,12) again (double) | 10:12 | 10:12 | same: both select the word |

Wheel numbers, for the record: Rust moves 4 / 18 / 69 / 219 lines for
1 / 3 / 10 / 30 notches down (acceleration — `[editor] scroll_accel`,
`src/app/dispatch.rs:1176–1232` in mnml) and 1 / 20 / 69 / 220 up;
Zig moves 3 per notch flat (`ui.wheel_lines = 3`,
`src/app/dispatch.zig:2160–2162`): 3 / 9 / 30 / 90.

## Timing

Per side and run: the `start` event and the first non-empty
`screen.txt` after spawn; peak RSS (`ps -o rss` every 50 ms); the mean
and the slowest per-step latency from the command's append to the
next screen dump after its ack (1 ms polls), wait steps excluded.
Neither side's `status.json` carries frame timing, so the dump latency
stands in for it. Full tables in each run's `timing.md`.

| run | side | start event | first frame | peak RSS | mean dump | slowest (step) | `open` painted |
|---|---|---:|---:|---:|---:|---:|---:|
| keys 120×40 | rust | 2107 ms | 2110 ms | 111.1 MB | 36.4 ms | 116 ms (2) | 116 ms |
| | zig | 195 ms | 216 ms | 66.2 MB | 33.9 ms | 357 ms (2) | 357 ms |
| keys-standard 120×40 | rust | 3951 ms | 4084 ms | 93.9 MB | 35.1 ms | 159 ms (2) | 159 ms |
| | zig | 302 ms | 332 ms | 68.2 MB | 51.3 ms | 1323 ms (2) | 1323 ms; the `PageDown` after it 495 ms |
| mouse 120×40 | rust | 2033 ms | 2039 ms | 111.7 MB | 58.0 ms | 227 ms (10, tab click) | 126 ms |
| | zig | 340 ms | 409 ms | 46.9 MB | 280.6 ms | 2487 ms (2) | 2487 ms; the first click after it acked at 1815 ms |
| keys 200×60 | rust | 2449 ms | 2454 ms | 116.0 MB | 27.7 ms | 125 ms (2) | 125 ms |
| | zig | 146 ms | 160 ms | 66.7 MB | 41.3 ms | 352 ms (2) | 352 ms |

Per-key latency once the file is open is 1–50 ms on both; the Rust
mean carries a ~45 ms tail on some steps (its 40 ms headless poll
sleep), the Zig mean is dragged by the open. The Rust start includes a
marketplace fetch (`src/main.rs:970` →
`src/app/marketplace_methods.rs:127`) — a `marketplace: 43` toast
appeared on the Rust screen at step 20 of the vim run, network from a
headless harness.

## Findings, by user impact

1. **Zig — a click lands right of the glyph on any line with
   multi-byte characters.** Step 30: cell 45 on
   `/// Ünïcödé in a comment` is `ö` (char 9); Rust puts the cursor at
   10:9, Zig at 10:11. The editor view registers every cell hit with
   `.col = c.off` — a **byte** offset (`src/ui/editor_view.zig:920`,
   `CellInfo.off` at `:388–391`) — and the click handler adds the
   pointer's cell delta to it and passes the sum to `byteAtCol`, which
   counts **chars** (`src/app/dispatch.zig:2497–2498` →
   `src/editor/document.zig:479–486`). One char of error per multi-byte
   char before the cell; the double-click still selects the right word
   because `wordBoundsAt` works from the (wrong) byte outward.
2. **Zig — opening the 314 KB file paints 0.36–2.5 s later than Rust's
   0.12–0.16 s, and the first input after it can wait 0.5–1.8 s.**
   The `open` acks in 13–41 ms; the frame that follows is the slow one.
   The first paint parses the whole file at once (`parsed_seq == null`
   forces `refresh` outside the idle gate, `src/app/render.zig:1289–1297`
   → `src/app/syntax.zig:147–151`), and with `sticky_context` on every
   frame that pins a row asks `scopeChain` → `fresh()` for a current
   tree (`src/app/sticky.zig:29–33`, `src/app/syntax.zig:190–195`). The
   spread between runs (357 → 1323 → 2487 ms) suggests something else
   contends for the frame too — the language-server sync on the same
   path (`render.zig:1286`) is the next suspect. Rust's first paint
   highlights lazily and its outline cache is regex-based
   (`src/ui/editor_view.rs:1244–1262`).
3. **Rust — in the standard profile, `Enter` after `Ctrl+F` closes the
   bar, so the next `Enter` edits the file.** Steps 140–145: Rust
   inserts three newlines with auto-indent (26:5, 27:5, 28:5; `dirty:
   true`), Zig steps to the next three matches and keeps the bar. The
   Rust prompt is Enter-accept (`src/app/find.rs:519–523`,
   `accept_find` at `:27–34`); the Zig bar keeps the standard profile's
   Enter = next / Shift+Enter = previous / Esc closes
   (`src/app/cmd_find.zig:183–200`). A user cycling matches on Rust
   modifies the buffer without noticing.
4. **Wrap — the two algorithms differ, and at 120×40 it is the source
   of nearly every screen difference.** Rust: `chunks =
   nchars.div_ceil(tw)`, `char_start = chunk * tw`
   (`src/ui/editor_view.rs:400–420`) — a hard break every `tw` chars,
   `↪` in the continuation gutter (`:494`), and because it counts chars
   a row holding wide glyphs runs past `tw` cells (`tokenize("中 文 文
   本  wide cells", buf` then `↪  as usize)` at step 3). Zig: break
   after the last space, by cell width, at least one row
   (`src/ui/editor_view.zig:426–455`), the continuation gutter blank
   and the text indented. The top line follows: 84 of 134 steps differ
   at 120×40, none at 200×60.
5. **Zig — the sticky-context row pins a scope that does not enclose
   the viewport.** Steps 98–133 and the `zt` at both sizes: Zig pins
   `3075 pub fn poll_span154…` (its body ends at 3098) above the real
   enclosing `3099 pub fn split_needle155…`; Rust pins only the latter.
   `scopeChain` walks the tree-sitter tree
   (`src/app/syntax.zig:190–195` → `structure.scopeChain`), and the
   fixture is Rust-shaped but not valid Rust (`None + "…"`, `true <
   "…"`), so error recovery nests one function inside the previous
   one — and pins something on 90 of 134 steps at 200×60 where Rust
   pins on 2, because after the first unclosed error every later item
   nests. Rust's chain is the regex outline, immune to parse errors
   (`src/ui/editor_view.rs:1244–1262`). Zig also pins with the line
   number and up to three rows (`src/app/sticky.zig:23, 43–66`); Rust
   pins numberless. A real file with a syntax error mid-edit will show
   the same wrong header.
6. **Gutter click — three different answers.** Step 6, cell (32,20) on
   the gutter of the wrapped line 18: Rust 19:1, Zig 18:2. Zig's
   `.gutter` hit falls through to `editorCellMouse` with `col = 0 +
   (m.x − hit.x)` (`src/app/dispatch.zig:1580–1598`, then `:2497`), so
   the gutter's cells count as text columns. Rust's text path is
   wrap-aware (`src/app/dispatch.rs:315–341`, called from
   `src/tui/mouse/down_left.rs:4137, 4166`), but the gutter press
   parks the cursor at the *next* line's start — a line-select whose
   cursor sits past the selected line (`src/tui/mouse/mod.rs:824` reads
   only the row; the selection itself is not in the dump).
   Neither is "cursor to column 1 of the clicked row".
7. **Indent guides.** Rust paints `│` at each indent level in leading
   whitespace (`src/ui/editor_view.rs:292, 871`); Zig paints spaces.
   The 80 steps in the 200×60 run's `highlight/other` bucket differ
   for this alone. Not a navigation
   bug; the largest remaining same-look gap on an open file.
8. **Wheel scroll — known, a separate track.** Rust accelerates a fast
   spin up to 2.5× on `normal` (`src/app/dispatch.rs:1176–1232`,
   `budgeted_scroll` at `:1232`); Zig moves `wheel_lines` per notch
   (`src/app/dispatch.zig:2160–2162`, `src/config/Config.zig:210`).
   The numbers are in the mouse table above.
9. **Zig — the editor scrollbar paints `█` for both track and thumb**
   (`src/ui/scrollbar.zig:45–49`; the thumb differs only by style), so
   the dump — and a monochrome or high-contrast theme — shows a solid
   bar with no position. Rust paints styled spaces
   (`src/ui/editor_view.rs:1405–1425`). Cosmetic.
10. **Dump artifact, Rust side.** `screen_to_text` copies every cell's
    symbol (`src/ipc/mod.rs:1976–1988`); ratatui leaves the spacer cell
    after a wide glyph holding whatever was painted there last, so the
    Rust dump reads `日m本e語tの—` where the screen shows `日本語の`. Not
    user-visible; the harness blanks the spacer on both sides before
    counting.
11. **Startup and memory.** Rust reaches its first frame in 2.0–4.1 s
    (the marketplace fetch and the session restore), Zig in 0.16–0.41
    s; peak RSS 94–116 MB against 47–68 MB.
12. **Chrome, already documented or new-minor:** the tree's cursor
    cell `▌` (README), the rail rows (README), the coverage ticker's
    phase and the clock on the statusline, the claude mark
    (`U+F1E00`) that Zig paints at the right of the tab row and Rust
    does not, and the empty-pane splash sitting one row lower on Zig
    (steps 0–1).

## What the harness cannot see

Selections and highlights (the drag, the double-click's word, the
find match, the cursor-line band) are colour, and `screen.txt` has
none — steps 28–31 agree on the cursor and say nothing about the
selection. The scroll offset is inferred from the gutter. A change to
the IPC protocol that exposed `scroll_line`, the selection range and
the frame's paint time would make three columns of every table exact;
this track did not change the protocol.
