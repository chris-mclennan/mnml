---
agent: nvchad-user
severity: SEV-2
---

## SEV-2 `Ctrl+Shift+[` / `Ctrl+Shift+]` do nothing in vim NORMAL — bracket prefix eats the key before chord dispatch

**Reproduction**:
```
{"cmd":"open","path":"a.rs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"key","key":"escape"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"g"}
{"cmd":"key","key":"j"}                // cursor inside `fn main()` body, line 3 col 1
{"cmd":"key","key":"j"}
{"cmd":"key","key":"ctrl+shift+["}      // bound to editor.toggle_fold per src/command.rs:656
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
// All 10 lines still visible; no fold.
{"cmd":"run-command","id":"editor.toggle_fold"}   // same command, direct
{"cmd":"snapshot"}
// Now line 1 collapses to `fn main() {    ⋯ 5 hidden`
```

`Ctrl+Shift+]` (`editor.unfold_all`) has the same problem.

**Expected**: VS Code muscle memory. Per the task description and `src/command.rs:649-664`, `Ctrl+Shift+[` toggles a fold; `Ctrl+Shift+]` unfolds all. The chord chain in `src/tui/chord.rs::dispatch_chord_chain` runs BEFORE the focused-pane handler in `src/tui/mod.rs::dispatch_key`, so the binding should win.

**Actual**: Chord is registered (`keys: &["Ctrl+Shift+["]` in `src/command.rs:656`) but never fires. The `editor.toggle_fold` event line does NOT appear in `events.jsonl` after a `ctrl+shift+[` keypress; only the bare `"key":"ctrl+shift+["` event. Direct `run-command editor.toggle_fold` works perfectly (verified — folds the body cleanly).

**Source pointer**: `src/input/vim.rs:2321` — the NORMAL handler matches `KeyCode::Char('[')` regardless of modifiers and sets `Prefix::BracketOpen` unconditionally. Mod-check is absent. But this should be moot because `dispatch_chord_chain` runs first in `src/tui/mod.rs:1340`. Suspect the registered Chord's `Char('[') + Ctrl+Shift` is somehow falling through `resolve_seq` to `None` (the IPC parses `ctrl+shift+[` to the matching KeyEvent, and `Chord::of` does not touch non-uppercase chars). Worth a unit test like `Keymap::build(vim_cfg).resolve_seq(&[Chord::of(&parse_key_spec("Ctrl+Shift+[").unwrap())])` to confirm the lookup table actually has the entry.

**Notes**: VS Code parity is the whole point of these bindings (per the source comment "VS Code's Ctrl+Shift+[/] is the canonical fold/unfold"). vim users have `za`/`zR` as fallbacks (those work), but a user coming from VS Code who toggles to vim mode will type Ctrl+Shift+[ and see nothing happen. Also: on real macOS terminals without kitty keyboard protocol, `Ctrl+[` literally sends ESC — so even if the dispatch were fixed, the chord would only reach a user with kitty-protocol enabled. Worth declaring "VS Code shortcut, kitty-protocol terminals only" in the cheatsheet rather than promising it cross-terminal.
