---
finding: dead-scroll-field
severity: SEV-3
agent: claude-agents-power-user
repro: e2e
---

## What happened
`ClaudeAgentsPane` has a `pub scroll: usize` field (declared at `src/claude_agents.rs:235`) that is never read by the renderer or updated by navigation. The renderer in `src/ui/claude_agents_view.rs` computes its own local `scroll` variable from `sel_line` and `body_h` per frame. The stored field is always 0 and serves no purpose, which is confusing for anyone reading the struct definition.

## Steps to reproduce
1. Open `:ai.agents_dashboard`.
2. Navigate down past the viewport.
3. Add a log/breakpoint on `p.scroll` — it never changes from 0 even when the display has scrolled.

## Expected
Either `scroll` is updated to track the rendered viewport offset (useful for persistence or testing), or it is removed from the struct.

## Observed
`scroll` stays 0 while the display scrolls via the locally-derived variable. Dead state in the pane struct.

## Suspected cause
`src/claude_agents.rs:235`: `pub scroll: usize` field is initialized to 0 and never written. The auto-scroll logic computes a local `scroll` in `draw()` at `src/ui/claude_agents_view.rs:171-175` without reading the struct field. This is a leftover from an earlier design where scroll was tracked explicitly.
