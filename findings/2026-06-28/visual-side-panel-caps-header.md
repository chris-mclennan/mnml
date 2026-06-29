---
agent: drive-mnml
severity: SEV-3
surface: right-panel
---

# "SIDE PANEL" all-caps header diverges from "right panel" vocabulary

Visual confirmation of design-critic finding #5. The empty-state header
reads `" SIDE PANEL"` in screaming-caps bold-dim. Every other surface
naming this feature uses "right panel" lowercase: palette title,
tooltips, whichkey, context menu, toast.

Captured in `/tmp/qa-vis-02-rightpanel.png` (Ctrl+Shift+B opens panel
with empty state).

## Fix
Change header text to `" right panel"`.
