## [SEV-1] Multi-cursor insert panics on `is_char_boundary` assertion

**Symptom**: mnml crashes with `panicked at src/editor/mod.rs:2671:35: assertion failed: self.is_char_boundary(idx)` when typing into a multi-cursor state where an extra cursor's byte position has become stale relative to the current buffer.

Log excerpt (from `/tmp/mnml-headless.log`):

```
thread 'main' (26403569) panicked at src/editor/mod.rs:2671:35:
assertion failed: self.is_char_boundary(idx)
```

**Reproduction (intermittent)**: The crash reproduced during a session with mixed alt-click multi-cursor, Ctrl+D word-picks, undo/redo, and repeated typing on `src.py`. The final IPC pattern the log confirms just before shutdown:

```
{"cmd":"open","path":"src.py"}
{"cmd":"key","key":"ctrl+home"}
{"cmd":"key","key":"end"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"left"}
{"cmd":"key","key":"ctrl+d"}
{"cmd":"key","key":"ctrl+d"}
{"cmd":"type","text":"XX"}
```

In the failing session that path had been walked once already with several undo/redo/paste cycles between; a clean workspace run of the exact sequence above reproduces the WRONG-position-insertion bug (see SEV-2-ctrl-d-second-cursor-wrong-position) but did not always panic. The panic is the terminal failure mode of the same root cause.

**Expected**: Multi-cursor typing never panics; extra cursors either follow the delete/insert semantics correctly or are dropped/clamped.

**Actual**: `insert_str(p, s)` is called with `p` past-end (or mid-UTF-8) because `delete_selection_if_any` on the primary cursor shrinks `self.text` but does NOT rebase extra_cursors / extra_anchors, so any extra cursor whose byte offset was past the deleted range stays at its old value.

**Source pointer**: `src/editor/mod.rs:2650` (`InsertChar` calls `delete_selection_if_any` at 2651, then multi-cursor branch at 2653 uses stale `extra_cursors`). Root cause is `delete_selection_if_any` at `src/editor/mod.rs:3968` — updates `self.cursor` + `self.anchor` only, leaves `extra_cursors` / `extra_anchors` unshifted. When the stale offset lands mid-multibyte-char (UTF-8 workspace) the `insert_str` assertion fires.

**Notes**: Also reproducible mechanism for the SEV-2 wrong-position bug on ASCII buffers (same root cause; the panic is the pathological subset when the stale offset crosses a UTF-8 boundary or exceeds `text.len()`). Reproduced in a workspace with CJK content still writes to the wrong byte, but stays inside a boundary — no panic in the shorter runs. In the failing 45-min session the accumulated drift eventually landed on a bad byte and killed the process.
