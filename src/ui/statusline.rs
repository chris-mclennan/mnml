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

use crate::app::{App, DynamicSegment, SegmentSide};
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
    /// #1012 f/u (2026-08-18) — half-open char range `[start, end)`
    /// within `text` to underline. Used by the multi-account Claude
    /// chip to underline JUST the account letter (e.g. `P` in
    /// ` \u{F1E00} P 24% ` — chars 3..4), which reads more
    /// distinctly than bolding the whole chip (bold on a
    /// tier-color pill is too close to unbold to spot at a
    /// glance). Empty range = no underline.
    underline_range: Option<(usize, usize)>,
    /// #1038 (2026-08-18) — half-open char range `[start, end)`
    /// within `text` whose foreground is overridden. Used to color
    /// JUST the "status" element inside a chip (the % on Claude/
    /// Codex, the ± delta on coverage) with a tier color while
    /// the rest of the chip keeps the base fg (dark) on a stable
    /// brand-color bg. Preserves powerline arrows between chips
    /// because bg no longer collapses to a shared tier color when
    /// two neighbors happen to hit the same green/yellow/red.
    fg_range: Option<(usize, usize, Color)>,
    /// #1038 — same shape as `fg_range`, but overrides the bg
    /// on that range. Produces a mini-pill INSIDE the chip.
    /// Currently unused (fg tint reads better than a bg patch —
    /// see 2026-08-18 f/u) but the composition machinery in
    /// `to_spans` still honors it if a future chip sets it.
    bg_range: Option<(usize, usize, Color)>,
}

impl Seg {
    fn new(text: impl Into<String>, fg: Color, bg: Color) -> Self {
        Seg {
            text: text.into(),
            fg,
            bg,
            bold: false,
            underline_range: None,
            fg_range: None,
            bg_range: None,
        }
    }
    fn bold(mut self) -> Self {
        self.bold = true;
        self
    }
    /// #1012 f/u — underline just the char range `[start, end)`
    /// (half-open). Used to mark the ACTIVE account letter in the
    /// multi-account ticker chip without underlining the whole
    /// percent-and-glyph pill. Empty or out-of-range values are
    /// treated as "no underline".
    fn underline_range(mut self, start: usize, end: usize) -> Self {
        if end > start {
            self.underline_range = Some((start, end));
        }
        self
    }
    /// #1038 — override the fg on char range `[start, end)` while
    /// the rest of the chip keeps its base fg. Used to color the
    /// status element (% / delta / count) inside a chip whose bg
    /// is the stable brand color. Empty range → no override.
    /// Peer to `bg_range` — retained for future chip designs where
    /// the bg patch reads worse than an fg tint.
    #[allow(dead_code)]
    fn fg_range(mut self, start: usize, end: usize, color: Color) -> Self {
        if end > start {
            self.fg_range = Some((start, end, color));
        }
        self
    }
    /// #1038 — same shape but overrides bg. Emits a colored
    /// mini-pill inside the chip. Zero-width → no override.
    /// Currently unused (the "mini-pill inside a pill" look tested
    /// weird — chips settled on fg_range for tier color) but kept
    /// for future chip designs where a bg patch might read better.
    #[allow(dead_code)]
    fn bg_range(mut self, start: usize, end: usize, color: Color) -> Self {
        if end > start {
            self.bg_range = Some((start, end, color));
        }
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
    /// Emit spans covering the char breakpoints from underline_range
    /// + fg_range + bg_range. Zero-width segments elided.
    ///
    /// Style composition, per-char (in this order):
    ///   - inside fg_range → override fg
    ///   - inside bg_range → override bg
    ///   - inside underline_range → add UNDERLINED
    fn to_spans(&self) -> Vec<Span<'static>> {
        let base = self.style();
        let cols = self.cols();
        if cols == 0 {
            return Vec::new();
        }
        let ul = self
            .underline_range
            .map(|(s, e)| (s.min(cols), e.min(cols)));
        let fg = self.fg_range.map(|(s, e, c)| (s.min(cols), e.min(cols), c));
        let bg = self.bg_range.map(|(s, e, c)| (s.min(cols), e.min(cols), c));
        let any = ul.map(|(s, e)| e > s).unwrap_or(false)
            || fg.map(|(s, e, _)| e > s).unwrap_or(false)
            || bg.map(|(s, e, _)| e > s).unwrap_or(false);
        if !any {
            return vec![Span::styled(self.text.clone(), base)];
        }
        let mut cuts: Vec<usize> = vec![0, cols];
        if let Some((s, e)) = ul {
            cuts.push(s);
            cuts.push(e);
        }
        if let Some((s, e, _)) = fg {
            cuts.push(s);
            cuts.push(e);
        }
        if let Some((s, e, _)) = bg {
            cuts.push(s);
            cuts.push(e);
        }
        cuts.sort_unstable();
        cuts.dedup();
        let byte_at = |char_idx: usize| -> usize {
            self.text
                .char_indices()
                .nth(char_idx)
                .map(|(b, _)| b)
                .unwrap_or(self.text.len())
        };
        let mut spans: Vec<Span<'static>> = Vec::with_capacity(cuts.len());
        for w in cuts.windows(2) {
            let (a, b) = (w[0], w[1]);
            if a >= b {
                continue;
            }
            let mid = a;
            let in_ul = ul.map(|(s, e)| mid >= s && mid < e).unwrap_or(false);
            let in_fg = fg.map(|(s, e, _)| mid >= s && mid < e).unwrap_or(false);
            let in_bg = bg.map(|(s, e, _)| mid >= s && mid < e).unwrap_or(false);
            let mut style = base;
            if let Some((_, _, c)) = fg
                && in_fg
            {
                style = style.fg(c);
            }
            if let Some((_, _, c)) = bg
                && in_bg
            {
                style = style.bg(c);
            }
            if in_ul {
                style = style.add_modifier(Modifier::UNDERLINED);
            }
            let ba = byte_at(a);
            let bb = byte_at(b);
            spans.push(Span::styled(self.text[ba..bb].to_string(), style));
        }
        spans
    }
}

/// Cap of columns dynamic sibling segments can consume on either
/// side of the statusline (per side). At least 20 cells always
/// available; scales with terminal width up to `total / 3`.
fn dynamic_lane_budget(total_width: usize) -> usize {
    (total_width / 3).max(20)
}

/// One dynamic segment that survived packing, in the form we
/// render (already truncated to fit its allocation).
struct RenderedDynamicSegment {
    /// Segment id — used post-render to register a hover / click
    /// hitrect (`statusline_segment_hits`) so downstream tooltip
    /// + info-panel copy can look the source manifest up.
    id: String,
    text: String,
    color: Option<String>,
}

/// Hybrid pack: sort by priority desc, allocate each segment its
/// `max_width` (or the natural text width, whichever is smaller)
/// while budget allows. Segments that would exceed the remaining
/// budget below their `min_width` are dropped entirely (not
/// truncated further). Higher-priority always wins.
fn collect_dynamic_segments(
    all: &[DynamicSegment],
    side: SegmentSide,
    total_width: usize,
) -> Vec<RenderedDynamicSegment> {
    let mut candidates: Vec<&DynamicSegment> = all.iter().filter(|s| s.side == side).collect();
    if candidates.is_empty() {
        return Vec::new();
    }
    candidates.sort_by_key(|c| std::cmp::Reverse(c.priority));

    let mut budget = dynamic_lane_budget(total_width);
    let mut out: Vec<RenderedDynamicSegment> = Vec::new();
    for s in candidates {
        let natural_width = s.text.chars().count();
        // The width we'd LIKE to allocate — clamp text width to
        // max_width, then to what's left of the budget.
        let desired = natural_width.min(s.max_width as usize);
        let alloc = desired.min(budget);
        // Drop when the remaining budget can't even give this
        // segment its declared minimum.
        if alloc < s.min_width as usize {
            continue;
        }
        // Truncate + pad to allocation.
        let mut text = if natural_width > alloc {
            ellipsize(&s.text, alloc)
        } else {
            s.text.clone()
        };
        // Powerline chips read cleaner with a leading + trailing
        // space; segment text usually already has them, but pad
        // if not.
        if !text.starts_with(' ') {
            text.insert(0, ' ');
        }
        if !text.ends_with(' ') {
            text.push(' ');
        }
        let final_width = text.chars().count();
        budget = budget.saturating_sub(final_width);
        out.push(RenderedDynamicSegment {
            id: s.id.clone(),
            text,
            color: s.color.clone(),
        });
    }
    out
}

/// Convert a packed dynamic segment into a `Seg` for the render
/// pipeline. Named theme color lookup falls back to `comment`
/// (matches the manifest loader's fallback).
/// Compact `12.3k` / `4.5M` formatter for Codex token counts.
fn format_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn seg_from_dynamic(rd: &RenderedDynamicSegment) -> Seg {
    let t = theme::cur();
    let fg = t.bg_darker; // dark text on colored chip
    let bg = match rd.color.as_deref() {
        Some("red") => t.red,
        Some("orange") => t.orange,
        Some("yellow") => t.yellow,
        Some("green") => t.green,
        Some("blue") => t.blue,
        Some("cyan") => t.cyan,
        Some("teal") => t.teal,
        Some("purple") => t.purple,
        Some("pink") => t.pink,
        Some("magenta") => t.purple,
        Some("comment") => t.comment,
        _ => t.comment,
    };
    Seg::new(rd.text.clone(), fg, bg)
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

/// Tier color for a Claude usage %. <60 = green, 60-84 = yellow,
/// 85+ = red. Shared by the single-account chip and the multi-
/// account render so both surfaces color-code identically. #944.
fn tier_color(percent: u16, t: &theme::Theme) -> ratatui::style::Color {
    if percent >= 85 {
        t.red
    } else if percent >= 60 {
        t.yellow
    } else {
        t.green
    }
}

/// Task #944 (2026-08-16) — compact per-account chip content.
/// Renders as `0 Pe 40% · Wo 62% · Co 12%` (glyph + one
/// segment per account, 2-char name prefix). Chip color = worst
/// tier across accounts so a hot account is visible without
/// staring at each number. Accounts with no snapshot yet render
/// as `Nm …`; last-error accounts render as `Nm —!` (red family).
fn render_claude_chip_all_accounts(app: &App, t: &theme::Theme) -> (String, ratatui::style::Color) {
    let mut parts: Vec<String> = Vec::with_capacity(app.ai_usage_claude_accounts.len());
    let mut worst: u16 = 0;
    let mut any_error = false;
    // 2026-08-17 — same three-state logic as `render_single_account_chip`:
    //   errored          → `!` + red
    //   fetched (any %)  → tier color, 0% renders as `0%` green (idle+healthy)
    //   never fetched    → `…` gray
    // Prior version lumped "fetched 0%" with "never fetched" and rendered
    // both gray, which was misleading for genuinely-idle accounts.
    let mut any_fetched_gt_zero = false;
    for acc in &app.ai_usage_claude_accounts {
        let abbrev = account_abbrev(&acc.name);
        let u = &acc.usage;
        if u.last_error.is_some() {
            parts.push(format!("{abbrev}—!"));
            any_error = true;
        } else if u.fetched_at > 0 {
            // Successful fetch — always show the number (0% included).
            parts.push(format!("{abbrev}{}%", u.percent));
            worst = worst.max(u.percent);
            any_fetched_gt_zero = true;
        } else {
            parts.push(format!("{abbrev}…"));
        }
    }
    if parts.is_empty() {
        return (" \u{F1E00} … ".to_string(), t.comment);
    }
    let color = if any_error && worst == 0 {
        t.red
    } else if any_fetched_gt_zero {
        // At least one account has a successful fetch — reflect the
        // worst tier (green when everyone's low, yellow/red when hot).
        tier_color(worst, t)
    } else {
        // No account has a successful fetch yet — gray.
        t.comment
    };
    let text = format!(" \u{F1E00} {} ", parts.join(" · "));
    (text, color)
}

/// #1038 — render result for a Claude account chip. `text` is the
/// fully-formed chip label. `tier_fg` colors the numeric status
/// portion `[tier_range]` when set; the rest of the chip uses the
/// caller's base fg on the chip's brand bg. `tier_range` is the
/// char range covering the % + optional reset suffix (typically
/// everything after the glyph and any letter prefix, before the
/// trailing space). When `tier_range` is `None`, the whole chip
/// gets `tier_fg` — used for the error / never-fetched em-dash
/// states where there's no distinct status element to color.
struct ClaudeChipResult {
    text: String,
    tier_fg: ratatui::style::Color,
    tier_range: Option<(usize, usize)>,
}

/// Render a single account's usage as a chip. Shared by the
/// single-account (`Off`) render path and the multi-account
/// `Ticker` render path — extracted 2026-08-17 so ticker mode
/// gets the same session/weekly/both detail the single-account
/// chip provides. `letter_prefix` is an optional 1-char account
/// letter (`P`/`W`/`C`) — empty string for the Off case (no
/// disambiguation needed), non-empty for Ticker (identifies which
/// account is currently on-screen).
fn render_single_account_chip(
    u: &crate::ai_usage::ClaudeUsage,
    mode: &str,
    letter_prefix: &str,
    show_reset: bool,
    t: &theme::Theme,
) -> ClaudeChipResult {
    let prefix = if letter_prefix.is_empty() {
        String::new()
    } else {
        format!("{letter_prefix} ")
    };
    if u.last_error.is_some() {
        // R5 keyboard SEV-3 2026-08-08 — differentiate errors from 0%.
        return ClaudeChipResult {
            text: format!(" \u{F1E00} {prefix}—! "),
            tier_fg: t.red,
            tier_range: None,
        };
    }
    if u.fetched_at == 0 {
        // Never fetched — no signal yet.
        return ClaudeChipResult {
            text: format!(" \u{F1E00} {prefix}— "),
            tier_fg: t.comment,
            tier_range: None,
        };
    }
    // Successful fetch. Render per mode; tier color reflects the
    // worst of the shown numbers (0% used ⇒ green).
    //
    // #1012 (2026-08-18) — when `show_reset` is true (`[ai]
    // claude_show_reset = true`), append `⟳<countdown>` after each
    // percent so the user sees when the window opens back up:
    // "24%⟳3h 62%⟳4d".
    let session_r = if show_reset {
        format_reset_suffix(u.resets_at, u.percent)
    } else {
        String::new()
    };
    let weekly_r = if show_reset {
        format_reset_suffix(u.weekly_resets_at, u.weekly_percent)
    } else {
        String::new()
    };
    let (label, tier_pct) = match mode {
        "weekly" => (
            format!(" \u{F1E00} {prefix}{}%{} ", u.weekly_percent, weekly_r),
            u.weekly_percent,
        ),
        "both" => (
            format!(
                " \u{F1E00} {prefix}{}%{} {}%{} ",
                u.percent, session_r, u.weekly_percent, weekly_r
            ),
            u.percent.max(u.weekly_percent),
        ),
        _ => (
            format!(" \u{F1E00} {prefix}{}%{} ", u.percent, session_r),
            u.percent,
        ),
    };
    // Compute the tier range = span of the numeric status element.
    // Layout is ` <glyph> [prefix]<numbers> ` — char 0 is the
    // leading space, char 1 is the glyph, char 2 is the space
    // after the glyph, chars 3..3+prefix_cols are the letter
    // prefix, then numbers to the last non-space char.
    let cols = label.chars().count();
    let prefix_cols = prefix.chars().count();
    let numeric_start = 3 + prefix_cols;
    let numeric_end = cols.saturating_sub(1); // strip trailing space
    let tier_range = if numeric_end > numeric_start {
        Some((numeric_start, numeric_end))
    } else {
        None
    };
    ClaudeChipResult {
        text: label,
        tier_fg: tier_color(tier_pct, t),
        tier_range,
    }
}

/// #1012 (2026-08-18) — format the time remaining until `resets_at`
/// (Unix epoch seconds) as a compact ` <n><unit>` suffix (leading
/// space acts as the separator). Empty in three cases so the chip
/// doesn't grow when the countdown adds no info:
///   - `resets_at == 0` — never fetched
///   - `remaining == 0` — already past
///   - `percent == 0`   — user hasn't touched this window; the
///     countdown to a reset we haven't consumed is noise
///
/// Uses the largest unit that fits at 1 digit + a letter (`3h` not
/// `3h27m`) so the chip stays narrow. Prior versions used a
/// separator glyph (U+27F3 ⟳, then Codicon refresh) — both were
/// visually noisy; a plain space is the cleanest read.
///
/// Buckets:
///   <1m         → ` <1m`
///   <60m        → ` <n>m`
///   <24h        → ` <n>h`
///   otherwise   → ` <n>d`
fn format_reset_suffix(resets_at: u64, percent: u16) -> String {
    if resets_at == 0 || percent == 0 {
        return String::new();
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let remaining = resets_at.saturating_sub(now);
    if remaining == 0 {
        return String::new();
    }
    if remaining < 60 {
        " <1m".to_string()
    } else if remaining < 3600 {
        format!(" {}m", remaining / 60)
    } else if remaining < 86_400 {
        format!(" {}h", remaining / 3600)
    } else {
        format!(" {}d", remaining / 86_400)
    }
}

/// Single-character name prefix for the multi-account chip. Uses
/// the first char upper-cased, so `personal` → `P`, `work` → `W`,
/// `consulting` → `C`. Was 2-char (`Pe`/`Wo`/`Co`) — user report
/// 2026-08-17: with 3 accounts + spaces, the chip clipped for
/// 1990-cell terminals. Collision on first-letter is possible but
/// rare (2 accounts starting with the same letter); user
/// disambiguates via the Claude Usage pane's section headers.
/// Falls back to `?` when the name is empty.
fn account_abbrev(name: &str) -> String {
    let a = name
        .chars()
        .next()
        .map(|c| c.to_ascii_uppercase())
        .unwrap_or('?');
    a.to_string()
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
    // Sibling-authored dynamic segments (hybrid packing: sort by
    // priority desc, allocate max_width while budget allows, drop
    // lower-priority when full). Left-lane segments go here so
    // they render right after the mode chip.
    let dyn_left = collect_dynamic_segments(&app.dynamic_segments, SegmentSide::Left, width);
    // Index of the git-branch chip in `left` once pushed — used after
    // render_left to register a clickable rect that fires `git.graph`.
    let mut branch_seg_idx: Option<usize> = None;
    // #polish 2026-07-06 — new statusline chips: PR badge, file
    // (name + glyph), diagnostics (err + warn), symbol crumb, language.
    let mut pr_seg_idx: Option<usize> = None;
    let mut file_glyph_idx: Option<usize> = None;
    let mut file_name_idx: Option<usize> = None;
    let mut diag_err_idx: Option<usize> = None;
    let mut diag_warn_idx: Option<usize> = None;
    let mut symbol_seg_idx: Option<usize> = None;
    let mut macro_seg_idx: Option<usize> = None;
    let mut find_seg_idx: Option<usize> = None;
    let mut sel_seg_idx: Option<usize> = None;
    let mut progress_seg_idx: Option<usize> = None;
    let mut bg_tasks_seg_idx: Option<usize> = None;
    let mut ai_seg_idx: Option<usize> = None;
    app.rects.statusline_branch_chip = None;
    app.rects.statusline_mode_chip = None;
    app.rects.statusline_file_chip = None;
    app.rects.statusline_diagnostics_chip = None;
    app.rects.statusline_language_chip = None;
    app.rects.statusline_symbol_chip = None;
    app.rects.statusline_pr_chip = None;
    app.rects.statusline_macro_chip = None;
    app.rects.statusline_find_chip = None;
    app.rects.statusline_sel_chip = None;
    app.rects.statusline_progress_chip = None;
    app.rects.statusline_bg_tasks_chip = None;
    app.rects.statusline_ai_chip = None;
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
    // Append left-lane dynamic segments (from sibling
    // `statusline_set_segment` calls) right after the mode chip.
    // Track (left_seg_index, segment_id) so we can register hover
    // / click hitrects after `render_left` computes the on-screen
    // column ranges.
    let mut dyn_left_placements: Vec<(usize, String)> = Vec::with_capacity(dyn_left.len());
    for spec in &dyn_left {
        dyn_left_placements.push((left.len(), spec.id.clone()));
        left.push(seg_from_dynamic(spec));
    }
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
        pr_seg_idx = Some(left.len());
        left.push(Seg::new(chip, theme::cur().purple, theme::cur().bg2));
    }
    // file segment: icon (its devicon color) + name + dirty marker, both on STATUSLINE bg.
    match app.active_editor() {
        Some(b) => {
            let p = b.path.clone().unwrap_or_else(|| b.display_name().into());
            let (glyph, gc) = icons::for_path(&p, false, false, nerd);
            file_glyph_idx = Some(left.len());
            left.push(Seg::new(format!(" {glyph} "), gc, theme::cur().statusline));
            let name = format!("{}{} ", b.display_name(), if b.dirty { " ●" } else { "" });
            file_name_idx = Some(left.len());
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
                diag_err_idx = Some(left.len());
                left.push(Seg::new(
                    format!("  {errs} "),
                    theme::cur().red,
                    theme::cur().statusline,
                ));
            }
            if warns > 0 {
                diag_warn_idx = Some(left.len());
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
                    symbol_seg_idx = Some(left.len());
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
                macro_seg_idx = Some(left.len());
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
                find_seg_idx = Some(left.len());
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
    // Sibling-authored right-lane dynamic segments (packed by
    // priority, dropped if overflow). Rendered leftmost on the
    // right lane so they don't push the builtin chips off screen
    // — losing a sibling segment is better than losing line/col.
    let dyn_right = collect_dynamic_segments(&app.dynamic_segments, SegmentSide::Right, width);
    // Track (right_seg_index, segment_id) so hover / click rects
    // can be registered against on-screen positions after
    // `render_right` computes them.
    let mut dyn_right_placements: Vec<(usize, String)> = Vec::with_capacity(dyn_right.len());
    for spec in &dyn_right {
        dyn_right_placements.push((right.len(), spec.id.clone()));
        right.push(seg_from_dynamic(spec));
    }
    // Test-runner chip — `🧪 <label>`. Shown when the user has
    // launched a test pane in this session (cargo / npm / pytest /
    // go / playwright) and that pane is still alive. Click →
    // focus the pane. Cleared when the pane closes.
    app.rects.statusline_test_chip = None;
    let test_chip_label = match &app.last_test_run {
        Some((label, pane_idx)) => {
            // Drop the entry silently when the pane has been
            // closed since we recorded it — keeps the chip
            // honest.
            if *pane_idx < app.panes.len() {
                Some((label.clone(), *pane_idx))
            } else {
                None
            }
        }
        None => None,
    };
    let mut test_seg_idx: Option<usize> = None;
    if let Some((label, _pane_idx)) = test_chip_label.clone() {
        test_seg_idx = Some(right.len());
        right.push(Seg::new(
            format!(" \u{1F9EA} {label} "),
            theme::cur().bg_darker,
            theme::cur().yellow,
        ));
    }
    // AI usage meters — Claude (F1E00, %) + Codex (F1E01, tokens).
    // Each chip renders only when the corresponding integration is
    // enabled. Green/yellow/red per usage tier for Claude; single
    // color for Codex (no known quota to grade against). #876.
    app.rects.statusline_ai_claude_chip = None;
    app.rects.statusline_ai_codex_chip = None;
    let mut ai_claude_seg_idx: Option<usize> = None;
    let mut ai_codex_seg_idx: Option<usize> = None;
    let claude_enabled = app
        .config
        .ui
        .integration_icons
        .iter()
        .any(|ic| ic.id == "claude_code" && ic.enabled);
    let codex_enabled = app
        .config
        .ui
        .integration_icons
        .iter()
        .any(|ic| ic.id == "codex" && ic.enabled);
    if claude_enabled {
        let t = theme::cur();
        // Config `[ai] claude_meter_mode` picks what the chip shows:
        //   "session" (default): 5h utilization only — if you run
        //      out of session you're done for that window, so this
        //      is the more actionable number for right-now decisions.
        //   "weekly": 7-day utilization only.
        //   "both": both, e.g. `24%s · 81%w`.
        let mode = app
            .config
            .ai
            .as_table()
            .and_then(|t| t.get("claude_meter_mode"))
            .and_then(|v| v.as_str())
            .unwrap_or("session");
        // #1012 (2026-08-18) — opt-in `⟳<countdown>` suffix after each
        // percent. Off by default; a busy statusline user asked for it
        // so long-running sessions know how many days remain in the
        // weekly window. Reads from `[ai] claude_show_reset = true`.
        let show_reset = app
            .config
            .ai
            .as_table()
            .and_then(|t| t.get("claude_show_reset"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        // Task #944 — tri-state multi-account display. `Off` (default)
        // = active account only. `Compact` = one segment per account
        // (`P40% · W62% · C12%`, worst-tier color) — visible-all-at-
        // once but width-expensive. `Ticker` (2026-08-17) rotates
        // through accounts on wall-clock (4s per window) rendering
        // each with the full session+weekly detail — trades "see all
        // at once" for "see full detail for each in turn". Falls back
        // to Off render when only ONE account is configured (the
        // multi-account modes have nothing to compare).
        let multi_mode = if app.ai_usage_claude_accounts.len() > 1 {
            app.config.ai_claude_multi_mode()
        } else {
            crate::config::ClaudeMultiMode::Off
        };
        // #1038 — chip bg is Claude's brand color (stable orange),
        // tier color (green/yellow/red) moves onto the % via
        // fg_range. Two neighbor chips no longer fuse when both hit
        // the same tier — bg differs by chip identity, powerline
        // arrows stay visible.
        struct ClaudeRender {
            text: String,
            tier_fg: Color,
            tier_range: Option<(usize, usize)>,
            underline: (usize, usize),
        }
        let claude_render: ClaudeRender = match multi_mode {
            crate::config::ClaudeMultiMode::Compact => {
                let (text, tier_fg) = render_claude_chip_all_accounts(app, &t);
                // Compact chip is `<glyph> Pe 40% · Wo 62% · Co 12%` —
                // the whole numeric block is worth coloring. Span from
                // after `<space><glyph><space>` (char 3) to before the
                // trailing space.
                let cols = text.chars().count();
                let tier_range = if cols > 4 { Some((3, cols - 1)) } else { None };
                ClaudeRender {
                    text,
                    tier_fg,
                    tier_range,
                    underline: (0, 0),
                }
            }
            crate::config::ClaudeMultiMode::Ticker => {
                let n = app.ai_usage_claude_accounts.len();
                let idx = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| (d.as_secs() / 4) as usize % n)
                    .unwrap_or(0);
                let acc = &app.ai_usage_claude_accounts[idx];
                let letter = account_abbrev(&acc.name);
                let res = render_single_account_chip(&acc.usage, mode, &letter, show_reset, &t);
                // #1012 f/u — active-account letter (char 3..4) gets
                // an underline; tier_range covers the numbers after.
                let underline = if acc.is_active { (3, 4) } else { (0, 0) };
                ClaudeRender {
                    text: res.text,
                    tier_fg: res.tier_fg,
                    tier_range: res.tier_range,
                    underline,
                }
            }
            crate::config::ClaudeMultiMode::Off => {
                let active = app.active_claude_account();
                let usage_ref = active.map(|a| &a.usage);
                match usage_ref {
                    Some(u) => {
                        let res = render_single_account_chip(u, mode, "", show_reset, &t);
                        ClaudeRender {
                            text: res.text,
                            tier_fg: res.tier_fg,
                            tier_range: res.tier_range,
                            underline: (0, 0),
                        }
                    }
                    None => ClaudeRender {
                        text: " \u{F1E00} … ".to_string(),
                        tier_fg: t.comment,
                        tier_range: None,
                        underline: (0, 0),
                    },
                }
            }
        };
        ai_claude_seg_idx = Some(right.len());
        // Brand color = Claude orange (stable, so neighboring chips
        // never fuse). Text is dark for readability. The numeric
        // status span gets a tier-colored bg patch (mini-pill inside
        // the chip), matching the old whole-chip pill treatment but
        // scoped so the outer bg stays brand-stable. When there's
        // no numeric span (error / no-data em-dash), the whole chip
        // uses the tier fg on the brand bg.
        //
        // 2026-08-18 f/u: was `bg_range` (tier bg-patch inside the
        // chip) — visually read as a "mini-pill nested inside a
        // pill" because the sharp bg-edge inside the brand pill
        // looked like a separate chip. Switched to `fg_range`:
        // numbers get colored TEXT on the brand bg instead of a
        // colored patch. Same info-density, no nested rectangle.
        let base_fg = if claude_render.tier_range.is_none() {
            claude_render.tier_fg
        } else {
            t.bg_darker
        };
        let mut seg = Seg::new(claude_render.text, base_fg, t.orange);
        if let Some((s, e)) = claude_render.tier_range {
            seg = seg.fg_range(s, e, claude_render.tier_fg);
        }
        let (u_start, u_end) = claude_render.underline;
        seg = seg.underline_range(u_start, u_end);
        right.push(seg);
    }
    if codex_enabled {
        let t = theme::cur();
        // #1038 — Codex bg = cyan (brand, stable). Codex has no
        // tier status (no known quota), so the whole chip is dark
        // on cyan. No-data em-dash dims the text.
        let (text, has_data) = match &app.ai_usage_codex {
            Some(u) if u.tokens_today > 0 => (
                format!(" \u{F1E01} {} ", format_tokens(u.tokens_today)),
                true,
            ),
            Some(_) => (" \u{F1E01} 0 ".to_string(), true),
            None => (" \u{F1E01} … ".to_string(), false),
        };
        ai_codex_seg_idx = Some(right.len());
        let fg = if has_data { t.bg_darker } else { t.comment };
        right.push(Seg::new(text, fg, t.cyan));
    }
    // Coverage meter — Tattle rollups. Feature % (from
    // `feature-coverage/_trends/trends.json`) always leads; Code %
    // (Istanbul, from `code-coverage/_trends/trends.json`) appended
    // when that file exists too. Either can be absent per user
    // (chip hides entirely if BOTH are missing). Click →
    // `tattle_coverage_ext.open` (integration Pty pane). Chip color
    // = feature delta direction (Code delta shown via arrow only).
    // 2026-08-16 — Code % added per user ask.
    app.rects.statusline_coverage_chip = None;
    app.ensure_coverage_loaded();
    let mut coverage_seg_idx: Option<usize> = None;
    // 2026-08-16 — right-click on the chip picks which halves render.
    // `both` = F + C; `feature` = F only (backwards-compat); `code` =
    // Istanbul only. `.filter(|_| show_X)` collapses a disabled half
    // to None so the existing "hide the C block if code_now.is_none()"
    // path handles the both→feature transition without extra branches.
    // The code-only case takes a dedicated render arm below.
    // 2026-08-16 — narrow-chip modes. Prior default `both` felt too
    // wide in a busy statusline. `feature` (new default) / `code` show
    // one half; `ticker` auto-cycles between F-only and C-only on a
    // ~4s wall-clock period so users can see both without paying the
    // width cost. Redraw cadence (~120ms idle poll → term.draw) is
    // fine-grained enough that the swap looks smooth.
    //
    // Ticker degrades gracefully when only one data source exists —
    // the "either can be absent" case (no Istanbul rollup, or no
    // feature rollup). If both present: alternate. If one present:
    // pin to it (else the chip blinks off half the time and the
    // right-click hitbox vanishes with it).
    let mode = app.config.ui.coverage_chip_mode.as_str();
    let has_f = app
        .coverage_trends
        .as_ref()
        .and_then(|t| t.overall_current())
        .is_some();
    let has_c = app
        .istanbul_trends
        .as_ref()
        .and_then(|t| t.overall_current())
        .is_some();
    let ticker_show_f = if mode == "ticker" && has_f && has_c {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() / 4 % 2 == 0)
            .unwrap_or(true)
    } else {
        // Single-source or non-ticker: pin ticker_show_f meaningfully.
        // For ticker with only F: true (show F). For ticker with only
        // C: false (show C). Ignored otherwise.
        has_f
    };
    let show_f = matches!(mode, "both" | "feature") || (mode == "ticker" && ticker_show_f);
    let show_c = matches!(mode, "both" | "code") || (mode == "ticker" && !ticker_show_f);
    let feature_now = app
        .coverage_trends
        .as_ref()
        .and_then(|t| t.overall_current())
        .filter(|_| show_f);
    let feature_prev = app
        .coverage_trends
        .as_ref()
        .and_then(|t| t.overall_at(7))
        .filter(|_| show_f);
    let code_now = app
        .istanbul_trends
        .as_ref()
        .and_then(|t| t.overall_current())
        .filter(|_| show_c);
    // Istanbul updates per-commit rather than daily, so the delta is
    // vs previous commit, not 7-day lookback (see `overall_prev`).
    let code_prev = app
        .istanbul_trends
        .as_ref()
        .and_then(|t| t.overall_prev())
        .filter(|_| show_c);
    // Code-only mode: feature_now is None (either show_f=false or the
    // file doesn't exist); render a C-only chip if code_now exists.
    if feature_now.is_none()
        && let Some(c_now) = code_now
    {
        let t = theme::cur();
        // Same "arrow + magnitude" format as feature's delta suffix
        // for consistency (was arrow-only prior to 2026-08-16 fix).
        let (delta, fg) = match code_prev {
            Some(p) => {
                let d = c_now - p;
                let arrow = if d.abs() < 0.05 {
                    "±"
                } else if d > 0.0 {
                    "▲"
                } else {
                    "▼"
                };
                let color = if d.abs() < 0.05 {
                    t.comment
                } else if d > 0.0 {
                    t.green
                } else {
                    t.red
                };
                (format!(" {arrow}{:.1}", d.abs()), color)
            }
            None => (String::new(), t.comment),
        };
        let text = format!(" {} C {:.0}%{} ", coverage_glyph(app), c_now, delta);
        coverage_seg_idx = Some(right.len());
        // #1038 — bg = teal (coverage brand, stable). Delta arrow +
        // magnitude gets a tier-color bg patch (mini-pill inside).
        // Empty delta case: no patch, whole chip is dark on teal.
        let delta_cols = delta.chars().count();
        let cols = text.chars().count();
        let mut seg = Seg::new(text, t.bg_darker, t.teal);
        if delta_cols > 0 {
            let start = cols - 1 - delta_cols; // strip trailing space + delta width
            let end = cols - 1;
            seg = seg.fg_range(start, end, fg);
        }
        right.push(seg);
    } else if let Some(f_now) = feature_now {
        let t = theme::cur();
        let (f_delta, fg) = match feature_prev {
            Some(p) => {
                let d = f_now - p;
                let arrow = if d.abs() < 0.05 {
                    "±"
                } else if d > 0.0 {
                    "▲"
                } else {
                    "▼"
                };
                let color = if d.abs() < 0.05 {
                    t.comment
                } else if d > 0.0 {
                    t.green
                } else {
                    t.red
                };
                (format!(" {arrow}{:.1}", d.abs()), color)
            }
            None => (String::new(), t.comment),
        };
        let code_str = code_now
            .map(|c_now| {
                // Match feature's " ▲1.4"-style delta suffix (arrow +
                // 1-decimal magnitude) instead of arrow-only. User
                // reported the missing change value 2026-08-16:
                // "up down change value not showing for code. it shows
                // for feature".
                let delta = match code_prev {
                    Some(p) => {
                        let d = c_now - p;
                        let arrow = if d.abs() < 0.05 {
                            "±"
                        } else if d > 0.0 {
                            "▲"
                        } else {
                            "▼"
                        };
                        format!(" {arrow}{:.1}", d.abs())
                    }
                    None => String::new(),
                };
                format!(" · C {:.0}%{}", c_now, delta)
            })
            .unwrap_or_default();
        let text = format!(
            " {} F {:.0}%{}{} ",
            coverage_glyph(app),
            f_now,
            f_delta,
            code_str
        );
        coverage_seg_idx = Some(right.len());
        // #1038 — bg = teal (stable). The F delta gets a tier-color
        // bg patch; if code_now is present, the C delta gets its own
        // patch too. Multi-range bg via chained bg_range wouldn't
        // work (single field), so use fg_range to tint the FIRST
        // delta and bg_range for the SECOND when both are shown.
        // Simpler for now: only tint the FIRST delta patch. Full
        // two-patch treatment is a follow-up if the user wants it.
        let f_delta_cols = f_delta.chars().count();
        let cols = text.chars().count();
        let mut seg = Seg::new(text, t.bg_darker, t.teal);
        if f_delta_cols > 0 {
            // Locate f_delta at "` F {:.0}%<f_delta>...`".
            // Compute start by summing widths of everything before it.
            let head_cols = format!(" {} F {:.0}%", coverage_glyph(app), f_now)
                .chars()
                .count();
            let start = head_cols;
            let end = start + f_delta_cols;
            if end <= cols {
                seg = seg.fg_range(start, end, fg);
            }
        }
        right.push(seg);
    }
    // Now-playing chip — pushed first so it's the leftmost segment of
    // the right cluster (closer to centre). Doubles as the mixr launch
    // button: shows the track from whatever player the background
    // poller found (mixr / macOS Music / Spotify), `♪ mixr` when idle.
    // Click → `mixr.show`. Data is `App.now_playing`.
    // Three-segment transport cluster `[play/pause] [ffwd] [track]`
    // when any source is playing or has a track loaded. Source-aware
    // dispatch — mixr uses its IPC, Apple Music / Spotify use
    // AppleScript (see `tui.rs` send_macos_player). Idle (no track
    // from any source) collapses to a single `♪ mixr` chip.
    //
    // Nerd-font codepoints — basic Unicode ⏸/▶/⏭ rendered as
    // invisible glyphs in mnml's font-fallback chain on the user's
    // setup (reported 2026-06-17).
    const NF_PLAY: char = '\u{f04b}'; // nf-fa-play
    const NF_PAUSE: char = '\u{f04c}'; // nf-fa-pause
    const NF_FFWD: char = '\u{f051}'; // nf-fa-step-forward
    let mixr_is_source = app
        .now_playing
        .as_ref()
        .map(|np| np.source.eq_ignore_ascii_case("mixr"))
        .unwrap_or(false);
    let has_track_loaded = app
        .now_playing
        .as_ref()
        .map(|np| !np.track.is_empty())
        .unwrap_or(false);
    let track_is_playing = app
        .now_playing
        .as_ref()
        .map(|np| np.playing)
        .unwrap_or(false);
    let (mixr_play_seg_idx, mixr_ffwd_seg_idx, mixr_seg_idx) = if has_track_loaded {
        // Three-segment transport cluster.
        let np = app
            .now_playing
            .as_ref()
            .expect("guarded by has_track_loaded");
        // Combine artist + title when the source separates them.
        // Mixr bakes "Artist - Title" into `track` and uses `detail`
        // for bpm, so its `track` already reads well by itself. macOS
        // Music / Spotify keep title in `track` and artist in
        // `detail` — join them as `Artist - Title` so the chip shows
        // both. Falls back to bare `track` for any source that
        // leaves `detail` empty.
        let raw = if mixr_is_source || np.detail.is_empty() {
            np.track.clone()
        } else {
            format!("{} - {}", np.detail, np.track)
        };
        let clean = raw.split_whitespace().collect::<Vec<_>>().join(" ");
        // Truncate at 28 chars (+ 1 for the `…`) — bounded so a long
        // title + artist can't push the clock + LSP chips off the
        // strip.
        let shown: String = if clean.chars().count() > 28 {
            clean.chars().take(28).chain(std::iter::once('…')).collect()
        } else {
            clean
        };
        let glyph = if track_is_playing { NF_PAUSE } else { NF_PLAY };
        // Play / pause segment.
        let play_idx = right.len();
        right.push(Seg::new(
            format!(" {glyph} "),
            theme::cur().purple,
            theme::cur().bg2,
        ));
        // Ffwd segment.
        let ffwd_idx = right.len();
        right.push(Seg::new(
            format!(" {NF_FFWD} "),
            theme::cur().purple,
            theme::cur().bg2,
        ));
        // Track text segment.
        let track_idx = right.len();
        right.push(Seg::new(
            format!(" {shown} "),
            theme::cur().purple,
            theme::cur().bg2,
        ));
        (Some(play_idx), Some(ffwd_idx), track_idx)
    } else {
        // Idle: single `♪ <preferred>` chip. Click activates whichever
        // music app the user picked in Settings (`ui.preferred_music_app`
        // — default `mixr`). Lets a user who lives in Spotify see "♪
        // spotify" and tap to open it, instead of the chip always
        // showing mixr.
        let label = match app.config.ui.preferred_music_app.as_str() {
            "music" => " ♪ music ",
            "spotify" => " ♪ spotify ",
            _ => " ♪ mixr ",
        };
        let idx = right.len();
        right.push(Seg::new(
            label.to_string(),
            theme::cur().comment,
            theme::cur().bg2,
        ));
        (None, None, idx)
    };
    // Suppress unused-var warning when `mixr_is_source` falls out of
    // use — it's used by the click dispatcher to pick mixr vs
    // AppleScript routing, but the render side doesn't need it.
    let _ = mixr_is_source;
    let mut clock_seg_idx: Option<usize> = None;
    let mut stress_seg_idx: Option<usize> = None;
    let mut lsp_seg_idx: Option<usize> = None;
    let mut wrap_seg_idx: Option<usize> = None;
    let mut autosave_seg_idx: Option<usize> = None;
    let mut filesize_seg_idx: Option<usize> = None;
    let mut lncol_seg_idx: Option<usize> = None;
    app.rects.statusline_workspace_chip = None;
    app.rects.statusline_clock_chip = None;
    app.rects.statusline_mixr_chip = None;
    app.rects.statusline_mixr_play_chip = None;
    app.rects.statusline_mixr_ffwd_chip = None;
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
        progress_seg_idx = Some(right.len());
        right.push(Seg::new(
            format!(" ⟳  {label} "),
            theme::cur().bg_darker,
            theme::cur().cyan,
        ));
    }
    // Unified "mnml is busy" chip (#6) — supplements the per-signal
    // chips above. Shown when the total background count is at least
    // 2, so a single LSP/AI task (which the specific chip already
    // covers) doesn't get a duplicate. Spinner phase follows the
    // toast-stack pattern so the two animate in sync.
    let bg_n = app.background_task_count();
    if bg_n >= 2 {
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];
        let idx = (ms / 100) as usize % frames.len();
        let spin = frames[idx];
        bg_tasks_seg_idx = Some(right.len());
        right.push(Seg::new(
            format!(" {spin} {bg_n} "),
            theme::cur().bg_darker,
            theme::cur().cyan,
        ));
    }
    // `✦ AI` chip while an inline-suggestion request is in flight — the
    // ghost-text round-trip is ~0.5–1.5s, so this tells the user a
    // completion is coming (vs the editor just sitting idle).
    if app.ai_suggestion_in_flight() {
        ai_seg_idx = Some(right.len());
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
    // Autosave indicator — chip when `[editor] autosave_secs > 0`.
    // Lets the user see at a glance that idle saves are armed.
    // #polish 2026-07-06 — was `AS 5s` (unclear abbreviation);
    // now uses a disk glyph so the semantic is visual, not
    // dependent on knowing the two-letter code.
    let autosave = app.config.editor.autosave_secs;
    if autosave > 0 {
        autosave_seg_idx = Some(right.len());
        let label = if nerd {
            format!(" \u{F0193} {autosave}s ")
        } else {
            format!(" save {autosave}s ")
        };
        right.push(Seg::new(label, theme::cur().bg_darker, theme::cur().green));
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
            sel_seg_idx = Some(right.len());
            right.push(Seg::new(
                format!(" Sel {n} "),
                theme::cur().bg_darker,
                theme::cur().yellow,
            ));
        }
    }
    // Stress meter — visible signal of how loaded mnml is.
    // 4-block bar that fills as the p95 frame time climbs:
    //   0-20  score → 1 block (dim, green-ish)
    //   20-40 → 2 blocks (yellow)
    //   40-70 → 3 blocks (orange)
    //   70+   → 4 blocks (red, bold)
    // 2026-07-20 — always render when `[ui] stress_meter = true`
    // (default). Previously the chip hid when score == 0 to keep
    // idle sessions clean, but the score routinely crosses zero as
    // frame times bucket in/out — users saw it flicker. `stress
    // = false` in config or the right-click "Hide" action drops
    // it entirely; empty bar (score 0) still paints so the slot
    // stays visually anchored.
    if app.config.ui.stress_meter {
        let stress = app.stress_score();
        let (filled, color) = if stress >= 70 {
            (4, theme::cur().red)
        } else if stress >= 40 {
            (3, theme::cur().orange)
        } else if stress >= 20 {
            (2, theme::cur().yellow)
        } else if stress > 0 {
            (1, theme::cur().green)
        } else {
            (0, theme::cur().comment)
        };
        let mut bar = String::from(" ");
        for i in 0..4 {
            bar.push(if i < filled { '\u{2588}' } else { '\u{2591}' });
        }
        bar.push(' ');
        stress_seg_idx = Some(right.len());
        right.push(Seg::new(bar, color, theme::cur().bg2));
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
    let language_seg_idx: Option<usize> = Some(right.len());
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
    app.rects.statusline_mixr_play_chip = to_rect(mixr_play_seg_idx, &right_rects);
    app.rects.statusline_mixr_ffwd_chip = to_rect(mixr_ffwd_seg_idx, &right_rects);
    app.rects.statusline_lsp_chip = to_rect(lsp_seg_idx, &right_rects);
    app.rects.statusline_wrap_chip = to_rect(wrap_seg_idx, &right_rects);
    app.rects.statusline_autosave_chip = to_rect(autosave_seg_idx, &right_rects);
    app.rects.statusline_filesize_chip = to_rect(filesize_seg_idx, &right_rects);
    // Test-runner chip — translate seg index → screen rect like
    // the others above.
    if let Some(idx) = test_seg_idx
        && let Some(&(start, w)) = right_rects.get(idx)
        && w > 0
    {
        app.rects.statusline_test_chip = Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }
    app.rects.statusline_lncol_chip = to_rect(lncol_seg_idx, &right_rects);
    app.rects.statusline_stress_chip = to_rect(stress_seg_idx, &right_rects);
    // Dynamic segment hitrects (both manifest-declared chips and
    // IPC-driven `statusline_set_segment` chips). Cleared + rebuilt
    // per frame. Registered from BOTH lanes; consumer (mouse
    // dispatch / tooltip) doesn't care which side each id
    // originated on. 2026-08-17.
    app.rects.statusline_segment_hits.clear();
    for (seg_idx, id) in &dyn_right_placements {
        if let Some(rect) = to_rect(Some(*seg_idx), &right_rects) {
            app.rects.statusline_segment_hits.push((rect, id.clone()));
        }
    }
    for (seg_idx, id) in &dyn_left_placements {
        // Inline the left-lane translation — `left_to_rect` is
        // declared further down; hitrect registration only needs
        // the same shape (start_col + width → screen Rect).
        let Some(&(start, w)) = left_rects.get(*seg_idx) else {
            continue;
        };
        if w == 0 || (start + w) as u16 > area.width {
            continue;
        }
        app.rects.statusline_segment_hits.push((
            Rect {
                x: area.x + start as u16,
                y: area.y,
                width: w as u16,
                height: 1,
            },
            id.clone(),
        ));
    }
    // AI usage meter chips — same pattern as the others (#876).
    if let Some(idx) = ai_claude_seg_idx
        && let Some(&(start, w)) = right_rects.get(idx)
        && w > 0
    {
        app.rects.statusline_ai_claude_chip = Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }
    if let Some(idx) = ai_codex_seg_idx
        && let Some(&(start, w)) = right_rects.get(idx)
        && w > 0
    {
        app.rects.statusline_ai_codex_chip = Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }
    if let Some(idx) = coverage_seg_idx
        && let Some(&(start, w)) = right_rects.get(idx)
        && w > 0
    {
        app.rects.statusline_coverage_chip = Some(Rect {
            x: right_lane_x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        });
    }

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
    // #polish 2026-07-06 — register the new left-lane chip rects.
    // Helper: single-seg → left-lane screen rect.
    let left_to_rect = |idx_opt: Option<usize>, rects: &[(usize, usize)]| -> Option<Rect> {
        let idx = idx_opt?;
        let &(start, w) = rects.get(idx)?;
        if w == 0 || (start + w) as u16 > area.width {
            return None;
        }
        Some(Rect {
            x: area.x + start as u16,
            y: area.y,
            width: w as u16,
            height: 1,
        })
    };
    // File chip spans the glyph seg + name seg (rendered adjacent). Combine
    // them into one click zone so the pointer can land anywhere on the
    // file line.
    if let (Some(g_idx), Some(n_idx)) = (file_glyph_idx, file_name_idx)
        && let (Some(&(g_start, _)), Some(&(n_start, n_w))) =
            (left_rects.get(g_idx), left_rects.get(n_idx))
    {
        let total_w = (n_start + n_w).saturating_sub(g_start);
        if total_w > 0 && (g_start + total_w) as u16 <= area.width {
            app.rects.statusline_file_chip = Some(Rect {
                x: area.x + g_start as u16,
                y: area.y,
                width: total_w as u16,
                height: 1,
            });
        }
    }
    // Diagnostics chip spans the err seg + warn seg (either or both may
    // be absent). Uses whichever end-points are available.
    let diag_first = diag_err_idx.or(diag_warn_idx);
    let diag_last = diag_warn_idx.or(diag_err_idx);
    if let (Some(first), Some(last)) = (diag_first, diag_last)
        && let (Some(&(first_start, _)), Some(&(last_start, last_w))) =
            (left_rects.get(first), left_rects.get(last))
    {
        let total_w = (last_start + last_w).saturating_sub(first_start);
        if total_w > 0 && (first_start + total_w) as u16 <= area.width {
            app.rects.statusline_diagnostics_chip = Some(Rect {
                x: area.x + first_start as u16,
                y: area.y,
                width: total_w as u16,
                height: 1,
            });
        }
    }
    app.rects.statusline_symbol_chip = left_to_rect(symbol_seg_idx, &left_rects);
    app.rects.statusline_pr_chip = left_to_rect(pr_seg_idx, &left_rects);
    app.rects.statusline_macro_chip = left_to_rect(macro_seg_idx, &left_rects);
    app.rects.statusline_find_chip = left_to_rect(find_seg_idx, &left_rects);
    app.rects.statusline_language_chip = to_rect(language_seg_idx, &right_rects);
    app.rects.statusline_sel_chip = to_rect(sel_seg_idx, &right_rects);
    app.rects.statusline_progress_chip = to_rect(progress_seg_idx, &right_rects);
    app.rects.statusline_bg_tasks_chip = to_rect(bg_tasks_seg_idx, &right_rects);
    app.rects.statusline_ai_chip = to_rect(ai_seg_idx, &right_rects);
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
        for span in s.to_spans() {
            out.push(span);
        }
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
        for span in s.to_spans() {
            out.push(span);
        }
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
            Focus::RightPanel => ("PANEL", theme::cur().cyan),
            Focus::BottomPanel => ("BOTTOM", theme::cur().cyan),
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

/// Task #955 — Coverage chip glyph lookup. Reads the installed
/// `tattle_coverage` integration's glyph from `App::integration_icons`
/// (which merges built-in defaults + manifest overrides + user
/// preferences at load time). Fallback: `U+F437` (nf-oct-graph) —
/// the current default set in `src/marketplace.rs::catalog_lookup`.
/// A future glyph swap only needs to update the integration
/// manifest (`~/.config/mnml/integrations/tattle_coverage.toml`) or
/// the sibling's `install.rs` — the statusline chip picks it up
/// automatically, no more triple-source drift.
fn coverage_glyph(app: &crate::app::App) -> String {
    const FALLBACK: &str = "\u{F437}";
    app.config
        .ui
        .integration_icons
        .iter()
        .find(|ic| ic.id == "tattle_coverage")
        .map(|ic| ic.glyph.clone())
        .filter(|g| !g.is_empty())
        .unwrap_or_else(|| FALLBACK.to_string())
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
