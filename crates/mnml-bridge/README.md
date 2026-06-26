# mnml-bridge

Bridge / Mount protocol for [mnml](https://github.com/chris-mclennan/mnml)
sibling tools.

This crate gives sibling tools a way to render their UI as a
first-class pane *inside* mnml — owning the activity-bar icon, the
rail content area, and the editor body area — instead of running as a
plain `Pty` pane that draws into stdout.

## The four tiers

| Tier | What | Sibling sees |
|---|---|---|
| 1. Env vars | mnml sets `MNML_WORKSPACE`, `MNML_THEME`, `MNML_IPC_DIR` on every spawned Pty. | Just read env vars at startup. |
| 2. JSONL sibling→host | Sibling appends JSONL commands to `$MNML_IPC_DIR/command` — `toast`, `open-pty`, `open`. | Append a line to a file. |
| 3. mnml-bridge SDK | This crate — typed Rust API for tiers 1 + 2 + the Mount protocol. | `use mnml_bridge::*;` |
| 4. Mount | Sibling connects to a Unix socket per mount, streams cell + style frames back, receives input. | Implement a small render + input loop. |

## Wire shape

Length-prefixed JSON. Every message is 4 bytes LE length + that many
bytes of UTF-8 JSON body.

**Host → Sibling**
- `Hello { geometry, theme }` — first message on connect
- `Resize { geometry }` — on terminal resize
- `Input { event }` — forwarded key / mouse event
- `Goodbye` — host shutting down or unmounting

**Sibling → Host**
- `Frame { cells }` — full screen of cells; host stamps into its frame
- `Bye` — sibling exiting

## License

MIT OR Apache-2.0
