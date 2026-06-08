---
title: Coming from VS Code
description: Translation guide for VS Code users — standard input mode, Ctrl shortcuts, the command palette, tabs + splits + sidebar + multi-cursor, what the mouse can reach and what's keyboard-only.
---

mnml's default input mode is **standard** — modeless, Ctrl-shortcut, typing inserts. If you came in from VS Code, almost every chord in your fingers does the thing you expect. `Ctrl+S` saves. `Ctrl+P` opens the file picker. `Ctrl+Shift+P` opens the command palette. `Ctrl+/` toggles a line comment. `Ctrl+D` adds the next occurrence to a multi-cursor.

What's different: there's no Lua extension API, no settings JSON, and the file tree is one of several rails. mnml is a terminal app, so anything VS Code does via Electron-specific affordances (drag-from-system-drop, image preview tabs, side-by-side rich diff) either renders the terminal-native equivalent or doesn't exist. The job of this page is to point out which chords translate, what the mouse can do, where the keyboard alternative lives, and what isn't here.

## You're already in standard mode

Standard is the default — you don't have to set anything. If you've inherited a `~/.config/mnml/config.toml` that flipped you into vim mode, change it back:

```toml
# ~/.config/mnml/config.toml
[editor]
input_style = "standard"
```

Or runtime-toggle (works from either mode):

```vim
:set input=standard
```

That `:` ex command works in standard mode too — `:` is one of the few "vim-isms" that always pops the ex line, regardless of input handler. There's also a palette command: `Ctrl+Shift+P` → **editor: toggle keymap**.

Standard mode has no mode chip. There's nothing to leave; typing inserts; arrows move; `Shift+arrow` extends a selection.

The internals — why both modes coexist without scattering `if vim {}` through the editor — are documented on [Editing](/manual/editing/). You don't need them to be productive.

## The chord translation

These tables cover the chords you reach for instinctively. Source of truth: `src/command.rs` (built-in defaults) and `src/input/standard.rs` (the standard handler).

### File ops

| VS Code | mnml | Notes |
|---|---|---|
| `Ctrl+S` save | `Ctrl+S` | App-level command; works from every pane |
| `Ctrl+N` new file | `Ctrl+N` | |
| `Ctrl+O` open file | `Ctrl+P` | mnml uses VS-Code's *file picker* chord (Cmd+P on macOS), not the OS file dialog |
| `Ctrl+P` quick-open | `Ctrl+P` | Fuzzy file picker |
| `Ctrl+Shift+P` command palette | `Ctrl+Shift+P` | Also `F1` |
| `Ctrl+W` close tab | `Ctrl+W` | Closes the active buffer |
| `Ctrl+Shift+T` reopen closed | `Ctrl+Shift+T` | |
| `Ctrl+Tab` last buffer | `Ctrl+Tab` | Also `Ctrl+6` (vim alias) |
| `Ctrl+PageDown` / `PageUp` next/prev tab | `Ctrl+PageDown` / `PageUp` | |
| `Alt+1` … `Alt+9` jump to tab N | `Alt+1` … `Alt+9` | |
| `Ctrl+B` toggle sidebar | `Ctrl+B` | Toggles the file tree / activity rail |
| `Ctrl+,` settings | `Ctrl+,` | Opens the schema-driven [settings overlay](/manual/settings/) |

`Ctrl+R` is mapped to `picker.recent` (recent files / workspaces), not to "reload window" — VS Code's reload doesn't have an analog here; mnml's `<leader>r` (in vim mode) or the **app: restart** palette command does the same thing.

### Editing

| VS Code | mnml |
|---|---|
| `Ctrl+A` select all | `Ctrl+A` |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | `Ctrl+C` / `Ctrl+X` / `Ctrl+V` (system clipboard) |
| `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` undo / redo | All three present (`Ctrl+Y` is redo too) |
| `Ctrl+/` toggle line comment | `Ctrl+/` |
| `Ctrl+]` / `Ctrl+[` indent / dedent | `Ctrl+]` (bracket match) + `Tab` / `Shift+Tab` for selection indent |
| `Alt+↑` / `Alt+↓` move line | `Alt+↑` / `Alt+↓` (also `Alt+J` / `Alt+K`) |
| `Shift+Alt+↓` duplicate line | `Ctrl+Shift+D` (mnml's chord); `Shift+Alt+↓` doesn't currently fire |
| `Ctrl+Shift+K` delete line | `Ctrl+Shift+K` |
| `Ctrl+Enter` open line below | `Ctrl+Enter` |
| `Ctrl+Shift+Enter` open line above | `Ctrl+Shift+Enter` |
| `Ctrl+L` select line | `Ctrl+L` |
| `Ctrl+D` add next occurrence | `Ctrl+D` |
| `Ctrl+Shift+L` select all occurrences | `Ctrl+Shift+L` |
| `Ctrl+Alt+↓` / `↑` add cursor below / above | `Ctrl+Alt+↓` / `↑` (also `Ctrl+Alt+J` / `K`) |
| `Esc` collapse selection / cursors | `Esc` |
| `Home` / `End` smart line nav | `Home` / `End` (smart-home: first non-whitespace, then col 0) |
| `Ctrl+Home` / `End` file start / end | `Ctrl+Home` / `End` |
| `Ctrl+G` go to line | `Ctrl+G` |
| `Ctrl+←` / `Ctrl+→` word motion | `Ctrl+←` / `Ctrl+→` (Shift extends) |
| `Ctrl+Backspace` / `Delete` word-delete | Both present |

**Modifier-leak guard.** Adding Alt to any Ctrl chord (so `Ctrl+Alt+X`, `Ctrl+Alt+A`, etc.) is silently ignored — it does NOT fire the bare-Ctrl variant. macOS keyboards emit `Ctrl+Alt+*` for OS-level shortcuts and the leak used to cut/select/save by accident. Fixed; explicit `!alt` guards on every Ctrl arm.

### Find + replace

| VS Code | mnml |
|---|---|
| `Ctrl+F` find in file | `Ctrl+F` |
| `F3` / `Shift+F3` next / prev match | `F3` / `Shift+F3` |
| `Alt+R` toggle regex in find | `Alt+R` |
| `Ctrl+H` find + replace | `Ctrl+H` |
| `Ctrl+Shift+F` workspace search | `Ctrl+Shift+F` (graphical grep pane) |

### LSP / language intelligence

mnml's LSP surface mirrors VS Code closely. See [LSP](/manual/lsp/) for the full story.

| VS Code | mnml |
|---|---|
| `F12` goto definition | `F12` |
| `Ctrl+Space` trigger completion | `Ctrl+Space` |
| `Ctrl+.` quick-fix / code actions | `Ctrl+.` |
| `Alt+Enter` quick-fix (JetBrains alias) | `Alt+Enter` |
| `Alt+Shift+O` organize imports | `Alt+Shift+O` |
| `Ctrl+Shift+I` format document | `Ctrl+Shift+I` |
| `Ctrl+Shift+O` symbols in file | `Ctrl+Shift+O` |
| Hover popup (mouse) | Hover with mouse, or `:Hover` ex command |
| `F2` rename symbol | Palette: **lsp: rename symbol** |

`Ctrl+click` for goto-definition works — mouse-over a symbol with Ctrl/Cmd held, click, mnml fires `lsp.goto_definition` on the symbol under the cursor. `Alt+←` / `Alt+→` walk the jump history.

### Tabs (mouse + keyboard)

The bufferline is the row of file tabs across the top of the editor. mnml supports both VS-Code-style click-and-drag and keyboard navigation.

| Mouse action | Result |
|---|---|
| Left-click tab | Focus that buffer |
| Middle-click tab | Close that buffer |
| Drag tab | Reorder (drop slot is computed live during drag) |
| Right-click tab | Context menu — Close, Close others, Close all, etc. |
| Click the `×` on a tab | Close that tab |
| Click the `+` (right edge) | New empty buffer |

Keyboard equivalents are all in the file-ops table above.

### Splits

| VS Code | mnml |
|---|---|
| `Ctrl+\` split editor | `Ctrl+\` toggles a scratch terminal (note: differs from VS Code) |
| Drag split divider | Click + drag the divider |
| Click in a pane to focus | Click in the pane |
| Close active editor group | Palette: **view: close split** |

mnml's split chord story is in vim's `Ctrl-W` prefix — `Ctrl-W v` / `Ctrl-W s`, then `Ctrl-W h/j/k/l` to navigate. Even in standard mode, those work (the `Ctrl-W` prefix is global). The leader equivalents (`<leader>sv` / `<leader>ss` / `<leader>sh`/`sj`/`sk`/`sl`) need the leader chord (`Ctrl+K` in standard mode) — see the leader section below.

**Heads up — `Ctrl+\` opens a scratch terminal**, not a split. The chord matches `Ctrl+`backtick`` for the integrated terminal. If you want to split, use `Ctrl-W v` or the palette.

### Tree + sidebar (mouse-friendly)

| Mouse action | Result |
|---|---|
| Click file in tree | Open in preview (italic tab) |
| Double-click file in tree | Open + pin (regular tab) |
| Click folder | Expand / collapse |
| Right-click tree node | Context menu (rename, delete, new file, new folder, reveal in OS) |
| Click `+` chip on a section | Add — workspace, integration, etc. |
| Click integration icon | Launch that sibling pane |
| Hover any chip | Tooltip — what is this, what's its state |

Keyboard: `Ctrl+B` toggles the tree. `Ctrl+Shift+E` focuses the tree from anywhere. Once focused, arrow keys / `j` `k` navigate, `Enter` opens, `Space` previews, `/` filters, `n` creates a new file, `Esc` returns to the editor.

### The command palette

`Ctrl+Shift+P` (or `F1`) opens the palette. Every command — every chord, every ex command, every plugin action — is searchable here by name. Type to filter, `↑` `↓` walk results, `Enter` runs, `Esc` closes.

The palette also reads:

- **Recent commands** — `Ctrl+R` lists recently-run commands
- **Palette bar** — there's an optional always-visible search chip in the bufferline (`[ui] palette_bar_visible = true`); clicking it is the same as `Ctrl+Shift+P`

### Multi-cursor

The Sublime / VS Code idiom is exactly the same:

| Action | Chord |
|---|---|
| Add cursor at next occurrence | `Ctrl+D` |
| Skip current + add next | (palette: **editor: skip occurrence**) |
| Select all occurrences | `Ctrl+Shift+L` |
| Column cursors above / below | `Ctrl+Alt+↑` / `↓` (also `Ctrl+Alt+K` / `J`) |
| Cursor at mouse click | `Alt+click` |
| Box selection (column) | `Shift+Alt+drag` |
| Collapse to single cursor | `Esc` |

All cursors apply edits in parallel — type and every cursor inserts, `Backspace` and every cursor deletes.

### Debugging

Standard VS Code keys all work; see [LSP](/manual/lsp/) for the language-server side.

| VS Code | mnml |
|---|---|
| `F5` start / continue | `F5` continue (run) |
| `Shift+F5` stop / step-out-of-continue | `Shift+F5` continue (no separate stop) |
| `F9` toggle breakpoint | `F9` |
| `Shift+F9` conditional breakpoint | `Shift+F9` |
| `F10` step over | `F10` |
| `F11` step into | `F11` |
| `Shift+F11` step out | `Shift+F11` |

### Terminal

| VS Code | mnml |
|---|---|
| `Ctrl+`backtick`` open terminal | `Ctrl+`backtick`` (also `Ctrl+\`) — scratch terminal toggle |
| `Ctrl+T` (not bound by default) | `Ctrl+T` opens / focuses a shell pane |

`Ctrl+J` expands a snippet at the cursor (the snippet-expand chord; VS Code uses `Tab` after typing a snippet trigger, mnml also accepts `Tab` from the completion popup but `Ctrl+J` is the explicit chord).

### Window / navigation

| VS Code | mnml |
|---|---|
| `Ctrl+Shift+Z` zen mode | `Ctrl+Shift+Z` zen mode (full-screen single buffer) |
| `Alt+←` / `Alt+→` go-back / go-forward | `Alt+←` / `Alt+→` (mnml navigation history) |
| `Ctrl+L` (terminal clear) | `Ctrl+L` is SelectLine in editor — for terminal-clear, use a shell pane (Ctrl+L is forwarded) |
| `Ctrl+Q` quit | `Ctrl+Q` |

### Hover tooltips (everywhere)

Hover any tree-rail integration chip, any statusline chip (workspace, branch, mixr now-playing, …), any tab badge, any gutter column — a tooltip explains what you're looking at and its current state. Move the cursor off and the tooltip dismisses. Move to another chip and it swaps cleanly (no stale tooltip overlap).

## The leader chord (optional but useful)

mnml's vim mode has a leader trie under `<space>`. In standard mode the entry chord is `Ctrl+K`. The trie is the same — same continuations, same commands. Press `Ctrl+K`, then the next key paints a which-key popup. Try:

- `Ctrl+K p` → command palette (same as `Ctrl+Shift+P`)
- `Ctrl+K g s` → git status / staging pane
- `Ctrl+K l d` → goto definition (LSP)
- `Ctrl+K a c` → open Claude Code
- `Ctrl+K ?` → cheatsheet pane (every chord, searchable)

You can ignore the leader entirely if it doesn't fit how you think — every leader action has a palette command and a chord. But it's there as a discoverable "rich menu" that most VS Code users haven't met.

The full leader map is documented on [Coming from NvChad](/manual/coming-from-nvchad/) — same trie, same content.

## Differences worth knowing

Honest list of places where VS Code muscle memory doesn't translate cleanly.

### `Ctrl+\` opens a terminal, not a split

VS Code uses `Ctrl+\` to split the active editor. mnml uses it (alongside ``Ctrl+`backtick``) to toggle a scratch terminal pane. If you want to split: `Ctrl-W v` (vertical) or `Ctrl-W s` (horizontal); both work from standard mode. The terminal split chord may be remappable in a future config refinement.

### `Shift+Alt+↓` duplicate line — use `Ctrl+Shift+D`

`Shift+Alt+↓` isn't currently bound; `Ctrl+Shift+D` is mnml's duplicate-line. The legacy `Alt+Down` is move-line-down (the more-common VS Code chord).

### No JSON settings — TOML instead

`Ctrl+,` opens a [settings overlay](/manual/settings/) (a sectioned keyboard-driven list, not a JSON file). The on-disk source of truth is TOML at `~/.config/mnml/config.toml`. You can edit either; both ends up at the same state.

A per-workspace overlay at `<workspace>/.mnml/config.toml` is the equivalent of VS Code's workspace settings.

### No extensions marketplace

mnml's plugin model is two parts: registered commands (built-in, in `src/command.rs`) and out-of-process **sibling binaries** hosted as panes via [blit-host](/manual/integrations/installing/). The `> INTEGRATIONS` section of the file tree shows installed siblings; click `+` to browse + install more. No marketplace, no signing, no auto-updates pushed at you. See [Installing integrations](/manual/integrations/installing/).

### Built-in things VS Code does via extensions

- **Git** — built-in. Status pane, diff pane, blame, commit graph, AI-generated commit messages. See [Git](/manual/git/).
- **HTTP client** — built-in `.http` / `.curl` / `.rest` files with `Send` chord. See [HTTP client](/manual/http/).
- **Test runner** — built-in via the test pane (palette: **test: run all** etc.).
- **AI** — built-in Claude Code + Claude chat + Codex panes. See [AI panes](/manual/ai-panes/).
- **Debugger (DAP)** — built-in, F5 / F9 / F10 / F11 work.
- **Browser via CDP** — `<leader>B` opens Chrome via the DevTools Protocol with a coupled live-preview pane.

You don't install REST Client, GitLens, GitHub Copilot, Thunder Client. They're all in the box.

### No tab pinning state via right-click

The right-click context menu on a tab covers Close, Close others, Close all. "Pin tab" isn't a state today — preview tabs (italic) become pinned (regular) on first edit, automatically. If you want to keep a file open without pinning, just don't edit it.

### Tree drag-and-drop reorders files? No

The tree is read-only-for-position. Right-click → rename to move a file. Drag-and-drop reorder for files isn't a feature.

### `Ctrl+K Ctrl+S` keyboard shortcuts UI? No

VS Code's keyboard-shortcuts editor doesn't exist. To see every chord, open the cheatsheet pane:

```vim
:cheatsheet
```

…or `Ctrl+K ?` (leader → ?), or palette → **view: cheatsheet (all chords)**.

To rebind, edit `[keys.global]` in `~/.config/mnml/config.toml`. The remapping surface is still under construction — built-in defaults cover the common chords, but a full `[keys.standard]` overlay isn't there yet.

### `Ctrl+S` on every pane

In VS Code, `Ctrl+S` saves the focused editor — and does nothing on most other surfaces. In mnml, `Ctrl+S` is an `App` command (not handler-level), so it fires from any pane that supports saving. From a non-saveable pane (git status, terminal, integration sibling) it no-ops silently.

## First-launch checklist

A 60-second path from "fresh install" to "I can work like I did in VS Code."

1. **Launch in your workspace** — no config needed; standard is the default:

   ```sh
   mnml ~/some/project
   ```

2. **Try `Ctrl+P`** — file picker opens. Type, Enter, file opens.

3. **Try `Ctrl+Shift+P`** — command palette. Type "settings", Enter, the settings overlay opens. (Or just hit `Ctrl+,`.)

4. **Try `Ctrl+B`** — toggle the file tree. Click around. Right-click for context menus.

5. **Hit `Ctrl+S`** to save anything you touched. The dirty dot on the tab clears.

You're in. Treat the leader chord (`Ctrl+K`) as a nice-to-have — your existing chord vocabulary covers the day-to-day.

## Next

- [Editing](/manual/editing/) — the architectural framing, the EditOp model, multi-cursor specifics
- [Settings & configuration](/manual/settings/) — TOML schema, the settings overlay, every config knob
- [LSP](/manual/lsp/) — language servers, completion, code actions, refactors
- [Git](/manual/git/) — built-in git surface (status, diff, blame, AI commits)
- [Coming from NvChad](/manual/coming-from-nvchad/) — the other half of the migration story, for vim teammates
- [Installing integrations](/manual/integrations/installing/) — adding sibling viewers (forge, AWS, observability)
