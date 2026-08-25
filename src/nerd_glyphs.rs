//! Full Nerd Fonts glyph catalog, loaded from bundled `glyphnames.json`.
//!
//! The prior icon picker (see `icon_catalog.rs`) shipped ~200 hand-picked
//! entries and fell back to raw `U+XXXX` labels for every other codepoint
//! in the Nerd Font PUA ranges — so typing "repo pull" matched nothing
//! and users could only search by hex.
//!
//! This module compiles in the official `glyphnames.json` from
//! ryanoasis/nerd-fonts (see `data/nerd-glyphnames.json`) and exposes
//! a lazily-parsed catalog keyed by codepoint, so every row in the
//! picker carries its glyph name + category — searchable the same way
//! nerdfonts.com's search is.
//!
//! JSON shape:
//! ```json
//! {
//!   "METADATA": { "version": "...", ... },
//!   "cod-repo_pull": { "char": "", "code": "eb40" },
//!   "md-cloud_download": { "char": "2", "code": "f0162" },
//!   ...
//! }
//! ```
//!
//! Key = the canonical name (`nf-cod-repo_pull` without the `nf-` prefix).
//! `char` is the literal glyph; `code` is the hex codepoint (lower-case).
//!
//! Refresh via `curl -L https://raw.githubusercontent.com/ryanoasis/nerd-fonts/HEAD/glyphnames.json -o data/nerd-glyphnames.json`
//! and rebuild.

use std::collections::HashMap;
use std::sync::OnceLock;

/// One catalog entry — everything the picker needs to render one row.
#[derive(Debug, Clone)]
pub struct GlyphMeta {
    /// Codepoint as `u32`, e.g. `0xEB40`.
    pub codepoint: u32,
    /// Canonical name from the JSON key, e.g. `"cod-repo_pull"`.
    pub full_name: String,
    /// Category prefix (before the first `-`), e.g. `"cod"`.
    /// Meaningful values: cod, md, oct, fa, dev, weather, fae, seti, linux,
    /// custom, ple, extra, pom, pl, iec, indent, indentation.
    pub category: String,
    /// Human-readable name (underscore-to-space of the suffix after
    /// the category), e.g. `"repo pull"`. This is what a user searching
    /// "pull" is expected to type; both this and `full_name` participate
    /// in the picker's fuzzy match so `cod-repo_pull` and `repo pull`
    /// both land on the same row.
    pub human_name: String,
}

/// Full metadata catalog, keyed by codepoint. Parsed once on first
/// access — the JSON blob is ~530 KB, parse ~30 ms at release opt.
static CATALOG: OnceLock<HashMap<u32, GlyphMeta>> = OnceLock::new();

const RAW_JSON: &str = include_str!("../data/nerd-glyphnames.json");

fn build_catalog() -> HashMap<u32, GlyphMeta> {
    let Ok(root) = serde_json::from_str::<serde_json::Value>(RAW_JSON) else {
        return HashMap::new();
    };
    let Some(obj) = root.as_object() else {
        return HashMap::new();
    };
    let mut out = HashMap::with_capacity(obj.len().saturating_sub(1));
    for (name, entry) in obj {
        if name == "METADATA" {
            continue;
        }
        let Some(code) = entry.get("code").and_then(|v| v.as_str()) else {
            continue;
        };
        let Ok(cp) = u32::from_str_radix(code, 16) else {
            continue;
        };
        let (category, suffix) = match name.split_once('-') {
            Some((c, s)) => (c.to_string(), s.to_string()),
            // Entries without a category prefix are rare; treat the
            // whole thing as the name and label the category as "".
            None => (String::new(), name.clone()),
        };
        let human_name = suffix.replace('_', " ");
        out.insert(
            cp,
            GlyphMeta {
                codepoint: cp,
                full_name: name.clone(),
                category,
                human_name,
            },
        );
    }
    out
}

/// Return the metadata catalog, building it on first call.
pub fn catalog() -> &'static HashMap<u32, GlyphMeta> {
    CATALOG.get_or_init(build_catalog)
}

/// Look up one glyph by codepoint. `None` if the codepoint isn't in
/// the Nerd Fonts inventory (unassigned slot in the PUA).
pub fn get(cp: u32) -> Option<&'static GlyphMeta> {
    catalog().get(&cp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_loads_and_has_thousands_of_entries() {
        let c = catalog();
        // Sanity: Nerd Fonts 3.5+ ships ~11k glyphs. Guard against
        // an accidental empty parse.
        assert!(
            c.len() > 5000,
            "catalog only has {} entries; JSON parse failed?",
            c.len()
        );
    }

    #[test]
    fn known_glyphs_resolve() {
        let pull = get(0xEB40).expect("EB40 present");
        assert_eq!(pull.full_name, "cod-repo_pull");
        assert_eq!(pull.category, "cod");
        assert_eq!(pull.human_name, "repo pull");

        let cloud_up = get(0xF0167).expect("F0167 present");
        assert_eq!(cloud_up.category, "md");
        assert!(cloud_up.human_name.contains("cloud upload"));
    }

    #[test]
    fn unassigned_codepoint_returns_none() {
        // Middle of a Nerd Font gap.
        assert!(get(0xE099).is_none());
    }
}
