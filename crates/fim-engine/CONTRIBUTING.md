# Contributing to mnml-fim-engine

Thanks for your interest in mnml-fim-engine. This guide covers the workflow and
conventions. The crate lives inside the mnml workspace at `crates/fim-engine/`;
its standalone repo was absorbed on 2026-08-10 and is gone.

## Getting started

```bash
git clone https://github.com/chris-mclennan/mnml
cd mnml/crates/fim-engine
cargo test
```

mnml-fim-engine builds on stable Rust (MSRV **1.85**, edition 2024). It has no C/C++
build dependencies — candle is pure Rust.

The first run of `examples/smoke.rs` downloads a ~1 GB model to the shared cache
(`~/.cache/fim-engine`); after that it's offline.

## Features

- `metal` (default) — GPU inference via Apple Metal, macOS-only.
- On Linux / for CPU-only, build with `--no-default-features`.

Test both where you can — CI does.

## The verification gate

Every change must pass, in order:

```bash
cargo fmt
cargo build
cargo clippy --all-targets   # warning-free
cargo test
```

The `/verify` skill in `.claude/skills/` runs the gate.

## Architecture

Three small modules:

- `download.rs` — fetch + cache the GGUF weights and tokenizer; `ModelChoice`,
  `DownloadProgress`, `is_model_cached`.
- `infer.rs` — load the model and run the FIM sampling loop; `trim_at_suffix`
  cuts the model's rejoin over-generation.
- `lib.rs` — the public surface: `FimEngine`, `default_cache_dir`, re-exports.

fim-engine is a path dependency of `tmnl` and `mnml`. It is deliberately its own
crate so candle's large dependency tree compiles once and a consuming app's
incremental rebuilds stay fast — keep the dependency surface lean.

## Conventions

- Run `cargo fmt` and keep `cargo clippy --all-targets` warning-free.
- Inference correctness is subtle — add a unit test when you change the sampling
  or trimming logic (`trim_at_suffix` has a test per case).
- Match the surrounding code style.

## Pull requests

1. Branch from `main`.
2. Make your change with tests; run the verification gate.
3. Open a PR describing the change and how you verified it.
4. CI runs `fmt` + `clippy -D warnings` + `test` on macOS and Linux — keep it
   green.

## License

By contributing, you agree that your contributions will be dual licensed under
the MIT and Apache-2.0 licenses, as described in [README.md](README.md#license),
without any additional terms or conditions.
