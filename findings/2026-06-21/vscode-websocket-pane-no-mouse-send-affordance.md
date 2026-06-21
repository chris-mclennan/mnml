---
severity: SEV-3
surface: Pane::Websocket
hunt: vscode-user mixed-input
date: 2026-06-21
---

## [SEV-3] Websocket pane has no mouse-clickable send affordance, no clickable input row, no "→ Send" button — keyboard-only message sending

**Reproduction**:
```jsonc
{"cmd":"run-command","id":"ws.connect"}
{"cmd":"type","text":"wss://echo.websocket.events"}
{"cmd":"key","key":"enter"}
{"cmd":"wait_ms","ms":1500}
{"cmd":"snapshot"}
// pane shows:
//   ┌ ws · ● open · wss://… · 0 msgs · enter=send · esc=close · ctrl+e=tree ┐
//   │  (log)                                                                │
//   │  ▸ <input prompt>                                                     │
//   └──────────────────────────────────────────────────────────────────────┘
{"cmd":"click","col":15,"row":35,"button":"left"}    // click in the input row
// click *focuses* the pane (via app.rects.editor_panes) but does
// nothing input-specific. The cursor doesn't move into the input
// box, no visual change, no hover affordance.
{"cmd":"hover","col":15,"row":35}
// no tooltip
```

**Expected**: A mouse user who clicks the input row expects either a
visible cursor / focus indicator landing there, or a clickable "Send"
button next to the input. Postman / Insomnia / VS Code's REST Client all
ship a literal send button.

**Actual**: `src/ui/ws_view.rs:99-126` renders the input row as a single
`Paragraph` line with no rect registration. The only mouse interaction
the pane supports is the pane-body `editor_panes` registration
(`ws_view.rs:57`) which focuses the pane on left-click and
`src/app/dispatch.rs:808-817` which scrolls the log on wheel. There is no
hit-test for the input row, no rect for a `Send` glyph (none rendered),
and the header text `enter=send` is the only discoverability surface.
Right-click context menu on the pane is also absent.

The behaviour is internally consistent (it's a TUI, the model is
keyboard-first), but for a VS Code user the lack of *any* mouse-clickable
"send" feels like the pane is read-only.

**Source pointer**:
- `src/ui/ws_view.rs:99-126` — input row, no rects registered
- `src/app/dispatch.rs:808-817` — only wheel-scroll for the log
- `src/tui.rs:1791-1837` — keyboard handlers (Enter/Esc/Ctrl+E/etc.)
- `src/app/http.rs:589-602` — `ws_send_on_active` exists, just no mouse
  caller for it

**Notes**: Two cheap wins —
1. Render a "→ send" pill at the right edge of the input row, register
   its rect, on left-click call `WebsocketPane::send_input`. Mirrors how
   the Request pane has its big "[ Send ]" affordance.
2. Right-click on a previous outgoing log line could re-yank the message
   into the input (mouse-driven retry). Today right-click on the log
   does nothing.

Neither is destructive; both restore parity with the keyboard story.
