---
agent: api-workflow-user
severity: SEV-3
verifies: 4ab2730 e597fa4 591a4b4
surface: multi-block-http
---

Verification run 2026-06-29. Build: release, all lib tests pass.

**1. Multi-block leading-block save (4ab2730)** — PASSES with one caveat.

Both blocks survive on disk. Blank separator line between leading block and first
`### name` is lost (see `http-3rd-redispatch-leading-block-blank-line.md`). No
data loss; file is parseable. The pre-4ab2730 catastrophic overwrite (SEV-1) is
fixed.

**2. Single-block .http save (4ab2730 fallback)** — PASSES.

`splice_http_block` returns `None` when `blocks.len() < 2`. Code falls through
to `std::fs::write(&path, format!("{curl_text}\n"))` — whole-file curl one-liner
overwrite. `request_pane_save_writes_curl_back_to_source` test covers this path.

**3. http.next_block / prev_block viewport reveal (4ab2730)** — PASSES.

`move_to_http_block` calls `b.editor.place_cursor(target_row, 0)` then
`self.reveal_pane(self.active)`. Viewport adjustment is handled per-frame by the
render loop in `src/ui/editor_view.rs` lines 173-192: when `cur_row < buf.scroll +
scrolloff` or the visible offset exceeds the max, `buf.scroll` is updated. The
`reveal_pane` call is redundant (pane is already active) but harmless. The
`scroll_pinned` flag is cleared in the same render frame if the cursor changed, so
pinned viewports also follow.

**4. History headers/body preservation (e597fa4)** — PASSES.

`append_with_global_mirror` stores `headers: Some(&rp.request.headers)` and
`request_body: rp.request.body.as_deref()` for both Ok and Err responses
(`src/app/http.rs` lines 4110-4150). The picker accept handler (`src/app/picker.rs`
lines 762-780) reconstructs `-H 'Name: Val'` and `--data-raw 'body'` from these
fields when present. `append_writes_headers_and_body_to_jsonl` test verifies
the serialization round-trip; older entries without the fields produce a
method+url-only curl (graceful degradation).

**5. [http] default_env config key (591a4b4)** — PASSES.

`EnvSet::select_with_config_default` is called with `self.config.http.default_env
.as_deref()` at all 6 fire sites in `src/app/http.rs` (lines 1520, 1583, 1675,
1843, 2336, 2955). Four-tier precedence (explicit → $MNML_ENV → [http]
default_env → .rqst/config default_env) verified by the
`select_with_config_default_precedence` test in `src/http/template.rs`.
`EnvSet::load` reads `.rqst/env/<name>.env` first then `.mnml/env/<name>.env`,
so `.mnml/` keys win on collision.
