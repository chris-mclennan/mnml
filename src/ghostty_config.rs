//! Parse `~/.config/ghostty/config` far enough to answer "which font
//! would ghostty use to render this codepoint?".
//!
//! We only care about `font-codepoint-map` lines. Shape:
//!
//! ```text
//! font-codepoint-map = U+EA60-U+EC1E=Symbols Nerd Font Mono
//! font-codepoint-map = U+F0001-U+F1AFF=Symbols Nerd Font Mono
//! font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols
//! ```
//!
//! Rules cascade top-down; the LAST matching entry wins in ghostty
//! (later config lines override earlier ones for the same codepoint).
//!
//! Codepoints outside every mapped range fall back to the terminal's
//! primary font family (which we don't try to detect — that's ghostty
//! font-stack territory and not knowable without linking ghostty).
//!
//! Used by the icon picker to surface the routing on the footer so
//! the user can see WHY a glyph renders the way it does.

use std::path::PathBuf;
use std::sync::OnceLock;

#[derive(Debug, Clone)]
struct CodepointRange {
    start: u32,
    end: u32,
    family: String,
}

static RULES: OnceLock<Vec<CodepointRange>> = OnceLock::new();

fn ghostty_config_path() -> Option<PathBuf> {
    // macOS + Linux use the same location.
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .map(|p| p.join("ghostty").join("config"))
}

fn parse_rules() -> Vec<CodepointRange> {
    let Some(path) = ghostty_config_path() else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let Some(rest) = line
            .strip_prefix("font-codepoint-map")
            .and_then(|s| s.trim_start().strip_prefix('='))
            .map(str::trim)
        else {
            continue;
        };
        // Split "U+EA60-U+EC1E=Symbols Nerd Font Mono" on the LAST
        // `=` (family names could theoretically contain one; ranges
        // never do).
        let Some((cps, family)) = rest.rsplit_once('=') else {
            continue;
        };
        let family = family.trim().to_string();
        // Range: `U+EA60-U+EC1E` or single `U+EA60`.
        let cps = cps.trim();
        let (a, b) = if let Some((a, b)) = cps.split_once('-') {
            (a.trim(), b.trim())
        } else {
            (cps, cps)
        };
        let parse = |s: &str| {
            s.trim_start_matches("U+")
                .trim_start_matches("u+")
                .parse::<u32>()
                .ok()
                .or_else(|| {
                    u32::from_str_radix(s.trim_start_matches("U+").trim_start_matches("u+"), 16)
                        .ok()
                })
        };
        if let (Some(start), Some(end)) = (parse(a), parse(b)) {
            out.push(CodepointRange { start, end, family });
        }
    }
    out
}

fn rules() -> &'static [CodepointRange] {
    RULES.get_or_init(parse_rules)
}

/// Which font would ghostty use for this codepoint per the parsed
/// codepoint-map? `None` = codepoint is outside every mapped range
/// (falls back to the terminal's primary font — we can't tell what
/// that is from here).
pub fn resolve_family(cp: u32) -> Option<&'static str> {
    // Later rules override earlier ones in ghostty — walk from the
    // end and take the first hit.
    for r in rules().iter().rev() {
        if cp >= r.start && cp <= r.end {
            return Some(r.family.as_str());
        }
    }
    None
}

/// True if any codepoint-map rule was successfully parsed from the
/// config. False when no ghostty config is present or all lines
/// were malformed — surfaces to the picker as "no routing info" so
/// the footer doesn't lie about mapping when we have no data.
pub fn has_any_rules() -> bool {
    !rules().is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_test_rules() -> Vec<CodepointRange> {
        vec![
            CodepointRange {
                start: 0xEA60,
                end: 0xEC1E,
                family: "Symbols Nerd Font Mono".to_string(),
            },
            CodepointRange {
                start: 0xF1B00,
                end: 0xF20FF,
                family: "MnmlSymbols".to_string(),
            },
        ]
    }

    fn resolve(cp: u32, rules: &[CodepointRange]) -> Option<&str> {
        for r in rules.iter().rev() {
            if cp >= r.start && cp <= r.end {
                return Some(&r.family);
            }
        }
        None
    }

    #[test]
    fn eb40_maps_to_symbols_nerd_font_mono() {
        let rules = build_test_rules();
        assert_eq!(resolve(0xEB40, &rules), Some("Symbols Nerd Font Mono"));
    }

    #[test]
    fn baked_range_maps_to_mnmlsymbols() {
        let rules = build_test_rules();
        assert_eq!(resolve(0xF1F10, &rules), Some("MnmlSymbols"));
    }

    #[test]
    fn unmapped_codepoint_returns_none() {
        let rules = build_test_rules();
        assert_eq!(resolve(0xF404, &rules), None);
    }

    #[test]
    fn later_rules_override_earlier() {
        // If two rules cover a codepoint, the LATER one wins —
        // matches ghostty's cascading behavior.
        let rules = vec![
            CodepointRange {
                start: 0xEA00,
                end: 0xEFFF,
                family: "Font A".to_string(),
            },
            CodepointRange {
                start: 0xEB40,
                end: 0xEB40,
                family: "Font B".to_string(),
            },
        ];
        assert_eq!(resolve(0xEB40, &rules), Some("Font B"));
    }
}
