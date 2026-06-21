---
finding: nvchad-diagnostics-severity-filter-undocumented
severity: SEV-3
agent: nvchad-power-user
repro: headless-ipc
---

# Diagnostics pane `s` cycles severity filter but the primary legend doesn't mention it

`src/tui.rs:2468-2472` binds `s` (Char) → `cycle_severity_filter`
on the Diagnostics pane. `src/ui/diagnostics_view.rs:73` paints
the bottom legend as:

```
  ⏎ jump   r refresh   esc back
```

No mention of `s`. The pane *does* hint at `s` cycles severity
in a couple of secondary states (`diagnostics_view.rs:86, 103`)
— "(filtered out — `s` cycles severity)" and "filter: {} ({shown}
/{total})  ·  `s` cycles severity" — but those text strings only
appear when there are diagnostics, AND in particular states.

For a vim user with a fresh "no diagnostics in open files" pane
(the most common starting state), the legend is the *only* place
to discover key bindings. `s` is invisible. The vim user reaches
for `s` thinking "substitute char" → nothing happens (Diagnostics
isn't an editor) → user assumes no chord exists, never finds the
severity filter.

## Reproduction

```jsonc
{"cmd":"run-command","id":"lsp.diagnostics"}
{"cmd":"wait_ms","ms":300}
{"cmd":"snapshot"}
// screen.txt bottom of pane:
//   "0 errors · 0 warnings"
//   "  ⏎ jump   r refresh   esc back"   ← no `s`
{"cmd":"key","key":"s"}                          // user wonders if
                                                 // anything happens
{"cmd":"wait_ms","ms":150}
{"cmd":"snapshot"}                                // no visible change
                                                 // (empty pane, filter
                                                 // applies invisibly)
```

**Expected**: the legend shows `s severity` next to the existing
chord tags, the same way the agents dashboard shows everything
in a `?` chord-help overlay.

**Actual**: chord exists, is undiscoverable until the user
already has diagnostics AND happens to read the smaller hint
string.

## Source pointer

`src/ui/diagnostics_view.rs:73` — the bottom legend literal.

`src/tui.rs:2468-2472` — the actual chord binding.

## Notes

Compared to the Cheatsheet's discoverability (`/ filter · j/k ·
esc closes` in the title strip, plus `?` for full chord help,
plus `r refresh`), the Diagnostics pane is bare. Trivial fix:
append `s sev-filter` to the legend literal. Filed as SEV-3
because the chord works, the user just can't find it from a
cold start.
