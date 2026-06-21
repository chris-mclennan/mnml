---
finding: inlay-hints-not-per-language
severity: SEV-3
agent: multilang-dev-user
language: ts
repro: workspace-fixture
---

# `lsp.inlay_hints_toggle` is global (per-session), not per-language

## Summary

`:lsp.inlay_hints_toggle` flips `app.config.editor.inlay_hints` — a single
boolean that applies to all languages in the session. A polyglot dev who
wants inlay hints for Go (goroutine types are hard to infer) but not for
TypeScript (the type annotations are already explicit in the code) cannot
configure this independently.

## Observed behavior

```rust
// src/command.rs line 699
app.config.editor.inlay_hints = !app.config.editor.inlay_hints;
```

One flip affects every open buffer in every language.

## Impact

Low in practice — most developers either want hints or don't, globally.
The agent spec flagged per-language behavior as a test criterion; the current
design is intentional (single toggle) but does not match VS Code's model where
inlay hints can be configured per-language via settings.

## Suggested fix (v2)

Could be addressed by per-language config: `[editor.inlay_hints.typescript]`,
`[editor.inlay_hints.go]`, etc., with the toggle binding to the focused file's
language. Low priority.
