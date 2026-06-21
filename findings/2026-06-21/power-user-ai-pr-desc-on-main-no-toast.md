---
finding: pr-desc-on-main-no-toast
severity: SEV-3
agent: power-user-ai
repro: e2e
---

# `:ai.write_pr_description` on `main` produces a confusing toast ("forgot to commit?")

When the user is sitting on the base branch itself (a common state for
mnml's workflow — small commits straight to `main` per CLAUDE.md), the
flow ends with:

```
ai.pr_desc: HEAD has no changes vs main (forgot to commit?)
```

Verified e2e in headless mode on a one-commit repo with `main = HEAD`.

The toast is technically correct but misleading: the user *did* commit;
they're just on the base branch, so by construction there are no
"branch's commits" to describe. "forgot to commit?" suggests user
error when the actual situation is "you're on main, there's nothing
to PR".

The check at `src/app/ai.rs:2097-2102`:
```rust
if diff_text.trim().is_empty() {
    self.toast(format!(
        "ai.pr_desc: HEAD has no changes vs {base_ref} (forgot to commit?)"
    ));
    return;
}
```

Doesn't distinguish:
- (a) on `main`, merge_base == HEAD → diff is empty
- (b) on `feature/foo` with no diff yet → diff is empty

Same shape applies to `:ai.recompose_branch` at line 1974-1978, which
toasts "HEAD has no commits past main" — clearer wording, copy that
pattern.

**Fix shape**: Detect the on-base-branch case before computing diff.
```rust
let head_sha = git_rev_parse("HEAD")?;
if merge_base == head_sha {
    self.toast(format!(
        "ai.pr_desc: you're on {base_ref} — switch to a feature branch first"
    ));
    return;
}
```

Severity SEV-3 — purely a wording / UX issue, not a correctness bug.
But the new command's first impression on a `main`-workflow user (which
is most mnml users by the project's own convention) is "forgot to
commit?" — that lands wrong.
