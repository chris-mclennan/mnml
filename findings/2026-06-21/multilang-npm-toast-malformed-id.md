---
finding: npm-toast-malformed-id
severity: SEV-2
agent: multilang-dev-user
language: ts
repro: e2e
---

# npm runner toast has malformed command ID for multi-word subcommands

## Summary

When `package.json` is absent and `npm.run`, `npm.build`, or `npm.lint` is
invoked, the toast message shows the raw subcmd string embedded in the
command name — producing `npm.run dev:`, `npm.run build:`, and `npm.run lint:`
instead of `npm.run:`, `npm.build:`, and `npm.lint:`.

## Root cause

`run_manifest_command` in `src/app/playwright.rs` (line 181) constructs the
toast with `"{bin}.{subcmd}: no {manifest} at {path}"`. When `subcmd` is
`"run dev"` (as passed by `npm.run`), this yields `npm.run dev: no package.json
at /path/to/workspace` — not `npm.run: no package.json at ...`.

The same bug exists for:
- `cargo.clippy` → subcmd `"clippy --all-targets"` → toast `cargo.clippy --all-targets: no Cargo.toml at …`
- `go.test` → subcmd `"test ./..."` → toast `go.test ./...: no go.mod at …`
- `go.build` → subcmd `"build ./..."` → toast `go.build ./...: no go.mod at …`
- `go.vet` → subcmd `"vet ./..."` → toast `go.vet ./...: no go.mod at …`
- `go.run` → subcmd `"run ."` → toast `go.run .: no go.mod at …`

## Confirmed via e2e tests

```
tests/e2e/npm_runner_toast_format.test   → 0/1 passed (toast says "npm.run dev:")
tests/e2e/go_runner_toast_format.test    → 0/1 passed (toast says "go.test ./...:")
tests/e2e/cargo_runner_toast_format.test → 0/1 passed (toast says "cargo.clippy --all-targets:")
```

Rendered toast (captured from headless screen):
```
npm.run dev: no package.json at /private/var/.../T/.tmpqQ9En9
go.test ./...: no go.mod at /private/var/.../T/.tmpOmq1dt
cargo.clippy --all-targets: no Cargo.toml at /private/var/.../T/.tmpLLVkEN
```

## Fix sketch

`run_manifest_command` needs to receive the command ID (or the first word of
subcmd) separately from the full args string. Either:
- Accept a `cmd_id: &str` parameter and use that in the toast: `"{cmd_id}: no {manifest} at …"`
- Or split subcmd on the first space: `subcmd.split_whitespace().next().unwrap_or(subcmd)` for the toast

## Affected code

`/Users/chrismclennan/Projects/mnml/src/app/playwright.rs`, lines 177–194
`/Users/chrismclennan/Projects/mnml/src/command.rs`, lines 3962 (`clippy --all-targets`),
3990 (`run dev`), 3997 (`run build`), 4018 (`run lint`), 4039 (`test ./...`),
4046 (`build ./...`), 4053 (`vet ./...`), 4060 (`run .`)
