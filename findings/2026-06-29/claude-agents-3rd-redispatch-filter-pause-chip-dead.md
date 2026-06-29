---
finding: filter-pause-chip-dead-code
severity: SEV-3
agent: claude-agents-power-user
verifies: 54301a9
repro: e2e
---

## What happened
The " · paused (filter)" chip added in 54301a9 is dead code. It is computed in
`pause_chip` but the filter-mode title format string omits it, so it can never
be rendered. The tests/e2e/agents_filter_pause_chip.test file already documents
this and the test passes (by only verifying the non-broken behavior path).

## Steps to reproduce
1. Open `ai.dashboard`.
2. Press `/` to enter filter mode.
3. Observe the title bar.

## Expected
Title bar shows `· paused (filter)` to indicate live tail is halted while
typing, giving the user visual feedback that refresh is suspended.

## Observed
Title bar shows `Claude Agents · /<query> · enter applies · esc clears` — the
first format branch (filter_mode = true) does not include `pause_chip` in its
format string. Since `p.paused = true` only when `filter_mode = true`, and
filter_mode = true selects the branch that omits `pause_chip`, the chip can
never appear.

## Suspected cause
`src/ui/claude_agents_view.rs:65` — the `if p.filter_mode` branch at line 65
uses a hardcoded format string that does not interpolate `pause_chip`. The chip
is interpolated in the else-if and else branches (lines 76-88), but those
branches only execute when `filter_mode = false`, at which point `p.paused` is
also false (cleared by the same Esc/Enter that clears filter_mode).
