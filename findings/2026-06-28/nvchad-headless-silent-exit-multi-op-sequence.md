---
agent: nvchad-user
severity: SEV-1
---

## SEV-1 `--headless --input vim` exits silently mid-session (no stderr, no panic message)

**Reproduction**: The exact trigger is non-deterministic across runs, but reproduced TWICE in this session with the same workflow shape:

```
{"cmd":"open","path":"sample.txt"}
{"cmd":"wait_ms","ms":200}
// ... a chunk of operations: visual-mode select+yank, :%s/...//gc with y/n confirms, 
// :e brand-new.txt, type, :wq, :vsplit, ctrl+w l, run-command view.split_right ...
// Approx 100 IPC commands deep
{"cmd":"snapshot"}                 // last event in events.jsonl
// ----- mnml process exits here. ps -p <pid> shows nothing. No stderr output. -----
// Subsequent IPC commands are accepted into the file but never processed.
```

**Expected**: mnml stays alive until the host sends `{"cmd":"quit"}` (or `restart`). Either crash with a `panicked at` trace on stderr, OR keep going.

**Actual**: Process dies silently. `RUST_BACKTRACE=full` produced an empty stderr file. The headless loop just stops polling the command channel. The host has no way to know — it has to `ps -p <pid>` or notice that `events.jsonl` stopped advancing.

**Source pointer**: unknown. Candidate areas (all touched in the run-up to both observed exits):
* `src/app/layout.rs::split_active` — modifies the layout tree, and at one point I had ~5 panes with multiple `Ctrl+W c` closes interleaved.
* The substitute-confirm `:%s/.../.../gc` prompt loop in `src/app/find.rs` — both exits happened AFTER a `gc` flow that had been answered with `y/n/q` mid-stream.
* The `events.jsonl` writer in `src/ipc/mod.rs` — but a panic there would still hit a backtrace.
* The headless loop in `src/headless.rs` itself — if the redraw loop's `Terminal::draw` returns Err, does the loop bail without a log?

**Notes**: This was the most expensive finding to investigate because there's no breadcrumb. At minimum:
1. Wrap the headless event loop in a `std::panic::catch_unwind` + write the panic payload to `events.jsonl` as a final `"event":"panic","payload":"..."` line so the host learns something.
2. Add a `Drop` guard on `Ipc` that emits `"event":"shutdown","reason":"..."` on every exit path.

Even if the underlying crash is from a third-party crate that catches its own panic, the IPC channel needs a death certificate. Right now headless test scripts can hang waiting for state changes from a corpse.
