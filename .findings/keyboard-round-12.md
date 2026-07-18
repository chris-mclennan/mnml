# vscode-keyboard-purist bug hunt — Round 12

Date: 2026-07-14
Driver: headless mnml + IPC (`--input standard`), fresh scratch workspace with 6 files (a.txt, b.txt, hello.rs, foo.py, snippet.rs, subdir/note.md).
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl-shortcut vocabulary. No mouse.

Scope: verify round-11 fixes (cheatsheet Esc → `focus_pane_or_tree`, settings shift+R dual-driver). Verify all round-10/11/design-round-4 items. Hunt fresh across chord-chain interruptions, every `Ctrl+K <letter>` follow-through, right-panel empty-state picker keyboard reach, search/replace overlays, palette mode switches, undo/redo boundaries, and any other newly-uncovered SEV-2s. No source edits.

## Executive summary

- SEV-1: 0
- SEV-2: 4
- SEV-3: 10

Round-11's two shipped fixes both **hold cleanly**. Cheatsheet Esc via `focus_pane_or_tree` returns focus to the last editor pane (activePane 0 = hello.rs) — no more "focus=tree, cheatsheet visible" trap; the pane still lingers as a background tab (arguably intentional, since the round-11 commit explicitly kept the "hide the pane" question for later). Settings dual-driver reset-all works under BOTH `{"cmd":"key","key":"shift+r"}` (IPC keymap → `Char('r') + SHIFT`) AND `{"cmd":"type","text":"R"}` (naked `Char('R')`, no SHIFT): the modified `[relative] *` mark clears and Line numbers snaps back to `[absolute]` in either path. Plain `r` still resets only the focused row.

The rest of the priority verifications also hold: Alt+V / Alt+H / Alt+G no longer open invisible menus. Ctrl+Shift+L multi-cursor + typing `COUNT` produces a whole-word replace across every `count` (line 4/6 `count2` untouched). Ctrl+Alt+W closing the last right-panel tab snaps `focus=pane`. Ctrl+Shift+E from Integrations returns to Explorer + focuses the tree. `@` / `#` picker prefixes fire the LSP calls with the "symbols: fetching…" / "workspace symbols: fetching…" toast. Menu-bar mnemonic cycle works (Alt+F → 3× S → Settings; 4th S wraps). Right-arrow from Selection wraps to brand menu; Left-arrow from brand wraps to Selection.

Fresh problems and rollovers this round:

1. **Undo does NOT clear multi-cursor selection state (new SEV-2).** After `Ctrl+Shift+L` on `count` + type `X` + `Ctrl+Z` restores buffer content correctly — but the extra cursors are still armed. Typing a single character afterward inserts it at every dormant cursor position. Reproduces on both hello.rs and a.txt. Only `Esc` clears the cursor extras; `Ctrl+Z` doesn't. VS Code's convention is that Ctrl+Z restores buffer AND selection state; mnml peels them apart.

2. **`Ctrl+`` opens the scratch terminal but has no keyboard close path (new SEV-2).** First `Ctrl+`` opens the strip. Second `Ctrl+`` while focused in the pty → the shell receives a literal backtick (mnml's key handler forwards to the pty before checking the toggle chord). `Esc` blurs (`focused=false`), but the toggle logic in `toggle_scratch_term` only closes when `focused=true` — so subsequent Ctrl+` presses just refocus in a loop. Palette `term.scratch_toggle` works. The chip line reads `scratch · Esc blurs · \`term.scratch_toggle\` closes` — accurate but confirms the chord is one-way. VS Code's Ctrl+` is a true toggle (open/close regardless of focus).

3. **Git Graph Esc still uses `focus_tree()` not `focus_pane_or_tree()` (round-11 SEV-2 #4 rollover, not addressed by the cheatsheet fix).** Ctrl+Shift+G → git graph opens as pane N; Esc → `focus=tree, activePane=N` (graph body still visible). Same class as the cheatsheet bug that was fixed in commit `80c46716`. The fix touched Cheatsheet only; `src/tui/handlers/pane.rs:2033` (git graph Esc) is unchanged. The family didn't get the refactor.

4. **Right panel empty-state picker still has no keyboard focus path (round-11 SEV-2 #2 rollover).** `Ctrl+Shift+B` opens right panel with the 5-row `Add a panel: ▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests` picker. Ctrl+K r (leader r) does nothing (goes to whichkey submenu that expects a follow-up), Tab / F6 / Ctrl+2 all silent. `Down` / `Enter` route to the editor. Palette workaround: `>outline show` etc. Round-11 F2 not shipped.

The picture keeps improving for a keyboard-purist but has a real regression this round — the undo/multi-cursor state leak is a genuine data-integrity risk (a stray keystroke after Ctrl+Z can silently write to 4 places). The scratch terminal close chord is the second real chord-misfire this hunt has found; both make it harder to close things with the keyboard alone. That said, none of the SEV-2s make a full editing day impossible — the palette (`Ctrl+Shift+P`) is a reliable workaround for the terminal close, and multi-cursor undo just needs an `Esc` reflex. I could still get through a day without touching the mouse; I'd just develop finger-memory for `Esc` after any multi-cursor operation and for the palette to close the terminal.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. Undo restores buffer but leaves multi-cursor state active (new)

Repro (fresh headless standard-mode session, hello.rs open):

```
{"cmd":"key","key":"ctrl+g"} → 2 → enter          # cursor to line 2
{"cmd":"key","key":"home"} + 8× right             # cursor at col 9 (inside "count")
{"cmd":"key","key":"ctrl+shift+l"}                # 3 whole-word "count" selections
{"cmd":"type","text":"COUNT"}                     # replace all → OK
{"cmd":"key","key":"ctrl+z"} ×N                   # undo everything (2 presses per round-11 F6)
                                                   # buffer restored to pristine
{"cmd":"type","text":"X"}                         # ← single X keystroke
```

Observed: `X` is inserted at 4 positions across lines 3/5/7:

```
1 fn main() {
2     let count = 5;                              # unmarked (cursor was here)
3     let countX2 = 6;                            # X inserted
4     let another = count + count2;
5     println!("count={}", count)X;               # X inserted
6     let value = another;
7     prXintln!("vXalue={}", value);              # X inserted TWICE (multi extras)
8 }
```

Expected (VS Code): after Ctrl+Z restores the buffer AND selection state, typing X should insert once at the primary cursor position.

Actual: buffer restored, multi-cursor extras kept. Undo history doesn't include cursor-state snapshots.

Only `Esc` (which calls `clear_extras` implicitly via the selection-clear handler) restores single-cursor behavior. Every user who habitually hits Ctrl+Z after a multi-cursor edit will lose data the next time they type. This is the same class as round-11 F6 (undo takes 2 presses because delete+insert are separate edit-op batches) but strictly more dangerous — F6 was cosmetic, this is a silent corruption.

Fix sketch: teach `undo` / `redo` to snapshot `Editor::extras` alongside the text edit batch, and restore it on rollback. Alternatively, clear `extras` on any undo/redo boundary (simpler, less "vscode-correct" but safer).

### 2. `Ctrl+`` opens scratch terminal but never closes via keyboard (new)

Repro:

```
{"cmd":"key","key":"ctrl+`"}                     # scratch strip opens, focused=true
{"cmd":"key","key":"ctrl+`"}                     # shell receives backtick char (not toggle!)
{"cmd":"key","key":"escape"}                     # focused=false, focus=Pane on editor
{"cmd":"key","key":"ctrl+`"}                     # scratch strip re-focuses (not closes)
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"ctrl+`"}                     # re-focuses again
… loop forever
```

Root cause (from `src/tui/mod.rs:1587-1599`):

```rust
if let Some(scratch) = app.scratch_term.as_mut() && scratch.focused {
    if key.code == KeyCode::Esc { scratch.focused = false; return; }
    let bytes = crate::app::dispatch::pty_key_bytes(key);
    if !bytes.is_empty() { scratch.session.write_bytes(&bytes); }
    return;                                        # ← Ctrl+` never reaches keymap
}
```

The scratch-focused branch swallows every non-Esc keystroke (including Ctrl+`) into the pty. So the `toggle_scratch_term` close branch (`if s.focused { self.scratch_term = None }` at `src/app/mod.rs:...`) is unreachable via the chord.

The header chip `scratch · Esc blurs · \`term.scratch_toggle\` closes` is telling the user exactly what works (palette command) and what doesn't (the chord). Kudos for the honesty, but the chord it advertises to open the pane (Ctrl+`) is a one-way trip; VS Code's is a true toggle.

Fix sketch: whitelist `Ctrl+`` in the pty-forward branch — check the code+modifier before consulting `pty_key_bytes`; if it matches the toggle chord, `return` after firing `toggle_scratch_term()` on the app.

### 3. Git Graph Esc still routes to `focus_tree()` — cheatsheet fix wasn't extended to the family (round-11 SEV-2 #4 rollover)

Repro:

```
{"cmd":"key","key":"ctrl+shift+g"}   # git graph opens as pane 4; focus=pane, active=4
{"cmd":"key","key":"escape"}         # focus=tree, activePane=4, graph body still visible
```

State after Esc:
```json
{"focus":"tree","activePane":4,"panes":[…,{"title":"git graph","dirty":false}]}
```

`src/tui/handlers/pane.rs:2033` reads `KeyCode::Esc => app.focus_tree()` — the cheatsheet fix (`focus_pane_or_tree`) wasn't applied to the sibling Git Graph handler. Family bug — the round-11 commit only touched Cheatsheet.

The `focus_pane_or_tree` helper is already generic enough (`.iter().filter_map(|(i,p)| matches!(p, Pane::Editor(_)).then_some(i)).next()` — finds the first editor pane, falls back to tree). Swapping the call in git graph, git status, spend report, image, websocket, DAP panes, flaky panes, grep, etc. (I count 8+ `KeyCode::Esc => app.focus_tree()` sites in `pane.rs`) would extend the round-11 fix consistently. The current situation is a partial fix that only helps if the user opened Cheatsheet, not the far more common Git Graph.

### 4. Right panel empty-state picker still has no keyboard focus path (round-11 SEV-2 #2 rollover)

Repro:

```
{"cmd":"key","key":"ctrl+shift+b"}   # right panel opens with 5-row picker; focus=editor
{"cmd":"key","key":"tab"}            # focus=pane (unchanged)
{"cmd":"key","key":"f6"}             # focus=pane (unchanged; F6 unbound)
{"cmd":"key","key":"ctrl+2"}         # focus=pane (unchanged; VSCode's secondary-sidebar focus)
{"cmd":"key","key":"ctrl+k"} + r     # ambiguous (leader r is under +toggle submenu); no toast
{"cmd":"key","key":"down"}           # moves EDITOR cursor down; picker rows never selectable
```

Round-11 F2 explicitly flagged this and it wasn't addressed. The 5 rows (`▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests`) look arrow-navigable but there's no chord that reaches them. VS Code binds `Ctrl+Alt+B` to "Toggle Secondary Side Bar" and `Cmd+K Cmd+B` to focus/blur — mnml doesn't have a "focus right panel picker" chord.

Workarounds all bypass the picker: `Ctrl+Shift+P` → search for e.g. `outline show`, or Ctrl+K + O runs outline via a chord chain. The picker itself remains mouse-only.

---

## SEV-3 — Chord unbound / discoverability / muscle-memory drift / protocol nit

### 5. `outline.show` doesn't move existing outline into right panel when re-run (new)

Repro:

```
{"cmd":"run-command","id":"outline.show"}   # outline opens as editor split (right panel not visible)
{"cmd":"key","key":"ctrl+shift+b"}          # right panel opens (empty picker)
{"cmd":"run-command","id":"outline.show"}   # outline retargets in-place; panel still empty
```

State: `rightPanelPanes=[]` even though `right_panel_visible=true` and outline pane exists.

Root cause (from `src/app/lsp.rs:585-602`): the "already open ⇒ retarget + refresh" branch fires `reveal_pane(id)` for the middle-split outline instead of `right_panel_push(id)` when the panel is visible. Only fresh outlines (no prior pane) get pushed. CLAUDE.md's Right-panel v3 status says "when the panel is visible, `outline.show` and `lsp.diagnostics` route into the panel instead of splitting the editor body" — but the "already open" case is a gap.

Workaround: `Ctrl+W` to close the middle-split outline, then `outline.show` re-fires the fresh-open branch → now correctly pushes to right panel. Two chords instead of one.

### 6. Multi-cursor undo still takes 2 Ctrl+Z presses (round-11 F6 rollover)

Same as round-11 — first Ctrl+Z removes the inserted COUNTs but leaves the delete of `count`; second restores. Since finding #1 above is worse (undo leaves cursors armed), fixing #1 first is the priority; F6 becomes moot if #1's fix also snapshots undo boundaries.

### 7. F8 / Shift+F8 unbound — VS Code's next/prev-problem chords (round-11 F7 rollover)

`lsp.next_diagnostic` and `lsp.prev_diagnostic` still have `keys: &[]`. Ctrl+Shift+M opens the Problems pane; F8/Shift+F8 do nothing. Muscle-memory friction.

### 8. `Ctrl+K Ctrl+0` / `Ctrl+K Ctrl+J` (fold-all / unfold-all) unbound (round-11 F8 rollover)

`editor.fold_all_brackets` and `lsp.fold_all` still have `keys: &[]`. Ctrl+K Ctrl+0 falls into whichkey (armed after Ctrl+K) and silently dies at the second stroke with no match.

### 9. `Ctrl+K Ctrl+S` (Keyboard Shortcuts editor) still unbound (round-11 F9 rollover)

mnml still doesn't have a keyboard-shortcuts editor UI. `Ctrl+K Ctrl+S` chord absorbed into whichkey after leader, dies silently. Palette (`Ctrl+Shift+P` → text search) remains the workaround.

### 10. Picker Home / End / PageUp / PageDown are no-ops (round-11 F10 rollover)

`handle_picker_key` in `src/tui/handlers/overlay.rs:340` still only matches Up/Down/Left/Right/Ctrl+P/Ctrl+N/Ctrl+U/Backspace/printable. Home/End/PageUp/PageDown pressed inside a 706-item palette or a 6-item file picker → no navigation. VS Code parity: PageUp/PageDown jump by page-height, Home/End jump to first/last.

### 11. Picker Tab / Alt+Enter — no split-open (round-11 F11 rollover)

Tab in the file picker calls `picker_accept_secondary()` which is a stub for every kind. Alt+Enter routes through the primary Enter path (opens in same tab). VS Code binds Alt+Enter to "open in new group / split" — mnml has neither hook. Palette workaround: run `view.split_right` first, then `Ctrl+P` a file into that split.

### 12. `Ctrl+P` Enter with no matches silently closes picker (round-11 F12 rollover)

Type `zzzzznonexistent` in Ctrl+P → `(no matches)` display; Enter → picker closes with no toast, no "create with this name?" offer. VS Code shows a small "Create new file" affordance when the query is a valid filename pattern with zero matches.

### 13. Ctrl+Shift+F retains the previous query as seed — creates concatenation (new)

Repro:

```
{"cmd":"key","key":"ctrl+shift+f"}          # opens "Grep workspace" prompt (empty)
{"cmd":"type","text":"count"} + enter        # fires grep, opens results pane
… cancel results, no explicit clear
{"cmd":"key","key":"ctrl+shift+f"}           # reopens; query field seeded with "count"
{"cmd":"type","text":"count"} + enter        # actual query becomes "countcount" (0 matches)
```

The retained seed is helpful when refining a query, but a fresh Ctrl+Shift+F usually means "new search" — an empty seed with the previous as a `<C-r>0`-style register recall would be more discoverable. Or clear on Esc.

### 14. Non-git workspace + missing rg → misleading "git grep: no matches" toast (new)

Repro (in a workspace with no `.git/`, and `rg` not on PATH):

```
{"cmd":"key","key":"ctrl+shift+f"}
{"cmd":"type","text":"count"} + enter
```

Toast: `git grep: no matches for "count"` — but there ARE matches, git grep is running in a non-git dir where it errors out. Round-11 F7-verified the persistent chip `grep unavailable — install ripgrep (\`brew inst…` for the "both tools missing" case, but the "git installed, workspace not a git repo, rg missing" case falls through to a false-negative toast. mnml should detect the exit code / stderr and either fall back to a plain `find + grep` or emit `grep unavailable (workspace is not a git repo)`.

---

## Verifications — Round-11 fixes that held

### Priority items from the task

- **Cheatsheet Esc returns to last editor via `focus_pane_or_tree`.** Verified. `Ctrl+K ?` → Cheatsheet pane opens (pane 1); `Escape` → `focus=pane, activePane=0, activeFile=hello.rs`. The Cheatsheet pane lingers as a background tab (not hidden) — matches the round-11 commit's scope. Fix site: `src/app/layout.rs:1862` `focus_pane_or_tree`.

- **Settings Shift+R fires reset-all under BOTH `shift+r` (IPC) AND naked `R` (real terminal).** Verified. Fresh Settings + focus Line numbers row + `left` to modify → `[relative] *`. Then:
    - `{"cmd":"key","key":"shift+r"}` → row snaps back to `[absolute]`, `*` gone. ✓
    - Re-modify + `{"cmd":"type","text":"R"}` (naked R via type dispatch) → same behavior. ✓
    - Re-modify + `{"cmd":"type","text":"r"}` → resets only focused row (single). ✓
  All three paths agree. Fix site: `src/tui/handlers/overlay.rs:325-332` — `Char(c) if c.eq_ignore_ascii_case(&'r') → if SHIFT || c == 'R' { reset-all }`.

- **Alt+letter visibility filter (round-10 F1).** Verified. Alt+V / Alt+G / Alt+H silent at 120-col headless width; menu state unchanged, no ghost action on subsequent Enter.

- **Ctrl+Shift+L full-range multi-cursor (round-10 F2).** Verified. From line 2 col 9 inside `count`, `Ctrl+Shift+L` selects 3 whole-word `count` matches; typing `COUNT` replaces each in-place; `count2` on lines 3/4 untouched.

- **Ctrl+Alt+W focus reset (round-10 F6).** Verified. Outline lands as `rightPanelPanes[0]` after `outline.show` with panel visible; `Ctrl+K r` focuses right panel; `Ctrl+Alt+W` closes it → `focus=pane, rightPanelPanes=[]`.

- **Menu-bar mnemonic cycle.** Verified. Alt+F menu (File) has three S rows (Save, Save all, Settings). After Alt+F + S + Enter → saves (verified: dirty=false after saved toast). After Alt+F + S + S + S + Enter → opens Settings. 4th S wraps back to Save.

- **Menu-bar Enter walks past separators.** Verified. Alt+F + Enter (no arrows first) → opens `New file in /` prompt (skips separators between the header and the first action).

- **Ctrl+Shift+E returns from Integrations to Explorer + focuses tree.** Verified. Ctrl+Shift+X → sidebar in INTEGRATIONS. Ctrl+Shift+E → sidebar reverts to Explorer, `focus=tree`.

- **`@` / `#` picker prefixes emit fetching-toast + fire LSP.** Verified. Ctrl+P + `@` → toast `symbols: fetching…` visible for the picker's close moment. Ctrl+P + `#` → toast `workspace symbols: fetching…` + opens the workspace-symbol query prompt.

- **Menu Left/Right wrap (design-round-4).** Verified. Alt+M then right×4 → wraps around Selection back to brand. Alt+M then left → wraps to Selection (rightmost visible).

### Other round-11 items re-verified

- **Ctrl+F find + Enter jumps to first match; F3 / Shift+F3 walk after Enter.** Verified. Note: F3 pressed **before** Enter is a no-op (cursor stays) — Enter must be the "first match jump" trigger. Consider auto-jumping to first match on typing (VS Code convention) — mild SEV-3 candidate, not filed.
- **Ctrl+H replace opens as `Find (Enter → Replace)` two-stage prompt.** Verified.
- **Ctrl+Shift+F workspace grep + git-repo workspace.** Verified — works after `git init && git add -A && git commit`.
- **Ctrl+/ toggle line comment.** Verified.
- **Alt+Up / Alt+Down move line.** Verified.
- **Shift+Alt+Down duplicate line.** Verified.
- **Ctrl+D add cursor at next word.** Verified.
- **Ctrl+L select line.** Verified.
- **Ctrl+G goto line.** Verified.
- **Ctrl+Home / Ctrl+End.** Verified.
- **F1 opens Help overlay; Esc closes cleanly.** Verified.
- **F2 rename prompt.** Verified.
- **Ctrl+. quick fix.** Fires silently (no LSP → no code actions to offer). Chord bound, LSP context missing.
- **F5 DAP debug.** Bound; toasts `dap: no [dap.rs] config` on scratch.
- **F11 zen mode toggle.** Verified.
- **Ctrl+, Settings.** Verified. `/` focuses filter; typing narrows; `r` reset row; `R` reset all; `shift+r` reset all; Esc cancels.
- **Ctrl+P Ctrl+P (hammer 20x).** Stable — no leaked overlay.
- **Ctrl+Z 100x + Ctrl+Shift+Z 100x.** Completes in ~1.5s wall clock; no lag.
- **Ctrl+K + Esc.** Cleanly clears chord chain.
- **Ctrl+K + wait 1.6s.** Whichkey `<leader>` overlay appears with all 24 top-level bindings visible.
- **Ctrl+K + h + wait 1.6s.** `<leader> h` (+http) submenu appears with 5 sub-bindings.
- **Ctrl+K + g + wait 1.6s.** `<leader> g` (+git) submenu appears with 16 bindings.
- **Ctrl+K Ctrl+O opens workspace picker.** Verified.
- **Ctrl+K Ctrl+P opens file picker (same as Ctrl+P).** Verified.
- **Ctrl+K b fires `git.blame_toggle`.** Verified — toasts `computing blame… → git blame returned nothing (untracked file?)` on the fresh git repo.
- **Ctrl+K w fires `write/save`.** Verified — saved dirty buffer.
- **Ctrl+Q opens Quit dialog; Esc cancels.** Verified. Buttons `Save/Discard/Cancel` on dirty-close prompt reachable via hotkey letters (S/D/C) — but no Tab-cycle indicator visible in screen.txt (color-only highlight).
- **Ctrl+W with dirty buffer opens Save/Discard/Cancel prompt.** Verified.

### Chord-chain interruption behavior

- **Back-to-back `Ctrl+K` + printable letter (no gap):** silent for unbound letters (n, x, z), fires bound command for bound letters (h/g/f open submenus after whichkey delay). No key leaks to the editor buffer.
- **`Ctrl+K` + `Ctrl+K`:** whichkey overlay opens.
- **`Ctrl+K` + top-level chord (`Ctrl+P` / `Ctrl+B`):** interrupt handled correctly — file picker opens / sidebar toggles.
- **`Ctrl+K` (armed) + printable when whichkey overlay is up:** letter routes to whichkey (opens submenu or dies) — does NOT leak to editor buffer.
- **`Ctrl+K` + `h` (rapid) + printable typing HELLO:** in an earlier iteration where multi-cursor extras were left over from a prior Ctrl+Shift+L test, HELLO's `L L O` were typed at multiple cursor positions (see SEV-2 #1 — that's actually the multi-cursor extras leak, not a chord-chain issue).

### Right-panel focus check

`Ctrl+K r` (with panel empty) — silent, no toast, no focus change. `Tab`, `F6`, `Ctrl+2`, `Down` all route through editor. Confirmed no keyboard path into the empty picker.

---

## Test-drive log

- Workspace: `/private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad/ws12`
- Files: `a.txt` `b.txt` `foo.py` `hello.rs` `snippet.rs` `subdir/note.md`; `git init` + committed mid-session for grep testing.
- Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml --headless --input standard <ws12>` — rebuilt at session start because the on-disk `target/release/mnml` (15:09) predated commit `c6fef50e` (16:07). Same gotcha as rounds 10 and 11.
- IPC: `.mnml/ipc/{command,screen.txt,status.json,events.jsonl,rects.json}`.
- No mouse commands (`click`, `drag`, `hover`, `scroll`, `mouse_*`) fired at any point.
- Session ended with `{"cmd":"quit"}` — clean shutdown.
