---
agent: vscode-user-mouse
severity: SEV-3
---

## VERIFIED — right-panel surfaces that DO work (counter-evidence for the broken sweep)

The other findings in this batch flag broken right-panel mouse paths. For balance, here's what verifiably works with the same harness, so the broken ones are credibly distinguished from a harness defect:

### A. Bufferline filter excludes panel-hosted panes ✓
```jsonl
{"cmd":"open","path":"src/main.rs"}
{"cmd":"wait_ms","ms":500}
{"cmd":"click","col":101,"row":0,"button":"left"}
{"cmd":"wait_ms","ms":500}
{"cmd":"run-command","id":"outline.show"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```
`rects.json` after: only `bufferline_tab:0` (main.rs). The Outline pane (id 1) is NOT in the bufferline strip — `src/ui/bufferline.rs:155-156` filter (`filter(|i| !app.right_panel_panes.contains(i))`) is functional.

### B. Bridge fill from active rightmost tab → × ✓
With a single hosted pane (Outline) the screen at row 1 visibly reads
`"main.rs ⌥                    ×"` — the bg2 fill between the chip end and the × cell is present (the gap is rendered as bg2 spaces, matching the active chip's background). `src/ui/mod.rs:724-742` `bridge_rect` draws this. Visually correct.

### C. Right-click on chips ELSEWHERE in chrome opens menus ✓
- gear `(1, 46)` → 5-item Settings menu opens.
- integration chip `(108, 0)` → "Disable / Edit / Remove" menu opens with the integration name in the title.
- bufferline tab right-click — covered in earlier findings, works.

### D. Empty-state click on `:outline.show` / `:lsp.diagnostics` ✓ (only when panel was preloaded from session)
See `mouse-right-panel-empty-state-click-fails-after-runtime-toggle.md` — the click rect is wired correctly; the failure mode is specific to runtime-toggle. The "happy path" itself works.

### E. Panel toggle button at `(101, 0)` ✓
Click on `palette_right_panel_button` toggles `right_panel_visible` correctly, observed via screen diff and `session.json` round-trip.

### F. `view.right_panel_close_tab` command path ✓
```jsonl
{"cmd":"run-command","id":"view.right_panel_close_tab"}
# → rightPanelPanes:[], outline pane removed
```
…so the underlying `close_pane(pid)` path works. Only the × *click* path can't reach it (see `mouse-right-panel-x-close-left-click-noop.md`).

**Purpose of this file**: future hunters running the same scenarios should expect A-F to pass. If they fail, the harness/binary is broken; if they pass while the other findings still reproduce, the broken-set is real and not a setup artifact.
