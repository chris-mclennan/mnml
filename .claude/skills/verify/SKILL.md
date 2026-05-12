---
name: verify
description: Run the mnml verification gate — cargo fmt, build, clippy (warning-free), and the test suite — and report. Use after making changes to mnml, before committing.
allowed-tools: Bash(cargo fmt:*), Bash(cargo build:*), Bash(cargo clippy:*), Bash(cargo test:*)
---

# Verify mnml

Run the standard gate, in order, and stop at the first failure:

1. `cargo fmt` — format (this rewrites files; that's expected).
2. `cargo build` — must compile clean.
3. `cargo clippy --all-targets` — must be **warning-free** (the project keeps it clean).
4. `cargo test` — all tests pass.

Report the outcome of each step. If clippy has warnings, list them and fix the
trivial ones (`cargo clippy --fix --allow-dirty --lib -p mnml` / `--tests` handles
most). If a build/test fails, surface the error — don't paper over it.

(The `PostToolUse` hook auto-restarts the running mnml after the `cargo build`
step, so a successful verify also refreshes what the user sees.)
