//! Sibling-icons SDK — mnml-side discovery + codepoint assignment
//! + bake dispatch.
//!
//! The sibling side lives in `mnml-bridge::install_integration` /
//! `mnml-bridge::sibling_glyphs_dir`. When a sibling declares
//! `ChipSpec::glyph_svg`, `--install` copies the SVG to
//! `~/.config/mnml/glyphs/<id>.svg`. This module handles what
//! happens on the mnml side:
//!
//! 1. **Discovery.** [`App::discover_sibling_glyphs`] scans that
//!    directory for `*.svg` at startup + on `integrations.refresh`.
//! 2. **Assignment.** Each discovered id gets a stable codepoint in
//!    `U+F1C00–U+F1CFF` (or the explicit override from the
//!    matching `IntegrationManifest.chip.glyph_codepoint`).
//!    Assignments persist in `~/.config/mnml/glyphs/assignments.toml`
//!    so a codepoint doesn't jump between restarts.
//! 3. **Merge.** [`App::merge_integration_manifests`] reads the
//!    resulting `sibling_glyph_codepoints` map to fill
//!    `IntegrationIcon.glyph` when the manifest declared
//!    `glyph_svg` but no explicit `glyph`.
//! 4. **Bake.** [`App::bake_sibling_glyphs`] (bound to the palette
//!    command `integrations.bake_sibling_glyphs`) shells out
//!    fontforge to bake every discovered SVG into
//!    `~/Library/Fonts/MnmlSymbols.ttf` in one pass. This is an
//!    explicit action, not a startup side-effect — fontforge is
//!    heavy and users don't want it firing every launch.

use crate::app::App;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The PUA block reserved for sibling-shipped icons.
const SIBLING_RANGE_START: u32 = 0xF1C00;
const SIBLING_RANGE_END: u32 = 0xF1CFF;

/// One entry in `~/.config/mnml/glyphs/assignments.toml`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct Assignment {
    /// Sibling id (basename of the SVG file).
    id: String,
    /// Uppercase hex codepoint, no `U+` prefix.
    codepoint: String,
}

#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
struct AssignmentFile {
    #[serde(default, rename = "assignment")]
    entries: Vec<Assignment>,
}

/// Path to `~/.config/mnml/glyphs/`. `None` if `$HOME` is unset.
fn sibling_glyphs_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".config")
            .join("mnml")
            .join("glyphs"),
    )
}

fn assignments_path() -> Option<PathBuf> {
    Some(sibling_glyphs_dir()?.join("assignments.toml"))
}

fn load_assignments() -> AssignmentFile {
    let Some(p) = assignments_path() else {
        return AssignmentFile::default();
    };
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
/// state. Deletes `~/.config/mnml/glyphs/<id>.svg` (if present)
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
pub(crate) fn purge_sibling_glyph_state(id: &str) -> (bool, bool) {
    let svg_deleted = sibling_glyphs_dir()
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
    // For each discovered SVG, find or assign a codepoint.
    let mut out: HashMap<String, u32> = HashMap::new();
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
        for cp in SIBLING_RANGE_START..=SIBLING_RANGE_END {
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
                SIBLING_RANGE_START, SIBLING_RANGE_END
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
    /// Scan `~/.config/mnml/glyphs/*.svg`, assign codepoints
    /// (respecting `IntegrationManifest.chip.glyph_codepoint`
    /// overrides), and populate `App::sibling_glyph_codepoints`.
    /// Idempotent — safe to call from `App::new` AND from
    /// `integrations.refresh`.
    pub fn discover_sibling_glyphs(&mut self) {
        let Some(dir) = sibling_glyphs_dir() else {
            return;
        };
        // Build the manifest-driven override map: id → explicit
        // codepoint declared by the sibling's manifest. Non-hex or
        // out-of-u32 values are silently skipped (defense in depth).
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
        let (svgs, assignments) = discover(&dir, &overrides);
        // Remember the discovered set on the app so
        // merge_integration_manifests + bake can find each SVG.
        self.sibling_glyph_svgs = svgs;
        self.sibling_glyph_codepoints = assignments;
    }

    /// Bake every discovered sibling SVG into MnmlSymbols.ttf in
    /// one fontforge invocation. Mirrors the shape of
    /// `bake_builtin_glyphs_matching` (per-glyph args passed as
    /// `--glyph SVG:CP:NAME:width=…:…`). No-op with a toast when
    /// no sibling SVGs have been discovered.
    ///
    /// Wired to the `integrations.bake_sibling_glyphs` palette
    /// command. Not auto-invoked at startup — fontforge is a heavy
    /// dependency and firing it every launch would be user-hostile.
    pub fn bake_sibling_glyphs(&mut self) {
        if self.sibling_glyph_svgs.is_empty() {
            self.toast("bake sibling glyphs: no SVGs in ~/.config/mnml/glyphs/");
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
        for (id, svg_path) in &self.sibling_glyph_svgs {
            let Some(cp) = self.sibling_glyph_codepoints.get(id).copied() else {
                eprintln!("mnml: sibling glyph {id} has no codepoint; skipping");
                continue;
            };
            // Default transform tuning — matches the AWS defaults
            // used by the built-in bake path. Per-sibling overrides
            // are a v2 nicety (would need a `[glyph]` sub-table in
            // the manifest); v1 assumes AWS-shaped square SVGs.
            args.push("--glyph".to_string());
            args.push(format!(
                "{}:{:04X}:sibling-{}:width=1.25:height=0.80:center=0.36:x_center=0.50",
                svg_path.display(),
                cp,
                id,
            ));
            // Persist per-bake metadata so the "edit existing" flow
            // in the glyph builder picks up the sibling SVG on
            // demand.
            crate::glyph_builder::upsert_meta(crate::glyph_builder::GlyphMeta {
                codepoint: format!("{cp:04X}"),
                name: format!("sibling-{id}"),
                svg: svg_path.to_string_lossy().into_owned(),
                width_frac: 1.25,
                height_frac: 0.80,
                center_frac: 0.36,
                center_x_frac: 0.50,
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
        // via the sibling_glyphs_dir() helper. EnvGuard restores
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
        assert_eq!(assignments["alpha"], SIBLING_RANGE_START);
        assert_eq!(assignments["beta"], SIBLING_RANGE_START + 1);
        assert_eq!(assignments["charlie"], SIBLING_RANGE_START + 2);
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
        let dir = tmp.path().join(".config/mnml/glyphs");
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

    /// #853 — `purge_sibling_glyph_state` deletes the SVG AND drops
    /// the assignments-file entry. Verifies both side-effects and
    /// that unrelated entries survive.
    #[test]
    fn purge_sibling_glyph_state_drops_svg_and_assignment_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let dir = tmp.path().join(".config/mnml/glyphs");
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
        let (svg_gone, assignment_gone) = purge_sibling_glyph_state("victim");
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
    fn purge_sibling_glyph_state_drops_matching_glyph_meta_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let dir = tmp.path().join(".config/mnml/glyphs");
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
        purge_sibling_glyph_state("victim");
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
    fn purge_sibling_glyph_state_noop_when_id_never_registered() {
        let tmp = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _home = crate::EnvGuard::set("HOME", tmp.path());
        let (svg_gone, assignment_gone) = purge_sibling_glyph_state("nonexistent");
        assert!(!svg_gone);
        assert!(!assignment_gone);
    }
}
