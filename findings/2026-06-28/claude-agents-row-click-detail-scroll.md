---
agent: claude-agents-power-user
severity: SEV-3
surface: claude-agents-dashboard
---

# Mouse click on a row doesn't reset detail_scroll; keyboard nav does

`j`/`k`/PageUp/PageDown call `move_up()`/`move_down()` which contain
`self.detail_scroll = 0`. A single mouse click routes through
`handle_scm_row_click` at `src/app/dispatch.rs:1191-1201`, which does
`p.selected = flat_idx` but no `p.detail_scroll = 0`.

Repro: open a session's Bash view, scroll it with Shift+PgDn so
detail_scroll > 0, then single-click any other row. The drill-down
updates to the new row's content but stays scrolled at the old offset.
If the new row has fewer Bash commands, the panel renders with content
scrolled past — appears empty or cut off until the user scrolls up.

Site: `src/app/dispatch.rs:1195` — add `p.detail_scroll = 0` alongside
the `p.selected = flat_idx` assignment.
