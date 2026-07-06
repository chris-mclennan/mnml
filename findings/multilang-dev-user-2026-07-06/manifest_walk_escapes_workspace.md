---
finding: manifest-walk-escapes-workspace-boundary
severity: SEV-2
agent: multilang-dev-user
language: ts | py | go
repro: workspace-fixture (code-read; live e2e repro attempted but blocked by harness — see notes)
---

`find_manifest_dir()` (src/app/playwright.rs:672-687), used by `run_npm_subcommand`,
`run_pytest`, and `run_go_subcommand` (via `run_manifest_command`), walks parent
directories looking for `package.json` / `pyproject.toml` / `go.mod` etc. with **no
boundary check against `self.workspace`**:

```rust
pub fn find_manifest_dir(
    start: &std::path::Path,
    manifests: &[&str],
) -> Option<std::path::PathBuf> {
    let mut cur = start.to_path_buf();
    loop {
        for m in manifests {
            if cur.join(m).exists() {
                return Some(cur);
            }
        }
        if !cur.pop() {
            return None;
        }
    }
}
```

The loop only stops at the filesystem root (`cur.pop()` returning `false`), never at
`self.workspace`. This is deliberate for the *monorepo sub-package* case (2026-06-28
fix: walk up from the active editor's dir to find a package.json above a nested
package) — but it means that if the **opened workspace itself** has no manifest
anywhere inside it, the walk keeps going *above* the workspace root into ancestor
directories the user never opened.

Concretely: open mnml on `~/scratch/demo` (no package.json anywhere under `demo/`),
where `~/scratch/package.json` happens to exist (a sibling scratch project, a stray
leftover, or literally `~/package.json` from some other tool). `:npm.test` will
silently `cd ~/scratch && npm test` — running an unrelated project's test suite
inside a pty pane labeled as if it were the open workspace's, with no toast or
indication that the command executed *outside* the folder the user opened. Same
applies to `pytest.run` walking up past a workspace root to a `pyproject.toml` in a
parent monorepo/home directory, and `go.test` walking up to an unrelated `go.mod`
(e.g. `$HOME/go.mod` or a scratch dir some other Go tool created).

This is the same class of bug the 2026-06-21 and 2026-06-28 fixes addressed (comments
right above this function reference both), but those fixes only handled walking
*correctly within* the workspace tree — they never added a stop condition at
`self.workspace` itself. The fix should clamp the walk: stop (and fall back to the
existing "no manifest found" toast) once `cur` is no longer a prefix of
`self.workspace` (or, if `start` was already outside the workspace, at minimum stop at
filesystem boundaries `/`, `$HOME` — not walk into arbitrary ancestor dirs the user
never added as a workspace).

Notes: I attempted a live headless repro (nested `/tmp/manifest-escape-test/inner/subdir`
opened as workspace, with `/tmp/manifest-escape-test/package.json` as the escape
target) but ran out of turn budget getting the IPC handshake to come up in time under
`--headless` before the harness needed to exit; the `cargo run -- test` E2E runner
auto-generates its own temp workspace root and doesn't expose a way to point it at a
pre-existing nested directory, so this needs a manual `./run.sh ~/scratch/demo` repro
to confirm the live toast/pty-cwd, not just the code read. The code path itself is
unambiguous, though — worth a second pass with `cargo test find_manifest_dir` style
unit tests asserting `find_manifest_dir(start, ..)` never returns a path that isn't
a descendant-or-self of the workspace root.
