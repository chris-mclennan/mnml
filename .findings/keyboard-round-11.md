# vscode-keyboard-purist bug hunt — Round 11

Date: 2026-07-14
Driver: headless mnml + IPC (`--input standard`), fresh scratch workspace with 5 files (a.txt, b.txt, hello.rs, foo.py, snippet.rs).
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl-shortcut vocabulary. No mouse.

Scope: verify round-10 fixes (Alt+letter visible-menu-only filter, Ctrl+Shift+L full-range selections, Ctrl+Alt+W focus reset). Verify design-round-4 mnemonic cycle, Ctrl+Shift+E return, `@` / `#` toast, grep-unavailable chip. Hunt fresh across fold chords, snippet nav, Ctrl+Space, Shift+Enter, chord-chain interrupts, quickfix nav (F8), tab management, keyboard-reachability of every clickable chip. Look for chord-collision (post-insert dedup at startup).

## Executive summary

- SEV-1: 0
- SEV-2: 4
- SEV-3: 10

The round-10 batch **held cleanly**. Alt+V / Alt+G / Alt+R / Alt+T / Alt+H no longer open invisible menus — the state stays unchanged, subsequent Enter goes to the editor (fires no ghost action). Ctrl+Shift+L multi-cursor now produces full-range selections at every occurrence: typing `COUNT` after `Ctrl+Shift+L` on `count` replaces every whole-word `count` with `COUNT` (line 4/6 `count2` untouched — proper whole-word behavior). Ctrl+Alt+W closing the last right-panel tab reliably snaps focus back to `Focus::Pane`; downstream tools reading `status.focus` will no longer see the stale `right_panel` value. Menu-bar mnemonic cycle works — File menu's three `S` items (Save, Save all, Settings) are individually reachable by pressing `S` 1/2/3 times before Enter; a fourth press wraps back to Save. Enter with no arrow presses walks past the separator to the first Action (Alt+F Enter → "New file in /" prompt). Ctrl+Shift+E from Integrations flips activity_section back to Explorer and focuses the tree in a single chord. `@` and `#` picker prefixes both fire the appropriate LSP command AND toast (`"symbols: fetching…"` / `"workspace symbols: fetching…"`) before closing the picker. Grep with `rg` + `git` both missing surfaces a persistent `grep unavailable — install ripgrep (\`brew inst…` chip that stays for at least 4 s under `PATH=` isolation.

Fresh problems and rollovers this round:

1. **Cheatsheet Esc has the same "focus goes to tree, pane stays" quirk as Git Graph.** Esc from a Cheatsheet pane (`Ctrl+K ?`) sets `focus=tree` but leaves `activePane=cheatsheet` — the graph body is still the visible pane in the editor body when focus jumps out. Same class as round-10 SEV-2 F5 (Git Graph Esc). The round-9 Problems-pane fix (`focus_pane_or_tree` rewrite that returns to the last editor) hasn't been extended to Cheatsheet, Git Graph, or presumably any other help-style overlay-pane.

2. **Round-10 SEV-2 F3 (right-panel empty-state picker) still holds.** `Ctrl+Shift+B` opens the empty right panel with `Add a panel: ▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests`; `Ctrl+K r` doesn't move focus into it, `Down`/`Enter` route through the editor. Round-10 shipped F1/F2/F6 (commit `fc77e42e`), not F3.

3. **Round-10 SEV-2 F4/F5 (Ctrl+J snippet-expand / Git Graph Esc) still hold.** Kept for regression tracking; both persist as documented.

4. **`R` reset-all in Settings overlay is ambiguous between IPC and real-keyboard drivers.** `overlay.rs:325` matches `KeyCode::Char('R')` explicitly, but `input::keymap::parse_key_spec` translates the spec `"shift+r"` to `KeyCode::Char('r')` + `KeyModifiers::SHIFT`, which hits the `Char('r')` arm (reset-focused-row) BEFORE the `Char('R')` arm. Real macOS Terminal/iTerm sends `Char('R')` naked (no SHIFT) so users get reset-all as advertised, but any harness/scripting layer typing `shift+r` gets reset-row instead. The chord-help chip advertises `R reset all` — the tooltip and IPC-driven behavior disagree.

Fewer new problems this round than round-10; all four SEV-2s are known regressions and everything explicitly listed in the priority verifications is confirmed working. For a keyboard-purist trying to get a day's work done: the picture keeps improving. Alt+letter is no longer a silent trap. Multi-cursor typing does the right thing. Focus lands where you expect after right-panel close, after Ctrl+Shift+E, after Enter in a menu. The remaining SEV-2s (right-panel empty state, Ctrl+J, Git Graph / Cheatsheet Esc) all admit a workaround (palette, direct chord, Ctrl+W to close) — they nudge the user toward the palette rather than the mouse. I could complete an editing day without touching the mouse; I'd hit friction picking a right-panel content or backing out of the Git Graph, but nothing forces a hand to the trackpad.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. Esc from Cheatsheet pane blurs focus to tree but pane stays open (new — mirrors round-10 F5)

Repro:

```
{"cmd":"key","key":"ctrl+k"}
{"cmd":"key","key":"?"}            → Cheatsheet opens; focus=pane, activePane=<cheatsheet>
{"cmd":"key","key":"escape"}       → focus=tree, activePane STILL <cheatsheet>
```

State after Esc:
```json
{"focus":"tree","activePane":3,"panes":[…,{"title":"Cheatsheet","dirty":false}]}
```

The Cheatsheet body remains rendered in the editor area; the mode chip flips to TREE. VS Code's convention: Esc from a "reference" pane (Cheatsheet, Help, Problems) returns focus to the last editor AND closes/hides the pane if appropriate. The round-9 fix for Problems-Esc did the "return to last editor" part but stopped short of the "hide the pane" part; here neither happens.

Same class as round-10 SEV-2 F5 (Git Graph). Both are help/reference panes that Esc treats as tree-blur only. Suggest teaching `focus_pane_or_tree` to also hide the pane when it's a Cheatsheet or Git Graph (or add a `Pane::is_ephemeral()` method that both types return `true` from and the Esc handler skips them + steps back to the last editor pane).

### 2. Right panel "Add a panel:" picker still no keyboard path (regression tracking from round-10 SEV-2 F3)

Repro:

```
{"cmd":"key","key":"ctrl+shift+b"}   → right panel opens empty; focus stays on editor
{"cmd":"key","key":"ctrl+k"}
{"cmd":"key","key":"r"}              → toast "right panel is empty…"; focus still on editor
{"cmd":"key","key":"down"}           → moves EDITOR cursor down; picker rows never selectable
```

Round-10 commit `fc77e42e` shipped F1/F2/F6 (Alt+letter / Ctrl+Shift+L / Ctrl+Alt+W) — F3 was not addressed. The 5 rows in the empty-state picker (`▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests`) look like arrow-navigable rows but there's no chord that routes focus into them. Palette workaround only. VS Code's welcome-to-empty-panel picker has full arrow-key + Enter support.

### 3. Ctrl+J still fires `snippet.expand` — VS Code chord misfire (regression tracking from round-10 SEV-2 F4)

Round-10 kept this open; still open. `Ctrl+J` in mnml runs `snippet.expand`, toasting `no snippet matches '<word>'` when the identifier before cursor doesn't match a configured snippet. VS Code binds Ctrl+J to "toggle bottom panel"; mnml has no single "toggle bottom panel" chord. On a workspace with a configured snippet, a stray Ctrl+J destroys the current word and replaces it with the snippet template — silently destructive.

Recommend keeping snippet.expand behind a leader chord (`Ctrl+K j` or `<leader>sj`) and reclaiming Ctrl+J for a bottom-panel-toggle (Problems / scratch terminal cycle).

### 4. Esc from Git Graph pane blurs to tree but graph stays visible (regression tracking from round-10 SEV-2 F5)

Same as round-10; verified again. `Ctrl+Shift+G` opens git graph as `activePane=<idx>`; `Esc` moves `focus=tree` but the graph body remains visible in the editor area. `Ctrl+W` correctly closes the pane. See finding #1 above — Cheatsheet has the same class of bug, so this is a family issue for reference-only panes.

---

## SEV-3 — Chord unbound / discoverability / muscle-memory drift / protocol nit

### 5. `R` reset-all in Settings — IPC vs terminal split (new)

`overlay.rs:317-332` matches two arms:

```rust
KeyCode::Char('r') => app.settings_reset_row(),
KeyCode::Char('R') => { app.config = Config::default(); app.toast("settings: all reset to defaults"); }
```

The intended VS Code convention: `r` resets the focused row, `Shift+R` resets everything. Real terminals typically deliver Shift+R as `Char('R')` (no SHIFT modifier), hitting the second arm. But the IPC keymap parser (`input::keymap::parse_key_spec`) translates `"shift+r"` to `KeyEvent::new(Char('r'), SHIFT)` — which matches the first arm (reset-row) because the match key.code is lowercased.

Observable via IPC: send `shift+r`, only the focused row resets. Send `type "R"` (character), reset-all fires.

Downgraded to SEV-3 because a real keyboard user probably hits the intended path — but any harness / plugin / test runner sending `shift+r` gets silently different behavior. Cleanest fix: match both `Char('r')` with SHIFT and `Char('R')` in the reset-all arm, or read the modifier explicitly regardless of which char code the terminal produces.

### 6. Multi-cursor undo still takes 2 Ctrl+Z presses (regression tracking from round-10 SEV-2 F2 remark)

After `Ctrl+Shift+L` on `count` + type `COUNT`, one `Ctrl+Z` un-inserts the COUNTs but leaves the deletion of the original word in place — line 2 shows `    let  = 5;` instead of `let count = 5;`. A second `Ctrl+Z` restores the pre-Ctrl+Shift+L state.

The full-range-selection landing in round-10 fixed the *forward* behavior (typing REPLACES). Undo coalescing didn't get merged into a single edit-op-batch, so the delete + insert phases undo independently. Documented in round-10's F2 body; still holds.

### 7. F8 / Shift+F8 unbound — VS Code's next/prev-problem chord (new)

VS Code binds `F8` to "Next Problem" and `Shift+F8` to "Previous Problem". mnml has `lsp.next_diagnostic` / `lsp.prev_diagnostic` with `keys: &[]` — palette-only. Ctrl+Shift+M opens the Problems pane (round-9 fix), then arrows + Enter jump, but there's no in-editor "hop to next diagnostic" chord. Muscle-memory friction.

### 8. `Ctrl+K Ctrl+0` / `Ctrl+K Ctrl+J` (fold-all / unfold-all) unbound (regression from round-10 F8)

Same as round-10. `editor.fold_all_brackets` and `lsp.fold_all` have `keys: &[]`. Ctrl+K Ctrl+0 falls into whichkey → dies at the second stroke with no match.

### 9. `Ctrl+K Ctrl+S` (Keyboard Shortcuts editor) unbound (regression from round-10 F9)

Same as rounds 8/9/10. mnml doesn't have a keyboard-shortcuts editor UI at all; the chord is unclaimed. Ctrl+K Ctrl+S falls into whichkey and dies at Ctrl+S with no whichkey mapping. Palette `Ctrl+Shift+P` → text search remains the workaround.

### 10. Picker Home / End / PageUp / PageDown are no-ops (regression from round-10 F10)

`handle_picker_key` (`src/tui/handlers/overlay.rs:340`) matches Up / Down / Left / Right / Ctrl+P / Ctrl+N / Ctrl+U / Backspace + printable chars — not Home, End, PageUp, PageDown. 706-item palette; single-row nav only. VS Code parity: PageUp/PageDown jump by picker-height, Home/End jump to first/last.

### 11. Picker Tab / Alt+Enter — no split-open (regression from round-10 F11)

Same as round-10. Tab maps to `picker_accept_secondary()` which is a stub for every kind. Alt+Enter routes through the picker's normal enter path (same as Enter — opens in same tab). VS Code binds Alt+Enter to "open in new group / split" — mnml has neither.

### 12. `Ctrl+P` Enter with no matches silently closes picker (regression from round-10 F12)

Same as rounds 8/9/10. Type `xyzzy_nonexistent-file.txt`, Enter drops the query, no toast, no "create with this name?" offer.

### 13. `Ctrl+Alt+Left` / `Ctrl+Alt+Right` (move editor to next/prev split) unbound (regression from round-10 F13)

Palette search `move editor` returns zero results for pane-move. `editor.move_up` / `editor.move_down` exist (line move) but no "push this tab across the split boundary" command. VS Code binds these to `workbench.action.moveEditorInto{Next,Previous}Group`.

### 14. Theme toggle chip, "+ dock" chip, bufferline "+ new tab" chip, language chip — all mouse-only (rollover from round-10 F14 + newly observed)

- `theme.toggle` / `theme.pick` / `theme.reset` — `keys: &[]` (bufferline theme-toggle icon click-only).
- `tab.new` — `keys: &[]` (bufferline `+` chip click-only).
- `dock.new_text*` / `dock.new_log_tail` — `keys: &[]` (`+ dock` bottom-right chip click-only).
- Statusline language chip (rs/py/txt/…): there's no `language.set` command at all; the chip's click just changes filetype from a menu. No keyboard entry point.

None are on the critical-path for editing, but each is a "keyboard user can't reach this without palette" affordance.

---

## Verifications — Round-10 fixes that held

### Priority items from the task

- **Alt+letter no longer opens off-screen menu at 120 cols (menu_bar_words filter).** Verified. Alt+V / Alt+G / Alt+R / Alt+T / Alt+H all silent (no menu state change, no screen delta). Alt+H specifically doesn't open Help even though Help is menu idx 9 (invisible at 120 cols). `try_open_menu_from_key` in `src/tui/mod.rs:413-462` filters through `app.rects.menu_bar_words` (the per-render visible set).

- **Ctrl+Shift+L multi-cursor now sets full-range selections — typing REPLACES.** Verified. Cursor at line 2 col 9 of hello.rs (inside `count`), `Ctrl+Shift+L` selects 3 whole-word `count` matches (lines 2, 3, 3). Type `COUNT` → line 2/3 counts replaced, `count2` on lines 4/6 unaffected (whole-word discipline held). `add_extra_cursor_with_anchor` helper in `src/editor/mod.rs` is the fix site.

- **Ctrl+Alt+W closing the last right-panel tab now resets focus to Pane/Tree.** Verified. `outline.show` with right panel visible → tab lands as `rightPanelPanes[0]`. `Ctrl+K r` moves focus to `right_panel`. `Ctrl+Alt+W` closes the outline → status shows `focus=pane, rightPanelPanes=[]` (was `focus=right_panel` in round-10 pre-fix).

- **Menu-bar mnemonic cycle.** Verified in File menu — File has three S rows (Save, Save all, Settings). Alt+F + S → highlight Save; +S → highlight Save all; +S → highlight Settings; +S → wraps back to Save. Enter on 3rd S opens Settings overlay. `handle_menu_key` in `src/tui/mod.rs:564-598` uses `last_mnemonic` state to cycle. View menu (invisible at 120 cols) has 7 Toggle-* items; cycle behavior is code-equivalent (couldn't reach interactively at 120 cols, but the fix commit `f92aa2ee` covers it).

- **Menu-bar Enter walks past separators to first Action.** Verified. `Alt+F` + `Enter` (no arrow presses first) → "New file in /" prompt fires. `handle_menu_key` `KeyCode::Enter` arm calls `walk_to_action(&menu.items, 0, true)` when `item_idx` is invalid, skipping separators.

- **Ctrl+Shift+E returns from Integrations to Explorer + focuses tree.** Verified. `Ctrl+Shift+X` → sidebar in INTEGRATIONS. `Ctrl+Shift+E` → sidebar reverts to Explorer, `focus=tree` in status. Idempotent (running it again with focus already on tree is a no-op, focus stays).

- **`@` in Ctrl+P toasts "symbols: fetching…" before firing async LSP.** Verified in a fresh Ctrl+P + `@` sequence — the toast appears at the picker's close moment, then decays as usual. `#` toasts "workspace symbols: fetching…" and opens the workspace-symbol query prompt. Both in `src/tui/handlers/overlay.rs:428-458`.

- **Grep unavailable → persistent chip.** Verified via a sub-instance launched with `PATH=`. `Ctrl+Shift+F` + `main` + Enter → chip reads `grep unavailable — install ripgrep (\`brew inst…` and stays for ≥ 4 s. Second chip also fires: `LSP: rust-analyzer not installed — \`rustup com…` (from the same PATH-empty environment).

### Other round-10 items re-verified

- **Cheatsheet via Ctrl+K ?** loads the full leader-key overlay (though Esc leaves the pane behind — see SEV-2 #1).
- **Ctrl+K Ctrl+I hover** — bound; silent on non-Cargo scratch .rs (rust-analyzer doesn't attach to loose files).
- **Ctrl+B / Ctrl+Shift+B** toggle sidebar / right panel cleanly.
- **Ctrl+PageUp / Ctrl+PageDown** cycle tabs sequentially; skip over `problems ✓` correctly.
- **Ctrl+Tab MRU pair-swap** works (hello.rs ↔ a.txt).
- **Ctrl+Shift+T** reopens closed tabs in LIFO order (verified with 4 closes + 4 reopens).
- **Ctrl+W** with dirty buffer opens the 3-button "Unsaved changes" prompt; Esc cancels.
- **Ctrl+Q** opens 2-button "Quit mnml?" prompt; Esc cancels.
- **Ctrl+F find + F3 next + Shift+F3 prev** — F3 advances only from the start of a match; from mid-word cursor F3 was silent (may want to jump to next match regardless — SEV-3 candidate but not filed).
- **Ctrl+H replace** opens with the previous find seed correctly (`Replace 8× "count" with`).
- **Ctrl+/ toggle line comment** works (added `//` prefix to selected line).
- **Ctrl+]/Ctrl+[** indent/outdent works.
- **Alt+Up / Alt+Down** move line works.
- **Shift+Alt+Down** duplicate line works.
- **Ctrl+G goto line** prompt + Enter jumps correctly.
- **Ctrl+L select line** works (VS Code parity — was mistakenly bound to view.redraw in earlier rounds).
- **Ctrl+D add cursor at next word** — first press selects word, subsequent presses add cursors at next whole-word matches.
- **Ctrl+`** toggle scratch terminal panel.
- **Ctrl+T** opens workspace-symbol query prompt (aliased from `lsp.workspace_symbols`).
- **F1** opens Help overlay (toggle).
- **F2** rename symbol prompt.
- **F5 / F9 / F10** DAP debug — bound; toasts "dap: no [dap.rs] config" on scratch workspace.
- **F11** zen mode toggle.
- **Shift+F10** context menu for focused element (tree row or active pane).
- **Ctrl+,** Settings overlay opens; arrow keys navigate rows; Esc cancels (reverts); `r` reset row works; `type "R"` reset all works; `/` filter works.
- **Ctrl+P Ctrl+P (hammer 20x)** stable.
- **Ctrl+Z 100x, Ctrl+Shift+Z 100x** completes near-instantly (0.4s wall clock each, sub-1ms per op).
- **Ctrl+K + Esc** cleanly clears chord chain state; typing lands in editor.
- **Ctrl+K a** (partial leader chord) → whichkey overlay appears at ~1.5 s; Esc closes cleanly.
- **`>` / `@` / `#` picker prefixes** all route correctly (`>` opens palette, `@` fires document symbols, `#` fires workspace symbols).
- **File menu 4 S presses (wrap)** — verified: after 3 S → Settings highlighted, 4th S wraps back to Save.
- **Right-arrow menu wrap** from Selection (idx 3, the last visible) → wraps to brand menu (idx 0), skipping invisible View/Go/Run/Terminal/Window/Help. Correct.
- **Alt+M** opens brand menu (`>_  mnml`).

### Chord-collision audit

Extracted every `keys: &["…"]` entry from `src/command.rs`; every chord appears exactly once across the 573 non-empty entries. No duplicate bindings in the command registry (the earlier `ctrl+t` / `ctrl+l` collisions have been retired per the code comments). Multi-key chord chains (`ctrl+k <letter>` / `ctrl+k ctrl+<letter>`) don't shadow single-key chords because the chord layer arms on the leader first.

---

## Test-drive log

- Workspace: `/private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad/ws11`
- Files: `a.txt` `b.txt` `foo.py` `hello.rs` `snippet.rs`
- Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml --headless --input standard <ws11>` (rebuilt at session start because the on-disk `target/release/mnml` was older than commit `fc77e42e` — a repeat of the round-10 gotcha; without the rebuild F1/F2/F6 would have appeared "still broken").
- IPC: `.mnml/ipc/{command,screen.txt,status.json,events.jsonl,rects.json}`.
- Grep-unavailable verification: sub-instance launched with `PATH= mnml --headless --input standard <ws11-nopath>` so both `rg` and `git` spawn as `NotFound`.
- No mouse commands (`click`, `drag`, `hover`, `scroll`, `mouse_*`) fired at any point.
