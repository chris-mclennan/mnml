---
finding: overwrite-tool-confirm-prompt
severity: SEV-3
agent: power-user-ai
repro: code-review
---

# `:ai.write_branch_name` unconditionally overwrites any open prompt — can swallow an `AiToolConfirm` and hang the worker

`src/app/ai.rs:1890-1895`:

```rust
pub fn request_ai_write_branch_name(&mut self) {
    self.prompt = Some(crate::prompt::Prompt::new(
        crate::prompt::PromptKind::AiBranchNameDescription,
        "describe the branch (NL → branch name):".to_string(),
    ));
}
```

Blindly assigns `self.prompt = Some(...)`. If a different prompt was
already open — most concerning, an `AiToolConfirm` from an in-flight
agent worker — that prompt is silently replaced. The agent worker is
blocked on `confirm_rx.recv()` waiting for an Allow/Deny; the user has
no UI to reach it anymore.

The drain at `src/app/ai.rs:1549` only sets `pending_tool_confirm` when
the worker emits `AiMsg::ConfirmTool`. There is no cleanup path that
clears it when the prompt is displaced — it just sits there until the
user happens to fire something else that opens an `AiToolConfirm`
prompt and accidentally answers the *new* worker's question with the
*old* worker's slot. Practically: worker leaks forever.

Reproduce (IPC):
1. Configure `[ai] api_write_tools = true`, `api_write_confirm = true`.
2. Run a `:ai.chat` that triggers a write_file call → `AiToolConfirm`
   prompt opens.
3. Run `:ai.write_branch_name` via palette / IPC.
4. The tool-confirm prompt is gone. The agent worker is wedged.

The same shape applies to all four new commands when they open prompts
unconditionally (`request_ai_write_branch_name` is the only one that
opens a prompt directly, but the *seeded BranchName* prompt that the
drain handler opens in `pending_branch_name_job` (line 1619) is
similarly unconditional).

**Fix shape**:
- Add a guard at every prompt-opener:
  ```rust
  if self.prompt.is_some() {
      self.toast("close the current prompt first");
      return;
  }
  ```
- Or treat displacement as "deny" and call `self.resolve_tool_confirm(false)`
  if the displaced prompt was an `AiToolConfirm` (mirrors `prompt_cancel`
  at `src/app/picker.rs:1011`).

The `prompt_cancel` path already handles this correctly — the
displacement path is the gap.

Severity SEV-3 because the trigger requires `api_tools = true` with
write_confirm — most users won't hit this. But the failure mode
(silently-wedged worker thread) is bad when it happens.
