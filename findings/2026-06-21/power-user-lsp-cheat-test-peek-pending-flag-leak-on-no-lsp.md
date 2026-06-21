---
finding: peek-pending-flag-leak-on-no-lsp
severity: SEV-2
agent: power-user-lsp-cheat-test
repro: e2e
---

# `pending_peek_definition` flag leaks when LSP fails / returns no result

## Surface

`:lsp.peek_definition_overlay` (commit `883fd62`).

## What's expected

The peek overlay's pending-state flag is single-shot: arm it, fire
goto-def, the LSP response handler observes the flag, opens the
floating overlay instead of jumping, and clears the flag.

## What actually happens

The flag is cleared in EXACTLY one place — the `LspEvent::GotoDefinition`
match arm in `src/app/lsp.rs:1037-1038`. If that event never arrives
the flag stays `true` forever, and the very next `:lsp.goto_definition`
(or `gd`) gets misrouted into the peek branch.

There are at least three ways the event never arrives:

1. **No LSP server attached** for the active file type — `lsp_request_at_cursor`
   toasts "no language server" (`src/app/lsp.rs:1014`) and returns
   without firing anything. `pending_peek_definition` was already
   set on line 199 *before* the toast.
2. **No editor / unsaved file** — same path, toast at line 1002/1006,
   flag still set.
3. **LSP returned a null result or an error** — `src/lsp/client.rs:1022-1024`
   bails on `result == null` before sending `LspEvent::GotoDefinition`.
   The flag was set in `peek_definition_overlay`, but the response
   handler never reaches the clear.

## Repro

See `tests/e2e/peek_definition_overlay_no_lsp_leak.test`.

The e2e harness has no real LSP, so the toast path is reproducible.
The flag-stays-set consequence isn't observable from a `.test` script
(no public accessor) but is a direct read of the code path. To prove
end-to-end in a real session:

1. Open a `.rs` file with no `rust-analyzer` available, OR cursor on
   a symbol that has no definition.
2. Run `:lsp.peek_definition_overlay`. You'll see "no language server
   for this file (go-to-definition)" or no overlay opens.
3. Move to a different file / fire up rust-analyzer / put cursor on a
   resolvable symbol.
4. Run `:lsp.goto_definition` (or press `gd`). Expected behavior:
   cursor jumps. Actual behavior: a floating overlay opens instead.

## Suggested fix sketch

Either:
- Clear `pending_peek_definition` in `peek_definition_overlay` when
  `lsp_request_at_cursor` reports failure (the `send` closure returns
  `false`), AND clear it on the LSP error/null-result code path in
  `src/lsp/client.rs:~1024`.
- Or — simpler — clear it unconditionally in `tick`'s LSP event loop
  whenever any LSP response is dispatched, and re-arm it from the
  GotoDefinition handler only when the handler decides to peek.

The cleanest move is probably a `Drop`-like guard inside
`peek_definition_overlay` that holds the flag in scope only for the
single call, but the registry/event model makes that awkward — a
simple timeout-cleared flag (e.g. clear if no GotoDefinition event
arrived after 2s) would close the loop without restructuring.
