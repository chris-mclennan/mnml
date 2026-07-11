## [SEV-3] Ctrl+Shift+F workspace grep swallows the query — no results pane opens

**Reproduction**:

```jsonc
{"cmd":"open","path":"src.py"}
{"cmd":"key","key":"ctrl+shift+f"}
// prompt: "Grep workspace" (correct)
{"cmd":"type","text":"greet"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":800}
{"cmd":"snapshot"}
// status.json panes still: [{src.py}]
// no grep results pane, no right-panel host, no toast — the query silently vanishes
```

**Expected** (VS Code): Ctrl+Shift+F opens the workspace search side view with results grouped by file, click-to-jump.

**Actual**: The prompt closes on Enter, no results pane opens, no toast is shown, no output anywhere. The workspace has a match (`greet` appears 3× in `src.py`) — verified with `ripgrep`. Same behavior for `main` (also 3× matches).

**Notes**: `rg` is on the machine (`command rg --version` works) — mnml just does not surface the result. Could be that mnml's `open_grep_prompt` requires the results pane to be pre-registered / requires a plugin, but the current UX is a silent failure. A toast with `no matches` OR `rg not found` OR an opened results pane are all acceptable outcomes; the current outcome is invisible.

**Source pointer**: `find.grep` command entry, `src/command.rs:746` — `app.open_grep_prompt()` chain, and whichever pane wiring is meant to receive results.
