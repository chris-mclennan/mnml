## [SEV-3] Triple-click does not select the current line

**Reproduction**:

```jsonc
{"cmd":"click","col":40,"row":3,"button":"left"}   // click 1
{"cmd":"click","col":40,"row":3,"button":"left"}   // click 2 — word select works
{"cmd":"click","col":40,"row":3,"button":"left"}   // click 3 — expected: line select
{"cmd":"snapshot"}
// statusline shows Sel 4 (still just the word)
```

**Expected** (VS Code, and every other standard modeless editor): Three left clicks at the same position selects the entire line.

**Actual**: The double-click selects the word (`Sel 4`), the third click just re-fires as a single click — the click-streak state machine only tracks up to click_count = 2. Confirmed by inspecting `src/tui/mouse/up_left.rs:284` + `down_left.rs:1172`: `is_double = matches!(app.last_click, Some((ts, x, y, 1)) …)` — there's no arm that recognizes streak = 2 → line select.

**Source pointer**: `src/tui/mouse/up_left.rs:284` (`app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }))`). Extending to track 3-click for `SelectLine` would fit the existing pattern.

**Notes**: Bare quality-of-life gap for VS Code muscle memory. `Ctrl+L` still works for line-select via keyboard.
