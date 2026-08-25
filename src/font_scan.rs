//! Installed-font scanning for the Marketplace FONTS section
//! (task #1202, 2026-08-25).
//!
//! Motivation: the 2026-08-25 font day showed that a *stale* Nerd Font
//! silently changes what mnml looks like — Nerd Fonts 3.4.0's codicon
//! U+EB40 is a book shape while 3.5.1's is the arrow-into-circle, and
//! nothing on the system tells you which vintage you're running. This
//! module reads the truth from the font files themselves (name-table
//! ID 5 carries "…;Nerd Fonts X.Y.Z") so the Marketplace can show
//! each installed family's version next to the latest release and
//! offer a one-click brew update.
//!
//! Three parts:
//!   - a minimal sfnt name-table reader (seek-based — never loads the
//!     multi-MB glyph tables) for TTF / OTF / first-font-of-TTC;
//!   - `scan_nerd_fonts()` over the platform font dirs, grouped by
//!     family;
//!   - the latest-release check against the ryanoasis/nerd-fonts
//!     GitHub API, cached 24h at `~/.cache/mnml/nerdfonts-latest.json`
//!     (fetch runs on a worker thread — see `App::spawn_font_check`).

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// One installed font family (deduped across weight/style files).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledFont {
    /// Typographic family (name ID 16, falling back to ID 1) —
    /// "JetBrainsMono Nerd Font Mono", "Symbols Nerd Font Mono", …
    pub family: String,
    /// The "Nerd Fonts X.Y.Z" version from name ID 5, when present.
    /// `None` for MnmlSymbols (mnml-owned, no NF lineage).
    pub nf_version: Option<String>,
    /// One representative file (the first seen for the family).
    pub path: PathBuf,
}

/// Font directories to scan, per platform. Missing dirs are skipped.
fn font_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let home = std::env::var_os("HOME").map(PathBuf::from);
    #[cfg(target_os = "macos")]
    {
        if let Some(h) = &home {
            dirs.push(h.join("Library/Fonts"));
        }
        dirs.push(PathBuf::from("/Library/Fonts"));
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(h) = &home {
            dirs.push(h.join(".local/share/fonts"));
            dirs.push(h.join(".fonts"));
        }
        dirs.push(PathBuf::from("/usr/share/fonts"));
        dirs.push(PathBuf::from("/usr/local/share/fonts"));
    }
    #[cfg(windows)]
    {
        if let Some(lad) = std::env::var_os("LOCALAPPDATA") {
            dirs.push(PathBuf::from(lad).join("Microsoft/Windows/Fonts"));
        }
        dirs.push(PathBuf::from("C:/Windows/Fonts"));
    }
    let _ = home;
    dirs
}

/// Scan the platform font dirs for Nerd Font families (plus mnml's
/// own MnmlSymbols). One entry per family; the first file wins as the
/// representative path. Non-recursive except one level down (Linux
/// often nests per-family subdirs).
pub fn scan_nerd_fonts() -> Vec<InstalledFont> {
    let mut out: Vec<InstalledFont> = Vec::new();
    let mut visit_file = |path: &Path| {
        let ext_ok = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| matches!(e.to_ascii_lowercase().as_str(), "ttf" | "otf" | "ttc"))
            .unwrap_or(false);
        if !ext_ok {
            return;
        }
        let Some((family, version_str)) = read_family_and_version(path) else {
            return;
        };
        if !is_nerd_font_family(&family) {
            return;
        }
        // Collapse variant families into one row — a single brew cask
        // ships "JetBrainsMono Nerd Font" + " Mono" + " Propo" + the
        // NL (no-ligature) trio, all at the same version. Nine rows
        // for one install read as noise (seen live 2026-08-25).
        let family = display_group(&family);
        let nf_version = version_str.as_deref().and_then(nf_version_from_id5);
        match out.iter_mut().find(|f| f.family == family) {
            Some(existing) => {
                // Same family from several weight files — keep the
                // highest version string seen (a half-updated family
                // should surface as the newer install).
                if existing.nf_version.as_deref() < nf_version.as_deref() {
                    existing.nf_version = nf_version;
                }
            }
            None => out.push(InstalledFont {
                family,
                nf_version,
                path: path.to_path_buf(),
            }),
        }
    };
    for dir in font_dirs() {
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                if let Ok(sub) = std::fs::read_dir(&p) {
                    for e2 in sub.flatten() {
                        visit_file(&e2.path());
                    }
                }
            } else {
                visit_file(&p);
            }
        }
    }
    out.sort_by(|a, b| a.family.cmp(&b.family));
    out
}

/// Is this family a Nerd Font (or mnml's own symbols face)? Covers
/// the full "X Nerd Font [Mono|Propo]" form and the abbreviated
/// "X NF" / "X NFM" / "X NFP" forms some files carry as their only
/// family name.
fn is_nerd_font_family(family: &str) -> bool {
    family == "MnmlSymbols"
        || family.contains("Nerd Font")
        || ["NF", "NFM", "NFP"]
            .iter()
            .any(|suf| family.ends_with(&format!(" {suf}")))
}

/// Canonical display/group name for a family: variant suffixes
/// (" Nerd Font Mono", " Nerd Font Propo", " NF", " NFM", " NFP") and
/// the NL no-ligatures marker all fold into "<Base> Nerd Font".
fn display_group(family: &str) -> String {
    if family == "MnmlSymbols" {
        return family.to_string();
    }
    let mut base = family.split(" Nerd Font").next().unwrap_or(family);
    for suf in [" NFM", " NFP", " NF"] {
        if let Some(stripped) = base.strip_suffix(suf) {
            base = stripped;
            break;
        }
    }
    let base = base.strip_suffix("NL").unwrap_or(base);
    format!("{} Nerd Font", base.trim_end())
}

/// Pull "X.Y.Z" out of a name-ID-5 version string like
/// "Version 3.5.1;Nerd Fonts 3.5.1" (formats vary across releases;
/// anchor on the "Nerd Fonts" marker, not the leading "Version").
pub fn nf_version_from_id5(s: &str) -> Option<String> {
    let idx = s.find("Nerd Fonts")?;
    let rest = &s[idx + "Nerd Fonts".len()..];
    let ver: String = rest
        .trim_start()
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let ver = ver.trim_matches('.').to_string();
    if ver.is_empty() { None } else { Some(ver) }
}

// ── sfnt name-table reader ────────────────────────────────────────

fn read_u16(f: &mut std::fs::File, at: u64) -> Option<u16> {
    let mut b = [0u8; 2];
    f.seek(SeekFrom::Start(at)).ok()?;
    f.read_exact(&mut b).ok()?;
    Some(u16::from_be_bytes(b))
}

fn read_u32(f: &mut std::fs::File, at: u64) -> Option<u32> {
    let mut b = [0u8; 4];
    f.seek(SeekFrom::Start(at)).ok()?;
    f.read_exact(&mut b).ok()?;
    Some(u32::from_be_bytes(b))
}

/// Read (family, version-string) from a font file's name table.
/// Family prefers typographic family (ID 16) over legacy family
/// (ID 1) — NF per-weight files often carry a styled ID 1 like
/// "JetBrainsMono NFM ExtraBold" while ID 16 is the clean family.
/// Version is name ID 5. Seek-based: touches only the table
/// directory + the name table, never the glyph data.
pub fn read_family_and_version(path: &Path) -> Option<(String, Option<String>)> {
    let mut f = std::fs::File::open(path).ok()?;
    let mut sfnt_base: u64 = 0;
    let magic = read_u32(&mut f, 0)?;
    if magic == u32::from_be_bytes(*b"ttcf") {
        // TrueType Collection — read the first font's offset.
        sfnt_base = read_u32(&mut f, 12)? as u64;
    }
    let num_tables = read_u16(&mut f, sfnt_base + 4)?;
    // Cap: a real font has well under 64 tables; anything bigger is
    // a corrupt header — bail instead of seeking around 4GB files.
    if num_tables > 64 {
        return None;
    }
    let mut name_off: Option<u64> = None;
    for i in 0..num_tables as u64 {
        let rec = sfnt_base + 12 + i * 16;
        let tag = read_u32(&mut f, rec)?;
        if tag == u32::from_be_bytes(*b"name") {
            name_off = Some(read_u32(&mut f, rec + 8)? as u64);
            break;
        }
    }
    let name_off = name_off?;
    let count = read_u16(&mut f, name_off + 2)?;
    if count > 512 {
        return None;
    }
    let string_off = name_off + read_u16(&mut f, name_off + 4)? as u64;
    // Per name-id slot: (value, came-from-windows-platform). Windows
    // (platform 3, UTF-16BE) beats Mac (platform 1, latin-ish), and
    // the FIRST record of the winning platform sticks — NF files
    // carry duplicate platform-3 ID-16 records ("JetBrainsMono Nerd
    // Font" followed by the abbreviated "JetBrainsMono NF"); last-
    // wins picked the abbreviation and broke the "Nerd Font" family
    // filter (found live on JetBrainsMonoNerdFont-Bold.ttf).
    let mut family_16: Option<(String, bool)> = None;
    let mut family_1: Option<(String, bool)> = None;
    let mut version: Option<(String, bool)> = None;
    let upgrade = |slot: &mut Option<(String, bool)>, platform: u16, s: String| {
        let is_win = platform == 3;
        match slot {
            Some((_, true)) => {}
            Some(_) if is_win => *slot = Some((s, true)),
            Some(_) => {}
            None => *slot = Some((s, is_win)),
        }
    };
    for i in 0..count as u64 {
        let rec = name_off + 6 + i * 12;
        let platform = read_u16(&mut f, rec)?;
        let name_id = read_u16(&mut f, rec + 6)?;
        if !matches!(name_id, 1 | 5 | 16) {
            continue;
        }
        let len = read_u16(&mut f, rec + 8)? as usize;
        let off = read_u16(&mut f, rec + 10)? as u64;
        if len == 0 || len > 4096 {
            continue;
        }
        let mut buf = vec![0u8; len];
        f.seek(SeekFrom::Start(string_off + off)).ok()?;
        f.read_exact(&mut buf).ok()?;
        let s = if platform == 3 {
            // UTF-16BE
            let units: Vec<u16> = buf
                .chunks_exact(2)
                .map(|c| u16::from_be_bytes([c[0], c[1]]))
                .collect();
            String::from_utf16_lossy(&units)
        } else {
            // Mac roman ≈ ASCII for every font we care about.
            buf.iter().map(|&b| b as char).collect()
        };
        let s = s.trim().to_string();
        if s.is_empty() {
            continue;
        }
        match name_id {
            16 => upgrade(&mut family_16, platform, s),
            1 => upgrade(&mut family_1, platform, s),
            5 => upgrade(&mut version, platform, s),
            _ => {}
        }
    }
    let family = family_16.or(family_1)?.0;
    Some((family, version.map(|(v, _)| v)))
}

// ── latest-release check + cache ──────────────────────────────────

/// 24h cache for the GitHub latest-release lookup.
#[derive(serde::Serialize, serde::Deserialize)]
struct LatestCache {
    version: String,
    checked_epoch: u64,
}

fn latest_cache_path() -> Option<PathBuf> {
    if let Some(root) = std::env::var_os("MNML_DATA_ROOT") {
        return Some(PathBuf::from(root).join("nerdfonts-latest.json"));
    }
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join(".cache")
            .join("mnml")
            .join("nerdfonts-latest.json"),
    )
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Cached latest Nerd Fonts version if the cache is fresher than
/// 24h. `None` = stale/missing → caller should fetch.
pub fn latest_nerdfonts_cached() -> Option<String> {
    let path = latest_cache_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    let cache: LatestCache = serde_json::from_str(&text).ok()?;
    if now_epoch().saturating_sub(cache.checked_epoch) < 24 * 3600 {
        Some(cache.version)
    } else {
        None
    }
}

/// Fetch the latest release tag from the nerd-fonts repo and persist
/// the cache. Blocking — call from a worker thread only.
pub fn fetch_latest_nerdfonts() -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .user_agent("mnml")
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .get("https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest")
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("GitHub API: HTTP {}", resp.status()));
    }
    let body = resp.text().map_err(|e| e.to_string())?;
    let json: serde_json::Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    let tag = json
        .get("tag_name")
        .and_then(|v| v.as_str())
        .ok_or("no tag_name in release")?;
    let version = tag.trim_start_matches('v').to_string();
    if let Some(path) = latest_cache_path() {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let cache = LatestCache {
            version: version.clone(),
            checked_epoch: now_epoch(),
        };
        if let Ok(text) = serde_json::to_string(&cache) {
            let _ = std::fs::write(path, text);
        }
    }
    Ok(version)
}

// ── update command mapping ────────────────────────────────────────

/// Homebrew-cask slug irregulars: NF base names whose cask token
/// isn't a plain CamelCase→kebab split. Everything else derives.
const CASK_OVERRIDES: &[(&str, &str)] = &[
    // "JetBrains" is one word in the cask token, so the naive
    // CamelCase split would wrongly produce "jet-brains-mono".
    ("JetBrainsMono", "jetbrains-mono"),
    ("MesloLGS", "meslo-lg"),
    ("MesloLGM", "meslo-lg"),
    ("MesloLGL", "meslo-lg"),
    ("SauceCodePro", "sauce-code-pro"),
    ("CaskaydiaCove", "caskaydia-cove"),
    ("CaskaydiaMono", "caskaydia-mono"),
    ("BlexMono", "blex-mono"),
    ("iMWriting", "im-writing"),
];

/// CamelCase → kebab-case ("JetBrainsMono" → "jetbrains-mono").
/// Consecutive capitals stay one word ("DejaVuSansMono" →
/// "deja-vu-sans-mono" is wrong, but DejaVu is in no one's brew list
/// under that split — overrides cover real irregulars as they come
/// up).
fn camel_to_kebab(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for (i, c) in s.chars().enumerate() {
        if c.is_ascii_uppercase() && i > 0 {
            out.push('-');
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

/// The shell command that updates one installed family, or `None`
/// when mnml can't drive the update (MnmlSymbols is auto-baked;
/// non-macOS is a v1 cut — the row shows the release URL instead).
/// brew handles install-vs-upgrade itself: `install` on an already-
/// installed cask prints "already installed" and `--force` refreshes,
/// so use `upgrade || install` to cover both.
pub fn update_command(family: &str) -> Option<String> {
    if family == "MnmlSymbols" {
        return None;
    }
    if !cfg!(target_os = "macos") {
        return None;
    }
    // "Symbols Nerd Font [Mono]" → the symbols-only cask.
    if family.starts_with("Symbols Nerd Font") {
        return Some(
            "brew upgrade --cask font-symbols-only-nerd-font || \
             brew install --cask font-symbols-only-nerd-font"
                .to_string(),
        );
    }
    // Strip the " Nerd Font" suffix (plus Mono/Propo variants) — or
    // the abbreviated " NF"/" NFM"/" NFP" — to recover the base name
    // the cask is keyed on.
    let mut base = family.split(" Nerd Font").next().unwrap_or(family);
    for suf in [" NFM", " NFP", " NF"] {
        if let Some(stripped) = base.strip_suffix(suf) {
            base = stripped;
            break;
        }
    }
    let base = base.replace(' ', "");
    if base.is_empty() {
        return None;
    }
    let kebab = CASK_OVERRIDES
        .iter()
        .find(|(k, _)| *k == base)
        .map(|(_, v)| v.to_string())
        .unwrap_or_else(|| camel_to_kebab(&base));
    let cask = format!("font-{kebab}-nerd-font");
    Some(format!(
        "brew upgrade --cask {cask} || brew install --cask {cask}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nf_version_parses_common_id5_shapes() {
        assert_eq!(
            nf_version_from_id5("Version 3.5.1;Nerd Fonts 3.5.1").as_deref(),
            Some("3.5.1")
        );
        assert_eq!(
            nf_version_from_id5("Version 2.030;ryanoasis Nerd Fonts 3.4.0").as_deref(),
            Some("3.4.0")
        );
        assert_eq!(nf_version_from_id5("Version 1.0"), None);
        assert_eq!(nf_version_from_id5("Nerd Fonts "), None);
    }

    #[test]
    fn display_group_collapses_variants() {
        for f in [
            "JetBrainsMono Nerd Font",
            "JetBrainsMono Nerd Font Mono",
            "JetBrainsMono Nerd Font Propo",
            "JetBrainsMonoNL Nerd Font Mono",
            "JetBrainsMono NF",
            "JetBrainsMonoNL NFM",
        ] {
            assert_eq!(display_group(f), "JetBrainsMono Nerd Font", "{f}");
        }
        assert_eq!(display_group("Symbols Nerd Font Mono"), "Symbols Nerd Font");
        assert_eq!(display_group("MnmlSymbols"), "MnmlSymbols");
    }

    #[test]
    fn cask_mapping_covers_the_common_families() {
        assert_eq!(
            update_command("JetBrainsMono Nerd Font Mono"),
            Some(
                "brew upgrade --cask font-jetbrains-mono-nerd-font || \
                 brew install --cask font-jetbrains-mono-nerd-font"
                    .to_string()
            )
        );
        assert_eq!(
            update_command("Symbols Nerd Font Mono"),
            Some(
                "brew upgrade --cask font-symbols-only-nerd-font || \
                 brew install --cask font-symbols-only-nerd-font"
                    .to_string()
            )
        );
        assert!(
            update_command("FiraCode Nerd Font")
                .unwrap()
                .contains("font-fira-code-nerd-font")
        );
        assert!(
            update_command("MesloLGS Nerd Font")
                .unwrap()
                .contains("font-meslo-lg-nerd-font")
        );
        // mnml-owned face is auto-baked — never offer brew.
        assert_eq!(update_command("MnmlSymbols"), None);
    }

    /// Build a minimal in-memory TTF containing just a name table,
    /// write it to a temp file, and round-trip the reader.
    #[test]
    fn name_table_reader_roundtrips_synthetic_font() {
        // Strings: ID1 family, ID5 version, ID16 typographic family.
        let fam1 = "JetBrainsMono NFM ExtraBold";
        let ver = "Version 3.5.1;Nerd Fonts 3.5.1";
        let fam16 = "JetBrainsMono Nerd Font Mono";
        let to_utf16be =
            |s: &str| -> Vec<u8> { s.encode_utf16().flat_map(|u| u.to_be_bytes()).collect() };
        // Real NF files carry a SECOND platform-3 ID-16 record with
        // the abbreviated family AFTER the full one — first must win.
        let fam16_abbrev = "JetBrainsMono NF";
        let s1 = to_utf16be(fam1);
        let s5 = to_utf16be(ver);
        let s16 = to_utf16be(fam16);
        let s16b = to_utf16be(fam16_abbrev);
        // name table: header(6) + 4 records(12 each) + strings.
        let mut name = Vec::new();
        name.extend(0u16.to_be_bytes()); // format
        name.extend(4u16.to_be_bytes()); // count
        name.extend(((6 + 4 * 12) as u16).to_be_bytes()); // stringOffset
        let push_rec = |name_id: u16, off: u16, len: u16, name: &mut Vec<u8>| {
            name.extend(3u16.to_be_bytes()); // platform 3 (Windows)
            name.extend(1u16.to_be_bytes()); // encoding
            name.extend(0x0409u16.to_be_bytes()); // lang en-US
            name.extend(name_id.to_be_bytes());
            name.extend(len.to_be_bytes());
            name.extend(off.to_be_bytes());
        };
        let (o1, l1) = (0u16, s1.len() as u16);
        let (o5, l5) = (o1 + l1, s5.len() as u16);
        let (o16, l16) = (o5 + l5, s16.len() as u16);
        let (o16b, l16b) = (o16 + l16, s16b.len() as u16);
        push_rec(1, o1, l1, &mut name);
        push_rec(5, o5, l5, &mut name);
        push_rec(16, o16, l16, &mut name);
        push_rec(16, o16b, l16b, &mut name);
        name.extend(&s1);
        name.extend(&s5);
        name.extend(&s16);
        name.extend(&s16b);
        // sfnt wrapper: offset table (12) + 1 table record (16).
        let name_offset = 12 + 16;
        let mut font = Vec::new();
        font.extend(0x00010000u32.to_be_bytes()); // sfnt version
        font.extend(1u16.to_be_bytes()); // numTables
        font.extend([0u8; 6]); // search range etc (unused)
        font.extend(*b"name");
        font.extend(0u32.to_be_bytes()); // checksum
        font.extend((name_offset as u32).to_be_bytes());
        font.extend((name.len() as u32).to_be_bytes());
        font.extend(&name);
        let dir = std::env::temp_dir().join(format!("mnml-font-scan-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("synthetic.ttf");
        std::fs::write(&path, &font).unwrap();
        let (family, version) = read_family_and_version(&path).unwrap();
        // ID 16 wins over ID 1.
        assert_eq!(family, fam16);
        assert_eq!(
            version.as_deref().and_then(nf_version_from_id5).as_deref(),
            Some("3.5.1")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Live sanity check on this machine's real font dir — only
    /// asserts when a Nerd Font is actually installed, so CI boxes
    /// without fonts stay green.
    #[test]
    fn scan_runs_without_panicking() {
        let fonts = scan_nerd_fonts();
        for f in &fonts {
            assert!(!f.family.is_empty());
        }
    }
}
