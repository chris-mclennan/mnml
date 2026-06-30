---
agent: multilang-dev-user
severity: SEV-2
language: typescript
repro: e2e
---

# `:npm.run_script` monorepo walk uses workspace root, not editor path

## Summary

`open_npm_run_script_prompt()` calls `find_manifest_dir(&self.workspace, ...)`
while `run_npm_subcommand()` (used by `:npm.build` / `:npm.test`) uses
`most_recent_editor_path()`. In a pnpm/yarn monorepo with no package.json at
the workspace root, `:npm.run_script` toasts "no package.json found" while
`:npm.build` correctly finds the sub-package's manifest.

## Repro (confirmed by e2e)

```
# Workspace layout:
#   (root) — no package.json
#   packages/app/package.json (has scripts)
#   packages/app/src/index.ts (active editor)

open packages/app/src/index.ts

:npm.build   → opens pty with "npm run build" in packages/app/  ✓
:npm.run_script → toasts "npm.run_script: no package.json found" ✗
```

E2e test at `/private/tmp/claude-501/.../npm_run_script_monorepo.test`
catches this: the screen shows `"npm.run_script: no package.json found"`.

## Root cause

`src/app/playwright.rs` line 159:
```rust
pub fn open_npm_run_script_prompt(&mut self) {
    let pkg = find_manifest_dir(&self.workspace, &["package.json"]);
    //                           ^^^^^^^^^^^^ workspace root only
```

vs `run_manifest_command` lines 407-411 (which powers `npm.build`):
```rust
let start_dir = self
    .most_recent_editor_path()        // ← walks from active editor's dir
    .and_then(|p| p.parent())
    .map(|p| p.to_path_buf())
    .unwrap_or_else(|| self.workspace.clone());
```

## Fix direction

Replace `&self.workspace` in `open_npm_run_script_prompt` with the same
`most_recent_editor_path()`-based start dir used by `run_manifest_command`:

```rust
let start_dir = self
    .most_recent_editor_path()
    .and_then(|p| p.parent())
    .map(|p| p.to_path_buf())
    .unwrap_or_else(|| self.workspace.clone());
let pkg = find_manifest_dir(&start_dir, &["package.json"]);
```

Same pattern also applies to `open_go_run_path_prompt` (line 185), but for Go
workspaces the go.mod is almost always at the workspace root, so the impact is
minimal there vs npm monorepos.
