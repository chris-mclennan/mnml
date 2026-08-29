//! Integration-icons SDK — mnml-side discovery + codepoint assignment
//! + bake dispatch. (Renamed from "sibling" 2026-08-04 — task #868.)
//!
//! The integration side lives in `mnml-bridge::install_integration` /
//! `mnml-bridge::integration_glyphs_dir`. When an integration declares
//! `ChipSpec::glyph_svg`, `--install` copies the SVG to
//! `~/.cache/mnml/pending-glyphs/<id>.svg`. This module handles what
//! happens on the mnml side:
//!
//! 1. **Discovery.** [`App::discover_integration_glyphs`] scans that
//!    directory for `*.svg` at startup + on `integrations.refresh`.
//! 2. **Assignment.** Each discovered id gets a stable codepoint in
//!    `U+F1C00–U+F1CFF` (or the explicit override from the
//!    matching `IntegrationManifest.chip.glyph_codepoint`).
//!    Assignments persist in `~/.config/mnml/integration-glyphs.toml`
//!    so a codepoint doesn't jump between restarts.
//! 3. **Merge.** [`App::merge_integration_manifests`] reads the
//!    resulting `integration_glyph_codepoints` map to fill
//!    `IntegrationIcon.glyph` when the manifest declared
//!    `glyph_svg` but no explicit `glyph`.
//! 4. **Bake.** [`App::bake_integration_glyphs`] (bound to the palette
//!    command `integrations.bake_integration_glyphs`) shells out
//!    fontforge to bake every discovered SVG into
//!    `~/Library/Fonts/MnmlSymbols.ttf` in one pass. This is an
//!    explicit action, not a startup side-effect — fontforge is
//!    heavy and users don't want it firing every launch.

use crate::app::App;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The PUA block reserved for integration-shipped icons.
const INTEGRATION_RANGE_START: u32 = 0xF1C00;
const INTEGRATION_RANGE_END: u32 = 0xF1CFF;

/// One entry in `~/.config/mnml/integration-glyphs.toml`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct Assignment {
    /// Integration id (basename of the SVG file).
    id: String,
    /// Uppercase hex codepoint, no `U+` prefix.
    codepoint: String,
}

#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
struct AssignmentFile {
    #[serde(default, rename = "assignment")]
    entries: Vec<Assignment>,
}

/// Directory holding integration-shipped SVGs. Still read by discover()
/// for the current-generation `install_integration` copy-based flow;
/// slated for removal in the bake-on-install redesign (mnml-bridge
/// 0.5) which drops the disk SVGs entirely.
/// Handoff dir — `~/.cache/mnml/pending-glyphs/`. Integrations
/// using `ChipSpec::glyph_svg_bytes` write here at install time;
/// mnml bakes + deletes on the next startup so nothing persistent
/// lands anywhere.
///
/// The `mnml-bridge::pending_glyphs_dir()` writer targets HOME-only.
/// This reader mirrors that (not data_root(), since we don't want a
/// portable-mode install to double up caches).
fn pending_glyphs_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".cache")
            .join("mnml")
            .join("pending-glyphs"),
    )
}

/// Path to `~/.config/mnml/integration-glyphs.toml` (flat, top-level).
/// 2026-08-04 — moved up out of `glyphs/` since the plan is to
/// delete the whole `glyphs/` dir once the bake-on-install
/// redesign lands. Keeping the id→codepoint map at the parent
/// avoids an orphan directory holding a single TOML file.
fn assignments_path() -> Option<PathBuf> {
    Some(crate::data_root::data_root().join("integration-glyphs.toml"))
}

/// Legacy locations that get migrated to the current `integration-glyphs.toml`
/// on first load. In order from newest-legacy to oldest:
/// - `sibling-glyphs.toml` (mid-day 2026-08-04 — the "sibling" rename
///   moved this once already; renaming to "integration" is a second
///   move within the same day)
/// - `glyphs/assignments.toml` (pre-2026-08-04)
fn legacy_assignments_paths() -> Vec<PathBuf> {
    let root = crate::data_root::data_root();
    vec![
        root.join("sibling-glyphs.toml"),
        root.join("glyphs").join("assignments.toml"),
    ]
}

fn load_assignments() -> AssignmentFile {
    let Some(p) = assignments_path() else {
        return AssignmentFile::default();
    };
    // Migration: silently promote the first legacy path that has a
    // file. Later-in-list = older; we prefer newer-legacy since it's
    // more likely to be in the current TOML shape.
    if !p.exists() {
        for legacy in legacy_assignments_paths() {
            if !legacy.exists() {
                continue;
            }
            if let Some(parent) = p.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            // Prefer a rename (atomic on same fs); fall back to
            // copy+remove if rename fails for any reason.
            if std::fs::rename(&legacy, &p).is_err()
                && let Ok(text) = std::fs::read_to_string(&legacy)
            {
                let _ = std::fs::write(&p, &text);
                let _ = std::fs::remove_file(&legacy);
            }
            break;
        }
    }
    let Ok(text) = std::fs::read_to_string(&p) else {
        return AssignmentFile::default();
    };
    toml::from_str(&text).unwrap_or_default()
}

fn save_assignments(file: &AssignmentFile) {
    let Some(p) = assignments_path() else {
        return;
    };
    // #1225 — never let a caller that knows about no glyphs at all
    // truncate a populated ledger. `discover` now skips the write when
    // nothing changed, which is the primary fix; this is the backstop
    // for any future caller that recomputes the set from an empty or
    // unreadable source. A deliberate shrink to zero has to go through
    // `purge_integration_glyph_state`, which removes one known id from
    // a set it just read, and so never lands here with an empty vec
    // unless that id was genuinely the last one — in which case the
    // on-disk file has exactly one entry and this guard lets it pass.
    if file.entries.is_empty() {
        let on_disk = load_assignments().entries.len();
        if on_disk > 1 {
            eprintln!(
                "mnml: refusing to write an empty {} over {on_disk} existing entries \
                 (#1225 guard) — this would be data loss",
                p.display()
            );
            return;
        }
    }
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // Dedupe id-alias rows before write: when a short id (e.g.
    // `amplify`) and its family-qualified peer (e.g. `mnml-aws-amplify`)
    // point at the SAME codepoint, keep only the family-qualified one.
    // The short id is a legacy alias from the pre-Integration-SDK era —
    // integrations register under their crate name now, and
    // leaving both in the ledger is what surfaced in the R6
    // Amplify-icon confusion (audit 2026-08-09).
    let deduped = dedupe_aliases(file);
    if let Ok(text) = toml::to_string_pretty(&deduped) {
        let _ = crate::app::backup::write_toml_with_backup(&p, &text, "assignments");
    }
}

/// True when `short` could be an alias for `long` — i.e. `long` has the
/// form `mnml-<family>-<short>` for some `<family>` segment. Case-
/// insensitive on the tail. Match returns the LONG id, so a caller
/// building a "keep only the long form" set can consult one function.
fn is_alias_pair(short: &str, long: &str) -> bool {
    if short.is_empty() || long.len() <= short.len() {
        return false;
    }
    long.strip_prefix("mnml-")
        .and_then(|rest| rest.rsplit_once('-'))
        .is_some_and(|(_family, tail)| tail.eq_ignore_ascii_case(short))
}

fn dedupe_aliases(file: &AssignmentFile) -> AssignmentFile {
    // Group entries by codepoint so we can compare peers.
    use std::collections::HashMap;
    let mut by_cp: HashMap<String, Vec<&Assignment>> = HashMap::new();
    for e in &file.entries {
        by_cp.entry(e.codepoint.clone()).or_default().push(e);
    }
    let mut keep: Vec<Assignment> = Vec::with_capacity(file.entries.len());
    for group in by_cp.values() {
        if group.len() < 2 {
            keep.push((*group[0]).clone());
            continue;
        }
        // Multi-id-at-one-codepoint. Drop any short id whose long
        // family-qualified peer is also in the group; keep everything
        // else (unrelated dupes stay — they're real drift and the
        // audit_glyphs command will still surface them).
        let mut kept_ids: Vec<&Assignment> = Vec::new();
        for candidate in group {
            let overshadowed = group
                .iter()
                .any(|other| other.id != candidate.id && is_alias_pair(&candidate.id, &other.id));
            if !overshadowed {
                kept_ids.push(candidate);
            }
        }
        for e in kept_ids {
            keep.push((*e).clone());
        }
    }
    // Restore stable order — sort by id for determinism.
    keep.sort_by(|a, b| a.id.cmp(&b.id));
    AssignmentFile { entries: keep }
}

/// #853 — uninstall cleanup for the integration-icons SDK's on-disk
/// state. Deletes `~/.cache/mnml/pending-glyphs/<id>.svg` (if present)
/// AND drops the matching entry from `assignments.toml` (if any).
/// Leaves everything else in the assignments file untouched.
///
/// Returns `(svg_deleted, assignment_dropped)` so the caller can
/// toast a specific breakdown. Both false = no-op; user sees no
/// toast (that's the common case — most integrations don't ship
/// SVG glyphs).
///
/// Rationale from the reviewer of `2491708f`: a reinstalled
/// integration with a NEW svg could collide with the stale
/// codepoint assignment, and the orphan `<id>.svg` inflates the
/// glyphs dir over time. Called from `remove_integration_by_id`
/// alongside the base + override manifest deletes so a single
/// uninstall gesture cleans everything.
pub(crate) fn purge_integration_glyph_state(id: &str) -> (bool, bool) {
    // Bridge 0.6 writes to `~/.cache/mnml/pending-glyphs/`; the
    // pre-0.6 `<data_root>/glyphs/` location is wiped wholesale
    // at startup so we only look at pending here.
    let svg_deleted = pending_glyphs_dir()
        .map(|d| d.join(format!("{id}.svg")))
        .is_some_and(|p| p.exists() && std::fs::remove_file(&p).is_ok());
    let mut file = load_assignments();
    // #863 — also drop the glyph_meta.toml entry for the assigned
    // codepoint before removing the assignment (afterwards the
    // codepoint lookup would fail). Best-effort: uninstall is not
    // gated by whether this succeeds — the entry just leaks if the
    // meta file is unwritable, same as a partial glyph delete.
    let cp_hex = file
        .entries
        .iter()
        .find(|e| e.id == id)
        .map(|e| e.codepoint.clone());
    let before = file.entries.len();
    file.entries.retain(|e| e.id != id);
    let assignment_dropped = file.entries.len() != before;
    if assignment_dropped {
        save_assignments(&file);
    }
    if let Some(hex) = cp_hex {
        let _ = crate::glyph_builder::remove_meta_by_cp_hex(&hex);
    }
    (svg_deleted, assignment_dropped)
}

/// Walk `dir` for `*.svg` files. Returns a stably-sorted vector of
/// `(id, absolute_svg_path)` where `id` is the file stem.
/// Assignments-file entries with matching ids get their codepoints
/// re-used; new ids get the next free slot in the integration PUA range
/// (deterministic — sorted-by-id order).
pub(crate) fn discover(
    dir: &Path,
    manifest_overrides: &HashMap<String, u32>,
) -> (Vec<(String, PathBuf)>, HashMap<String, u32>) {
    let mut svgs: Vec<(String, PathBuf)> = Vec::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return (svgs, HashMap::new()),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("svg") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        // Skip empty or otherwise-suspicious ids (matches
        // mnml-bridge::validate_id — dir-traversal characters).
        if stem.is_empty() || stem.contains(['/', '\\', '\0']) {
            continue;
        }
        svgs.push((stem.to_string(), path));
    }
    // Deterministic order → deterministic codepoint assignment for
    // any id NOT already in assignments.toml or overrides.
    svgs.sort_by(|a, b| a.0.cmp(&b.0));

    // Merge prior assignments + manifest-declared explicit overrides.
    let mut file = load_assignments();
    // Snapshot for the change check at the end of this fn (#1225).
    let loaded_snapshot = file.entries.clone();
    let mut used: std::collections::HashSet<u32> = file
        .entries
        .iter()
        .filter_map(|e| u32::from_str_radix(&e.codepoint, 16).ok())
        .collect();
    // Overrides win regardless of prior assignment: bump the old
    // codepoint (if any) out of the file and re-insert the override.
    for (id, cp) in manifest_overrides {
        file.entries.retain(|e| &e.id != id);
        file.entries.push(Assignment {
            id: id.clone(),
            codepoint: format!("{cp:04X}"),
        });
        used.insert(*cp);
    }
    // 2026-08-06 — seed the codepoint map from ALL persisted
    // assignments, not just currently-discovered SVGs. The SVG can
    // be purged after bake (font is now newer than the SVG →
    // `purge_baked_pending_glyphs` deletes it), but the glyph is
    // still in the font at the assigned codepoint. Paint code needs
    // the id → codepoint mapping to render it. Was: only populated
    // for ids with a live SVG in pending-glyphs — terminal glyph
    // vanished after the first bake.
    let mut out: HashMap<String, u32> = file
        .entries
        .iter()
        .filter_map(|e| {
            u32::from_str_radix(&e.codepoint, 16)
                .ok()
                .map(|cp| (e.id.clone(), cp))
        })
        .collect();
    for (id, _path) in &svgs {
        if let Some(entry) = file.entries.iter().find(|e| &e.id == id)
            && let Ok(cp) = u32::from_str_radix(&entry.codepoint, 16)
        {
            out.insert(id.clone(), cp);
            continue;
        }
        // Assign a fresh slot from the integration PUA range. Linear
        // scan — the range is 256 slots, cheap.
        let mut assigned: Option<u32> = None;
        for cp in INTEGRATION_RANGE_START..=INTEGRATION_RANGE_END {
            if !used.contains(&cp) {
                used.insert(cp);
                assigned = Some(cp);
                break;
            }
        }
        let Some(cp) = assigned else {
            eprintln!(
                "mnml: integration glyph range U+{:04X}-U+{:04X} exhausted; \
                 dropping {id}",
                INTEGRATION_RANGE_START, INTEGRATION_RANGE_END
            );
            continue;
        };
        file.entries.push(Assignment {
            id: id.clone(),
            codepoint: format!("{cp:04X}"),
        });
        out.insert(id.clone(), cp);
    }
    // #1225 — persist ONLY when the ledger actually changed.
    //
    // This used to write unconditionally, and the comment called it
    // "idempotent". It is not: `App::new` reaches here (via
    // `with_integration_manifests_merged` →
    // `discover_integration_glyphs`), so *constructing an App* wrote
    // the user's `integration-glyphs.toml`. Any caller pointed at a
    // pending-glyphs dir with no SVGs in it — every test that builds
    // an App over a tempdir, for one — loaded the real ledger,
    // added nothing, and wrote the result straight back. When the
    // load ALSO missed (different data_root than the write), the
    // "result" was empty and the real file got truncated.
    //
    // Observed: running `cargo test` emptied
    // `~/.config/mnml/integration-glyphs.toml` on the developer's own
    // machine, leaving a 0-byte `.pre-assignments-*` backup as
    // evidence. On CI the file doesn't exist, so the same write read
    // back as `[]` and looked like a flaky glyph test for three weeks.
    //
    // Comparing against the loaded snapshot makes a no-change call a
    // genuine no-op: no write, no backup churn, nothing to truncate.
    file.entries.sort_by(|a, b| a.id.cmp(&b.id));
    if file.entries != loaded_snapshot {
        save_assignments(&file);
    }
    (svgs, out)
}

impl App {
    /// Scan `~/.cache/mnml/pending-glyphs/*.svg`, assign codepoints
    /// (respecting `IntegrationManifest.chip.glyph_codepoint`
    /// overrides), and populate `App::integration_glyph_codepoints`.
    /// Idempotent — safe to call from `App::new` AND from
    /// `integrations.refresh`.
    /// 2026-08-06 — if `[ui] terminal_glyph_svg` points at an
    /// existing file, copy it to `~/.cache/mnml/pending-glyphs/
    /// terminal.svg` so the next `integrations.refresh` +
    /// `integrations.bake_integration_glyphs` picks it up and
    /// assigns a codepoint. Idempotent — only copies when the
    /// source is newer than the pending copy. Silent no-op on any
    /// error (unreadable path, missing HOME, etc).
    pub fn stage_terminal_glyph_svg(&mut self) {
        let raw = self.config.ui.terminal_glyph_svg.trim();
        if raw.is_empty() {
            return;
        }
        let path = if let Some(rest) = raw.strip_prefix("~/") {
            let Some(home) = std::env::var_os("HOME") else {
                return;
            };
            std::path::PathBuf::from(home).join(rest)
        } else {
            std::path::PathBuf::from(raw)
        };
        if !path.exists() {
            return;
        }
        let Some(pending) = std::env::var_os("HOME").map(|h| {
            std::path::PathBuf::from(h)
                .join(".cache")
                .join("mnml")
                .join("pending-glyphs")
        }) else {
            return;
        };
        let _ = std::fs::create_dir_all(&pending);
        let dst = pending.join("terminal.svg");
        // Skip re-copy when the font already has a bake newer than
        // the source SVG. On macOS `std::fs::copy` preserves the
        // source mtime (COPYFILE_ALL), so comparing dst-vs-src is a
        // no-op: dst would always inherit src's older mtime, get
        // purged by `purge_baked_pending_glyphs` on the same startup
        // (font > svg → delete), and we'd re-stage next launch — a
        // "cleaned up 1 baked pending-glyph SVG" toast every restart
        // forever. Gate on src-vs-FONT instead: if the font is newer
        // than the user's SVG, that codepoint is already baked in;
        // only stage when the user has actually touched the source.
        let Some(home) = std::env::var_os("HOME") else {
            return;
        };
        let font = std::path::PathBuf::from(&home).join("Library/Fonts/MnmlSymbols.ttf");
        let src_mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        let font_mtime = std::fs::metadata(&font).and_then(|m| m.modified()).ok();
        if let (Some(s), Some(f)) = (src_mtime, font_mtime)
            && s <= f
        {
            return;
        }
        let _ = std::fs::copy(&path, &dst);
    }

    pub fn discover_integration_glyphs(&mut self) {
        // Build the manifest-driven override map: id → explicit
        // codepoint declared by the integration's manifest. Non-hex
        // or out-of-u32 values are silently skipped (defense in depth).
        let mut overrides: HashMap<String, u32> = HashMap::new();
        for m in &self.integration_manifests {
            let Some(chip) = &m.chip else { continue };
            let Some(cp_hex) = &chip.glyph_codepoint else {
                continue;
            };
            if let Ok(cp) = u32::from_str_radix(cp_hex.trim_start_matches("U+"), 16) {
                overrides.insert(m.id.clone(), cp);
            }
        }
        let Some(pending) = pending_glyphs_dir() else {
            return;
        };
        let (svgs, assignments) = discover(&pending, &overrides);
        self.integration_glyph_svgs = svgs;
        self.integration_glyph_codepoints = assignments;
        // 2026-08-08 — reconcile against `glyph_meta.toml`, which is
        // the source of truth for what's actually baked into the font.
        // Every `bake_builtin_glyphs_matching` call writes an entry to
        // that file with name "sibling-<id>" or "ai-<slug>"; if the
        // integration-glyphs.toml assignment disagrees, the runtime
        // HashMap ends up pointing at the wrong codepoint and the
        // chip renders whatever else lives at the stale address. That's
        // the "ghostty icon disappeared" report from tonight — the
        // assignment said F1C00 (an AWS glyph), the font had ghostty
        // at F1C14. Repair silently on every discovery pass.
        self.reconcile_glyph_codepoints_from_meta();
    }

    /// Walk `glyph_meta.toml` and, for each entry whose name matches a
    /// known runtime id pattern (`sibling-<id>` or `ai-<id>`), force
    /// the runtime HashMap + persisted assignment to that codepoint.
    /// Overwrites divergent values with the meta's authoritative
    /// codepoint. Safe to run every startup — idempotent, cheap
    /// (bounded by meta entry count, typically <100).
    fn reconcile_glyph_codepoints_from_meta(&mut self) {
        let meta = crate::glyph_builder::load_meta();
        let mut assignments = load_assignments();
        let mut changed = false;
        for entry in &meta.glyphs {
            let Ok(cp) = u32::from_str_radix(&entry.codepoint, 16) else {
                continue;
            };
            // Runtime chips key by integration id ("terminal",
            // "browser", "claude_code"). Meta names them
            // "sibling-<id>" for integrations, "ai-<slug>" for the
            // baked AI spark glyphs (F1E00/F1E01). Only reconcile the
            // integration-prefixed ones — the ai- ones are rendered via
            // hardcoded codepoints in theme.rs, not the HashMap.
            let Some(id) = entry.name.strip_prefix("sibling-") else {
                continue;
            };
            let previous = self.integration_glyph_codepoints.get(id).copied();
            if previous != Some(cp) {
                self.integration_glyph_codepoints.insert(id.to_string(), cp);
                changed = true;
            }
            // Sync the persisted assignment file too so a downstream
            // `save_assignments` doesn't clobber the fix.
            if let Some(slot) = assignments.entries.iter_mut().find(|e| e.id == id) {
                if slot.codepoint != entry.codepoint {
                    slot.codepoint = entry.codepoint.clone();
                    changed = true;
                }
            } else {
                assignments.entries.push(Assignment {
                    id: id.to_string(),
                    codepoint: entry.codepoint.clone(),
                });
                changed = true;
            }
        }
        if changed {
            save_assignments(&assignments);
        }
    }

    /// Delete pending-dir SVGs whose bytes have already been baked
    /// into `MnmlSymbols.ttf` — proxy: the font's mtime is newer
    /// than the SVG's mtime. Safe because fontforge reads the SVG
    /// synchronously at bake time; anything predating the current
    /// font is either already inside it OR the bake failed (in
    /// which case a re-install would rewrite the SVG anyway).
    ///
    /// Called at startup after discovery, so a fresh mnml launch
    /// after a successful bake cleans up automatically. Legacy
    /// `~/.cache/mnml/pending-glyphs/` files are LEFT ALONE — 0.4
    /// integrations still expect them there.
    pub fn purge_baked_pending_glyphs(&self) -> usize {
        let Some(pending) = pending_glyphs_dir() else {
            return 0;
        };
        if !pending.is_dir() {
            return 0;
        }
        let Some(home) = std::env::var_os("HOME") else {
            return 0;
        };
        let font = std::path::PathBuf::from(home).join("Library/Fonts/MnmlSymbols.ttf");
        let Ok(font_meta) = std::fs::metadata(&font) else {
            return 0;
        };
        let Ok(font_mtime) = font_meta.modified() else {
            return 0;
        };
        let mut deleted = 0usize;
        for (id, _) in &self.integration_glyph_svgs {
            let candidate = pending.join(format!("{id}.svg"));
            let Ok(svg_meta) = std::fs::metadata(&candidate) else {
                continue;
            };
            let Ok(svg_mtime) = svg_meta.modified() else {
                continue;
            };
            if font_mtime > svg_mtime && std::fs::remove_file(&candidate).is_ok() {
                deleted += 1;
            }
        }
        deleted
    }

    /// Bake every discovered integration SVG into MnmlSymbols.ttf in
    /// one fontforge invocation. Mirrors the shape of
    /// `bake_builtin_glyphs_matching` (per-glyph args passed as
    /// `--glyph SVG:CP:NAME:width=…:…`). No-op with a toast when
    /// no integration SVGs have been discovered.
    ///
    /// Wired to the `integrations.bake_integration_glyphs` palette
    /// command. Not auto-invoked at startup — fontforge is a heavy
    /// dependency and firing it every launch would be user-hostile.
    pub fn bake_integration_glyphs(&mut self) {
        if self.integration_glyph_svgs.is_empty() {
            self.toast("bake integration glyphs: no SVGs in ~/.cache/mnml/pending-glyphs/");
            return;
        }
        let Some(home) = std::env::var_os("HOME") else {
            self.toast("bake integration glyphs: $HOME unset");
            return;
        };
        let home = PathBuf::from(home);
        let font_out = home.join("Library/Fonts/MnmlSymbols.ttf");
        // Same script-resolution walk the other bake paths use — try
        // the running binary's ancestor chain first, then the
        // canonical ~/Projects/mnml/ layout.
        let script = match std::env::current_exe()
            .ok()
            .and_then(|p| {
                let mut cur = p;
                while cur.pop() {
                    let cand = cur.join("scripts/build_mnml_symbols.py");
                    if cand.exists() {
                        return Some(cand);
                    }
                }
                None
            })
            .or_else(|| {
                let cand = home.join("Projects/mnml/scripts/build_mnml_symbols.py");
                if cand.exists() { Some(cand) } else { None }
            }) {
            Some(p) => p,
            None => {
                self.toast("bake integration glyphs: build_mnml_symbols.py not found");
                return;
            }
        };
        // Build the fontforge arg list — one --glyph per SVG.
        // Missing codepoints (should be impossible after discover)
        // get skipped with a warning.
        let mut args: Vec<String> = vec![
            "-script".to_string(),
            script.to_string_lossy().into_owned(),
            "--output".to_string(),
            font_out.to_string_lossy().into_owned(),
        ];
        let mut baked = 0usize;
        for (id, svg_path) in &self.integration_glyph_svgs {
            let Some(cp) = self.integration_glyph_codepoints.get(id).copied() else {
                eprintln!("mnml: integration glyph {id} has no codepoint; skipping");
                continue;
            };
            // Default transform tuning — matches the AWS defaults
            // used by the built-in bake path. Per-integration overrides
            // are a v2 nicety (would need a `[glyph]` sub-table in
            // the manifest); v1 assumes AWS-shaped square SVGs.
            // 2026-08-06 — terminal glyph (custom SVG for the H/V
            // cluster terminal chip) needs slightly larger height +
            // lower baseline than the AWS default so it lines up
            // with the H/V split icons visually. User-tuned pixel
            // shift request.
            let (width_frac, height_frac, center_frac, center_x_frac) = if id == "terminal" {
                // Smaller than default + baseline lowered so the glyph
                // matches the H/V split icons visually. Higher center
                // = higher on screen (em units up from baseline), so
                // 0.28 pulls it below the cap-height mid-point.
                (1.07f32, 0.76f32, 0.30f32, 0.50f32)
            } else {
                (1.25f32, 0.80f32, 0.36f32, 0.50f32)
            };
            args.push("--glyph".to_string());
            args.push(format!(
                "{}:{:04X}:sibling-{}:width={:.2}:height={:.2}:center={:.2}:x_center={:.2}",
                svg_path.display(),
                cp,
                id,
                width_frac,
                height_frac,
                center_frac,
                center_x_frac,
            ));
            // Persist per-bake metadata so the "edit existing" flow
            // in the glyph builder picks up the integration SVG on
            // demand.
            crate::glyph_builder::upsert_meta(crate::glyph_builder::GlyphMeta {
                codepoint: format!("{cp:04X}"),
                name: format!("sibling-{id}"),
                svg: svg_path.to_string_lossy().into_owned(),
                width_frac,
                height_frac,
                center_frac,
                center_x_frac,
            });
            baked += 1;
        }
        if baked == 0 {
            self.toast("bake integration glyphs: nothing to bake (codepoints missing)");
            return;
        }
        let profile = crate::pty_pane::BinaryProfile {
            label: format!("bake integration glyphs ({baked})"),
            exe: "fontforge".to_string(),
            args,
            cwd: None,
            env: vec![],
            session_id: None,
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!(
            "baking {baked} integration glyph(s) · restart terminal after fontforge exits"
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write_svg(dir: &Path, name: &str) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, b"<svg/>").unwrap();
        p
    }

    #[test]
    fn is_alias_pair_matches_family_qualified_long_form() {
        assert!(is_alias_pair("amplify", "mnml-aws-amplify"));
        assert!(is_alias_pair("codebuild", "mnml-aws-codebuild"));
        assert!(is_alias_pair("slack", "mnml-msg-slack"));
        assert!(
            is_alias_pair("AMPLIFY", "mnml-aws-amplify"),
            "case-insensitive tail match"
        );
    }

    #[test]
    fn is_alias_pair_rejects_unrelated() {
        assert!(!is_alias_pair("amplify", "mnml-aws-codebuild"));
        assert!(!is_alias_pair("amplify", "amplify")); // same, not an alias-of-longer
        assert!(!is_alias_pair("aws", "mnml-aws-amplify")); // family segment != short id
        assert!(!is_alias_pair("", "mnml-aws-amplify"));
    }

    #[test]
    fn dedupe_drops_short_id_when_long_peer_shares_codepoint() {
        let file = AssignmentFile {
            entries: vec![
                Assignment {
                    id: "amplify".into(),
                    codepoint: "F1C0E".into(),
                },
                Assignment {
                    id: "mnml-aws-amplify".into(),
                    codepoint: "F1C0E".into(),
                },
                Assignment {
                    id: "terminal".into(),
                    codepoint: "F1C14".into(),
                },
            ],
        };
        let out = dedupe_aliases(&file);
        assert_eq!(out.entries.len(), 2);
        assert!(
            out.entries
                .iter()
                .any(|e| e.id == "mnml-aws-amplify" && e.codepoint == "F1C0E")
        );
        assert!(out.entries.iter().any(|e| e.id == "terminal"));
        assert!(
            !out.entries.iter().any(|e| e.id == "amplify"),
            "short alias dropped"
        );
    }

    #[test]
    fn dedupe_leaves_unrelated_dupes_alone() {
        // Two unrelated ids sharing a codepoint (real drift, not
        // aliasing) — the alias-dedupe pass should NOT collapse them.
        // The audit_glyphs command still flags this for the user.
        let file = AssignmentFile {
            entries: vec![
                Assignment {
                    id: "foo".into(),
                    codepoint: "F1C99".into(),
                },
                Assignment {
                    id: "bar".into(),
                    codepoint: "F1C99".into(),
                },
            ],
        };
        let out = dedupe_aliases(&file);
        assert_eq!(out.entries.len(), 2, "unrelated dupes preserved");
    }

    #[test]
    fn assigns_deterministic_codepoints_by_sorted_id() {
        let tmp = tempfile::tempdir().unwrap();
        write_svg(tmp.path(), "beta.svg");
        write_svg(tmp.path(), "alpha.svg");
        write_svg(tmp.path(), "charlie.svg");
        // Overwrite HOME so assignments.toml lands in the tempdir
        // via the integration_glyphs_dir() helper. EnvGuard restores
        // HOME on scope exit — including during panic unwind.
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        // Move svgs into the canonical dir under HOME.
        let canonical = tmp.path().join(".config/mnml/glyphs");
        fs::create_dir_all(&canonical).unwrap();
        for n in ["alpha.svg", "beta.svg", "charlie.svg"] {
            fs::copy(tmp.path().join(n), canonical.join(n)).unwrap();
        }
        let (svgs, assignments) = discover(&canonical, &HashMap::new());
        assert_eq!(svgs.len(), 3);
        assert_eq!(svgs[0].0, "alpha");
        assert_eq!(svgs[1].0, "beta");
        assert_eq!(svgs[2].0, "charlie");
        assert_eq!(assignments["alpha"], INTEGRATION_RANGE_START);
        assert_eq!(assignments["beta"], INTEGRATION_RANGE_START + 1);
        assert_eq!(assignments["charlie"], INTEGRATION_RANGE_START + 2);
    }

    #[test]
    fn manifest_override_pins_codepoint_outside_range() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let dir = tmp.path().join(".config/mnml/glyphs");
        fs::create_dir_all(&dir).unwrap();
        write_svg(&dir, "amplify.svg");
        let mut overrides = HashMap::new();
        overrides.insert("amplify".to_string(), 0xF1B00);
        let (svgs, assignments) = discover(&dir, &overrides);
        assert_eq!(svgs.len(), 1);
        assert_eq!(assignments["amplify"], 0xF1B00);
    }

    #[test]
    fn preserves_prior_assignment_across_calls() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        // Same Ubuntu-CI flake as `purge_integration_glyph_state_drops_svg_and_assignment_entry`:
        // XDG_CONFIG_HOME (if set on the runner) routes the assignments
        // file outside the tempdir before HOME even gets a look-in, so
        // the second `discover` call doesn't see the first call's
        // persisted state and the "prior assignment persisted"
        // assertion fires against a fresh allocation. Same guards fix
        // it: clear XDG + pin MNML_DATA_ROOT explicitly (PORTABLE_CACHE
        // OnceLock can be poisoned by a prior test in the same binary,
        // so #1041's MNML_DATA_ROOT is the actual load-bearing pin).
        // Was CI-red 2026-08-19 run 32267413016.
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));
        let dir = tmp.path().join(".cache/mnml/pending-glyphs");
        fs::create_dir_all(&dir).unwrap();
        write_svg(&dir, "one.svg");
        let (_svgs, first) = discover(&dir, &HashMap::new());
        let one_cp = first["one"];
        // Add a second SVG whose id sorts BEFORE the first. The
        // deterministic-order rule would want to assign
        // range_start to "aaa", but the prior assignment for "one"
        // must not budge.
        write_svg(&dir, "aaa.svg");
        let (_svgs, second) = discover(&dir, &HashMap::new());
        assert_eq!(second["one"], one_cp, "prior assignment persisted");
        assert_ne!(second["aaa"], one_cp);
    }

    /// #853 — `purge_integration_glyph_state` deletes the SVG AND drops
    /// the assignments-file entry. Verifies both side-effects and
    /// that unrelated entries survive.
    /// #1225 — `discover` must not write the ledger when it found
    /// nothing new. This is the data-loss guard, not a style point:
    /// `App::new` reaches `discover` via
    /// `with_integration_manifests_merged`, so before this every
    /// constructed App re-wrote the user's real
    /// `integration-glyphs.toml` — and any caller whose load missed
    /// wrote an EMPTY set over it. Running `cargo test` emptied the
    /// developer's own file and left a 0-byte `.pre-assignments-*`
    /// backup as proof; CI never noticed because the file is absent
    /// there, so the same write read back as `[]` and presented as a
    /// flaky glyph test.
    #[test]
    fn discover_over_an_empty_dir_does_not_touch_the_ledger() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));

        // Seed a populated ledger, exactly like a real user's.
        let seeded = AssignmentFile {
            entries: vec![
                Assignment {
                    id: "mnml-aws-lambda".into(),
                    codepoint: "F1C01".into(),
                },
                Assignment {
                    id: "terminal".into(),
                    codepoint: "F1C02".into(),
                },
            ],
        };
        save_assignments(&seeded);
        let path = assignments_path().unwrap();
        let before = fs::read_to_string(&path).unwrap();
        assert!(before.contains("mnml-aws-lambda"), "setup: ledger seeded");

        // An empty pending dir — the shape every App-constructing test has.
        let empty = tmp.path().join(".cache/mnml/pending-glyphs");
        fs::create_dir_all(&empty).unwrap();
        let (svgs, _map) = discover(&empty, &HashMap::new());
        assert!(svgs.is_empty(), "setup: no SVGs to discover");

        // Assert NO WRITE, not "same content", and not "no new
        // backup" either — both are vacuous here, verified by
        // reverting the fix and watching them still pass:
        //   * an unconditional save serializes identical bytes, so a
        //     content check sees no difference;
        //   * `backup_path` stamps at SECOND granularity, so the seed
        //     write and the discover write collide on one filename and
        //     the backup COUNT never moves.
        // mtime is the observable that actually distinguishes "did not
        // write" from "rewrote the same bytes": a truncate+write bumps
        // it even when the content is byte-identical.
        let mtime = |pth: &Path| {
            std::fs::metadata(pth)
                .and_then(|m| m.modified())
                .expect("ledger must exist")
        };
        // Let the clock advance past the filesystem's timestamp
        // resolution so a write is guaranteed to be observable.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let mtime_before = mtime(&path);

        let (svgs2, _m2) = discover(&empty, &HashMap::new());
        assert!(svgs2.is_empty());

        assert_eq!(
            mtime(&path),
            mtime_before,
            "discover() WROTE the ledger despite finding nothing (mtime \
             moved). With a mis-rooted or failed load, this same write \
             puts an EMPTY set over real user data."
        );
        assert_eq!(
            before,
            fs::read_to_string(&path).unwrap(),
            "ledger content changed"
        );
    }

    #[test]
    fn purge_integration_glyph_state_drops_svg_and_assignment_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        // Ubuntu-CI flake 2026-08-09: GitHub runners sometimes have
        // XDG_CONFIG_HOME set (empty or otherwise) — `data_root()`
        // consults XDG BEFORE $HOME, so a stray XDG value routes the
        // assignments file OUTSIDE the tempdir. Remove XDG for the
        // test's duration alongside the HOME override. Same pattern
        // as `src/shell_prompt.rs::tests`.
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        // #1041 — pin data_root to the tempdir explicitly. HOME+XDG
        // guards were not enough on Ubuntu because PORTABLE_CACHE
        // (a OnceLock) can be poisoned by earlier tests in the same
        // binary; MNML_DATA_ROOT is the highest-precedence override.
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));
        let dir = tmp.path().join(".cache/mnml/pending-glyphs");
        fs::create_dir_all(&dir).unwrap();
        // Seed two integration glyphs; discover assigns codepoints.
        write_svg(&dir, "victim.svg");
        write_svg(&dir, "keeper.svg");
        let (_svgs, assignments) = discover(&dir, &HashMap::new());
        // Sanity — both SVGs on disk, both entries in assignments.
        assert!(dir.join("victim.svg").exists());
        assert!(dir.join("keeper.svg").exists());
        // Diagnostic: what did discover produce? On Ubuntu we saw
        // this test fail without a clear pre/post breakdown; make
        // the failure message explicit.
        let assign_pre = load_assignments();
        let ids_pre: Vec<&str> = assign_pre.entries.iter().map(|e| e.id.as_str()).collect();
        assert!(
            assign_pre.entries.iter().any(|e| e.id == "victim"),
            "pre-purge: victim missing from assignments (in-memory={:?}, on-disk ids={:?}, data_root={:?})",
            assignments.keys().collect::<Vec<_>>(),
            ids_pre,
            crate::data_root::data_root(),
        );
        assert!(
            assign_pre.entries.iter().any(|e| e.id == "keeper"),
            "pre-purge: keeper missing from assignments (in-memory={:?}, on-disk ids={:?}, data_root={:?})",
            assignments.keys().collect::<Vec<_>>(),
            ids_pre,
            crate::data_root::data_root(),
        );
        // Purge just "victim".
        let (svg_gone, assignment_gone) = purge_integration_glyph_state("victim");
        assert!(svg_gone, "svg file was expected to exist + delete cleanly");
        assert!(
            assignment_gone,
            "assignment entry was expected to exist + drop cleanly"
        );
        assert!(!dir.join("victim.svg").exists(), "svg deleted");
        assert!(dir.join("keeper.svg").exists(), "keeper's svg untouched");
        let assign_post = load_assignments();
        let ids_post: Vec<&str> = assign_post.entries.iter().map(|e| e.id.as_str()).collect();
        assert!(
            !assign_post.entries.iter().any(|e| e.id == "victim"),
            "post-purge: victim survived (on-disk ids={ids_post:?})",
        );
        assert!(
            assign_post.entries.iter().any(|e| e.id == "keeper"),
            "post-purge: keeper's assignment entry preserved (on-disk ids={ids_post:?})",
        );
    }

    /// #863 — a matching `glyph_meta.toml` entry for the assigned
    /// codepoint is dropped when the integration is purged. Guards against
    /// zombie meta entries piling up over install/uninstall cycles.
    #[test]
    fn purge_integration_glyph_state_drops_matching_glyph_meta_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        // Same ubuntu-CI XDG flake as the integration test above (see
        // daa0aa16). `glyph_builder::meta_path()` reaches
        // `user_config_path()` which consults `$XDG_CONFIG_HOME`
        // before `$HOME`; a stray XDG value on GH runners routes
        // `glyph_meta.toml` OUTSIDE the tempdir and any pre-existing
        // meta content leaks into the assertion, making
        // `len == 1` fail. Remove XDG for the test's duration.
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));
        let dir = tmp.path().join(".cache/mnml/pending-glyphs");
        fs::create_dir_all(&dir).unwrap();
        write_svg(&dir, "victim.svg");
        write_svg(&dir, "keeper.svg");
        let (_svgs, assigned) = discover(&dir, &HashMap::new());
        let victim_cp = assigned["victim"];
        let keeper_cp = assigned["keeper"];
        // Seed both meta entries as if the user had baked them.
        crate::glyph_builder::upsert_meta(crate::glyph_builder::GlyphMeta {
            codepoint: format!("{victim_cp:04X}"),
            name: "victim".into(),
            svg: "/tmp/victim.svg".into(),
            width_frac: 1.0,
            height_frac: 1.0,
            center_frac: 0.5,
            center_x_frac: 0.5,
        });
        crate::glyph_builder::upsert_meta(crate::glyph_builder::GlyphMeta {
            codepoint: format!("{keeper_cp:04X}"),
            name: "keeper".into(),
            svg: "/tmp/keeper.svg".into(),
            width_frac: 1.0,
            height_frac: 1.0,
            center_frac: 0.5,
            center_x_frac: 0.5,
        });
        let meta_pre = crate::glyph_builder::load_meta();
        assert_eq!(meta_pre.glyphs.len(), 2);
        // Purge one.
        purge_integration_glyph_state("victim");
        let meta_post = crate::glyph_builder::load_meta();
        assert_eq!(meta_post.glyphs.len(), 1, "victim's meta entry dropped");
        assert!(
            meta_post
                .glyphs
                .iter()
                .any(|g| g.codepoint == format!("{keeper_cp:04X}")),
            "keeper's meta entry preserved"
        );
    }

    /// Nothing to purge → both flags false, no toast fired.
    #[test]
    fn purge_integration_glyph_state_noop_when_id_never_registered() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _xdg = crate::EnvGuard::remove("XDG_CONFIG_HOME");
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let _data_root = crate::EnvGuard::set("MNML_DATA_ROOT", tmp.path().join(".config/mnml"));
        let (svg_gone, assignment_gone) = purge_integration_glyph_state("nonexistent");
        assert!(!svg_gone);
        assert!(!assignment_gone);
    }
}
