---
title: Hover-help
description: The Ableton-style info box docked to the bottom of the left panel — zero-delay descriptions of whatever the mouse is over, or whatever the keyboard focus is on, in plain English.
---

Hover-help is a small info box docked at the bottom of the left panel. It describes whatever the mouse is currently over — chip, menu item, tree row, tab, activity-bar icon — or when the mouse is idle, whatever the keyboard is focused on. Off by default; toggle on when you're learning mnml's chrome and off once you've built the muscle memory.

The box is modelled on Ableton Live's Info View: a fixed corner, word-wrapped, zero-delay, always visible when enabled so the eye knows where to look. It's different from the tooltip popup (`src/ui/tooltip.rs`) — the tooltip waits 500 ms before painting and floats near the cursor; the info box paints immediately and stays put.

## Turning it on

Three surfaces reach the same setting:

```toml
[ui]
hover_help = true            # default: false
```

```vim
:set hh                      " on
:set nohh                    " off
:set hh!                     " toggle
```

Palette command: `view.toggle_hover_help`. Menu bar: **View → Toggle hover-help strip**.

The prior form of this feature was a 1-row footer strip below the cmdline; that was replaced on 2026-08-09 with the bottom-of-left-panel info box. The config key (`hover_help`) and toggle command (`view.toggle_hover_help`) kept their names — the shape changed, the wiring didn't.

## Layout

Six rows tall, docked at the bottom of the left panel. Width matches the panel width (respects `[ui] tree_width`).

```
── WORKSPACE ─────────────
▸ src/
   app/
   ui/
     hover_help.rs
   main.rs

── GIT ───────────────────
  · main
    2 unstaged / 0 staged

┌────────────────────────┐
│ ?  Info                │
│ hover_help.rs · Rust   │
│                        │
│ File. Enter opens it   │
│ in a new tab. Right-   │
│ click for cut / copy   │
│ / paste / rename.      │
└────────────────────────┘
```

Row 0 is the `? Info` header (a cyan `?` marker + dim "Info" label) so users learn what the box is. The body wraps to the panel width with a 1-cell gutter on each side. Long descriptions truncate at the box's height — there's no scrollbar because the box is ephemeral information, not a document.

The bg is a slightly darker tint than the tree rail so the box reads as a distinct pane rather than accidental tree overflow.

When the toggle is off, the box isn't reserved — the tree gets those six rows back. Setting a very narrow left panel width (below the minimum required for the box) hides the box even when the toggle is on.

## What it describes

The text feed is the same one the tooltip popup uses (`crate::ui::tooltip::describe_text`), stripped down to just the text pair (primary + optional secondary line). Every chip, menu item, tree row, activity-bar icon, and bufferline tab in mnml has a description registered — hovering anything in the chrome gives you a line of text.

### The fallback ladder

When nothing is hovered, the box falls through a fixed ladder so it never goes blank-and-purposeless:

1. **Hovered chip** — the chip currently under the mouse (via `app.hover_chip`).
2. **Focus target when focus isn't on a pane** — for tree focus, the selected tree row; for right-panel focus, the hosted pane; for bottom-panel focus, the hosted pane.
3. **Active pane summary** — the file / URL / kind of the active pane (Editor / Request / Pty / MdPreview / Ai / ClaudeAgents / …).
4. **Focus hint** — a last-resort line pointing at the palette (`Ctrl+Shift+P`).

The focus-target branch takes precedence over the active pane on purpose. Before 2026-08-09, a keyboard-only walk through the tree kept showing the same editor pane info because the active-pane branch always matched first — a vim user on `j` / `k` in the sidebar saw the last-touched editor pane's description instead of the row they were on. The fixed order shows the row when it's what you're focused on.

### Tree rows show file language

For files, the description includes the friendly language name derived from the extension:

| Extension | Language line |
|---|---|
| `.rs` | Rust |
| `.tsx` | TypeScript (JSX) |
| `.ts` | TypeScript |
| `.py` | Python |
| `.go` | Go |
| `.md` | Markdown |
| `.yaml` / `.yml` | YAML |
| `.toml` | TOML |
| `.dockerfile` | Dockerfile |
| `.http` / `.curl` / `.rest` | HTTP request |
| unknown | uppercased extension (`.foo` → `FOO`) |

Directories show as `<name>/` with the secondary line `Directory. Enter or Right expands / opens. j/k walks rows.`.

### Pane-specific summaries

The active-pane branch (either as fallback #3, or via right-panel / bottom-panel focus branch #2) shows a compact one-liner per pane kind:

| Pane | Primary line | Secondary hint |
|---|---|---|
| Editor | `<title> · <LANG> · <N> lines[· unsaved]` | Preview / pinned status, when applicable |
| Request | pane title | `Request pane — Enter to send, Ctrl+S saves as .http/.curl.` |
| Pty | pane title | `Terminal pane — Ctrl+Alt+H to detach, Ctrl+Alt+K to kill.` |
| MdPreview | pane title | `Rendered markdown preview — click header chip to jump back to source.` |
| Ai | pane title | `Claude / Codex session — type at the bottom prompt.` |
| ClaudeAgents | `<source> · <workspace> · <state> · <short session id>` | `Agents dashboard — j/k walks rows, K kills, Enter drills in, / filters.` |

The Agents-dashboard branch reads live from the currently-selected row rather than showing a generic pane title — a dense pane with many session rows is otherwise opaque without a mouse hover. See [AI panes](/manual/ai-panes/) for the sessions themselves.

## When the mouse doesn't matter

The box is genuinely useful without a mouse. Keyboard-only users get:

- Tree focus + `j` / `k` → the box updates every row change with the file / language.
- Right-panel focus (`Ctrl+E` to cycle) → the hosted pane's summary line.
- Bottom-panel focus (same cycle) → same, for whichever pane is hosted at the bottom.
- Everything else (active editor pane focused, palette open, etc.) → the active pane's summary.

The fallback text for pane focus reminds you `Ctrl+Shift+P` opens the palette, so it's still useful even when the box has nothing else to say.

## Interaction with other overlays

The tooltip popup and the info box coexist — hover a chip and both fire, with the tooltip appearing near the cursor after 500 ms and the info-box text updating immediately. The info box has no delay and never floats — it's always in the same corner, so a quick glance down-left tells you what the cursor is on.

The info box lives inside the left panel's paint region. When the left panel is hidden (via `view.toggle_tree` / `Ctrl+B`), the box is hidden with it — the toggle for hover-help doesn't force the panel visible.

## When to leave it off

Off is the default because the box costs six rows of the left panel — those rows show file tree entries otherwise. Enable it while you're:

- Learning mnml's chrome for the first time (hover any chip to see what it does).
- Auditing a keybinding you don't remember (walk to the pane, look at the summary line).
- Wondering why a chip is dim (the description often explains — e.g. `enabled = false` for integrations, or a `[requires]` predicate failure).

Once the muscle memory forms, `:set nohh` and get the tree rows back.

## Next

- [Menu bar](/manual/menu-bar/) — the toggle-hover-help entry lives under View
- [Activity bar](/manual/activity-bar/) — the left panel that hosts the info box
- [Workspaces & the file rail](/manual/workspaces/) — the tree the box paints below
- [Statusline, gutter & F1 help](/manual/statusline-chrome/) — the tooltip popup the info box shares its text feed with
- [Settings & configuration](/manual/settings/) — the `[ui] hover_help` key and its neighbours
