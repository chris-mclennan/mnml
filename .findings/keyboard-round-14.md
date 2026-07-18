# vscode-keyboard-purist bug hunt — Round 14

Date: 2026-07-16
Driver: headless mnml + IPC (`--input standard`), fresh scratch workspace with 7 files (a.txt, b.txt, hello.rs, foo.py, snippet.rs, subdir/note.md, .gitignore), `git init` + committed. 140-col screen (200 for menu-bar coverage; 120 for narrow-fallback verify).
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl-shortcut vocabulary. No mouse.

Scope: verify round-13 priority items (undo clears multi-cursor extras; Ctrl+` from focused scratch; cheatsheet Esc; Settings Shift+R dual driver; menu-bar mnemonic cycle & separator walk; Ctrl+Shift+E cycle; `@`/`#` picker toasts; grep unavailable chip; Alt+letter narrow-width visibility; Ctrl+Shift+L extras full-range selections; Ctrl+Alt+W right-panel close+focus). Hunt fresh: chord conflicts inside a focused Pty pane (SIGNIFICANT), Esc semantics after multi-cursor, undo-grouping for Replace-all, close_prompt (dirty-close) button focus, silent chord absorbs across every modal type, chord chain reachability from tree focus.

## Executive summary

- SEV-1: 0
- SEV-2: 5 (2 new + 3 rollovers)
- SEV-3: 9 (2 new + 7 rollovers)

All 11 round-13 priority verifications **hold cleanly**. The undo-clears-extras behavior is intact (Ctrl+Shift+L on `count` → type "X" → Ctrl+Z → type "Y" only inserts once at primary cursor; extras are dropped). Full-range multi-cursor selection also holds — typing "COUNT" after Ctrl+Shift+L replaces the whole word at every extra (no `COUNTcount` regression). Ctrl+` from a FOCUSED scratch pty correctly closes it (round-12 fix). Cheatsheet Esc snaps back to the last editor via `focus_pane_or_tree` (activePane=0, focus=pane) — the cheatsheet header text "Esc → tree" is stale (now goes to pane instead), noted SEV-3. Settings Shift+R AND naked `R` both reset all rows (the `*` modified markers vanish under both drivers). Menu-bar `Alt+V T` fires Toggle file tree; `Alt+V TT + Enter` fires Toggle right panel (mnemonic cycle + separator walk both work at 200 cols). Ctrl+Shift+E returns from Integrations to Explorer + focuses tree. `@` in Ctrl+P toasts "symbols: fetching…"; `#` toasts "workspace symbols: fetching…". Alt+V at 120 cols is a clean no-op (View menu truncated off-screen; no phantom open). Ctrl+Alt+W closes a right-panel tab and snaps focus back to activePane=0 / focus=pane. Chord chain `Ctrl+K + t + r` from tree focus fires `view.toggle_right_panel` cleanly (round-12 whichkey-tree fix holds).

Ripgrep unavailability chip was NOT reachable in this hunt: my scratch workspace is a git repo and `git grep` succeeded (4 hits fell out cleanly), so the toast_persistent("grep.unavailable", …) path in `src/app/grep.rs:147` never fires. Code inspection confirms the message is correctly worded ("grep unavailable — install ripgrep (`brew install ripgrep`) or run in a git repo. Query: <q>") — the persistent chip fires only when BOTH rg is missing AND git grep also fails. Code path verified sound; couldn't exercise via headless without setting up a non-git workspace.

Fresh problems this round:

1. **Ctrl+letter chord conflicts inside a focused Pty pane (new SEV-2, high-impact).** A keyboard user in a shell pane loses 4 essential readline / shell chords that mnml has bound globally: `Ctrl+D` (would send EOF / exit the shell) fires `editor.add_cursor_at_next_word` which silently no-ops on a Pty pane; `Ctrl+K` (would kill-line-forward in bash) opens the whichkey leader overlay; `Ctrl+N` (readline next-history) opens the New-file prompt; `Ctrl+P` (readline previous-history) opens the file picker; `Ctrl+R` (readline reverse-i-search) opens the Recent-files picker; `Ctrl+F` (readline forward-char) silently no-ops (toasts "find only works in editor panes" internally? — no toast observed, just swallowed). Ctrl+A (beginning-of-line) DOES route to shell — confirmed by inserting X at start after Ctrl+A. Ctrl+U (unix-line-discard) DOES route to shell — confirmed. So the pattern is: mnml's global keymap dispatches BEFORE the pty router, and any Ctrl+letter that mnml has bound wins even when a Pty is focused. VS Code has a `terminal.integrated.commandsToSkipShell` list for exactly this — a set of chords the terminal never routes to shell (default excludes Ctrl+D/K/N/P/R/A/E/U). mnml has the opposite gap: it eats those chords everywhere. Impact for a keyboard-purist sibling-tool user: (a) can't exit a shell with Ctrl+D; (b) can't kill-line-forward with Ctrl+K; (c) can't reverse-i-search with Ctrl+R; (d) can't scroll history with Ctrl+P / Ctrl+N. All-day-in-terminal users notice within minutes.

2. **Esc after Ctrl+Shift+L doesn't clear extra cursors (new SEV-2).** Position on `count` line 2 col 12 → Ctrl+Shift+L (3 whole-word hits: line 2, line 4 twice) → Esc → type "X" → all 3 positions still get an X. In VS Code, Esc after multi-cursor selection reverts to the primary cursor. mnml's standard-mode input handler (`src/input/standard.rs:336`) treats Esc as `SelectClear` when `ctx.has_selection` is true — and multi-cursor primary DOES have a selection. So Esc → SelectClear returns as `Ops`, not `Ignored`, which skips the pane.rs `Unhandled(Esc)` path that DOES call `ClearExtraCursors`. Net: after Ctrl+Shift+L, the only way to drop extras is to type something (which fans out) or hit Ctrl+Z. `focus_pane_or_tree` / palette / other chord doesn't reach ClearExtraCursors either. This is a real footgun — a keyboard user commits Ctrl+Shift+L, decides they don't want it, hits Esc, then types a character to see the extras were never cleared. The pane.rs comment at line 2325 explicitly claims "clear extra cursors if multi-cursor mode is active" — but the standard-mode input handler routes Esc as SelectClear before it reaches that logic.

Rollovers still unfixed (round-13 called out; round-14 re-confirms):

3. **Close-buffer dirty dialog has no Tab/arrow cycle and no visible focus indicator (SEV-2 rollover).** `Ctrl+W` on a dirty buffer opens the "Unsaved changes: [Save] [Discard] [Cancel]" dialog. The handler at `src/tui/mod.rs:1972` only accepts `s/S/Enter → Save`, `d/D → Discard`, `c/C/Esc → Cancel`. Tab is a no-op; Left/Right are no-ops. No visible focus indicator on any button. Contrast: PromptKind::QuitConfirm / PromptKind::DeleteConfirm / generic PromptKind confirms all DO handle Tab/Left/Right + BackTab + cursor rotation (`src/tui/handlers/overlay.rs:541-556`). The dirty-close dialog is its own state machine (`app.close_prompt`), not a Prompt, and the Tab-cycle code was never copied over. A keyboard user reading the dialog fresh sees three buttons + `Save` as leftmost, and has NO WAY to reach Discard except by knowing the `d` hotkey.

4. **Chord chords silently swallowed inside every modal prompt (SEV-2 rollover).** Verified: inside Find (Ctrl+F) prompt, `Ctrl+P` / `Ctrl+Shift+P` / `F3` / `Ctrl+F` typed inside the prompt do NOTHING — no picker, no palette, no next-match. Typing after the swallow appends to the query field ("count" + `Ctrl+P` swallow + type "X" = query "countX"). Same holds inside Ctrl+H replace prompt, Ctrl+G goto prompt, F2 rename prompt, Ctrl+Q QuitConfirm dialog, close_prompt dirty dialog, workspace-symbols prompt. No toast / no beep / no indicator that the chord was blocked. VS Code convention: chords tunnel to workspace commands. In mnml, the modal steals then silently drops.

5. **Git Graph pane Esc still `focus_tree()` instead of `focus_pane_or_tree()` (SEV-2 rollover).** `Ctrl+Shift+G` → git graph opens as activePane=4, focus=pane. `Escape` → focus=tree, activePane=4 (git graph still visible but no longer focused). Contrast: Cheatsheet Esc correctly snaps activePane=0, focus=pane. Round-11 introduced `focus_pane_or_tree` for the cheatsheet fix; it never got wired to git graph. Round-12 flagged this; round-13 re-flagged; round-14 confirms still unfixed. Outline / Diagnostics Esc gets this right — only Git Graph regressed.

6. **Right-panel empty-state picker has no keyboard focus path (SEV-2 rollover).** `Ctrl+Shift+B` opens the panel with the 5-row `▸ Outline / ▸ Problems / ▸ AI chat / ▸ Grep / ▸ Tests` picker. `Tab` inserts a tab into the editor pane; `Down` doesn't move the picker cursor; `F6` doesn't switch focus. The `Ctrl+K + t + r` chord chain toggles the panel but doesn't focus the picker either. Only workaround is the palette (`Ctrl+Shift+P` → `outline show`).

7. **Home key not smart-toggling to first-non-whitespace (SEV-3 rollover).** VS Code: first `Home` moves to first-non-whitespace of the line; second `Home` moves to col 1. mnml jumps straight to col 1. Rollover from prior rounds.

8. **Picker `Home`/`End`/`PageUp`/`PageDown` are no-ops (SEV-3 rollover).** Only Down/Up move the picker cursor. Home/End/PageUp/PageDown are silently absorbed.

9. **`F3` / `Shift+F3` in Find bar don't navigate (SEV-3 rollover).** Must Esc first, then F3 navigates. Inside the find prompt they're swallowed.

10. **`Ctrl+K Ctrl+S` (Keyboard Shortcuts editor), `Ctrl+K Ctrl+U`, `Ctrl+K Ctrl+F`, `Ctrl+K Z`, `Ctrl+0`, `Ctrl+.` (Quick Fix), `Ctrl+Shift+Space` (param hints), `Ctrl+;`, `Ctrl+K W` unbound (SEV-3 rollover).** Not blockers; the palette + cheatsheet cover the alternatives.

11. **`Alt+V` twice doesn't toggle View menu closed (new SEV-3).** VS Code convention: Alt+letter twice closes the menu that Alt+letter opened. In mnml, second Alt+V keeps the View menu open (or re-opens it, same result visually). Only Esc / clicking-elsewhere / picking-an-item closes.

12. **Replace-all is N undo units, not one (new SEV-3).** Ctrl+H → find "count" → replace "COUNT" → 6 replacements. Ctrl+Z only reverts 1 replacement at a time (6 Ctrl+Z's needed to fully undo). VS Code batches Replace-all into a single undo group.

The keyboard-purist story keeps holding at 90%+. The daily loop (open, edit, save, close, switch buffers, split, palette, cheatsheet, LSP hover chord) is fully keyboard-complete. Multi-cursor, comment-toggle, dup-line, move-line, word-nav, buffer-nav via Ctrl+PgUp/PgDn all work. Could I get a day of work done without touching the mouse? **Yes** — with two caveats: (1) if I use a Pty pane for a shell, I have to context-switch out to a hidden non-mnml shell to Ctrl+D/K/R/P/N (real friction for sibling-tool users), and (2) I have to memorize letter hotkeys for the dirty-close dialog (Discard = `d`, Cancel = `c`) because Tab doesn't cycle. Both are round-13 & prior known items that continue to slip.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. Ctrl+letter chord conflicts inside a focused Pty pane (new)

Repro:

```
{"cmd":"open-pty","command":["bash"]}
{"cmd":"key","key":"ctrl+d"}          # expected: bash sends EOF and exits
                                       # actual: silently absorbed (bash still alive with prompt showing)
{"cmd":"key","key":"ctrl+k"}          # expected: bash readline kill-line-forward
                                       # actual: whichkey leader overlay opens
{"cmd":"key","key":"ctrl+r"}          # expected: reverse-i-search
                                       # actual: Recent-files picker opens
{"cmd":"key","key":"ctrl+n"}          # expected: next-history
                                       # actual: New-file prompt opens
{"cmd":"key","key":"ctrl+p"}          # expected: previous-history
                                       # actual: Open-file picker opens
```

Chords that CORRECTLY route to Pty when Pty is focused: `Ctrl+A` (beginning-of-line), `Ctrl+U` (unix-line-discard), `Ctrl+C` (SIGINT), space, letters, backspace, arrows.

Chords that mnml INTENDS to escape from Pty (comment at `src/tui/handlers/pane.rs:2114-2119`): `Ctrl+E` (cycle focus), `Ctrl+B` (tree toggle), Esc (forwarded). Those are documented and correct.

Chords that mnml UNINTENTIONALLY eats before pty routing (all bind to editor-only commands that no-op when active pane is Pty):
- `Ctrl+D` → `editor.add_cursor_at_next_word` (`src/command.rs:876`). `run_editor_op` in `src/app/mod.rs:12654` only fires if `Pane::Editor`; else silent no-op. **User can't Ctrl+D to exit a shell.**
- `Ctrl+K` → `whichkey.leader` (`src/command.rs:5928`). Opens a global overlay. **Kills user's kill-line-forward.**
- `Ctrl+N` → `file.new` (`src/command.rs:2172`). Opens a prompt.
- `Ctrl+P` → `picker.files` (implied via Ctrl+P binding).
- `Ctrl+R` → `picker.recent` (`src/command.rs:2467`).
- `Ctrl+F` → `find.find` (`src/command.rs:728`). Toasts nothing but silently absorbs; typed chars after go to shell but Ctrl+F itself is eaten.

Fix sketch (three options, listed by cost):
1. **Cheap: add a `commandsToSkipShell` list** with Pty-first routing for a hardcoded set (`Ctrl+D`, `Ctrl+K`, `Ctrl+R`, `Ctrl+P`, `Ctrl+N`, `Ctrl+F`). Check active pane BEFORE keymap dispatch — if Pty and key ∈ SKIP_LIST, forward to pty. Palette / whichkey are still reachable via `Ctrl+Shift+P` / `<leader>` (space in vim, `Ctrl+K` isn't the only leader).
2. **Middle: add a config key** `[terminal] commands_to_skip = ["ctrl+d", "ctrl+k", ...]` so users can add / remove chords. Match VS Code's setting exactly.
3. **Full: per-pane keymap** — `PtyKeymap` vs `EditorKeymap` at dispatch time. Big refactor; matches Neovim's `terminal-mode` distinction.

Recommend #1 for a v1 fix — a hardcoded list of ~6 chords, gated at the dispatch entry. Ship with a warning-level toast the first time it fires ("Ctrl+D routed to shell; palette still via Ctrl+Shift+P").

### 2. Esc after Ctrl+Shift+L doesn't clear extra cursors (new)

Repro:

```
{"cmd":"open","path":"hello.rs"}
{"cmd":"key","key":"ctrl+g"} {"cmd":"type","text":"2:12"} {"cmd":"key","key":"enter"}
{"cmd":"key","key":"ctrl+shift+l"}   # 3 whole-word "count" hits selected
{"cmd":"key","key":"escape"}         # user thinks: "actually never mind"
{"cmd":"type","text":"X"}            # observed: X appears at all 3 positions
                                      # expected: X only at primary cursor
```

Root cause: `src/input/standard.rs:336` — when `ctx.has_selection` is true, Esc returns `InputResult::Ops(vec![SelectClear])`. This is a handled result — pane.rs never reaches the `BufferEvent::Unhandled(k)` branch that calls `ClearExtraCursors` (`src/tui/handlers/pane.rs:2339-2348`). Primary cursor DOES have a selection after Ctrl+Shift+L, so the `has_selection` path fires. SelectClear only clears the primary's selection, not the extra cursors' selections.

Fix sketch: three options:
1. In `src/input/standard.rs:336` Esc handler, also emit `ClearExtraCursors` alongside `SelectClear` if extras are present. Requires the ctx to expose `has_extra_cursors: bool`.
2. Make SelectClear op always clear extras too. (Semantic drift — SelectClear could still be used by other paths that DO want to keep extras.)
3. Add a new op `EscapeMultiCursor` that = SelectClear + ClearExtraCursors, emit it from the standard-mode Esc when extras are set.

Also: the pane.rs comment claiming "Esc clears extras if multi-cursor mode is active" is misleading — the path fires ONLY when the input handler returns Unhandled, which the standard handler doesn't do when there's a selection. Either update the comment or actually route through.

### 3. Close-buffer dirty dialog: no Tab cycle, no focus indicator (rollover from round-13)

Repro:

```
{"cmd":"open","path":"hello.rs"}
{"cmd":"key","key":"end"} {"cmd":"type","text":"//x"}   # dirty
{"cmd":"key","key":"ctrl+w"}                             # dialog: Save / Discard / Cancel
{"cmd":"key","key":"tab"}                                # observed: no visible change
{"cmd":"key","key":"right"}                              # observed: no visible change
{"cmd":"key","key":"enter"}                              # fires Save (leftmost, default)
```

Handler location: `src/tui/mod.rs:1972-1980`. Only accepts `s/S/Enter/d/D/c/C/Esc`. Tab, Left, Right, BackTab are not handled.

Contrast: `src/tui/handlers/overlay.rs:541-556` handles Tab/Left/Right/BackTab for QuitConfirm, DeleteConfirm, and every generic confirm-button prompt. The dirty-close dialog is separately managed as `app.close_prompt: Option<PaneId>` (not a `PromptKind`) and never picked up the Tab-cycle refactor.

Fix sketch: (a) Add a `close_prompt_cursor: usize` field to App (default 0). (b) In the handler at `src/tui/mod.rs:1972-1980`, add `Left/BackTab` → cursor = (cursor + 2) % 3 and `Right/Tab` → cursor = (cursor + 1) % 3. (c) `Enter` fires the button at `cursor` (was: fires Save always). (d) In `src/ui/prompt.rs` `close_prompt` draw path (if exists), highlight the cursor button with `row_highlight_menu()`.

Alternative: migrate the close_prompt to use `PromptKind::CloseBufferConfirm` and reuse the generic-confirm handler that already has Tab-cycle. Bigger refactor but cleaner architecturally.

### 4. Chord chains silently swallowed inside every modal prompt (rollover)

Repro:

```
{"cmd":"key","key":"ctrl+f"}                       # Find prompt
{"cmd":"type","text":"count"}                      # query "count"
{"cmd":"key","key":"ctrl+shift+p"}                 # SILENTLY BLOCKED — no palette, no toast
{"cmd":"type","text":"X"}                          # query becomes "countX"
```

Verified same pattern in: Ctrl+H Replace, Ctrl+G Goto, F2 Rename, close_prompt dirty dialog, QuitConfirm dialog, workspace symbols prompt.

Fix sketch: For each of `Ctrl+P`, `Ctrl+Shift+P`, `Ctrl+Shift+F` (palette / picker / grep) — check BEFORE the prompt-handler at `handle_prompt_key`: if key is one of the ~5 top-level palette / picker chords, close the current prompt and fire the chord. Same shape as the `Ctrl+S` intercept at `src/tui/mod.rs:1569-1580`. Alternative: emit a toast ("chord blocked by <prompt>; Esc first") — worse UX but at least eliminates silent-swallow feel.

### 5. Git Graph pane Esc still routes to `focus_tree()` (rollover from round-11/12/13)

Repro:

```
{"cmd":"open","path":"hello.rs"}
{"cmd":"key","key":"ctrl+shift+g"}                # git graph opens as activePane=1, focus=pane
{"cmd":"key","key":"escape"}                      # observed: focus=tree, activePane=1
                                                   # expected: focus=pane, activePane=0 (last editor)
```

Same fix as Cheatsheet Esc landed in round-11. Wire `focus_pane_or_tree()` into the git-graph Esc handler instead of `focus_tree()`.

## SEV-3 — Polish / discoverability

### 6. Cheatsheet header text says "Esc → tree" but Esc actually returns to last editor pane (new)

Screen text at `src/ui/cheatsheet.rs` (implied): header reads `┌ Cheatsheet · / filter · j/k · Esc → tree · Ctrl+W close ──────┐`. After round-11's `focus_pane_or_tree` fix, Esc returns to the last editor. Documentation drift — either update the header to `Esc → back` or `Esc → editor` or `Esc → last pane`.

### 7. Home key not VS Code Smart Home (rollover)

`Home` at line 4 col 20 (`    println!(...)`) jumps to col 1. VS Code: first Home → col 5 (first-non-whitespace); second Home → col 1.

### 8. Picker Home/End/PageUp/PageDown no-op (rollover)

Verified in Ctrl+P Open-file picker. Only Down/Up move selection.

### 9. F3 / Shift+F3 in Find bar don't navigate (rollover)

Inside the find prompt, F3 = no-op. Only after Esc closes the find prompt does F3 walk matches.

### 10. Ctrl+K Ctrl+S / Ctrl+K Ctrl+U / Ctrl+K Ctrl+F / Ctrl+K Z / Ctrl+0 / Ctrl+. / Ctrl+Shift+Space / Ctrl+; / Ctrl+K W unbound (rollover)

All are silently absorbed / no-op. Palette + cheatsheet cover the workaround paths.

### 11. Alt+V twice doesn't toggle View menu closed (new)

VS Code convention: Alt+letter opens menu; Alt+letter again closes it. In mnml, second Alt+V keeps the menu open. Only Esc / picking-an-item / another chord closes.

### 12. Replace-all is N undo units, not one (new)

Ctrl+H → find "count" → replace "COUNT" → 6 replacements in hello.rs. Ctrl+Z reverts 1 replacement at a time. 6 undos needed to fully revert. VS Code batches Replace-all as one undo group.

### 13. Ctrl+K Ctrl+I chord chain fires lsp.hover cleanly (verified good)

Not a finding — confirming chord chains WORK. `Ctrl+K` opens whichkey; `Ctrl+I` inside whichkey resolves the chord chain to `lsp.hover`. Only a no-op here because rust-analyzer isn't running against a Cargo.toml-less workspace.

### 14. Right-panel empty-state picker has no keyboard focus path (rollover)

Documented in round-13; still unfixed. Only palette (`Ctrl+Shift+P` → `outline show`) or the leader chord chain `Ctrl+K + t + r` toggle the panel; nothing focuses the 5-row picker to Enter-select.

---

## Verifications — Round-13 priority items (all HOLD)

- Undo/Redo clears extra cursors: **verified**. Ctrl+Shift+L → type X → Ctrl+Z → type Y → only primary cursor mutates.
- Ctrl+` from focused scratch pty: **verified**. Closes the strip in one press (was: typed literal backtick).
- Cheatsheet Esc → last editor via `focus_pane_or_tree`: **verified** (focus=pane, activePane=0). Header text stale, filed SEV-3 above.
- Settings Shift+R AND naked R reset all: **verified** for both drivers.
- Menu-bar mnemonic cycle: **verified**. `Alt+V T` = Toggle file tree (fires treeVisible=false); `Alt+V TT + Enter` = Toggle right panel (fires rightPanelVisible=true). Fires past `Command palette` (row 0) → `───` separator → Toggle file tree (row 2) confirms separator walk.
- Ctrl+Shift+E from Integrations returns to Explorer + focuses tree: **verified**.
- `@` / `#` picker prefixes toast: **verified**. `@` → "symbols: fetching…"; `#` → "workspace symbols: fetching…".
- Grep unavailable → persistent chip: **code path verified**; couldn't reach via headless without a non-git workspace. Message wording in `src/app/grep.rs:150` is correct.
- Alt+letter at 120 cols: **verified silent no-op**. Alt+V produces no phantom overlay.
- Ctrl+Shift+L multi-cursor extras full-range: **verified**. Typing "COUNT" over 3 selected "count"s produces "let COUNT = 0" / "COUNT={}" / "COUNT" — no leftover `count` fragments.
- Ctrl+Alt+W closes right-panel tab + snaps focus to editor: **verified** (rightPanelPanes=[], activePane=0, focus=pane).
- Chord chain `Ctrl+K + t + r` from tree focus → view.toggle_right_panel: **verified**.
