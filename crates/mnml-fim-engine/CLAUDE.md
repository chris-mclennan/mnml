# fim-engine — working notes

Embedded fill-in-the-middle code completion — a quantized qwen2.5-coder model
run in-process via candle. A path dependency of `tmnl` and `mnml`.

## Architecture

Three small modules:

- `download.rs` — fetch + cache the GGUF weights and tokenizer on first use;
  `ModelChoice`, `DownloadProgress`, `is_model_cached`.
- `infer.rs` — load the model, run the FIM sampling loop; `trim_at_suffix` cuts
  the model's "rejoin" over-generation.
- `lib.rs` — the public surface: `FimEngine` (`load` / `complete`),
  `default_cache_dir`, re-exports.

## Why it's a separate crate

candle's dependency tree is large. Keeping fim-engine separate means a consuming
app (mnml, tmnl) compiles candle once and its normal incremental rebuilds don't
recompile it. Keep the dependency surface lean — that's the whole point.

## Conventions

- `cargo fmt` + `cargo clippy --all-targets` clean before every commit — the
  repo is gated on both.
- The `metal` feature is opt-in (Apple-only). Default is CPU. Consumers
  enable metal via a `[target.'cfg(target_os = "macos")']` override.
  This is the opposite of what CLAUDE.md said until 2026-08-12 —
  changed because `default = ["metal"]` broke Linux/Windows workspace
  builds after fim-engine was vendored into mnml.
- Inference correctness is subtle — add a unit test when changing the sampling
  or trimming logic.
- Commit messages end with the `Co-Authored-By: Claude …` trailer.

## Verify

`cargo fmt` · `cargo build` · `cargo clippy --all-targets` · `cargo test`. The
`/verify` skill in `.claude/skills/` runs the gate.

Roadmap lives in `.local/PLAN.md`; user-facing history in `CHANGELOG.md`.
