//! `fim-engine` — embedded fill-in-the-middle code completion.
//!
//! A self-contained local code-completion engine: it downloads a small
//! quantized [qwen2.5-coder] model on first use, caches it, and runs
//! inference in-process via [candle] — no external daemon, no API key,
//! no network after the one-time download.
//!
//! Shared by mnml + tmnl. Typical use:
//!
//! ```no_run
//! use fim_engine::FimEngine;
//! use std::path::Path;
//!
//! // Blocking — do this on a worker thread.
//! let mut engine = FimEngine::load(Path::new("/Users/me/.mnml/models"), &|p| {
//!     eprintln!("{}: {}/{:?}", p.label, p.received, p.total);
//! })?;
//! let completion = engine.complete("fn add(a: i32, b: i32) -> i32 {\n    ", "\n}", 64)?;
//! # Ok::<(), String>(())
//! ```
//!
//! [qwen2.5-coder]: https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B
//! [candle]: https://github.com/huggingface/candle

mod download;
mod infer;

pub use download::{DownloadProgress, ModelPaths, is_model_cached};

use std::path::{Path, PathBuf};

/// The canonical, host-agnostic model cache directory — every consumer
/// (mnml, tmnl, …) should pass this to [`FimEngine::load`] so the
/// ~1 GB download is shared, not duplicated per app.
///
/// `$XDG_CACHE_HOME/fim-engine` when set, else `~/.cache/fim-engine`,
/// else `./.fim-engine-cache` as a last resort.
pub fn default_cache_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CACHE_HOME")
        && !xdg.is_empty()
    {
        return PathBuf::from(xdg).join("fim-engine");
    }
    if let Ok(home) = std::env::var("HOME")
        && !home.is_empty()
    {
        return PathBuf::from(home).join(".cache").join("fim-engine");
    }
    PathBuf::from(".fim-engine-cache")
}

/// A loaded local FIM completion engine. Holds the model in memory;
/// keep one alive and call [`FimEngine::complete`] repeatedly.
pub struct FimEngine {
    model: infer::Model,
}

impl FimEngine {
    /// Download (if needed) + load the model. `cache_dir` is where the
    /// GGUF weights + tokenizer are stored — e.g. `~/.mnml/models`.
    /// `progress` is invoked periodically while files download.
    ///
    /// Blocking and slow on the first call (a ~1 GB download); fast
    /// afterwards (just the load). Run it on a worker thread.
    pub fn load(
        cache_dir: &Path,
        progress: &(dyn Fn(DownloadProgress) + Sync),
    ) -> Result<Self, String> {
        let paths = download::ensure_model(cache_dir, progress)?;
        let model = infer::Model::load(&paths.gguf, &paths.tokenizer)?;
        Ok(FimEngine { model })
    }

    /// Generate a completion for the cursor sitting between `prefix`
    /// (code before) and `suffix` (code after). Returns the text to
    /// insert — never includes the surrounding code. `max_tokens`
    /// bounds the length (≈ 64 is a good inline default).
    ///
    /// Blocking + CPU-bound (~100–400 ms for the 1.5B model). Call on
    /// a worker thread; never on the UI thread.
    pub fn complete(
        &mut self,
        prefix: &str,
        suffix: &str,
        max_tokens: usize,
    ) -> Result<String, String> {
        self.model.complete(prefix, suffix, max_tokens)
    }
}
