//! The bottom statusline — NvChad-style powerline segments. The mode chip is the
//! only place that reads `EditingMode` (it shows the editing mode if there is
//! one, else a context label — `TREE` / `VIEW` / `EDIT`).
//!
//! Left:  `[mode] [git branch +N] [<icon> file ●]`
//! Right: `[Ln:Col] [<folder> workspace] [language]`
//! The gap holds a centered toast / pending-key hint.
//!
//! Git chip carries branch + provider glyph + ahead/behind (`⇡N ⇣N`) +
//! per-file added / changed / removed (NvChad-style with nerd glyphs) +
//! conflicts (`⚠N`). The remaining unstarted bit is a PR badge — would
//! cross-reference the active branch against open PRs across the four
//! SCM hosts (`bitbucket_pull_requests` / `github_pull_requests` / etc.).

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

/// Shorten `s` so its char count is at most `target_cols`. Appends
/// `…` as a marker that truncation happened. Tries to preserve the
/// leading single-space padding many segs have (better visual fit).
fn ellipsize(s: &str, target_cols: usize) -> String {
    let cur = s.chars().count();
    if cur <= target_cols {
        return s.to_string();
    }
    // Reserve 1 char for the trailing `…`.
    let take = target_cols.saturating_sub(1);
    let mut out: String = s.chars().take(take).collect();
    out.push('…');
    out
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
        EditingMode::Insert
            | EditingMode::Replace
            | EditingMode::Visual
            | EditingMode::VisualLine
            | EditingMode::VisualBlock
            | EditingMode::Normal
    );
    let mut left: Vec<Seg> = Vec::new();
    // Index of the git-branch chip in `left` once pushed — used after
    // render_left to register a clickable rect that fires `git.graph`.
    let mut branch_seg_idx: Option<usize> = None;
    app.rects.statusline_branch_chip = None;
    app.rects.statusline_mode_chip = None;
    // Mode chip is the first 1 (ASCII / non-vim) or 2 (vim + nerd) segs in
    // `left`. Capture the seg span so we can register a click rect that
    // spans both halves of the split-mode chip.
    let mode_seg_start = left.len();
    if nerd && is_vim_mode {
        // Split the vim chip so the diamond-V glyph gets its own orange tint
        // (NvChad-style vim accent), then the label uses the mode's normal
        // dark-on-color contrast. Orange-on-orange (REPLACE mode) would
        // disappear, so fall back to bg_darker there.
        let glyph_fg = if mode_bg == theme::cur().orange {
            theme::cur().bg_darker
        } else {
            theme::cur().orange
        };
        left.push(Seg::new(" \u{e7c5} ".to_string(), glyph_fg, mode_bg).bold());
        left.push(Seg::new(format!("{mode_label} "), theme::cur().bg_darker, mode_bg).bold());
    } else {
        left.push(Seg::new(format!(" {mode_label} "), theme::cur().bg_darker, mode_bg).bold());
    }
    let mode_seg_end = left.len(); // exclusive
    {
        let g = app.git.snapshot();
        if let Some(branch) = &g.branch {
            // Provider icon (GitHub /GitLab / Bitbucket / Azure / generic
            // git fallback) when nerd fonts are on. Falls back to nf-fa-
            // code-fork () for non-recognized remotes or no remote.
            let provider = if nerd {
                g.provider_icon.unwrap_or("\u{F126}")
            } else {
                ""
            };
            let mut txt = if provider.is_empty() {
                format!(" {branch}")
            } else {
                format!(" {provider} {branch}")
            };
            if g.ahead > 0 {
                txt.push_str(&format!("  ⇡{}", g.ahead));
            }
            if g.behind > 0 {
                txt.push_str(&format!(" ⇣{}", g.behind));
            }
            // NvChad-style file counts: + (added) ● (changed) - (removed),
            // followed by ⚠ conflicts. Collapses the staged/unstaged
            // distinction into "what's the net change" — matches gitsigns.
            if g.added > 0 {
                txt.push_str(&format!("  \u{F0419} {}", g.added)); //   added
            }
            if g.changed > 0 {
                txt.push_str(&format!("  \u{F06D5} {}", g.changed)); //   changed
            }
            if g.removed > 0 {
                txt.push_str(&format!("  \u{F0374} {}", g.removed)); //   removed
            }
            if g.conflicts > 0 {
                txt.push_str(&format!("  ⚠{}", g.conflicts));
            }
            txt.push(' ');
            branch_seg_idx = Some(left.len());
            left.push(Seg::new(txt, theme::cur().green, theme::cur().bg2));
        }
    }
    // PR badge: when the current branch has an open PR/MR across any of
    // the four configured SCM hosts, show `BB#123` / `GH#42` / `GL!7` /
    // `AZ#9` so the user can see at a glance "yes, there's a PR on this".
    // Read from `app.git_rail.pulls` which the SCM workers populate +
    // `App::refresh_rail_pulls` keeps in sync. Picks the *first* current-
    // branch PR (sorted to front by refresh_rail_pulls), since most repos
    // have at most one PR per branch.
    if let Some(pr) = app.git_rail.pulls.iter().find(|p| p.is_current_branch) {
        let chip = format!("  {}{} ", pr.host_tag, pr.number_label);
        left.push(Seg::new(chip, theme::cur().purple, theme::cur().bg2));
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
    // Now-playing chip — pushed first so it's the leftmost segment of
    // the right cluster (closer to centre). Doubles as the mixr launch
    // button: shows the track from whatever player the background
    // poller found (mixr / macOS Music / Spotify), `♪ mixr` when idle.
    // Click → `mixr.show`. Data is `App.now_playing`.
    // When mixr is the now-playing source the chip's leading glyph
    // swaps from `♪` to ⏸ (playing) or ▶ (track loaded but paused),
    // so the chip doubles as a play/pause transport. A satellite
    // ⏭ chip pushes adjacent while playing — click sends teleport.
    // Non-mixr sources (Apple Music / Spotify) keep the `♪` glyph
    // since mnml can't transport-control those; the chip stays a
    // pure now-playing indicator + launch button.
    // Nerd-font codepoints (same as tmnl's chrome-side satellite at
    // `gpu_launcher_paint::MIXR_*_GLYPH`) — chosen over the basic
    // Unicode ⏸/▶/⏭ because those don't render reliably across
    // mnml's font-fallback chain (user-reported 2026-06-17: the
    // chip looked like it had no leading glyph).
    const NF_PLAY: char = '\u{f04b}'; // nf-fa-play
    const NF_PAUSE: char = '\u{f04c}'; // nf-fa-pause
    const NF_TELEPORT: char = '\u{f051}'; // nf-fa-step-forward
    let mixr_is_source = app
        .now_playing
        .as_ref()
        .map(|np| np.source.eq_ignore_ascii_case("mixr"))
        .unwrap_or(false);
    let (mixr_glyph, render_satellite) = match (&app.now_playing, mixr_is_source) {
        (Some(np), true) if np.playing => (NF_PAUSE, true),
        (Some(np), true) if !np.track.is_empty() => (NF_PLAY, false),
        _ => ('♪', false),
    };
    let mixr_seg_idx = {
        let (label, fg) = match &app.now_playing {
            Some(np) if np.playing => {
                // Sanitise first — collapse control chars / whitespace
                // runs (a stray tab in a title was splitting the chip)
                // — then truncate hard so a long title can't crowd the
                // right lane.
                let clean = np.track.split_whitespace().collect::<Vec<_>>().join(" ");
                let shown: String = if clean.chars().count() > 18 {
                    clean.chars().take(17).chain(std::iter::once('…')).collect()
                } else {
                    clean
                };
                (format!(" {mixr_glyph} {shown} "), theme::cur().purple)
            }
            Some(np) if mixr_is_source && !np.track.is_empty() => {
                // Mixr loaded with a paused/cued track — show the
                // play glyph + track so the user knows what's
                // queued and that clicking will toggle playback.
                let clean = np.track.split_whitespace().collect::<Vec<_>>().join(" ");
                let shown: String = if clean.chars().count() > 18 {
                    clean.chars().take(17).chain(std::iter::once('…')).collect()
                } else {
                    clean
                };
                // Keep the chip in `purple` even when paused so the
                // play glyph stays visible against `bg2`. `comment`
                // is too close to the segment background and the
                // chip read as "no glyph at all" — user-reported.
                (format!(" {mixr_glyph} {shown} "), theme::cur().purple)
            }
            _ => (format!(" {mixr_glyph} mixr "), theme::cur().comment),
        };
        let idx = right.len();
        right.push(Seg::new(label, fg, theme::cur().bg2));
        idx
    };
    // Satellite teleport chip — only renders when mixr is the
    // source AND a deck is actively producing audio. Click sends
    // `mixr --command teleport`. Same semantic as tmnl's chrome-
    // side satellite (`gpu_launcher_paint::MIXR_TELEPORT_GLYPH`).
    let mixr_teleport_seg_idx = if render_satellite {
        let idx = right.len();
        right.push(Seg::new(
            format!(" {NF_TELEPORT} "),
            theme::cur().purple,
            theme::cur().bg2,
        ));
        Some(idx)
    } else {
        None
    };
    let mut clock_seg_idx: Option<usize> = None;
    let mut lsp_seg_idx: Option<usize> = None;
    let mut wrap_seg_idx: Option<usize> = None;
    let mut autosave_seg_idx: Option<usize> = None;
    let mut filesize_seg_idx: Option<usize> = None;
    let mut lncol_seg_idx: Option<usize> = None;
    app.rects.statusline_workspace_chip = None;
    app.rects.statusline_clock_chip = None;
    app.rects.statusline_mixr_chip = None;
    app.rects.statusline_mixr_teleport_chip = None;
    app.rects.statusline_lsp_chip = None;
    app.rects.statusline_wrap_chip = None;
    app.rects.statusline_autosave_chip = None;
    app.rects.statusline_filesize_chip = None;
    app.rects.statusline_lncol_chip = None;
    // LSP indicator — `LSP {N}` chip when there's at least one running
    // language server in the workspace. Tells the user at a glance that
    // LSP features are available; `:LspStatus` for the breakdown.
    let lsp_n = app.lsp.server_count();
    if lsp_n > 0 {
        lsp_seg_idx = Some(right.len());
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
    // `✦ AI` chip while an inline-suggestion request is in flight — the
    // ghost-text round-trip is ~0.5–1.5s, so this tells the user a
    // completion is coming (vs the editor just sitting idle).
    if app.ai_suggestion_in_flight() {
        right.push(Seg::new(
            " \u{F0E2D} AI ".to_string(),
            theme::cur().bg_darker,
            theme::cur().orange,
        ));
    }
    // `WRAP` chip when `[ui] wrap` is on. Easy to forget the mode is
    // active when the file's lines aren't actually long; this gives a
    // quiet visible confirmation.
    if app.config.ui.wrap {
        wrap_seg_idx = Some(right.len());
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
        autosave_seg_idx = Some(right.len());
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
        filesize_seg_idx = Some(right.len());
        right.push(Seg::new(
            format!(" {size_label} "),
            theme::cur().comment,
            theme::cur().bg2,
        ));
        // `Ln 12/580` (current of total) — the "/580" lets the user gauge
        // where they are in the file without scanning the scroll bar.
        lncol_seg_idx = Some(right.len());
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
        // UTC mode: zero offset + `Z` suffix (ISO convention) so the user
        // can tell the difference at a glance from the local-time chip.
        let off_secs = if app.clock_show_utc {
            0
        } else {
            local_tz_offset_secs()
        };
        let resolved = (now as i64 + off_secs).rem_euclid(86400) as u64;
        let hh = (resolved / 3600) % 24;
        let mm = (resolved / 60) % 60;
        let label = if app.clock_show_utc {
            format!(" {hh:02}:{mm:02}Z ")
        } else {
            format!(" {hh:02}:{mm:02} ")
        };
        clock_seg_idx = Some(right.len());
        right.push(Seg::new(label, theme::cur().comment, theme::cur().bg2));
    }
    // workspace / cwd block (the name that used to sit atop the file tree).
    // Multi-repo: show the *active repo* name (with workspace as detail when
    // the active repo isn't the workspace root) so clicking the chip to swap
    // repos has visible feedback after.
    let ws_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace");
    let label_text = if app.repos.len() > 1 {
        app.repos
            .get(app.active_repo)
            .map(|r| r.name.clone())
            .unwrap_or_else(|| ws_name.to_string())
    } else {
        ws_name.to_string()
    };
    let folder_glyph = if nerd { "\u{f07b}" } else { "" };
    let workspace_seg_idx: Option<usize> = Some(right.len());
    right.push(
        Seg::new(
            format!(" {folder_glyph} {label_text} "),
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
    // First measure the right lane so we know how much room left has;
    // then trim the longest left seg with `…` if left + right would
    // overflow. Without this, a long filename pushed every right-side
    // chip (mixr, line/col, clock, workspace, ext) off-screen — the
    // 2026-06-07 bug-hunt SEV-3 finding.
    let (_, projected_right_used, _) = render_right(&right, arrows, theme::cur().statusline);
    let projected_left_used: usize = left.iter().map(|s| s.cols()).sum();
    // Reserve at least 4 cells between left and right when they'd otherwise touch.
    let min_gap = 4_usize;
    let avail_for_left = width.saturating_sub(projected_right_used + min_gap);
    if projected_left_used > avail_for_left
        && let Some((longest_idx, _)) = left.iter().enumerate().max_by_key(|(_, s)| s.cols())
    {
        let overshoot = projected_left_used - avail_for_left;
        let cur_cols = left[longest_idx].cols();
        let target_cols = cur_cols.saturating_sub(overshoot).max(3);
        if target_cols < cur_cols {
            left[longest_idx].text = ellipsize(&left[longest_idx].text, target_cols);
        }
    }
    let (mut spans, used, left_rects) = render_left(&left, arrows, theme::cur().statusline);
    let (right_spans, right_used, right_rects) =
        render_right(&right, arrows, theme::cur().statusline);
    // Right-lane segs land at `area.x + area.width - right_used` (the lane's
    // leftmost cell). Translate per-seg starts within the lane.
    let right_lane_x = area.x + area.width.saturating_sub(right_used as u16);
    if let Some(idx) = workspace_seg_idx
        && let Some(&(start, w)) = right_rects.get(idx)
        && w > 0
    {
        app.rects.statusline_workspace_chip = Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }
    if let Some(idx) = clock_seg_idx
        && let Some(&(start, w)) = right_rects.get(idx)
        && w > 0
    {
        app.rects.statusline_clock_chip = Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }
    // Helper: translate an optional seg idx into a right-lane click rect.
    let to_rect = |idx_opt: Option<usize>, rects: &[(usize, usize)]| -> Option<Rect> {
        let idx = idx_opt?;
        let &(start, w) = rects.get(idx)?;
        if w == 0 {
            return None;
        }
        Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        })
    };
    app.rects.statusline_mixr_chip = to_rect(Some(mixr_seg_idx), &right_rects);
    app.rects.statusline_mixr_teleport_chip = to_rect(mixr_teleport_seg_idx, &right_rects);
    app.rects.statusline_lsp_chip = to_rect(lsp_seg_idx, &right_rects);
    app.rects.statusline_wrap_chip = to_rect(wrap_seg_idx, &right_rects);
    app.rects.statusline_autosave_chip = to_rect(autosave_seg_idx, &right_rects);
    app.rects.statusline_filesize_chip = to_rect(filesize_seg_idx, &right_rects);
    app.rects.statusline_lncol_chip = to_rect(lncol_seg_idx, &right_rects);

    // Register the git-branch chip's click rect for `git.graph` routing.
    // `left_rects[i] = (start_col_within_left_lane, width_in_cols)` — translate
    // to a screen-relative `Rect` by adding `area.x`.
    if let Some(idx) = branch_seg_idx
        && let Some(&(start, w)) = left_rects.get(idx)
        && w > 0
        && (start + w) as u16 <= area.width
    {
        app.rects.statusline_branch_chip = Some(Rect {
            x: area.x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }
    // Register the mode chip — combined rect spanning the 1 or 2 segs that
    // make it up (vim + nerd splits into glyph + label; otherwise single).
    if mode_seg_end > mode_seg_start
        && let Some(&(start, _)) = left_rects.get(mode_seg_start)
    {
        let last = mode_seg_end - 1;
        if let Some(&(end_start, end_w)) = left_rects.get(last) {
            let total_w = (end_start + end_w).saturating_sub(start);
            if total_w > 0 && (start + total_w) as u16 <= area.width {
                app.rects.statusline_mode_chip = Some(Rect {
                    x: area.x + start as u16,
                    y: area.y,
                    width: total_w as u16,
                    height: 1,
                });
            }
        }
    }

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
/// Also returns the (start_col, width) of each seg's TEXT (excluding the trailing
/// powerline arrow) so callers can register click rects.
fn render_left(
    segs: &[Seg],
    arrows: bool,
    tail_bg: Color,
) -> (Vec<Span<'static>>, usize, Vec<(usize, usize)>) {
    let mut out = Vec::new();
    let mut used = 0;
    let mut seg_rects: Vec<(usize, usize)> = Vec::with_capacity(segs.len());
    for (i, s) in segs.iter().enumerate() {
        let start = used;
        out.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
        seg_rects.push((start, s.cols()));
        let next_bg = segs.get(i + 1).map(|n| n.bg).unwrap_or(tail_bg);
        if arrows && next_bg != s.bg {
            out.push(Span::styled(
                PL_RIGHT,
                Style::default().fg(s.bg).bg(next_bg),
            ));
            used += 1;
        }
    }
    (out, used, seg_rects)
}

/// Right-anchored segments; a `` before each (its fg = this bg, bg = prev bg),
/// skipped between two same-bg neighbors. Also returns each seg's
/// `(start_col_within_right_lane, width)` so callers can register click rects.
fn render_right(
    segs: &[Seg],
    arrows: bool,
    head_bg: Color,
) -> (Vec<Span<'static>>, usize, Vec<(usize, usize)>) {
    let mut out = Vec::new();
    let mut used = 0;
    let mut seg_rects: Vec<(usize, usize)> = Vec::with_capacity(segs.len());
    for (i, s) in segs.iter().enumerate() {
        let prev_bg = if i == 0 { head_bg } else { segs[i - 1].bg };
        if arrows && prev_bg != s.bg {
            out.push(Span::styled(PL_LEFT, Style::default().fg(s.bg).bg(prev_bg)));
            used += 1;
        }
        let start = used;
        out.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
        seg_rects.push((start, s.cols()));
    }
    (out, used, seg_rects)
}

/// `(label, bg_color)` for the mode chip.
fn mode_chip(app: &App) -> (&'static str, Color) {
    match app.editing_mode() {
        EditingMode::Insert => ("INSERT", theme::cur().green),
        EditingMode::Replace => ("REPLACE", theme::cur().orange),
        EditingMode::Visual => ("VISUAL", theme::cur().purple),
        // V-LINE / V-BLOCK share purple with VISUAL — they're a
        // sub-mode of visual. Statusline differentiates them by
        // label so the user knows which selection geometry's active.
        // nvchad-user-2026-06-10 S3-03.
        EditingMode::VisualLine => ("V-LINE", theme::cur().purple),
        EditingMode::VisualBlock => ("V-BLOCK", theme::cur().purple),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_byte_size_picks_the_right_unit() {
        assert_eq!(format_byte_size(0), "0B");
        assert_eq!(format_byte_size(512), "512B");
        assert_eq!(format_byte_size(1023), "1023B");
        // 1 KiB and up — one decimal under 10K, whole numbers above.
        assert_eq!(format_byte_size(1024), "1.0K");
        assert_eq!(format_byte_size(1536), "1.5K");
        assert_eq!(format_byte_size(20 * 1024), "20K");
        // 1 MiB and up.
        assert_eq!(format_byte_size(1024 * 1024), "1.0M");
        assert_eq!(format_byte_size(20 * 1024 * 1024), "20M");
    }

    /// Render-assertion: with an editor open, the statusline's right
    /// lane carries a `Ln <cur>/<total> Col <c>` chip.
    #[test]
    fn draw_paints_the_line_column_chip() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        std::fs::write(ws.join("note.txt"), "one\ntwo\nthree\n").unwrap();
        let mut app = App::new(ws.clone(), crate::config::Config::default()).unwrap();
        app.open_path(&ws.join("note.txt"));

        let mut term = Terminal::new(TestBackend::new(120, 1)).unwrap();
        term.draw(|f| draw(f, &mut app, f.area())).unwrap();
        let buf = term.backend().buffer();
        let row: String = (0..buf.area.width).map(|x| buf[(x, 0)].symbol()).collect();
        assert!(
            row.contains("Ln 1/"),
            "statusline missing line chip: {row:?}"
        );
        assert!(
            row.contains("Col 1"),
            "statusline missing column chip: {row:?}"
        );
    }
}
