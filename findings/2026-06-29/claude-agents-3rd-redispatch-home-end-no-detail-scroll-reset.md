---
finding: home-end-no-detail-scroll-reset
severity: SEV-3
agent: claude-agents-power-user
verifies: 54301a9
repro: e2e
---

## What happened
Home and End keys in the agents dashboard do not reset `detail_scroll` to 0
when moving to a new row. This causes the drill-down panel to open mid-scroll
on the new row, showing content from the middle of the view rather than the
top. j/k navigation, PgUp/PgDn, and mouse click all reset detail_scroll
correctly, making Home/End the only navigation primitives that don't.

## Steps to reproduce
1. Open `ai.dashboard` with multiple sessions visible.
2. Navigate to a row and press `v` to switch to Bash or Files drill-down.
3. Press Shift+PgDn several times to scroll the detail panel deep.
4. Press End to jump to the last row, then Home to jump to the first.

## Expected
Each Home/End jump resets detail_scroll to 0 so the newly-selected row's
drill-down shows from the top.

## Observed
detail_scroll is preserved from the previous row. If the previous row had
detail_scroll = 8, the newly Home/End-selected row also opens at offset 8,
even though the new row may have fewer lines — in that case the panel appears
empty (all content scrolled past) or shows the wrong section.

## Suspected cause
`src/tui/handlers/pane.rs:909-919`. The `KeyCode::Home` handler sets
`p.selected = 0` directly; the `KeyCode::End` handler sets `p.selected =
n.saturating_sub(1)` — neither calls `move_up()` / `move_down()` which reset
`detail_scroll`. Fix: add `p.detail_scroll = 0;` in both arms.
