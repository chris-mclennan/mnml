---
finding: http-panel-filter-section-header-counts-not-filtered
severity: SEV-3
surface: http.send
---

**Repro**: numbered steps (headless IPC harness).

1. Workspace with a `requests/` collection (multiple `.curl`/`.http` files),
   an `.rqst/env/dev.env`, and several prior `http.send` calls logged to
   `.rqst/history.jsonl`.
2. Click the HTTP activity-bar icon to open the HTTP panel.
3. Click `/ filter`, then type a query that matches only ONE item overall
   (e.g. `badurl`, matching a single `.curl` file, but not the `dev` env
   name and not any recent-history URL).

**Expected**: Per the task's documented behavior ("`/` focuses the filter
row, typing narrows across all seven sections FILES / RECENT / CAPTURED /
ENVS / CHAINS / MOCKS / COLLECTIONS"), every section's row list AND its
`(N)` count badge should reflect the filtered result set.

**Actual**: The **rows** filter correctly (e.g. the ENVS section's `○ dev`
row disappears when the filter doesn't match "dev"; the RECENT section
shows zero rows when no history entry matches). But every top-level
section header's `(N)` count badge keeps showing the **unfiltered total**,
producing a misleading combination like:

```
▼ RECENT (11)
                              ← zero rows rendered here (all filtered out)
▼ ENVS (1)
  + New env                  ← the "○ dev" row is gone (doesn't match filter)
                              ← but the header still says "(1)"
```

A user reads "RECENT (11)" and reasonably expects 11 rows below it; instead
there are none, with no visual indication that the count is stale vs. the
filter having genuinely emptied the section.

Root cause: `src/ui/http_panel.rs` computes each section's header count
directly from the raw, unfiltered cache length and passes it straight to
`draw_section_header`:

```rust
// src/ui/http_panel.rs:148-151
let files_len = app.http_panel_files_cache.len();
let recent_len = app.http_panel_recent_cache.len();
let captured_len = app.http_panel_captured_cache.len();
let envs_len = app.http_panel_envs_cache.len();
let chains_len = app.http_panel_chains_cache.len();
let mocks_len = app.http_panel_mocks_cache.len();
```
and (line 207) `let collections_len = app.http_panel_collection_roots.len();`
— none of these account for `app.http_panel_filter`. `draw_section_header`
(line 391-415) then renders `count_str = format!(" ({count})")` verbatim.

Meanwhile the row-drawing functions (`draw_recent` at line 852-856,
`draw_envs`, etc.) DO correctly consult `app.http_panel_filter` per-row and
skip non-matching entries — so the mismatch is specifically the header
badge vs. the body, not the filter mechanism itself (which works). This
reproduces identically across all six section headers that use a
`_cache.len()` (FILES, RECENT, CAPTURED, ENVS, CHAINS, MOCKS) plus
COLLECTIONS' `collection_roots.len()`.

**IPC trace** (screen.txt before/after typing filter "badurl"):
- Unfiltered: `▼ ENVS (1)` with row `○ dev` visible.
- Filtered to "badurl": `▼ ENVS (1)` — header unchanged — but the `○ dev`
  row is no longer rendered (correctly filtered out since "dev" doesn't
  match "badurl").
- Same pattern on `▼ RECENT (11)`: header stays "(11)" while zero history
  rows render underneath.

**Notes**: `src/ui/http_panel.rs:148-153` (cache-length header counts) +
`:207` (`collections_len`) + `:391-415` (`draw_section_header`, where the
count is rendered). Fix: compute each section's count as the number of
items that pass the same `filter_lc` predicate its row-drawer already
uses (or have the row-drawers return a post-filter count that the header
render step consumes), rather than the raw cache length.
