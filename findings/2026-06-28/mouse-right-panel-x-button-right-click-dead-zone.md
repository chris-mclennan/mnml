---
agent: vscode-user-mouse
severity: SEV-3
---

## SEV-3 Right-panel × close button right-click is a no-op (1-cell dead zone, render-reviewer #4 still applies)

**Reproduction**:
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":158,"row":1,"button":"right"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```
No context menu opens. No state changes. `right_panel_close` rect at `(158, 1, 1, 1)` is the precise hit zone tested; right-click also at cols 157 and 159 (over the visual `×` area) produces nothing.

**Source pointer**: `src/tui/mouse.rs:932-1364` (the right-click handler block) has explicit cases for `right_panel_tabs` (lines 953-963), `palette_search_chip`, `activity_bar_gear`, every statusline chip, integration chips, launcher chips, dock kebabs, session tabs — but no entry for `right_panel_close`. The cell at (158, 1) is a 1-cell dead zone on right-click.

**Expected (one of)**:
- Mirror left-click (close active tab) so accidental right-click does the same thing — gentlest fix.
- Show a small menu (Close · Close others · Close all) like a regular tab — matches the right-click context-menu UX the rest of mnml's chrome offers.

**Actual**: Silently swallowed. Note that the render-reviewer flagged this in v3 and the commit `6433be3` claims "mouse SEV-2 fix" but the dead zone persists.

**Severity rationale**: SEV-3 — left-click is the canonical close path and the × glyph reads as a close target, so users rarely right-click it. But every other right-click in mnml's chrome (gear, integration, launcher, session tab, bufferline tab, statusline chips, dock kebabs, tree headers) opens a menu — the 1-cell silence is a polish gap.

**Note**: Even if you decide left-click stays the only action, consider documenting the right-click no-op in the tooltip copy at `src/ui/tooltip.rs:334-341` (currently says `"click: close · panel stays open"` with no mention of right-click). Today the tooltip implies right-click does nothing useful; users have to guess.
