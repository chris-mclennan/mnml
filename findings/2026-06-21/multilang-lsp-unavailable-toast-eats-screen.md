---
finding: lsp-unavailable-toast-displaces-status-bar
severity: SEV-3
agent: multilang-dev-user
language: ts
repro: e2e
---

# LSP unavailable toast appears persistently and occludes status bar area

## Observed behavior

When opening a `.ts` file in an environment where `typescript-language-server`
is not on PATH (e.g., a fresh machine, CI, or a workspace without global npm
tools), a toast fires:

```
LSP: typescript-language-server unavailable (spawn typescript-language-server: No such file or directory (os error 2)) — skipping
```

In headless rendering, this toast appears at the bottom line of the screen,
overlapping the status bar area. During e2e tests, this caused test assertions
like `expect screen contains "node_modules"` to fail because the tree rail's
bottom rows were obscured by the toast.

## Severity justification

This is SEV-3 (cosmetic / discoverability) rather than SEV-1 because:
1. The error itself is handled correctly — the file opens and renders normally.
2. In the real terminal (not headless), the toast appears in the toast stack and
   auto-dismisses after a few seconds.
3. The underlying issue is that `typescript-language-server` is not installed,
   which is a known honest cut (per agent doc spec).

However, the toast message is long (84 chars) and contains the OS error detail
which is not useful to the user. A better message would be:
```
LSP: typescript-language-server not found — install: npm i -g typescript typescript-language-server
```

The install hint is already in `src/tools.rs` (line 60) but is not included
in the LSP spawn error path.

## Affected code

`/Users/chrismclennan/Projects/mnml/src/lsp/mod.rs`, line 668–670:
```rust
let _ = self.tx.send(LspEvent::Message(format!(
    "LSP: {} unavailable ({e}) — skipping",
    sc.cmd
)));
```

The `e` here is the OS error string ("spawn typescript-language-server: No such
file or directory (os error 2)"). Stripping the OS noise and adding the install
hint from `src/tools.rs` would improve the UX for new TS developers.
