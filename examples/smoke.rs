//! End-to-end smoke test — downloads the model (first run only) and
//! runs one fill-in-the-middle completion. Verifies the whole path:
//! HF download → cache → candle load → FIM inference → decode.
//!
//!   cargo run --release --example smoke
//!
//! First run downloads ~1 GB to the shared cache; later runs just load.

use std::time::Instant;

fn main() {
    let cache = fim_engine::default_cache_dir();
    let choice = fim_engine::ModelChoice::Qwen1_5B;
    eprintln!("cache dir: {}", cache.display());
    eprintln!(
        "model cached: {}",
        fim_engine::is_model_cached(&cache, choice)
    );

    let t0 = Instant::now();
    let mut engine = match fim_engine::FimEngine::load(&cache, choice, &|p| {
        let pct = p
            .total
            .map(|t| format!("{}%", p.received * 100 / t.max(1)))
            .unwrap_or_else(|| format!("{} bytes", p.received));
        eprintln!("  download {} … {pct}", p.label);
    }) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("LOAD FAILED: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("loaded in {:.1}s", t0.elapsed().as_secs_f64());

    // A classic FIM hole — the body of an `add` function.
    let prefix = "fn add(a: i32, b: i32) -> i32 {\n    ";
    let suffix = "\n}\n";
    let t1 = Instant::now();
    match engine.complete(prefix, suffix, 32) {
        Ok(completion) => {
            eprintln!("completion in {} ms", t1.elapsed().as_millis());
            eprintln!("--- prefix ---\n{prefix}");
            eprintln!("--- COMPLETION ---\n{completion}");
            eprintln!("--- suffix ---\n{suffix}");
        }
        Err(e) => {
            eprintln!("COMPLETE FAILED: {e}");
            std::process::exit(1);
        }
    }
}
