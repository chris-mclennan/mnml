---
agent: vscode-user-mouse
severity: SEV-3
verifies: mouse-rects-empty-state-not-dumped
verdict: CONFIRMED-FIXED
---

## Verdict — CONFIRMED-FIXED in b767b8c

`src/ipc/mod.rs:967-975` now emits both rects via the `one!` macro:

```rust
one!(
    "right_panel_empty_outline",
    app.rects.right_panel_empty_outline
);
one!(
    "right_panel_empty_diagnostics",
    app.rects.right_panel_empty_diagnostics
);
```

Verified in `rects.json` from a live headless run with the panel toggled visible
+ empty:

```
{"label":"right_panel_empty_outline","x":129,"y":5,"w":13,"h":1},
{"label":"right_panel_empty_diagnostics","x":129,"y":6,"w":16,"h":1},
```

The prior finding's audit-blind-spot is closed. Audit harnesses can now verify
these click-rects are painted in the right place.
