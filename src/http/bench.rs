//! Concurrent fire-N-times bench, shared by `mnml http bench` (CLI)
//! and the `http.bench` palette command / right-click "Bench (10×)"
//! menu item. Returns a single trace string so both call sites can
//! render it identically — terminal prints it, TUI pipes it into a
//! response pane / toast.
//!
//! Ported from rqst's `bench.rs` as part of phase 5 of the rqst→mnml
//! port-back (2026-06-19). Same shape: sort-by-latency samples, p50/
//! p95/p99/max percentiles, status-class breakdown, first 3 errors.

use crate::http::{self, Request};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

/// Result row per worker iteration: `(elapsed_ms, status)`.
type Sample = (u64, u16);

/// Run `req` `n` times across `concurrency` worker threads. Each
/// thread loops fetching work from the shared atomic counter so
/// hot threads naturally pick up slack from slow ones (vs static
/// chunking which would let a slow first-thread bottleneck the
/// whole bench). Returns the formatted summary; transport errors
/// are folded into the trace's "errors" section.
pub fn run(req: &Request, n: u32, concurrency: u32) -> String {
    let n = n.max(1);
    let concurrency = concurrency.max(1).min(n);
    let counter = Arc::new(AtomicU32::new(0));
    let req_arc = Arc::new(req.clone());
    let results: Arc<Mutex<Vec<Sample>>> = Arc::new(Mutex::new(Vec::with_capacity(n as usize)));
    let errors: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

    let started = Instant::now();
    let mut handles = Vec::with_capacity(concurrency as usize);
    for _ in 0..concurrency {
        let counter = counter.clone();
        let req = req_arc.clone();
        let results = results.clone();
        let errors = errors.clone();
        handles.push(thread::spawn(move || {
            loop {
                let i = counter.fetch_add(1, Ordering::SeqCst);
                if i >= n {
                    break;
                }
                let t = Instant::now();
                match http::send(&req) {
                    Ok(resp) => {
                        let elapsed = t.elapsed().as_millis() as u64;
                        results.lock().unwrap().push((elapsed, resp.status));
                    }
                    Err(e) => {
                        errors.lock().unwrap().push(e);
                    }
                }
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let total_elapsed_ms = started.elapsed().as_millis() as u64;

    let mut samples: Vec<Sample> = Arc::try_unwrap(results)
        .unwrap_or_else(|m| Mutex::new(m.lock().unwrap().clone()))
        .into_inner()
        .unwrap();
    samples.sort_by_key(|(ms, _)| *ms);
    let errs = errors.lock().unwrap().clone();

    format_summary(req, n, concurrency, total_elapsed_ms, &samples, &errs)
}

fn format_summary(
    req: &Request,
    n: u32,
    concurrency: u32,
    total_elapsed_ms: u64,
    samples: &[Sample],
    errs: &[String],
) -> String {
    let durations: Vec<u64> = samples.iter().map(|(ms, _)| *ms).collect();
    let min = durations.first().copied().unwrap_or(0);
    let max = durations.last().copied().unwrap_or(0);
    let pct = |p: f64| -> u64 {
        if durations.is_empty() {
            return 0;
        }
        let idx = ((durations.len() as f64 - 1.0) * p).round() as usize;
        durations[idx.min(durations.len() - 1)]
    };
    let mean = if durations.is_empty() {
        0
    } else {
        durations.iter().sum::<u64>() / durations.len() as u64
    };

    let mut out = String::new();
    out.push_str(&format!(
        "bench  {} {}\n  {} requests · {} concurrent\n",
        req.method, req.url, n, concurrency
    ));
    out.push_str(&format!(
        "\nbench summary — {} samples in {} ms (rate: {:.1} req/s)\n",
        durations.len(),
        total_elapsed_ms,
        if total_elapsed_ms > 0 {
            durations.len() as f64 * 1000.0 / total_elapsed_ms as f64
        } else {
            0.0
        }
    ));
    out.push_str(&format!(
        "  latency ms — min {min} · p50 {} · p95 {} · p99 {} · max {} · mean {mean}\n",
        pct(0.50),
        pct(0.95),
        pct(0.99),
        max
    ));

    let mut classes: BTreeMap<u16, u32> = BTreeMap::new();
    for (_, status) in samples {
        let class = *status / 100;
        *classes.entry(class).or_insert(0) += 1;
    }
    out.push_str("  status:");
    for (class, count) in &classes {
        out.push_str(&format!(" {class}xx={count}"));
    }
    out.push('\n');
    // 2026-06-20 — ASCII histogram of response times.
    // 10 equal buckets across [min, max]; bar width scales to
    // the largest bucket count. Skipped for ≤1 sample.
    if durations.len() > 1 && max > min {
        out.push_str("\n  histogram (ms):\n");
        const BUCKETS: usize = 10;
        const BAR_W: usize = 30;
        let range = (max - min).max(1);
        let mut counts = [0u32; BUCKETS];
        for d in &durations {
            let pos = if *d >= max {
                BUCKETS - 1
            } else {
                ((d - min) * BUCKETS as u64 / range) as usize
            };
            counts[pos.min(BUCKETS - 1)] += 1;
        }
        let peak = counts.iter().copied().max().unwrap_or(1).max(1);
        for (i, &c) in counts.iter().enumerate() {
            let lo = min + range * i as u64 / BUCKETS as u64;
            let hi = min + range * (i + 1) as u64 / BUCKETS as u64;
            let bar_len = (c as usize * BAR_W) / peak as usize;
            let bar: String = std::iter::repeat('█').take(bar_len).collect();
            out.push_str(&format!(
                "    {lo:>4}–{hi:<4} ms │{bar:<BAR_W$}│ {c}\n"
            ));
        }
    }
    if !errs.is_empty() {
        out.push_str(&format!("  errors: {} (showing up to 3)\n", errs.len()));
        for e in errs.iter().take(3) {
            out.push_str(&format!("    {}\n", e));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_summary_with_zero_samples() {
        let req = Request {
            method: "GET".into(),
            url: "https://example.invalid/".into(),
            headers: Vec::new(),
            body: None,
        };
        let out = format_summary(&req, 0, 1, 0, &[], &[]);
        assert!(out.contains("bench summary"));
        assert!(out.contains("0 samples"));
    }

    #[test]
    fn formats_percentiles_with_known_samples() {
        let req = Request {
            method: "POST".into(),
            url: "https://x/y".into(),
            headers: Vec::new(),
            body: None,
        };
        let samples: Vec<Sample> = vec![(10, 200), (20, 200), (30, 500), (40, 200), (50, 200)];
        let out = format_summary(&req, 5, 1, 100, &samples, &[]);
        assert!(out.contains("min 10"), "{}", out);
        // 2026-06-19 — api-workflow-user agent flagged that the
        // earlier assertion set only covered min/max, so a
        // rounding regression in pct() would silently pass. With
        // samples sorted ascending [10,20,30,40,50] and indices
        // `((n-1)*p).round()`:
        //   p50: 4 * 0.50 = 2.0 → durations[2] = 30
        //   p95: 4 * 0.95 = 3.8 → round 4 → durations[4] = 50
        //   p99: 4 * 0.99 = 3.96 → round 4 → durations[4] = 50
        assert!(out.contains("p50 30"), "{}", out);
        assert!(out.contains("p95 50"), "{}", out);
        assert!(out.contains("p99 50"), "{}", out);
        assert!(out.contains("max 50"), "{}", out);
        assert!(out.contains("2xx=4"), "{}", out);
        assert!(out.contains("5xx=1"), "{}", out);
    }
}
