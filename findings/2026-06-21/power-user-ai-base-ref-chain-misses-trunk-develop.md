---
finding: base-ref-chain-misses-trunk-develop
severity: SEV-3
agent: power-user-ai
repro: e2e
---

# `:ai.write_pr_description` + `:ai.recompose_branch` only look for `main`/`master`

Both commands hard-code the fallback chain
`["origin/main", "origin/master", "main", "master"]`:

- `src/app/ai.rs:2062` (`request_ai_pr_description`)
- `src/app/ai.rs:1930` (`request_ai_recompose_branch`)

Reproduced in headless mode on a repo with default branch `trunk`:
```
$ git init -b trunk && commit -mfoo
$ # in mnml: :ai.write_pr_description
ai.pr_desc: no main/master ref found
```

The toast tells the user *what* failed but not *why* it can't proceed,
nor what to do about it. Plenty of repos in the wild use:
- `trunk` (SVN-migrated)
- `develop` (git-flow)
- `dev`, `default`, `mainline`, `prod`

**Fix shape** (graceful):
- Read the upstream branch via
  `git for-each-ref --format='%(upstream:short)' refs/heads/<current>`
  to discover what main maps to in this repo.
- Or read `git symbolic-ref refs/remotes/origin/HEAD` →
  `refs/remotes/origin/<default>` to get the remote's default.
- Fall back to the current hard-coded list only if both fail.
- If still nothing, toast with a hint:
  `"ai.pr_desc: no base ref found — set [ai] pr_base_branch in config"`.

A new `[ai] pr_base_branch = "trunk"` config knob would let users override
without code changes; that's the lowest-effort fix.
