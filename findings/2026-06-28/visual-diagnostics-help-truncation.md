---
agent: drive-mnml
severity: SEV-3
surface: right-panel / diagnostics-pane
---

# Diagnostics pane help-line truncates when hosted in right panel

When `:lsp.diagnostics` is hosted in the right panel at default width
(~22 cells in my workspace), the pane-internal help line truncates:

```
⏎ jump  · r refresh  · s severi
```

`severities` is cut to `severi` (overflow at the column right edge).
This is a pane-internal hint render bug (not the tab-strip truncation
that design-critic #1 already flagged).

Captured in `/tmp/qa-vis-03-tabs.png`. Same class of overflow exists in
the grep pane's 58-char hint line at narrow widths (design-critic noted
this in "Out of scope but noted").

## Fix
Diagnostics pane help line needs a width-aware short form:
- Full width: `⏎ jump  · r refresh  · s severity`
- Narrow:    `⏎/r/s`  or  `nav: ⏎ refresh: r`
