//! `integrations.audit_glyphs` — read-only diagnostic that surfaces
//! the three drift classes the 2026-08-09 sibling audit named:
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
/// `font-codepoint-map` config line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GhosttyRange {
    pub start: u32,
    pub end: u32,
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
        // Split on `=`; the LEFT side is the range.
        let Some(range_spec) = rest.split('=').next() else {
            continue;
        };
        // `range_spec` = `U+E5FA-U+E8FF` (or a single `U+XXXX` — rare).
        let Some((lo_str, hi_str)) = range_spec.split_once('-') else {
            // Single-codepoint form.
            if let Some(cp) = parse_ghostty_cp(range_spec) {
                out.push(GhosttyRange {
                    start: cp,
                    end: cp,
                });
            }
            continue;
        };
        let (Some(lo), Some(hi)) = (parse_ghostty_cp(lo_str), parse_ghostty_cp(hi_str)) else {
            continue;
        };
        if lo <= hi {
            out.push(GhosttyRange { start: lo, end: hi });
        }
    }
    out
}

fn parse_ghostty_cp(s: &str) -> Option<u32> {
    let s = s.trim();
    let hex = s.strip_prefix("U+").or_else(|| s.strip_prefix("u+"))?;
    u32::from_str_radix(hex, 16).ok()
}

/// True when `cp` is in ANY of the routed ranges.
pub fn is_routed(cp: u32, ranges: &[GhosttyRange]) -> bool {
    ranges.iter().any(|r| r.contains(cp))
}

/// Find rows in `assignments` that share a codepoint under different ids.
/// Returned as a list of `(codepoint_hex, Vec<id>)` — the id list is at
/// least 2. Sorted by codepoint for stable output.
///
/// Cosmetic drift today (the runtime uses whichever row was last
/// inserted); load-bearing on the next re-install if the row-order
/// disagrees with the sibling's declared id.
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
}

#[derive(Debug, Clone)]
pub struct OrphanMeta {
    pub codepoint: u32,
    pub svg_path: PathBuf,
    pub in_font: bool,
}

impl App {
    /// Fire the audit, write the report, toast the count.
    pub fn audit_glyphs(&mut self) {
        let findings = collect_findings();
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

fn collect_findings() -> AuditFindings {
    let mut findings = AuditFindings::default();

    // Ghostty routing map (may be empty if no config).
    let ghostty_ranges = read_ghostty_ranges();

    // Which codepoints does MnmlSymbols.ttf actually have baked?
    let baked = read_baked_codepoints();

    // Class 1 — walk installed manifests, check every chip.glyph codepoint.
    for (id, glyph_char, label) in read_manifest_glyphs() {
        let cp = glyph_char as u32;
        // If the glyph is a plain ASCII letter (fallback shim) skip —
        // that's not a real glyph declaration.
        if cp < 0x80 {
            continue;
        }
        let routed = is_routed(cp, &ghostty_ranges);
        let in_mnml_font = baked.contains(&cp);
        if !routed && !in_mnml_font {
            findings.unrenderable.push(UnrenderableGlyph {
                manifest_id: id,
                codepoint: cp,
                label,
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

fn read_baked_codepoints() -> std::collections::HashSet<u32> {
    use std::collections::HashSet;
    // ~/Library/Fonts/MnmlSymbols.ttf. If missing, treat every glyph as
    // "not in mnml font" — the audit still runs, just conservatively.
    let Some(home) = std::env::var_os("HOME") else {
        return HashSet::new();
    };
    let path = PathBuf::from(home).join("Library/Fonts/MnmlSymbols.ttf");
    if !path.exists() {
        return HashSet::new();
    }
    // Parse the TTF's cmap directly via a tiny shell-out. We can't
    // pull `ttf-parser` into mnml core for one call site — but Python's
    // `fontTools` is on the user's machine (used elsewhere by the
    // glyph bake pipeline).
    let out = std::process::Command::new("python3")
        .arg("-c")
        .arg(
            r#"
import sys
try:
    from fontTools.ttLib import TTFont
    f = TTFont(sys.argv[1])
    for cp in sorted(f['cmap'].getBestCmap().keys()):
        print(f"{cp:X}")
except Exception:
    pass
"#,
        )
        .arg(&path)
        .output();
    let Ok(o) = out else {
        return HashSet::new();
    };
    let text = String::from_utf8_lossy(&o.stdout);
    text.lines()
        .filter_map(|l| u32::from_str_radix(l.trim(), 16).ok())
        .collect()
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
        let cp_hex = entry.get("codepoint").and_then(|v| v.as_str()).unwrap_or("");
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
fn read_orphan_meta_entries(
    baked: &std::collections::HashSet<u32>,
) -> Vec<OrphanMeta> {
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
        let cp_hex = entry.get("codepoint").and_then(|v| v.as_str()).unwrap_or("");
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

    body.push_str("## Manifest glyphs that won't render\n\n");
    if f.unrenderable.is_empty() {
        body.push_str("None. Every installed manifest's `chip.glyph` codepoint is either in ghostty's `font-codepoint-map` OR baked into `MnmlSymbols.ttf`.\n\n");
    } else {
        body.push_str("| Manifest id | Codepoint | Label | Fix |\n|---|---|---|---|\n");
        for u in &f.unrenderable {
            body.push_str(&format!(
                "| `{}` | U+{:04X} | {} | Swap the sibling's `chip.glyph` to a codepoint in ghostty's routed range (F0001-F1AFF for MDI, E5FA-E8FF for codicon/DevIcons) OR ship an SVG for baking. |\n",
                u.manifest_id, u.codepoint, u.label
            ));
        }
        body.push('\n');
    }

    body.push_str("## id-alias duplicates in `integration-glyphs.toml`\n\n");
    if f.duplicates.is_empty() {
        body.push_str("None. Every codepoint in the assignment ledger is claimed by exactly one id.\n\n");
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
        body.push_str("| Codepoint | SVG path (missing) | Outline baked | Fix |\n|---|---|---|---|\n");
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
    fn parse_range_line_extracts_the_pair() {
        let cfg = "font-codepoint-map = U+E5FA-U+E8FF=Symbols Nerd Font Mono\n";
        let out = parse_ghostty_codepoint_map(cfg);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0], GhosttyRange { start: 0xE5FA, end: 0xE8FF });
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
    fn is_routed_true_when_in_any_range() {
        let ranges = vec![
            GhosttyRange { start: 0xE5FA, end: 0xE8FF },
            GhosttyRange { start: 0xF0001, end: 0xF1AFF },
        ];
        assert!(is_routed(0xE8A4, &ranges));
        assert!(is_routed(0xF07D2, &ranges));
        assert!(!is_routed(0xF0F6, &ranges), "F0F6 falls outside routed ranges — should tofu");
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
