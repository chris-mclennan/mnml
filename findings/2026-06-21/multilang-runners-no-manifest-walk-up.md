---
finding: runners-no-manifest-walk-up
severity: SEV-2
agent: multilang-dev-user
language: go
repro: e2e
---

# Runner manifest detection is root-only — monorepo sub-package workflows break

## Summary

`:go.test`, `:npm.test`, and the other runners check for their manifest
(`go.mod`, `package.json`, `pyproject.toml`) only at `self.workspace` (the
workspace root). In a monorepo or sub-package layout, a developer typically
opens a sub-directory in mnml and then tries to run tests. The manifest doesn't
exist at the opened path even though one exists upstream.

## Affected workflows

**Go monorepo (most common Go layout):**
```
/repo/
  go.mod           ← manifest is here
  cmd/
    server/
      main.go
    worker/
      main.go
  internal/
    auth/
      auth.go
```
Developer opens `/repo/cmd/server` as workspace → `:go.test` toasts
"no go.mod" even though `/repo/go.mod` exists.

**pnpm/npm workspace (standard frontend layout):**
```
/monorepo/
  package.json     ← root manifest
  packages/
    ui/
      package.json ← child manifest
    api/
      package.json
```
Developer opens `/monorepo/packages/ui` → `:npm.test` toasts "no package.json"
even though both a local AND root `package.json` exist.

## Confirmed behavior

`tests/e2e/runners_dont_walk_up.test` (from independent bug-hunt) confirms the
root-only detection behavior. The test passes — meaning the behavior is "working
as implemented", but it's wrong from a developer workflow perspective.

## Root cause

`run_manifest_command` in `src/app/playwright.rs` line 178:
```rust
let path = self.workspace.join(manifest);
if !path.exists() {
    // toast...
}
```

No ancestor walk. `go.mod` finding specifically might need to call
`crate::git::branch::current` or similar — or the `go` toolchain itself
handles `./...` with the right cwd.

## Suggested fix

For Go specifically: the runner could spawn in `self.workspace` but rely on
Go's own module discovery (Go's toolchain walks up from cwd to find `go.mod`).
The manifest check should still warn if no `go.mod` is found anywhere in the
ancestor chain, but could relax to checking parent dirs up to the repo root.

For npm: pnpm workspaces put `package.json` at both the root AND each package —
running from the package dir is intentional and correct. The root manifest
might not have the right scripts for the sub-package.

The fix is language-specific — Go benefits most from ancestor walk; npm is
intentionally per-package.
