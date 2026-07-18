# vscode-keyboard-purist bug hunt — Round 8

Date: 2026-07-11
Driver: headless mnml + IPC (`--input standard`), workspace = fresh scratch tree.
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl+P / Ctrl+Shift+P / Ctrl+K / arrows only. No mouse.

Scope: verify the round-7 right-panel focus flow end-to-end, then poke less-covered surfaces (palette recents, Ctrl+P help, multi-cursor, LSP flows, terminal, bufferline, git, settings, find & replace).

## Executive summary

- SEV-1 count: 0
- SEV-2 count: 6
- SEV-3 count: 6

The round-7 fix for the right panel is nine-tenths there — Ctrl+E cycles the
focus into and out of the panel correctly, the PANEL statusline chip lights up,
arrow / Enter / r / Esc all reach the hosted pane's key handler, and the panel
gains a clean escape path back to the tree. But the marquee affordance
advertised for the round — `Ctrl+K r` to move focus straight into the panel —
does not work as pressed. The binding is registered with the spec
`"Ctrl+K r"` (capital `K`), which the parser turns into a Ctrl+**Shift**+K r
chord because the Chord normalization implicitly adds SHIFT when the char is
uppercase. So the palette and whichkey both advertise "Ctrl+K r" but the
actual key that fires the command is Ctrl+Shift+K r. On the advertised chord
whichkey.leader wins instead, then the r is fed to whichkey which toasts
"no leader mapping: <leader>r". That is exactly what the round-7 note was
trying to close, so it counts as a SEV-2 regression against its own claim.

Outside the right-panel flow the biggest gaps are the two canonical VS Code
LSP chords with no keyboard path — Shift+F12 for references and
Ctrl+Shift+Space for signature help are both silent. The find/replace prompt
still refuses Tab between the two fields (VS Code muscle memory dies here),
the command palette does not surface recently-used commands on empty query,
Ctrl+P has no `?` inline help, and typing `>` into Ctrl+P treats it as a
literal filter char rather than the VS Code mode-switch to the command
palette. Zoom-out: an average day is very drivable now, but the fine
edges of the LSP / find / palette flows still remind you every couple hours
that it isn't quite VS Code.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. `Ctrl+K r` (view.focus_right_panel) never fires — spec case-normalized to Ctrl+Shift+K r

Command declared as `keys: &["Ctrl+K r"]` at `src/command.rs:1847`. Pressing
Ctrl+K r (no shift) with the right panel open + a hosted problems pane fires
`whichkey.leader` fallback + then `whichkey_feed('r')`, toasting
`no leader mapping: <leader>r`. Focus does not move into the panel.

Root cause: `parse_key_spec("Ctrl+K")` strips the lowercase `ctrl+` prefix and
falls through to `key_code("K")`, returning `KeyCode::Char('K')`. Then
`Chord::of(KeyEvent{Char('K'), CONTROL})` at `src/input/keymap.rs:44` hits the
`is_ascii_uppercase` branch and adds SHIFT to the chord modifiers. So the map
holds `Chord{Char('k'), CONTROL|SHIFT}` → view.focus_right_panel. Every other
Ctrl+K binding in the registry uses lowercase (`ctrl+k z`, `ctrl+k ctrl+i`,
`ctrl+k ctrl+left/right/up/down`, etc.) and works. Only this one shipped with
uppercase and is silently broken.

Confirmed by pressing Ctrl+Shift+K r in the same headless scenario — focus DOES
move to the right panel (`{focus:"right_panel"}`). The palette + whichkey both
advertise the chord as "Ctrl+K r" so the hint lies to the user.

Round-7 status text advertises "right panel gained keyboard focus (Ctrl+K r)"
— this is the fix that landed but is dead on arrival. Regression against the
round-7 claim.

### 2. Shift+F12 (find references) has no chord — canonical VS Code miss

`lsp.references` at `src/command.rs:3617` has `keys: &[]`. Grep confirms no
Shift+F12 binding anywhere. Pressing Shift+F12 in a `main.go` buffer is a
silent no-op — no toast, no palette hint, no fallback. The related F12
(goto def) works fine ("no language server for this file (go-to-definition)"
toast). Round 2/3 flagged the same lsp.references gap; still open in round 8.

VS Code muscle memory: Shift+F12 is one of the top-5 LSP chords. Users who
switch between projects will notice this within an hour of touching mnml.

### 3. Ctrl+Shift+Space (signature help) has no chord

`lsp.signature_help` at `src/command.rs:3648` has `keys: &[]`. The trigger
IS wired to auto-fire on `(` or `,` while typing (see `src/app/lsp.rs:141`)
so users get the popup as they type args, but there is no way to re-summon it
after the popup has been dismissed / expired. VS Code binds Ctrl+Shift+Space
to "Trigger Parameter Hints" specifically for that "I dismissed it, show me
again" flow. No mnml chord. Palette-only.

### 4. `Ctrl+H` chained to Replace still shows a modal find prompt, not a two-field find+replace bar

`Ctrl+H` opens a `Find (Enter → Replace)` modal (`src/app/picker.rs:1637`
seed). Typing a pattern then Enter jumps to the first match AND, on match,
opens a second `Replace 1× "pat" with` modal. That does work — the
chain_to_replace flag threads correctly. But pressing Tab in the first modal
is a no-op — Tab is expected to move to the Replace field in VS Code's
combined find/replace bar. There is no way to compose a find+replace pair
without first executing the find. Also no chord (Alt+Enter in VS Code) to
run replace-all directly from the find field. Modal-serial rather than
inline-bar.

Prior rounds have flagged Ctrl+H repeatedly; kept here because Tab is now
literally silent (no navigation) so the user reflex fails without feedback.

### 5. Right-panel `/` filter is Outline-only — Problems pane has no filter chord

`src/tui/handlers/pane.rs:787` (Outline pane) handles `Char('/') → filter_mode
= true`. The Diagnostics pane at line 1598 does NOT handle `/`. Same for
Grep / Quickfix. Task explicitly asked that `/` filter work in the right
panel — it does for Outline, does not for Problems. Feature gap.

Reproduced by right-panel-focusing the problems pane and pressing `/`: no
filter row appears, no visible affordance. `s` DOES work (cycles severity
filter) but `/` is a common muscle-memory query key.

### 6. No git-flow chord surface — everything is palette-only

The `git.*` command group (`git.blame_toggle`, `git.commit`, `git.stash`,
`git.stash_pop`, `git.fetch`, `git.pull`, `git.push`, and about 15 more) has
zero `keys` bindings. Ctrl+Shift+G opens the git graph pane (round-7 fix,
works fine) but from the graph pane there is no chord for the common
operations. VS Code doesn't expose most of these on chords either, so this
isn't a strict VS Code miss — but a "SEV-2 no keyboard path" for the ones
users reach hourly: at minimum blame toggle and commit deserve a chord.

Every git action currently either needs `Ctrl+Shift+P` → type name, or a
`<leader>g...` chord that requires the vim leader. Standard-mode VS Code
users have palette or nothing.

---

## SEV-3 — Polish / could be more discoverable

### 1. Command palette has no recent-items bubbling on empty query

Ctrl+Shift+P → picker opens on the full 680-command list with no
prioritization. VS Code convention: recently-used commands appear at the top
of an empty-query palette so the last five power-actions are one Enter away.
mnml has a separate `picker.recent_commands` (Ctrl+K Ctrl+O) that dedicated
recents, but the primary palette does not blend recents to top. Nice-to-have.

### 2. Command palette has no `>` / `@` / `#` mode-switch prefixes

Typing `>save` into Ctrl+P treats `>` as a literal filter char. Result:
`0 of 6 (no matches)`. VS Code convention:
- `>` in Ctrl+P → switch to command palette
- `@` → symbol picker
- `#` → workspace symbol picker

None of these prefixes are wired. Muscle-memory misfires; user has to Esc and
re-open with the right chord.

### 3. Ctrl+P `?` in query is a filter char, not inline help

VS Code's Ctrl+P shows an inline help panel when the query is exactly `?`
listing the available prefixes. mnml treats `?` as a filter char (`0 of 5
(no matches)`). Fine for a keyboard-purist who already knows the chords, but
a discovery miss for users learning the app.

### 4. Right-panel Esc jumps to Tree, not to the last editor pane

From RightPanel focus, Esc → `focus_tree()` (both Outline at
`src/tui/handlers/pane.rs:802` and Diagnostics at line 1613 call
`app.focus_tree()`). VS Code convention: Esc from a docked panel returns
focus to the last text editor, not to the file explorer. Minor annoyance
for a keyboard user who wants to bounce between problems ↔ editor.

### 5. "closed <name> · ↶ Undo (⇧⌃Z)" toast advertises Ctrl+Shift+Z; the actual reopen chord is Ctrl+Shift+T

`src/ui/toast_stack.rs:231` renders `↶ Undo (⇧⌃Z)`. Both work
(`src/tui/mod.rs:552` binds Ctrl+Shift+Z to commit_pending_undo when a toast
is live; buffer.reopen has `Ctrl+Shift+T`). Advertising ⇧⌃Z steals a chord
mnml also uses for Redo in a different flow — a VS Code user reaching for
Ctrl+Shift+T for the reopen and seeing the chip say ⇧⌃Z gets a small mental
stumble. Chip should say Ctrl+Shift+T (matching buffer.reopen's static
binding), or advertise both.

### 6. Ctrl+K r is advertised in the palette + whichkey group hints but is unreachable

Straight downstream of SEV-2 #1. Every discovery surface tells the user
"Ctrl+K r focuses the right side panel" and none of them fire. Even after
the SEV-2 root cause is fixed, this class of issue (spec advertised
does-not-match spec dispatched) deserves a startup lint — the parse loop
in `src/input/keymap.rs:139` could warn when a spec contains uppercase
chord chars (which will silently be re-normalized as SHIFT'd), the same way
it already warns on chord collisions.

---

## What round 8 verified as working (positive findings)

- Ctrl+E cycles focus Tree ⇄ Pane ⇄ RightPanel correctly (with right panel
  hosted a Problems pane). PANEL statusline chip lights on entry.
- Arrows in a focused right-panel Problems pane navigate rows (verified via
  handler code; empty diagnostics list in test scenario left visible
  side-effects sparse).
- Esc from the right panel returns to Tree (arguably wrong destination —
  SEV-3 #4 — but the escape path IS present, no stuck state).
- Ctrl+P → arrow → Enter opens the selected file at the correct pane index.
- Ctrl+P + `nes` fuzzy → single match highlighted → Enter opens nested.txt.
- Ctrl+Shift+P palette filters "save" → 182/680, arrow moves highlight down
  correctly (skipping visually adjacent rows because MRU-ordered).
- Ctrl+D multi-cursor extend by word (verified via Sel-N statusline: after
  3× Ctrl+D on "foo" content, statusline reads `Sel 3`).
- Ctrl+Alt+Down adds a cursor per press below (verified by typing `X` across
  3 cursors → `Xfoo bar` on lines 1/2/3).
- Esc drops extra cursors (Sel N chip disappears; primary cursor remains).
- Ctrl+K Ctrl+I fires lsp.hover (chord chain still works for lowercase
  specs). Toast: "no language server for this file (hover)".
- F12 fires lsp.goto_definition. Toast on missing LSP.
- F2 opens "Rename symbol to" prompt.
- Ctrl+. fires lsp.code_action.
- Ctrl+/ toggles line comment (Go: `// func main() {}`).
- Alt+Down moves line down. Shift+Alt+Down duplicates line.
- Ctrl+F + query + F3 next / Shift+F3 prev with `match N/M` toast.
- Ctrl+G go-to-line jumps cursor.
- Ctrl+, opens Settings overlay. Arrows navigate rows, ←→ adjusts value with
  `*` modified marker, `r` resets focused row (clears `*`), `/theme` filters
  down to just the Theme row.
- Ctrl+B toggles tree visibility.
- Ctrl+Shift+B toggles right panel.
- Ctrl+\ splits editor right (2 identical panes).
- Ctrl+Tab MRU-switches. Ctrl+PgDn advances tab sequentially with wrap.
- Ctrl+W closes active tab. Ctrl+Shift+T reopens last-closed with position.
- Ctrl+W on a dirty tab shows a `[Save] [Discard] [Cancel]` button dialog;
  Esc from the dialog cancels without losing the buffer.
- Ctrl+K z toggles zen mode. (Lowercase spec works — contrast with SEV-2 #1.)
- Ctrl+R opens the Recent files picker; MRU order visible.
- Ctrl+Shift+G opens the git graph pane even on a non-git workspace.
- Palette Esc closes without firing; picker Esc returns focus to editor.
- 5× rapid Ctrl+P + Esc cycles leave focus cleanly on the editor.
- 50× type-a followed by 50× Ctrl+Z leaves the buffer clean (dirty=false,
  cursor at 1,1) with no observable lag in the drive-loop time budget.
- The Ctrl+H → find → Enter → Replace-modal chain works (SEV-2 #4 is the
  Tab-between-fields gap, not that the flow is broken).

---

## What I did NOT cover

- LSP flows against a real running language server (workspace had `main.go`
  + no gopls). Chords all fire and produce the expected "no LSP" toast; the
  actual popup UX behind hover / rename / code-action / references is
  reachable-in-principle but I didn't exercise the popups.
- Terminal (Pty) focus / escape hatch — Ctrl+` in headless doesn't spawn a
  pty (no controlling terminal). `term.scratch_toggle` via run-command was
  a silent no-op; not scored because headless is a plausible cause.
- Ctrl+K Ctrl+S (Keyboard Shortcuts panel) — still no chord (round 2
  SEV-3, not re-scored).
- F11 fullscreen — headless environment can't really test window-level
  full-screen; round 2 flagged already.

---

## Repro method

Every finding was reproduced with:

```
target/release/mnml --headless --input standard <fresh workspace>
```

driven via file-IPC (`.mnml/ipc/command`) with the drive.sh helper. Screen
snapshots + status.json + events.jsonl captured after each scenario. The
workspace was scrubbed (`rm -rf .mnml/`) between scenarios so no session
state carried over. Commands used: `wait_ms`, `key`, `type`, `open`,
`run-command`, `snapshot`, `quit`. No `click` / `hover` / `wheel` / `drag`.
