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
        // Falls back to `.rqst/requests/<name>` for parity with rqst.
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

/// Dry-run drift check — for each source, fetch the spec into a
/// temp dir and diff the generated stubs against what's currently
/// on disk under the source's `out`. Reports Added / Removed /
/// Changed files per source; NO writes to the real `out` dirs.
///
/// Output shape mirrors `run_sync` — a trace string per source
/// suitable for a scratch pane, plus a summary total. When there's
/// zero drift, the trace is short + celebratory.
///
/// 2026-07-08 user request: "id like to be able to run something
/// to check".
pub fn check_sync(workspace: &Path) -> Result<(String, usize), String> {
    check_sync_with_normalize(workspace, false)
}

/// Same as `check_sync` but with an explicit `normalize` flag that
/// turns Tier-1 dynamic-value substitution on/off on the discover
/// side. When on, ISO 8601 timestamps and lowercase UUIDs in the
/// generated bodies are compared as `{{$isoTimestamp}}` / `{{$uuid}}`
/// — so swagger-side re-generation of those values stops registering
/// as drift. 2026-07-09.
pub fn check_sync_with_normalize(
    workspace: &Path,
    normalize: bool,
) -> Result<(String, usize), String> {
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
    trace.push_str("# http.sync_check — drift report\n\n");
    let mut total_drift: usize = 0;
    for s in &sources {
        if s.kind != "swagger" {
            trace.push_str(&format!(
                "## {}\n  skipping unsupported kind '{}'\n\n",
                s.name, s.kind
            ));
            continue;
        }
        trace.push_str(&format!(
            "## {}\n  spec: {}\n  compared against: {}\n",
            s.name,
            s.url,
            s.out.display()
        ));
        // Generate into a temp dir. Best-effort cleanup at scope
        // exit even on error paths (tempdir Drop handles it).
        let tmp = match tempfile::TempDir::new() {
            Ok(t) => t,
            Err(e) => {
                trace.push_str(&format!("  ERR: tempdir: {e}\n\n"));
                continue;
            }
        };
        let dargs = discover::Options {
            spec: s.url.clone(),
            out: tmp.path().to_path_buf(),
            base_url: s.base_url_override.clone(),
            normalize,
            edge_cases: false,
            // Sources-sync writes into a fresh tempdir every run,
            // so nothing to preserve; force overwrite.
            force: true,
        };
        if let Err(e) = discover::run(&dargs) {
            trace.push_str(&format!("  ERR: discover: {e}\n\n"));
            continue;
        }
        // Walk both trees, collect relative paths.
        let generated = walk_curls(tmp.path());
        let existing = walk_curls(&s.out);
        let mut added: Vec<PathBuf> = generated
            .keys()
            .filter(|p| !existing.contains_key(*p))
            .cloned()
            .collect();
        let mut removed: Vec<PathBuf> = existing
            .keys()
            .filter(|p| !generated.contains_key(*p))
            .cloned()
            .collect();
        let mut changed: Vec<PathBuf> = generated
            .iter()
            .filter(|(p, new)| existing.get(*p).is_some_and(|old| old != *new))
            .map(|(p, _)| p.clone())
            .collect();
        added.sort();
        removed.sort();
        changed.sort();
        let drift = added.len() + removed.len() + changed.len();
        total_drift += drift;
        if drift == 0 {
            trace.push_str("  clean — no drift\n\n");
            continue;
        }
        trace.push_str(&format!(
            "  drift: {} added, {} removed, {} changed\n",
            added.len(),
            removed.len(),
            changed.len()
        ));
        for p in &added {
            trace.push_str(&format!("    + {}\n", p.display()));
        }
        for p in &removed {
            trace.push_str(&format!("    - {}\n", p.display()));
        }
        for p in &changed {
            trace.push_str(&format!("    ~ {}\n", p.display()));
        }
        trace.push('\n');
    }
    trace.push_str(&format!(
        "# summary — {} file(s) differ across all sources\n",
        total_drift
    ));
    if total_drift > 0 {
        trace.push_str("# run `:http.sync` to apply (overwrites existing stubs)\n");
    }
    Ok((trace, total_drift))
}

/// Walk `dir` recursively, return `{relative_path → contents}` for
/// every `.curl` file. `None` on unreadable dir → empty map (a
/// missing `out` dir is treated as "all generated files are
/// ADDED"). File contents are read as UTF-8; non-UTF-8 files are
/// skipped (unusual for .curl but safe).
fn walk_curls(dir: &Path) -> std::collections::HashMap<PathBuf, String> {
    let mut out = std::collections::HashMap::new();
    fn walk(root: &Path, cur: &Path, acc: &mut std::collections::HashMap<PathBuf, String>) {
        let Ok(rd) = fs::read_dir(cur) else { return };
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                walk(root, &p, acc);
            } else if p.extension().and_then(|e| e.to_str()) == Some("curl")
                && let Ok(text) = fs::read_to_string(&p)
                && let Ok(rel) = p.strip_prefix(root)
            {
                acc.insert(rel.to_path_buf(), text);
            }
        }
    }
    walk(dir, dir, &mut out);
    out
}

/// Run discover for each `kind == "swagger"` source. Returns a
/// trace string (one line per source) so the TUI can render it in
/// a pane like bench / chain output, plus the total count of stubs
/// written for the toast. Other kinds (`openapi3`, `bruno`, …) are
/// silently logged as skipped — forward-compat hook for future
/// importers.
pub fn run_sync(workspace: &Path) -> Result<(String, usize), String> {
    run_sync_with_normalize(workspace, false)
}

/// Same as `run_sync` but with an explicit `normalize` flag
/// (Tier-1 dynamic-value substitution). Writes stubs with
/// `{{$isoTimestamp}}` / `{{$uuid}}` in place of concrete timestamp/
/// UUID values so re-syncing produces byte-identical output modulo
/// real API changes.
pub fn run_sync_with_normalize(
    workspace: &Path,
    normalize: bool,
) -> Result<(String, usize), String> {
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
            normalize,
            edge_cases: false,
            // Sync IS the "regenerate from spec" workflow — overwrite
            // by design so the sources always mirror the spec.
            force: true,
        };
        match discover::run(&dargs) {
            Ok((n, _skipped)) => {
                trace.push_str(&format!("[sync] {}: wrote {n} stub(s)\n", s.name));
                total += n;
                ran += 1;
            }
            Err(e) => {
                trace.push_str(&format!("[sync] {}: failed — {e}\n", s.name));
            }
        }
    }
    // Seed `.mnml/env/dev.env.example` with the well-known env
    // vars discover references (Tier 4). Only touches the file
    // when it doesn't exist — never clobbers a user's tuned copy.
    if let Some(seeded) = maybe_seed_env_example(workspace) {
        trace.push_str(&format!("\n[sync] seeded {}\n", seeded.display()));
    }
    trace.push_str(&format!(
        "\n[sync] done — {ran} source(s), {total} request stub(s) total\n"
    ));
    Ok((trace, total))
}

/// If `<workspace>/.mnml/env/dev.env.example` doesn't exist yet,
/// write a starter file listing the well-known env vars that
/// discover's ID substitution + faker vocab reference. Users
/// can `cp dev.env.example dev.env` and fill in values.
///
/// Skipped when the file already exists (never clobbers). Returns
/// the path when written; `None` otherwise.
fn maybe_seed_env_example(workspace: &Path) -> Option<PathBuf> {
    let dir = workspace.join(".mnml").join("env");
    let path = dir.join("dev.env.example");
    if path.exists() {
        return None;
    }
    if fs::create_dir_all(&dir).is_err() {
        return None;
    }
    let mut contents = String::from(
        "# Seeded by `mnml sync` on first run — 2026-07-09.\n\
         # Well-known env vars that discover-generated stubs reference.\n\
         # Copy to `dev.env` and fill in values for your workspace.\n\
         \n\
         BASE_URL=\n\
         TOKEN=\n\
         \n",
    );
    for v in crate::http::faker::known_env_vars() {
        contents.push_str(&format!("{v}=\n"));
    }
    fs::write(&path, contents).ok().map(|_| path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maybe_seed_env_example_writes_starter_file_on_first_run() {
        let dir = tempfile::tempdir().unwrap();
        let out = maybe_seed_env_example(dir.path()).expect("should write");
        let text = fs::read_to_string(&out).unwrap();
        assert!(text.contains("BASE_URL="), "starter contents: {text}");
        assert!(text.contains("TOKEN="), "starter contents: {text}");
        assert!(text.contains("MERCHANT_ID="), "starter contents: {text}");
        assert!(text.contains("LOCATION_ID="), "starter contents: {text}");
    }

    #[test]
    fn maybe_seed_env_example_leaves_existing_file_alone() {
        let dir = tempfile::tempdir().unwrap();
        let env_dir = dir.path().join(".mnml").join("env");
        fs::create_dir_all(&env_dir).unwrap();
        let path = env_dir.join("dev.env.example");
        fs::write(&path, "USER_TUNED=1\n").unwrap();
        let result = maybe_seed_env_example(dir.path());
        assert!(result.is_none(), "should not touch existing file");
        assert_eq!(fs::read_to_string(&path).unwrap(), "USER_TUNED=1\n");
    }
}
