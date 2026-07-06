---
finding: stale-multilang-finding-fixtures-now-fail
severity: SEV-3
agent: multilang-dev-user
language: ts | py
repro: e2e
---

Re-ran the `.test` fixtures left behind by prior multilang-dev-user rounds
(`findings/multilang-2026-06-28-redo/*.test`, `findings/multilang-2026-06-28-3rd/*.test`)
against current HEAD (224d471): 32/35 pass, 3 fail:

- `py_requirements_txt_only.test` — asserts `pytest.run` toasts
  `"pytest: no pyproject.toml"` for a `requirements.txt`-only Python project. This was
  the *documented bug* at the time the fixture was written; it has since been fixed
  (`run_pytest` now accepts `requirements.txt` as a valid marker, matching pyright's
  root_markers — see the `multilang 3rd 2026-06-28 SEV-2` comment in
  `src/app/playwright.rs`). The fixture asserts the old broken behavior, so it now
  correctly fails — this is a stale fixture, not a regression.
- `ts_node_modules_tree.test` — asserts `node_modules` appears in the file tree when no
  `.gitignore` suppresses it (the SEV-3 finding at the time: tree/picker
  inconsistency). Current `src/tree.rs` (`multilang 3rd 2026-06-28 F3`) now hardcodes
  hiding `node_modules` / `__pycache__` / `vendor` / `.venv` / etc. in the tree
  regardless of `.gitignore`, matching the picker's existing hardcoded exclusion. The
  inconsistency was fixed by making both surfaces hide unconditionally — again, stale
  fixture asserting old behavior, not a regression.
- `pycache_tree_no_gitignore.test` — same root cause as above, Python side.

None of these represent live bugs — all three are fixtures whose assertions describe
behavior that has since been intentionally changed (for the better) by other fixes.
But they sit in a `findings/` tree that isn't part of `tests/e2e/` or `cargo test`, so
nothing flags them as stale automatically; anyone re-running old finding fixtures for
a "did we regress?" sanity check (as I did here) will see 3 reds and have to manually
dig through git blame/comments to confirm they're obsolete rather than real
regressions. Recommend either deleting these three stale fixtures or moving the
still-relevant subset of `findings/multilang-2026-06-28-*` into `tests/e2e/` as
permanent regression coverage (most of the other 32 are exactly the kind of thing
that belongs in `tests/e2e/` — manifest detection, monorepo cwd, gitignore-driven
hiding — and currently only survive by accident in a findings/ dir that could be
cleaned up at any time).
