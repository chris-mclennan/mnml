# vscode-keyboard-purist bug hunt — Round 10

Date: 2026-07-14
Driver: headless mnml + IPC (`--input standard`), fresh scratch workspace with 4 files (a.txt, b.txt, hello.rs, foo.py).
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl-shortcut vocabulary. No mouse.

Scope: verify round-9 fixes (Ctrl+Shift+E returns to Explorer, `@`-toast in Ctrl+P, persistent grep-unavailable chip, menu-bar mnemonics + Enter-past-separators, Ctrl+D multi-cursor, Esc from Problems). Explore multi-step chords (Ctrl+K variants), F-keys, arrow-motion in overlays, tab management, LSP flows, keyboard reachability of every clickable chip, escape hatches from every panel type.

## Executive summary

- SEV-1: 0
- SEV-2: 6
- SEV-3: 8

The round-9 batch **held up cleanly**. Ctrl+Shift+E now switches the sidebar activity to Explorer *and* focuses the tree even from Integrations (`view.focus_tree` command was extended to call `set_activity_section(Explorer)` first). `@` in Ctrl+P toasts `symbols: fetching…` before firing the async LSP request. Ctrl+Shift+F grep with both `rg` and `git` missing surfaces a **persistent** `grep unavailable — install ripgrep` chip that stays until dismissed (verified by running under `PATH=` empty). Alt+F menu mnemonic letters (N/O/S) fire the matching item and close the menu without leaking. Enter from the File menu after a fresh keyboard-open walks past separators and fires the first Action. Ctrl+D on a word selects the word then adds cursors at each next match on subsequent presses. Esc from Problems returns to the last editor.

Fresh problems this round:

1. **Alt+letter opens off-screen menus with no visual feedback.** The menu bar knows 10 menus (File / Edit / Selection / View / Go / Run / Terminal / Window / Help + Brand) but at 120 cols the paint code only lays down whatever fits before a right-side chip cluster — Selection typically the last. Yet `Alt+V` / `Alt+G` / etc. still SET `menu_open` to the invisible menu index and swallow subsequent keystrokes. Enter fires the invisible menu's first Action blind. Right-arrow past the last-visible menu also silently moves selection into the invisible pool.

2. **Ctrl+Shift+L (Select all occurrences) fires but extra cursors have no selection — typing INSERTS instead of REPLACING.** `select_all_occurrences` calls `add_extra_cursor(start)` for each match, discarding the word's end. `add_extra_cursor` sets `extra_anchors[i] = Some(cursor)` — a zero-length selection. Typing then inserts at the word start (before the matched text) instead of replacing the selected word. Result: `count` → `COUNTcount` at every extra-cursor position. VS Code parity is destroyed.

3. **Right panel "Add a panel:" picker has no keyboard path.** `Ctrl+K r` opens the right panel + says "right panel is empty" if it has no panes. Focus stays on the editor. The empty-state body shows five clickable rows (Outline / Problems / AI chat / Grep / Tests) with palette hints. No keyboard chord routes focus into the picker rows, no `Down`/`Enter` navigates them.

Ctrl+J still fires `snippet.expand` — the round-9 SEV-2 #6 chord-misfire holds. VS Code parity would put "toggle panel" here. Escape from Git Graph is still the round-9 half-blur (focus goes to tree, graph pane stays visible in the editor body). Palette Home/End/PageUp/PageDown remain no-ops in the 706-item palette (round-9 SEV-3 #11).

For a keyboard-purist trying to get a day's work done: mnml is *close* — the round-9 wave rounded off the biggest sharp edges (Ctrl+Shift+E, `@`, mnemonics, Ctrl+D, Esc from Problems) and Ctrl+K variants are broadly discoverable through the cheatsheet. But the invisible-menu-bar + Ctrl+Shift+L + right-panel-empty-state gaps are the kind of thing that make a user drop back to the palette + mouse when they hit them. Fewer than round-9's 8 SEV-2s, but the surface still hasn't reached "I can pretend the mouse is unplugged" polish.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. Alt+V / Alt+G / Alt+R / Alt+T / Alt+W / Alt+H silently open OFF-SCREEN menus

At 120-column width (default headless size), the menu bar only paints the menus that fit before the right-side chip cluster. Repro:

```
Terminal cols: 120
Menu bar visible: File, Edit, Selection
Menu bar hidden: View, Go, Run, Terminal, Window, Help
```

Keyboard-only user presses `Alt+V` expecting the View menu to open:

```
{"cmd":"key","key":"alt+v"}   → no visible change on screen
{"cmd":"key","key":"enter"}    → the FIRST action of the invisible View menu fires
                                (in the current mnml, that's view.discovery → the click-hints overlay)
```

Root cause: `try_open_menu_from_key` (`src/tui/mod.rs:434`) sets `app.menu_open = Some(MenuOpenState::new_keyboard(i))` for **any** matching menu, ignoring whether the menu is currently rendered. Then `ui::menu_bar::draw_dropdown` bails at `app.rects.menu_bar_words.iter().find(|(_, i)| *i == open.menu_idx)` returning None, because the invisible menu never registered a word rect. Menu is open in state, not in pixels.

Same class:
- Right-arrow from Selection (idx 3) → advances to View (idx 4), still invisible. Third `Right` press "closes" the menu visually (open moved past visibility) but state is `menu_open = Some(View)`. Any subsequent printable char is swallowed by the invisible menu's mnemonic search.
- Alt+letter opens ANY of the 10 menus regardless of visibility.

Two-side fix: either skip invisible menus in Right/Alt-letter navigation (VS Code convention: shrink the bar or overflow into a `»` chevron), OR clamp `menu_open.menu_idx` to the visible set (a Selector like `MENUS[visible_idx]`).

### 2. Ctrl+Shift+L (Select all occurrences) → extra cursors have no selection; typing pollutes text

Cursor at line 2 col 9 on `hello.rs` (inside the word `count`). Ctrl+Shift+L. Expected VS Code behavior: every occurrence of `count` gets a fresh selection, typing `COUNT` replaces all. Actual:

```
Before:
  2     let count = 5;
  3     println!("count: {}", count);
  4     let count2 = count + 1;

After Ctrl+Shift+L, type "COUNT":
  2     let COUNT = 5;                                    ← primary cursor: selection REPLACED
  3     println!("COUNTcount: {}", COUNTcount);           ← extras: INSERTED at word start
  4     let count2 = COUNTcount + 1;                      ← extra: INSERTED at word start
```

The primary cursor at `hits[0]` gets `set_selection(first_s, first_e)` — a full selection over the word — and typing correctly deletes the selection first. The other extras (`hits.iter().skip(1)`) go through `b.editor.add_extra_cursor(*s)` — which passes only the START byte, never the END. Inside `add_extra_cursor`, `extra_anchors.push(Some(b))` where `b == cursor`; the resulting "selection" is length zero. On insert, nothing gets deleted → the typed text stacks in front of the still-present word.

Repro (`src/app/find.rs:335`):

```rust
for (s, _e) in hits.iter().skip(1) {
    b.editor.add_extra_cursor(*s);   // ← discards `_e`!
}
```

The `_e` is right there in the tuple. Fix would need an `add_extra_cursor_with_selection(anchor, cursor)` helper OR a bulk `set_multi_selections(&[(s, e), ...])` builder. SEV-2 because the chord LOOKS like it worked (`selected 4 occurrences` toast fires), then silently produces garbage.

Undo compounds the badness: after typing "COUNT" and pressing Ctrl+Z once, line 2 becomes `    let  = 5;` (word `count` deleted, `COUNT` NOT restored) — the coalescing undo doesn't group the multi-cursor operation cleanly. User needs multiple Ctrl+Zs to unwind.

### 3. Right panel "Add a panel:" empty-state picker — no keyboard path

Steps to reproduce (fresh workspace, right panel closed):

```
{"cmd":"key","key":"ctrl+k"}
{"cmd":"key","key":"r"}          → right panel opens; toast "right panel is empty — open Outline / Problems first"; focus stays on pane
```

Screen now shows a right panel body:

```
Add a panel:

▸ Outline  :outline.show
▸ Problems  :lsp.diagnostics
▸ AI chat  :ai.chat
▸ Grep  :find.grep
▸ Tests  :test.run

Hide: Ctrl+Shift+B
```

The `▸` marks look like they should be arrow-key navigable, and each row shows a palette command. But there's no keyboard chord to route focus INTO the picker rows. `Down` / `Up` moves the *editor* cursor (the focus never landed in the panel). `Enter` doesn't fire. Only path: `Ctrl+Shift+P` → type `outline.show` → Enter. VS Code's welcome-to-empty-panel picker has full arrow-key + Enter support.

Contrast with `Ctrl+K r` when the panel HAS a pane already: focus does land in `Focus::RightPanel` and Esc returns cleanly. The gap is specifically the empty state.

### 4. `Ctrl+J` still fires `snippet.expand` — VS Code chord misfire (regression tracking from round-9)

Kept for regression tracking. VS Code binds Ctrl+J to "toggle bottom panel." mnml binds it to `snippet.expand`. The chord is destructive when the user just typed a trigger word — the word gets replaced by a snippet template instead of the panel toggling. `Ctrl+` covers terminal panel role; `Ctrl+Shift+M` covers Problems; there's no single "toggle bottom panel" chord.

### 5. Esc from Git Graph (Ctrl+Shift+G) blurs to tree but leaves graph visible (regression tracking from round-9)

Kept for regression tracking. Round-9's SEV-2 #3. Esc from the git-graph pane moves focus to the tree (mode chip flips TREE) but the graph pane stays as the active pane in the editor body. The "esc back to editor" semantic that landed for Problems in round-9 hasn't been extended to the graph pane. Confirmed by:

```
{"cmd":"run-command","id":"git.graph"}       → focus=pane, activePane=<graph>
{"cmd":"key","key":"esc"}                     → focus=tree, activePane still <graph>
                                                (graph body still visible)
```

Suggested treatment: teach `focus_pane_or_tree` (`src/app/layout.rs:1862`) to also blur out of the graph pane, OR have Esc-in-graph close the graph outright.

### 6. Ctrl+Alt+W closes right-panel tab but focus doesn't reset — subsequent typing is ambiguous

After opening Outline in the right panel and running `Ctrl+K r` → focus=right_panel, hitting `Ctrl+Alt+W` closes the outline tab (correct — `right_panel_panes` shrinks to `[]`). But `focus` stays as `right_panel` even though the right panel now has zero panes:

```json
{"focus":"right_panel","rightPanelPanes":[],"panes":[{"title":"hello.rs"}]}
```

Typing `X` after this state DID land in the editor (line 1 got `HI`-prefixed correctly in my repro), so the typing dispatch has a fallback path. But `status.focus` publishes `right_panel` — misleading to any downstream tool reading it. Cleaner is to snap focus back to `pane` (or `tree` when no editor is open) at the moment the last right-panel pane closes.

---

## SEV-3 — Chord unbound / discoverability / muscle-memory drift

### 7. Menu bar arrow-key highlight is color-only — text-only screen dumps can't see it (informational)

Round-9's SEV-2 #1 claimed "no visible selection cursor" in the menu after arrow-key navigation. Code review shows `row_highlight_menu()` (`src/ui/design_tokens.rs:138`) applies `bg(cyan) + fg(bg_dark) + BOLD` — a color-based highlight that a real terminal renders but the ratatui `TestBackend` character dump can't show. Downgraded to SEV-3 informational: in an actual ghostty/wezterm terminal the highlight IS visible; the round-9 finding was inaccurate about "no highlight applied at all". Left in report so future rounds don't re-file it.

### 8. `Ctrl+K Ctrl+0` / `Ctrl+K Ctrl+J` (fold-all / unfold-all) unbound (regression from round-9 SEV-3 #9)

Same as round-9. `editor.fold_all_brackets` and `lsp.fold_all` have `keys: &[]`. Ctrl+K Ctrl+0 falls into `<leader>` whichkey then dies at the second stroke.

### 9. `Ctrl+K Ctrl+S` (Keyboard Shortcuts editor) unbound (regression from round-9 SEV-3 #10)

Same as rounds 8 & 9. Falls into `<leader>` chord chain. mnml doesn't have a keyboard-shortcuts editor UI — palette + `Ctrl+,` + text-search is the workaround.

### 10. Picker Home / End / PageUp / PageDown are no-ops (regression from round-9 SEV-3 #11)

Same as round-9. 706-item palette; only `Up` / `Down` / `Ctrl+P` / `Ctrl+N` navigate one row at a time. `handle_picker_key` (`src/tui/handlers/overlay.rs:340`) doesn't match Home/End/PageUp/PageDown — they fall through to no-op.

### 11. Picker `Tab` = documented no-op (regression from round-9 SEV-3 #12)

Same as round-9. `picker_accept_secondary()` is a stub for every kind. VS Code binds Alt+Enter in Ctrl+P to "open in new group / split" — mnml has neither Alt+Enter nor Tab wired.

### 12. `Ctrl+P` Enter with no matches silently closes picker — no "create file" prompt (regression from round-9 SEV-3 #13)

Same as round-9. Typing `nonexistent-file-xxx.txt` → Enter drops the query, no toast, no "create with this name" offer.

### 13. `Ctrl+Alt+Left` / `Ctrl+Alt+Right` (move editor to next/prev split) unbound

VS Code binds these to "Move editor into next group" / "prev group". mnml uses Ctrl+Alt+Up / Ctrl+Alt+Down for AddCursor-Above/Below, and Ctrl+Alt+Left/Right for nothing. A keyboard-only user who splits with `Ctrl+\` then wants to push a tab across splits has to palette-search "move editor" → nothing matches (no such command exists). SEV-3 because the workflow is niche.

### 14. `+ dock` bottom-right empty-state chip is mouse-only

When `App::dock_widgets` is empty, mnml paints a discoverability `+ dock` chip at the bottom-right of the editor body (`src/ui/dock.rs:32`). Click fires a new-widget picker. No keyboard chord — palette has `dock.new_text` / `dock.new_text_br` / `dock.new_text_tl` / `dock.new_text_tr` / `dock.new_log_tail` but none are bound. A pure-keyboard user has to palette their way in. SEV-3 because the affordance itself is optional.

---

## Verifications — Round-9 fixes that held

### Priority items from the task

- **Ctrl+Shift+E → sidebar Explorer + focus tree.** After `Ctrl+Shift+X` puts sidebar into INTEGRATIONS, `Ctrl+Shift+E` correctly flips `active_section` back to Explorer, tree body reappears, focus lands on tree. Round-9's SEV-2 #4 (the "one-way trap") is FIXED. The command `view.focus_tree` was extended to call `set_activity_section(Explorer)` before `focus_tree()`.

- **`@` in Ctrl+P picker toasts `symbols: fetching…` before firing lsp.symbols.** Verified: after `Ctrl+P` + type `@`, picker closes and a `symbols: fetching…` toast appears immediately. Round-9's SEV-2 #8 (silent close on empty LSP) is FIXED.

- **Ctrl+Shift+F with rg + git missing shows persistent chip.** Verified by launching `PATH= mnml --headless …` (empty PATH) so both `rg` and `git` fail to spawn. Chip reads `grep unavailable — install ripgrep (\`brew inst…` and stays for at least 5 s (persistent, not toast). Round-9's SEV-2 #7 is FIXED.

- **Alt+F menu mnemonic letters (N/O/S) fire matching item + close menu.** Verified: after `Alt+F`, `N` opens the "New file in /" prompt AND the menu closes. `O` closes menu (dispatched picker.files but the observable state after was the pre-existing tree — action fired without a visible affordance because picker.files is a preview toggle). `S` closes menu (dispatched file.save — silent since file wasn't dirty). No mnemonic letter leaks into the buffer under any menu. Round-9's SEV-2 #1 letter-leak part is FIXED.

- **Enter from Alt+F walks past separators to first Action.** After `Alt+F` + `Enter` with no prior arrow presses, "New file in /" prompt opens (New file is the first Action, followed by Open file… + Open folder… + Separator + Save + …). Confirmed Enter is no longer eaten. Round-9's SEV-2 #1 walk-past-separator part is FIXED.

- **Ctrl+D → editor.add_cursor_at_next_word.** First Ctrl+D on `count` selects the word (cursor jumps 8→13). Second Ctrl+D adds a cursor at the next `count` occurrence. Third adds another. Typing at that point modified all `count` instances (line 2 + line 3 twice) with `count` in `count2` untouched (whole-word match). Round-9's SEV-2 #5 is FIXED.

- **Esc from Problems (Ctrl+Shift+M) returns to last editor.** Verified: `activePane` was 1 (problems), Esc → `activePane=0, activeFile=hello.rs`, focus=pane. Round-9's SEV-2 #2 is FIXED via `focus_pane_or_tree` re-write.

### Other round-9 items re-verified

- **Ctrl+K r → focus right panel** works when the panel has hosted panes (`focus=right_panel`). Toasts when empty.
- **Shift+F12 → lsp.references** fires but async-silent (LSP not warmed up in scratch workspace).
- **F11 → Zen mode** enters, `Esc` exits. Still holds.
- **Ctrl+B / Ctrl+Shift+B** toggle sidebar / right panel cleanly.
- **Ctrl+Shift+T** reopens closed tab.
- **Ctrl+Tab MRU pair-swap** works. `Ctrl+PageUp` / `Ctrl+PageDown` sequential works.
- **Shift+F10 opens the context menu** for focused element — tree row menu when focus=tree, tab menu when focus=pane. Both Esc cleanly.
- **Cheatsheet via Ctrl+K ?** loads the full leader-key list.
- **Whichkey via Ctrl+K + timeout** shows the leader help overlay; Esc closes.
- **Ctrl+G goto line** prompt + Enter jumps correctly.
- **Ctrl+F find + F3 next** work.
- **Ctrl+H replace** opens with previous find seed correctly.
- **Ctrl+/ toggle line comment** works.
- **Alt+Down move line** works; **Shift+Alt+Down duplicate line** works.
- **Ctrl+Shift+K delete line** works.
- **Ctrl+, opens Settings** overlay; arrow keys navigate rows; Esc cancels.
- **Ctrl+W on dirty file** opens the 3-button Unsaved changes prompt (Save / Discard / Cancel); Esc cancels.
- **Ctrl+P Ctrl+P (hammer 20x)** stays stable — the picker opens on first press and subsequent Ctrl+P's move selection up (VS Code parity).
- **Ctrl+K a t** whichkey chord chain opens a shell pane (verifies chord-chain feed-through fix from round-8).
- **prompt cursor navigation** — Left / Right / Home / End all work inside overlay prompts (e.g., `Ctrl+N`'s New file prompt honors Home + insertion in the middle).
- **Ctrl+Z 100 times, Ctrl+Y 100 times** — no perceptible lag, no state corruption.

---

## Test-drive log

- Workspace: `/private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad/ws10`
- Files: `a.txt` `b.txt` `hello.rs` `foo.py`
- Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml --headless --input standard <ws10>` (rebuilt at the start of the session — the release binary was older than the round-9 source-code fix; without the rebuild `Ctrl+Shift+E` would have appeared "still broken" — noted as a session gotcha).
- IPC: `.mnml/ipc/{command,screen.txt,status.json,events.jsonl,rects.json}`
- Grep-unavailable verification run in a sub-instance launched via `PATH= mnml --headless --input standard <ws10>` so both `rg` and `git` spawn as `NotFound`.
- No mouse commands (`click`, `drag`, `hover`, `scroll`, `mouse_*`) fired at any point.
