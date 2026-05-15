//! Smoke-test for the GitHub Actions worker. Loads `[github]` config,
//! spawns the worker, drains the channel for `DRAIN_SECONDS`, prints a
//! per-repo run count + a few sample rows. Sibling to
//! `examples/bitbucket_smoke.rs`.
//!
//! Run: `cargo run --example github_smoke`
//!
//! Requires `$GITHUB_TOKEN` (or whatever `[github] auth_env` names).
//! Read-only.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use mnml::config::Config;
use mnml::github::{GithubEvent, spawn};

const DRAIN_SECONDS: u64 = 20;

fn main() {
    let workspace = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let cfg = Config::load(None, &workspace);
    let gh = &cfg.github;

    println!("── [github] config ──");
    println!("  auth_env  = {}", gh.auth_env_name());
    println!("  poll_secs = {}", gh.poll_secs_or_default());
    println!("  repos     = [");
    for r in &gh.repos {
        println!("    {}/{}", r.owner, r.repo);
    }
    println!("  ]");
    if !gh.any_configured() {
        println!("(no [[github.repos]] configured — exiting)");
        return;
    }
    if std::env::var(gh.auth_env_name()).ok().is_none() {
        println!(
            "(${} not set — export your GitHub PAT first, then re-run)",
            gh.auth_env_name()
        );
        return;
    }
    println!();

    println!("── spawning worker, draining for {DRAIN_SECONDS}s ──");
    let handle = spawn(gh.clone());
    let start = Instant::now();
    let mut connected = false;
    let mut failures: Vec<String> = Vec::new();
    let mut per_repo_counts: Vec<((String, String), usize)> = Vec::new();
    let mut samples: Vec<String> = Vec::new();

    while start.elapsed() < Duration::from_secs(DRAIN_SECONDS) {
        match handle.rx.recv_timeout(Duration::from_millis(500)) {
            Ok(GithubEvent::WorkflowRuns { owner, repo, runs }) => {
                per_repo_counts.push(((owner.clone(), repo.clone()), runs.len()));
                for r in runs.iter().take(3) {
                    let dur = r
                        .duration_secs
                        .map(|s| format!("{s}s"))
                        .unwrap_or_else(|| "—".to_string());
                    let branch = r.target_ref.as_deref().unwrap_or("(no ref)");
                    samples.push(format!(
                        "  {glyph} #{n:<5} {label:<10} {wf:<14} {branch:<20} {dur:<6} {owner}/{repo}",
                        glyph = r.state.glyph(),
                        n = r.run_number,
                        label = r.state.label(),
                        wf = r.workflow_name,
                    ));
                }
            }
            Ok(GithubEvent::Connected) => connected = true,
            Ok(GithubEvent::Failed(msg)) => failures.push(msg),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    println!("\n── results ──");
    println!("  Connected event:    {connected}");
    println!("  Failed events:      {}", failures.len());
    for (i, msg) in failures.iter().take(10).enumerate() {
        println!("    [{i}] {msg}");
    }
    println!("\n  per-repo runs fetched:");
    for ((owner, repo), n) in &per_repo_counts {
        println!("    {owner}/{repo}  → {n} rows");
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
