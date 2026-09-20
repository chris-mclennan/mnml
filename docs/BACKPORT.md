# Backport notes — what mnml-zig proved, and how to do it in Rust mnml

`docs/DESIGN.md` D9 lists the designs that were meant to flow back to the
Rust repo once the Zig side showed they hold. Each item below names the
Zig code that proves the design (file:line as of this branch — the
function names are the stable handles) and says, in one paragraph, how
the same shape lands in Rust. Line numbers drift; `grep` the handle.

## 1. One `AppEvent` enum, one receiver

**Proof.** `src/core/event.zig:92` `pub const AppEvent = union(enum)` is
the single inbound type; `src/core/event.zig:158` `EventQueue` with
`post` at `:184` is the one queue; `src/core/event.zig:138` `freeEvent`
owns the payload when nobody adopts it. Workers post (`src/todos.zig:217`),
the UI thread drains in `App.handle` (`src/app.zig` `.todos => |result|
try todos.handle(self, result)`), and a payload is either adopted or
freed in the handler — never stashed.

**In Rust.** Replace the 31 `Receiver<T>` fields on `App` and the 35
`drain_*` methods with one `enum AppEvent { Todos(ScanResult), Git(..),
Lsp(..), Pty(..), .. }` and one `mpsc::Receiver<AppEvent>` (`Sender`
cloned into every worker). `tick` becomes one `while let Ok(ev) =
rx.try_recv() { self.handle(ev) }` with a `match`. Payload ownership
falls out of `enum` moves. Do it one subsystem at a time: add the
variant, route the worker's `Sender<T>` through a shim that wraps into
`AppEvent`, delete the old receiver.

## 2. Wakeup-driven loop; idle CPU → 0

**Proof.** `src/tui/loop.zig:82–86`: the loop computes
`app.nextDeadlineMs()` and blocks on `app.events.wake.waitTimeout(io,
timeout)`; the input worker posts key events into the same queue
(`src/tui/input.zig`), so the UI thread has exactly one wait. `App.tick`
and `App.render` run only after a wake or a deadline.

**In Rust.** Move crossterm reading onto its own thread that sends
`AppEvent::Input(Event)` into the receiver from item 1, then replace the
`event::poll(16ms)` spin with `rx.recv_timeout(next_deadline -
Instant::now())`, where `next_deadline` is the minimum of the toast
expiry, the autosave timer, the watcher poll, the git refresh and the
cursor blink. Render only when an event arrived or a deadline fired.

## 3. Pty: a ring buffer plus one "readable" flag

**Proof.** `src/pty/session.zig:2` — a reader thread moves the child's
output into a `Ring` (`src/pty/ring.zig`; capacity at `session.zig:119`),
and notifies once on the empty→readable edge (`:77`), not once per read.
The UI thread feeds the ghostty-vt `Terminal` from the ring on its own
schedule; `held` (`:133`) is the one atomic.

**In Rust.** Replace the `Sender<Vec<u8>>` per 8 KiB read with a
`ringbuf::HeapRb<u8>` (producer on the reader thread, consumer on the UI
thread) and an `AtomicBool` "readable" that the reader sets on the
empty→non-empty transition and posts one `AppEvent::PtyReadable(id)`
for. `tick` drains the consumer into the vt parser in one pass. Output
bursts stop allocating a `Vec` each, and the queue stops filling with
8 KiB chunks during a `cat` of a large file.

## 4. `HitMap` + `HitTarget`: mouse routing is one `match`

**Proof.** `src/ui/hit.zig:38` `HitTarget = union(enum)` and `:84`
`HitMap` with `add` (`:97`) and `at` (`:103`); every component
registers its rect in the same statement that paints it
(`src/ui/list_panel.zig` — rows, kebab, chip, filter, scrollbar).
`src/app/dispatch.zig:762` `const target = app.hits.at(m.x, m.y)` then
one `switch` with one prong per kind; `:1316` is the same lookup for
drags. `rects.json` is derived from the map, not maintained.

**In Rust.** Add `enum HitTarget { Pane(PaneId), Row { panel, idx },
Chip { panel, kind }, Divider(usize), Button(u32), .. }` and `struct
HitMap(Vec<(Rect, HitTarget)>)` cleared at the top of `draw`. Every
`render_*` that computes a rect pushes it. `dispatch_mouse` becomes
`match hits.at(x, y)`. Delete `down_left.rs` (4558 lines) and the
271-field `PaneRects` as prongs move over; keep `rects.json` by
serialising the map. The Zig side also records *attempted* rects so a
component painting past its parent is a test failure — worth carrying
over as `debug_assert!(child ⊆ parent)` in `HitMap::add`.

## 5. A `Ui` context instead of `&mut App` in painters

**Proof.** `src/ui/ui.zig` — `Ui{ canvas, hits, theme, arena, focus,
hover, ascii }` is what every `draw` receives; `src/app/render.zig:124`
builds it once per frame. Components never see `*App`; only commands and
event handlers do (`docs/CONVENTIONS.md` "Components"). `paintRow` in
`src/todos.zig` receives a `Ui` clipped to its row.

**In Rust.** `struct Ui<'a> { frame: &'a mut Frame, hits: &'a mut HitMap,
theme: &'a Theme, focus: Focus, hover: Option<(u16, u16)>, ascii: bool }`
and change painter signatures from `fn draw(app: &mut App, f: &mut
Frame, area)` to `fn draw(state: &PanelState, ui: &mut Ui, area, props)`.
The borrow checker then stops the painter from mutating app state, which
is the point. Start with the panels that already have a `*_panel.rs`
module; the editor view last.

## 6. `ListPanel<Row>`: one widget for TODOS / NOTES / FINDINGS / SESSIONS

**Proof.** `src/ui/list_panel.zig:82` `pub fn ListPanel(comptime Row:
type) type` with `Props` (`:110`) and `draw` (`:138`): header with the
live count, the `/` filter row, the focused-row accent, the scrollbar,
the kebab and the sort chip are all inside it; the caller supplies a
`paintRow` and the chip labels. `src/todos.zig:706` is the one instance
so far; the NOTES / FINDINGS panels are on the Remaining list because
the widget makes them a re-skin.

**In Rust.** `struct ListPanel<R> { state: ListState, _row: PhantomData<R> }`
with `fn draw(&mut self, ui: &mut Ui, area, props: ListProps<'_, R>,
paint_row: impl Fn(&R, &mut Ui, Rect))`. Move the shared chrome out of
`todos_panel.rs`, `notes_panel.rs`, `findings_panel.rs` and
`sessions_panel.rs` into it; the four files keep only their row type,
their paint closure and their data source. The sort chip and the
narrow-width icon form live in the widget once, which is where the
38-cells-at-30 bug would have been caught.

## 7. `CommandId` from a spec table; `MenuAction::Command(CommandId)`

**Proof.** `src/core/command.zig:56` `pub const CommandId = blk:` derives
the enum from `src/commands/specs.zig` at comptime; `:130` `runners` is
an `EnumArray(CommandId, ?CommandFn)` merged from every subsystem's
`pub const table`; `:460` `MenuAction = union(enum) { command: CommandId,
.. }` so a menu row naming a wrong id is a compile error; `-Dpartial=false`
makes a spec without a runner a compile error too. `zig build docs`
(`tools/gen_commands.zig`) renders the same table, so the docs cannot
drift.

**In Rust.** A `build.rs` that reads `commands.toml` (or a Rust array in
`src/commands/specs.rs` included by both) and writes `enum CommandId`
plus `static SPECS: [Spec; N]` into `OUT_DIR`. `MenuAction::Command(String)`
becomes `MenuAction::Command(CommandId)`, and the four source-scanning
tests (menu ids resolve, default keyspecs parse, duplicate ids, chord
collisions) become `const` assertions or build-script errors. The
right-click audit bug class — a row firing an id that does not exist —
stops being a runtime discovery.

## 8. `fn(&mut App) -> Result<(), CommandError>` and a `Diag` slot

**Proof.** `src/core/command.zig:24` `CommandError` (`Failed`,
`NoActivePane`, `NotAnEditor`, `OutOfMemory`, ..) and `:39` `Diag{ msg }`
with `fail` (`:48`): a runner writes the user-facing reason into the
frame arena and returns `error.Failed`; the dispatcher toasts it once.
`src/app/cmd_app.zig` `qfGo` is a small example — four reasons, one
return type. The `.test` runner asserts on the toast, so a wrong reason
is a failing test.

**In Rust.** `type CommandFn = fn(&mut App) -> Result<(), CommandError>`
with `enum CommandError { Failed(String), NoActivePane, NotAnEditor, .. }`;
`run_command` does `if let Err(e) = f(app) { app.toast(e.to_string()) }`.
Delete `last_command_failed` and the ad-hoc `bool` returns. The
`Failed(String)` variant is the `Diag` slot; a `diag!(app, "…")` macro
that builds it keeps call sites short.

## 9. A per-job reverse channel for AI confirms

**Proof.** `src/app/ai.zig:119` `confirm: Io.Queue(bool)` inside the
heap-allocated job; the worker parks on `getOne` (`:812`), the confirm
box answers with `putOne` (`:548`), and every other way the box can
close answers `false` (`:524`, `overlayClosing` at `:553`). No global
map of senders; the job dies with its queue.

**In Rust.** Replace `HashMap<u64, Sender<bool>>` on `App` with a
`tokio::sync::oneshot::Sender<bool>` (or `std::sync::mpsc::SyncSender<bool>`
with capacity 1) stored on the job's confirm request: `AppEvent::AiConfirm
{ job, prompt, reply: Sender<bool> }`. The overlay keeps the sender; its
`Drop` (or the explicit close paths) sends `false`. A dismissed box is a
"no", never a hang, by construction.

## 10. `apply_one` prongs delegate to `editor/{motion,insert,delete,…}`

**Proof.** `src/editor/apply.zig` — `Editor.apply` is one `switch` whose
prongs are one-liners into `motion.zig` (`:60` `motion.page`),
`insert.zig` (`:163` `insert.insertNewline`), `delete.zig` (`:168`
`delete.backspace`), `select.zig`, `surround.zig`, `multicursor.zig`.
Each module owns one concern and its tests; `apply.zig` stays a table.

**In Rust.** Split `editor.rs::apply_one` the same way: `mod motion;
mod insert; mod delete; mod select; mod surround;` under `src/editor/`,
each exporting `pub fn <op>(ed: &mut Editor, out: &mut EditOutcome)`.
`apply_one` becomes `match op { EditOp::Backspace => delete::backspace(self,
out), .. }`. The move is mechanical and can be done one arm at a time;
the tests move with the arm.

## 11. Cancellation per subsystem: one `Io.Group`, joined on drop

**Proof.** `src/todos.zig:128` `group: Io.Group`, `:189` `group.cancel`
before `:194` `group.concurrent` on rescan; `State.deinit` (`:159`)
cancels before anything the worker borrows is freed, and `App.deinit`
calls it first. Stale results are dropped by generation. The same shape
in `src/app/update.zig` `State.group` and `src/app/http.zig` `group`.

**In Rust.** Give each subsystem a `tokio_util::sync::CancellationToken`
(or an `Arc<AtomicBool>` checked in the worker's loop) plus the
`JoinHandle`s it spawned; `Drop for Subsystem` cancels then joins.
Replace "drop the `Sender` and hope the worker notices" with an explicit
`token.cancel()` and a generation counter on results so a late reply
from a cancelled scan is ignored rather than adopted.

## 12. The settings box says how long its list is

**Proof.** `src/ui/settings.zig` `draw` splits the box into a section
strip (`stripForm` / `drawStrip`), the rows, and a footer; the rows give
a column back to `scrollbar.drawVertical` under `scrollbar_owner`
whenever `items.len > list_h`, and the footer carries `positionText`
(`12-40 of 97`, compact `40/97` when the key hint needs the room).
`State.scrollTo` is the one door for a view move — the wheel
(`State.wheel`), a bar drag (`State.barJump`, routed by `dispatch.zig`'s
`paneBarJump`) and a section jump (`State.jumpSection` / `jumpTo`, bound
to `]` `[` Tab Shift-Tab `g` `G` and to each strip name's
`sectionHit(n)`) all call it, so the cursor is pulled into the new window
instead of dragging it back on the next frame.

**The filter on the box is NOT one of these.** Rust already has one —
`SettingItem::matches_row` / `filter_settings` / `settings_filter_focus`
in `src/app/settings.rs`, painted as row 0 of the inner area by
`src/ui/settings_overlay.rs` — and Zig's (`Filter` / `filterKey` /
`filtered` / `rowMatches` in `src/ui/settings.zig`, `lists` / `refocus`
in `src/app/settings.zig`) is the same feature with four differences
worth taking the other way, back into Rust:

- Rust's filter input is **append-only** (`s.filter.push(c)`), with a
  painted `▏` for a cursor. Zig's is a `text_field`, so the caret,
  `←→`, Home/End, the word deletes and a paste all work. This is the
  gap `docs/CONVENTIONS.md` says to close on day one, and it is still
  open in Rust.
- Rust matches a row's label and **every option it offers**; Zig
  matches the label, the word the **current value** reads as, and the
  **section's name**. `always` should find the rows that *are* always,
  not every row that could be; `editor` should bring that section.
- Rust drops the empty sections silently. Zig keeps every name on the
  section strip and **dims** the ones with no match, so the strip says
  where the matches are and a click still jumps (by name — the visible
  list has lost the headers). Rust has no strip yet either (above).
- Zig's footer swaps its position for **`5 of 87`**, and a query
  nothing answers to says **`no setting matches "…"`** where the rows
  would be rather than leaving a blank box.

One difference goes the other way and should stay: Rust focuses the
field the moment the overlay opens (a vscode-keyboard finding — typing
straight in used to drop keystrokes). Zig cannot, because its list
binds `j` `k` `h` `l` `r` `R` `g` `G` `q`; `/` (and Ctrl+F in the
standard profile) opens it instead.

**In Rust.** `src/app/settings.rs` builds the same item list and
`src/ui/` paints the same 60 % x 70 % box, and it has the same bug: the
UI section alone outgrows the cap, so `Editor` / `Integrations` / `AI` /
`Reset` sit below the fold with nothing on screen saying so. Take the
three affordances in one pass — they are independent of the row
painter. Reuse `paint_simple_scrollbar` for the bar (do not hand-roll
one), register it under a reserved scrollbar owner so the existing
`ScrollbarDrag` routing picks it up, and add a `section: usize` arm to
the settings hit enum for the strip. The footer position is the one that
matters for narrow terminals, where no bar fits; it is four lines.
Everything here is component-local — no `Pane` or `EditOp` variant is
involved, and one command id: `view.settings_search`, which opens the
box with the filter already holding the keys. `/` is only discoverable
once you are in the box, so the palette needs its own way in; Rust
focuses the field on open and so needs no equivalent.

**One thing the Rust side should NOT copy.** The script that proves
these affordances used to assert the footer's `22/93` verbatim, and
every settings row that landed anywhere re-pinned it — 93, 95, 96, 98
in a single day. Zig's `status.json` grew a `settings` object instead
(`{top, visible, atTop, atEnd}`, `src/ipc/screen.zig`), the same
window without the total, and the script reads that. Rust's
`status.json` can take the same key: it is additive and its `quit` /
`cursor` neighbours are untouched.

## Two more that were not on the list

- **Persisted state as ZON with a version and a workspace key**
  (`src/app/session.zig` `Saved.version` / `.workspace`, checked in
  `restore` before anything is applied): a stale or foreign session is
  one toast, never a half-restored layout. In Rust: add `version` and
  `workspace` to `SavedSession`, check both first, and stop
  deserialising into the live `App` field by field.
- **`defaults.test` + a break-check script** (`tests/e2e/defaults.test`,
  `tools/break-check.sh`): the shipped defaults are asserted from the
  screen, and every behaviour test is shown to fail against a one-line
  break before it counts. Both are shell / `.test` files the Rust repo
  can take as they are, pointing at `cargo test -- <name>`.
