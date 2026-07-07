---
title: File actions & tree up-navigation
description: mnml's file-manager surface — cut / copy / paste / duplicate / move-to on the file rail, Alt-drag to copy, and the `..` up-navigation row that climbs the workspace root one directory at a time.
---

Everything you'd expect from a file manager, wired straight into the file rail: cut, copy, paste, duplicate, move-to. Plus tree drag-and-drop with an Alt-modifier for copy, and a `..` row at the top of the tree that walks the workspace root up one directory.

None of it requires opening a shell. The clipboard is a `Vec<PathBuf>` on `App` — single-path today, multi-select ready for the future — so a copy stays sticky and can paste into several destinations in one go, while a cut clears itself after the first paste (that's what "move" means).

## The five actions

| Action | Palette | Chord (tree focus) | Semantics |
|---|---|---|---|
| **Cut** | `file.cut` | `Ctrl+X` | Stage the selected file for a subsequent `paste = move` |
| **Copy** | `file.copy` | `Ctrl+C` | Stage the selected file for a subsequent `paste = duplicate` |
| **Paste** | `file.paste` | `Ctrl+V` | Drop the clipboard into the selected row's directory |
| **Duplicate** | `file.duplicate` | `Ctrl+D` | Create `name-copy.ext` in place, collision-safe up to `-copy-999` |
| **Move to…** | `file.move_to` | — | Prompt for a destination directory (tilde expansion, workspace-relative or absolute) |

The `Ctrl+X` / `Ctrl+C` / `Ctrl+V` / `Ctrl+D` chords only fire when **the tree is focused**. Tree focus never edits text, so these don't fight standard-mode's Ctrl+X (cut in editor) or Ctrl+C (copy in editor) — those chords still work inside a buffer.

All five actions also appear on the tree row's right-click menu (see [Right-click menu](#right-click-menu) below).

## Cut + paste = move

Cut a file and its path lands on `file_clipboard` with the `cut = true` flag. The next paste calls `std::fs::rename` from the source to `<target-dir>/<source-name>`, then **clears the clipboard**:

```
select users.rs
Ctrl+X            → toast: "cut users.rs"
select tests/
Ctrl+V            → toast: "moved 1 item into tests"
                    (clipboard now empty)
```

A cut followed by a paste into the source's own directory is a no-op — no self-clobber, no error, no toast.

Open editors pointed at the moved file automatically re-point to the new path. The tree refreshes; git status re-reads.

## Copy + paste = duplicate

Copy a file (or directory) and its path lands on `file_clipboard` with `cut = false`. The next paste calls `copy_recursively` — `std::fs::copy` for files, a walk for directories — and **keeps the clipboard sticky** so the same set can paste into several destinations:

```
select src/                    ← a whole directory
Ctrl+C                         → toast: "copied src"
select ../mnml-copy/
Ctrl+V                         → recursive fs::copy into ../mnml-copy/src/
select ../mnml-backup/
Ctrl+V                         → same set copies again into ../mnml-backup/src/
                                (clipboard still holds src/)
```

On Unix, **symlinks are preserved** — `symlink_metadata` detects them and the copy path emits `std::os::unix::fs::symlink(target, dst)` instead of copying the linked file's contents. Windows returns an error explaining the platform gap; a v2 pass may add a `--follow` toggle.

### Same-directory copy-paste = auto-bump

Pasting a copy into the source's own directory would otherwise clobber the source. Instead mnml bumps the destination name:

```
select users.rs
Ctrl+C
Ctrl+V (with users.rs still selected)
                  → creates users-copy.rs (not users.rs → users.rs)
Ctrl+V again      → creates users-copy-2.rs
Ctrl+V again      → creates users-copy-3.rs
                    …
                  → creates users-copy-999.rs
                  → after that, falls back to users-copy-lots.rs
```

The suffix rule (`-copy`, then `-copy-2`, `-copy-3`, …) is the same `collision_free_copy_name` helper `file.duplicate` uses.

### Existing target = skip

Pasting into a foreign directory where a same-named file already lives skips that item and toasts `already exists: <rel>`. Other items in a multi-path clipboard still paste.

## Duplicate in place

`Ctrl+D` (or `:file.duplicate`) creates a copy of the selected file *right next to it* in the same directory, using the same `-copy` / `-copy-N` suffix rule:

```
select users.rs
Ctrl+D            → creates users-copy.rs
Ctrl+D again      → creates users-copy-2.rs
```

Works on directories too — the whole tree gets duplicated recursively with the parent named `<name>-copy` / `<name>-copy-N`. Toast reads `duplicated <src> → <dest>`.

## Move to…

`file.move_to` opens a **destination directory prompt** seeded with the selected file's current parent:

```
┌── Move src/users.rs to… ──────────────────────────────────┐
│  src/                                                     │
│                                                           │
│    src/api/                                               │
│    src/handlers/                                          │
│    tests/                                                 │
└───────────────────────────────────────────────────────────┘
```

Path completion uses the standard prompt autocomplete (workspace-relative, absolute, or tilde-prefixed). Enter runs the move; the destination directory is `mkdir -p`'d if missing. Same guards apply: same source-and-destination toasts as a no-op, existing target refuses to overwrite.

The destination-existence check is strict — mnml won't clobber. Rename the destination first if you want to replace.

## Right-click menu

Right-click any tree row for a context menu with the file actions inline:

```
┌── users.rs ────────────────────┐
│  Cut                           │
│  Copy                          │
│  Paste here                    │ ← only shown when clipboard non-empty
│  Duplicate                     │
│  Move to…                      │
│  Rename…                       │
│  Delete…                       │
│  Reveal in Finder              │
│  Open externally               │
│  Copy path                     │
└────────────────────────────────┘
```

**Paste here** only renders when `file_clipboard` is non-empty — so the menu doesn't dangle a no-op action when there's nothing staged.

The menu works from tree focus **and** from the palette bar's context menu; `Shift+F10` opens the same menu from the focused row without a mouse.

## Tree drag-and-drop

Drag any tree row onto a **directory row** to move it. The drop fires a confirmation prompt:

```
Move src/users.rs to tests/?
   [ Move ]  [ Cancel ]
```

`[ Move ]` is focused by default — the drag was intentional, so the affirmative answer is what the user meant. `Esc` or `[ Cancel ]` aborts without touching the filesystem.

### Alt-drag = copy

Hold `Alt` while starting the drag to copy instead. **Alt-drag fires immediately without confirmation** — because copy is non-destructive, and this is the Finder / VS Code convention:

```
Alt-hold + drag src/users.rs onto tests/
    → fs::copy(src, tests/users.rs)
    → toast: "copied → tests/users.rs"
    (no prompt, no undo — src stays where it was)
```

The `Alt` modifier is captured at drag-start (mouse-down) and preserved through the drop — releasing Alt mid-drag doesn't flip the operation back to move. If you started an Alt-drag by mistake, the source file is untouched, so worst case you delete the just-copied destination.

Dropping onto a **file** row (rather than a directory) is a no-op — mnml doesn't guess at "put it next to this file" semantics.

## The `..` up-navigation row

At the very top of the file tree, above the workspace name row, mnml paints a `..` row when the workspace has a parent directory:

```
  .. Projects              ← click to climb to ~/Projects
▾ MY-WORKSPACE
    src/
    tests/
    Cargo.toml
```

The row shows `..` followed by the parent directory's basename (dimmed) so you know what you're climbing into before you click. It's hidden entirely when:

- The workspace is at the filesystem root (`/`) — nothing to climb into.
- The workspace is the empty-state splash (its layout owns the whole rail rect).

### Click behavior

Click the `..` row and mnml calls `set_workspace_to(<parent>)` — the same code path `promote_to_primary_workspace` uses. That means:

- The tree reloads from the new root.
- The workspace-scoped repo scan re-runs (git repos, worktrees, PRs).
- Git status re-reads for the new root.
- The integrations rail re-scans in the new context.
- LSP roots pointed at the previous workspace close.
- The palette bar's workspace chip updates.
- Session state (`.mnml/session.json`) starts writing to the new root.

In practical terms, it's the same effect as launching mnml with the parent as the workspace argument, but without restarting.

### Palette

| Surface | Call |
|---|---|
| Row click | `..` at the top of the tree |
| Ex-command | `:view.workspace_up` |
| Palette | `view: Navigate the workspace root up one level (..)` |

Useful when you launched into `~/Projects/mnml` and realise you actually want `~/Projects` visible with mnml *and* mixr side by side — one click, no reboot.

At filesystem root the palette command toasts `already at filesystem root` and the row is hidden entirely.

## Clipboard state model

The clipboard is minimal by design:

```rust
pub file_clipboard: Vec<PathBuf>,
pub file_clipboard_cut: bool,
```

- **v1** stages a single path per action — future multi-select on the tree flips this to a `Vec`.
- `file_clipboard_cut` distinguishes cut (move on paste) from copy (duplicate on paste).
- Cut clears itself on paste; copy sticks.
- The clipboard is **process-scoped** — it doesn't survive an mnml restart, and it doesn't cross into the OS clipboard (that would clobber your text clipboard).

Nothing about this state is written to disk — a session restore starts with an empty clipboard, which is the safe default. A crash mid-move can't leave the clipboard in a stale state that later pastes into the wrong place.

## Interaction with other tree flows

- **Rename** and **Delete** live on the same right-click menu as the file actions and dispatch through the same `MenuAction` handler. Rename inline; delete opens the button-dialog confirm.
- **New file / New folder** appear on the directory context menu (right-click a folder to see them). They pre-seed the prompt with the target directory's path.
- **Reveal in Finder** / **Open externally** / **Copy path** — the OS integration trio, unchanged by the file actions work.

## Quick reference

| Task | Chord (tree focus) | Palette | Right-click |
|---|---|---|---|
| Cut | `Ctrl+X` | `file.cut` | Cut |
| Copy | `Ctrl+C` | `file.copy` | Copy |
| Paste | `Ctrl+V` | `file.paste` | Paste here |
| Duplicate in place | `Ctrl+D` | `file.duplicate` | Duplicate |
| Move to a chosen folder | — | `file.move_to` | Move to… |
| Drag to move | drag onto folder | — | — |
| Drag to copy | `Alt` + drag onto folder | — | — |
| Climb workspace root | click `..` row | `view.workspace_up` | — |

## Next

- [Workspaces & the file rail](/manual/workspaces/) — the workspace model, `[[workspaces]]` siblings, `set_workspace_to` semantics
- [Activity bar](/manual/activity-bar/) — the vscode-style rail the file tree lives in
- [Editing](/manual/editing/) — how the tree interacts with the two input modes when a file opens into an editor pane
- [Statusline, gutter & F1 help](/manual/statusline-chrome/) — the palette-bar workspace chip that reflects `..` climbs
