## [SEV-3] Settings overlay: clicking a row cycles the value; can't click a specific option

**Reproduction**:

```jsonc
{"cmd":"key","key":"ctrl+,"}          // open Settings
// Line 1: `▸ Line numbers   relative / [absolute] / off  *`
{"cmd":"click","col":58,"row":9,"button":"left"}  // aim for the word "relative"
// Result: value cycles [absolute] → [off], not → [relative]
{"cmd":"click","col":58,"row":9,"button":"left"}  // click again
// Result: cycles [off] → [relative]
{"cmd":"click","col":58,"row":9,"button":"left"}
// Result: cycles [relative] → [absolute]
```

**Expected** (VS Code convention, and Family Settings UI feels like it should follow suit): clicking a specific option word ("relative" / "absolute" / "off") should set THAT choice directly. Clicking the empty area of the row could still cycle, but hit-testing on the value words should target them.

**Actual**: Clicking anywhere on the row cycles to the next value regardless of what word was clicked.

**Source pointer**: `src/tui/mouse/mod.rs` handling of `app.rects.settings_rows` — the whole row is one hit rect; per-value column hit-rects would be needed to target specific choices.

**Notes**: `CLAUDE.md`'s Family Settings UI convention says "Each row: `▸ <label>: [active] / other1 / other2  *`" — no explicit spec of what clicks do, but the visual affordance strongly implies clicking a specific value word selects it. Keyboard flow (`h`/`l` / `←`/`→`) still works fine.
