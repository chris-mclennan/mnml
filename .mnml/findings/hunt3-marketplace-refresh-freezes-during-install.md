---
severity: SEV-2
status: open
---
# `marketplace.refresh` (and `marketplace.add_source`, which calls it) freezes the whole app — and `quit` hangs — until a running install's child process exits

**Command id / surface:** `marketplace.refresh`, `marketplace.add_source` (palette, `+ source` chip, tab menu, first-launch Private integrations row) — any call of `marketplace.refresh` while a Marketplace install or rebuild is running.

**Reproduction** (from a fresh launch; `MNML_MARKETPLACE_LOCAL=<fx>/slowsrc`, where `slowsrc/slow/` is a local app integration — `build.zig` that installs a shell script as `bin/mnml-slow`, and that script's `--install` does `sleep 12` before writing its manifest):
```
{"cmd":"run-command","id":"integrations.show_marketplace"}
{"cmd":"key","key":"i"}
# wait until `mnml-slow --install` is running (pgrep)
{"cmd":"run-command","id":"marketplace.refresh"}
{"cmd":"toast","text":"PING"}
```
The same freeze with `{"cmd":"run-command","id":"marketplace.add_source"}` + `type "acme"` + `enter` in place of the refresh.

**Expected:** the refresh (or the add) runs at once; the install either keeps going or is cancelled and says so; the UI stays live.

**Actual:** nothing after the refresh line is processed — no ack in `events.jsonl`, no new frame — until the install's child exits. `PING acked after 12s` (the full `sleep`), every run. With a real first-time `zig build` of an integration this is minutes of a frozen editor. Then the install's own "installed slow" toast lands.

**Why (from the source; the freeze itself is what was observed):** `refresh` starts with `st.group.cancel(app.io)` (`src/app/marketplace.zig:492`), and the install worker shares that group. The worker is inside `run` (`marketplace.zig` ~1398), whose `streamRemaining(...) catch {}` on the child's stderr swallows `error.Canceled` and then blocks in `child.wait`, so `group.cancel` on the UI thread waits for the child to finish on its own.

**Same cause, on quit:** `{"cmd":"quit"}` sent while `mnml-slow --install` sleeps 15 s: `{"event":"quit"}` is logged at once, but the process exits only when the child does — `exited after 15s` — because teardown cancels the same group (`src/app/marketplace.zig:219`). Quitting mid-`zig build` waits out the whole build.

**Reproduced:** 4/4 fresh launches for the refresh/add (two with `marketplace.refresh`, one with `marketplace.add_source`, one while the `zig build` step itself was sleeping — 15 s ack); 2/2 for quit.
