---
finding: runners-no-whichkey-group
severity: SEV-3
agent: multilang-dev-user
language: ts
repro: workspace-fixture
---

# All 16 test runner commands are palette-only — no which-key group

## Summary

The 16 newly shipped runner commands (npm.*, pytest.*, go.*, cargo.*) all have
`keys: &[]` and NO which-key group entry. They can only be reached via the
command palette (`:npm.test`, `:pytest.run`, etc.). For a developer who runs
tests dozens of times per hour, "open palette → type npm.test → Enter" is 4–5
keystrokes per invocation vs a two-chord `<leader>nt`.

The `cargo.*` family had the same gap before this commit; the new runners
carried the same omission forward.

## Evidence

`/Users/chrismclennan/Projects/mnml/src/whichkey.rs` — grep for `npm`, `pytest`,
`go.test`, `cargo.test` returns zero hits. The `+test` group does not exist in
the which-key trie.

`/Users/chrismclennan/Projects/mnml/src/command.rs` — all 16 runner commands
have `keys: &[]`.

## Suggested fix

Add a `<leader>r` (or `<leader>T`) which-key group named `+run`:
```
('n', cmd("npm.test",      "npm test")),
('N', cmd("npm.build",     "npm build")),
('d', cmd("npm.run",       "npm run dev")),
('p', cmd("pytest.run",    "pytest")),
('P', cmd("pytest.failed", "pytest --lf")),
('g', cmd("go.test",       "go test")),
('G', cmd("go.build",      "go build")),
('t', cmd("cargo.test",    "cargo test")),
('b', cmd("cargo.build",   "cargo build")),
```

Note: `<leader>r` was recently removed (2026-06-13) because it previously
triggered `app.restart`. Any new chord must not conflict. Consider `<leader>R`
or a dedicated `+run` group under a free key.

## Impact

Every non-Rust developer using mnml must use the palette for each test run.
Cargo users have the same friction but it's their default tool anyway.
