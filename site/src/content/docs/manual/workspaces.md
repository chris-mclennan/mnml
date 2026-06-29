---
title: Workspaces & the file rail
description: mnml's workspace model — the directory you launch with, the file-tree rail, sibling workspaces in `[[workspaces]]`, switching the active workspace, and the marker that lets `./run.sh restart` find your running instance.
---

mnml is *workspace-scoped*. Every long-lived piece of state — the file rail, discovered git repos, LSP roots, session restore, the IPC mailbox, per-file undo history, the gitignore-aware scan — anchors on one directory: the **workspace**. This page covers what counts as a workspace, how the left rail surfaces files, how to pin sibling workspaces alongside the launched one, and how the `./run.sh` wrapper tracks the running instance.

## What a workspace is

The workspace is the directory mnml opens. There are two ways to set it:

```bash
mnml                       # workspace = $PWD (where you ran the binary)
mnml ~/Projects/my-app     # workspace = ~/Projects/my-app (positional arg)
mnml --headless ~/repo     # same, with the headless frontend
```

The positional argument is just a path — it doesn't need to be a git repo, an existing file tree, or anything special. If the directory doesn't exist mnml refuses to start; otherwise the workspace is fixed for the life of that process.

`./run.sh` wraps this with the same shape:

```bash
./run.sh                   # workspace = the dir you ran ./run.sh from
./run.sh ~/Projects/notes  # workspace = ~/Projects/notes
```

The wrapper resolves the workspace to an absolute path before exec'ing `mnml`, so symlinks and `~` get normalised exactly once.

Once chosen, the workspace decides:

- **Where the file rail roots** — the top of the rail is `<workspace>`'s file list.
- **Where session state lives** — `<workspace>/.mnml/session.json` holds open buffers, pane layout, tab pages, marks, macros, and the per-row expand state of the rail.
- **Where the IPC mailbox lives** — `<workspace>/.mnml/ipc/` (see [Marker pattern](#the-marker-pattern) below).
- **Where the workspace-local config overlay lives** — `<workspace>/.mnml/config.toml` overlays your global `~/.config/mnml/config.toml`.
- **The git repo set** — mnml walks the workspace looking for `.git/` markers (capped at depth 3) on startup.
- **Default LSP roots** — workspace-relative paths and `root_markers` resolve against the workspace.

## The file rail

The left sidebar has two sections — **WORKSPACE** (the file tree) and **GIT** (branches, worktrees, open PRs). The whole rail is independently toggled by:

| Key | Action |
|---|---|
| `Ctrl+B` | Toggle rail visibility (the whole sidebar collapses) |
| `Ctrl+Shift+E` | Focus the file tree (VSCode convention — forces it visible if hidden) |

When focused, the rail navigates with `↑` / `↓` / `j` / `k`; `Enter` opens the selected row in a new editor pane; `Esc` returns focus to whatever pane you came from.

### What's shown — and what isn't

mnml's tree scan is **gitignore-aware**:

- Every `.gitignore` (including parent gitignores, `core.excludesFile`, and `.git/info/exclude`) is honoured. `target/`, `node_modules/`, `dist/`, etc. don't even appear in the listing.
- Dotfiles (`.git/`, `.env`, `.editorconfig`) are visible by default — toggle via `:view.toggle_hidden` (current section) or `:view.toggle_hidden_all` (every workspace section).
- The cap is **50,000 entries** — past that, the scan stops and a toast hints to narrow the workspace.

Gitignore is enforced even when the workspace isn't a git repo (a `.gitignore` at the root is still read). That keeps the rail useful in directories you haven't `git init`'d yet.

### Type-to-filter

Start typing while the tree is focused and you enter **filter mode** — a single-line input opens just under the workspace header, and the tree narrows to entries whose filename fuzzy-matches what you typed. Ancestor directories of every match are auto-expanded so the hierarchy stays readable.

| Key | Action |
|---|---|
| `/` (vim) or just typing (standard) | Enter filter mode |
| any character | Append to the filter |
| `Backspace` | Drop the last character |
| `Esc` | Exit filter mode (the filter sticks; clear it with empty input + `Esc`) |
| `Enter` | Open the focused match |

The filter is *sticky* — exiting filter mode keeps the current filter applied to the tree until you re-enter and clear it. The filter input itself shows the current value below the section header, with a `█` cursor when you're typing.

### Single-click to open

Click any file row to open it in the focused editor pane. Click a directory row to expand / collapse it. Right-click any row for the context menu (open in split, copy path, reveal in terminal, add to `.gitignore`, …). The rail dividers are drag-resizable — grab the right edge and pull to set `tree_width`.

### Expand / collapse chips

Each workspace header has a small chip cluster on the right edge:

- **Refresh** — re-scan the workspace (after an external `git clean`, a clone into the workspace, etc.).
- **Collapse-all / Expand-all** — flips the icon based on the current state. `tree.toggle_collapse_all` from the palette does the same thing.
- **Hidden files toggle** — flip dotfile visibility for this workspace.
- **+ repo** — add a workspace at runtime (see [Sibling workspaces](#sibling-workspaces) below).

## Sibling workspaces

A workspace can have *additional* directories pinned alongside it in the rail. Useful when you're working on a multi-repo project — say `mnml` + `mixr-rs` + `fim-engine` — and want one mnml window with three collapsible workspace sections instead of three separate launches.

Add them via `[[workspaces]]` in the workspace-local config:

```toml
# <workspace>/.mnml/config.toml
[[workspaces]]
name = "mixr-rs"
path = "~/Projects/mixr-rs"

[[workspaces]]
path = "~/Projects/fim-engine"     # name defaults to "fim-engine" (basename)
```

- `~` is expanded at config-load time.
- `name` defaults to the path's basename when omitted.
- Entries **append** across config files — a workspace-local file extends the global set rather than replacing it.
- Missing directories are tolerated — mnml logs them and skips, rather than failing to start.

Each entry renders as its own collapsible section in the rail below the launched workspace, with its own file tree, gitignore scan, expand state, and right-edge chip cluster. Click any file in any section to open it — the editor pane doesn't care which workspace the file came from.

### `Ctrl+P` workspace affinity

The fuzzy file picker (`Ctrl+P`, palette **Open file**) draws from three sources: the **current workspace's tree**, recently-opened files in the **current workspace**, and recently-opened files in **other workspaces** (so you can jump cross-project). Each item carries a `priority` field so the ranker doesn't accidentally promote a short cross-workspace label above a longer current-workspace path:

| Source | `PickerItem.priority` |
|---|---|
| Current-workspace recent file | `2` |
| Current-workspace tree entry | `2` |
| Cross-workspace recent file (from a sibling `[[workspaces]]` entry, or a file you opened before switching) | `1` |
| Extra-workspace tree entry (the file isn't in the current workspace's tree, but is in one of its siblings') | `0` |

`Picker::refilter` sorts by `(priority desc, fuzzy_score desc, index asc)` — priority wins **regardless of score**, score wins ties, original index breaks remaining ties. So typing `lib` in a workspace that contains `src/lib.rs` always surfaces `src/lib.rs` first even if a cross-workspace recent has the shorter (higher-scoring) bare-`lib.rs` label.

The picker also filters noise paths (`.git`, `node_modules`, `target`, `.next`, `dist`, `build`) at every source, matching VS Code's default `files.exclude`. Cross-workspace items render with their absolute parent directory as the detail line, so you can still tell **which** project a same-named file came from.

To add a workspace ad-hoc (not persisted):

- **`view.add_workspace`** — opens a prompt for a path; the entry vanishes on quit.
- Or set the `+` chip in any workspace header.

To remove an extras entry at runtime: `view.remove_workspace` (the primary workspace can't be removed — it's the launched root).

## `view.switch_workspace` — flipping the active workspace

Sibling workspaces are visible all the time, but only **one** workspace is *active* at any moment. The active workspace is what context-sensitive commands anchor on:

- `term.shell` uses it as the new pty's `cwd`.
- `:!cmd` runs the shell command against it.
- The workspace grep (`Ctrl+Shift+F`) roots there.
- The GIT rail section follows it (so the branch list, gutter, and commit graph all retarget at once).
- LSP roots resolve against it.

Switch with:

| Command | Action |
|---|---|
| `view.switch_workspace` | Open a picker of every workspace (primary + extras); accept ⇒ activate |
| Click a workspace's header in the rail | Same effect — that workspace becomes active |

What "activate" actually does: it expands the chosen workspace's section, collapses the others to header-only rows, focuses the rail on it, and points the git surface at whichever discovered repo lives there. The session restore still anchors on the launched primary; you don't have to worry about losing your tab layout by switching.

Most multi-repo workflows: leave one workspace active most of the time, click another's header when you need to scroll through its files, switch back when you're done. The picker is handy when you have more than a handful pinned and want fuzzy search instead of clicking around.

## The marker pattern

mnml stores enough state in a workspace's directory that one machine can run multiple mnml instances against different workspaces without conflicting. But the `./run.sh` wrapper needs to know which one is "the running one" so `./run.sh restart` and `./run.sh stop` target it.

That's the marker:

```text
$TMPDIR/mnml-running-$USER.workspace
```

Contents: a single line — the absolute path of the running mnml's workspace. Each `./run.sh` launch overwrites the marker with its own workspace, then `trap`s an `EXIT` handler to delete the marker on shutdown. A second `./run.sh` invocation overwrites; the most-recent launch wins.

The marker drives three operations:

```bash
./run.sh restart    # reads MARKER, writes {"cmd":"restart"} to <ws>/.mnml/ipc/command
./run.sh stop       # reads MARKER, writes {"cmd":"quit"}
./run.sh status     # prints the marker contents + whether the IPC dir exists
```

Internals: `./run.sh restart` appends a JSON command to the file-IPC mailbox at `<workspace>/.mnml/ipc/command`. mnml polls that file every tick; when it sees `{"cmd":"restart"}` it exits with status 75, which `./run.sh`'s outer loop interprets as "rebuild + relaunch" (any other exit status just terminates the loop). `{"cmd":"quit"}` exits cleanly.

The hook in `.claude/settings.json` calls `./run.sh restart` automatically after a successful `cargo build` so Claude-driven edits land in the running instance without you having to switch terminals. A failed build skips the restart — you don't want a broken binary in the loop.

If the marker is missing (no `./run.sh` ever ran, or the launching shell exited uncleanly), `./run.sh restart` / `stop` say so and exit non-zero rather than guessing. You can rebuild the marker by re-launching with `./run.sh`.

## Headless mode

The same workspace machinery works without a UI:

```bash
mnml --headless ~/repo            # rare; usually via ./run.sh
./run.sh headless ~/repo          # same, with the build + restart loop
```

Headless mode renders into a virtual `TestBackend` (ratatui's in-memory terminal) instead of crossterm, and is driven entirely by the file-IPC mailbox under `<workspace>/.mnml/ipc/`:

- `command` (JSONL, host → mnml) — input commands.
- `screen.txt` (mnml → host) — the rendered virtual screen dumped every tick.
- `status.json` (mnml → host) — focus / mode / cursor / dirty-buffer state.
- `events.jsonl` (mnml → host) — startup, file opens, command results.

Same `App`, same `ui::draw`, same `tui::dispatch_*` — the headless frontend just swaps the terminal backend and the input source. Useful for the planned `.test` E2E format, for headless smoke tests in CI, and for driving mnml from a sibling agent (see the `smoke` skill in `.claude/`).

The marker, `[[workspaces]]` config, sibling workspaces, and `view.switch_workspace` all behave identically in headless — there's no "this works only with a UI" surface.

## What's safe vs what's gated

- **Always safe (read-only):** every workspace scan, gitignore read, expand-state lookup. The scan caps at 50k entries; over that it stops.
- **One-key writes:** `view.add_workspace` / `view.remove_workspace` (extras only — never the primary), `view.switch_workspace`, `view.toggle_hidden`.
- **Workspace-local config edits:** require editing `<workspace>/.mnml/config.toml` manually; the settings overlay doesn't touch `[[workspaces]]`.
- **Not exposed:** mnml never `rm`'s files via the rail UI; deletion goes through the context menu's typed-confirm prompt.

## Next

- [Settings & configuration](/manual/settings/) — the full `[[workspaces]]` schema, plus every `[ui]` knob that affects the rail
- [Git](/manual/git/) — multi-repo workspaces and the GIT rail section
- [Editing](/manual/editing/) — buffer state per workspace, session restore
- [LSP](/manual/lsp/) — workspace-rooted servers and `root_markers`
