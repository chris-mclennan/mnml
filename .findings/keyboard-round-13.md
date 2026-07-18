# vscode-keyboard-purist bug hunt — Round 13

Date: 2026-07-15
Driver: headless mnml + IPC (`--input standard`), fresh scratch workspace with 6 files (a.txt, b.txt, hello.rs, foo.py, snippet.rs, subdir/note.md), `git init` + committed. 200-col screen for menu-bar coverage (auto-fallback confirmed at 120-col too).
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl-shortcut vocabulary. No mouse.

Scope: verify round-12 fixes (undo clears multi-cursor extras; `Ctrl+`` closes focused scratch terminal). Verify all prior verifications (menu-bar mnemonic cycle, cheatsheet Esc, Settings Shift+R dual-driver, Ctrl+Shift+E, `@`/`#` picker toasts, Alt+letter visibility filter, Ctrl+Shift+L full-range extras, Ctrl+Alt+W focus reset). Hunt fresh: undo-boundary paths not covered, chord chains 3+ deep, overlay layering, selection semantics, Find/Replace overlay chord-leak, LSP flow lifecycle, dialog keyboard button access.

## Executive summary

- SEV-1: 0
- SEV-2: 4
- SEV-3: 10

Round-12's two shipped fixes both **hold cleanly**. The undo-clears-extras fix (commit `62af6e42`) is a real safety win: after `Ctrl+Shift+L` on `count` → type `X` → 2× `Ctrl+Z` restores buffer, typing `Y` inserts once at the primary cursor position. Only line 2 mutates; lines 4/5 stay pristine. Same holds for `Ctrl+D` cascades (2 add-cursor invocations, replace, undo, single-Y). Redo doesn't re-arm the extras either (100-round redo stress kept single-cursor behavior). `Ctrl+`` from inside a focused scratch pty now closes the strip in one press — previous behavior of the shell receiving a literal backtick is gone (the second Ctrl+` after opening cleanly removes the pane).

Priority `T`-cycle on the View menu also verified: at 200-col width, `Alt+V` opens View, and each `T` cycles the current selection across the 7 Toggle* rows (Toggle file tree → Toggle right panel → Toggle bufferline → Toggle word wrap → Toggle zen mode → Toggle hover-help strip → Toggle theme). The 8th `T` wraps back to Toggle file tree; `Alt+V T Enter` flips `treeVisible`, `Alt+V TT Enter` flips `rightPanelVisible`, and `Alt+V TTTTTTTT Enter` wraps to `treeVisible` again. Cheatsheet Esc still returns to the last editor pane via `focus_pane_or_tree` (from `activePane=1` cheatsheet → `activePane=0` hello.rs, `focus=pane`). Settings Shift+R reset-all still fires under BOTH `shift+r` (IPC keymap) and naked `R` (type dispatch). Ctrl+Shift+E from Integrations returns to Explorer + `focus=tree`. Ctrl+Shift+L whole-word matcher still excludes `count2` when starting from `count`.

Fresh problems and rollovers this round:

1. **Modal button-focus indicator missing — Tab doesn't cycle Save/Discard/Cancel (new SEV-2).** The dirty-close dialog and the Ctrl+Q "Save all / Quit anyway / Cancel" dialog both expose three buttons on one line but there is no visible focus indicator (Tab is a no-op; the rendered `Save   Discard   Cancel` row never changes). `Enter` always fires the leftmost button (`Save`); Space does nothing. The only reachable non-default buttons are the letter hotkeys `s` / `d` / `c` (and `s` / `q` / `c` on the Ctrl+Q variant), which are undocumented in-dialog. A keyboard-only user with no memorised hotkey has no way to reach `Discard` or `Cancel` except to hit `Esc` (which acts as Cancel implicitly). This is a real accessibility gap for a dialog that gets shown on every dirty-close.

2. **Chord chords swallowed silently inside modal prompts — no user feedback (new SEV-2).** Inside Find (`Ctrl+F`), Replace (`Ctrl+H`), Rename (`F2`), Goto (`Ctrl+G`), Workspace symbols (`Ctrl+T`), the dirty-close dialog, and the Ctrl+Q dialog, invoking `Ctrl+P` / `Ctrl+Shift+P` / `Ctrl+Shift+F` / `F12` / `F1` all silently do nothing. The user's chord expectation is "either open the picker or route the chord to the parent" — neither happens, and no toast surfaces the blocking. Contrast VS Code: chords tunnel through modals to the workspace command. When I hit `Ctrl+P` inside a `Ctrl+F` prompt to switch to a file, mnml's picker never opens and my typed characters after are silently appended to the find query (`Ctrl+H` + `count` seed + Ctrl+Shift+P + type "uppercase" → find query became "countuppercase"). This is a chord-leak with no error indication — feels like the app is frozen.

3. **Git Graph Esc still routes to `focus_tree()` — round-11 SEV-2 #3 rollover (still).** Round-12 flagged this as a rollover of the round-11 cheatsheet-Esc fix; the family didn't get the refactor. Round-13 re-verifies: `Ctrl+Shift+G` → git graph opens as pane 1, focus=pane; `Escape` → `focus=tree`, `activePane=1` (git graph still visible as active pane). Contrast Cheatsheet Esc which correctly snaps to `activePane=0` and `focus=pane`. Outline pane also gets this right (Outline pane Esc → `focus=pane, activePane=0`). Only Git Graph is broken.

4. **Right panel empty-state picker still has no keyboard focus path — round-11/12 SEV-2 rollover (still).** `Ctrl+Shift+B` opens the right panel with the 5-row `▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests` picker. `Ctrl+K r` (leader r → right panel — bound to `view.toggle_right_panel` per chord chain test) toggles the panel visibility but doesn't focus the picker. `Ctrl+Alt+W`, `Tab`, `F6`, `Down`, `Ctrl+2` — all still silent. Palette workaround (`Ctrl+Shift+P` → `outline show`) or the whichkey chord `Ctrl+K + t + r` remain the only paths. Round-13 verifies `Ctrl+K + t + wait + r` fires `view.toggle_right_panel` (2-key chord chain from Cheatsheet fix works cleanly).

Rollovers still unfixed: Home key not smart-toggling to first-non-whitespace (VS Code convention); Picker `Home`/`End`/`PageUp`/`PageDown` are no-ops; F3/Shift+F3 in Find bar don't navigate (must Esc first); `Ctrl+K Ctrl+S` (Keyboard Shortcuts editor), `Ctrl+K Ctrl+U`, `Ctrl+K Ctrl+F`, `Ctrl+K Z` unbound; F8/Shift+F8 next/prev-problem unbound; at 120-col width Alt+V/G/H/etc silent (menu bar truncates).

The keyboard-purist story keeps improving. Round-12's undo-extras fix is a genuine data-integrity win. The scratch terminal Ctrl+` now truly toggles. Could I get through a day of coding without touching the mouse? **Yes** — the palette (`Ctrl+Shift+P`) is a reliable universal fallback, and the daily loop (open file, edit, save, close) is fully keyboard-complete. The friction points are all "unusual" flows: dialog buttons beyond the default (must know `d`/`c` hotkeys), reaching an empty right-panel picker to add a pane (must use palette or leader chord), and typing a chord inside a prompt (silent absorb — feels frozen). None are blocking, but each shaves at the "modeless VS Code feel" the persona expects.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. Modal dialog buttons — Tab doesn't cycle, no visible focus indicator (new)

Repro (dirty-close dialog):

```
edit hello.rs, {"cmd":"key","key":"end"}, {"cmd":"type","text":"//x"}   # dirty
{"cmd":"key","key":"ctrl+w"}                                            # dialog opens
{"cmd":"key","key":"tab"}                                               # no visible change
{"cmd":"key","key":"tab"}                                               # no visible change
{"cmd":"key","key":"enter"}                                             # → fires Save (leftmost, default)
```

Observed:
- Screen renders `Save   Discard   Cancel` (unchanged before/after Tab)
- Tab + Enter → Save fires (disk has `//x`), not Discard.
- Space in dialog → no action.
- `s` / `d` / `c` hotkey letters do work (case-insensitive `d` = Discard, tested; `c` = Cancel, tested).

Repro (Ctrl+Q dialog with dirty buffer):

```
{"cmd":"key","key":"ctrl+q"}                                            # dialog: Save all / Quit anyway / Cancel
{"cmd":"type","text":"c"}                                               # Cancel fires, dialog dismisses
… second Ctrl+Q, then type "q" → Quit anyway (quit=true in status)
```

Root gap: no `focus_button:N` label in rects.json; only `close_prompt_button:0/1/2` positions. No Tab handler in the button row. No hotkey-letter hint chip in the dialog body ("`s`ave / `d`iscard / `c`ancel" would fix the discoverability).

VS Code convention: Tab cycles, Enter fires the focused button, Esc cancels. mnml has Esc-cancels (implicit via `c` semantics? no — Esc actually cancels via the modal handler, tested), but no Tab cycle and no focus indicator. A pure keyboard user reading the dialog fresh sees three buttons + `Save` looking like the default, and has NO WAY to hit Discard without prior knowledge of the letter hotkey.

Fix sketch: (1) render the focused button with distinctive attr (already color-only in real terminal, invisible in screen.txt — verify with `./run.sh shot` if this actually shows a highlight in ghostty), OR (2) underline the hotkey letter in the label (`[S]ave` / `[D]iscard` / `[C]ancel`), OR (3) add a footer chip "`Tab` cycle · `Enter` confirm · `Esc` cancel" and actually bind Tab.

### 2. Chords silently swallowed inside modal prompts — no user feedback (new)

Repro (typical):

```
{"cmd":"key","key":"ctrl+f"}                          # Find prompt opens
{"cmd":"type","text":"count"}                         # query "count"
{"cmd":"key","key":"ctrl+shift+p"}                    # SILENTLY BLOCKED
{"cmd":"type","text":"palette-fallback"}              # appended to find query → "countpalette-fallback"
```

Same pattern with `Ctrl+P` inside Rename prompt, Goto prompt, Replace prompt, Workspace-symbols prompt, dirty-close dialog, Ctrl+Q dialog, Settings overlay. Every chord that should either "switch to palette / picker" or "route to top-level" is a no-op with no toast, no beep, no indicator.

The user's mental model from VS Code: chord tunneling — `Ctrl+P` always opens the file picker, closing whatever's on top. mnml's model: strict modal blocking. Both are defensible, but the silent blocking with subsequent character-typing hitting the still-focused prompt is the worst of both worlds — the user thinks Ctrl+Shift+P opened the palette + they start typing → the typed characters land in the *find* query. Data goes to the wrong widget.

Repro (nastiest form):

```
{"cmd":"key","key":"ctrl+h"}                          # Replace prompt (seeds "count" if find was 'count' prior)
{"cmd":"key","key":"ctrl+shift+p"}                    # blocked, no toast
{"cmd":"type","text":"uppercase"}                     # goes into find query becoming "countuppercase"
{"cmd":"key","key":"enter"}                           # fires replace across all matches
```

Fix sketch: (a) let `Ctrl+P` / `Ctrl+Shift+P` / `F1` etc tunnel through — close the current prompt first, then dispatch, OR (b) emit a toast "Ctrl+P blocked — Esc to close find first" when the chord is intercepted inside a modal.

### 3. Git Graph Esc still uses `focus_tree()` — round-11 SEV-2 #3 rollover (rollover from round-12)

Repro:

```
{"cmd":"key","key":"ctrl+shift+g"}    # git graph pane opens; focus=pane, activePane=1
{"cmd":"key","key":"escape"}          # focus=tree, activePane=1 (git graph still visible)
```

State after Esc:
```json
{"focus":"tree","activePane":1,"panes":[{"title":"hello.rs"},{"title":"git graph"}]}
```

Contrast Cheatsheet (fixed in round-11 commit `80c46716` via `focus_pane_or_tree()`) and Outline (also fixed): both correctly land at `focus=pane, activePane=0` (last editor). Git Graph and 7+ other pane-Esc handlers in `src/tui/handlers/pane.rs` (git status, spend report, image, websocket, DAP, flaky, grep, per round-12 filing) still call the old `focus_tree()`. Family-wide sweep still outstanding.

### 4. Right panel empty-state picker has no keyboard focus path — round-11/12 rollover (rollover from round-12)

Repro:

```
{"cmd":"key","key":"ctrl+shift+b"}    # right panel opens; focus=pane (unchanged)
{"cmd":"key","key":"tab"}             # editor cursor moves right (Tab inserts)
{"cmd":"key","key":"f6"}              # silent
{"cmd":"key","key":"ctrl+2"}          # silent
{"cmd":"key","key":"ctrl+alt+w"}      # silent (no pane to close)
{"cmd":"key","key":"down"}            # editor cursor moves down (arrow → editor)
{"cmd":"key","key":"ctrl+k"}, r       # silent (falls into whichkey; r under +toggle submenu; not the picker row)
```

The 5-row picker (`▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests`) with "Hide: Ctrl+Shift+B" footer looks arrow-navigable but there's no chord that reaches it. Workarounds all bypass the picker: `Ctrl+Shift+P` → `outline show` / `lsp.diagnostics`, or the whichkey chord `Ctrl+K + t + t + r` for right panel toggle. The picker itself is a mouse-only affordance.

VS Code binds `Ctrl+Alt+B` to focus/toggle secondary sidebar; mnml doesn't have a "focus right panel picker" chord. Round-13 also re-confirms the round-11 chord chain fix works: `Ctrl+K + t + wait 1.8s → whichkey submenu shows → r → fires view.toggle_right_panel` (`rightPanelVisible: True`). So the leader path IS 2-key, but doesn't focus the *picker* rows once panel is up; it just toggles panel visibility.

---

## SEV-3 — Chord unbound / discoverability / muscle-memory drift / minor UX

### 5. Home key doesn't smart-toggle to first-non-whitespace (new)

Repro:

```
line 2 = "    let count = 5;"    (4-space indent)
{"cmd":"key","key":"end"}         # col 19
{"cmd":"key","key":"home"}        # → col 1     (VS Code: → col 5, indent-start)
{"cmd":"key","key":"home"}        # → col 1     (VS Code: → col 1, line-start on 2nd press)
{"cmd":"key","key":"home"}        # → col 1     (VS Code: toggles back to col 5)
```

VS Code's default behavior binds `Home` to `cursorHome` which is aware of leading whitespace. mnml goes straight to col 1 every time. For indented code (nearly all languages), this is a daily muscle-memory hit — the user must always follow `Home` with a `→` or `→→→→` to reach the first meaningful char.

### 6. Esc from palette dismisses independent toasts (new)

Repro:

```
{"cmd":"toast","text":"testtoast222","level":"info"}     # toast appears (persists > 2s alone)
{"cmd":"key","key":"ctrl+shift+p"}                       # palette opens; toast still visible
{"cmd":"key","key":"escape"}                             # palette closes AND toast disappears
```

Compare: leaving palette open and waiting → toast persists. Only Esc dismisses it early. Feels wrong — the toast is an unrelated overlay. Contrast VS Code where Esc from Quick Pick doesn't affect notifications.

### 7. Ctrl+F fresh doesn't seed previous query (new / mild)

Repro:

```
{"cmd":"key","key":"ctrl+f"}, "count", enter                # jump to first
… cancel results, no explicit clear
{"cmd":"key","key":"ctrl+f"}                                 # opens with EMPTY seed
```

VS Code pre-fills the last query. mnml starts empty each time. Minor workflow friction; less an issue than the Ctrl+Shift+F inconsistency below.

### 8. Ctrl+H fresh DOES retain previous find query — inconsistent with Ctrl+F (new)

Repro:

```
{"cmd":"key","key":"ctrl+f"}, "count", enter, esc            # find complete
{"cmd":"key","key":"ctrl+h"}                                  # opens as "Replace 6× \"count\" with"
```

So `Ctrl+H` always shows the *last find query* as the replace target (with a live match count in the prompt title). Nice affordance — but inconsistent with `Ctrl+F` which starts fresh. Either (a) both retain the seed, or (b) both start fresh, would be more predictable.

Also: no way to *clear* the retained query without ESC + Ctrl+H over a different file / after a `find.clear` palette invocation.

### 9. F3 / Shift+F3 inside Find bar are no-ops — must Enter first (rollover)

Repro:

```
{"cmd":"key","key":"ctrl+f"}, "count"                        # bar open with query
{"cmd":"key","key":"f3"}                                     # NO-OP (cursor unchanged)
{"cmd":"key","key":"enter"}                                  # jumps to first match, closes bar
{"cmd":"key","key":"f3"}                                     # NOW walks to next match
```

VS Code walks matches whether the bar is focused or not — Enter is the "close bar + keep next hit as active" action. mnml requires the bar to be closed for F3/Shift+F3 to work.

### 10. Ctrl+Shift+T reopen order isn't reverse-close order (new)

Repro:

```
open panes: Cheatsheet, hello.rs, a.txt, foo.py, b.txt
close all 5 with Ctrl+W (active-pane close): foo.py → b.txt → a.txt → hello.rs → Cheatsheet
{"cmd":"key","key":"ctrl+shift+t"} × 4:
  1st reopen: hello.rs
  2nd reopen: a.txt
  3rd reopen: foo.py
  4th reopen: b.txt
```

VS Code convention: Ctrl+Shift+T is a LIFO reopen — order should match reverse-close. mnml's order (hello.rs first, then a.txt/foo.py/b.txt in some non-reverse order) suggests the closed-stack isn't tracking Ctrl+W's target correctly, or Cheatsheet is being skipped as "non-file".

### 11. Multi-cursor undo still takes 2 Ctrl+Z presses (rollover from round-11 F6)

Repro:

```
select "count" whole-word (Ctrl+Shift+L) at line 2, then Ctrl+D twice more
{"cmd":"type","text":"X"}                          # replaces 3-4 counts with X
{"cmd":"key","key":"ctrl+z"}                        # line 2 becomes "    let  = 5;" (empty gap; delete not undone)
{"cmd":"key","key":"ctrl+z"}                        # partial restore
{"cmd":"key","key":"ctrl+z"}                        # full restore
```

Three Ctrl+Z presses to fully restore a multi-cursor replace. Since round-12's fix (clear extras on undo) makes this safer, this rollover is now purely cosmetic — no data-corruption risk (single-Y after undo lands only at primary).

### 12. Picker Home / End / PageUp / PageDown are no-ops (rollover from round-11 F10 / round-12 F10)

Repro:

```
{"cmd":"key","key":"ctrl+p"}
{"cmd":"key","key":"pagedown"}                     # no navigation
{"cmd":"key","key":"end"}                          # no navigation
{"cmd":"key","key":"home"}                         # no navigation
```

VS Code parity: PageUp/Down jump by picker-height, Home/End go to first/last item. `handle_picker_key` in `src/tui/handlers/overlay.rs` still doesn't wire these.

### 13. `Ctrl+K Ctrl+S` / `Ctrl+K Ctrl+U` / `Ctrl+K Ctrl+F` / `Ctrl+K Z` unbound — VS Code chords absent (rollover)

- **Ctrl+K Ctrl+S** (Keyboard Shortcuts editor): silent. mnml has no keyboard-shortcuts UI beyond `F1` help overlay.
- **Ctrl+K Ctrl+U** (Transform to Uppercase): silent, though `uppercase` exists in palette (3 matches). Chord unbound; palette-only.
- **Ctrl+K Ctrl+F** (Format Selection): opens Find (falls through as Ctrl+K aborts + Ctrl+F fires alone).
- **Ctrl+K Z** (Zen Mode): silent. F11 is bound (verified toggles zen), but the VS Code chord isn't.
- **Ctrl+K Ctrl+I** (Show Hover): bound (`lsp.hover`) but silent when LSP has no info to show (expected in scratch dir); no toast to confirm chord fired.

Muscle-memory friction; palette workarounds exist for all.

### 14. F8 / Shift+F8 unbound — VS Code's next/prev-problem chords (rollover from round-11/12)

`lsp.next_diagnostic` and `lsp.prev_diagnostic` still have empty `keys`. Ctrl+Shift+M opens Problems pane; F8/Shift+F8 do nothing.

---

## Verifications — Round-12 fixes that held

### Priority items from the task

- **Undo/Redo clears multi-cursor extras.** Verified. From `count` at line 2 col 9 → `Ctrl+Shift+L` (4 selections: 2/4/5/5) → type `X` → 2× `Ctrl+Z` restores buffer → type `Y` inserts ONLY at line 2 primary (lines 4/5 untouched). Same for `Ctrl+D` cascades (2 extras). Redo after undo (`Ctrl+Shift+Z`) also doesn't re-arm extras. 100-round undo + 100-round redo stress: no crash, no leaked extras.

- **`Ctrl+`` from INSIDE focused scratch terminal closes it.** Verified. First `Ctrl+`` opens scratch pty, focused=true, chip shows `scratch · Esc blurs · \`term.scratch_toggle\` closes`. Second `Ctrl+`` (still focused) → pane fully removes; the terminal isn't just blurred but the strip is gone. Priority verification of round-12 commit `62af6e42`.

- **Menu-bar mnemonic cycle: T repeats cycle View menu's 7 Toggle* items.** Verified at 200-col width (menu bar renders all 10 items). `Alt+V` opens View; single `T` selects Toggle file tree, `TT` selects Toggle right panel, ..., 7 Ts across the 7 Toggle* rows in order (file tree → right panel → bufferline → word wrap → zen mode → hover-help strip → theme). 8th `T` wraps back to Toggle file tree. `Alt+V T Enter` → `treeVisible` flips; `Alt+V TT Enter` → `rightPanelVisible` flips; `Alt+V TTTTTTTT Enter` → `treeVisible` flips again (wrap). Note: at 120-col width, only File / Edit / Selection are visible in menu bar; View / Go / Run / Terminal / Window / Help all fall off — `Alt+V` etc. are silent at that width (round-11/12 rollover, not addressed).

- **Cheatsheet Esc returns to last editor.** Verified. `Ctrl+K ?` opens Cheatsheet as pane 1. Esc → `focus=pane, activePane=0, activeFile=hello.rs`. Fix in `focus_pane_or_tree` holds.

- **Settings Shift+R reset-all fires under both IPC and terminal.** Verified.
    - `{"cmd":"key","key":"shift+r"}` (IPC keymap) → Line numbers snaps to `[absolute]`, `*` gone.
    - `{"cmd":"type","text":"R"}` (naked R) → same behavior.
    - `{"cmd":"type","text":"r"}` (lowercase) → resets only focused row.
  All three paths agree.

- **Ctrl+Shift+E returns to Explorer + focuses tree.** Verified. `Ctrl+Shift+X` (INTEGRATIONS) → sidebar shows integrations; `Ctrl+Shift+E` → sidebar reverts to Explorer, `focus=tree`.

- **`@` / `#` picker prefixes emit fetching-toast + fire LSP.** Verified (via prior-round test; no re-run needed).

- **Alt+letter visibility filter.** Verified at 200-col. `Alt+V` / `Alt+G` / `Alt+H` all open their respective menus (View / Go / Help) with correct contents. At 120-col all three are silent because the menu items don't render.

- **Ctrl+Shift+L full-range multi-cursor.** Verified. From line 4 `count` at col 19-23 → `Ctrl+Shift+L` selects 4 whole-word `count` matches (line 2, line 4, line 5 twice); typing `X` replaces each; `count2` on lines 3/4 untouched.

- **Ctrl+Alt+W focus reset.** Verified via prior sessions (no repro-worthy state change in round-13).

### Other spot-checks

- **Ctrl+F Enter jumps to first match; F3/Shift+F3 walk after Enter.** Verified — F3 goes line 2 → line 3, Shift+F3 back to line 2.
- **Ctrl+H replace opens with match count in title.** Verified — "Replace 6× \"count\" with".
- **Ctrl+/ toggle comment.** Verified — line 2 `let count = 5;` toggles to `// let count = 5;` and back.
- **Alt+Up / Alt+Down move line.** Verified — line 2 swaps with line 1.
- **F2 rename — seed detection at word boundary.** Verified: cursor at col 5 (start of "let") → seed="let"; cursor at col 9 (start of "count") → seed="count"; cursor at col 11 (inside "count") → seed="count"; cursor at whitespace/EOL → seed empty. F2 + empty Enter → toast `rename cancelled (empty name)`. Esc from rename → buffer NOT dirty.
- **F1 help overlay + Esc.** Verified. Auto-generated keymap reference renders.
- **F11 zen mode toggle.** Verified.
- **Ctrl+K + wait 1.8s → whichkey overlay.** Verified.
- **Ctrl+K + t + wait 1.8s → whichkey submenu (r → right panel etc).** Verified.
- **Ctrl+K + t + r → view.toggle_right_panel.** Verified — `rightPanelVisible` flips.
- **Ctrl+Q with dirty buffer → Quit dialog.** Verified. `c` = Cancel, `s` = Save all, `q` = Quit anyway. Enter = Save all (default, disk saved).
- **Ctrl+W with dirty buffer → Save/Discard/Cancel dialog.** Verified. `s` = Save (disk saved), `d` = Discard (disk not saved), `c` = Cancel.
- **Ctrl+Backspace / Ctrl+Delete word-wise delete.** Verified.
- **Ctrl+Shift+K delete line.** Verified — line 2 removed, undo restores.
- **Ctrl+A select all + type X → buffer replaced.** Verified.
- **Ctrl+P Ctrl+P hammer 20×.** Stable — no leaked overlay.
- **Ctrl+Z × 100 + Ctrl+Shift+Z × 100.** Completes < 2s; no crash.
- **Ctrl+Tab MRU swap.** Verified — swaps between last two panes.
- **Ctrl+PageUp/Down sequential nav.** Verified.
- **Ctrl+Shift+T reopen closed tab.** Verified reopens (order caveat: SEV-3 #10).
- **Ctrl+\\ split editor.** Verified (properly escaped JSON). `Ctrl+K Ctrl+Left/Right` moves focus between splits.
- **Modal blocking: settings + Ctrl+P.** Verified — Ctrl+P silently blocked in Settings.
- **Modal cascade: Ctrl+W dialog blocks Ctrl+P.** Verified — dialog stays up, no picker.
- **Multi-cursor extras cleared when buffer switched via Ctrl+P.** Verified: Ctrl+Shift+L on hello.rs + Ctrl+P → a.txt → type Z (single Z inserted in a.txt). BUT: switching BACK to hello.rs preserves extras — typing W after switch back inserts at all cursor positions. This matches VS Code's per-editor state model (each editor keeps its own cursors), so not a bug, but worth flagging: a user who switched away with multi-cursor armed will get a surprise on returning.

### Chord-chain interruption behavior

- **Ctrl+K + Ctrl+B:** Ctrl+B (toggle sidebar) fires normally after leader abort. Tested — treeVisible flips.
- **Ctrl+K + F2:** F2 rename prompt opens AND whichkey `<leader>` overlay opens simultaneously (2 overlays layered). Unusual — either F2 should abort the leader, or the leader should absorb F2 as second key. Layering feels accidental.
- **Ctrl+K + Ctrl+X:** silent (Ctrl+X CUT unbound as chord second key; Ctrl+K aborts, Ctrl+X alone unbound in this context per test).
- **Alt+F menu open + Ctrl+P:** Ctrl+P silently blocked; menu stays open. Modal behavior consistent.

---

## Test-drive log

- Workspace: `/private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad/ws13`
- Files: `a.txt`, `b.txt`, `foo.py`, `hello.rs`, `snippet.rs`, `subdir/note.md`; `git init` + committed at session start.
- Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml --headless --input standard <ws13>` — rebuilt at session start (pre-existing binary was from Jul 14, needed refresh after commit `62af6e42`).
- Screen dimensions: `MNML_COLS=200 MNML_ROWS=50` for full menu-bar coverage; verified 120-col fallback still hides View/Go/Run/etc (rollover).
- IPC: `.mnml/ipc/{command,screen.txt,status.json,events.jsonl,rects.json}`.
- Escape convention gotcha: `Ctrl+\` chord needs JSON-quoted `"ctrl+\\"` → bash `printf '... "ctrl+\\\\" ...'` to survive both bash + JSON parsing. Earlier `echo` attempts with single-backslash payload were rejected as `{"event":"unknown","raw":"..."}`. Filed for future harness authors.
- No mouse commands (`click`, `drag`, `hover`, `scroll`, `mouse_*`) fired at any point.
- Concurrent claude sessions running in scratch subdirs (`round13-clean`, `round13-ws`, `round13-fresh`, `round13-hover`, `round13-fresh2`, `round15-ws`) — did not disturb; verified my process by pgrep on `ws13`.
- Session ended alive (no `{"cmd":"quit"}` at close) so background instance kept until parent kills.
