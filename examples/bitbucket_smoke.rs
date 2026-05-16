//! Smoke-test for the Bitbucket phase-1 worker. Loads the user's
//! `[bitbucket]` config (same path as the real App), spawns the worker,
//! drains the channel for `DRAIN_SECONDS`, prints a compact summary:
//! per-repo pipeline counts, sample rows, any `Failed` events.
//!
//! Run: `cargo run --example bitbucket_smoke`
//!
//! Requires `$BITBUCKET_TOKEN` (or whatever `[bitbucket] auth_env` points
//! at). Read-only: only hits the Bitbucket Cloud REST API; makes no UI
//! changes; doesn't write anything anywhere.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use mnml::bitbucket::{BitbucketEvent, spawn};
use mnml::config::Config;

/// We poll at 30s minimum, so 20s lets us hear the first burst of
/// per-repo Pipelines events after the worker connects without burning
/// the whole next-poll-cycle wait.
const DRAIN_SECONDS: u64 = 20;

fn main() {
    let workspace = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let cfg = Config::load(None, &workspace);
    let bb = &cfg.bitbucket;

    println!("── [bitbucket] config ──");
    println!("  auth_env  = {}", bb.auth_env_name());
    println!("  poll_secs = {}", bb.poll_secs_or_default());
    println!("  repos     = [");
    for r in &bb.repos {
        println!("    {}/{}", r.workspace, r.slug);
    }
    println!("  ]");
    if !bb.any_configured() {
        println!("(no [[bitbucket.repos]] configured — exiting)");
        return;
    }
    if std::env::var(bb.auth_env_name()).ok().is_none() {
        println!(
            "(${} not set — export your Bitbucket API token first, then re-run)",
            bb.auth_env_name()
        );
        return;
    }
    println!();

    println!("── spawning worker, draining for {DRAIN_SECONDS}s ──");
    let handle = spawn(bb.clone());
    let start = Instant::now();
    let mut connected = false;
    let mut failures: Vec<String> = Vec::new();
    let mut per_repo_counts: Vec<((String, String), usize)> = Vec::new();
    let mut samples: Vec<String> = Vec::new();

    while start.elapsed() < Duration::from_secs(DRAIN_SECONDS) {
        match handle.rx.recv_timeout(Duration::from_millis(500)) {
            Ok(BitbucketEvent::Pipelines {
                workspace,
                slug,
                pipelines,
            }) => {
                per_repo_counts.push(((workspace.clone(), slug.clone()), pipelines.len()));
                for p in pipelines.iter().take(3) {
                    let dur = p
                        .duration_secs
                        .map(|s| format!("{s}s"))
                        .unwrap_or_else(|| "—".to_string());
                    let branch = p.target_ref.as_deref().unwrap_or("(no ref)");
                    samples.push(format!(
                        "  {state_glyph} #{n:<5} {state_label:<10} {branch:<24} {dur:<6} {ws}/{slug}",
                        state_glyph = p.state.glyph(),
                        n = p.build_number,
                        state_label = p.state.label(),
                        ws = workspace,
                        slug = slug,
                    ));
                }
            }
            Ok(BitbucketEvent::PullRequests {
                workspace,
                slug,
                pull_requests,
            }) => {
                samples.push(format!(
                    "  ⇄  {ws}/{slug}  →  {n} open PR(s)",
                    ws = workspace,
                    slug = slug,
                    n = pull_requests.len(),
                ));
            }
            Ok(BitbucketEvent::BranchPipelines {
                workspace,
                slug,
                per_branch,
            }) => {
                samples.push(format!(
                    "  ⌥  {workspace}/{slug}  per-branch: {n} branch(es)",
                    n = per_branch.len(),
                ));
            }
            Ok(BitbucketEvent::MyPullRequests(prs)) => {
                samples.push(format!(
                    "  👤  mine: {n} PR(s) across all repos",
                    n = prs.len()
                ));
            }
            Ok(BitbucketEvent::Connected) => connected = true,
            Ok(BitbucketEvent::Failed(msg)) => failures.push(msg),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {} // keep looping
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    println!("\n── results ──");
    println!("  Connected event:    {connected}");
    println!("  Failed events:      {}", failures.len());
    for (i, msg) in failures.iter().take(10).enumerate() {
        println!("    [{i}] {msg}");
    }
    println!("\n  per-repo pipelines fetched:");
    for ((ws, slug), n) in &per_repo_counts {
        println!("    {ws}/{slug}  → {n} rows");
    }
    if !samples.is_empty() {
        println!(
            "\n── sample rows (first ≤3 per repo, total {}) ──",
            samples.len()
        );
        for line in &samples {
            println!("{line}");
        }
    }
    println!("\n(dropping handle → worker cancels + thread joins)");
    drop(handle);
}
