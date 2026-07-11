## [SEV-3] Ctrl+Space with no LSP produces nothing — no fallback to buffer-word / keyword completion

**Reproduction**:

```jsonc
{"cmd":"open","path":"src.py"}       // Python file, no LSP running
{"cmd":"key","key":"ctrl+home"}
{"cmd":"key","key":"end"}
{"cmd":"type","text":" gre"}
{"cmd":"key","key":"ctrl+space"}      // expected: keyword-completion popup with "greet"
{"cmd":"snapshot"}
// no popup, no toast — pure no-op
```

**Expected** (VS Code): Even without a language server, Ctrl+Space shows the built-in "Word Suggestions" from the current buffer (identifiers matching the prefix).

**Actual**: Nothing visible. `lsp.completion` is bound at `src/command.rs:3477` with `keys: &["ctrl+space"]` and calls `app.lsp_completion()` — which no-ops without an active LSP. No toast, no fallback to `keyword_complete`.

**Notes**: mnml already has `keyword_complete` (in `src/app/find.rs` — bound to vim's insert-mode `Ctrl+N`/`Ctrl+P`). Wiring Ctrl+Space in standard mode to fall back to `keyword_complete` when no LSP is registered for the buffer's language would close the gap.
