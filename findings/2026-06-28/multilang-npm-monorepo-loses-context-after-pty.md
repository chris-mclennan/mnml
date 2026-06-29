---
agent: multilang-dev-user
severity: SEV-2
language: ts
repro: e2e
---

# npm monorepo nearest-pkg fix loses context after first pty pane opens

## Behaviour

The `5d4c4f0` monorepo fix walks up from the **active editor's directory** to find the
nearest `package.json`. This works correctly for the first runner command while an
editor pane is focused. However, once the first command opens a pty pane (which
becomes the active pane), all subsequent npm/go/pytest commands fall back to the
**workspace root** — causing a false "no package.json found" toast for monorepos where
the root has no manifest.

## Repro sequence

```
# workspace has no package.json at root
mkdir -p packages/app/src
echo '{"scripts":{"test":"jest","build":"webpack"}}' > packages/app/package.json
echo "export const x = 1;" > packages/app/src/index.ts
```

1. Open `packages/app/src/index.ts` (editor active → correct context)
2. Run `npm.test` → opens pty → pty becomes `app.active`
3. Run `npm.build` → `active_editor()` returns `None` (pty is active)
4. Falls back to `self.workspace` (root, no package.json) → toast:
   `npm.build: no package.json found in <workspace> or any parent`

## Code path

`run_manifest_command` (src/app/playwright.rs ~line 401):

```rust
let start_dir = self
    .active_editor()               // None when pty is active
    .and_then(|b| b.path.as_ref())
    .and_then(|p| p.parent())
    .map(|p| p.to_path_buf())
    .unwrap_or_else(|| self.workspace.clone());  // ← falls back to root
```

After `open_pty_dir` sets `self.active = Some(pty_pane_id)`, `active_editor()` returns
`None` for any pty/diff/outline pane variant.

## Impact

In a pure-subpackage workspace (no root package.json) the monorepo fix works exactly
once, then breaks. The user would need to re-click the editor file before each runner
invocation.

## Suggested fix

Track the most-recently-focused editor path in `App` (`last_editor_path:
Option<PathBuf>`) and use it as the fallback when `active_editor()` returns `None`.
Cleared on workspace switch; updated whenever an editor pane gains focus.
