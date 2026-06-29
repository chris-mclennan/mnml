---
agent: multilang-dev-user
severity: SEV-3
language: ts
repro: e2e
---

# tree_node_modules_no_gitignore.test has stale/incorrect comment

## What's wrong

`tests/e2e/tree_node_modules_no_gitignore.test` contains:

```
# node_modules WITHOUT .gitignore:
# The tree's ignore walker does NOT filter node_modules (confirmed by unit test
# `tree::tests::node_modules_visible_without_gitignore`). This e2e test
# verifies the workspace opens normally with node_modules in the workspace.
```

Both statements are now wrong after `ac96648`:

1. **Behaviour changed**: `ac96648` added hardcoded artifact-dir hiding in
   `tree.rs::rescan()`. `node_modules` is now HIDDEN by default even without
   `.gitignore`. The comment says "does NOT filter" — wrong.

2. **Unit test doesn't exist**: The comment references
   `tree::tests::node_modules_visible_without_gitignore`. That test was
   renamed/replaced by `tree::tests::artifact_dirs_hidden_without_gitignore`
   (opposite semantics). The referenced test name produces no `cargo test`
   match.

The e2e test itself still passes because its assertions only check that `index.txt`
and `hello` appear on screen — they don't assert on `node_modules` visibility.

## Suggested fix

Update the comment to reflect the new behavior:

```
# node_modules WITHOUT .gitignore:
# ac96648 (2026-06-28): node_modules is now HIDDEN by default even without
# .gitignore — hardcoded in tree.rs::rescan() alongside __pycache__, target,
# .next, dist, build, vendor, .venv. Confirmed by unit test
# `tree::tests::artifact_dirs_hidden_without_gitignore`.
# This e2e test verifies the workspace opens normally (no crash) when
# node_modules exists — the tree just silently omits it.
```

Optionally add a positive assertion:
```
expect screen lacks "node_modules"
```
