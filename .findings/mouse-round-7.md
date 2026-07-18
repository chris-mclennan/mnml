# mnml mouse hunt — round 7 (2026-07-11)

Headless run against `~/Projects/mnml/target/release/mnml`, standard input,
workspace = a scratch `round7-ws` (git-init'd, `src/main.rs`, `docs/`,
`api.http` referencing `{{TOKEN}}` + `{{SECRET}}`, `.mnml/env/dev.env` with
`TOKEN=abc123`). Everything driven through file-IPC as a VS-Code-style
mouse-first user: `click` / `hover` / `drag` / `scroll` / `mouse_down`+
`mouse_up`. Keyboard used only for `escape` on wedged dialogs and to prove
that a feature is chord-only (each such case is logged as a SEV-2).

## Executive summary

**14 findings: 0 SEV-1 · 9 SEV-2 · 5 SEV-3.**

Mouse discoverability held up in the newly-shipped surfaces I was aimed at:
right-panel drag-resize is smooth and persists across restart, palette-bar
chips have decent tooltips, integration chip right-click gives a rich menu,
tree drag-drop + Alt-drag copy work, the `..` up-row and its tooltip both
work, external tool chips (btop) launch a Pty tab in one click, the HTTP
`[⇔]` chip + 1-cell divider + right-side tab strip all click through as
advertised, right-click on a `{{VAR}}` token surfaces Set value / Jump to
def / Copy name, and Alt-click multi-cursor really does place additional
cursors. **Could I get a day's work done without a chord? Mostly yes —**
the tree/tabs/splits/edit/HTTP loop is entirely mouse-reachable.

The remaining rough patches cluster around two areas.
**(1) The icon picker is effectively mouse-inaccessible** — you can *open*
the Edit dialog and *open* the picker (via `↵ actions`, which needs Enter),
but once inside the 10 000-glyph grid, click doesn't select a glyph, scroll
doesn't scroll the list, and there's no `×` to cancel. Enter/Esc/arrows
only.
**(2) The right-panel empty-state list ("Add a panel: ▸ Outline / Problems
/ AI chat / Grep / Tests") silently no-ops two of the five rows** —
Outline (without an active editor) and Tests both do nothing on click with
zero feedback. Problems, AI chat, and Grep work.

Plus one small consistency dent: right-click on the palette-bar chips
(sidebar/back/forward/search/dropdown/right-panel) produces no menu at all,
even though right-click on the neighbouring integration chip has a rich
one — feels broken by comparison.

---

## [SEV-2] Icon picker: no mouse path to select a glyph

**Reproduction** (workspace with any integration chip installed):
```jsonc
{"cmd":"click","col":1,"row":10}                     // Activity → Integrations
{"cmd":"click","col":10,"row":14,"button":"right"}   // right-click btop chip
{"cmd":"click","col":25,"row":20}                    // "Edit…"
{"cmd":"click","col":45,"row":18}                    // focus glyph row
{"cmd":"click","col":45,"row":18}                    // second click (double)
{"cmd":"click","col":45,"row":18}                    // third click (triple)
{"cmd":"click","col":45,"row":18,"button":"right"}   // right-click
{"cmd":"snapshot"}
```

**Expected**: any of double-click, right-click, or a visible button on the
glyph row opens the icon library picker.

**Actual**: none of the mouse gestures open the picker. The only way in is
`↵ Enter` on the focused row. Once the picker *is* open (by Enter):

- **Left-click on a glyph tile does not select it.** The rect
  `picker_item:N` is exported for each glyph, but a click just puts focus
  on the item; a second click doesn't confirm; there is no separate
  "Choose" button.
- **Scroll wheel over the grid does not scroll.** With 10 431 glyphs
  shown, that's the only reasonable way to browse; arrow keys are the
  only path.
- **There is no `×` / cancel button on the picker frame.** Esc is the
  only way to dismiss.

A mouse user cannot change an integration glyph. This surface is 100 %
keyboard-only end-to-end after the outer right-click menu.

**Impact**: the icon-picker feature ships as unreachable UX for
mouse-first users. `~70 glyphs` in the task brief actually rendered as
`10 431 shown` in the header, so the design assumption ("a small pickable
grid") no longer matches the data volume anyway.

**Source pointer**: `src/app/picker.rs` (icon picker rects + input
routing) — the `picker_item:N` rects are advertised on-screen but the
handler only fires on `Enter`, not on `MouseEventKind::Down(Left)`.

---

## [SEV-2] Right-panel empty-state row "Outline" silently no-ops when no editor is open, "Tests" silently no-ops always

**Reproduction**:
```jsonc
{"cmd":"click","col":82,"row":0}      // palette right-panel toggle → panel opens, empty state
{"cmd":"click","col":95,"row":5}      // "▸ Outline  :outline.show"
{"cmd":"snapshot"}
{"cmd":"click","col":95,"row":9}      // "▸ Tests  :test.run" (with main.rs open)
{"cmd":"snapshot"}
```

**Expected**: same behaviour as Problems / AI chat / Grep (all of which
work): the panel switches to that pane, or if the command has no context
(no editor / no test target) surface a toast.

**Actual**:

- **"Outline"** click does nothing when no file is open in the editor.
  Once you open `src/main.rs` first, the same click *does* work
  (Outline panel populates). So there is a silent guard on active-pane
  that shows no feedback.
- **"Tests"** click does nothing even with an editor open. No toast, no
  status message, no visual change.

Meanwhile Problems / AI chat / Grep all fire immediately regardless of
editor state. The inconsistency plus the total lack of feedback (no
toast "open a file first", no dimmed row) makes these rows look
straight-up broken.

---

## [SEV-2] Right-click on any palette-bar chip produces no menu

**Reproduction**:
```jsonc
{"cmd":"click","col":36,"row":0,"button":"right"}   // sidebar toggle
{"cmd":"click","col":39,"row":0,"button":"right"}   // back arrow
{"cmd":"click","col":42,"row":0,"button":"right"}   // forward arrow
{"cmd":"click","col":46,"row":0,"button":"right"}   // search chip
{"cmd":"click","col":77,"row":0,"button":"right"}   // dropdown chevron
{"cmd":"click","col":82,"row":0,"button":"right"}   // right-panel toggle
```

**Expected**: something. VS Code's title-bar analogs all give
something on right-click (e.g. "Reset width", "Hide", "Move to bottom",
"Show recent"). The palette bar is heavily branded as "the chrome" so it
should behave like chrome.

**Actual**: none of the six palette-bar chips produce anything on
right-click. Same coordinate rects (`palette_sidebar_button`,
`palette_back_button`, `palette_forward_button`, `palette_search_chip`,
`palette_dropdown_button`, `palette_right_panel_button`) do respond to
left-click and hover.

The dissonance is loudest next to `integration:46` (the browser chip,
same row): right-click there gives Disable / Move to top / Move up /
Move down / Move to bottom / Edit… / Copy id / Show manifest… / Remove.
So the user's mental model is "chips have menus" — and then the six
built-in chrome chips break that expectation.

---

## [SEV-2] Disabling an integration via right-click is one-way — no mouse path to re-enable

**Reproduction**:
```jsonc
{"cmd":"click","col":85,"row":0,"button":"right"}     // right-click browser chip
{"cmd":"click","col":80,"row":1}                      // "Disable (hide chip)"
{"cmd":"click","col":1,"row":10}                      // Activity → Integrations panel
```

**Expected**: the Integrations panel either lists disabled integrations
in a separate section with an "Enable" row-action, or "Marketplace" tab
lists the disabled ones with re-install/enable options, or right-click
in empty space gives "Show hidden integrations".

**Actual**:
- The browser chip disappears from the palette bar. ✔
- `enabled = false` is persisted to `~/.config/mnml/config.toml`. ✔
- On the Integrations activity panel: "Installed (8)" (was 9) — the
  disabled chip is no longer listed. There is no visible category for
  disabled integrations.
- The "Marketplace" tab-label at the top of the panel has **no
  click-rect** (see rects.json — no `marketplace_tab` / `installed_tab`).
  Clicking `Marketplace` text does nothing.
- The "Add integration" text at the bottom of the panel likewise has no
  click-rect and does nothing on click.
- Right-click on empty tree area (below the chip list) gives the file
  tree's default menu (New File / New Folder / …), not an
  integrations-panel menu.

Net: once a user disables a chip via right-click, the only recovery
is to hand-edit `config.toml` and set `enabled = true`. That is a hard
UX cul-de-sac.

---

## [SEV-2] `{{VAR}}` in the URL reports "not defined in active env" while the same var is bound in the same active env's Vars panel

**Reproduction**:
- `.mnml/env/dev.env` contains `TOKEN=abc123`
- `api.http` is `GET https://example.com/api/{{TOKEN}}`
- Open `api.http`, split-toggle the edit area, switch right side to Vars.

Observe:
- Right-side Vars panel shows `env: dev.env` with a row
  `TOKEN | abc123` — so mnml *has* loaded the env and *has* resolved
  TOKEN.
- Hover `{{TOKEN}}` in the URL:

```jsonc
{"cmd":"hover","col":74,"row":4}
```

  Tooltip renders **"not defined in active env · click to open env file"**.

- Left-click the token:

```jsonc
{"cmd":"click","col":74,"row":4}
```

  Opens the *"Value for TOKEN:"* seed-a-value prompt (the codepath the
  right-click menu labels "Set value…") instead of jumping to the
  `TOKEN=` line in `dev.env`.

- Right-click → "Jump to definition" *also* does nothing visible (no new
  buffer opens; `panes` in status.json shows only the two originally
  open tabs).

**Expected**: since Vars panel resolves TOKEN, so should the URL
tokenizer + hover + go-to-definition. Token colour should be cyan
(resolved), hover should say `abc123`, click should jump to
`.mnml/env/dev.env:1`.

**Actual**: token treated as unresolved everywhere in the URL. This
also implies the resolved/unresolved *colouring* (per FEATURES /
CLAUDE.md) is wrong for URL tokens — a mouse user would visually get
"undefined" (bold-red) even though the var is defined.

---

## [SEV-2] Icon-picker close: no `×` and no click-outside-to-dismiss

Once the glyph picker is open (`Enter` on glyph row → `Enter` on "Choose
from library"), the only mouse gesture that dismisses it is… nothing.
Clicking outside the picker box did not dismiss during my run. There is
no `×` on the picker frame. Esc key is the only exit. Same problem for
the "Glyph action" sub-menu (Choose from library / Create custom glyph)
one level up.

Every other overlay (right-click menus, welcome, confirm dialogs)
supports click-outside-to-dismiss. This one doesn't, so the discovery
gap compounds the SEV-2 above.

---

## [SEV-2] Silent no-op when dropping a file onto another file in the tree

**Reproduction**:
```jsonc
{"cmd":"drag","from_col":15,"from_row":9,"col":15,"row":15}
// api.http (row 9) dragged onto README.md (row 15)
```

**Expected**: either a Confirm prompt (mnml already knows how to prompt
"Move to <dir>/<basename>?" — it does so for file→folder drops), OR a
toast "Cannot drop file onto file", OR a drop-affordance during hover
that shows the drop is disabled. VS Code visually rejects (cursor-badge
shows a "no" symbol).

**Actual**: silent no-op. No toast, no prompt, no visual feedback during
drag. The user has to look at the tree to notice nothing happened.

(Same silence for drop onto a `.env` sibling in a different folder —
untested here but likely the same code path.)

---

## [SEV-2] Alt-drag copy has no on-screen affordance during the drag

Alt-drag on the tree does correctly copy on release (verified —
`api.http` copied into `docs/api.http`, both survive, no confirm
prompt). But during the drag itself, the ghost/tooltip that a
plain drag shows ("Move api.http to …?") doesn't distinguish from a
copy. A user pressing Alt has no visual confirmation the modifier
registered until the file appears in two places.

This is on the boundary of SEV-2/SEV-3; kept at SEV-2 because Alt-drag
is the only way to copy from the tree without a confirm.

Recommend: during Alt-drag, either (a) change the ghost-chip label to
"Copy api.http to <target>", or (b) show a small `+` badge on the drag
ghost like Finder does.

---

## [SEV-2] `activity:Explorer` click is a one-way trap once Integrations panel is showing

**Reproduction**:
```jsonc
{"cmd":"click","col":1,"row":10}      // Activity → Integrations (opens panel)
{"cmd":"click","col":2,"row":2}       // Activity → Explorer (expected: back to tree)
{"cmd":"snapshot"}
```

**Expected**: clicking Explorer while another activity panel is up
switches back to the file tree (like VS Code).

**Actual**: no change. Panel stays on Integrations. To get back to the
file tree the user must click `activity:Integrations` a second time
(that toggles it off), leaving no panel visible if right-panel isn't
open. So the file tree isn't restorable via the Explorer activity chip
at all.

Verified with a fresh restart (not a state-corruption artefact).

---

## [SEV-3] Palette-bar back/forward tooltip text is "no other buffers" instead of an action hint

Hovering `palette_back_button` (`x=39,y=0`) or `palette_forward_button`
(`x=42,y=0`) with a single buffer open produces the tooltip line

    no other buffers

That's a state description, not a click hint. Compare to
`palette_search_chip` which shows `command palette / click: open files,
commands, recent (Cmd+P)`. Recommended:

    back to previous buffer  (Cmd+[)
    · disabled — no other buffers

Two small extra dents while I was there:
- The search chip tooltip says `Cmd+P` but mnml's primary modifier is
  `Ctrl` (macOS-only leak from the copy).
- The dropdown-chevron chip tooltip is a bare `recent files` — no
  click-hint, no verb.

---

## [SEV-3] `..` up-navigation row tooltip prints a 108-char absolute path

Hovering `tree_up_row` shows:

```
Open parent as workspace
click: /private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad
```

The tooltip box stretches to the full width of the terminal because the
tempdir path is absurd. Recommend truncating with a middle-ellipsis
(`/private/tmp/…/scratchpad`) or showing only the last two segments —
the user cares about "which parent" not the absolute path.

---

## [SEV-3] Right-panel header truncates without an ellipsis at narrow widths

Drag the right-panel edge to leave `<10` cells inside the panel:

```jsonc
{"cmd":"drag","from_col":59,"from_row":10,"col":115,"row":10}
```

The header row renders as `right p` (bare truncation) with no
`…` marker and no re-flow. The FEATURES / CLAUDE.md contract says
"below 16 cells the body shows a 'too narrow' hint" — that hint
never appears in the empty-panel state; only the truncated header.
Adding `…` at the truncation point (or showing the "too narrow" hint
in the empty state too) would remove the "is this a bug?" pause.

---

## [SEV-3] Pty tab right-click menu has no "Restart" / "Kill process" action

Right-click on a Pty tab (`tools $` from `btop`) surfaces Close /
Close others / Close all / Split right / Split down / Split left /
Split up / Rename…. It does not offer "Restart"
or "Send SIGKILL", both of which are the actions a mouse user would
reach for on a hung `btop`/`htop` pane. Middle-click on the tab does
close the pane without confirmation — which is fine — but there's no
non-destructive re-run.

---

## [SEV-3] Right-clicking a chip's *command-line* row vs. its *label* row in the Integrations panel produced different menus once (unreproducible after a restart)

During one exploration session, right-clicking on the "tools.btop"
command line (`row=15`) of the btop entry opened the **"Install family
sibling" marketplace picker**, while right-clicking the label row
(`row=14`) opened the expected per-chip menu (Disable / Move up / …).

After a fresh restart I could not reproduce — both rows correctly
routed to the per-chip menu. Logging as SEV-3 since I only saw it
once, but the fact that a stale session could route right-click to a
completely different action ("open marketplace" vs. "chip menu")
suggests the panel's rect table is state-sensitive in a way that could
recur on real users. Worth an audit of the hit-test path when the panel
is scrolled + dialogs have been opened/closed several times in a
session.

---

## Positives observed (worth preserving)

- **Right-panel drag-resize** tracks the cursor 1-cell precisely; the
  edge rect (`right_panel_edge`) updates on every drag step.
- **Right-panel width persists across restart** (`session.json` writes
  `right_panel_width` and `right_panel_visible`, both honoured on
  relaunch).
- **`request_edit_split_chip` + `request_edit_split_divider` +
  `request_edit_tab_split:*`** all click through as advertised:
  toggle enables the split, divider cycles 50 → 70 → 30 → 50, right-side
  tab strip switches independent of the left side.
- **Integration chip right-click menu** is the best chip menu in the
  chrome — verb-rich, ordered sensibly, closes on Esc / click-outside.
- **`..` up-nav row + right-click "Set as workspace"** on a subfolder
  gives a full mouse-only workspace-switch loop.
- **Alt-click multi-cursor works.** Three Alt-clicks placed a cursor on
  three different lines and a subsequent `type "X"` inserted on all
  three simultaneously.
- **100 rapid clicks did not lag or crash** the app — it opened a few
  activities and a Pty pane but the loop stayed responsive.

---

## Test harness notes

- All work driven through `.mnml/ipc/` file IPC — no crossterm host.
- `drag` in the IPC schema does not accept a `mods` field; Alt-drag
  had to be synthesized as `mouse_down` (button="left", mods="alt") →
  `mouse_move` → `mouse_up`. That worked. Adding `mods` to `drag`
  would make the harness match real-world drag semantics.
- The task brief mentioned "~70 glyphs" for the icon picker; the picker
  header now reads `10 431 shown`. If the intent is still "a curated
  small grid", the picker's data source changed and the design premise
  no longer holds; if the intent is "10K glyphs", the mouse-navigation
  UX needs the full library-picker treatment (scroll, click-to-select,
  filter box).
