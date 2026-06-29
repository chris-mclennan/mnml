---
agent: claude-agents-power-user
severity: SEV-3
surface: right-panel + palette
---

# "evict active tab" (whichkey) vs "close the active tab" (palette) — two descriptions, one action

`view.right_panel_close_tab` registered in `src/command.rs:1557` with
title `"Right panel: close the active tab"`. Wired in whichkey at
`src/whichkey.rs:129` with label `"right panel: evict active tab"`.

Palette search shows `title`; whichkey overlay shows the label.
Users who see "evict active tab" in whichkey will not find it in the
palette searching for "evict" — and users searching "close tab" in the
palette won't recognize the whichkey entry.

Note: design-critic flagged this same item (low severity #6). Both
agents independently surfaced the discoverability problem.

## Fix
Pick one verb — "close" is the common term across the rest of the
codebase ("Close tab" context menu, "close active tab" × tooltip).
Change whichkey label from "evict active tab" → "close tab".
