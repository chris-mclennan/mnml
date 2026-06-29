---
agent: vscode-user
severity: mixed
verifies: 12eb3a8d (HEAD), since b767b8c (~25 commits)
---

# QA Sweep — round 5 (VS Code persona)

## Executive summary

Found **3 SEV-2** + **1 SEV-3**. The right-panel chrome and spend-abort
machinery shipped 9185f65/035b69b are rock-solid (Ctrl+Shift+B / Ctrl+Alt+W /
× right-click / Close-other-tabs all crisp; no zombie workers after a 5-cycle
rapid open/close). Workspace-affinity Ctrl+P, recursive lookups, and
`[http] default_env` all worked as advertised. Two structural gaps surfaced:
the IPC "death certificate" is **unreachable** on SIGTERM/SIGKILL (its only
trigger is `Drop`, which Rust does not run for default-disposition signals
on Unix), and `http.next_block` / `http.prev_block` reject `.curl` files even
though every other HTTP code-path accepts the trio `http | rest | curl`. Add
a SEV-2 session-restore desync where buffer #2 was kept alive but not added
to the layout's tab list, leaving the bufferline strip missing the active
tab. Overall feel: mnml's VS-Code-shaped chrome is in great shape; the
weaknesses are in the seams between subsystems.

---

## [SEV-2] `http.next_block` / `http.prev_block` reject `.curl` files

**Reproduction**:
```jsonc
{"cmd":"open","path":"http/multi.curl"}   // .curl with two ### blocks
{"cmd":"click","col":40,"row":3}          // focus the editor
{"cmd":"run-command","id":"http.next_block"}
{"cmd":"snapshot"}                        // cursor does NOT move
```
Repeat with `multi.http` (identical content, `.http` ext) — cursor jumps to
the next `###` correctly.

**Expected**: `.curl` is the dominant HTTP file extension in the workspace
(used by `http.send`, `http.lookup`, `http.save_response`, …). Block nav
should accept it.
**Actual**: `move_to_http_block` toasts "needs an open .http or .rest file"
and returns. The toast doesn't even bubble visibly when the command is
fired from the palette / chord (the user just sees nothing happen).
**Source**: `src/app/http.rs:1764` —
```rust
if !matches!(ext.as_str(), "http" | "rest") {
```
Compare sibling guards at `src/app/http.rs:2328` and `:2919`, which read
`"http" | "rest" | "curl"`.
**Notes**: One-line fix. Listed in the QA scope under "HTTP block nav
(<leader>h] / h[)" and read as "shipped"; it isn't, on .curl.

---

## [SEV-2] IPC death certificate never fires on SIGTERM / SIGKILL

**Reproduction**:
```bash
./target/release/mnml --headless --input standard $WS &
PID=$!
sleep 1.5
kill -TERM $PID            # or -KILL
sleep 0.5
tail -3 $WS/.mnml/ipc/events.jsonl
```

**Expected**: `events.jsonl` ends with the `{"event":"shutdown","reason":"unexpected",...}`
death-certificate line. The QA spec says: "Drop fires on stdlib teardown
even on SIGTERM".
**Actual**: Last event is `{"event":"key","key":"esc"}` (or whatever was
last processed). No shutdown line — on either SIGTERM or SIGKILL. Hosts
watching for an end-of-session marker hang.
**Source**: `src/ipc/mod.rs:236-251` — the certificate is emitted only
from `impl Drop for Ipc`. On Unix, default disposition for SIGTERM/SIGINT/
SIGHUP/SIGQUIT/SIGKILL is `_exit`-style termination; Rust's stdlib does
not install a handler that drains destructors. A separate `signal-hook`
crate (or a `ctrlc` hook installed in `headless::run`) is required.
**Notes**: Happy-path `quit` works (writes `exit` event before drop).
The bug is the assumption baked into the QA spec, not the code's intent —
but as shipped, the death certificate covers strictly fewer cases than
the comment claims ("ipc drop without happy-path exit" reads as if Drop
is reachable from termination signals; it isn't).

---

## [SEV-2] Session restore can leave an active buffer with no bufferline tab

**Reproduction**: This emerged from a multi-quit restart cycle (after the
HTTP env tests had opened multi.curl + multi.http + env-test.curl +
vim-test.txt + posts.curl). After a final `quit` the session saved:
```jsonc
"open":   [main.rs, posts.curl, vim-test.txt],   // 3 entries
"active": null,
"layout": null,
"layouts": [null]
```
On relaunch:
- `status.json` reports `activePane: 2` (`vim-test.txt`), cursor at line 2.
- The editor body renders vim-test.txt content.
- The bufferline strip exposes only `bufferline_tab:0` (main.rs) and
  `bufferline_tab:1` (posts.curl). No `bufferline_tab:2`.
- Statusline says "vim-test.txt", but a mouse user has nothing to click
  to switch back to it after navigating away.

**Expected**: Either (a) session restore should NEVER write `layout: null`
when `open` is non-empty (synthesise a single LeafTabs containing every
open buffer), or (b) the bufferline should derive its tab list from the
buffer set, not from a possibly-stale layout.
**Actual**: Active pane is unreachable via tab clicks until the user uses
Ctrl+P or a buffer-cycle chord. Clicking the visible main.rs tab does
restore sanity (activePane becomes 0), but vim-test.txt is now
permanently hidden in the strip while still living in the pane list.
**Source**: session save in `src/app/session.rs` (writes `active: null`
when no LeafTabs has focus during a transient state); restore in
`src/app/session.rs` / `src/app/mod.rs` doesn't reconcile a non-empty
`open` list against a null `layout`.
**Notes**: Reachable from an "all panes closed via Ctrl+W" + quit sequence
that empties the layout but leaves recently-opened buffers in `open[]`.

---

## [SEV-3] `http.next_block` failure-mode produces an invisible toast

**Reproduction**: Same as the SEV-2 above — `http.next_block` on a `.curl`
file fires `self.toast("http.next/prev_block: needs an open .http or
.rest file");` but nothing visible appears.
**Expected**: A toast labelled with that text in the bottom-right corner
(the spend report's "computing spend…" toast lives in the same surface
and is clearly visible).
**Actual**: No toast renders. `events.jsonl` shows
`{"event":"command_run","id":"http.next_block","ok":"true"}` — the
command is "ok" even though it didn't do its job. The user gets zero
feedback.
**Source**: `src/app/http.rs:1765` — the toast may be suppressed when
fired during the same tick as the run-command dispatch. Either fix the
guard (the SEV-2 fix) or surface the toast.
**Notes**: Same toast-suppression pattern likely applies to the other
two failure branches in `move_to_http_block` (parse error, empty
blocks). Worth verifying once the .curl guard is widened.

---

## Verified clean (no findings)

- **Right panel chrome (Ctrl+Shift+B / Ctrl+Alt+W / × menu / Close other / Close all)** — all four routes worked; context menu shows "Close tab / Close other tabs / Close all tabs / Hide side panel". Empty-state click-rects `right_panel_empty_{outline,diagnostics,ai,grep,test}` all hit and routed correctly.
- **Right-panel persistence across restart** — `right_panel_tabs: ["outline","diagnostics"]` survived a quit + relaunch; AI/Grep/Test cleared as designed.
- **Spend rapid open/close (5x in 10s)** — toast cycle behaved; final `ps -M` showed 3 Mach threads (main + 2). No phantom workers.
- **Picker workspace affinity (Ctrl+P)** — local `api/v1/posts.curl` and `api/v2/posts.curl` beat shorter-named recents from `tattle-claude-workspace` and `tattle-mnml-workspace`.
- **`[http] default_env = "staging"`** — after fixing the env file format (`.mnml/env/staging.env`), `{{host}}` in a `.curl` was substituted with `staging.example.com` at send time.
- **HTTP recursive lookups** — `http.lookup` showed `auth/login.curl`, `users/list.curl`, and `top.curl` (all three depths) from `.rqst/lookups/`.
- **Vim `de` / `d$` inclusivity** — `de` deletes "hello" inclusive of the 'o'; `d$` clears the line through the last char.
- **Happy-path shutdown event** — `quit` IPC command writes `{"event":"exit"}` to events.jsonl as expected.

---

## File pointers

- `src/app/http.rs:1764` — SEV-2 .curl block-nav guard.
- `src/ipc/mod.rs:236-251` — Drop-only death certificate; SEV-2 signal gap.
- `src/app/session.rs` (save + restore paths) — SEV-2 layout-null reconciliation.
- workspace used: `/private/tmp/claude-501/-Users-chrismclennan-Projects-mnml/7315bf76-e114-4769-826c-eaed0af4e84c/scratchpad/qa-sweep-1`.
