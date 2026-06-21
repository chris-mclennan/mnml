---
finding: go-run-hardcoded-dot
severity: SEV-3
agent: multilang-dev-user
language: go
repro: workspace-fixture
---

# `go.run` is hardcoded to `go run .` — fails for non-root main packages

## Summary

`go.run` always runs `go run .` (the workspace root). For Go projects where the
main package is NOT at the root (the majority of real Go projects use
`cmd/<appname>/main.go`), this silently fails with:

```
go: cannot run non-main package
```

or (if the root has no .go files):

```
no Go files in /path/to/workspace
```

## Common Go project layouts affected

- Single app: `cmd/myapp/main.go` → `go run .` fails, need `go run ./cmd/myapp`
- Multi-binary: `cmd/server/main.go`, `cmd/worker/main.go` → which one?
- Standard library: no main at all → `go run .` error

## Comparison

`go.build ./...` and `go.test ./...` both use `./...` which correctly traverses
the entire module. `go.run` doesn't have an obvious analog (you can't `go run ./...`
with multiple main packages), but the hardcoded `.` is wrong for the common case.

## Suggested fix

- Option A: Change `go.run` to `go run ./cmd/...` or prompt for the target
- Option B: Make `go.run` a prompt that offers discovered `main` packages
  (scan for `package main` files under the workspace)
- Option C: Drop `go.run` from the initial set (only `go.test`, `go.build`,
  `go.vet` are universally useful) — a shell pty is the right escape hatch

## Affected code

`/Users/chrismclennan/Projects/mnml/src/command.rs`, line 4056–4060:
```rust
id: "go.run",
title: "Go: run `go run .` in a pty pane",
run: |app| app.run_go_subcommand("run ."),
```
