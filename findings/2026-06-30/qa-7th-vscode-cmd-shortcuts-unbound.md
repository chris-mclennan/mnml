---
agent: vscode-user
severity: SEV-3
---

# macOS Cmd+P / Cmd+W / Cmd+S etc. are unbound in standard mode

Mnml documents Cmd as a shorthand for Super in the key-spec parser. macOS users
with VS Code muscle memory press Cmd+P (file picker), Cmd+W (close tab),
Cmd+S (save), Cmd+, (settings), Cmd+Shift+P (palette), Cmd+B (sidebar) — none
of these fire anything in standard mode. Only the Ctrl-prefixed variant works.

## Reproduction

```jsonl
{"cmd":"open","path":"main.rs"}
{"cmd":"open","path":"hello.py"}
{"cmd":"snapshot"}
{"cmd":"key","key":"cmd+w"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
// status.json: 2 panes — Cmd+W did nothing
{"cmd":"key","key":"cmd+p"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
// no file picker overlay shown
```

**Expected**: on macOS, Cmd+P / Cmd+W / Cmd+S behave as Ctrl-equivalents.
That's basically every other native+TUI editor's macOS convention.

**Actual**: only Ctrl+P / Ctrl+W / Ctrl+S work; Cmd+X are no-ops. A VS Code
user landing here will assume the app is broken until they remember to
reach for Ctrl.

**Source pointer**: `src/command.rs` lists all `keys: &["ctrl+…"]` strings;
there is no per-platform Cmd alias layer. The IPC parser at
`src/ipc/mod.rs:parse_key_spec` accepts `cmd+x` but it routes to `super+x`
which isn't bound anywhere.

**Notes**: On crossterm Mac terminals, Cmd often doesn't reach the app (the
terminal eats it for native shortcuts), so users in real terminals may not
hit this immediately — but Ghostty in particular DOES forward Cmd to the
app, and the new "mnml runs in any terminal" pivot makes this user-visible.
Lowest effort: when in macOS, treat `super+<letter>` as an alias for
`ctrl+<letter>` for VS-Code-style chord bindings.
