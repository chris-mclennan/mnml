---
finding: cheatsheet-filter-ignores-collapsed-sections
severity: SEV-2
agent: power-user-lsp-cheat-test
repro: e2e
---

# Cheatsheet filter ignores collapsed sections — rows that match the query stay hidden, and `(collapsed)` headers persist with zero matches

## Surface

`src/cheatsheet.rs::visible_sections` (commit `1346dba`).

## What happens

`visible_sections()` special-cases collapsed sections BEFORE applying
the query filter:

```rust
.filter_map(|sec| {
    if self.collapsed.contains(&sec.group) {
        return Some(CheatsheetSection {
            group: sec.group.clone(),
            rows: Vec::new(),       // collapsed → no rows
        });
    }
    let rows: Vec<_> = if q.is_empty() {
        sec.rows.clone()
    } else {
        sec.rows.iter().filter(|r| /* matches */).cloned().collect()
    };
    if rows.is_empty() && !q.is_empty() {
        None         // filter dropped this section (only for NON-collapsed)
    } else {
        Some(CheatsheetSection { group: sec.group.clone(), rows })
    }
})
```

Two consequences:

### 1. Filtered query can't reach a matching row inside a collapsed section

If I collapse the `[editing]` section, then type `/save` to find
`buffer.save_all`, I'll see — nothing. The row exists, the filter
matches it, but the section is collapsed so `visible_sections`
returns it with `rows: Vec::new()`. The cheatsheet pretends the row
doesn't exist.

This is the worst-case UX: discoverability is the cheatsheet's whole
job, and a hidden match is invisible to the user trying to find it.

### 2. `(collapsed)` headers stay rendered even when the filter has zero matches anywhere

If I `Z`-collapse everything then type a never-matching string like
`/zzznevermatcheszzz`, the screen still shows every section header
(rendered as `▸ <group> (collapsed)`). A correctly-implemented filter
would show `no matches` (the `sections.is_empty()` branch in
`src/ui/cheatsheet_view.rs:50`). The mismatch makes the empty-state
look like real content.

## Repro

`tests/e2e/cheatsheet_filter_respects_collapse.test` — passing —
demonstrates case 2 directly. Case 1 requires a real keymap with
the matching row inside a known-collapsed section; not reproducible
in the e2e harness without depending on the keymap layout, but the
code is unambiguous.

## Suggested fix

Pick one of:

- **Filter overrides collapse** (preferred): when `query` is non-empty,
  bypass the collapse special-case — show matching rows regardless of
  collapsed state (and maybe auto-render those sections with a
  different header style to indicate "expanded by filter").
- **Auto-expand under filter**: when a query is typed, automatically
  expand any section that contains a match. Restore collapse state
  when the filter clears.
- **Hide collapsed sections under filter**: at least drop the
  `(collapsed)` placeholder rendering when the query is non-empty
  (it's lying about state — those sections might have matches).

The first option is closest to what existing tools do (VS Code's
collapse + filter combo auto-expands matches). The fix is small —
move the collapse check INSIDE the post-filter empty check, e.g.:

```rust
let rows: Vec<_> = if q.is_empty() { ... };
if rows.is_empty() {
    if q.is_empty() && self.collapsed.contains(&sec.group) {
        // collapsed, no filter → keep header
        Some(CheatsheetSection { group: sec.group.clone(), rows: vec![] })
    } else {
        None       // filter dropped (or section was just empty)
    }
} else {
    // collapsed under a filter → uncollapse for display
    Some(CheatsheetSection { group: sec.group.clone(), rows })
}
```
