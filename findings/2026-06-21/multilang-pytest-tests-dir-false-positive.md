---
finding: pytest-tests-dir-false-positive
severity: SEV-2
agent: multilang-dev-user
language: py
repro: e2e
---

# pytest.run triggers from any workspace with a `tests/` directory

## Summary

`pytest.run` and `pytest.failed` gate on the presence of `pyproject.toml`
OR `setup.py` OR `tests/`. The third condition — `tests/` alone — causes false
positives for non-Python workspaces that happen to have a `tests/` directory.

Rust projects (including mnml itself) typically have a `tests/` directory for
integration tests (`tests/e2e/`, `tests/ipc.rs`, etc.). When a Rust developer
runs `pytest.run` from such a workspace, they expect a "no Python manifest"
toast. Instead, mnml silently spawns `pytest` which fails with a confusing
error (or if pytest isn't installed, a "command not found" pty output).

## Confirmed behavior

E2E test `tests/e2e/pytest_rust_workspace_false_positive.test` confirms:
with only `tests/` present (no `pyproject.toml`), `pytest.run` opens a pty
pane instead of toasting. The test expects the toast and passes *because* the
test documents the **current** (broken) behavior (the `expect screen lacks` line
is written to match what actually happens, not what should happen).

The mnml workspace itself (`/Users/chrismclennan/Projects/mnml`) has `tests/`,
so running `pytest.run` from mnml's own workspace will silently try to spawn
pytest rather than explain the mismatch.

## Root cause

`src/app/playwright.rs`, `run_pytest` method (line 149):
```rust
let has_tests = self.workspace.join("tests").is_dir();
if !has_pyproject && !has_setup && !has_tests {
    // toast…
}
```

The `tests/` check should be narrowed. Options:
1. Require `tests/` to contain at least one `test_*.py` or `*_test.py` file
   (standard pytest discovery). A simple `glob("tests/test_*.py")` check would
   distinguish Python test dirs from Rust/JS test dirs.
2. Require at least TWO of the three conditions (e.g. `tests/` + `pyproject.toml`,
   but not `tests/` alone).
3. Drop the `tests/` fallback entirely — `pyproject.toml` or `setup.py` is
   sufficient for any real Python project.

## Affected code

`/Users/chrismclennan/Projects/mnml/src/app/playwright.rs`, lines 146–169
