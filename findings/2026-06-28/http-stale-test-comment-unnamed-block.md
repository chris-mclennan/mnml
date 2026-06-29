---
agent: api-workflow-user
severity: SEV-3
---

**surface**: multi-block-http

**Finding**: Stale comment in `splice_http_block_handles_unnamed_leading_block` unit test contradicts post-fix behavior.

**Repro**:

1. Read `src/app/http.rs` lines 4333-4336.
2. The comment says:
   > "The save path won't reach `splice_http_block` for None, so this test documents what `splice_http_block` does in case it's called."

**Expected**: The comment accurately describes current behavior.

**Actual**: After commit 5020def, `save_request_to_source` now ALWAYS enters the splice path for `.http` / `.rest` files regardless of whether `source_block_name` is `None` or `Some`. The comment's claim that "the save path won't reach `splice_http_block` for None" is now false — it's exactly what the fix made happen.

The test still passes (the function behavior is correct), but the comment misleads anyone reading it into thinking this is dead-code documentation rather than a live code path.

**Notes**:

- No runtime impact. Purely a documentation issue.
- Relevant line: `src/app/http.rs:4333-4336` (in `splice_http_block_handles_unnamed_leading_block` test).
- Can be fixed with a one-line comment update.
