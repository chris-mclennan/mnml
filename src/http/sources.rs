//! `<workspace>/.rqst/sources.json` reader + driver. Ported from
//! rqst's `sources.rs` as part of the rqst→mnml port-back. Phase 2,
//! 2026-06-19.
//!
//! Each entry is a swagger/OpenAPI source with `kind: "swagger"`,
//! a `url` to fetch, and an `out` directory to write `.curl` stubs
//! into. The CLI's `mnml http sync` command (or the `http.sync`
//! palette command in-app) reads this file and fires
//! [`crate::http::discover::run`] for each entry — same logic the
//! existing `mnml discover` CLI uses, batched.
//!
//! Keeping `.rqst/sources.json` (vs migrating to `.mnml/`) so a
//! workspace stays portable between the legacy rqst app and mnml
//! during the transition. Mnml-native workspaces can also use
//! `.mnml/sources.json` — the loader checks `.mnml/` first and
//! falls back to `.rqst/`.

use crate::http::discover;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Source {
    pub name: String,
    pub kind: String,
    pub url: String,
    pub out: PathBuf,
    pub base_url_override: Option<String>,
}

/// Read and parse the workspace's `sources.json`. Prefers
/// `.mnml/sources.json`; falls back to `.rqst/sources.json` for
/// legacy workspaces. `Ok(None)` when neither file exists (a not-
/// yet-set-up workspace); `Err` only on parse failure or unreadable
/// file.
pub fn load(workspace: &Path) -> Result<Option<Vec<Source>>, String> {
    let candidates = [
        workspace.join(".mnml").join("sources.json"),
        workspace.join(".rqst").join("sources.json"),
    ];
    let path = candidates.iter().find(|p| p.exists());
    let Some(path) = path else {
        return Ok(None);
    };
    let raw = fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let arr: Vec<serde_json::Value> =
        serde_json::from_str(&raw).map_err(|e| format!("parse {}: {e}", path.display()))?;
    let mut out: Vec<Source> = Vec::with_capacity(arr.len());
    for v in &arr {
        let name = v
            .get("name")
            .and_then(|s| s.as_str())
            .unwrap_or("(unnamed)")
            .to_string();
        let kind = v
            .get("kind")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string();
        // Skip malformed entries instead of aborting the whole
        // load — reviewer-flagged 2026-06-19: a single bad entry
        // in a 6-source file used to kill the other 5 silently.
        // The trace path in `run_sync` already logs per-source
        // failures, so the omission surfaces via the toast/CLI.
        let Some(url) = v.get("url").and_then(|s| s.as_str()) else {
            eprintln!("mnml http sync: source `{name}` missing 'url' — skipping");
            continue;
        };
        let url = url.to_string();
        // `out` is a path relative to the workspace, or absolute.
        // Falls back to `.rqst/requests/<name>` for parity with rqst
        // — same shape the existing tattle workspace already uses.
        let out_path = v
            .get("out")
            .and_then(|s| s.as_str())
            .map(PathBuf::from)
            .unwrap_or_else(|| workspace.join(".rqst").join("requests").join(&name));
        let resolved = if out_path.is_absolute() {
            out_path
        } else {
            workspace.join(out_path)
        };
        let base_url_override = v
            .get("base_url_override")
            .and_then(|s| s.as_str())
            .map(str::to_string);
        out.push(Source {
            name,
            kind,
            url,
            out: resolved,
            base_url_override,
        });
    }
    Ok(Some(out))
}

/// Run discover for each `kind == "swagger"` source. Returns a
/// trace string (one line per source) so the TUI can render it in
/// a pane like bench / chain output, plus the total count of stubs
/// written for the toast. Other kinds (`openapi3`, `bruno`, …) are
/// silently logged as skipped — forward-compat hook for future
/// importers.
pub fn run_sync(workspace: &Path) -> Result<(String, usize), String> {
    let sources = match load(workspace)? {
        Some(s) if !s.is_empty() => s,
        Some(_) => return Err("sources.json is empty".into()),
        None => {
            return Err(format!(
                "no sources.json found at {} or {}",
                workspace.join(".mnml").join("sources.json").display(),
                workspace.join(".rqst").join("sources.json").display(),
            ));
        }
    };
    let mut trace = String::new();
    let mut total: usize = 0;
    let mut ran: usize = 0;
    for s in &sources {
        if s.kind != "swagger" {
            trace.push_str(&format!(
                "[sync] {}: skipping unsupported kind '{}'\n",
                s.name, s.kind
            ));
            continue;
        }
        trace.push_str(&format!(
            "[sync] {}: fetch {} → {}\n",
            s.name,
            s.url,
            s.out.display()
        ));
        let dargs = discover::Options {
            spec: s.url.clone(),
            out: s.out.clone(),
            base_url: s.base_url_override.clone(),
        };
        match discover::run(&dargs) {
            Ok(n) => {
                trace.push_str(&format!("[sync] {}: wrote {n} stub(s)\n", s.name));
                total += n;
                ran += 1;
            }
            Err(e) => {
                trace.push_str(&format!("[sync] {}: failed — {e}\n", s.name));
            }
        }
    }
    trace.push_str(&format!(
        "\n[sync] done — {ran} source(s), {total} request stub(s) total\n"
    ));
    Ok((trace, total))
}
