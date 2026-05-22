<div align="center">

# fim-engine

**Embedded fill-in-the-middle code completion — local, offline, in-process.**

A self-contained Rust crate that downloads a small quantized
[qwen2.5-coder](https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B) model once,
caches it, and runs completion inference in your process via
[candle](https://github.com/huggingface/candle). No daemon, no API key, no
network after the first run.

[![Crates.io](https://img.shields.io/crates/v/fim-engine.svg?logo=rust)](https://crates.io/crates/fim-engine)
[![Documentation](https://docs.rs/fim-engine/badge.svg)](https://docs.rs/fim-engine)
[![CI](https://github.com/chris-mclennan/fim-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/chris-mclennan/fim-engine/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)

</div>

---

**fim-engine** gives an editor Copilot-style inline completion without a cloud
round-trip. "Fill in the middle" means it completes the gap at the cursor given
the code *before* and the code *after* — exactly the shape an inline suggestion
needs.

It is the completion backend shared by
[`mnml`](https://github.com/chris-mclennan/mnml-rs) (ghost-text suggestions) and
[`tmnl`](https://github.com/chris-mclennan/tmnl-rs) (`⌘I` command completion), kept
as its own crate so candle's large dependency tree compiles once and a consuming
app's incremental rebuilds stay fast.

## Highlights

- **Offline & private** — inference runs in-process; nothing leaves the machine
  after the one-time model download.
- **Pure Rust** — no external daemon, no C/C++ build dependencies, no OpenSSL
  (rustls for the download).
- **Managed model** — downloads a quantized GGUF + tokenizer to a shared cache
  on first use, with a progress callback; instant on every run after.
- **Metal acceleration** — the default `metal` feature runs on the Apple GPU
  (~10× faster than CPU for the 1.5B model); build `--no-default-features` for
  pure CPU elsewhere.
- **Two model sizes** — `Qwen1_5B` (fast, the inline default) or a larger
  `Qwen3B` (smarter multi-line completion) via `ModelChoice`.

## Usage

```bash
cargo add fim-engine
```

Loading is a ~1 GB download on the first call, so do it on a worker thread:

```rust
use fim_engine::{FimEngine, ModelChoice};

// Blocking — run on a worker thread, never the UI thread.
let cache = fim_engine::default_cache_dir();
let mut engine = FimEngine::load(&cache, ModelChoice::Qwen1_5B, &|p| {
    eprintln!("{}: {}/{:?}", p.label, p.received, p.total);
})?;

// Complete the gap between `prefix` and `suffix`.
let insert = engine.complete(
    "fn add(a: i32, b: i32) -> i32 {\n    ", // prefix — code before the cursor
    "\n}",                                  // suffix — code after the cursor
    64,                                     // max tokens
)?;
println!("suggestion: {insert}");
# Ok::<(), String>(())
```

`complete` returns only the text to insert — never the surrounding code. It is
CPU/GPU-bound (~100–400 ms for the 1.5B model); call it off the UI thread.

## The model cache

[`default_cache_dir`] resolves a host-agnostic location —
`$XDG_CACHE_HOME/fim-engine`, else `~/.cache/fim-engine` — so every consumer
shares one download instead of duplicating ~1 GB per app. [`is_model_cached`]
reports whether a given `ModelChoice` is already on disk.

## Features

| Feature | Default | Effect |
|---------|---------|--------|
| `metal` | ✅ | GPU inference via Apple Metal (macOS). Build `--no-default-features` on Linux / for CPU-only. |

## The tmnl family

fim-engine is one of a small family of terminal-native Rust tools:

| Project | What it is | |
|---------|-----------|--|
| [**tmnl**](https://github.com/chris-mclennan/tmnl-rs) | A GPU-accelerated terminal | uses fim-engine for `⌘I` completion |
| [**mnml**](https://github.com/chris-mclennan/mnml-rs) | A terminal IDE | uses fim-engine for ghost-text |
| [**mixr**](https://github.com/chris-mclennan/mixr-rs) | A terminal DJ app | — |
| [**tmnl-protocol**](https://github.com/chris-mclennan/tmnl-protocol) | The binary wire protocol | — |
| **fim-engine** | Embedded code completion | ← you are here |

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The roadmap
lives in [`.local/PLAN.md`](.local/PLAN.md) and the release history in
[CHANGELOG.md](CHANGELOG.md).

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.

The model weights are downloaded at runtime from the Hugging Face CDN and are
**not** part of this crate; the qwen2.5-coder model is licensed separately by
its authors.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this crate by you, as defined in the Apache-2.0 license, shall
be dual licensed as above, without any additional terms or conditions.
