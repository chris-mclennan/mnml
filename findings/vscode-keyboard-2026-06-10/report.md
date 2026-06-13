# mnml VS Code Keyboard-Purist Bug Hunt — 2026-06-10

Driver: headless via file-IPC, `MNML_COLS=160 MNML_ROWS=50`, `--input standard`, workspace `/tmp/mnml-keyboard-ws`.

**1 SEV-1, 10 SEV-2, 2 SEV-3.**

## SEV-1

**S1-01 — Ctrl+W mis-fires; no chord closes a focused pty pane.** From editor focus with `[main.rs, README, terminal]`, Ctrl+W closed `main.rs` and the split twin but left the pty orphaned. No keyboard chord exists for "close active pty pane"; only `view.close_split` (palette). Worse, `view.close_split` returned `ok=true` on the events log without actually closing — required a follow-up Ctrl+W. User can land in a state where they cannot keyboard-close a stray terminal.

## SEV-2

- **S2-01 Ctrl+Shift+Z is Zen mode, not redo.** VS Code's universal redo chord rips chrome out mid-edit. `Ctrl+Y` does redo (works), but reflexive Ctrl+Shift+Z burns every time.
- **S2-02 Ctrl+L is "Force a full redraw", not "Select line".** Confirmed Ctrl+L + Delete → one char deleted.
- **S2-03 Ctrl+. unbound.** Quick fix lives at `Alt+Enter` (IntelliJ style).
- **S2-04 Ctrl+Space (trigger completion) unbound.** Palette search "completion" shows only vim-insert `Ctrl+P`/`Ctrl+N` keyword completion.
- **S2-05 F11 unbound.** Zen-mode chord is the misbound Ctrl+Shift+Z.
- **S2-06 Ctrl+1 / Ctrl+2 (focus split N) unbound.** Neither moved `activePane` with two splits open.
- **S2-07 Directional split focus has no chord at all.** `view.focus_left/right/up/down` are palette-only (`keys: &[]`).
- **S2-08 Ctrl+N "new file" only fires from tree focus.** Welcome overlay advertises `^N new file` globally; from editor pane focus it's silently swallowed. Tree focus opens "New file in /" prompt.
- **S2-09 Tree Enter on a non-file row silently spawns a `terminal (zsh)` pane.** Navigating past README.md with arrow keys, Enter created terminal panes — no prompt, no warning. IPC `treeSelection` still reported `README.md` while a terminal opened. Keyboard tree-nav is dangerous past the file list.
- **S2-10 Esc from editor pane refocuses the tree (vim semantics).** No overlay open + reflexive Esc = focus jumps to tree, subsequent typed keys hit tree-filter. VS Code purist would expect Esc to be a no-op.
- **S2-11 LSP hover has no keyboard chord.** Palette-only (`lsp.hover` no key). VS Code uses `Ctrl+K Ctrl+I`. Can't see a docstring without palette every time.
- **S2-12 Ctrl+W doesn't close a focused pty pane** (closed adjacent editor + split twin instead). See S1-01.

## SEV-3

- **S3-01 Ctrl+] / Ctrl+[ indent/outdent appear unbound in standard mode** (no visible indent shift). Tab at line start does indent, so behavior exists, chord doesn't map.
- **S3-02 Welcome lies about Ctrl+K.** Welcome chip says `^K which-key`; palette confirms `view.leader` bound to Ctrl+K, but pressing it from editor pane produced no visible overlay in headless snapshots (could be render-only or chord misfire).

## What works (confirmed clean)

Ctrl+P picker (fuzzy, Esc, fresh-on-reopen, Down nav), Ctrl+Shift+P palette (~411 cmds, Esc closes, Enter runs), Ctrl+R recents, Ctrl+S save, Ctrl+Z undo, Ctrl+Y redo, Ctrl+A/C/V, Ctrl+F find + F3/Shift+F3 next/prev, Ctrl+H replace, Ctrl+G goto-line, Ctrl+/ comment-toggle, Alt+Up/Down move-line, Shift+Alt+Up/Down duplicate-line, Ctrl+D add-cursor-next-occurrence (multi-cursor type confirmed), Ctrl+B sidebar toggle, Ctrl+Shift+E focus tree, Ctrl+E cycle focus, Ctrl+\ split right, Ctrl+T terminal, Ctrl+Tab MRU swap, Ctrl+PageUp/PageDown sequential tab nav, Ctrl+Shift+T reopen closed, F2 rename, F12 go-to-def, Ctrl+, settings overlay (←→ adjust, ↑↓ move, r/R reset, Enter save, Esc cancel — all worked), discovery overlay (↑↓/Enter/i/y/Esc), git pane (palette open, then s/u/space/a/Enter/c keyboard-driven). Esc from every modal overlay correctly returns focus. Ctrl+P hammer 20× stable; 50× Ctrl+Z round-trip ~1s.

## Executive summary

Could a VS Code keyboard-purist get their day's work done in mnml without touching the mouse? Yes. The IPC + palette + picker substrate is fully keyboard-reachable — every command is discoverable, every overlay dismisses cleanly with Esc. But you'd burn 30 minutes rewiring six muscle-memory chords: Ctrl+Shift+Z (Zen, not redo), Ctrl+. (unbound, use Alt+Enter), Ctrl+Space (unbound), F11 (unbound), Ctrl+1/2 (unbound, only Ctrl+E cycles), closing a pty (`:view.close_split`). The sharpest paper-cut is reflexive Esc in an unoverlaid editor refocusing the tree — a VS Code user loses keyboard focus to a surface they didn't ask for. Not "keyboard-incomplete" so much as **VS-Code-chord incomplete** — bindings lean vim + IntelliJ. Worth a SEV-2 sweep through `whichkey.rs` / `command.rs` adding `Ctrl+Shift+Z` redo alias, `Ctrl+.` for `lsp.code_action`, `Ctrl+Space` for completion, `F11` for zen, `Ctrl+1..9` for focus split N, and `Ctrl+K Ctrl+I` for LSP hover.
