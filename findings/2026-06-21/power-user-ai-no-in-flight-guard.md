---
finding: no-in-flight-guard
severity: SEV-2
agent: power-user-ai
repro: code-review
---

# All 4 new AI commands have no in-flight guard — rapid re-fire orphans the first job

`:http.ai_build` already established the pattern (`src/app/http.rs:444-447`):

```rust
if self.http_ai_build_in_flight {
    self.toast("http.ai_build: a build is already in flight");
    return;
}
```

None of the four new commands have this guard:

- `:ai.write_pr_description` — `src/app/ai.rs:2059-2129`
- `:ai.explain_diff` — `src/app/ai.rs:2013-2050`
- `:ai.write_branch_name_accept` — `src/app/ai.rs:1899-1918`
- `:ai.recompose_branch` — `src/app/ai.rs:1929-2005`

Each unconditionally sets `self.pending_<flow>_job = Some(new_job_id)`,
overwriting the previous job id without cancelling its worker.

**Concrete failure mode** (`:ai.explain_diff` shown; identical shape for
the other three):

1. User runs `:ai.explain_diff` → spawns job A, `pending_explain_diff_job = Some(A)`.
2. User runs `:ai.explain_diff` again (impatient — the first is still
   streaming). Spawns job B; `pending_explain_diff_job = Some(B)`.
3. Job A finishes, sends `AiMsg::Done(text_a)` with `job_id = A`.
4. The drain at `src/app/ai.rs:1677` tests
   `self.pending_explain_diff_job == Some(A)` — **false** (it's `Some(B)`).
   Falls through past all four `pending_*_job` blocks.
5. Falls to the fallback at line 1806:
   ```rust
   let Some(Pane::Ai(a)) = self.panes.iter_mut().find(|p|
       matches!(p, Pane::Ai(a) if a.job_id == job_id && ...))
   else { continue; };
   ```
   No `Pane::Ai` has `job_id == A` (none was ever opened — these flows
   route through `pending_*_job` slots, not `Pane::Ai`). The message is
   **silently dropped**.

Net effect:
- User's first Claude call: tokens billed, no scratch produced, no toast.
- Worker thread for job A keeps streaming until completion regardless
  (`_cancel` arc is dropped immediately on caller frame since
  `spawn_ai_job` returns `(job_id, _sid, _cancel)` and the caller does
  `let (_, _, _cancel) = …`). API tokens silently burned.

**Test plan**:
- [ ] Mirror `http_ai_build_in_flight` — add `pending_<flow>_job.is_some()`
      check at entry, toast "already in flight", `return`.
- [ ] Or store the cancel arc per slot and signal cancel on the orphaned
      old job before overwriting.
