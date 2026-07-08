//! External markdown-preview renderer — pipes the source through
//! `glow` (or a user-configured command) and paints the ANSI output.
//!
//! The builtin renderer (`ui::md_preview`) is mnml's default: fast,
//! image-aware, cursor-tracking. This module is an opt-in "richer
//! looks, fewer features" path for users who want glow's typography.
//!
//! Config: `[ui] md_preview_engine = "glow" | "custom:<cmd>"`.
//! Selected via `App::config.ui.md_preview_engine`. Falls back to
//! the builtin renderer on any failure — spawn miss, non-zero exit,
//! empty output — with a one-shot toast so the user knows why.
//!
//! Caching: results are keyed by `(engine, width, source_hash)` so
//! typing in the source pane re-renders on change but a stable
//! preview doesn't re-fork glow every frame.

use std::hash::{Hash, Hasher};
use std::io::Write;
use std::process::{Command, Stdio};

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

/// Cached render — `(engine, width, source_hash) → styled lines`.
/// Held on `MdPreview` so scrolling and mouse motion don't trigger
/// re-renders.
#[derive(Debug, Default, Clone)]
pub struct ExternalCache {
    /// A cheap hash of the source text — see [`Self::key`]. `0`
    /// means "empty" / uninitialized so the first render always
    /// misses.
    pub key: (String, u16, u64),
    pub lines: Vec<Line<'static>>,
}

impl ExternalCache {
    pub fn is_fresh(&self, engine: &str, width: u16, source: &str) -> bool {
        self.key == (engine.to_string(), width, hash_source(source))
    }
}

fn hash_source(s: &str) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

/// Attempt to render `source` via the configured external engine.
/// `engine` is `"glow"` or `"custom:<cmd>"`. Returns styled Lines
/// (one per output row) on success, or a short error string suitable
/// for a toast.
pub fn render(engine: &str, width: u16, source: &str) -> Result<Vec<Line<'static>>, String> {
    let (program, args, is_shell) = resolve_command(engine, width)?;
    // Spawn, pipe source in on stdin, collect stdout.
    let mut child = if is_shell {
        Command::new("sh")
            .arg("-c")
            .arg(&program)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
    } else {
        Command::new(&program)
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
    }
    .map_err(|e| format!("md-preview external '{program}': {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(source.as_bytes());
    }
    let output = child
        .wait_with_output()
        .map_err(|e| format!("md-preview external wait: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let head = stderr
            .lines()
            .next()
            .map(|l| l.trim())
            .unwrap_or("nonzero exit");
        return Err(format!("md-preview external '{program}': {head}"));
    }
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    if stdout.trim().is_empty() {
        return Err(format!("md-preview external '{program}': empty output"));
    }
    Ok(parse_ansi_lines(&stdout))
}

fn resolve_command(engine: &str, width: u16) -> Result<(String, Vec<String>, bool), String> {
    if engine == "glow" {
        // `-s auto` picks a style matching the terminal's dark/light
        // bias. `-w` clamps the wrap width so glow doesn't over-run
        // the pane.
        Ok((
            "glow".to_string(),
            vec!["-s".into(), "auto".into(), "-w".into(), width.to_string()],
            false,
        ))
    } else if let Some(cmd) = engine.strip_prefix("custom:") {
        let cmd = cmd.trim();
        if cmd.is_empty() {
            return Err("md_preview_engine=custom: requires a command".into());
        }
        // Custom command runs via `sh -c` so pipes / args are honored
        // as the user typed them. Width is exposed via $MNML_WIDTH.
        let full = format!("MNML_WIDTH={width} {cmd}");
        Ok((full, Vec::new(), true))
    } else {
        Err(format!(
            "md_preview_engine='{engine}' — unknown (expected \"glow\" or \"custom:<cmd>\")"
        ))
    }
}

// ── ANSI SGR parser ─────────────────────────────────────────────────
//
// Parses `\x1b[<params>m` sequences and produces styled Spans. Enough
// SGR coverage for glow: reset, bold, dim, italic, underline, standard
// 8+bright colors, 256-palette (38;5;n), 24-bit RGB (38;2;r;g;b), fg
// and bg. Other CSI is dropped. `\x1b[K` (erase-in-line) is dropped too.
//
// Each output line is a ratatui `Line` of `Span<'static>`; call sites
// scroll and paint the same way as the builtin renderer.

fn parse_ansi_lines(s: &str) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut cur_spans: Vec<Span<'static>> = Vec::new();
    let mut cur_style = Style::default();
    let mut buf = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\n' {
            flush(&mut cur_spans, &mut buf, cur_style);
            lines.push(Line::from(std::mem::take(&mut cur_spans)));
            continue;
        }
        if c == '\r' {
            continue;
        }
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                let mut params = String::new();
                let mut final_byte = None;
                for n in chars.by_ref() {
                    if n.is_ascii_alphabetic() || n == '~' {
                        final_byte = Some(n);
                        break;
                    }
                    params.push(n);
                }
                if final_byte == Some('m') {
                    flush(&mut cur_spans, &mut buf, cur_style);
                    cur_style = apply_sgr(cur_style, &params);
                }
                // Any other CSI (K, H, etc.) is silently dropped.
            }
            continue;
        }
        buf.push(c);
    }
    flush(&mut cur_spans, &mut buf, cur_style);
    if !cur_spans.is_empty() {
        lines.push(Line::from(cur_spans));
    }
    lines
}

fn flush(spans: &mut Vec<Span<'static>>, buf: &mut String, style: Style) {
    if !buf.is_empty() {
        spans.push(Span::styled(std::mem::take(buf), style));
    }
}

fn apply_sgr(mut style: Style, params: &str) -> Style {
    let codes: Vec<i32> = params
        .split(';')
        .filter_map(|p| p.parse::<i32>().ok())
        .collect();
    if codes.is_empty() {
        return Style::default();
    }
    let mut i = 0;
    while i < codes.len() {
        let code = codes[i];
        match code {
            0 => style = Style::default(),
            1 => style = style.add_modifier(Modifier::BOLD),
            2 => style = style.add_modifier(Modifier::DIM),
            3 => style = style.add_modifier(Modifier::ITALIC),
            4 => style = style.add_modifier(Modifier::UNDERLINED),
            7 => style = style.add_modifier(Modifier::REVERSED),
            22 => style = style.remove_modifier(Modifier::BOLD | Modifier::DIM),
            23 => style = style.remove_modifier(Modifier::ITALIC),
            24 => style = style.remove_modifier(Modifier::UNDERLINED),
            27 => style = style.remove_modifier(Modifier::REVERSED),
            30..=37 => style = style.fg(basic_color(code - 30, false)),
            38 => {
                if let Some(color) = parse_extended(&codes, &mut i) {
                    style = style.fg(color);
                }
            }
            39 => style = style.fg(Color::Reset),
            40..=47 => style = style.bg(basic_color(code - 40, false)),
            48 => {
                if let Some(color) = parse_extended(&codes, &mut i) {
                    style = style.bg(color);
                }
            }
            49 => style = style.bg(Color::Reset),
            90..=97 => style = style.fg(basic_color(code - 90, true)),
            100..=107 => style = style.bg(basic_color(code - 100, true)),
            _ => {}
        }
        i += 1;
    }
    style
}

fn basic_color(idx: i32, bright: bool) -> Color {
    match (idx, bright) {
        (0, false) => Color::Black,
        (1, false) => Color::Red,
        (2, false) => Color::Green,
        (3, false) => Color::Yellow,
        (4, false) => Color::Blue,
        (5, false) => Color::Magenta,
        (6, false) => Color::Cyan,
        (7, false) => Color::Gray,
        (0, true) => Color::DarkGray,
        (1, true) => Color::LightRed,
        (2, true) => Color::LightGreen,
        (3, true) => Color::LightYellow,
        (4, true) => Color::LightBlue,
        (5, true) => Color::LightMagenta,
        (6, true) => Color::LightCyan,
        (7, true) => Color::White,
        _ => Color::Reset,
    }
}

/// Called when the previous SGR code was 38 or 48 — pulls the
/// extended-color spec off `codes` starting at `i+1` and advances
/// `i` past its params. Returns the parsed color or `None` if
/// malformed.
fn parse_extended(codes: &[i32], i: &mut usize) -> Option<Color> {
    let next = *codes.get(*i + 1)?;
    if next == 5 {
        // 256-palette: 38;5;n.
        let n = *codes.get(*i + 2)?;
        *i += 2;
        Some(palette_color(n))
    } else if next == 2 {
        // 24-bit: 38;2;r;g;b.
        let r = *codes.get(*i + 2)? as u8;
        let g = *codes.get(*i + 3)? as u8;
        let b = *codes.get(*i + 4)? as u8;
        *i += 4;
        Some(Color::Rgb(r, g, b))
    } else {
        None
    }
}

fn palette_color(n: i32) -> Color {
    if !(0..=255).contains(&n) {
        return Color::Reset;
    }
    match n {
        0..=7 => basic_color(n, false),
        8..=15 => basic_color(n - 8, true),
        16..=231 => {
            // 6x6x6 color cube.
            let n = n - 16;
            let r = ((n / 36) % 6) as u8;
            let g = ((n / 6) % 6) as u8;
            let b = (n % 6) as u8;
            let scale = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
            Color::Rgb(scale(r), scale(g), scale(b))
        }
        232..=255 => {
            // Grayscale ramp.
            let level = 8 + (n - 232) as u8 * 10;
            Color::Rgb(level, level, level)
        }
        _ => Color::Reset,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_lines() {
        let lines = parse_ansi_lines("hello\nworld\n");
        assert_eq!(lines.len(), 2);
    }

    #[test]
    fn parses_sgr_bold_red() {
        let lines = parse_ansi_lines("\x1b[1;31mERR\x1b[0m ok\n");
        assert_eq!(lines.len(), 1);
        let spans = lines[0].spans.clone();
        assert!(spans.iter().any(|s| s.content == "ERR"));
        assert!(spans.iter().any(|s| s.content == " ok"));
    }

    #[test]
    fn drops_unknown_csi() {
        let lines = parse_ansi_lines("\x1b[2Kbye\n");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].spans[0].content, "bye");
    }

    #[test]
    fn parses_24bit_rgb() {
        let style = apply_sgr(Style::default(), "38;2;10;20;30");
        assert_eq!(style.fg, Some(Color::Rgb(10, 20, 30)));
    }

    #[test]
    fn palette_ramp_maps_to_rgb() {
        // 256-palette index 16 = cube (0,0,0) = black.
        assert_eq!(palette_color(16), Color::Rgb(0, 0, 0));
        // Grayscale ramp starts at 232.
        assert_eq!(palette_color(232), Color::Rgb(8, 8, 8));
    }
}
