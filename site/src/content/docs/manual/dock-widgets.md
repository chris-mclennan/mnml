---
title: Dock widgets
description: Corner-pinned mini-panels — a third UI tier between full editor panes and 1-row status chrome. Notes, log tails, build status.
---

mnml has three UI tiers:

1. **Full panes** — editors, terminals, diffs, the HTTP request pane. They live in the split tree and take 50%-ish chunks of the workspace.
2. **Dock widgets** — corner-pinned mini-panels inside the editor body. Each one occupies a fraction of the editor's width × height, pinned to one of four corners.
3. **Status chrome** — the 1-row statusline, the bufferline, the cmdline bar.

This page is about the middle tier. Dock widgets are for things you want visible *next to* the buffer rather than *instead of* it — a tailing build log, a quick note, a Claude session's last few lines, a transient checklist.

## What a widget looks like

Every dock widget has the same chrome:

- A 1-row **title bar** at the top, with the widget's name on the left and a `⋮` kebab glyph on the right.
- A bordered **body** below it, painted at `(width_frac × editor_width)` by `(height_frac × editor_height)`.
- A **corner pin** — `BottomLeft`, `BottomRight`, `TopLeft`, or `TopRight`. The widget's body anchors against that corner of the editor body (not the workspace — file rail and statusline are excluded from the math).

Widgets sharing a corner **stack inward**: bottom corners stack upward, top corners stack downward. Each per-corner stack is capped at 50% of the editor's height — adding a sixth widget to a corner whose stack would push past that cap simply doesn't render. The editor underneath can't be smothered.

## Creating a widget

The palette commands (`Ctrl-Shift-P`) cover the v1 content variants. There are no default keybindings — `dock.*` is mouse-and-palette territory for now.

| Command | What it does |
|---|---|
| `dock.new_text` | Spawn a Note widget at bottom-left |
| `dock.new_text_br` | …at bottom-right |
| `dock.new_text_tl` | …at top-left |
| `dock.new_text_tr` | …at top-right |
| `dock.new_log_tail` | Spawn a LogTail widget at bottom-left, defaulting to `<workspace>/.mnml/run.log` |
| `dock.move_corner_next` | Cycle the most recently added widget through BL → BR → TR → TL → BL |
| `dock.close_all` | Remove every widget |

Each `dock.new_text*` command appends a Note widget with a sequenced title (`Note 1`, `Note 2`, …) and the default Medium size (0.5 × 0.25). The Notes are seeded with a placeholder body explaining the close glyph and the `dock.close_all` escape hatch.

### Empty-state chip

When zero widgets exist, a faint ` + dock ` chip floats at the bottom-right of the editor body. Click it to spawn a default Note 1. The chip disappears the moment any widget exists — it's discoverability, not chrome.

## Content variants

The content payload is a Rust enum so future variants (live AI-session tail, build/test status, plugin-supplied content) can land without touching the renderer's chrome path. v1 ships two.

### Text

Static text. Created via `dock.new_text*`. The body wraps within the widget; rename via the kebab menu (see below) to give it a meaningful title.

### LogTail

Re-reads a file each frame and shows its last `max_lines` lines (16 by default). Reads are cheap because the files are small — there's no watcher, just a per-frame `read_to_string`. Useful for:

- Build logs (`cargo build 2>&1 | tee .mnml/run.log` while you work)
- Test output
- AI-session JSONL transcripts under `.mnml/ai/`
- Any newline-delimited log a sibling tool writes to disk

When the file has more lines than the widget can show, the title bar carries a `▼N` chip indicating how many lines are hidden above the visible tail. The widget's path is set at creation time; to point a widget at a different file, close it and re-open via `dock.new_log_tail` (or edit `.mnml/session.json` directly — see [Session persistence](#session-persistence) below).

## Sizes

Five named presets live on the kebab menu's **Resize ▸** sub-list:

| Preset | Width × Height (fractions of editor body) |
|---|---|
| Small | 0.25 × 0.15 |
| Medium (default) | 0.5 × 0.25 |
| Large | 0.5 × 0.4 |
| Wide | 0.9 × 0.25 |
| Tall | 0.5 × 0.5 |

Fractions are clamped to `0.15..=0.9` at render time — even a session file with bad data can't produce a 1-cell sliver or an editor-smothering monolith. The kebab menu pre-selects the preset that matches the widget's current size, so opening it on a Medium widget lands the highlight on **Medium**.

A widget dragged to a custom size (a future capability) shows no preset highlighted; the size simply isn't one of the five.

## Layout modes

How the widget interacts with the editor body underneath.

### Overlay (default)

The widget paints **on top** of the editor at its corner. The editor doesn't reflow — it still occupies the full body rect, and the lines under the widget are temporarily hidden. Closing the widget reveals them again. This is the default because it's the lowest-commitment option: pop a Note open, glance at it, close it, no buffer scroll.

### Inline (eats space)

The widget claims its own **strip** at the top or bottom edge of the editor body. The editor reflows around it — the buffer shrinks vertically so the widget sits beside the visible text rather than over it. Use this when the widget is part of your working surface (a persistent log tail, a checklist you're crossing off as you edit).

Multiple inline widgets at the same edge **tile horizontally**: the left corner's widget paints first, then the right corner's widget paints to its right. Each widget gets `width_frac × editor_width` of the strip. If the combined widths exceed the strip width, later widgets silently overflow (first-inline-wins). The combined strip height is capped at 50% of the editor's height so the editor stays usable.

Top and bottom strips coexist — a TL inline note and a BR inline log tail both apply, taking strips off the top and bottom respectively.

## Opacity modes

How the widget paints its background.

### Solid (default)

Paints a full background under the widget, completely covering whatever editor text is behind it.

### Translucent

Skips the body bg fill so the editor text underneath shows through behind the widget's content. The title bar and border keep their background so the widget remains visible — only the body lets text bleed through. Good for a low-distraction reminder note that you want visible but not blocking.

The fractions and corner pin still apply; this is purely about the body paint.

## The kebab menu

Every widget has a `⋮` glyph at the right end of its title bar. Click it (or right-click anywhere on the widget — the right-click is a power-user shortcut) to open the per-widget menu.

```
── Resize ──
  Small
● Medium
  Large
  Wide
  Tall
── Move to ──
● Bottom-left
  Bottom-right
  Top-left
  Top-right
── Layout ──
● Overlay
  Inline
── Opacity ──
● Solid
  Translucent
──
  Rename…
  Close
```

The `●` marker tracks the current value for each section. The menu opens with the highlight pre-positioned on the row that matches the widget's current state — so a Medium / BL / Overlay / Solid widget opens with **Medium** highlighted; you can press `Esc` immediately and you've changed nothing.

The menu **drops up** when there isn't enough space below the kebab anchor (i.e., when it would clip into the statusline). The dispatcher checks the anchor's distance to the body bottom edge and flips the menu's growth direction accordingly.

### Keyboard

| Key | Action |
|---|---|
| `↑` / `↓` | Move the highlight (skipping headers and separators) |
| `Tab` | Same as `↓` |
| `Enter` | Apply the highlighted row |
| `Esc` | Close the menu without changes |
| Click outside | Same as `Esc` |

The `Rename…` row opens a no-pane prompt seeded with the current title; `Enter` commits, `Esc` reverts.

## Drag-to-move

Click + hold on a widget's **title bar** to arm a drag. While armed:

- The title bar gets a cyan accent and shows a `⇲` glyph next to the kebab.
- A cyan ghost chip `⇲ <title>` follows the cursor.
- A translucent `░` overlay paints on the **target landing rect** — the actual rect the widget would occupy if you released here, not the full quadrant of the editor body. A label centers on the overlay (`⤴ Top-left`, `⤵ Top-right`, etc.) so you know which corner you're heading to.

Release to drop:

- If the cursor is in the top half / bottom half × left half / right half of the editor body, the widget pins to the matching corner.
- The widget's size doesn't change — only its corner.

### Magnetic snap

If the release happens within **8 cells** of another widget's body center, the dragged widget **snaps** to that target:

- The dragged widget inherits the target's `corner`.
- The dragged widget reorders in `App::dock_widgets` to sit **adjacent** to the target — above if the cursor was above the target's vertical center, below otherwise.

This is how you build stacks intentionally. Drop Note 2 next to Note 1 at bottom-left and they share the corner with predictable stacking order, rather than Note 2 fighting for its own corner.

Outside the 8-cell snap radius, the fallback is the quadrant logic — useful when you want to *move away* from another widget rather than next to it.

## Session persistence

The entire widget vec — positions, sizes, corners, content payloads, layout mode, opacity mode — round-trips through `.mnml/session.json` like editor buffers and the split tree. Restart mnml and your dock arrangement comes back exactly as you left it.

Session files saved before the layout / opacity fields were added load cleanly via serde defaults (`Overlay` / `Solid`), so an older session never loses its widgets to a schema mismatch.

To clear the dock between sessions:

```bash
# In the workspace root
rm .mnml/session.json
```

Or from inside mnml: `dock.close_all`, then close + reopen.

## Config and ground truth

There's no `[dock]` config section in v1 — widgets are runtime state, not configured. The full data model lives in:

- `src/dock.rs` — `DockWidget`, `DockCorner`, `DockContent`, `Layout`, `Opacity`, `SizePreset`, `KebabMenuItem`, `KebabMenuState`.
- `src/ui/dock.rs` — overlay + inline renderer, kebab menu paint, drop-zone preview, the empty-state chip.
- `src/tui.rs` — mouse and keyboard dispatch (search for `dock_drag_id`, `dock_kebab_menu`, `dock_widget_kebabs`).
- `src/app/mod.rs` — `App::dock_widgets`, `dock_widget_next_id`, `dock_kebab_menu`, plus the `PaneRects` fields for click-rect dispatch.
- `src/app/session.rs` — the save/restore path.
- `src/command.rs` — the `dock.*` palette commands.

## Next

- [Editing](/manual/editing/) — the buffer underneath the widgets
- [Panes & layout](/manual/workspaces/) — the bigger tier above dock widgets
- [Activity bar](/manual/activity-bar/) — chrome on the *side* of the editor
- [Settings & configuration](/manual/settings/) — what's TOML, what's runtime
- [Headless & .test](/manual/headless/) — the dock renders into the virtual screen too
