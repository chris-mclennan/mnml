//! Smoke-test for the Azure DevOps worker. Loads `[azdevops]` config,
//! spawns the worker, drains the channel for `DRAIN_SECONDS`, prints a
//! per-project build count + a few sample rows. Sibling to
//! `examples/github_smoke.rs` + `examples/bitbucket_smoke.rs`.
//!
//! Run: `cargo run --example azdevops_smoke`
//!
//! Requires `$AZDO_TOKEN` (or whatever `[azdevops] auth_env` names) — a
//! personal access token with `Code (read)` + `Build (read)` scopes.
//!
//! Read-only. If the Mine endpoint's `creatorId=me` shorthand 400s on
//! your tenant, set `[azdevops] creator_id = "<guid>"` in
//! `~/.config/mnml/config.toml` — the worker now also auto-falls-back to
//! a profile/me lookup but the config override skips the round-trip.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use mnml::azdevops::{AzDevOpsEvent, spawn};
use mnml::config::Config;

const DRAIN_SECONDS: u64 = 20;

fn main() {
    let workspace = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let cfg = Config::load(None, &workspace);
    let az = &cfg.azdevops;

    println!("── [azdevops] config ──");
    println!("  auth_env   = {}", az.auth_env_name());
    println!("  poll_secs  = {}", az.poll_secs_or_default());
    println!(
        "  creator_id = {}",
        az.creator_id.as_deref().unwrap_or("(default: \"me\")")
    );
    println!("  projects   = [");
    for p in &az.projects {
        println!("    {}/{}/{}", p.org, p.project, p.repo);
    }
    println!("  ]");
    if !az.any_configured() {
        println!("(no [[azdevops.projects]] configured — exiting)");
        return;
    }
    if std::env::var(az.auth_env_name()).ok().is_none() {
        println!(
            "(${} not set — export your Azure DevOps PAT first, then re-run)",
            az.auth_env_name()
        );
        return;
    }
    println!();

    println!("── spawning worker, draining for {DRAIN_SECONDS}s ──");
    let handle = spawn(az.clone());
    let start = Instant::now();
    let mut connected = false;
    let mut failures: Vec<String> = Vec::new();
    let mut per_proj_counts: Vec<(String, usize)> = Vec::new();
    let mut samples: Vec<String> = Vec::new();

    while start.elapsed() < Duration::from_secs(DRAIN_SECONDS) {
        match handle.rx.recv_timeout(Duration::from_millis(500)) {
            Ok(AzDevOpsEvent::Builds { label, builds }) => {
                per_proj_counts.push((label.clone(), builds.len()));
                for b in builds.iter().take(3) {
                    let dur = b
                        .duration_secs
                        .map(|s| format!("{s}s"))
                        .unwrap_or_else(|| "—".to_string());
                    let branch = b.target_ref.as_deref().unwrap_or("(no ref)");
                    samples.push(format!(
                        "  {glyph} #{n:<5} {state:<10} {branch:<20} {dur:<6} {label}",
                        glyph = b.state.glyph(),
                        n = b.id,
                        state = b.state.label(),
                    ));
                }
            }
            Ok(AzDevOpsEvent::PullRequests {
                label,
                pull_requests,
            }) => {
                samples.push(format!(
                    "  ⇄  {label}  →  {n} active PR(s)",
                    n = pull_requests.len(),
                ));
            }
            Ok(AzDevOpsEvent::BranchBuilds { label, per_branch }) => {
                samples.push(format!(
                    "  ⚙  {label}  per-branch: {n} branch(es)",
                    n = per_branch.len(),
                ));
            }
            Ok(AzDevOpsEvent::MyPullRequests(prs)) => {
                samples.push(format!("  👤  mine: {n} PR(s)", n = prs.len()));
            }
            Ok(AzDevOpsEvent::Connected) => connected = true,
            Ok(AzDevOpsEvent::Failed(msg)) => failures.push(msg),
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
    println!("\n  per-project builds fetched:");
    for (label, n) in &per_proj_counts {
        println!("    {label}  → {n} rows");
    }
    if !samples.is_empty() {
        println!(
            "\n── sample rows (first ≤3 per project, total {}) ──",
            samples.len()
        );
        for line in &samples {
            println!("{line}");
        }
    }
    println!("\n(dropping handle → worker cancels + thread joins)");
    drop(handle);
}
