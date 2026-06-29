---
agent: input-handler-reviewer
severity: SEV-1
introduced_by: 4548d64
panic_path: dead-code-not-panic
---

# Browser Alt+Left / Alt+Right is dead code — global nav.back/forward eats it first

`nav.back` / `nav.forward` are registered globally with `keys:
&["alt+left"]` / `keys: &["alt+right"]` (command.rs:1743-1754). The
chord-chain dispatcher fires those FIRST and consumes the keys. My new
arms in `pane.rs:565-566` (browser Alt+Left/Right back/forward) never
execute.

## Fix
Either (a) move browser routing INTO `nav.back`/`nav.forward` behind a
pane-type check — when active pane is Browser, fire `browser_back()`
instead of `nav_back_jump()` — or (b) use Ctrl+Alt+Left/Right for
browser history.

(a) is more user-natural (same chord works for both contexts).
