---
finding: no-http-block-navigation-commands
severity: SEV-3
surface: multi-block-http
---

**Repro**:

1. Open a `.http` file with 3 named blocks (`### block-one`, `### block-two`, `### block-three`).
2. Try `:http.next_block` or `:http.prev_block` from the command palette.

**Expected**: Commands exist and move the editor cursor to the start of the next/previous block,
allowing keyboard-driven block selection before `:http.send`.

**Actual**: Neither `http.next_block` nor `http.prev_block` exists in the command registry.
Searching the palette shows no match. The only way to fire a different block is to manually
move the editor cursor into that block's range and then run `:http.send`.

**Confirmation**: `grep -rn '"http\.' src/command.rs` lists 40+ registered commands; neither
`http.next_block` nor `http.prev_block` appears.

**Impact**: Keyboard-only workflows on `.http` files with many blocks require manual cursor
navigation to switch the "active" block. There is no chord or command to cycle blocks
without touching the cursor.

**Notes**: This is a missing feature, not a regression from a previously-working state. No
prior commit is visible that added and then removed these commands. Documenting as SEV-3
because the multi-block `.http` format is marketed as first-class and block navigation
via keyboard is a standard operation in every competitor tool (VS Code REST Client, IntelliJ
HTTP Client, Hoppscotch).
