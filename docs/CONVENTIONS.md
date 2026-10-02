# mnml conventions

Short rules, one example each. The design rationale lives in
`docs/DESIGN.md` (D1–D10); this file is what you check a diff against.

## Allocation — three tiers (D1, `src/core/alloc.zig`)

Every allocation belongs to exactly one tier. Name the tier in your head
before you write `alloc`.

| tier | get it from | lifetime | freed by |
|---|---|---|---|
| **gpa** | `app.gpa` (passed to `App.init(gpa, io)`) | process | the owner's `deinit` |
| **snapshot** | `sub.snapshot.allocator()` — one `SnapshotArena` per replace-wholesale dataset | until the next dataset lands | `SnapshotArena.replace` / `reset` |
| **frame** | `app.frame.allocator()` | one frame: from the top of `render` to the top of the next `render` | nobody — `FrameArena.begin` at the top of `App.render` |

```zig
// gpa: lives as long as the buffer
buf.path = try gpa.dupe(u8, path);           // freed in Buffer.deinit

// snapshot: the whole TODO list is replaced at once
const items = try scan.arena.allocator().alloc(Item, n);

// frame: a label that only needs to survive this render
const label = try std.fmt.allocPrint(ui.arena, "({d})", .{count});
```

Rules:
- `page_allocator` only for pty ring buffers. Never in a `test`.
- Every `test` block uses `std.testing.allocator`. Leak = failure.
- No per-buffer arenas: buffer allocations have independent lifetimes, so
  `Editor`/`Buffer` hold gpa-owned `ArrayList`s and free them in `deinit`.
- Nothing allocated from `app.frame` may be stored in `App` or any
  subsystem `State`. If you need it next iteration, `gpa.dupe` it.
  // changed: the reset moved from the top of the loop iteration to the
  top of `App.render`. The hit map is registered during a frame and
  read by the *next* iteration's mouse event; resetting between them
  would hand the router freed rects. Dispatch and tick allocate on the
  arena freely — a render always follows an event.

## String ownership is spelled by the type

- `[]u8` field ⇒ **owned**. The holder allocated it on the gpa and frees
  it in `deinit`.
- `[]const u8` field ⇒ **borrowed**. A literal, or a slice into a snapshot
  or frame arena. The holder never frees it. To keep it past the current
  iteration, `gpa.dupe` at the boundary and store the result as `[]u8`.

```zig
pub const Item = struct {
    path: []const u8,   // borrowed from the scan's snapshot arena
    title: []const u8,  // borrowed from the same arena
};
pub const DynCommand = struct {
    id: []u8,           // owned: registered at runtime, freed on unregister
};
```

## Event payloads (D3, `src/core/event.zig`)

A payload on `AppEvent` is **owned by the event**. The handler either
adopts it (moves it into subsystem state) or frees it before returning.
There is no third option, and no handler may stash the raw pointer to
"deal with later".

```zig
.todos => |result| app.todos.handle(app, result), // adopts result.arena, frees the box
```

- Workers build the payload on their own arena / gpa allocations and post
  it. A failed `post` calls `freeEvent` so a closed queue cannot leak.
- Workers never toast. Failures travel as `.err = .{ .source, .msg }`,
  with `msg` gpa-owned and freed by the handler after toasting.

## Errors (D2, `src/core/command.zig`)

- Commands are `fn (*App) CommandError!void`. A user-facing reason goes in
  `app.diag.fail(...)` (frame arena) right before `return error.Failed`.
- `errdefer` after every acquire. Multi-field mutations snapshot the old
  values and `errdefer`-restore them.
- No `catch unreachable` outside comptime and tests.
- Render functions return `Allocator.Error!void`; OOM skips the frame.

## Components (D6, `src/ui/`)

- A component is `State` (persistent transient: scroll, hover, filter
  buffer — owned by its subsystem) plus `draw(state, ui, area, props)`.
- Register the hit in the **same statement** as the paint:
  `ui.hits.add(row_rect, .{ .row = .{ .panel = .todos, .idx = i } })`.
  A painted-but-unregistered rect is a bug by construction.
- Components take `Ui`, never `*App`. Only commands and event handlers
  see `*App`.
- Layout is the parent's job (`Rect.split*`); a component paints inside
  the rect it is given and clips to it.

## If a thing has a component, draw it through the component

The reason the component layer exists: adjust the language in the
component and everywhere using it benefits. A painter that draws a
frame from four corner literals, keeps its own `--ascii` twin of a hint
string, or cuts a string with its own `"…"` has forked the drawing —
it compiles, renders and reviews clean, and the only way it is ever
found is two screens disagreeing. So:

- **If a thing has a component, draw it through the component.**
- **If the component lacks what you need, extend the component** — a
  variant, a `Look`, a second entry point — **never fork the drawing.**
  Two callers wanting the same missing variant is the signal to add it.
- A true one-off (a glyph that is not a rule, a table's junctions, a
  test helper reading a dump) carries `// chrome-audit: allow — <why>`
  on its line, so the reason sits beside the shape it excuses.

`zig build chrome-audit` (`tools/chrome_audit.zig`) is the guard for the
cheap shapes — a box-drawing glyph as a whole literal outside the
frame modules, an `if (ascii) "…" else "…"` pair a component already
answers — and its unit test walks the real trees under `zig build
unit`. What it cannot see (a chip painted as raw styled text, an empty
state as a plain string) is what review is for.

What each component owns (`src/ui/` unless noted):

| component | owns |
|---|---|
| `border.zig` | every frame (`draw`, five glyph sets incl. `.ascii`) and every straight rule (`rule`, `ruleGlyph`); `Ui.hrule` / `Ui.vrule` are the short forms |
| `overlay.zig` | the popup / menu / modal frames with their titles (`box`, `frameLook`), the hint row (`hint`) and the hint language's one `--ascii` spelling (`hintText`: `·` `←→` `↑↓` `←` `→` `⏎` `↵` `—`) |
| `clip.zig` + `Ui.clipStr` / `Ui.ellipsisText` | cutting a string to cells and the ellipsis it leaves — `…`, or `...` under `--ascii` |
| `header.zig` | the caps header: label, subtitle, the chip ladder on the right |
| `chip.zig` | the `sort:` / `view:` / mode / refresh / new chips — text, styles, the hit |
| `filter_input.zig` | the `/ filter` row: glyph, placeholder, caret, the hit |
| `empty_state.zig` | "nothing here" copy with its glyph and its style |
| `list_panel.zig` | the whole list panel: header + chips + filter + rows + marker + kebab + scrollbar |
| `scrollbar.zig` | every scrollbar (`.glyph` and `.solid` looks) and its hit |
| `link_span.zig` | a link inside text already painted — the `.link` hit, the dotted / lit look — and the one URL matcher (`nextUrl`, `urlAt`); what else links is the app's finder (`app/link_rules.zig`: the installed integrations' `links[]`) on `Ui.links` |
| `render.zig`'s `drawMenu` (`src/app/`) | the context menu: rows, separator rules, the `menu_item` hits |
| `toast.zig` · `prompt.zig` · `confirm.zig` · `tooltip.zig` · `which_key.zig` | one transient each, opened through `overlay.box` |
| `bufferline.zig` | the file tabs (the tab strip in core) |
| `pane_rail.zig` · `accent_color.zig` | the `▌` rail and the one accent ladder |
| `focus_cue.zig` | which pane or section has the keys (`ui.focus_cue`: `.dim`, `.rail`, or `.both` — the default): the dim role on what does not (`words`), the unfocused rail stepped back (`rail`), the focused caps header lit (`label`) — asked by `bufferline`, `header`, `tree_view` and `render.drawPaneContent`, never re-decided |
| `expander.zig` · `tree_view.zig` | the `▸`/`▾` slot and the tree's connectors |
| `sdk/mnml-sdk/src/pane/chrome.zig` | the same chrome on the integrations' side of the wire: `capsHeader`, `tabStrip`, `filterPill`, `rowGround`, `scrollbar`, `frameBox` / `frameTitled`, `vrule` / `hrule`, `confirmBox`, `hintRow`, `actionChips` — an integration supplies words and targets, never glyphs |

## Every pane wears a rail (`src/ui/pane_rail.zig`)

A pane is a colour. One cell wide, down its left edge, its full height,
the `▌` every other "this thing is that colour" marker in the app uses.
No pane kind is exempt but one: a terminal, an editor, a git diff, a
request, a list — if it is a pane, it has a rail. The exception is a
mounted integration, which owns every cell of its own grid: the app
colour there is the sibling's to paint, and a rail on top would be the
same colour twice and a column narrower for the sibling.

- **The colour comes off the one ladder** (`src/ui/accent_color.zig`),
  the same one the SESSIONS panel draws from. A pane takes the first
  slot no live pane is wearing when it opens (`accent_color.firstFree`),
  keeps it for its life, and gives it back when it closes. Two
  terminals open at once are therefore never the same colour, and a
  closed pane's colour is the next pane's.
- **`PaneStore.add` hands it out**, so a new pane kind gets a rail
  without its author doing anything. Adding a kind is a `Pane` variant,
  not a visit to the rail code.
- **A pane that already belongs to something wears that owner's
  colour**, not a slot off the ladder: a git status / diff / graph
  pane its repo's accent, which is what tells two repos' panes apart
  (one repo has no accent — nothing to tell apart — and the pane falls
  back to its own slot). A mounted integration goes further and takes
  no ladder slot at all (`Pane.wearsOwnAccent`): the app colour IS its
  rail, and mnml paints nothing over it.
- **Who paints it is a second question** (`pane_accent.paintsOwnStripe`,
  not `wearsOwnAccent` — a slot and a stripe are different things). Two
  kinds paint their own first column and so get no rail on top of it: a
  mounted integration, and a git status / diff / graph pane while its
  repo has an accent (`git_palette.repoGutter` paints the same `▌` in
  the same cell). Painting both would be the colour twice and the
  content two columns in.
- **The rail registers no hit.** The pane's own hit already covers the
  column, so the stripe is transparent to the pointer.
- **Where it goes.** A pane whose content owns its first column insets:
  the body is `pane_rail.body(rect, true)` and the rail has the column
  to itself. A pane with a blank chrome cell there shares it instead
  (`pane_rail.drawOver`), so nothing on screen moves — the editor's
  gutter opens with the sign column, and a sign still wins the cell it
  needs. When you add a kind, ask which of the two it is; do not invent
  a third.
- **One bar per row.** A pane that paints its own `▌` in its first
  content column — a git graph row in its lane's colour, a sessions
  row in its session's, a usage account's gutter — does not get a
  second one beside it: after the pane paints, `pane_rail.absorb`
  moves that stripe into the rail's cell (the row's own colour wins
  the row) and blanks the cell it left, so no text moves. It runs in
  `drawPaneContent` for every inset pane; a pane never special-cases
  the rail. A pane whose body is a `ListPanel` (the sessions table)
  keeps its first column for the list's selection marker, so its row
  stripe is one cell further in: `pane_rail.absorbList` takes the row's
  own stripe into the rail, else the selection marker, and blanks both
  cells — never `▌ ▌`, never `▌▌`.
- `ui.pane_rail` is `all` / `sessions` / `off`, read in one place
  (`pane_accent.railColorOf`). Nothing else branches on it.

## Chrome that slides in — and the pin that stops it

Three surfaces hide themselves and slide back over the editor when the
pointer asks for them, and they are one idiom, not three:

| surface | config | reveals through | the module |
|---|---|---|---|
| the side columns | `ui.sidebar = .auto` (and an `.always` column on a terminal narrower than `ui.sidebar_auto_below`, 100 by default) | the column's screen edge, then the panel itself | `src/app/sidebar_auto.zig` |
| the launcher dock | `ui.dock.mode = .auto_hide` | the edge band of `ui.dock.edge`, then the strip | `src/app/launcher_dock.zig` |

| the menu bar | `ui.menu_bar = .auto` | the chrome row itself | `src/app/menu_bar.zig` |

A bottom launcher dock is the one of the three whose band and whose
strip can be different rows. The band is the SCREEN's last row — the
edge a hand reaches for — and `ui.dock.placement` settles where the
strip lands: `.inner` (the default) above the statusline, on the
editor area's last row, `.outer` under the `:` line, on the band's own
row. Carved and revealed are the same row in both, so the strip never
moves when the mode does. The grip stays on the band whichever it is,
which is why an open `:` line puts the grip away under both while only
`.outer` has its reveal refused.

The rules they share:

- **A reveal is paint, never layout.** `render.chrome` reports no column
  and no strip while one is up, so every pane keeps the rect it had and
  no pty is resized when the pointer brushes a screen edge.
- **The dwell is arbitrated in one place** (`src/app/hover_zones.zig`),
  because several of them want the same cell. A zone is registered per
  frame, priority breaks the tie, and `dwelled(id)` answers the one
  question each `shown()` asks.
- **Each has an effective mode**, not a raw config read: `mode(app)`
  returns `.always` while the surface is pinned and the config's value
  otherwise. Nothing outside the module reads `app.cfg.ui.<surface>`
  to decide whether it is up.
- **The pin is the family's chip** (`src/ui/pin_chip.zig`): 󰐃 in three
  cells, `P` under `--ascii`, dim and in the comment colour cold, full
  foreground on a ground one step lighter under the pointer, the
  theme's yellow when it is on. It sits at the END of whatever it pins
  — the header strip's right, the dock strip's tail, the last menu
  word — registers its hit with its paint, and is drawn only where
  there is something to pin: a surface configured `.always` wears none.
- **A pin lasts the session and edits nothing.** Unpinning is meant to
  be one click, not a round trip through the config file. (The
  launcher dock's rides in `session.zon` so a restored session comes
  back as it was; the sidebar's and the menu bar's do not.)
- **The grip names the edge** (`src/ui/edge_grip.zig`): `⋯` on a top or
  bottom row, `⋮` on a side column, three cells at the MIDDLE of the
  very band `hover_zones` watches, dim in the comment colour and one
  step brighter under the pointer. It is the band's name and never a
  second way in — a dwell on it reveals because it is *inside* the
  zone. The grip and the pin chip are the two ends of one gesture: the
  grip brings the surface out and a click on it KEEPS it (the pin the
  chip toggles, through the surface's existing command — no new
  command id), the chip lets it go. So a surface wears exactly one of
  the two at a time: the grip while it is down, the chip while it is
  up, and neither when it is configured `.always` (nothing to summon)
  or `.hidden` (no zone is registered, so a handle there would do
  nothing). `ui.edge_grips = false` turns all three off together and
  gives the invisible bands back; the bands never move, so every
  reveal works either way. Where the middle of a band is already
  spoken for, the grip moves to the middle of the run it is actually
  summoning and that is written down — the menu bar's sits on the
  words' run, because the row's own centre is the workspace chip's and
  the chip never hides.

## A command that reads a painter's state must be able to compute it

The file tree's row list is built by its own painter: `Tree.draw` scans
once and latches `loaded`. Anything that only PAINTS is fine with that.
A **command** that reads `app.tree.rows` is not — it can run before any
scan has found anything, and then it reports an empty tree rather than
doing its job. That is how `view.context_menu_at_focus` (Shift+F10) came
to toast `no tree row under the cursor` headless while working in the
live app: in a `.test` the app starts before the script's `write` steps
land, so the one scan sees an empty workspace and nothing re-scans.

The rule: a command that reads state a frame produces **computes it
first** rather than failing on its absence (here, a scan when the row
list is empty). A behaviour that differs between the live app and a
headless script is a bug in the app, not a fact about the harness —
and it is the shape that makes a hunt's findings untrustworthy in both
directions.

## The settings overlay — the family idiom (`src/ui/settings.zig`)

mnml and mixr each own their settings UI; there is no shared crate, so
the idiom is written down instead. A settings screen is:

- A **scrollable sectioned list** in an overlay, not a pane. Headers read
  `── UI ──` / `── Editor ──` / `── AI ──` / `── Integrations ──` /
  `── Reset ──`.
- One row per setting: `▸ <label>:  [active] / other1 / other2  *` — `▸`
  is focus, `[brackets]` the current choice, `*` modified from the
  shipped default. The labels pad so the colons line up.
- Keys, in **both** profiles: `←→` adjust · `↑↓` move · Tab /
  Shift-Tab step a section · Home/End/PgUp/PgDn move further · `/`
  filter (Ctrl+F too in the standard profile) · `Ctrl+R` reset the
  focused row · Enter save + close · Esc cancel (back to the
  opened-state config, including the bytes of every file written
  since) — a live filter first, see below.
- **The vim profile adds its letters**: `h l` adjust, `j k` move, `[`
  `]` section, `g` `G` the ends, `r` reset the row, `R` reset all, `q`
  save. **The standard profile has none of them and is type-to-filter
  instead**: any printable key opens the pill and goes into the query,
  the way VS Code's settings screen behaves, because a settings box
  whose first letter is a command turns `quit` into "save, close, and
  drop `uit` into the buffer underneath". `/` and space are the two
  printables the standard box still spends on a control (the family
  filter chord and the row's toggle), so a query cannot *begin* with
  either. The footer says which set is live (`hintFor`'s two families
  of five forms), and reset-all is the Reset section's action row
  there rather than a letter.
- **The title names the focused row's destination file** (`Settings · →
  .mnml/config.zon`), under `~` for a home-scope one. The FILE NAME is
  the fact it carries — "this project, or every project?" — so a
  subtitle too long for the box is cut from the LEFT
  (`→ …/mnml/config.zon`, `elideLeft`); the border clips from the right,
  which threw exactly that half away.
- **The footer is state-aware.** The box has two key states and the
  footer says which one it is in: the list's set above, or — while the
  filter field has the keys — the FIELD's (`type to filter · ←→ caret ·
  ↑↓ move · Enter to the list · Esc clears`). There `←→` move the text
  caret and Enter only hands the list back, so a footer that still
  promised `adjust` and `save` was wrong about every clause a
  searching user would act on.
- **Reset-all asks first**, in both profiles, in the app's own confirm
  box (`src/ui/confirm.zig`) with Cancel focused — Enter on reflex is
  the harmless answer. It wears the one confirm row like every other
  box (see *The confirm box* below); it never grows its own.
- v1 rows are **discrete choices**. (Zig also ships the minimal number
  row, `‹ [32] ›`.) The overlay never edits arrays of complex things —
  those stay ZON-edited.
- The box is ~60 % of the screen wide and caps at ~70 % tall.

**The list is longer than the box, so the overflow has to be visible,
not merely reachable** — a user cannot arrow to a section they do not
know exists. Three affordances, all in `draw`, none of them optional:

- A **section strip** under the title — `UI · Editor · AI · Integrations
  · Reset`, the cursor's section in the active-chip colour, each name its
  own `.overlay_item(sectionHit(n))` click target. Tab / Shift-Tab step
  sections (`]` / `[` too in the vim profile), Home / End are the ends
  (`g` / `G` too in vim). A jump puts the
  section's header on the *top* row of the window, so the name jumped to
  is on screen. A box too narrow for the names falls back to the
  initials (`U · E · A · I · R`) and then to no strip at all
  (`stripForm`).
- A **scrollbar** down the right edge whenever the list overflows,
  painted by the shared `src/ui/scrollbar.zig` (never hand-rolled), with
  the usual drag and click-on-track through `.scrollbar{owner, axis}`.
- A **position** in the footer — `12–40 of 97`, or the compact `40/97`
  when the long form would cost the key hint a segment, so the overflow
  still shows in a box too narrow for a bar. The form is chosen against
  the *widest* the long one can ever get, so it does not flip mid-scroll.

**Past sixty-odd rows the three affordances stop being enough, so a
settings screen filters.** This is a family rule, not a Zig detail:
scrolling ninety rows to find `Launcher dock labels` is not a control.
mnml's Rust build has a first version of it (`filter_settings` in
`src/app/settings.rs`) that misses most of what follows — the shape
below is the one every settings screen in the family owes, and
`docs/BACKPORT.md` §12 lists what Rust still has to take.

- `/` opens the **family filter pill** (`src/ui/filter_input.zig`'s
  look: a cell of ground, the search glyph in the accent, then the
  query or `/ filter`) on its own row *under the box's title and above
  the section strip*. The strip stays — which sections still hold a
  match is part of the answer, and a pill that replaced it would throw
  that away. The standard profile takes **Ctrl+F** for it as well (VS
  Code's habit); vim gets `/` alone. The footer's hint row names it.
- The field is a **`text_field`** — caret, arrows, Home/End, word
  deletes and paste from day one, never an append-only buffer.
- The query is a **case-insensitive substring over three things**: the
  row's label, the word its current value reads as (`always`, `on`,
  a number row's digits — so `always` finds every row set to it), and
  its section's name (so `editor` brings that whole section).
- A **section header survives only where a row under it matched**; the
  strip dims the sections with none but still lets a click jump. The
  footer swaps its scroll position for `3 of 91` — matched rows of all
  of them. A query nothing answers to says so where the rows would be.
- **The cursor is always on a match.** A focused row that still matches
  keeps the focus; one the query dropped hands it to the first match,
  window back at the top — a cursor left pointing at a row that is no
  longer there adjusts the wrong setting. `↑↓` from the field walk the
  matches without leaving it, `Enter` hands the list back with the
  query still on, and only then does `←→` adjust the focused row.
- **Esc takes the query before it takes the box**: the first press
  clears the filter and returns to the whole list, the second cancels
  the overlay the way it always did.

Anything that moves the **view** rather than the cursor — the wheel, a
bar drag, a section jump — goes through `State.scrollTo`, which pulls the
cursor into the new window. `draw` scrolls back to the cursor, so a
cursor left behind drags the window straight back on the next frame.

## The confirm box — one look, every time (`src/ui/confirm.zig`)

Every yes/no in the app goes through the one primitive, and the
primitive paints the one row. There is no second style to pick.

- **One button row.** Each choice is `  [S]ave  `: the key letter
  bracketed where it occurs in the label, `  [K] Label  ` when it does
  not occur there, underlined either way, painted as a chip — the
  focused one `chip_active`, the rest `chip`. The row starts one cell
  in from the frame's left edge, the choices two cells apart.
- **One height.** Six rows for a one-line message, one more per extra
  `\n`, centred a third of the way down the whole screen (`.third`).
- **One frame.** Rust's square `popup_menu` with the title as plain
  bold text — the same frame the prompt and the which-key popup wear.
- **Cancel is the last choice, and on anything destructive it holds the
  focus** (`.selected = choices.len - 1`), so Enter on a box nobody
  meant to raise is the harmless answer. A cancel that undoes nothing
  still SAYS so where the act would have been visible (the delete box
  toasts `cancelled — a.txt kept`); Esc is the one quiet exit.
- **Labels are verbs, not Yes / No**, wherever the verb is known —
  `Delete` / `Delete permanently` / `Cancel`, `Save all` / `Quit
  anyway` / `Cancel`. The key letter is the verb's own first letter
  where it can be.

// changed (one-confirm), 2026-09-21, on the user's call: the Rust
editor had TWO rows — a bracketed one for its close prompt and a plain
right-aligned one, in a box a row shorter, for its delete confirm — and
`confirm.zig` inherited both behind a `Buttons` enum. Seen side by side
(the quit box against the close box) they read as two different widgets.
The enum and the `.plain` path are gone rather than left as a dead
branch, so there is nothing to pick and nothing to drift.

## Keys reach the editor before the keymap in vim's modal states

- In vim Normal / Visual, every unmodified key is the handler's (`g`,
  `d`, `z`, `m`… are its prefixes). Only modified chords (`ctrl+…`,
  `alt+…`) and the bare leader `space` go through the chord chain
  first. A `Keys.vim` entry like `g d` is therefore documentation for
  which-key / the cheatsheet; the handler emits the same command itself.
- A pending chord owns the next key outright, plain or not: once `space`
  is armed the `e` of `<leader>e` goes to the chain, never to the
  handler as a motion. Esc on a pending chord cancels it — no fallback.
- The `:` line takes every key while open; Insert / Replace keep every
  unmodified key; an operator-pending state keeps every unmodified key.
- Because it takes every key, an open `:` line says so: the statusline
  mode chip reads `CMD` (one word for the app's own line and a
  buffer's vim one), and `status.json` carries `"cmdline"` for the
  app's. A press off the bottom row closes an EMPTY line the way a
  text field loses focus — a half-typed one stays, since the user is
  mid-command (`cmdline.clickAway`).

## Commands (D5)

- Ids are `<namespace>.<snake_verb>` — checked at comptime. `group` is
  the palette group and may be finer than the namespace
  (`picker.files` → `go`); only the panel namespaces (`todos`, `notes`,
  `findings`, `sessions`, `http`) must be grouped under their own name,
  and that is a compile error (`src/core/command.zig`).
- Runners live in `src/<sub>.zig` as `pub const table = .{ .@"todos.refresh" = &refresh, … }`
  and are merged into `command.runners` at comptime.
- Keys are declared per profile in `commands/specs.zig` (`Keys{ vim, standard, both, vim_handler }` —
  `vim_handler` is documentation for a chord the vim handler emits itself).
  Every chord must parse, and an exact duplicate within a profile is a
  compile error.

## Editor + input (D4, `src/editor/`, `src/input/`)

- Text changes only through `Editor.splice(start, end, new)`; it patches
  the line index incrementally, so every line read is infallible.
  `Editor.apply` is the only caller path a handler reaches.
- `Editor.apply(op, viewport_rows, clip, arena) Error!EditOutcome`:
  `error.Unsupported` is a real answer for a tag no slice has landed yet
  (`apply.zig` names the slice in a `TODO(vim-slice: …)`). `Buffer`
  skips such an op and records `@tagName` in `last_unsupported`.
- `InputHandler.handleKey(key, ctx, arena) Allocator.Error!InputResult`:
  the op list, `repeat.inner` and string payloads live in the frame
  arena. Only `Buffer.feedKey` destructures an `InputResult`.
- Dot-repeat is `Buffer` state: ops are `EditOp.dupe(gpa)`d when
  recorded and `free(gpa)`d when replaced. Macro registers store raw
  `Key`s on the `Clipboard` (`clip.macros`, reached through the
  `*Clipboard` `feedKey` takes) and replay through `feedKey`; only the
  recording in flight is `Buffer` state.
  // changed: D4 kept macros per buffer; vim's are registers, so `qa`
  in one file and `@a` in another must work. They persist in
  `<data root>/macros.zon` (`src/app/macros_store.zig`).
- Undo snapshots own their text on the gpa, one per entry; the ring frees
  an entry when it evicts it.
- The vim profile's behaviour follows Neovim: `>>` leaves the cursor
  on the first non-blank, `Y` is `y$` (Neovim's default, so charwise),
  `dip` is linewise. Where it still differs, the deviation is noted at
  the test that pins it.

## Tests

- `std.testing.allocator` only.
- Every behaviour test ships with a break-check: revert the fix, watch
  the test fail, grep that the break really landed.
- Test the shipped default, not values around it.

## Verification on Linux — `tools/linux-verify.sh`

The Mac is where the code is written, so the Mac is where a file that
only passes on the Mac gets written. Before a change that touches the
filesystem, processes, a pty, a shell step or a build file is called
done, run the sequence on Linux too:

```sh
tools/linux-verify.sh                          # every step; logs in .verify/linux/
tools/linux-verify.sh unit-safe corpus         # named steps only
MNML_LINUX_ARCH=amd64 tools/linux-verify.sh    # the other arch (emulated on a Mac)
```

It builds a small image (a Debian base, the Zig 0.16.0 tarball pinned by
sha256, the tools the corpus shells out to) and streams `git archive
HEAD` into a fresh container — never a bind mount, so nothing the run
does reaches the worktree, and what it tests is the commit, not the
working tree. It runs, each with its exit code and log:
`zig build -Dpartial=false`, `zig build unit` in ReleaseSafe and Debug,
the ReleaseSafe build, the gate at 80x24,120x40,200x60, the full corpus
with `MNML_E2E_ALLOW_SHELL=1`, `tools/run-sh-check.sh` and the
integrations' and SDK's own `zig build test`. `summary.tsv` has a row a
step: name, exit, seconds, the counts.

- **Arch** is `MNML_LINUX_ARCH` (`amd64` | `arm64`), defaulting to the
  engine's own, so Apple Silicon runs native arm64 — say which one a
  result came from. CI can run it once per arch.
- **Offline**: `MNML_LINUX_OFFLINE=1` gives the image build and the run
  `--network none`; the Zig packages come from `MNML_LINUX_PKG_SEED`
  (default: the local global cache's `p/`). A base that already has the
  tools (`MNML_LINUX_BASE=node:20`) then needs no apt at all.
- It runs as an unprivileged user, under a reaping init (`--init`): a
  permission test run as root, or an orphan test under a PID 1 that
  never reaps, fails or passes for a reason no user's machine has.
- A shell step is `/bin/sh`, which is dash on Debian: no `printf '\x'`,
  no `echo -e`. GNU coreutils: `mktemp` wants its X's, `dd` its `M`,
  `sed -i` takes no `''`. What the Linux run found is in
  `docs/PORTABILITY-linux.md`.

`tools/linux/run.sh` is the interactive sibling (a read-only bind mount,
a shell in the container, one phase at a time); `linux-verify.sh` is the
whole sequence, unattended, on a commit.

## Hover help: every control ships with its entry; the audit enforces it

The info view (`src/ui/info_view.zig`, the help box at the bottom of the
left column) reads a curated dictionary before the tooltip's one-liner:
`src/app/info_view_copy.zig` is the one switch from a `HitTarget` to an
area module under `src/app/info_view_copy/` (statusline, rail, chrome,
dock, settings, menus, overlays, panels, editor, tree). An `Entry` is
data — a title, a body of two to four sentences, an optional aside,
`keys` and `links`:

- **The body is about THIS control in THIS state.** A git chip's entry
  names the branch and its dirty counts; a diagnostics chip's counts the
  errors; a Settings row's reads its current value and where it is
  written. Never a restatement of the label (`opens more rows` is the
  shape to reject). What a click and the right button do, then the one
  caveat a user hits.
- **`keys` name commands, not chords.** The chord is read off the keymap
  under the active profile when the entry paints (`chordOf`), so a rebind
  moves the copy and an unbound command's row is dropped rather than
  lie. A literal chord (`Enter`, `Esc`, `→ / ←`) is allowed only from
  `literal_chords`. `info_view_copy.lint` fails a key whose command no
  profile binds.
- **`links` are typed.** `.command` carries a `CommandId` — a wrong id is
  a compile error; `.settings` carries a row from `settingsRow("ui.x")` —
  a wrong path is a compile error; `.url` a web page through the OS
  browser; `.docs` a section of the embedded manual (`docsSection("The
  launcher dock")` — docs/CONFIG.md ships inside the binary, and the
  section opens as a read-only markdown preview on a virtual
  `mnml-docs://` path, `src/app/docs.zig`; the lint fails a heading the
  manual does not have); `.ask` sends a prompt to the Claude session with the target's
  state in it (`askPrompt`: the diagnostics, the branch's files, the
  unread messages, the config key and value), gated on Claude's route
  (`ai.route(app, .claude)`, from `ai.routing.claude.backend` else
  `ai.backend`) — off,
  the row becomes a Settings link that says why.
- **A control without an entry is visible.** The ladder paints the
  tooltip's line with a dim *no help written yet* aside first; `zig build
  hover-audit` (`src/app/info_view_audit.zig`) walks every target family
  — every menu opened for real — and fails on an uncovered target that
  `docs/hover-help-todo.txt` does not list. That file is the backlog: a
  new control cannot land without help, and a line that is covered now
  is reported stale. `mnml hover-audit --write-todo
  docs/hover-help-todo.txt` regenerates it.
- **The box is sticky under the pointer.** Crossing onto the box to
  click a link keeps the last target's entry (`State.sticky`); a link's
  press re-resolves that target, so nothing from the frame arena is kept.

## Reverse channels (D3) — `src/app/ai.zig`

A worker that needs an answer from the UI owns the channel: `ai.Job.confirm`
is an `Io.Queue(bool)` with a one-slot ring inside the heap-allocated job.
The worker posts `.confirm` and parks on `getOne`; the UI answers with
`putOne` from the confirm box — and from every other way the box can close
(`dispatch.closeOverlay` → `ai.overlayClosing`), so a dismissed box is a
"no", never a hang. No global map of senders; the job dies with its queue.

## The reference module — `src/todos.zig` (D8)

Every convention above has one concrete instance in `src/todos.zig`.
When a new subsystem is written, it is written against these lines;
when a convention is argued about, this is the code the argument is
about. (Line numbers are as of the commit that added this section;
the function names are the stable handles.)

| convention | where |
|---|---|
| **Payload ownership** (D1): the worker owns the result until the post; the handler adopts or frees, on every path | `scanWorker` (`todos.zig:204`): `errdefer result.destroy(gpa)` at 209, `events.post(io, .{ .todos = result })` at 217. `handle` (`:365`): `defer result.destroy(app.gpa)` at 367 — the box dies whether or not it was adopted. `App.handle`'s `.todos => \|result\| try todos.handle(self, result)` (`app.zig:684`) is the only place the event is touched. |
| **Snapshot arena** (D1): one arena per replace-wholesale dataset | `State.snapshot: alloc.SnapshotArena` (`:131`); `st.snapshot.reset()` then the copy loop in `handle` (`:374`–`:385`). `State.items` borrows from it and is re-pointed in the same function. |
| **Cancellation** (D3): one `Io.Group` per subsystem; cancel-on-rescan; stale results dropped by generation | `State.group: Io.Group` (`:128`); `refresh` (`:187`): `group.cancel(io)` → `generation +%= 1` → `group.concurrent(...)`. The worker is a cancel point per file (`io.checkCancel()` at `:261`, and every read). `handle` drops `result.generation != st.generation` (`:368`). `State.deinit` (`:158`) cancels before anything the worker borrows is freed — `App.deinit` calls it first. The test at `:981` starts three scans over 400 files and asserts only the third lands and nothing leaks. |
| **Workers never toast** (D2) | `postErr` (`:221`) posts `.err = .{ .source = .todos, .msg }`; `App.handle` toasts it and clears `scanning`. |
| **Errors** (D2): `diag.fail` right before `error.Failed`; `errdefer` after every acquire | `refresh`'s `catch` (`:194`), `openItem` / `copyPathCmd` / `ignoreFileCmd` (`:470`–`:530`); `ignoreFileCmd`'s `errdefer app.gpa.free(key)`. |
| **Command table** (D5): `pub const table = .{ .@"todos.<verb>" = &fn, … }`, merged at comptime; menu rows name ids as enums | `pub const table` (`:104`). `openRowMenu` (`:680`) builds `MenuAction{ .command = .@"todos.open" }` rows — a missing id is a compile error. `command.zig`'s `runner_tables` lists `@import("../todos.zig")`. |
| **Hook subscriber** (D10.2): a Zig `Subscriber` on a curated hook | `onSavePost` (`:177`), subscribed in `App.initWith` (`app.zig:325`) as `.{ .zig = &todos.onSavePost }`. The test at `:1110` saves a file with a new marker and asserts the generation moved. |
| **Component draw + hit registration** (D6): a `Ui`, a rect, hits in the same statement as the paint | `draw` (`:706`) hands `ListPanel(Item)` its rows, `paintRow` (`:772`), the sort chip label and the empty state; the panel registers `.row` / `.kebab` / `.chip` / `.filter_input` / `.scrollbar` itself. `paintRow` receives a `Ui` clipped to its row and never reaches `*App`. |
| **Mouse routing** (D6): one `switch (app.hits.at(x, y))`, one prong per hit kind, routed by `PanelId` | `dispatch.zig:512` onward — `.row` → `todos.rowMouse` (`:610`), `.kebab` → `kebabMouse`, `.chip` → `chipMouse` (`:641`), `.filter_input` → `filterMouse`, `.scrollbar` (owner `.panel`) → `scrollbarMouse`, `.menu_item` → `runMenuAction` (`dispatch.zig:299`). |
| **Keys**: the component's `handleKey` first, then the panel's own letters, then the chord chain | `handleKey` (`:561`) — `Panel.handleKey` decides motion / filter / enter; `r` `s` `n` `esc` after; `false` lets `dispatch.zig:51` fall through to the chord chain. |
| **Tests** on `std.testing.allocator`, one `.test` e2e | `:815`–`:1110`; `tests/e2e/todos_panel.test`. |

Things that did not hold as written, fixed in the same change:

- `// changed:` D8 named `todos.cycle_sort`; the spec table (Rust
  parity) spells it `todos.sort`. Three Zig-only ids were added so the
  kebab menu rows can be `MenuAction{ .command }`: `todos.open`,
  `todos.copy_path`, `todos.ignore_file` — the count pins read 800.
- `// changed:` `ListPanel.Props` has no busy flag, so the scanning
  spinner overpaints the refresh chip's three cells from `draw`
  (`paintSpinner`, `:744`); the chip's hit is untouched. A `busy:
  bool` on `Props` is the right home once the ui side takes it.
- `// changed:` D3 has the `.test` runner call `pumpEvents` / `tick` /
  `render`; `App.tick` calls `pumpEvents` itself (`app.zig:701`) so
  the `e2e.Driver` vtable did not change and a worker result lands
  through the same `tick` the headless loop already calls.
- `// changed:` `tests/e2e` was a symlink into Rust mnml's suite with the
  Zig-only scripts kept apart in `tests/e2e-zig`; since 2026-09-07 the
  corpus is a real copy in one folder and the host headers are gone.
- The right-panel slot did not exist: `App.right_panel: ?PanelId`
  (40 columns + a divider, `render.zig`), with
  `view.activity_todos` / `view.toggle_right_panel` /
  `view.focus_right_panel` / `view.right_panel_close_tab` in
  `cmd_view.zig`. One panel at a time; other panels paint a
  placeholder until their module lands.
- A context-menu overlay did not exist: `Overlay.menu` (`MenuState`
  in `app.zig`, `App.openMenu`), drawn by `render.zig`'s `drawMenu`
  with `.menu_item{0, idx}` hits; keys and clicks in `dispatch.zig`.
  A press anywhere else dismisses it.
- `App.hover` tracks the pointer so the kebab-on-hover paints; the
  frame passes it as `Ui.hover`.

