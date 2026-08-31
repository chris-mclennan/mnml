---
name: verify
description: Run the fim-engine verification gate — cargo fmt, build, clippy (warning-free), and the test suite — and report. Use after making changes, before committing.
allowed-tools: Bash(cargo fmt:*), Bash(cargo build:*), Bash(cargo clippy:*), Bash(cargo test:*)
---

# Verify fim-engine

Run the standard gate, in order, and stop at the first failure:

1. `cargo fmt` — format (this rewrites files; that's expected).
2. `cargo build` — must compile clean.
3. `cargo clippy --all-targets` — must be **warning-free**.
4. `cargo test` — all tests pass.

Report the outcome of each step. If a build/test fails, surface the error —
don't paper over it.

The `metal` feature is on by default (Apple GPU). If you changed anything
feature-gated, also check the CPU-only path:

```
cargo clippy --all-targets --no-default-features
cargo test --no-default-features
```

`cargo test` is fast — it covers the pure `trim_at_suffix` logic and does not
download the model. `examples/smoke.rs` *does* download (~1 GB on first run);
only run it when verifying real inference end-to-end.
