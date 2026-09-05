---
severity: SEV-2
status: open
---
# Toast right-click menu is painted underneath the toast and past the statusline — two of its three items are invisible

**Command id:** `context_menus.openToastMenu` (toast right-click). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"toast","text":"hello toast","level":"warn"}
{"cmd":"wait_ms","ms":50}
{"cmd":"click","col":108,"row":35,"button":"right"}
{"cmd":"dump-rects"}
{"cmd":"snapshot"}
```
**screen.txt** rows 33–39, cols 95–120:
```
            ╭─────────────
            │ hello toast
            ╰─────────────
            │─────────────
Col 2  ⚠ 2  │    Dismiss
            ╰─────────────
```
**rects.json**:
```
{"label":"menu_item:0:0","x":100,"y":35,"w":18,"h":1}   ← hidden under the toast box
{"label":"menu_item:0:1","x":100,"y":36,"w":18,"h":1}   ← hidden under the toast box
{"label":"menu_item:0:2","x":100,"y":38,"w":18,"h":1}   ← "Dismiss", painted over the statusline row
{"label":"button:1879048192","x":99,"y":34,"w":20,"h":3}
```

**Expected**: the menu opens above the pointer when there is no room below and is painted on top of the toast (VS Code context menus always flip to fit and are the topmost layer).
**Actual**: the menu anchors at the click row, runs off the bottom (`Dismiss` sits on the statusline), and the toast is painted after it, covering items 0 and 1. The user sees only `Dismiss`; the other two rows are clickable but invisible.

**Source pointer**: `src/app/context_menus.zig:204` `openToastMenu` (anchor = click x,y with no flip); toast painting order vs. menu overlay in `src/app/render.zig`.
