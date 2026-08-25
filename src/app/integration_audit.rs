//! `integrations.audit_glyphs` — read-only diagnostic that surfaces
//! the three drift classes the 2026-08-09 integration audit named:
//!
//! 1. **Manifest glyph won't render** — the `chip.glyph` codepoint on
//!    an installed integration falls outside ghostty's
//!    `font-codepoint-map` routed ranges AND isn't baked into
//!    `MnmlSymbols.ttf`. Guaranteed tofu on this box.
//! 2. **id-alias duplicates in `integration-glyphs.toml`** — two rows
//!    pointing at the same codepoint under different ids (e.g.
//!    `amplify` + `mnml-aws-amplify` both → F1C0E). Cosmetic today,
//!    load-bearing on the next re-install.
//! 3. **Orphan `glyph_meta.toml` entries** — SVG path no longer
//!    exists AND the codepoint isn't in the font either. Genuine
//!    dead entries.
//!
//! Companion to `integrations.audit_shadowed_binaries` (task #921
//! era): both are "report the drift, don't repair it" so the user
//! can see the state before we mutate anything.
//!
//! Report drops into `<workspace>/.mnml/findings/glyph-audit-<epoch>.md`
//! so the Findings activity panel picks it up naturally. Toast
//! shows the total-drift count.

use crate::app::App;
use std::collections::HashMap;
use std::path::PathBuf;

/// One inclusive codepoint range parsed from ghostty's
/// `font-codepoint-map` config line, plus the font it forces the
/// range to. The font matters (#1205): ghostty applies NO fallback
/// inside a force-routed range, so "routed" only means "renders" when
/// the target font actually carries the codepoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRange {
    pub start: u32,
    pub end: u32,
    /// Target font family after the final `=` — e.g. `MnmlSymbols`,
    /// `Symbols Nerd Font Mono`. Empty when the line omitted it.
    pub font: String,
}

impl GhosttyRange {
    /// True when `cp` is in `[start, end]` inclusive.
    pub fn contains(&self, cp: u32) -> bool {
        cp >= self.start && cp <= self.end
    }
}

/// Parse every `font-codepoint-map = U+XXXX-U+YYYY=<font>` line out
/// of ghostty's config. Lines mnml doesn't understand (`font-family`,
/// `theme`, comments, whitespace) get skipped. When the config isn't
/// present or unreadable, returns an empty vec — every glyph then
/// reports as "not routed", which is the honest fallback.
pub fn parse_ghostty_codepoint_map(config_text: &str) -> Vec<GhosttyRange> {
    let mut out = Vec::new();
    for line in config_text.lines() {
        let line = line.trim();
        // Match: `font-codepoint-map = U+E5FA-U+E8FF=Symbols Nerd Font Mono`
        // (whitespace around `=` is legal per ghostty's parser).
        let Some(rest) = line.strip_prefix("font-codepoint-map") else {
            continue;
        };
        // Skip past the `=` after the key.
        let rest = rest.trim_start();
        let Some(rest) = rest.strip_prefix('=') else {
            continue;
        };
        let rest = rest.trim();
        // `rest` now looks like `U+E5FA-U+E8FF=Symbols Nerd Font Mono`.
        // LEFT of the first `=` is the range; RIGHT is the target font.
        let (range_spec, font) = match rest.split_once('=') {
            Some((r, f)) => (r, f.trim().to_string()),
            None => (rest, String::new()),
        };
        // `range_spec` = `U+E5FA-U+E8FF` (or a single `U+XXXX` — rare).
        let Some((lo_str, hi_str)) = range_spec.split_once('-') else {
            // Single-codepoint form.
            if let Some(cp) = parse_ghostty_cp(range_spec) {
                out.push(GhosttyRange {
                    start: cp,
                    end: cp,
                    font,
                });
            }
            continue;
        };
        let (Some(lo), Some(hi)) = (parse_ghostty_cp(lo_str), parse_ghostty_cp(hi_str)) else {
            continue;
        };
        if lo <= hi {
            out.push(GhosttyRange {
                start: lo,
                end: hi,
                font,
            });
        }
    }
    out
}

fn parse_ghostty_cp(s: &str) -> Option<u32> {
    let s = s.trim();
    let hex = s.strip_prefix("U+").or_else(|| s.strip_prefix("u+"))?;
    u32::from_str_radix(hex, 16).ok()
}

/// Find rows in `assignments` that share a codepoint under different ids.
/// Returned as a list of `(codepoint_hex, Vec<id>)` — the id list is at
/// least 2. Sorted by codepoint for stable output.
///
/// Cosmetic drift today (the runtime uses whichever row was last
/// inserted); load-bearing on the next re-install if the row-order
/// disagrees with the integration's declared id.
pub fn find_alias_duplicates(assignments: &[(String, u32)]) -> Vec<(u32, Vec<String>)> {
    let mut by_cp: HashMap<u32, Vec<String>> = HashMap::new();
    for (id, cp) in assignments {
        by_cp.entry(*cp).or_default().push(id.clone());
    }
    let mut out: Vec<(u32, Vec<String>)> = by_cp
        .into_iter()
        .filter(|(_, ids)| ids.len() >= 2)
        .collect();
    out.sort_by_key(|(cp, _)| *cp);
    for (_, ids) in out.iter_mut() {
        ids.sort();
    }
    out
}

/// Findings a single audit run collects. Serialized to the report.
#[derive(Debug, Default)]
pub struct AuditFindings {
    /// Manifest glyphs that ghostty won't route AND we haven't baked.
    pub unrenderable: Vec<UnrenderableGlyph>,
    /// id-alias duplicates in `integration-glyphs.toml`.
    pub duplicates: Vec<(u32, Vec<String>)>,
    /// `glyph_meta.toml` entries with dead SVG paths AND missing outlines.
    pub orphans: Vec<OrphanMeta>,
}

impl AuditFindings {
    pub fn total(&self) -> usize {
        self.unrenderable.len() + self.duplicates.len() + self.orphans.len()
    }
}

#[derive(Debug, Clone)]
pub struct UnrenderableGlyph {
    pub manifest_id: String,
    pub codepoint: u32,
    pub label: String,
    /// Where the reference lives — `"manifest"` or `"config icon"`.
    pub source: &'static str,
    /// Why it will tofu — human sentence from [`classify_glyph`].
    pub verdict: String,
}

/// mnml's own PUA block — the range mnml bakes into MnmlSymbols.ttf
/// itself, so presence there is fully decidable.
pub const MNML_PUA: std::ops::RangeInclusive<u32> = 0xF1B00..=0xF20FF;

/// The tofu decision for one referenced codepoint (#1205). Pure so
/// tests don't need fonts on disk. Returns `Some(verdict)` when the
/// glyph is certain (or near-certain) to render as `?`:
///
/// - **mnml PUA range**: mnml owns MnmlSymbols — not baked ⇒
///   guaranteed tofu, regardless of ghostty routing (a route INTO
///   MnmlSymbols can't help, and no other font carries this block).
/// - **Force-routed elsewhere**: ghostty applies no fallback inside a
///   `font-codepoint-map` range, so a resolvable target font that
///   lacks the codepoint ⇒ tofu. `route` carries
///   `(font_name, Some(cmap))` when the font file was found on disk;
///   `(_, None)` = unresolvable → honest `None` (can't verify).
/// - **Unrouted non-mnml glyphs**: the terminal's internal fallback
///   chain decides — undetectable by any app ⇒ `None`.
pub fn classify_glyph(
    cp: u32,
    baked: &std::collections::HashSet<u32>,
    route: Option<(&str, Option<&std::collections::HashSet<u32>>)>,
) -> Option<String> {
    if MNML_PUA.contains(&cp) {
        return if baked.contains(&cp) {
            None
        } else {
            Some("not baked into MnmlSymbols.ttf — guaranteed `?`".to_string())
        };
    }
    if let Some((font, Some(cmap))) = route
        && !cmap.contains(&cp)
    {
        return Some(format!(
            "force-routed to `{font}` which lacks it — `?` (routed ranges get no fallback)"
        ));
    }
    None
}

#[derive(Debug, Clone)]
pub struct OrphanMeta {
    pub codepoint: u32,
    pub svg_path: PathBuf,
    pub in_font: bool,
}

impl App {
    /// Fire the audit, write the report, toast the count.
    /// The config-icon glyphs to feed Class 1 alongside the installed
    /// manifests (#1205 — stale icon glyphs in config.toml were a
    /// blind spot; amplify's F087D lived there).
    fn audit_icon_refs(&self) -> Vec<(String, char, String)> {
        self.config
            .ui
            .integration_icons
            .iter()
            .filter_map(|i| {
                let ch = i.glyph.chars().next()?;
                let label = i.label.clone().unwrap_or_else(|| i.id.clone());
                Some((i.id.clone(), ch, label))
            })
            .collect()
    }

    /// #1205 — launch-time tofu check. Runs the same Class-1 scan the
    /// full audit uses and toasts when anything is certain to render
    /// as `?`, pointing at the full report command. Silent when clean
    /// or when MnmlSymbols hasn't been baked yet (first launch).
    pub fn glyph_audit_startup_check(&mut self) {
        let findings = collect_findings(&self.audit_icon_refs());
        let n = findings.unrenderable.len();
        if n > 0 {
            self.toast(format!(
                "\u{26A0} {n} integration icon{} will render as `?` \u{2014} run :integrations.audit_glyphs",
                if n == 1 { "" } else { "s" }
            ));
        }
    }

    pub fn audit_glyphs(&mut self) {
        let findings = collect_findings(&self.audit_icon_refs());
        let path = write_report(&self.workspace, &findings);
        let count = findings.total();
        match path {
            Some(p) if count > 0 => self.toast(format!(
                "glyph audit: {count} drift item{} → {}",
                if count == 1 { "" } else { "s" },
                p.display()
            )),
            Some(_) => self.toast("glyph audit: clean — no drift detected".to_string()),
            None => self.toast(format!(
                "glyph audit: {count} drift item{} (report write failed)",
                if count == 1 { "" } else { "s" }
            )),
        }
    }
}

fn collect_findings(config_icons: &[(String, char, String)]) -> AuditFindings {
    let mut findings = AuditFindings::default();

    // Ghostty routing map (may be empty if no config).
    let ghostty_ranges = read_ghostty_ranges();

    // Which codepoints does MnmlSymbols.ttf actually have baked?
    // `font_present = false` means the font hasn't been baked at all
    // (fresh install, first launch) — nothing mnml-PUA is assertable
    // yet, so those checks stand down rather than flagging the world.
    let (font_present, baked) = read_baked_codepoints();

    // #1205 — lazily-resolved cmaps for the fonts codepoint-map lines
    // force ranges to. Keyed by the font NAME from the config line;
    // `None` = we couldn't find a matching font file on disk (can't
    // verify → never flagged).
    let mut route_cmaps: HashMap<String, Option<std::collections::HashSet<u32>>> = HashMap::new();

    // Class 1 — walk installed manifests AND config icons, classify
    // every glyph codepoint. Deduped on (id, codepoint) since config
    // icons usually mirror the manifest they came from.
    let mut seen: std::collections::HashSet<(String, u32)> = std::collections::HashSet::new();
    let manifest_entries = read_manifest_glyphs()
        .into_iter()
        .map(|(id, ch, label)| (id, ch, label, "manifest"));
    let icon_entries = config_icons
        .iter()
        .map(|(id, ch, label)| (id.clone(), *ch, label.clone(), "config icon"));
    for (id, glyph_char, label, source) in manifest_entries.chain(icon_entries) {
        let cp = glyph_char as u32;
        // If the glyph is a plain ASCII letter (fallback shim) skip —
        // that's not a real glyph declaration. mnml-PUA refs are
        // also unassertable before the first bake exists.
        if cp < 0x80 || !seen.insert((id.clone(), cp)) {
            continue;
        }
        if MNML_PUA.contains(&cp) && !font_present {
            continue;
        }
        let route_font: Option<String> = ghostty_ranges
            .iter()
            .find(|r| r.contains(cp))
            .map(|r| r.font.clone());
        let route = match &route_font {
            Some(f) => {
                let cmap = route_cmaps
                    .entry(f.clone())
                    .or_insert_with(|| resolve_route_font_cmap(f));
                Some((f.as_str(), cmap.as_ref()))
            }
            None => None,
        };
        if let Some(verdict) = classify_glyph(cp, &baked, route) {
            findings.unrenderable.push(UnrenderableGlyph {
                manifest_id: id,
                codepoint: cp,
                label,
                source,
                verdict,
            });
        }
    }

    // Class 1b (#1205) — core-UI glyphs mnml itself draws every
    // frame: the BUILTIN_GLYPHS seeds (AI chips, spinners, …) plus
    // the script-injected tree connectors. A full font rebake wipes
    // F1F04/F1F05 until `scripts/inject_tree_connectors.py` reruns —
    // this is the check that surfaces it instead of a tofu tree.
    let core_required: Vec<(u32, &str)> = if font_present {
        crate::glyph_builder::BUILTIN_GLYPHS
            .iter()
            .map(|g| (g.codepoint, g.name))
            .chain([
                (0xF1F04, "tree-line-vertical"),
                (0xF1F05, "tree-line-corner"),
            ])
            .collect()
    } else {
        Vec::new()
    };
    for (cp, name) in core_required {
        if !baked.contains(&cp) {
            findings.unrenderable.push(UnrenderableGlyph {
                manifest_id: name.to_string(),
                codepoint: cp,
                label: "mnml core UI".to_string(),
                source: "core UI",
                verdict: "not baked into MnmlSymbols.ttf — guaranteed `?` (rerun the bake; tree connectors need scripts/inject_tree_connectors.py)".to_string(),
            });
        }
    }

    // Class 2 — id-alias duplicates in integration-glyphs.toml.
    let assignments = read_ledger();
    findings.duplicates = find_alias_duplicates(&assignments);

    // Class 3 — orphan glyph_meta.toml entries.
    for orphan in read_orphan_meta_entries(&baked) {
        findings.orphans.push(orphan);
    }

    findings
}

fn read_ghostty_ranges() -> Vec<GhosttyRange> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let path = PathBuf::from(home).join(".config/ghostty/config");
    match std::fs::read_to_string(&path) {
        Ok(text) => parse_ghostty_codepoint_map(&text),
        Err(_) => Vec::new(),
    }
}

fn read_baked_codepoints() -> (bool, std::collections::HashSet<u32>) {
    // ~/Library/Fonts/MnmlSymbols.ttf. `(false, empty)` = the font
    // isn't baked/readable at all — callers stand their mnml-PUA
    // checks down (first launch predates the first bake).
    //
    // #1205 — was a python3/fontTools shell-out; now the native
    // seek-based reader (`font_scan::cmap_codepoints`), so the audit
    // works on machines without fontTools and costs ~a millisecond.
    let Some(home) = std::env::var_os("HOME") else {
        return (false, std::collections::HashSet::new());
    };
    let path = PathBuf::from(home).join("Library/Fonts/MnmlSymbols.ttf");
    match crate::font_scan::cmap_codepoints(&path) {
        Some(set) => (true, set),
        None => (false, std::collections::HashSet::new()),
    }
}

/// #1205 — resolve a `font-codepoint-map` target font NAME to a font
/// file on disk and read its cmap. `None` = no matching file found
/// (the audit then treats the route as unverifiable, never flagged).
/// Matching is loose: the installed family (from the name table,
/// variant-collapsed) must be a prefix-ish of the config's name —
/// "Symbols Nerd Font" matches target "Symbols Nerd Font Mono".
fn resolve_route_font_cmap(font_name: &str) -> Option<std::collections::HashSet<u32>> {
    let target = font_name.trim().to_ascii_lowercase();
    if target.is_empty() {
        return None;
    }
    let installed = crate::font_scan::scan_nerd_fonts();
    let hit = installed.iter().find(|f| {
        let fam = f.family.to_ascii_lowercase();
        target == fam || target.starts_with(&fam) || fam.starts_with(&target)
    })?;
    crate::font_scan::cmap_codepoints(&hit.path)
}

/// Read every `~/.config/mnml/integrations/*.toml` and return
/// `(id, first-char-of-chip.glyph, label)` for each. Skips manifests
/// with an empty `chip.glyph`.
fn read_manifest_glyphs() -> Vec<(String, char, String)> {
    let mut out = Vec::new();
    let dir = crate::data_root::data_root().join("integrations");
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return out;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(val) = text.parse::<toml::Value>() else {
            continue;
        };
        let id = val
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or_else(|| path.file_stem().and_then(|s| s.to_str()).unwrap_or(""));
        let label = val
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or(id)
            .to_string();
        let glyph = val
            .get("chip")
            .and_then(|c| c.get("glyph"))
            .and_then(|g| g.as_str())
            .unwrap_or("");
        if let Some(ch) = glyph.chars().next() {
            out.push((id.to_string(), ch, label));
        }
    }
    out
}

/// Parse `~/.config/mnml/integration-glyphs.toml` for its (id, cp) pairs.
fn read_ledger() -> Vec<(String, u32)> {
    let mut out = Vec::new();
    let path = crate::data_root::data_root().join("integration-glyphs.toml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return out;
    };
    let Ok(val) = text.parse::<toml::Value>() else {
        return out;
    };
    let Some(entries) = val.get("assignment").and_then(|a| a.as_array()) else {
        return out;
    };
    for entry in entries {
        let id = entry.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let cp_hex = entry
            .get("codepoint")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if id.is_empty() || cp_hex.is_empty() {
            continue;
        }
        if let Ok(cp) = u32::from_str_radix(cp_hex.trim_start_matches("U+"), 16) {
            out.push((id.to_string(), cp));
        }
    }
    out
}

/// `glyph_meta.toml` entries whose `svg_path` no longer exists on disk.
/// We also stamp whether the codepoint IS in the font — an orphan meta
/// row + baked outline is a "SVG source deleted but the outline survives"
/// case (still worth flagging but distinct from "genuinely dead").
fn read_orphan_meta_entries(baked: &std::collections::HashSet<u32>) -> Vec<OrphanMeta> {
    let mut out = Vec::new();
    // The meta file lives next to MnmlSymbols.ttf's build state; a
    // small round-trip through the glyph_builder module reader keeps
    // us honest.
    let path = crate::data_root::data_root().join("glyph_meta.toml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return out;
    };
    let Ok(val) = text.parse::<toml::Value>() else {
        return out;
    };
    // Support both flat and `[[glyph]]` array shapes; the current
    // module writes `[[glyph]]`.
    let entries = val
        .get("glyph")
        .and_then(|a| a.as_array())
        .cloned()
        .unwrap_or_default();
    for entry in entries {
        let cp_hex = entry
            .get("codepoint")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let svg_path_str = entry.get("svg_path").and_then(|v| v.as_str()).unwrap_or("");
        if svg_path_str.is_empty() || cp_hex.is_empty() {
            continue;
        }
        let svg_path = PathBuf::from(svg_path_str);
        // Expand `~` if present.
        let svg_path = if let Some(rest) = svg_path_str.strip_prefix("~/") {
            std::env::var_os("HOME")
                .map(|h| PathBuf::from(h).join(rest))
                .unwrap_or(svg_path)
        } else {
            svg_path
        };
        if svg_path.exists() {
            continue;
        }
        let cp = u32::from_str_radix(cp_hex.trim_start_matches("U+"), 16).unwrap_or(0);
        out.push(OrphanMeta {
            codepoint: cp,
            svg_path,
            in_font: baked.contains(&cp),
        });
    }
    out
}

fn write_report(workspace: &std::path::Path, f: &AuditFindings) -> Option<PathBuf> {
    let dir = workspace.join(".mnml").join("findings");
    std::fs::create_dir_all(&dir).ok()?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    let path = dir.join(format!("glyph-audit-{stamp}.md"));
    let mut body = String::new();
    body.push_str("# Integration glyph audit\n\n");
    body.push_str(&format!("Drift items: {}\n\n", f.total()));
    body.push_str("Read-only report — nothing changed. See `scratchpad/sibling-audit-2026-08-09.md` for the structural design.\n\n");

    body.push_str("## Glyphs that will render as `?`\n\n");
    body.push_str(
        "**Scope (honest coverage — #1205):** this section checks (a) mnml's own \
         PUA block U+F1B00-U+F20FF against what's actually baked in `MnmlSymbols.ttf` \
         (fully decidable — mnml owns that font), and (b) codepoints your ghostty \
         `font-codepoint-map` force-routes to a font file we can find on disk \
         (forced routes get no fallback, so a missing codepoint there is tofu). \
         NOT checkable by any app: unrouted glyphs — the terminal's internal \
         fallback chain decides those.\n\n",
    );
    if f.unrenderable.is_empty() {
        body.push_str("None found within the checkable scope above.\n\n");
    } else {
        body.push_str(
            "| Id | Source | Codepoint | Label | Why | Fix |\n|---|---|---|---|---|---|\n",
        );
        for u in &f.unrenderable {
            body.push_str(&format!(
                "| `{}` | {} | U+{:04X} | {} | {} | Repoint to a live codepoint (see `integration-glyphs.toml` assignments), reinstall the integration, or rebake its SVG. |\n",
                u.manifest_id, u.source, u.codepoint, u.label, u.verdict
            ));
        }
        body.push('\n');
    }

    body.push_str("## id-alias duplicates in `integration-glyphs.toml`\n\n");
    if f.duplicates.is_empty() {
        body.push_str(
            "None. Every codepoint in the assignment ledger is claimed by exactly one id.\n\n",
        );
    } else {
        body.push_str("| Codepoint | Ids sharing it | Fix |\n|---|---|---|\n");
        for (cp, ids) in &f.duplicates {
            body.push_str(&format!(
                "| U+{:04X} | {} | Delete the shorter/legacy id from `~/.config/mnml/integration-glyphs.toml`. The `merge_integration_manifests` alias-dedupe pass now prevents new dupes. |\n",
                cp,
                ids.iter().map(|s| format!("`{s}`")).collect::<Vec<_>>().join(", ")
            ));
        }
        body.push('\n');
    }

    body.push_str("## Orphan `glyph_meta.toml` entries\n\n");
    if f.orphans.is_empty() {
        body.push_str("None. Every meta entry references a real SVG on disk.\n\n");
    } else {
        body.push_str(
            "| Codepoint | SVG path (missing) | Outline baked | Fix |\n|---|---|---|---|\n",
        );
        for o in &f.orphans {
            body.push_str(&format!(
                "| U+{:04X} | `{}` | {} | {} |\n",
                o.codepoint,
                o.svg_path.display(),
                if o.in_font { "YES" } else { "no" },
                if o.in_font {
                    "SVG source gone but outline survives in the font — safe to drop the meta entry."
                } else {
                    "Both SVG + outline gone — safe to drop the meta entry."
                },
            ));
        }
        body.push('\n');
    }

    std::fs::write(&path, body).ok()?;
    Some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_mnml_pua_requires_baked_regardless_of_routing() {
        use std::collections::HashSet;
        let baked: HashSet<u32> = [0xF1C04].into_iter().collect();
        // Baked → fine.
        assert!(classify_glyph(0xF1C04, &baked, None).is_none());
        // Not baked → guaranteed tofu, EVEN with a route covering it
        // (this is the exact codebuild F1B0A case the old logic
        // missed: routed-to-MnmlSymbols read as "renderable").
        let route_cmap: HashSet<u32> = HashSet::new();
        let verdict = classify_glyph(0xF1B0A, &baked, Some(("MnmlSymbols", Some(&route_cmap))));
        assert!(verdict.unwrap().contains("guaranteed"));
        assert!(classify_glyph(0xF1B0A, &baked, None).is_some());
    }

    #[test]
    fn classify_forced_route_checks_target_font() {
        use std::collections::HashSet;
        let baked: HashSet<u32> = HashSet::new();
        let nf: HashSet<u32> = [0xEB40].into_iter().collect();
        // Routed + present in the target font → renders.
        assert!(
            classify_glyph(0xEB40, &baked, Some(("Symbols Nerd Font Mono", Some(&nf)))).is_none()
        );
        // Routed + absent from the target font → tofu (no fallback
        // inside forced ranges).
        let v = classify_glyph(0xEB41, &baked, Some(("Symbols Nerd Font Mono", Some(&nf))));
        assert!(v.unwrap().contains("Symbols Nerd Font Mono"));
        // Routed but font file unresolvable → honest can't-verify.
        assert!(classify_glyph(0xEB41, &baked, Some(("Mystery Font", None))).is_none());
        // Unrouted non-mnml glyph → terminal fallback decides; never flagged.
        assert!(classify_glyph(0xEB41, &baked, None).is_none());
    }

    #[test]
    fn parse_captures_target_font_name() {
        let cfg = "font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols\n";
        let out = parse_ghostty_codepoint_map(cfg);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].font, "MnmlSymbols");
    }

    #[test]
    fn parse_range_line_extracts_the_pair() {
        let cfg = "font-codepoint-map = U+E5FA-U+E8FF=Symbols Nerd Font Mono\n";
        let out = parse_ghostty_codepoint_map(cfg);
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0],
            GhosttyRange {
                start: 0xE5FA,
                end: 0xE8FF,
                font: "Symbols Nerd Font Mono".to_string(),
            }
        );
    }

    #[test]
    fn parse_ignores_unrelated_lines() {
        let cfg = "\
font-family = SFMono
theme = catppuccin
# a comment
font-codepoint-map = U+F0001-U+F1AFF=Symbols Nerd Font Mono
font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols
";
        let out = parse_ghostty_codepoint_map(cfg);
        assert_eq!(out.len(), 2);
        assert!(out.iter().any(|r| r.contains(0xF07D2)));
        assert!(out.iter().any(|r| r.contains(0xF1E00)));
    }

    #[test]
    fn parse_handles_single_codepoint_form() {
        let cfg = "font-codepoint-map = U+ABCD=Menlo\n";
        let out = parse_ghostty_codepoint_map(cfg);
        assert_eq!(out.len(), 1);
        assert!(out[0].contains(0xABCD));
        assert!(!out[0].contains(0xABCE));
    }

    #[test]
    fn duplicates_detects_shared_codepoints() {
        let dupes = find_alias_duplicates(&[
            ("amplify".to_string(), 0xF1C0E),
            ("mnml-aws-amplify".to_string(), 0xF1C0E),
            ("terminal".to_string(), 0xF1C14),
        ]);
        assert_eq!(dupes.len(), 1);
        assert_eq!(dupes[0].0, 0xF1C0E);
        assert_eq!(
            dupes[0].1,
            vec!["amplify".to_string(), "mnml-aws-amplify".to_string()]
        );
    }
}
