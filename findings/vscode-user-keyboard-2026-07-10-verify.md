# vscode-keyboard verify + adjacent hunt (2026-07-10, post-6b1c96c)

Headless standard-input harness against a fresh `cargo build --release`
of 6b1c96c (binary bounced; the previously-cached release binary was
stale, so verifications were re-run against the new build).

## Executive summary

3 verified fixes (Copy id, Show manifest, markdown edit-raw all
palette-reachable + fire cleanly). 3 SEV-2s from the prior hunt
reproduce unchanged; 2 adjacent SEV-2s newly confirmed on the same
Integrations surface. Overall: the palette-twin fix does what it
promised, but the Integrations panel remains keyboard-hostile —
`/`, `j/k`, `Shift+F10`, and `+ Add integration` all fall through to
the hidden tree cursor (opens random tree files) or are outright
mouse-only. A keyboard-purist can now copy an id, but still can't
add / navigate integrations without the mouse.

## Verified fixed (was SEV-2, now works)

### F-01 `integrations.copy_id` — palette-reachable, clipboard confirmed
- Palette id: `integrations.copy_id`
- Palette title: `Integrations: copy an id to clipboard (picker)`
- `Ctrl+Shift+P` → `copy_id` → surfaces as top hit (18 of 665).
- Enter opens picker "Integrations: copy id" (47 rows).
- Enter on first row (`claude_code (on)`) → toast
  `copied ``claude_code`` to clipboard`, `pbpaste` returns `claude_code`.

### F-02 `integrations.show_manifest` — palette-reachable, opens .toml
- Palette id: `integrations.show_manifest`
- Palette title: `Integrations: open a chip's manifest file (picker)`
- `Ctrl+Shift+P` → `show_manifest` → 1 of 665 exact.
- Enter opens picker "Integrations: show manifest…".
- Picking `amplify` opens `/Users/chrismclennan/.config/mnml/integrations/amplify.toml`
  as an editor pane (`status.json.activeFile` confirms).
- Picking `claude_code` (built-in default with no manifest file) toasts
  `no manifest file for ``claude_code`` — it's a built-in default`.

### F-03 `markdown.edit_raw` — palette-reachable, no crash
- `Ctrl+Shift+P` → `markdown.edit_raw` → surfaces as top hit (2 of 665).
- Enter fires without crash even when no md-preview is active.

## Still SEV-2 (unchanged since prior hunt)

### SEV-2 K-01 `set_activity_section` idempotence gate — repro CONFIRMED
`src/app/layout.rs:1882` — `if self.active_section != section` guards
the focus/filter reset. Re-firing the SAME section is a no-op.

Repro:
1. `view.activity_todos` → panel shows a TODO hit.
2. `Down`+`Enter` on the hit → `todo_test.rs` opens; `status.focus =
   pane`.
3. Re-run `view.activity_todos` → `status.focus` **remains** `pane`.
4. Type `/` → editor eats it. `todo_test.rs.dirty = true`, cursor
   col `1 → 2`. Filter never focuses.

### SEV-2 K-02 Integrations + Agents lack per-section cursor — CONFIRMED
Repro (Integrations):
1. `view.activity_integrations`.
2. `j` → `status.treeCursor` `0 → 1`, `treeSelection` `a.txt →
   readme.md`. Enter would open readme.md, not the focused integration
   row.
Same class in Agents (Down + j both no-op on the visible cursor row).

### SEV-2 K-03 `+ Add integration` chip has no palette twin — CONFIRMED
No `integrations.add` in the `Command` registry (`grep -n 'id:
\"integrations\.' src/command.rs` returns 10 hits; none are `.add`).
Only call site is `src/tui/mouse/down_left.rs:1011` via
`crate::command::run("integrations.add", app)` from the click rect —
which silently no-ops (unregistered id). The nearest palette entries
(`sibling.install`, `integrations.glyph_builder`, `integrations.refresh`)
don't semantically match "add an integration to my chip bar".

## Adjacent SEV-2 (newly confirmed)

### SEV-2 K-04 `+ Add integration` chip not Tab-reachable
Rendered as a `Paragraph` at row `last_row` and stored in
`app.rects.integrations_add_chip` (`src/ui/mod.rs:3355`). No focusable
element registered; `Tab` from tree focus does nothing. Only the mouse
handler in `src/tui/mouse/down_left.rs:928` reacts.

### SEV-2 K-05 `Shift+F10` in Integrations panel opens tree context menu
Repro: `view.activity_integrations`, `Shift+F10` → context menu opens
titled `readme.md` (the hidden tree cursor's file), listing tree
actions (Open / Cut / Copy / Delete / …). No path from a focused
integration row to its context menu — same fall-through class as K-02.

## Environment

- Binary: `~/Projects/mnml/target/release/mnml` rebuilt from 6b1c96c
  (pre-rebuild binary was 2h stale and lacked the two new palette
  commands — worth flagging so future verifiers don't false-negative).
- Workspace: `<scratchpad>/ws` with `a.txt`, `readme.md`,
  `todo_test.rs` (single `TODO:`).
