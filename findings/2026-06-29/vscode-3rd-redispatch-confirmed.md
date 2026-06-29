---
agent: vscode-user
severity: SEV-3
verifies: 10c01c1,31e1481,a70b9a3,035b69b
---

# Round-3 verification — shipped commits

Build: `target/release/mnml` rebuilt at 2026-06-29 10:52 via
`PATH=/opt/homebrew/opt/zig@0.15/bin:$PATH cargo build --release`.

Headless harness via file-IPC. Workspaces under `/tmp/mnml-vscode-3rd-*`.

## CONFIRMED — 10c01c1 + 035b69b: Ctrl+Alt+W closes panel tab, Window menu silent

Setup: open right panel (`view.toggle_right_panel`), host outline tab
(`outline.show`), then send `ctrl+alt+w`.

Result: `rightPanelPanes` went `[1] → []`; the Window menu did NOT open
(no submenu items appeared on screen; status still shows the editor
pane as focus). The 035b69b `!modifiers.contains(CONTROL)` guard in
`try_open_menu_from_key` (`src/tui/mod.rs:280`) correctly excludes
`Ctrl+Alt+W` from the menubar accelerator path so the chord_chain layer
binds it to `view.right_panel_close_tab`.

## CONFIRMED — 31e1481: right-click on × opens active-tab menu

With one tab hosted, right-click at the `×` rect `(118, 1)` opens a
menu titled with the active tab's name and items "Close tab" + "Hide
side panel". With two tabs, the menu expands to include "Close other
tabs" + "Close all tabs". Source: `src/tui/mouse.rs:983` (the new
`right_panel_close` right-click branch) routes to
`open_right_panel_tab_context_menu`.

Empty-state toast caveat: the `else` branch toasting "right panel empty
— Ctrl+Shift+B to hide" is structurally unreachable through user
gesture because `right_panel_close` is `None` when no tab is hosted
(see `src/ui/mod.rs:878`). Defensive code, not a bug, but noting
because the test plan asked for that toast — you cannot fire it from
the keyboard or mouse in practice.

## CONFIRMED — a70b9a3 + 035b69b: Close other / Close all without arena-shift drift

Tested with 3 right-panel tabs (outline pid=1, diagnostics pid=2,
AI:explain pid=3) alongside an editor pane pid=0 OUTSIDE the panel.
Right-clicked the outline tab (idx 0), selected "Close other tabs".

Result: `rightPanelPanes` went `[1, 2, 3] → [1]`. Outline survived,
diagnostics + AI closed, editor pane pid=0 ("main.rs") survived
intact. Without the 035b69b descending-sort fix in
`src/app/context_menus.rs:806-828` the ascending iteration would have
hit a stale pid post-shift; the descending sort makes each
`remove_pane_storage` shift fall above remaining targets.

"Close all tabs" exercised separately on 2 right-panel tabs (outline +
diagnostics) plus editor + claude-code Pty panes outside: panel went to
empty, every out-of-panel pane survived.

## CONFIRMED — 31e1481: AI chip preserves state marker at narrow budget

Spawned `ai.explain` while panel hosted outline + diagnostics +
AI:explain. At full panel width (~32 cells, budget=6) bufferline label
was `AI ✦` (Done state). Dragged the panel grip narrow until per-tab
budget < 4; label collapsed to just `✦` — matching the
`src/ui/mod.rs:678` branch
`if budget >= 4 { "AI {marker}" } else { marker.to_string() }`.
Asking / Streaming → `…`; Done → `✦`; Failed → `✗`; Live → `●` all
share the same code path; only `Done` was exercised because the
Claude job completed before snapshot, but the format string is
state-agnostic.

## CONFIRMED — 035b69b: empty-state rects respect panel bottom

Launched with `MNML_ROWS=10` (statusline at y=8, panel height ≈ 7).
Empty-state rects rendered only for outline (y=5), diagnostics (y=6),
and ai (y=7). Grep (would-be y=8) and test (y=9) rects were
*omitted* — `rect_at()` in `src/ui/mod.rs:1057-1068` returns `None`
when `y >= panel_bottom`. Clicking at `(89, 8)` (statusline column
that aligns with the deleted rect's x range) did NOT fire `find.grep`
or `test.run`; `rightPanelPanes` stayed empty.

## CONFIRMED — 035b69b: wrap-shift fix preserves row-to-rect mapping at width 16–18

Dragged panel to width 17 (`right_panel_edge.x = 102`, content x=104).
Clicked the `:outline.show` line at `(107, 5)`. Outline pane opened
(`rightPanelPanes [] → [1]`). With wrapping enabled this row would
have been pushed down by the wrapping of the "Nothing here yet."
prose line, causing the click to land on `:lsp.diagnostics` or
`:ai.chat`. The `.wrap(Wrap)` removal in `src/ui/mod.rs:1025-1029`
keeps each command on its registered row.

## NEW REGRESSION — Ctrl+P workspace affinity bypassed by fuzzy scorer

**Severity**: SEV-2
**Verifies**: f9e7dfa (REFUTED — the fix is structurally incomplete)

**Reproduction**:
```
mkdir -p /tmp/affinity/src && cd /tmp/affinity && git init -q
echo 'pub fn local_lib() {}' > /tmp/affinity/src/lib.rs
mkdir -p /tmp/affinity/.mnml
cat > /tmp/affinity/.mnml/session.json <<'EOJ'
{ "open":[], "active":0, "tree_expanded":[],
  "recent_files":["/tmp/affinity/src/lib.rs","/somewhere/else/lib.rs"] }
EOJ
~/Projects/mnml/target/release/mnml --headless --input standard /tmp/affinity
# Then via IPC:
{"cmd":"key","key":"ctrl+p"}
{"cmd":"type","text":"lib"}
{"cmd":"key","key":"enter"}
```

**Expected** (per commit message + the in-source comment at
`src/app/picker.rs:137-146`): "`Ctrl+P lib<Enter>` lands on the local
lib.rs even when a dozen other projects' lib.rs are in the global
recent list."

**Actual**: `Ctrl+P → "lib" → Enter` opens
`/Users/chrismclennan/Projects/mnml/crates/mnml-bridge/src/lib.rs`
(NOT in workspace, came from global history) instead of the local
`/tmp/affinity/src/lib.rs`. Status `activeFile` after Enter:
`"/Users/chrismclennan/Projects/mnml/crates/mnml-bridge/src/lib.rs"`.

**Root cause**: The f9e7dfa fix re-orders the *source list* fed to the
picker so local files appear first in the unfiltered view. But the
fuzzy scorer applied when the user types "lib" re-ranks by character
score. Local files use the *workspace-relative* label
`"src/lib.rs"` (10 chars). Cross-workspace files use *file_name-only*
label `"lib.rs"` (6 chars) (see `src/app/picker.rs:124-128`). For the
query "lib", a 3-of-6-char match scores higher than 3-of-10, so
every cross-workspace `lib.rs` outranks the local `src/lib.rs`.

**Source pointer**: `src/app/picker.rs:115-136` (label-shaping
asymmetry) + the missing workspace-affinity boost in
`src/picker.rs::refilter` (the scorer doesn't know about workspace
membership).

**Notes**: This is the exact failure mode the fix's own
in-source comment claims to prevent. Either (a) tag picker items with
a `workspace_local: bool` and add a tie-break / score boost on top of
the fuzzy score, or (b) use a consistent label shape (file_name
only) and add a separate `detail` field for disambiguation. No
regression test was added for the fix — recommend one once the
real fix lands.

## Caveat — empty toast unreachable

The 31e1481 right-click-on-× branch has an `else` arm that
`app.toast("right panel empty — Ctrl+Shift+B to hide")` when no tab
is hosted. The `right_panel_close` click rect is unregistered in the
empty state (`src/ui/mod.rs:878`), so the toast is unreachable
through normal gestures. Defensive code; flag for review only if a
future change registers the × rect during empty state.
