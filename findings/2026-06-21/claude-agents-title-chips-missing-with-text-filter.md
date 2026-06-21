---
finding: title-chips-missing-with-text-filter
severity: SEV-3
agent: claude-agents-power-user
repro: e2e
---

## What happened
When a text filter is active (user pressed `/`, typed a query, pressed Enter), the title bar switches to a compact format that omits the `source_chip`, `ws_chip`, `multi` count chip, `count_chip` (visible/total), and `sort:X` label. If the user also has a source filter (`>`), workspace filter (`w`), multi-select (`space`), or a non-default sort (`s`) active alongside a text filter, all those chips silently disappear from the title.

## Steps to reproduce
1. Open `:ai.agents_dashboard`.
2. Press `s` a couple times to set sort to "cost↓".
3. Press `>` to set source filter to "claude".
4. Press ` ` to multi-select the focused row.
5. Press `/`, type "cargo", press Enter.
6. Observe the title bar.

## Expected
Title bar shows all active chips: source filter, sort mode, multi-select count, visible/total count.

## Observed
Title bar shows only `Claude Agents · filter: cargo · ○idle · / edit · ? help` — sort, source, multi-select, and count chips are all missing.

## Suspected cause
`src/ui/claude_agents_view.rs` at line 49-53: the `!p.query.is_empty()` branch formats a header that only includes `state_chip` and `pause_chip`. The other chips (`source_chip`, `ws_chip`, `multi`, `count_chip`, `sort`) are only in the `else` branch (no query). The fix is to include all active chips in the non-filter-mode non-empty query branch.
