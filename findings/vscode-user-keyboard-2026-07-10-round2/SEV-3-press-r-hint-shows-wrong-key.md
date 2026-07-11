# SEV-3 — "press \`r\` to fire" hint contradicts the actual chord

## What I did

Opened a fresh `.http` file. The response strip advertises:

```
not sent yet · press `r` to fire
```

Pressed lowercase `r` in the Request pane's Response view — nothing
happens. Pressed `Shift+R` — fires the send (via
`src/tui/handlers/pane.rs:2834`, which lists `KeyCode::Char('R')`
not `'r'`). The comment above that line explains the reason:

```rust
// 2026-06-21 nvchad SEV-2: bare `r` re-fired the
// request — destructive on PUT/DELETE. Bare `a` opened
// an AI debug pane that bills tokens. ... Now: capital
// `R` re-fires (vim canon for replace-mode actions
// of consequence) ...
```

So `r` → `R` in the handler happened, but the string in
`src/app/http.rs:776`, `:885`, `src/app/layout.rs:677`,
`src/app/workspace_methods.rs:813` still shows lowercase.

## Why it matters

New user opens a request pane, reads the hint, presses r, nothing
happens. They look for another way to send. The hint is actively
teaching the wrong chord.

## Suggested fix (not applied)

Search-and-replace `press \`r\` to fire` → `press \`R\` to fire`
across those four sites, plus wherever else the string is
copy-pasted (`grep -rn "press \`r\` to fire" src/`).

## Severity

SEV-3 — documentation-in-UI mismatch; the working chord exists,
just labeled wrong.
