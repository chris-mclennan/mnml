---
agent: vscode-user
severity: SEV-3
---

# Right-panel header shows buffer name, not pane kind (OUTLINE / DIAGNOSTICS)

CLAUDE.md status for the 2026-06-28 right-panel v2 feature states:

> Header shows the hosted pane's kind (OUTLINE / DIAGNOSTICS) with a `×` close button

In practice the header shows the underlying file name. With `main.rs` open
and `:outline.show` clicked from the empty-state row, the right panel header
reads `main.rs ⌥` with `×` to the right. Similarly `:lsp.diagnostics` shows
`problems ✓` not `DIAGNOSTICS`.

## Reproduction

```jsonl
{"cmd":"open","path":"main.rs"}
{"cmd":"key","key":"ctrl+shift+b"}        // open right panel (empty state)
{"cmd":"click","col":92,"row":5,"button":"left"}   // click :outline.show row
{"cmd":"wait_ms","ms":400}
{"cmd":"snapshot"}
// Right-panel header: "main.rs ⌥" — docs say "OUTLINE"
```

For VS Code parity the panel headers are short, kind-y labels ("Outline",
"Problems") — VS Code shows "OUTLINE" / "PROBLEMS" / "TIMELINE" etc. as
section titles, not the underlying file path. mnml's behavior may actually
be more useful (you can see which file the outline is FOR), but it doesn't
match either the docs or the VS Code convention.

**Expected**: header label matches the pane kind ("OUTLINE", "DIAGNOSTICS"),
optionally with the file as a subtitle.

**Actual**: header shows the file name (outline) or a pane-specific title
("problems"). No `OUTLINE` / `DIAGNOSTICS` literal.

**Source pointer**: `src/ui/right_panel.rs` (titles generated from
`Pane::title()` rather than a kind enum).

**Notes**: Either fix the docs (the file-name behavior is arguably better)
or fix the headers — they currently disagree. SEV-3 because both forms are
usable; the polish item is consistency with the documented intent.
