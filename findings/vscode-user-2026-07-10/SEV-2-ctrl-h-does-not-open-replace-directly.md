## [SEV-2] Ctrl+H does not open replace when no active find; opens a Find prompt instead

**Reproduction**:

```jsonc
// clean state, no active find
{"cmd":"key","key":"ctrl+h"}
{"cmd":"snapshot"}
```

**Expected** (VS Code): Ctrl+H immediately opens Find & Replace with two input rows (find + replace) — one chord, ready to type both patterns.

**Actual**: Ctrl+H opens a single-field prompt titled `Find` (the same overlay as Ctrl+F). The user has to enter a search term, press Enter, then hit Ctrl+H a SECOND time to get a `Replace N× "..." with` prompt.

Two-step flow is visible in `src/command.rs:739`:

```rust
Command { id: "find.replace",
          title: "Replace every match of the active find",
          keys: &["ctrl+h"],
          run: |app| app.open_replace_prompt(), }
```

`open_replace_prompt` requires an "active find" and falls back to opening a find prompt when none exists.

**Notes**: For a VS Code user who wants `Ctrl+H → type pattern → Tab → type replacement → Enter` the current flow adds an extra chord + Enter. There's no mention of the two-step workflow in the Find prompt UI either — no hint that Ctrl+H again after Enter will open Replace. Discoverability issue on top of the parity gap.
