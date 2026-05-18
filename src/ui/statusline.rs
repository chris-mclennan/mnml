//! The bottom statusline — NvChad-style powerline segments. The mode chip is the
//! only place that reads `EditingMode` (it shows the editing mode if there is
//! one, else a context label — `TREE` / `VIEW` / `EDIT`).
//!
//! Left:  `[mode] [git branch +N] [<icon> file ●]`
//! Right: `[Ln:Col] [<folder> workspace] [language]`
//! The gap holds a centered toast / pending-key hint.
//!
//! TODO: when the git track lands, flesh the left side out — split git changes
//! into `+N ~N -N`, add a sync/ahead-behind indicator, a GitHub/PR badge, etc.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::focus::Focus;
use crate::input::EditingMode;
use crate::ui::{icons, theme};

const PL_RIGHT: &str = "\u{e0b0}"; //
const PL_LEFT: &str = "\u{e0b2}"; //

/// Local-timezone offset from UTC in seconds. Cached on first call —
/// resolved via `$TZ_OFFSET_HOURS` (testing / containers), then by
/// shelling out to `date +%z` (parses `±HHMM`), with UTC as the
/// fallback when both fail. Stable per-process: a launch through a DST
/// boundary won't catch the shift, but mnml restarts are common
/// enough that this is a non-issue in practice.
fn local_tz_offset_secs() -> i64 {
    use std::sync::OnceLock;
    static CACHE: OnceLock<i64> = OnceLock::new();
    *CACHE.get_or_init(|| {
        if let Ok(s) = std::env::var("TZ_OFFSET_HOURS")
            && let Ok(h) = s.parse::<i32>()
        {
            return h as i64 * 3600;
        }
        let Ok(out) = std::process::Command::new("date").arg("+%z").output() else {
            return 0;
        };
        let s = String::from_utf8_lossy(&out.stdout);
        let s = s.trim();
        // Expect `±HHMM`
        if s.len() != 5 {
            return 0;
        }
        let sign: i64 = if s.starts_with('-') { -1 } else { 1 };
        let Ok(hh) = s[1..3].parse::<i64>() else {
            return 0;
        };
        let Ok(mm) = s[3..5].parse::<i64>() else {
            return 0;
        };
        sign * (hh * 3600 + mm * 60)
    })
}

struct Seg {
    text: String,
    fg: Color,
    bg: Color,
    bold: bool,
}

impl Seg {
    fn new(text: impl Into<String>, fg: Color, bg: Color) -> Self {
        Seg {
            text: text.into(),
            fg,
            bg,
            bold: false,
        }
    }
    fn bold(mut self) -> Self {
        self.bold = true;
        self
    }
    fn style(&self) -> Style {
        let s = Style::default().fg(self.fg).bg(self.bg);
        if self.bold {
            s.add_modifier(Modifier::BOLD)
        } else {
            s
        }
    }
    fn cols(&self) -> usize {
        self.text.chars().count()
    }
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().statusline)),
        area,
    );
    if area.width == 0 {
        return;
    }
    let width = area.width as usize;
    let arrows = !app.config.ui.ascii_icons;
    let nerd = !app.config.ui.ascii_icons;

    // ── left ──
    let (mode_label, mode_bg) = mode_chip(app);
    // Prefix the vim-mode chips with the `nf-custom-vim` glyph (`\u{e7c5}`,
    // the diamond-V logo) when nerd fonts are on — matches NvChad's
    // st_modes styling. EDIT/VIEW/TREE chips stay icon-less (standard
    // input mode / file-rail focus aren't "vim").
    let is_vim_mode = matches!(
        app.editing_mode(),
        EditingMode::Insert | EditingMode::Replace | EditingMode::Visual | EditingMode::Normal
    );
    let mode_seg_text = if nerd && is_vim_mode {
        format!(" \u{e7c5} {mode_label} ")
    } else {
        format!(" {mode_label} ")
    };
    let mut left = vec![Seg::new(mode_seg_text, theme::cur().bg_darker, mode_bg).bold()];
    {
        let g = app.git.snapshot();
        if let Some(branch) = &g.branch {
            let mut txt = format!("  {branch}");
            if g.ahead > 0 {
                txt.push_str(&format!("  ⇡{}", g.ahead));
            }
            if g.behind > 0 {
                txt.push_str(&format!(" ⇣{}", g.behind));
            }
            if g.staged > 0 {
                txt.push_str(&format!("  ✚{}", g.staged));
            }
            if g.modified > 0 {
                txt.push_str(&format!("  ●{}", g.modified));
            }
            if g.untracked > 0 {
                txt.push_str(&format!("  …{}", g.untracked));
            }
            if g.conflicts > 0 {
                txt.push_str(&format!("  ⚠{}", g.conflicts));
            }
            txt.push(' ');
            left.push(Seg::new(txt, theme::cur().green, theme::cur().bg2));
        }
    }
    // file segment: icon (its devicon color) + name + dirty marker, both on STATUSLINE bg.
    match app.active_editor() {
        Some(b) => {
            let p = b.path.clone().unwrap_or_else(|| b.display_name().into());
            let (glyph, gc) = icons::for_path(&p, false, false, nerd);
            left.push(Seg::new(format!(" {glyph} "), gc, theme::cur().statusline));
            let name = format!("{}{} ", b.display_name(), if b.dirty { " ●" } else { "" });
            left.push(Seg::new(name, theme::cur().fg, theme::cur().statusline));
            // LSP + linter diagnostics count (errors then warnings), if any.
            let (errs, warns) =
                b.all_diagnostics()
                    .fold((0u32, 0u32), |(e, w), d| match d.severity {
                        crate::lsp::Severity::Error => (e + 1, w),
                        crate::lsp::Severity::Warning => (e, w + 1),
                        _ => (e, w),
                    });
            if errs > 0 {
                left.push(Seg::new(
                    format!("  {errs} "),
                    theme::cur().red,
                    theme::cur().statusline,
                ));
            }
            if warns > 0 {
                left.push(Seg::new(
                    format!(" ⚠ {warns} "),
                    theme::cur().yellow,
                    theme::cur().statusline,
                ));
            }
            // Current symbol chip — the closest enclosing fn / struct /
            // class name for the cursor. Uses regex_outline (cheap per
            // render for typical files). Only paints when the buffer has
            // a recognized language and at least one symbol.
            if let Some(ext) = b.language_ext.as_deref() {
                let symbols = crate::regex_outline::extract_symbols(b.editor.text(), ext);
                let row = b.editor.row_col().0 as u32;
                if let Some(s) = symbols.iter().rev().find(|s| s.line <= row) {
                    let label: String = s.name.chars().take(40).collect();
                    left.push(Seg::new(
                        format!(" › {label} "),
                        theme::cur().purple,
                        theme::cur().statusline,
                    ));
                }
            }
            // Macro recording indicator — vim shows "recording @<reg>" along
            // the bottom row when `q<reg>` is active. We chip it onto the
            // statusline left side so it's visible across all panes.
            if let crate::app::MacroState::Recording { register, .. } = &app.macro_state {
                left.push(Seg::new(
                    format!(" ● rec @{register} "),
                    theme::cur().bg_darker,
                    theme::cur().red,
                ));
            }
            // Active find: ` " quoted query "  N/M ` so the user knows what's
            // matched without re-opening the prompt.
            if let Some(f) = b.find.as_ref()
                && !f.matches.is_empty()
            {
                let cur = f.current.map(|i| i + 1).unwrap_or(0);
                let m = f.matches.len();
                // Truncate long queries so the chip stays readable.
                let q: String = f.query.chars().take(24).collect();
                let ellip = if f.query.chars().count() > 24 {
                    "…"
                } else {
                    ""
                };
                left.push(Seg::new(
                    format!(" /{q}{ellip} {cur}/{m} "),
                    theme::cur().bg_darker,
                    theme::cur().yellow,
                ));
            }
        }
        None => left.push(Seg::new(
            " [no file] ",
            theme::cur().comment,
            theme::cur().statusline,
        )),
    }

    // ── right ──
    let mut right: Vec<Seg> = Vec::new();
    // LSP indicator — `LSP {N}` chip when there's at least one running
    // language server in the workspace. Tells the user at a glance that
    // LSP features are available; `:LspStatus` for the breakdown.
    let lsp_n = app.lsp.server_count();
    if lsp_n > 0 {
        right.push(Seg::new(
            format!(" LSP {lsp_n} "),
            theme::cur().bg_darker,
            theme::cur().blue,
        ));
    }
    // `$/progress` busy chip — shows when a long-running LSP task is
    // active (rust-analyzer indexing, etc.). Pick any one title; the
    // ordering is arbitrary but stable per-render.
    if let Some(title) = app.lsp_progress.values().next()
        && !title.is_empty()
    {
        let label: String = title.chars().take(28).collect();
        right.push(Seg::new(
            format!(" ⟳ {label} "),
            theme::cur().bg_darker,
            theme::cur().cyan,
        ));
    }
    // `WRAP` chip when `[ui] wrap` is on. Easy to forget the mode is
    // active when the file's lines aren't actually long; this gives a
    // quiet visible confirmation.
    if app.config.ui.wrap {
        right.push(Seg::new(
            " WRAP ".to_string(),
            theme::cur().bg_darker,
            theme::cur().purple,
        ));
    }
    // (Tab-page indicators live in the bufferline's right cluster — see
    // `src/ui/bufferline.rs`. No statusline chip needed.)
    // Autosave indicator — `[AS Ns]` chip when `[editor] autosave_secs > 0`.
    // Lets the user see at a glance that idle saves are armed.
    let autosave = app.config.editor.autosave_secs;
    if autosave > 0 {
        right.push(Seg::new(
            format!(" AS {autosave}s "),
            theme::cur().bg_darker,
            theme::cur().green,
        ));
    }
    if let Some(b) = app.active_editor() {
        let (row, col) = b.editor.row_col();
        // Filesize chip — buffer's *in-memory* byte count (so unsaved edits
        // are reflected). Compact: `<1KB` shows raw bytes, otherwise KB / MB.
        let bytes = b.editor.text().len();
        let size_label = format_byte_size(bytes);
        right.push(Seg::new(
            format!(" {size_label} "),
            theme::cur().comment,
            theme::cur().bg2,
        ));
        // `Ln 12/580` (current of total) — the "/580" lets the user gauge
        // where they are in the file without scanning the scroll bar.
        right.push(Seg::new(
            format!(" Ln {}/{} Col {} ", row + 1, b.editor.line_count(), col + 1,),
            theme::cur().fg,
            theme::cur().bg2,
        ));
        // Selection size chip — only when there's an active selection. Shows
        // the number of selected *characters* (multi-line selections include
        // their newlines).
        if b.editor.has_selection() {
            let n = b.editor.selected_text().chars().count();
            right.push(Seg::new(
                format!(" Sel {n} "),
                theme::cur().bg_darker,
                theme::cur().yellow,
            ));
        }
    }
    // Optional clock chip (HH:MM, local time). On by default — costs
    // ~0 (a single SystemTime call per render + one cached offset lookup).
    // `[ui] clock = false` to turn off. `TZ_OFFSET_HOURS` env var still
    // overrides the system offset for testing / containers.
    if app.config.ui.clock {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let off_secs = local_tz_offset_secs();
        let local = (now as i64 + off_secs).rem_euclid(86400) as u64;
        let hh = (local / 3600) % 24;
        let mm = (local / 60) % 60;
        right.push(Seg::new(
            format!(" {hh:02}:{mm:02} "),
            theme::cur().comment,
            theme::cur().bg2,
        ));
    }
    // workspace / cwd block (the name that used to sit atop the file tree).
    let ws_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace");
    let folder_glyph = if nerd { "\u{f07b}" } else { "" };
    right.push(
        Seg::new(
            format!(" {folder_glyph} {ws_name} "),
            theme::cur().blue,
            theme::cur().bg3,
        )
        .bold(),
    );
    // language block.
    let lang = app
        .active_editor()
        .and_then(|b| b.language_ext.clone())
        .unwrap_or_else(|| "—".to_string());
    right.push(
        Seg::new(
            format!("  {lang} "),
            theme::cur().bg_darker,
            theme::cur().blue,
        )
        .bold(),
    );
    // (The build-version chip lived here previously — it was useful during
    // active development but felt cluttered. Surfaced via `:version` now;
    // a future settings/about pane will own the long-form display.)

    // ── render: left segments + spacer + right segments, with `` / `` transitions ──
    let (mut spans, used) = render_left(&left, arrows, theme::cur().statusline);
    let (right_spans, right_used) = render_right(&right, arrows, theme::cur().statusline);

    // middle: chord-pending hint, centered in the leftover space. The vim `:`
    // cmdline and live toast now own the cmdline-bar row below the statusline,
    // so we only paint the *non-cmdline* part of `pending_display()` here
    // (`d`, `gqap`, `cw`, …) — the chord shorthand the user is mid-typing.
    let mid_avail = width.saturating_sub(used + right_used);
    let pending = app.pending_display();
    let is_pending = pending
        .as_deref()
        .map(|s| !s.starts_with(':'))
        .unwrap_or(false);
    let middle = if is_pending {
        pending.unwrap_or_default()
    } else {
        String::new()
    };
    let mid_text: String = {
        let m = if middle.is_empty() {
            String::new()
        } else {
            format!(" {middle} ")
        };
        let mc = m.chars().count();
        if mc >= mid_avail {
            m.chars().take(mid_avail).collect()
        } else {
            let total = mid_avail - mc;
            let lp = total / 2;
            format!("{}{}{}", " ".repeat(lp), m, " ".repeat(total - lp))
        }
    };
    let mid_style = if is_pending {
        Style::default()
            .fg(theme::cur().yellow)
            .bg(theme::cur().statusline)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default()
            .fg(theme::cur().comment)
            .bg(theme::cur().statusline)
    };
    spans.push(Span::styled(mid_text, mid_style));
    spans.extend(right_spans);

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Left-anchored segments; a `` after each (its fg = this bg, bg = next bg),
/// skipped between two same-bg neighbors so a multi-span segment looks unified.
fn render_left(segs: &[Seg], arrows: bool, tail_bg: Color) -> (Vec<Span<'static>>, usize) {
    let mut out = Vec::new();
    let mut used = 0;
    for (i, s) in segs.iter().enumerate() {
        out.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
        let next_bg = segs.get(i + 1).map(|n| n.bg).unwrap_or(tail_bg);
        if arrows && next_bg != s.bg {
            out.push(Span::styled(
                PL_RIGHT,
                Style::default().fg(s.bg).bg(next_bg),
            ));
            used += 1;
        }
    }
    (out, used)
}

/// Right-anchored segments; a `` before each (its fg = this bg, bg = prev bg),
/// skipped between two same-bg neighbors.
fn render_right(segs: &[Seg], arrows: bool, head_bg: Color) -> (Vec<Span<'static>>, usize) {
    let mut out = Vec::new();
    let mut used = 0;
    for (i, s) in segs.iter().enumerate() {
        let prev_bg = if i == 0 { head_bg } else { segs[i - 1].bg };
        if arrows && prev_bg != s.bg {
            out.push(Span::styled(PL_LEFT, Style::default().fg(s.bg).bg(prev_bg)));
            used += 1;
        }
        out.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
    }
    (out, used)
}

/// `(label, bg_color)` for the mode chip.
fn mode_chip(app: &App) -> (&'static str, Color) {
    match app.editing_mode() {
        EditingMode::Insert => ("INSERT", theme::cur().green),
        EditingMode::Replace => ("REPLACE", theme::cur().orange),
        EditingMode::Visual => ("VISUAL", theme::cur().purple),
        EditingMode::Normal => ("NORMAL", theme::cur().red),
        EditingMode::None => match app.focus {
            Focus::Tree => ("TREE", theme::cur().blue),
            Focus::Pane => {
                if app.active_editor().map(|b| b.read_only).unwrap_or(true) {
                    ("VIEW", theme::cur().cyan)
                } else {
                    ("EDIT", theme::cur().green)
                }
            }
        },
    }
}

/// Render `bytes` as a compact size label: `123B`, `4.2K`, `12M`. Tuned for
/// the statusline chip — single token, no fractional digits past 1 decimal.
fn format_byte_size(bytes: usize) -> String {
    if bytes < 1024 {
        format!("{bytes}B")
    } else if bytes < 1024 * 1024 {
        let kb = bytes as f64 / 1024.0;
        if kb < 10.0 {
            format!("{kb:.1}K")
        } else {
            format!("{}K", kb as usize)
        }
    } else {
        let mb = bytes as f64 / (1024.0 * 1024.0);
        if mb < 10.0 {
            format!("{mb:.1}M")
        } else {
            format!("{}M", mb as usize)
        }
    }
}
