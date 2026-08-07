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
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
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

/// Directory holding sibling-shipped SVGs. Still read by discover()
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
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = toml::to_string_pretty(file) {
        let _ = std::fs::write(&p, text);
    }
}

/// #853 — uninstall cleanup for the sibling-icons SDK's on-disk
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
/// re-used; new ids get the next free slot in the sibling PUA range
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
        // Assign a fresh slot from the sibling PUA range. Linear
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
                "mnml: sibling glyph range U+{:04X}-U+{:04X} exhausted; \
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
    // Persist (idempotent write).
    file.entries.sort_by(|a, b| a.id.cmp(&b.id));
    save_assignments(&file);
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
        // Skip re-copy when the pending file is already fresh.
        let src_mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        let dst_mtime = std::fs::metadata(&dst).and_then(|m| m.modified()).ok();
        if let (Some(s), Some(d)) = (src_mtime, dst_mtime)
            && s <= d
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

    /// Bake every discovered sibling SVG into MnmlSymbols.ttf in
    /// one fontforge invocation. Mirrors the shape of
    /// `bake_builtin_glyphs_matching` (per-glyph args passed as
    /// `--glyph SVG:CP:NAME:width=…:…`). No-op with a toast when
    /// no sibling SVGs have been discovered.
    ///
    /// Wired to the `integrations.bake_integration_glyphs` palette
    /// command. Not auto-invoked at startup — fontforge is a heavy
    /// dependency and firing it every launch would be user-hostile.
    pub fn bake_integration_glyphs(&mut self) {
        if self.integration_glyph_svgs.is_empty() {
            self.toast("bake sibling glyphs: no SVGs in ~/.cache/mnml/pending-glyphs/");
            return;
        }
        let Some(home) = std::env::var_os("HOME") else {
            self.toast("bake sibling glyphs: $HOME unset");
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
                self.toast("bake sibling glyphs: build_mnml_symbols.py not found");
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
                eprintln!("mnml: sibling glyph {id} has no codepoint; skipping");
                continue;
            };
            // Default transform tuning — matches the AWS defaults
            // used by the built-in bake path. Per-sibling overrides
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
            // in the glyph builder picks up the sibling SVG on
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
            self.toast("bake sibling glyphs: nothing to bake (codepoints missing)");
            return;
        }
        let profile = crate::pty_pane::BinaryProfile {
            label: format!("bake sibling glyphs ({baked})"),
            exe: "fontforge".to_string(),
            args,
            cwd: None,
            env: vec![],
            session_id: None,
            integration_id: None,
        };
        self.open_pty(profile);
        self.toast(format!(
            "baking {baked} sibling glyph(s) · restart terminal after fontforge exits"
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
        let _home = crate::EnvGuard::set("HOME", tmp.path());
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
    #[test]
    fn purge_integration_glyph_state_drops_svg_and_assignment_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let dir = tmp.path().join(".cache/mnml/pending-glyphs");
        fs::create_dir_all(&dir).unwrap();
        // Seed two sibling glyphs; discover assigns codepoints.
        write_svg(&dir, "victim.svg");
        write_svg(&dir, "keeper.svg");
        let (_svgs, _) = discover(&dir, &HashMap::new());
        // Sanity — both SVGs on disk, both entries in assignments.
        assert!(dir.join("victim.svg").exists());
        assert!(dir.join("keeper.svg").exists());
        let assign_pre = load_assignments();
        assert!(assign_pre.entries.iter().any(|e| e.id == "victim"));
        assert!(assign_pre.entries.iter().any(|e| e.id == "keeper"));
        // Purge just "victim".
        let (svg_gone, assignment_gone) = purge_integration_glyph_state("victim");
        assert!(svg_gone);
        assert!(assignment_gone);
        assert!(!dir.join("victim.svg").exists(), "svg deleted");
        assert!(dir.join("keeper.svg").exists(), "keeper's svg untouched");
        let assign_post = load_assignments();
        assert!(!assign_post.entries.iter().any(|e| e.id == "victim"));
        assert!(
            assign_post.entries.iter().any(|e| e.id == "keeper"),
            "keeper's assignment entry preserved"
        );
    }

    /// #863 — a matching `glyph_meta.toml` entry for the assigned
    /// codepoint is dropped when the sibling is purged. Guards against
    /// zombie meta entries piling up over install/uninstall cycles.
    #[test]
    fn purge_integration_glyph_state_drops_matching_glyph_meta_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
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
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let (svg_gone, assignment_gone) = purge_integration_glyph_state("nonexistent");
        assert!(!svg_gone);
        assert!(!assignment_gone);
    }
}
