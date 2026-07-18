# vscode-keyboard-purist bug hunt — Round 9

Date: 2026-07-12
Driver: headless mnml + IPC (`--input standard`), fresh scratch workspace with 4 files (a.txt, b.txt, hello.rs, foo.py).
Persona: VS Code user, standard-mode mnml, keyboard-only. Ctrl-shortcut vocabulary. No mouse.

Scope: verify recently-landed items hold (Ctrl+K r → focus right panel, Shift+F12 → lsp.references, Ctrl+Shift+Space → signature help, Ctrl+Shift+G → git graph, palette recents-at-top, view.reset_tree_width). Explore multi-step chords, panel navigation, palette-mode prefixes (`>`, `@`, `#`), tab management, LSP flows, menu bar keyboard access, find/replace/grep, and Esc-out-of-panel semantics.

## Executive summary

- SEV-1: 0
- SEV-2: 8
- SEV-3: 7

Recently-landed items **mostly hold** — Ctrl+K r successfully focuses the right panel, the palette shows starred recently-used commands at the top, Ctrl+Shift+G opens the git graph, and F11 zen mode works. But a serious cluster of "Esc from a docked panel does nothing visible" bugs (Problems, Git Graph, Integrations sidebar) makes the last-two-inches of the round-7/round-8 escape-hatch story unfinished. Meanwhile the top-of-screen menu bar (Alt+F / Alt+E / Alt+S) advertises a keyboard-openable menu but items are not visually highlighted on arrow, Enter does not fire the highlighted item, and mnemonic letters (N, O, S) leak straight into the editor while the menu is still open — the entire menu-bar keyboard flow is decorative.

Adjacent-but-worse: switching sidebar activity to Integrations via `Ctrl+Shift+X` has **no keyboard chord to return** — `Ctrl+Shift+E` doesn't route the activity back to Explorer, it just re-focuses the tree in whatever section is showing. `view.activity_explorer` command exists but has no default binding, so a keyboard-only user who accidentally hit Ctrl+Shift+X gets to open the palette and type "explorer" to get their files back. Same one-way trap on `Ctrl+Shift+G` — the graph opens, Esc does nothing, only Ctrl+W closes it, and the "esc back" hint at the top of the Problems view is a straight-up lie.

For fresh VS Code muscle memory: Ctrl+D still does not extend to a second occurrence on repeat (mnml's `Ctrl+D` = `SelectWord`, a one-shot; VS Code's = "add cursor at next match"), Ctrl+J fires snippet expansion instead of "toggle panel" (chord misfire), and Ctrl+K Ctrl+0 / Ctrl+K Ctrl+J (fold-all / unfold-all) fall into `<leader>` whichkey. Zoom-out: a keyboard-purist can survive a day, but the menu bar is misleading, several one-way panel traps close the escape hatch, and the "add cursor at next" gap is a daily bruise.

---

## SEV-2 — Chord fires wrong action / no keyboard path / multi-step chord broken

### 1. Menu bar (Alt+F / Alt+E / Alt+S) is decorative — no highlighted item, no Enter, no mnemonics

Alt+F opens the File menu overlay showing seven items (New file / Open file… / Open folder… / Save / Save all / Close tab / Settings… / Quit). None of them are visually highlighted — no `▌` cursor, no reverse-video row, no `▸`. Repro:

```
{"cmd":"key","key":"alt+f"} → File menu opens
{"cmd":"key","key":"down"}   → no visible change
{"cmd":"key","key":"down"}   → no visible change
{"cmd":"key","key":"enter"}  → menu closes; NOTHING fires
{"cmd":"key","key":"alt+f"}  → menu re-opens
{"cmd":"type","text":"N"}    → menu STAYS OPEN and the "N" is inserted into the buffer beneath (typed "}N" into hello.rs on line 6)
```

Three separate keyboard failures in one flow:
1. No visible selection cursor → user can't tell which item Enter would fire.
2. Enter closes the menu without firing anything.
3. Mnemonic characters (N for New file, O for Open, S for Save) leak through the menu into the editor.

For a keyboard-only user this is the single most polished-looking menu bar with **zero** working keyboard behavior. Right-arrow to swap between File / Edit / Selection menus works, so the bar clearly has some keyboard code — just not the item-selection half. VS Code: opens File menu with New File highlighted, arrows move highlight, Enter fires, mnemonic underlined letter fires directly.

### 2. Esc from Problems (Ctrl+Shift+M) does nothing — "esc back" hint is a lie

After Ctrl+Shift+M the diagnostics pane opens as a split at the bottom of the editor area with the row-2 hint `⏎ jump   r refresh   s severity-filter   esc back`. Pressing Esc:

- Fires `focus_pane_or_tree()` (see `src/tui/handlers/pane.rs:1617`).
- `activePane` remains 4 (the diagnostics pane).
- The diagnostics pane stays visible.
- Focus does not return to the previous editor buffer, despite the "esc back" chip and the code comment claiming the round-8 fix "returns focus to the last editor".

The bug is in `focus_pane_or_tree` (`src/app/layout.rs:1857`) — it calls `focus_pane` when `active.is_some()`, which is trivially true because the active pane IS the diagnostics pane. Nothing changes. The user has to Ctrl+W to close, or Ctrl+PgUp/PgDn to switch tabs; there is no "return to previous editor" chord that actually works. Confirmed with two consecutive Esc presses — status.json.activePane never changes.

### 3. Esc from Git Graph (Ctrl+Shift+G) blurs to tree but leaves graph visible

Ctrl+Shift+G opens the git graph pane full-editor-body. The user's only close chord is Ctrl+W. Esc from the graph moves focus to the tree (mode chip flips TREE) but the graph pane stays active in the editor body. No "back to previous editor" behavior. Same class as #2 — Esc is a partial-blur, not a return.

### 4. Ctrl+Shift+X → Integrations, no keyboard chord to return to file Explorer

Ctrl+Shift+X switches the sidebar from the workspace file tree to the Integrations section. `Ctrl+Shift+E` (advertised as "focus file tree") does not route the sidebar back to Explorer — it just refocuses the tree in whatever activity is currently showing, so the user stays in Integrations. There is a `view.activity_explorer` command (`src/command.rs`) but `keys: &[]`. Repro:

```
{"cmd":"key","key":"ctrl+shift+x"}      → sidebar switches to INTEGRATIONS
{"cmd":"key","key":"esc"}                → no effect
{"cmd":"key","key":"ctrl+shift+e"}      → focus goes to Integrations filter row, sidebar STAYS as Integrations
{"cmd":"run-command","id":"view.activity_explorer"}  → NOW the file list returns
```

Only path back is palette-typed "explorer" (or Ctrl+Shift+G / Ctrl+Shift+D to switch to a *different* activity as a workaround). SEV-2 — accidental Ctrl+Shift+X strands the user's file view.

### 5. `Ctrl+D` never extends to next occurrence — SelectWord one-shot

mnml's `Ctrl+D` in standard mode = `SelectWord` (see `src/input/standard.rs:235`), which selects the word around the cursor. A second Ctrl+D on the same selected word is a no-op (still `Sel 5` on "count"). VS Code's Ctrl+D is "add selection to next find match" — the *reason* to use it is the multi-cursor behavior on repeat. In mnml the muscle memory dies after the first press. `editor.add_cursor_at_next_word` exists as a command and even claims `keys: &["ctrl+d"]` at `src/command.rs:876`, but the standard input handler intercepts `Ctrl+D` first and returns `SelectWord`, so the registered command never fires. Suggested repair: teach the standard handler to route Ctrl+D through the command registry OR make SelectWord itself extend to the next occurrence when the current selection matches its next hit.

### 6. `Ctrl+J` fires snippet expansion instead of "toggle panel" — VS Code chord misfire

In VS Code, Ctrl+J toggles the bottom panel (Terminal / Problems / Output). In mnml, Ctrl+J = `editor.snippet_expand` (`src/command.rs`). Not just "different behavior" — actively destructive: if the user just typed a snippet trigger word before hitting Ctrl+J thinking "toggle panel", the word is silently expanded into something unexpected. Ctrl+` covers the terminal-panel role in mnml but leaves the general "toggle bottom panel" chord unclaimed by the correct binding.

### 7. Grep pane never renders results when right panel is visible and no matches (silent fail)

Ctrl+Shift+F opens the Grep workspace prompt. Type a query + Enter with:
- `rg` not on PATH (common case in ephemeral shells)
- Workspace is not a git repo (fallback to `git grep` also fails)

Result: `grep_workspace` returns empty hits, `run_workspace_grep` toasts `no matches for X` — but during headless drives on a workspace with actual matches on disk and no `rg` in PATH the toast is often too brief (or coalesced away) to notice. No pane is created, `rightPanelPanes:[]` stays empty, no persistent chip anywhere in the UI records that "the last grep failed because rg wasn't available". A keyboard-only user hits Ctrl+Shift+F ten seconds after `sudo apt install ripgrep` fails silently and gets... silence. SEV-2 because the whole Ctrl+Shift+F flow has no persistent failure feedback — no "grep is unavailable, install ripgrep" chip, no error toast that stays. (Note: the same happens for hosts where `rg` is a shell function/alias but not a binary — the `Command::new("rg")` spawn in `grep_workspace` doesn't see the alias.)

### 8. Ctrl+P + `@` prefix silently closes picker when no LSP symbols available

Verified `@` is a mode-switch prefix at `src/tui/handlers/overlay.rs:428` (recently landed). When pressed on a small file with LSP not yet responsive OR no symbols (e.g. a fresh 6-line hello.rs), the flow is:

1. Picker closes.
2. `lsp.symbols` fires `lsp.document_symbol(path)`, returns `true` (request sent).
3. No toast (the "no language server for this file" toast only fires on `false` return).
4. LSP reply never arrives (or arrives with 0 symbols).
5. User is left with the file view, the picker gone, no visible feedback.

The picker didn't get replaced, no picker.Symbols overlay appeared, no toast — pure disappearance. Compared to `#` (workspace symbols) which opens a query prompt as a visible acknowledgement, `@` is a black hole for the "the LSP isn't ready yet" case. SEV-2 because typing `@` at the wrong moment during a keyboard-only session gives zero feedback that the request was fired or is pending.

---

## SEV-3 — Chord unbound / discoverability / muscle-memory drift

### 9. Ctrl+K Ctrl+0 / Ctrl+K Ctrl+J (fold-all / unfold-all) fall into `<leader>` — no chord binding

VS Code's canonical fold-all / unfold-all chords. mnml has `editor.fold_all_brackets` and `lsp.fold_all` commands registered but both have `keys: &[]`. Typing `Ctrl+K Ctrl+0` results in the `<leader>` whichkey overlay pending after the second Ctrl+ press (Ctrl+0 is not a valid leader key so nothing fires). Same for `Ctrl+K Ctrl+J`. Users have `Ctrl+Shift+[` / `Ctrl+Shift+]` for the current fold but no whole-file fold shortcut.

### 10. Ctrl+K Ctrl+S (VS Code Keyboard Shortcuts) — unbound, falls to `<leader>`

Same pattern as #9 but for the VS Code keyboard-shortcuts editor. mnml doesn't have a keyboard-shortcuts editor UI, so the correct fix is to route to `view.settings` and scroll to a "keys" filter, or simply document the gap. (Already logged in round-8's SEV-3 pile — kept for regression tracking.)

### 11. PageUp / PageDown / Home / End in picker are no-ops — 701-item palette has no fast scroll

`handle_picker_key` in `src/tui/handlers/overlay.rs` handles Up/Down/Left/Right and Ctrl+P/Ctrl+N — but not PageUp / PageDown / Home / End. With 700+ commands in the palette a user has no faster-than-one-row-at-a-time scroll. VS Code binds all four (Home/End jump to first/last, PgUp/PgDn scroll a viewport). Muscle memory dies.

### 12. Tab in picker is a documented no-op — should open in a split (or similar secondary accept)

`handle_picker_key` maps Tab to `picker_accept_secondary()` which is a no-op for every kind (see the comment at `src/tui/handlers/overlay.rs:342`). VS Code binds Alt+Enter in Ctrl+P to "open in a new group / split". mnml has neither. Doesn't matter for palette but does matter for file-picker → open-in-split flows.

### 13. `Ctrl+P` Enter with no matches silently closes picker — no "create file" prompt

Typing `zzz.txt` (a filename that doesn't exist) into Ctrl+P then Enter: picker closes silently, nothing else happens. VS Code offers "Create new file with name `zzz.txt`" as an inline picker row when the query has no exact match. mnml drops the input. Same class as round-6 finding on the file picker's "did you mean to type it into the terminal?" gap.

### 14. `view.reset_tree_width` shipped without a default keybinding

Round-8 landed `view.reset_tree_width` (`src/command.rs`, `keys: &[]`). Palette-only. Since the command's whole purpose is to undo an accidental drag-resize, and a keyboard-only user can never drag-resize in the first place, this is more of a mouse-user rescue, so SEV-3. Still worth binding to something like `Ctrl+K Ctrl+B` (mnemonic: "reset sidebar B").

### 15. `Ctrl+Space` completion — silent no-op when LSP isn't ready

Positioning cursor mid-word on a fresh hello.rs and pressing Ctrl+Space: no visible completion popup, no toast, no status chip. If rust-analyzer hasn't indexed yet the user has no way to tell if their chord even fired. VS Code shows a small spinner or "Loading..." row in the completion popup while LSP is warming up. mnml has an `LSP 1` chip in the status bar but no per-request indicator.

---

## Verified holding — recently-landed items that survived Round 9

- **Ctrl+K r → view.focus_right_panel** (round-8 SEV-2 fix): fires as expected. Panel opens if hidden, focus lands inside.
- **Shift+F12 → lsp.references**: fires; picker opens correctly when LSP has results. Silent (as expected) when LSP has no data yet.
- **Ctrl+Shift+Space → lsp.signature_help**: fires; no visible feedback when LSP not ready but the chord no longer misfires to something destructive.
- **Ctrl+Shift+G → view.activity_git → git graph**: opens graph pane cleanly.
- **Palette recents-at-top**: verified — after running `view.welcome` once, the next Ctrl+Shift+P opens with `★ view · Welcome overlay …` at the top of the list.
- **Ctrl+P `>` prefix → command palette**: mode switch works (title flips from "Open file" to "Command palette").
- **Ctrl+P `#` prefix → workspace symbols**: opens the query prompt.
- **F11 → Zen mode**: enters zen, `Esc` exits cleanly.
- **Ctrl+B → toggle sidebar**: works both directions.
- **Ctrl+P → Ctrl+P (twice)**: second invocation starts with empty query (VS Code parity — VS Code seeds the last-searched name, which mnml doesn't, but this is arguably better).
- **Ctrl+Shift+T → reopen closed tab**: reopens up to N tabs; hitting it repeatedly restores each in reverse-close order.
- **Ctrl+Tab / Ctrl+PageUp / Ctrl+PageDown → tab switching**: MRU pair-swap for Ctrl+Tab; sequential for Ctrl+PageUp/Down.

---

## Test-drive log

- Workspace: `/private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad/ws2`
- Files: `a.txt` `b.txt` `hello.rs` `foo.py` `mnml.log`
- Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml --headless --input standard <ws2>`
- IPC: `.mnml/ipc/{command,screen.txt,status.json,events.jsonl,rects.json}`
- No mouse commands (`click`, `drag`, `hover`, `scroll`, `mouse_*`) fired at any point.
