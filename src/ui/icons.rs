//! File-type icons + colors, transcribed verbatim from
//! `nvim-tree/nvim-web-devicons` (default theme). Glyphs use Nerd Font
//! codepoints; with `nerd_font == false` we fall back to ASCII so terminals
//! without a Nerd Font configured still render usefully.

use ratatui::style::Color;
use std::path::Path;

/// (glyph string, RGB color) for one file/folder.
pub type Icon = (&'static str, Color);

pub const DEFAULT_FILE: Icon = ("\u{F15B}", Color::Rgb(0x6d, 0x80, 0x86));
pub const DEFAULT_FILE_ASCII: Icon = ("·", Color::Rgb(0x6d, 0x80, 0x86));

pub const FOLDER_CLOSED: Icon = ("\u{F07B}", Color::Rgb(0xe7, 0xc7, 0x87));
pub const FOLDER_OPEN: Icon = ("\u{F07C}", Color::Rgb(0xe7, 0xc7, 0x87));
pub const FOLDER_CLOSED_ASCII: Icon = ("\u{25B6}", Color::Rgb(0xe7, 0xc7, 0x87)); // ▶
pub const FOLDER_OPEN_ASCII: Icon = ("\u{25BC}", Color::Rgb(0xe7, 0xc7, 0x87)); // ▼

/// Resolve an icon for `path`. `is_dir` distinguishes folders; `is_expanded`
/// only matters when `is_dir`. `nerd_font` switches between real glyphs and
/// single-char ASCII stand-ins (so column widths stay stable).
pub fn for_path(path: &Path, is_dir: bool, is_expanded: bool, nerd_font: bool) -> Icon {
    if is_dir {
        return match (nerd_font, is_expanded) {
            (true, true) => FOLDER_OPEN,
            (true, false) => FOLDER_CLOSED,
            (false, true) => FOLDER_OPEN_ASCII,
            (false, false) => FOLDER_CLOSED_ASCII,
        };
    }
    if !nerd_font {
        return DEFAULT_FILE_ASCII;
    }
    let name_lower = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if let Some(icon) = filename_icon(&name_lower) {
        return icon;
    }
    let ext_lower = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    extension_icon(&ext_lower).unwrap_or(DEFAULT_FILE)
}

fn filename_icon(name: &str) -> Option<Icon> {
    Some(match name {
        "package.json" => ("\u{E71E}", Color::Rgb(0xE8, 0x27, 0x4B)),
        "package-lock.json" => ("\u{E71E}", Color::Rgb(0x7A, 0x0D, 0x21)),
        "pnpm-lock.yaml" => ("\u{E865}", Color::Rgb(0xF9, 0xAD, 0x02)),
        "tsconfig.json" => ("\u{E69D}", Color::Rgb(0x51, 0x9A, 0xBA)),
        ".env" => ("\u{F462}", Color::Rgb(0xFA, 0xF7, 0x43)),
        ".gitignore" | ".gitattributes" => ("\u{E702}", Color::Rgb(0xF5, 0x4D, 0x27)),
        ".gitconfig" => ("\u{E615}", Color::Rgb(0xF5, 0x4D, 0x27)),
        ".eslintrc" => ("\u{E655}", Color::Rgb(0x4B, 0x32, 0xC3)),
        ".prettierrc" => ("\u{E6B4}", Color::Rgb(0x42, 0x85, 0xF4)),
        ".editorconfig" => ("\u{E652}", Color::Rgb(0xFF, 0xF2, 0xF2)),
        ".dockerignore" => ("\u{F0868}", Color::Rgb(0x45, 0x8E, 0xE6)),
        ".npmrc" => ("\u{E71E}", Color::Rgb(0xE8, 0x27, 0x4B)),
        ".nvmrc" => ("\u{E718}", Color::Rgb(0x5F, 0xA0, 0x4E)),
        "dockerfile" | "docker-compose.yml" | "docker-compose.yaml" | "compose.yml"
        | "compose.yaml" => ("\u{F0868}", Color::Rgb(0x45, 0x8E, 0xE6)),
        "readme" | "readme.md" => ("\u{F00BA}", Color::Rgb(0xED, 0xED, 0xED)),
        "license" => ("\u{E60A}", Color::Rgb(0xD0, 0xBF, 0x41)),
        "copying" => ("\u{E60A}", Color::Rgb(0xCB, 0xCB, 0x41)),
        "makefile" => ("\u{E779}", Color::Rgb(0x6D, 0x80, 0x86)),
        _ => return None,
    })
}

fn extension_icon(ext: &str) -> Option<Icon> {
    Some(match ext {
        "ts" => ("\u{E628}", Color::Rgb(0x51, 0x9A, 0xBA)),
        "tsx" => ("\u{E7BA}", Color::Rgb(0x13, 0x54, 0xBF)),
        "js" | "cjs" => ("\u{E60C}", Color::Rgb(0xCB, 0xCB, 0x41)),
        "mjs" => ("\u{E60C}", Color::Rgb(0xF1, 0xE0, 0x5A)),
        "jsx" => ("\u{E625}", Color::Rgb(0x20, 0xC2, 0xE3)),
        "rs" => ("\u{E68B}", Color::Rgb(0xDE, 0xA5, 0x84)),
        "cs" => ("\u{F031B}", Color::Rgb(0x59, 0x67, 0x06)),
        "csproj" => ("\u{F0AAE}", Color::Rgb(0x51, 0x2B, 0xD4)),
        "sln" => ("\u{E70C}", Color::Rgb(0x85, 0x4C, 0xC7)),
        "cshtml" => ("\u{F1997}", Color::Rgb(0x51, 0x2B, 0xD4)),
        "razor" => ("\u{F1998}", Color::Rgb(0x51, 0x2B, 0xD4)),
        "fs" => ("\u{E7A7}", Color::Rgb(0x51, 0x9A, 0xBA)),
        "html" => ("\u{E736}", Color::Rgb(0xE4, 0x4D, 0x26)),
        "htm" => ("\u{E60E}", Color::Rgb(0xE3, 0x4C, 0x26)),
        "css" => ("\u{E6B8}", Color::Rgb(0x66, 0x33, 0x99)),
        "scss" | "sass" => ("\u{E603}", Color::Rgb(0xF5, 0x53, 0x85)),
        "less" => ("\u{E614}", Color::Rgb(0x56, 0x3D, 0x7C)),
        "vue" => ("\u{E6A0}", Color::Rgb(0x8D, 0xC1, 0x49)),
        "svelte" => ("\u{E697}", Color::Rgb(0xFF, 0x3E, 0x00)),
        "json" => ("\u{E60B}", Color::Rgb(0xCB, 0xCB, 0x41)),
        "yaml" | "yml" => ("\u{E8EB}", Color::Rgb(0xD7, 0x00, 0x00)),
        "toml" => ("\u{E6B2}", Color::Rgb(0x9C, 0x42, 0x21)),
        "xml" => ("\u{F05C0}", Color::Rgb(0xE3, 0x79, 0x33)),
        "csv" => ("\u{E64A}", Color::Rgb(0x89, 0xE0, 0x51)),
        "ini" | "conf" => ("\u{E615}", Color::Rgb(0x6D, 0x80, 0x86)),
        "py" => ("\u{E606}", Color::Rgb(0xFF, 0xBC, 0x03)),
        "go" => ("\u{E627}", Color::Rgb(0x00, 0xAD, 0xD8)),
        "rb" => ("\u{E791}", Color::Rgb(0x70, 0x15, 0x16)),
        "java" => ("\u{E738}", Color::Rgb(0xCC, 0x3E, 0x44)),
        "kt" => ("\u{E634}", Color::Rgb(0x7F, 0x52, 0xFF)),
        "swift" => ("\u{E755}", Color::Rgb(0xE3, 0x79, 0x33)),
        "c" => ("\u{E61E}", Color::Rgb(0x59, 0x9E, 0xFF)),
        "cpp" => ("\u{E61D}", Color::Rgb(0x51, 0x9A, 0xBA)),
        "h" | "hpp" => ("\u{F0FD}", Color::Rgb(0xA0, 0x74, 0xC4)),
        "php" => ("\u{E608}", Color::Rgb(0xA0, 0x74, 0xC4)),
        "lua" => ("\u{E620}", Color::Rgb(0x51, 0xA0, 0xCF)),
        "sql" => ("\u{E706}", Color::Rgb(0xDA, 0xD8, 0xD8)),
        "sh" => ("\u{E795}", Color::Rgb(0x4D, 0x5A, 0x5E)),
        "bash" => ("\u{E760}", Color::Rgb(0x89, 0xE0, 0x51)),
        "zsh" => ("\u{E795}", Color::Rgb(0x89, 0xE0, 0x51)),
        "ps1" => ("\u{F0A0A}", Color::Rgb(0x42, 0x73, 0xCA)),
        "md" => ("\u{F48A}", Color::Rgb(0xDD, 0xDD, 0xDD)),
        "txt" => ("\u{F0219}", Color::Rgb(0x89, 0xE0, 0x51)),
        "lock" => ("\u{E672}", Color::Rgb(0xBB, 0xBB, 0xBB)),
        "log" => ("\u{F0331}", Color::Rgb(0xDD, 0xDD, 0xDD)),
        "exe" => ("\u{EAE8}", Color::Rgb(0x9F, 0x05, 0x00)),
        "dll" => ("\u{EB9C}", Color::Rgb(0x4D, 0x2C, 0x0B)),
        "http" | "curl" | "rest" | "request" => ("\u{F1D8}", Color::Rgb(0x00, 0x8E, 0xC7)),
        "svg" => ("\u{F0721}", Color::Rgb(0xFF, 0xB1, 0x3B)),
        "png" | "jpg" | "jpeg" | "gif" | "webp" => ("\u{E60D}", Color::Rgb(0xA0, 0x74, 0xC4)),
        "zip" | "gz" | "tgz" => ("\u{F410}", Color::Rgb(0xEC, 0xA5, 0x17)),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn known_extensions_resolve() {
        assert_eq!(for_path(&PathBuf::from("app.ts"), false, false, true).0, "\u{E628}");
        assert_eq!(for_path(&PathBuf::from("lib.rs"), false, false, true).0, "\u{E68B}");
    }
    #[test]
    fn filename_beats_extension() {
        let pkg = for_path(&PathBuf::from("package.json"), false, false, true);
        assert_eq!(pkg.0, "\u{E71E}");
    }
    #[test]
    fn unknown_falls_back() {
        assert_eq!(for_path(&PathBuf::from("weird.xyz"), false, false, true), DEFAULT_FILE);
    }
    #[test]
    fn ascii_mode() {
        assert_eq!(for_path(&PathBuf::from("app.ts"), false, false, false), DEFAULT_FILE_ASCII);
        assert_eq!(for_path(&PathBuf::from("src"), true, false, false), FOLDER_CLOSED_ASCII);
    }
}
