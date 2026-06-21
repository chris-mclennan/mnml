---
finding: runners-manifest-detection-only-checks-workspace-root
severity: SEV-2
agent: power-user-lsp-cheat-test
repro: e2e
---

# Test runner detection (`cargo.* / npm.* / pytest.* / go.*`) checks ONLY the workspace root, never walks up

## Surface

`src/app/playwright.rs::run_manifest_command` + `run_pytest`
(commit `c5b459c`).

## What happens

The shared `run_manifest_command` (used by cargo/npm/go) does:

```rust
let path = self.workspace.join(manifest);
if !path.exists() { /* toast and return */ }
```

…and `run_pytest` does the same for `pyproject.toml`, `setup.py`,
or `tests/`. None of these walk up from the workspace root looking
for a parent directory that owns the manifest.

This breaks a very common dev layout:

- A Cargo workspace at `~/repos/mnml/Cargo.toml`, but you opened
  `~/repos/mnml/site/` directly (e.g. via `cd site && mnml .` or
  via "Open Recent" pointing to a sub-folder).
- A Go module at `~/repos/myapp/go.mod`, but you opened
  `~/repos/myapp/cmd/server/`.
- A Python package at `~/repos/proj/pyproject.toml`, but you opened
  `~/repos/proj/src/proj/`.

In all three cases the manifest exists somewhere up the tree, but
`:cargo.test` / `:go.test` / `:pytest.run` will toast "no Cargo.toml"
/ "no go.mod" / "no pyproject.toml" and refuse to run.

## Repro

`tests/e2e/runners_dont_walk_up.test` — passing — places a Go source
in a sub-directory with no manifest at the workspace root, then
verifies `:go.test` and `:pytest.run` toast. (Real users who opened
the sub-directory see the same toast even though a real run from
inside that subdirectory would work — `go test` and `pytest`
themselves both walk up to find a manifest at runtime, so the
mnml-side check is stricter than the underlying tool.)

## Suggested fix

Walk up from `self.workspace` to filesystem root looking for the
manifest, then run the underlying command from THAT directory (so
the tool finds the right module / package):

```rust
fn find_manifest_dir(start: &Path, manifest: &str) -> Option<PathBuf> {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join(manifest).exists() {
            return Some(dir);
        }
        if !dir.pop() { return None; }
    }
}
```

Then `run_manifest_command` can use the resolved dir as the `cwd`
for the pty, so `cargo test` runs from the workspace root even when
mnml was launched from a sub-directory.

Note that `cargo` itself walks up, so dropping the existence check
entirely and just running `cargo {subcmd}` from `self.workspace`
would also work for cargo (cargo's own walk handles it). But the
mnml-side check still trips the user before cargo gets a chance.

## Severity reasoning

SEV-2 (not SEV-1) because the workaround is "just open the
workspace root" — but for monorepo + tooling layouts where the
sub-package is the natural editing scope, the toast is a surprise.
