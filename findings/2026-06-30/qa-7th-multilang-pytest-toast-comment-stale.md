---
agent: multilang-dev-user
severity: SEV-3
language: python
repro: e2e
---

# Stale comment in `pytest_runner_missing_manifest.test`

## Summary

The comment in `tests/e2e/pytest_runner_missing_manifest.test` line 2 says:

```
# Should toast "pytest: no pyproject.toml / setup.py / tests/ at ..."
```

But the actual toast (from `src/app/playwright.rs` line 296-299) is:

```
"pytest: no pyproject.toml / setup.py / requirements.txt / test files at {workspace}"
```

The comment predates the `requirements.txt` detection addition (SEV-2 fix
from the previous round). The test itself still passes because
`expect screen contains "pytest: no pyproject.toml"` is a substring match,
not an exact match.

## Impact

Low — tests pass, toast text is user-visible and correct. The comment just
misleads a future developer reading the test.

## Fix

Update line 2 of `tests/e2e/pytest_runner_missing_manifest.test`:

```
# Should toast "pytest: no pyproject.toml / setup.py / requirements.txt / test files at ..."
```
