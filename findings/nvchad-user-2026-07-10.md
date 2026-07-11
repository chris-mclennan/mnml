# NvChad-user hunt — 2026-07-10 session

## Executive summary

**SEV-1: 1 · SEV-2: 3 · SEV-3: 1**

The `/`-filter absorb-block hoist landed cleanly (the seven flags
gated on `focus == Tree && section == X && picker/prompt/cmdline
none`, `set_activity_section` clears them all). `j`/`k`/`Enter`
row-nav is well-gated, no collision with vim `j`/`k` in the editor.
The bigger regression class this session is elsewhere — the
2026-07-06/07 "auto-route `.md` → MdPreview, `.http` → Request
pane" policy locks a vim user out of every ex command the moment
they land on one of those panes. Verdict: filter class fixed, but
a new class of "non-Editor pane traps vim keystrokes" got wider.

---

## [SEV-1] `:` on a Request pane silently mutates the URL — Enter fires the request

The Request pane's Edit-view `KeyCode::Char(c)` arm calls
`rp.type_char(c)` for every printable char that reaches focus,
and `KeyCode::Enter` on URL/Method calls `send_request_from_active`.
So a vim user who lands on `req.http`, thinks "I'll switch buffers",
and types `:bn<CR>` gets:

- URL rewritten to `https://httpbin.org/get:bn`
- A live 404 HTTP request fires (`✓ last: 404 (136 ms)`)
- `Esc` does not undo the URL edit; session-persistence keeps
  the mangled URL across relaunch

Same class: `/foo<CR>` types `/foo` and fires. `f`, `t`, `w`,
`b`, `d`, `y`, `p`, `x`, `u` all get typed literally. `Ctrl+W l`,
`gt`, `gg`, `G`, `<leader>…` all silently swallowed.

**Repro (fresh workspace with `req.http` = `GET https://httpbin.org/get`)**:
```jsonc
{"cmd":"open","path":"req.http"}
{"cmd":"wait_ms","ms":300}
{"cmd":"run-command","id":"view.focus_pane"}
{"cmd":"key","key":":"}
{"cmd":"type","text":"bn"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":1500}
{"cmd":"snapshot"}
```

Screen after: URL bar `https://httpbin.org/get:bn`, response
block `✓ last: 404 (136 ms)`.

**Expected**: `:bn` opens the ex cmdline (or a toast "no cmdline
on Request pane"); Enter certainly does not fire a network
request against a URL the user did not knowingly type.

**Actual**: URL corrupted + network side effect + `Esc` won't
revert.

**Source**: `src/tui/handlers/pane.rs:2710-2734` (Request Edit-
view Enter fires `send_request_from_active`; `Char(c)` calls
`rp.type_char(c)` unconditionally).

**Notes**: A vim user's most common ex prefix (`:`) becomes the
literal char `:` in the URL. Suggest gating URL edits behind an
explicit "enter edit mode" chord (e.g. `i`) or intercepting `:`
+ `/` when the URL bar has focus.

---

## [SEV-2] `.md` auto-preview traps vim keys — no chord path to raw editor

`open_path` (`src/app/layout.rs:367-369`) routes every `.md`
through `open_md_preview_for_path`, regardless of caller. The
MdPreview pane has `mode: "none"` and swallows every vim key:
`:`, `/`, `?`, `i`, `dd`, `:bn`, `:e file.txt`, `:q`, `:q!`,
`<leader>…` all inert. `Esc` from Welcome overlay drops focus
to Tree, so even opening a `.md` from an initial launch never
gets NORMAL mode.

The palette command `markdown.edit_raw` (`src/command.rs:2637`)
exists but has `keys: &[]` — the only keyboard reach is
`Ctrl+Shift+P` + fuzzy-search "markdown edit raw". No `<leader>`
chord, no whichkey entry, no `:` ex alias (vim `:` is dead on
the MdPreview pane anyway).

Also breaks the vim `:e <file>` mental model: from an editor
pane, `:e readme.md` swaps to preview (not raw edit). No vim
build of `:e! <path>` — `:e!` reloads the *current* file,
argument ignored (`src/app/ex_commands.rs:2438`).

**Repro**: `open readme.md`, `focus_pane`, `key i` / `key :` /
`type ":bn\n"` — all inert, `mode:"none"`, `activePane` unchanged.

**Expected**: at minimum, a documented chord (e.g. `<leader>me`)
to swap preview↔raw; ideally `:` on a MdPreview delegates to the
existing global ex cmdline so `:e`, `:bn`, `:q` still work.

**Actual**: MdPreview is a keyboard dead-zone for vim users.

**Notes**: Same class hits `.http` / `.curl` / `.rest`
(`src/app/layout.rs:377-382`) — see SEV-1 for the destructive
variant. `.md` isn't destructive but is a trap.

---

## [SEV-2] `?` includes `?` in the search pattern

`key ?` opens the Find modal with an empty pattern — good — but
subsequent `type "?lorem"` typed both the `?` and `lorem` into
the modal, so Enter searched for the literal string `?lorem`
(`no matches for "?lorem"` toast).

In vim, `?` opens a bottom-line reverse-search prompt where the
`?` is UI chrome, not part of the pattern. If a persona-tester
reflexively types `?pat<CR>` (the whole vim idiom), mnml
searches for `?pat`.

**Repro** (on `multi.txt` = `one lorem two\nlorem three\nfour lorem five`):
```jsonc
{"cmd":"key","key":"G"}
{"cmd":"type","text":"?lorem\n"}
```
Statusline: `no matches for "?lorem"`.

**Expected**: `?` opens a reverse-search prompt with `?` as
chrome; `?pat<CR>` searches for `pat` backward.

**Actual**: `?` opens a Find modal, `?` becomes character 1 of
the pattern.

**Source**: unknown — likely the `?` → `find.find` dispatcher
prepending `?` to the modal buffer.

---

## [SEV-2] Multi-cursor `i` acts as `c` — diverges from Neovim visual-multi convention

The `multi_cursor.test` locks in the current behavior: with two
selections held after `Ctrl+D`-style
`editor.add_cursor_at_next_word`, pressing `i` deletes each
selection and enters Insert. Typing `X` then Esc yields
`"X bar foo baXz foo"` from source `"foo bar foo baz foo"`.

In vim (and `mg979/vim-visual-multi`, the reference multi-cursor
plugin for NvChad), `i` on a visual/multi selection re-enters
Normal at anchor — no delete. `c` is the change verb. A vim user
who reflexively lower-cases into `i` after a `Ctrl+D` chain
loses each highlighted match instead of just planting an insert
cursor.

**Repro**:
```jsonc
{"cmd":"open","path":"rename.txt"}   // "foo bar foo baz foo\n"
{"cmd":"run-command","id":"view.focus_pane"}
{"cmd":"key","key":"gg"}
{"cmd":"key","key":"l"}
{"cmd":"run-command","id":"editor.add_cursor_at_next_word"}
{"cmd":"run-command","id":"editor.add_cursor_at_next_word"}
{"cmd":"key","key":"i"}
{"cmd":"type","text":"X"}
{"cmd":"key","key":"escape"}
{"cmd":"run-command","id":"file.save"}
```
File: `X bar foo baXz foo`

**Expected**: file unchanged; Insert cursors placed at each
selection's anchor.

**Actual**: each selection deleted, `X` inserted at each.

**Source**: `tests/e2e/multi_cursor.test:41-58` locks the
behavior in; the underlying dispatch treats `i` on selection as
`c`. Deliberate but non-canonical.

**Notes**: `vim-visual-multi` explicitly uses `c` for change
across all cursors; `i` inside multi-cursor visual mode drops
back to Normal without mutation. Recommend rebinding — or at
minimum documenting the divergence and gating on a config flag.

---

## [SEV-3] MdPreview Welcome-overlay Esc drops focus to Tree — vim user sees `mode:"none"` on the pane they just opened

Launching mnml → Welcome overlay → `Esc` → focus lands on Tree
even though a MdPreview pane is open. A vim user pressing `i`
to start editing sees no state change; there's no toast or
visual cue that focus is elsewhere. Consistent with existing
overlay-dismiss behavior, but combined with SEV-2 above it
compounds the "vim keys silently dead" impression.

**Repro**: launch on a workspace containing a `.md`, `open
readme.md`, `key escape`, `key i` — `status.json` shows
`focus:"tree"`, `mode:"none"`. Editor pane appears active but
isn't.

**Expected**: focus stays on the pane the user opened (or
Welcome-Esc restores prior focus).

**Actual**: focus resets to Tree on Welcome-overlay dismiss.

---

## Scenarios verified clean

- **SEV-2 filter absorb hoist (2026-07-09)**: `/scr` on Notes,
  `view.focus_pane`, `dd` on `file1.txt` → line deleted, filter
  chip unchanged. Confirmed on all 4 sections.
- **`j`/`k`/`Enter` row nav on TODOs / Notes / Sessions**:
  correctly gated behind `focus == Tree && !filter_focused &&
  picker/prompt/cmdline none`. No conflict with vim `j`/`k`
  inside editor panes.
- **8 new `ai.*_new_{left,right,top,bottom}` palette commands**:
  all `keys: &[]`, no chord surface, no collision with
  `<leader>a…` submenu (`src/command.rs:4863-4919`).
- **`/`, `*`, `n`, `N`, `:` on Editor panes** all reach the
  vim handler even after a filter section was `/`-focused
  earlier.
- **`Ctrl+B` / `Ctrl+Shift+P`** still work from Request and
  MdPreview panes (only global-chord escape hatches).

## Files touched
- `src/tui/handlers/pane.rs:2710-2734` — Request pane URL edit + Enter-fires-request path
- `src/app/layout.rs:355-382` — `.md` / `.http` auto-route
- `src/command.rs:2637-2654` — `markdown.edit_raw` (no chord)
- `src/tui/mod.rs:924-993` — j/k/Enter row nav gates
- `tests/e2e/multi_cursor.test:41-58` — locked-in `i`-as-`c` behavior
