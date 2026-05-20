//! Model-file acquisition — downloads the quantized GGUF weights + the
//! tokenizer from the HuggingFace CDN into a cache directory, skipping
//! files already present. Plain blocking HTTP; no `hf-hub` dependency.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// HuggingFace repo + file for the quantized weights. Qwen's official
/// qwen2.5-coder-1.5b-instruct GGUF at Q4_K_M — ~1 GB. The instruct
/// model retains FIM capability (the `<|fim_*|>` tokens are in-vocab);
/// the plain-base GGUF repo is access-gated, hence the instruct one.
const GGUF_REPO: &str = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF";
const GGUF_FILE: &str = "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf";
/// The base repo carries the `tokenizer.json` candle needs — the vocab
/// is identical between base + instruct.
const TOKENIZER_REPO: &str = "Qwen/Qwen2.5-Coder-1.5B";
const TOKENIZER_FILE: &str = "tokenizer.json";

/// Progress callback payload — emitted periodically during a download so
/// the host can paint a progress bar.
#[derive(Debug, Clone)]
pub struct DownloadProgress {
    /// Human label for the file in flight (`weights` / `tokenizer`).
    pub label: &'static str,
    /// Bytes received so far.
    pub received: u64,
    /// Total bytes, when the server reported a Content-Length.
    pub total: Option<u64>,
}

/// Resolved on-disk paths to the two model files.
#[derive(Debug, Clone)]
pub struct ModelPaths {
    pub gguf: PathBuf,
    pub tokenizer: PathBuf,
}

/// Ensure both model files exist in `cache_dir`, downloading whichever
/// are missing. `progress` is called periodically during a download.
/// Blocking — run on a worker thread.
pub fn ensure_model(
    cache_dir: &Path,
    progress: &(dyn Fn(DownloadProgress) + Sync),
) -> Result<ModelPaths, String> {
    fs::create_dir_all(cache_dir)
        .map_err(|e| format!("create {}: {e}", cache_dir.display()))?;
    let gguf = cache_dir.join(GGUF_FILE);
    let tokenizer = cache_dir.join(TOKENIZER_FILE);

    if !tokenizer.exists() {
        let url = hf_url(TOKENIZER_REPO, TOKENIZER_FILE);
        download(&url, &tokenizer, "tokenizer", progress)?;
    }
    if !gguf.exists() {
        let url = hf_url(GGUF_REPO, GGUF_FILE);
        download(&url, &gguf, "weights", progress)?;
    }
    Ok(ModelPaths { gguf, tokenizer })
}

/// True when both model files are already cached — lets the host show
/// "ready" vs "download required" without starting a download.
pub fn is_model_cached(cache_dir: &Path) -> bool {
    cache_dir.join(GGUF_FILE).exists() && cache_dir.join(TOKENIZER_FILE).exists()
}

fn hf_url(repo: &str, file: &str) -> String {
    format!("https://huggingface.co/{repo}/resolve/main/{file}")
}

/// Stream a URL to `dest`, writing to a `.part` temp file first and
/// renaming on success so an interrupted download never leaves a
/// half-file that looks complete.
fn download(
    url: &str,
    dest: &Path,
    label: &'static str,
    progress: &(dyn Fn(DownloadProgress) + Sync),
) -> Result<(), String> {
    let client = reqwest::blocking::Client::builder()
        .build()
        .map_err(|e| format!("http client: {e}"))?;
    let mut resp = client
        .get(url)
        .send()
        .map_err(|e| format!("GET {url}: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("GET {url}: HTTP {}", resp.status()));
    }
    let total = resp.content_length();
    let part = dest.with_extension("part");
    let mut file =
        fs::File::create(&part).map_err(|e| format!("create {}: {e}", part.display()))?;
    let mut buf = [0u8; 64 * 1024];
    let mut received: u64 = 0;
    let mut last_report: u64 = 0;
    loop {
        let n = resp
            .read(&mut buf)
            .map_err(|e| format!("read {label}: {e}"))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])
            .map_err(|e| format!("write {label}: {e}"))?;
        received += n as u64;
        // Report every ~4 MB so the callback isn't hammered.
        if received - last_report >= 4 * 1024 * 1024 {
            last_report = received;
            progress(DownloadProgress {
                label,
                received,
                total,
            });
        }
    }
    file.flush().map_err(|e| format!("flush {label}: {e}"))?;
    drop(file);
    fs::rename(&part, dest)
        .map_err(|e| format!("finalize {}: {e}", dest.display()))?;
    progress(DownloadProgress {
        label,
        received,
        total,
    });
    Ok(())
}
