---
finding: file-click-offset-wrong
severity: SEV-2
agent: claude-agents-power-user
repro: e2e
---

## What happened
When the Files drill-down panel is scrolled (`Shift+PgDn` to increase `detail_scroll` past `max_scroll`), file click targets in `app.rects.claude_drill_files` are computed using the raw `detail_scroll` value while the renderer clamps to `actual_scroll = detail_scroll.min(max_scroll)`. When `detail_scroll > max_scroll`, the click rects use a larger skip than the renderer does, so some visible file rows have no registered click target (clicks on them are silently ignored), and click targets are misaligned with the displayed rows.

## Steps to reproduce
1. Open `:ai.agents_dashboard` on a Claude session that has more than 8 recent file edits.
2. Press `v` until the Files drill-down panel is active.
3. Press `Shift+PgDn` multiple times to scroll the panel past its last item (detail_scroll > max_scroll).
4. Click a file row in the Files panel.
5. The click does not open the file.

## Expected
Clicking a file row in the Files panel always opens the file in an editor pane, regardless of scroll position.

## Observed
Clicks on visible rows are not registered when `detail_scroll` exceeds `max_scroll`. The displayed rows do not match the registered click rects.

## Suspected cause
`draw_detail` in `src/ui/claude_agents_view.rs` at lines 628-641: `file_clicks` is built using `scroll` (the raw `detail_scroll`) in the `if i >= scroll` guard and `(i - scroll)` y_offset. But the renderer at lines 688-694 uses `actual_scroll = scroll.min(max_scroll)` for the rendered output. The `file_clicks` should use `actual_scroll` for consistency.
