---
title: Startup picker
description: The JetBrains-style workspace chooser that pops up when you launch mnml.app from Finder — pick a configured workspace, open a file, or skip into whatever directory mnml was launched at.
---

When you launch mnml from a terminal you already know which workspace you want — you typed it on the command line. When you launch it from Finder, or from a dock icon, there's no terminal context to type a workspace path. The OS just hands mnml `$HOME` and walks away.

The **startup picker** is the overlay that fills that gap. It's a small chooser that comes up on launch and lets you pick where to go before you see the editor.

```
┌─ Open mnml — Esc to skip ─────────────────────────┐
│                                                   │
│  Pick a workspace or action:                      │
│  ▸ [1] New file (in current workspace)            │
│    [2] Open file…                                 │
│    [3] Open folder…                               │
│    [4] Open: work                                 │
│    [5] Open: mnml-family                          │
│    [6] Open: notes                                │
│                                                   │
│  ↑↓ move · Enter select · Esc skip                │
│                                                   │
└───────────────────────────────────────────────────┘
```

## When the picker appears

mnml shows the picker when **either** of these is true on launch:

- The `--startup-picker` CLI flag was passed.
- The `MNML_STARTUP_PICKER` environment variable is set to `1`.

In every other case mnml goes straight to the editor with no overlay. The picker is opt-in — running `mnml` from a shell never shows it unless you ask.

### The Finder / dock path

The `mnml.app` and `mnml-nightly.app` launchers (the macOS bundles installed by the DMG, or built locally via `./scripts/build-app.sh`) open mnml in Terminal.app with `--startup-picker` set, so clicking the mnml icon in Finder, Spotlight, or the dock lands you on the picker rather than dropping you straight into `$HOME` with no idea what's around.

## Picker rows

The picker assembles its rows from three fixed actions plus your configured workspaces:

| Row | Source | What it does |
|---|---|---|
| `[1] New file (in current workspace)` | Always present | Dismisses the picker — you continue in whatever workspace mnml was launched at (usually `$HOME` from Finder). |
| `[2] Open file…` | Always present | Dismisses the picker and immediately fires `view.discovery` (the fuzzy file picker) so you can search any file in the current workspace. |
| `[3] Open folder…` | Always present | Dismisses the picker and fires `view.add_workspace` — the path prompt that canonicalizes a typed path (supports `~/`) and adds it as an extra workspace section in the file rail. |
| `[4]`…`[9]` | First 6 entries from your `[[workspaces]]` config | Switches the file-tree focus to that configured workspace. |

The picker shows at most **9 rows** (the keys `1`-`9` are the only direct-jump hotkeys), so only the first 6 entries from `[[workspaces]]` make it in (rows `1`-`3` are reserved for the fixed actions). The rest are still reachable later via `view.switch_workspace` and the rail headers — they just don't get a startup-picker row.

### Configuring the workspace rows

The picker reads `[[workspaces]]` from your normal mnml config (`~/.config/mnml/config.toml` or a per-workspace overlay):

```toml
[[workspaces]]
name = "work"
path = "~/Projects/work-stuff"

[[workspaces]]
name = "family"
path = "~/Projects/mnml-family"

[[workspaces]]
path = "~/Projects/notes"     # name defaults to "notes" (basename)
```

`name` is what shows in the picker row (`Open: work`). When omitted, mnml uses the path's basename. See [Workspaces & the file rail](/manual/workspaces/) for the full schema and how these entries integrate with the file-rail's sibling-workspace pattern.

## Keys

| Key | Action |
|---|---|
| `↑` / `↓` / `j` / `k` | Move the highlight (wraps top↔bottom) |
| `Enter` | Commit the focused row |
| `1`-`9` | Direct-jump — selects and commits in one keystroke |
| `Esc` / `q` | Skip the picker and continue at the launch workspace |

"Skip" and "[1] New file" land at the same place — they both leave you in whatever workspace mnml was launched at (the same place you'd be without the picker). The picker isn't a workspace-switcher gate; it's a chooser that defaults to "don't pick anything."

## What "skip" means in practice

When mnml is launched from Finder, the workspace `mnml` was started at is whatever directory macOS hands to the `.app` bundle — usually `$HOME` for stable mnml, or the cwd of the launching shell for nightly. Skipping the picker (Esc / q / Row 1) means you start in that directory: the file rail roots at `$HOME`, the IPC mailbox goes to `~/.mnml/ipc/`, etc.

If you want to switch to a different workspace from there, the file-rail's workspace headers and `view.switch_workspace` work the same as in any other mnml session. The picker is just a faster path to that switch on first launch.

## Empty workspace state

The picker is one half of the no-real-workspace experience. The other half is the **file rail's empty state**, which kicks in whenever mnml's workspace path (canonicalized) equals your `$HOME` — the exact situation you land in when Finder hands the `.app` bundle no folder argument.

Instead of trying to enumerate your entire home directory as if it were a project (which would dump `Documents/`, `Downloads/`, `Library/`, every dotfile, …), the workspace tree section paints a vscode-style panel:

```
> ~

   No workspace open

  ▸ Open file…
  ▸ Open folder…

   Press Esc here to skip.
```

The two `▸` rows are clickable — they're wired to the same commands as their picker counterparts:

| Row | Command | Effect |
|---|---|---|
| `▸ Open file…` | `view.discovery` | Opens the fuzzy file picker. |
| `▸ Open folder…` | `view.add_workspace` | Prompts for a folder path (supports `~/`) and adds it as an extra workspace section. |

### Predicate — when does it trigger?

The empty-state check is exact: mnml canonicalizes both its workspace path and `$HOME`, and compares them. If they match, you get the empty panel; if they differ by even one directory level, you get a normal file tree.

In practice:

- `cd ~ && mnml .` → empty state (workspace == `$HOME`).
- Clicking the mnml.app icon from Finder → empty state (Finder hands the bundle `$HOME`).
- `cd ~/Projects/mnml && mnml .` → normal tree (workspace == `~/Projects/mnml`, not `$HOME`).
- `mnml ~/Projects/mnml` from anywhere → normal tree.

If you ever see the empty state and didn't expect it, the fix is to `cd` into a real project root before launching mnml — or click `▸ Open folder…` to point mnml at one without restarting.

The rest of the rail (GIT section, INTEGRATIONS section, statusline) behaves normally in empty-workspace mode; only the workspace-tree slot swaps its contents.

## Source

The picker's state and key handling live in `src/app/startup_picker.rs`; the overlay drawing lives in `src/ui/startup_picker.rs`. The empty-workspace state predicate (`is_empty_workspace`) and panel painter (`draw_empty_workspace_state`) live in `src/ui/tree_view.rs`. All four modules are small and independent — adding more action rows is a matter of extending the `StartupPickerAction` enum or appending to the empty-state row list.

## Next

- [Workspaces & the file rail](/manual/workspaces/) — `[[workspaces]]` schema in depth, sibling workspaces, the marker pattern
- [Install](/install/) — the `.app` / DMG packages whose launchers trigger the picker
