---
finding: cheatsheet-Z-asymmetry-after-single-collapse
severity: SEV-2
agent: power-user-lsp-cheat-test
repro: e2e
---

# Cheatsheet `Z` cycle is asymmetric — collapses one with `z`, then `Z` wipes instead of "collapse rest"

## Surface

`src/tui.rs:2139-2147` + `src/cheatsheet.rs::collapse_all/expand_all`
(commit `1346dba`).

## What happens

The `Z` chord is wired:

```rust
KeyCode::Char('Z') => {
    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
        if c.collapsed.is_empty() {
            c.collapse_all();
        } else {
            c.expand_all();
        }
    }
}
```

This is the standard "Z toggles between collapsed/expanded everything"
model — when nothing is collapsed, `Z` collapses everything; when
something is collapsed, `Z` expands everything. The asymmetric edge
is: after `z` collapses ONE section, `collapsed.is_empty() == false`,
so the next `Z` is `expand_all` — i.e. it WIPES the user's intentional
collapse decision and dumps every section back open.

Better-known editors (NvChad cheatsheet, VS Code outline view, IntelliJ
structure view) treat `Z` as "collapse all" unconditionally — if there
are any expanded sections, collapse them; if everything is already
collapsed, `Z` is a no-op or expands. The bug is that mnml's `Z`
flips from "collapse all" to "expand all" the moment a single section
is collapsed — making `Z` feel non-deterministic.

## Repro

`tests/e2e/cheatsheet_Z_asymmetry.test` — passing — demonstrates the
exact transition:

```
key z       # collapse one section
key Z       # user expects: collapse the rest
            # actual:        expand_all → no `(collapsed)` markers anywhere
```

The test asserts the bug: after `Z`, `expect screen lacks "(collapsed)"`
passes — meaning `Z` did expand-all instead of collapse-all.

## Suggested fix

Make `Z` semantically "fold-all": if any section is expanded, collapse
all; else expand all. Replace the condition:

```rust
if c.collapsed.is_empty() {
    c.collapse_all();
} else {
    c.expand_all();
}
```

with:

```rust
if c.collapsed.len() < c.sections.len() {
    c.collapse_all();   // at least one section is still expanded
} else {
    c.expand_all();     // everything is collapsed; toggle out
}
```

This makes `Z` symmetric ("fold-all toggle") regardless of intermediate
`z` operations.

## Related

The current cycle described in the prompt (`Z`→collapse, `Z`→expand,
`z` on one, `Z` → ???) was reproduced exactly: the third `Z` clears
collapsed instead of completing the collapse.
