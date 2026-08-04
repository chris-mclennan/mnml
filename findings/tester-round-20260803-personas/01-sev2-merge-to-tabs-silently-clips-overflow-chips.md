# [SEV-2] `layout.merge_to_tabs` silently clips overflow tabs in the resulting leaf strip

**Reproduction** (JSONL IPC, against a workspace with `file1.txt … file10.txt`):
```
{"cmd":"key","key":"esc"}
{"cmd":"open","path":"file1.txt"}
{"cmd":"open","path":"file2.txt"}
{"cmd":"open","path":"file3.txt"}
{"cmd":"open","path":"file4.txt"}
{"cmd":"open","path":"file5.txt"}
{"cmd":"open","path":"file6.txt"}
{"cmd":"open","path":"file7.txt"}
{"cmd":"open","path":"file8.txt"}
{"cmd":"open","path":"file9.txt"}
{"cmd":"open","path":"file10.txt"}
{"cmd":"run-command","id":"layout.spread_to_splits"}
{"cmd":"wait_ms","ms":200}
{"cmd":"run-command","id":"layout.merge_to_tabs"}
{"cmd":"wait_ms","ms":200}
{"cmd":"snapshot"}
```

**Expected**: After the merge, all 10 panes are visible or discoverable from the single leaf's tab strip — either every chip renders, or a `+N more` / overflow chevron affordance sits at the strip's end (same shape as the existing HTTP-filter `+N hidden` chip).

**Actual**: Toast reports "layout: merged 8 splits into 10 tabs". `status.json` shows all 10 panes present, and `rects.json` records exactly **5** `split_tab_chip:*` entries out of the 10 tabs the leaf owns. Panes 5–9 (`file6.txt`..`file10.txt`) are silently invisible in the strip. Related — after `spread_to_splits` on 10 tabs, the last leaf holds tabs `[7,8,9]` but its narrow (~22-cell) strip renders only pane 7's chip; panes 8 and 9 are also invisible in that strip.

**Source pointer**: `src/ui/mod.rs:3583` — the per-leaf strip loop breaks with `if chip_x >= tabs_right { break; }` and never sets a "hidden count". The `+N hidden` chip at `src/ui/mod.rs:3681` is gated on `hidden_tab_count > 0`, which is only populated for the ActivitySection::Http filter case (`src/ui/mod.rs:1631`). Nothing counts silently-clipped tabs.

**Notes**:
- Since the top bufferline's tab loop was retired in favor of per-leaf strips ("Top bufferline's tab loop is being retired in this branch" — `src/ui/mod.rs:1646`), per-leaf strips are the ONLY tab UI. Silent clipping means users lose visual awareness of buffers that ARE in the leaf.
- Users can still reach the hidden buffers via `:bn`/`:bp`/`:b N` / tree click, so data isn't lost — the bug is discoverability. This is exactly the scenario `layout.merge_to_tabs` was built to enable (mass-flatten splits into a single leaf), so the new feature surfaces the gap.
- Suggested fix: at strip-paint time, compute `hidden = tabs.len() - painted_count` and pass that as `hidden_tab_count` regardless of the HTTP-filter path.
