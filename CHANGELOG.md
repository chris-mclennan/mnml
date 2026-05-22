# Changelog

All notable changes to **fim-engine** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The roadmap lives in [`.local/PLAN.md`](.local/PLAN.md).

## [Unreleased]

fim-engine has not yet had a tagged release. The `0.1.0` line below summarises
the current `main`.

## [0.1.0]

### Added

- **Embedded FIM completion** — `FimEngine::load` downloads (once) and loads a
  quantized qwen2.5-coder model; `FimEngine::complete` fills the gap between a
  `prefix` and a `suffix`, returning only the text to insert.
- **Managed model cache** — `default_cache_dir` resolves a host-agnostic shared
  cache (`$XDG_CACHE_HOME/fim-engine` → `~/.cache/fim-engine`); `is_model_cached`
  reports whether a model is already on disk; a progress callback fires during
  the download.
- **Two model sizes** — `ModelChoice::Qwen1_5B` (fast, the inline default) and
  `ModelChoice::Qwen3B` (smarter multi-line completion).
- **Metal acceleration** — the default `metal` feature runs inference on the
  Apple GPU; `--no-default-features` builds CPU-only for Linux and elsewhere.
- **`trim_at_suffix`** — trims the model's "rejoin" over-generation so a
  completion never duplicates the code after the cursor.
- Pure Rust — candle for inference, rustls for the download; no external daemon,
  no C/C++ build dependencies.

[Unreleased]: https://github.com/chris-mclennan/fim-engine/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/chris-mclennan/fim-engine/releases/tag/v0.1.0
