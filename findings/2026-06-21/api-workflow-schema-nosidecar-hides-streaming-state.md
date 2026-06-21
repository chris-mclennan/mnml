---
finding: http-revalidate-schema-ignores-streaming-state-pane
severity: SEV-3
surface: http.revalidate_schema
---

**Repro**:
1. Open `requests/users.curl` which has a sibling `requests/users.schema.json`.
2. `:http.send` — response arrives, schema validation runs, footer shows "Schema: ✓ valid".
3. Edit `users.schema.json` to add a new required field.
4. Run `:http.revalidate_schema` — should re-run validation against the existing body with the updated schema.

**Expected**: schema validation runs again against the stored response body; footer updates to "Schema: ✗ 1 error(s)".

**Actual**: Works correctly for `RunState::Done`. However, `http_revalidate_schema` (src/app/http.rs:915–961) only mutates `rp.state` if:
```rust
if let Some(Pane::Request(rp)) = self.panes.get_mut(cur)
    && let RunState::Done(rv) = &mut rp.state
{
    rv.schema_result = Some(result);
}
```
The result is computed from `source_path` which is read in a prior borrow. The validation runs regardless of state, but the result is only applied when the state is `Done`. If the state has since become `Sending` (user hit `r` to re-fire while viewing the Done state), the schema result from the old body is computed and then silently dropped (no mutation, no toast about the state change). The toast always fires ("✓ schema re-validated: valid" etc.), leading the user to believe the new result was applied when it was dropped.

The `summary` toast fires unconditionally at line 937, before the state check at line 955. The user sees "✓ schema re-validated: valid" but the response view footer still shows the old schema result (from the send-time validation) because the mutation was skipped.

**Offending file:line**: `src/app/http.rs:937` — toast fires before state check at line 955 confirms the result was actually stored.
