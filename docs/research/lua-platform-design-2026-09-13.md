# Lua as a platform others write for — design for review

*2026-09-13 · a paper design; nothing here is built. The user's brief: "polish it
and do what we can with it so when people start to use it they can feel how well
thought out it is." Not Neovim compatibility — something of our own that gets
people the same results.*

## What stays, because it is already the good part

- **One edit chokepoint.** `mnml.buf.apply` is the only way a script changes
  text, and it goes through the same `EditOp`s the keys produce. Undo,
  dot-repeat, LSP `didChange` and the reparse all see it. Every new text
  facility below routes through it.
- **Roles, never colours.** A script names `accent`, `error`, `syn_string`;
  the theme paints. Decorations below use the same roles.
- **The budget.** 20 ms per entry, checked every 100 000 instructions; a
  runaway script costs one toast. A script from a stranger is safe to install
  because of this, and no other editor has it. It stays exactly as is.
- **Trust.** A workspace `init.lua` is an exec-bearing claim in the trust
  dialog. Installed scripts (below) are claims of the same kind.
- **One file, no `require`.** Kept for `init.lua`. An *installed script* is a
  directory, and gets a scoped `require` for its own files only (§3).

## 1. The six shapes a plugin takes, and what each still needs

| shape | today | gap |
|---|---|---|
| a picker over something | `picker.source{ items = fn(query) }`, runs once on open | a **live source**: `items` re-run as the query changes (debounced), `on_accept` with the row table, multi-select, a `preview(row)` returning rows for the picker's preview column |
| a pane that shows something | `pane.open{ render, on_hit, on_key }`, styled segments, hits, wheel | a **scrollable list helper** (cursor, selection, `j`/`k`/Enter for free), `on_resize`, `pane.title(id, text)`, `pane.focus(id)`, placement (`right`/`below`/`tab`) |
| decorations in the editor | none | **the biggest gap — §2** |
| a text operation | `buf.apply` with 131 ops, `atomic` | `buf.selection()` (range + mode), `buf.range(start, end)` text, `buf.word_at(byte)`, and an **operator** registration so `<leader>x{motion}` works in vim mode |
| a tool wrapper | `task.run{ cmd, on_done }` in a task pane | **streaming**: `on_line(text)` as output arrives; `hidden = true` for tools whose output is only parsed; a **diagnostics sink** — §2 |
| a statusline chip / a key | `statusline.segment`, `map`, `command` | a segment `on_click`; `command{ when = fn }` for context-sensitive enabling; that is all |

## 2. Decorations and diagnostics — the core work

Everything visible a plugin adds to the editor is one of four decorations.
They live in a **namespace** the script owns, so it can clear its own without
touching anyone else's, and they attach to **positions that follow edits**
(anchored to the text through the same marks the editor's own change list
uses — never to line numbers a later edit would shift).

```lua
local ns = mnml.decor.namespace("blame")            -- one per script concern
mnml.decor.virtual_text(ns, pane, line, { { "  chris · 3d ago", fg = "muted" } }, { at = "eol" | "above" | "below" })
mnml.decor.gutter(ns, pane, line, "▎", { fg = "accent" })    -- the sign column; one cell
mnml.decor.highlight(ns, pane, start_byte, end_byte, "match")  -- a role over a range
mnml.decor.line(ns, pane, line, "cursor_line")                 -- a whole-row ground
mnml.decor.clear(ns, pane?)                                    -- all of the namespace's, or one pane's
```

Rules: a decoration is data the renderer reads, never a callback per frame
(the budget cannot be spent in the paint loop); a namespace is dropped with
the script on `script.reload`; the sign column is shared with the debugger's
breakpoints and git's change marks, so a gutter mark declares a **priority**
and the highest wins the cell.

**Diagnostics as a sink.** A tool wrapper publishes the way a language
server does, and the editor treats it identically — the gutter, the
underline, the statusline count, the DIAGNOSTICS panel, `]d`:

```lua
mnml.diagnostics.set(ns, path, {
  { line = 12, col = 5, end_col = 9, severity = "warning", message = "unused", source = "eslint" },
})
mnml.diagnostics.clear(ns, path?)
```

## 3. Installed scripts — the part that makes it "others can write for"

A script is a directory:

```
~/.config/mnml/scripts/<name>/
  script.zon        -- name, version, api = 1, description, author, commands it adds, hooks it uses
  init.lua          -- the entry; may `require("lib.thing")` → <name>/lib/thing.lua ONLY
  README.md
```

- **Install** from a path, a git URL or an archive: `script.install <src>`;
  lands in the SCRIPTS panel with enable / disable / update / remove and a
  row per registered command. The manifest's `hooks` and `commands` are shown
  BEFORE the first run, in the trust dialog, as the claim the user accepts.
- **Isolation**: each installed script gets its own Lua state (its own
  budget clock, its own namespaces, its own `require` root). A crash in one
  is one toast and one disabled row, never the others.
- **`api = 1`** in the manifest is the contract: the `mnml` table documented
  in `docs/LUA.md` for that version. We freeze `1` the day we publish it and
  add, never change, until a `2`.
- **Workspace scripts** stay as today: `.mnml/init.lua`, trusted per
  workspace, one file.

## 4. The examples that ship (and are the acceptance tests)

Five scripts under `docs/examples/scripts/`, one per shape, each under 80
lines, each with a `.test` that drives it:

1. `git-blame-line` — decorations + a task: virtual text at eol for the
   cursor line, refreshed on `pane_focus` and cursor idle.
2. `eslint` — a tool wrapper: `task.run{ hidden, on_line }` → the
   diagnostics sink, on `save_post` for `.js`/`.ts`.
3. `recent-commands` — a live picker source over the command MRU with a
   preview column showing the command's chords.
4. `todo-list` — a scrollable list pane built on the list helper: `grep`
   through a task, Enter opens the file at the line.
5. `surround-word` — a text operation registered as an operator: works with
   any motion in vim mode, with a selection in standard mode, one undo step.

If one of these cannot be written in under 80 clean lines, the API is wrong,
not the example.

## 5. Polish that makes it feel deliberate

- `docs/LUA.md` becomes a reference with one runnable example per function
  and a "recipes" chapter that IS the five scripts.
- `mnml.inspect(v)` for debugging; `print` already toasts — keep both.
- Error messages name the argument and show the accepted shape (`picker.source: items must be a function(query) returning a table of rows`).
- `script.doctor`: lists every script, its api version, budget hits in this
  session, hook subscriptions, and namespaces with live decoration counts.
- The SCRIPTS panel shows budget overruns as a chip so a slow script is
  visible before it is annoying.

## 6. What stays deliberately out

- No Neovim API shim, no LuaJIT, no `ffi`. A separate decision, already made.
- No network or raw file system from Lua — `task.run` is the door, and it
  is visible in a task pane or declared `hidden` in the manifest.
- No per-frame callbacks for decorations; no timers. Idle hooks
  (`cursor_idle`, `buffer_change`) cover the real cases.
- No colour values. Roles only.

## 7. Sequence and size

1. **Decorations + diagnostics sink** (L): the render path and the editor
   core; the anchoring marks; the sign-column priority. Everything visible
   depends on it. Land with example 1 and 2.
2. **Live picker source + list-pane helper + buffer/operator additions** (M):
   land with examples 3, 4, 5.
3. **Installed scripts**: manifest, per-script state, scoped `require`,
   install/enable/update in the SCRIPTS panel, the trust claim (M).
4. **Polish**: docs rewrite, `script.doctor`, error messages, the chip (S).

Each step is one worktree, one agent, and its examples' `.test` files are the
acceptance. `api = 1` freezes at the end of step 3.

## Decisions (the user, 2026-09-13)

1. **Rail sections: both.** A script may open a pane (the common case) or
   register a rail section. A section is a `ListPanel` the script feeds rows
   to — the same `list` helper as the pane variant, hosted in the sidebar with
   the caps header, filter, sort chip and fold behaviour every built-in
   section has, so a script section is indistinguishable from TODOS. The
   activity-bar glyph and position come from the manifest. Sections land in
   step 2 with the list helper; the pane form first.
2. **Distribution reuses the integrations model** — installed / marketplace /
   dev, exactly as the INTEGRATIONS section has them:
   - **Marketplace** = the curated official set (a `mnml-scripts` repo we
     maintain, mirrored the way the integrations marketplace is). Rows show
     name, description, api version, the manifest's hook and command claims.
   - **Community** = any git URL or archive, installed by hand, shown under
     its own heading with a "community" badge. Same trust dialog, same claims.
   - **Private** = scripts from a source the user configures (a company repo,
     a path), like the private integrations an employer installs from outside.
   - One code path: a script is a directory with `script.zon`; where it came
     from is a field on the row and a filter in the panel. The SCRIPTS panel
     gains the three tabs the INTEGRATIONS panel has (installed · marketplace
     · dev), and `dev` is a workspace path being edited live with save-reloads.
3. **No freeze period.** `api = 1` is written into the manifest from day one
   and may still change until we say otherwise; the doc carries a "changed
   in" line per function. Freezing is a later, one-line decision.

## Open questions (none blocking)

- The marketplace's index format — reuse the integrations index schema as
  is, or a sibling schema? Default: reuse, with a `kind = script` field.
