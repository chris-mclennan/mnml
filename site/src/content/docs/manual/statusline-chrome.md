---
title: Statusline, gutter tooltips & F1 help
description: mnml's chrome-discoverability layer — every clickable/hoverable chip on the statusline, per-line gutter tooltips for git marks and diagnostics, and the filterable F1 help overlay.
---

mnml renders three overlapping surfaces that make the editor introspectable without opening a pane: the **statusline** (a strip of chips across the bottom of the screen), the **gutter sign column** (per-line marks for git changes, diagnostics, breakpoints, DAP arrows), and the **F1 help overlay** (a filterable, sectioned, keyboard-driven listing of every command with its bound chord). Each was originally paint-only — mnml drew the glyphs, and the user had to remember what they meant. As of 2026-07-06 all three now respond to hover and click, and the F1 overlay ships a `/` filter input on top so you can narrow a couple hundred rows to just the ones you care about.

This page walks through what each chip does, what its tooltip says, what happens when you click, and how the F1 overlay's filter behaves. It's the reference for "I see a glyph in the chrome — what is it?"

## The design rule

Every glyph in mnml's chrome answers three questions:

1. **What is this?** — a tooltip after ~500ms of stable hover.
2. **What happens if I click it?** — the tooltip's secondary line spells it out (`click: open PR in browser`), and the left-click does exactly that.
3. **What else can I do?** — right-click opens a context menu when the chip has more than one useful action. Where a chip's tooltip mentions `right-click:` that menu exists; where it doesn't, left-click is the only action.

That's the rule; the rest of this page is the inventory.

## Statusline chips

The statusline is a full-width row at the bottom of the screen, with a left-aligned cluster (mode / file / diagnostics / symbol / PR badge) and a right-aligned cluster (LSP progress, wrap, autosave, filesize, line/col, language, clock). Every chip below is registered as a hover rect on `app.rects.*` and routes through the tooltip system.

### Left cluster

| Chip | Glyph shape | Tooltip primary | Tooltip secondary | Left click |
|---|---|---|---|---|
| **File** | `<devicon> <name> ●` | full absolute path (+ ` · unsaved` when dirty) | `right-click: buffer menu` | `view.reveal_active` — expands the file tree and highlights the buffer's row |
| **Diagnostics** | ` N + ⚠ N` (spans both segs) | `N error(s) · M warning(s)` or `no diagnostics` | `click: open diagnostics panel` | `lsp.diagnostics` — opens the workspace-wide problems list |
| **Symbol** | ` › fn foo` | `symbol: <full name>` (untruncated) | `click: open outline` | `outline.show` — opens the symbols sidebar for the active file |
| **PR badge** | `<host>#<number>` (`BB#42`, `GH#101`, …) | `<host><number> — <PR title>` truncated at 60 chars | `click: open PR in browser` | opens the PR web URL in the default browser + toasts "opened BB#42" |
| **Macro rec** | `● rec @a` (appears while recording) | `recording into @a` | `click: stop recording` | `vim.macro_toggle` — stops recording |
| **Find** | ` /q N/M ` (appears during a find) | `find: <query> (N of M)` (full untruncated) | `click: reopen find prompt · n/N: next/prev` | `find.find` — reopens the find prompt |
| **Sel** | ` Sel N ` (appears with a non-empty selection) | `N chars · N bytes · N lines` | — | tooltip only (no click target) |

The **File** chip's rect spans both the devicon and the file name so a click anywhere on the compound chip works. Same story for the **Diagnostics** chip — the error and warning glyphs are separate segs but share one wide hover / click zone so you don't have to aim at either one specifically.

The **PR badge** only paints when the current branch has an open PR (from any of the four forge integrations that mnml resolves via `git_rail.pulls`). Push a new branch and the chip appears the next time the sidecar sync runs; merge or close the PR and it disappears.

### Right cluster

| Chip | Glyph shape | Tooltip primary | Tooltip secondary | Left click |
|---|---|---|---|---|
| **LSP** | `⚙ <server-count>` | `click: :LspStatus (running servers)` | — | opens the running-servers listing |
| **LSP progress** | `⟳ <title>` (appears during `$/progress`) | `LSP: <untruncated title>` (chip clips at 28 chars) | `$/progress notification` | tooltip only |
| **Bg tasks** | `⠋ N` (appears when N > 0) | `N background tasks running` | — | tooltip only |
| **AI in-flight** | `✦ AI` (appears while an inline suggestion is being fetched) | `waiting for AI completion` | `inline suggestion in flight` | tooltip only |
| **Wrap** | `WRAP` (on) / hidden (off) | `click: toggle word wrap` | — | toggles the buffer's wrap setting |
| **Autosave** | `AS` (on) / hidden (off) | `click: show autosave config` | — | toasts the current autosave interval + config path |
| **Filesize** | `123 KB` | `click: :Stat (file metadata)` | — | opens the file's stat overlay |
| **Ln/Col** | `L 42:8` | `click: goto line` | — | opens the `editor.goto_line` prompt |
| **Language** | `<devicon> <ext>` (`  rs`, `  py`, …) | `language: <ext>` or `no language` | `detected from file extension` | toasts `language: <ext> (via file extension)` |
| **Clock** | `12:34` | `click: local ⇄ UTC` | `right-click: clock menu` | swaps between local and UTC display |

The **Clock** chip's right-click menu covers format (12h / 24h / relative), timezone (local / UTC / custom), and clear-tick.

The **Language** chip's click is deliberately a *diagnostic* — it tells you what mnml thinks the language is and where it inferred that from, so if syntax highlighting or the LSP looks wrong you can see the mismatch. If mnml can't detect a language (no extension, no shebang, `.mnml/language_overrides.toml` didn't match) the chip paints `—` and the tooltip reads `no language`.

### Chip removal / hiding

Chips that would show `0` or an empty state hide entirely — the "hide-when-unused" idiom, so the statusline stays scannable. Concretely: the PR badge only appears when there IS a PR; the macro chip only appears while recording; the find chip only appears while a find is active; the Sel chip only appears with a non-empty selection; LSP progress and background-tasks chips appear only while their spinners are alive; the AI in-flight chip appears only while an inline suggestion is being fetched; the wrap chip hides when wrap is off (config default); the autosave chip hides when autosave is off. This means the visible-chip set on the statusline is a rough summary of what's currently going on in the buffer.

As of 2026-07-06, **every** paint-only chip on the statusline has been wired to the hover system, and every chip that has a sensible click action has one. If you see a glyph you don't recognize, hover it.

### The mode chip is special

The bottom-left mode chip (`NORMAL` / `INSERT` / `VISUAL` / …) doesn't have click routing — it's a status indicator, not a control. See [Editing](/manual/editing/#modes) for the full mode inventory. The chip's tooltip *is* wired to distinguish the three visual flavors (`VISUAL` for char-wise, `V-LINE`, `V-BLOCK`).

## Gutter hover tooltips

The gutter (left column of the editor body, before the line-number gutter) paints one glyph per line summarizing what's different from HEAD or what the LSP thinks. Hovering a mark for ~500ms reveals a tooltip that names what it is and — for diagnostics — spells out the full message.

### Mark priority

When multiple marks land on the same line, mnml paints only the highest-priority one — and the tooltip describes that one. The order (highest wins):

1. **DAP arrow** `▶` — the debugger is paused on this line.
2. **Conditional breakpoint** `◆` — breakpoint with a hit condition attached.
3. **Breakpoint** `●` — plain breakpoint.
4. **Diagnostic** `●` colored by severity (red = error, yellow = warning, cyan = info, grey = hint).
5. **Git change** `▎` (green = added, blue = modified, red = removed nearby).

This is the same priority the sign-column paints, so tooltip and glyph always agree.

### What the tooltip says

Per kind:

| Kind | Primary line | Secondary line |
|---|---|---|
| DAP arrow | `▶ debugger paused at line <N>` | `continue / step to advance` |
| Conditional breakpoint | `◆ conditional breakpoint (line <N>)` | `click gutter: toggle · right-click: edit condition` |
| Breakpoint | `● breakpoint (line <N>)` | `click gutter to toggle` |
| Diagnostic (single) | `● <severity>: <message>` — first line of the message, truncated at 80 chars with an ellipsis if longer | (none) |
| Diagnostic (multiple on one line) | Same as single, showing the first message | `+N more on this line` |
| Git change | `▎ git: added/modified/removed nearby (line <N>)` | `] c / [ c jumps hunks` |

The diagnostic tooltip is the useful one — a red `●` doesn't tell you *what* is wrong, but hovering it does. Previously you had to open the Problems pane (`:lsp.diagnostics` or click the statusline's diagnostics chip) or fire a Peek chord to read the message; now hovering is enough.

For lines with multiple diagnostics (a common case in typescript / eslint), the tooltip shows the first message and appends `+N more on this line` so you know there's more if you want to open the panel.

The git-change tooltip's secondary line is a keyboard hint — `] c` / `[ c` in vim mode jump between hunks in the current buffer (see [Git](/manual/git/#cursor-navigation-jumping-changes-in-a-file)).

### One rect per painted mark

Under the hood the editor paints one 1×1 rect per mark into `PaneRects.gutter_marks`. The hover system checks that vec first (before the coarser `editor_gutters` hover), so a hit on a mark cell wins over the generic gutter hover. Move off the mark and the tooltip fades.

## F1 help overlay

`F1` (also `?` in vim mode's default keymap) opens the help overlay — a centered, scrollable listing of every command in the registry grouped by section, with each command's currently-bound chord(s) on the right. It's the discoverability surface: if you can name the operation but don't remember the chord, F1 is where you look.

The overlay is auto-generated from the command registry and the live keymap. That means user `[keys.*]` overrides show up immediately without the help text needing to be hand-maintained — the row for `lsp.hover` shows `alt+k` if that's what your keymap says.

### The chrome

Two extra rows top and bottom bracket the binding list:

- **Row 1 — filter prompt.** Three states:
  - Idle (empty query, not focused): ` / filter…` in comment color.
  - Focused (`/` pressed, typing): ` /<query>` in yellow bold.
  - Filled + blurred (query kept, focus left): ` filter: <query>   (/ to edit)`.
- **Row N-1 — hint bar.** Contextual to focus:
  - While typing: `typing…`.
  - Idle: ` / filter · j/k · c/e · Esc`.

Between them: section headers (`GIT`, `LSP`, `EDITOR`, `HTTP`, …) and binding rows (`ctrl+k ctrl+i  →  lsp.hover`), with a count in the top-right corner of the frame that changes to `N of matched` when filtering.

### Filtering

`/` in the overlay focuses the filter input. Typing appends to the query; Backspace removes; Enter or Esc blurs the input (query stays active); a second Esc closes the overlay.

The filter is a case-insensitive substring match over each binding's title AND its chord string. Type `git` and you get every command with "git" in its title *and* every command bound to a chord containing "git" (usually none — but the point is one query hits both dimensions).

When a filter is active:

- **Sections with zero matches hide entirely.** No empty `GIT` header if the query is `foo`.
- **Per-section collapsed state is ignored.** Sections you collapsed with `c` show every match — the point of filtering is to see hits, not remember what you folded.
- **The header count switches to N-of-matched** so you can see how narrow the filter is.
- **When nothing matches**, the body shows a single `no bindings match "<query>"` row.

### Keyboard

| Key | Action |
|---|---|
| `/` | Focus the filter input |
| Typing (while focused) | Append to query |
| `Backspace` (while focused) | Remove last char |
| `Enter` / `Esc` (while focused) | Blur — query stays active, list stays filtered |
| `↑` / `k` / `↓` / `j` (idle) | Scroll one row |
| `PgUp` / `PgDn` (idle) | Scroll 10 rows |
| `Home` / `End` (idle) | Scroll to top / bottom |
| `c` (idle) | Collapse ALL sections |
| `e` (idle) | Expand ALL sections |
| `Esc` / `F1` (idle) | Close the overlay |

`c` and `e` are the bulk toggles; you can also click a section header to collapse just that one section. Filter mode hides the per-section collapsed state so hits are visible regardless.

## Configuration

Nothing on this page is configured through TOML directly — the chip visibility is data-driven (there's a PR because there's a PR, not because a key is set), and the F1 filter has no persisted state (starts empty each session).

The tooltip **hover delay** is `500ms` and hard-coded in `src/tui/mouse/mod.rs`. That value isn't a config knob yet; if it's too short (spurious tooltips while scanning) or too long (waiting for the tooltip to render) let us know.

## Source

- `src/lib.rs` — `HoverChip` enum (46 variants) + `GutterMarkKind` enum.
- `src/ui/statusline.rs` — chip rect registration on `app.rects.statusline_*`.
- `src/ui/editor_view.rs` — gutter mark painting + `PaneRects.gutter_marks` push.
- `src/ui/tooltip.rs` — `describe()` maps every `HoverChip` variant to its tooltip primary + secondary.
- `src/tui/mouse/mod.rs` — hover delay tracker; mouse-move updates the hovered chip on `App`.
- `src/tui/mouse/down_left.rs` — left-click routing for every statusline chip.
- `src/app/dispatch.rs` — `hover_chip_at(x, y)` walks all chip rects; checked in priority order (gutter marks first).
- `src/app/help.rs` — `HelpOverlayState` (`scroll`, `collapsed`, `query`, `filter_focused`) + `build_help(keymap)`.
- `src/ui/help_overlay.rs` — the overlay renderer (filter prompt row, sections, binding rows, hint bar).
- `src/tui/handlers/overlay.rs::handle_help_overlay_key` — `/`, Backspace, Esc, c/e, j/k, PgUp/Dn.

## Next

- [Editing](/manual/editing/) — the mode chip and cursor shapes that share the statusline
- [Git](/manual/git/) — the gutter's `▎` add/modify/remove signs, the branch chip, and the diff-hunk navigation the tooltip hints at
- [LSP](/manual/lsp/) — the diagnostics severity colors that the gutter mark and tooltip render
- [Chord chains](/manual/chord-chains/) — how the chords listed in the F1 overlay are resolved at run time
- [Right side panel](/manual/right-panel/) — where the diagnostics-chip and symbol-chip clicks route their pane
