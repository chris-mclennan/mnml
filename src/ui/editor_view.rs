//! The editor pane body: a line-number gutter + the text, with tree-sitter
//! syntax colors, indent guides, current-line highlight, and selection. Renders
//! one leaf into `area`; with splits this is called per leaf. Returns the
//! on-screen cursor cell when `focused`, so `ui::draw` can place the caret.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::git::diff::SignKind;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw_pane(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().bg_dark)),
        area,
    );

    // Optional breadcrumb row at the top — the workspace-relative parent
    // directory of the active file, dim, on its own row. Especially useful
    // with splits (you can tell which pane is which without scanning the
    // bufferline). The filename itself is omitted — it's already on the
    // bufferline tab, no point showing it twice. Workspace-root files
    // (no parent dir) get no breadcrumb row at all — the editor takes
    // the whole `area` there.
    let crumb_label = if app.config.editor.breadcrumb && area.height >= 3 {
        breadcrumb_label(app, pane_id)
    } else {
        None
    };
    let (crumb_area, area) = if crumb_label.is_some() {
        (
            Some(Rect {
                x: area.x,
                y: area.y,
                width: area.width,
                height: 1,
            }),
            Rect {
                x: area.x,
                y: area.y + 1,
                width: area.width,
                height: area.height - 1,
            },
        )
    } else {
        (None, area)
    };
    if let (Some(ca), Some(label)) = (crumb_area, crumb_label) {
        draw_breadcrumb(frame, ca, &label);
    }

    // #polish 2026-07-06 — the `👁 Preview` chip moved to the
    // bufferline (right side, left of the terminal icon).
    // `draw_md_editor_banner` is kept in this file only because
    // there could still be a caller; it's not invoked here.

    let tab_w = app.config.editor.tab_width.max(1);
    let relnum = app.config.ui.relative_line_numbers;
    let show_ws = app.config.ui.show_whitespace;
    // `[ui] color_column = N` paints a subtle marker at column N (1-based).
    // 0 = off. Stored as Option<usize> of the 0-based column index for the
    // per-cell loop below.
    let color_col_idx: Option<usize> = match app.config.ui.color_column {
        0 => None,
        n => Some(n.saturating_sub(1)),
    };
    // Git gutter signs for this file (added/modified/removed lines), from the
    // ~3s-cached `git diff HEAD`. `app.git` / `app.panes` / `app.rects` are
    // disjoint fields, so this borrow coexists with the `&mut Buffer` below.
    let buf_path = match app.panes.get(pane_id) {
        Some(Pane::Editor(b)) => b.path.clone(),
        _ => return None,
    };
    let signs: Option<&Vec<(usize, SignKind)>> = buf_path
        .as_ref()
        .and_then(|p| app.git.snapshot().line_changes.get(p));
    let Some(Pane::Editor(buf)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let line_count = buf.editor.line_count();
    // Gutter = [1 sign cell][line number, right-aligned][1 space], or in blame
    // mode [1 sign cell][`<sha> <author>`, BLAME_W wide][1 space].
    // When `[ui] line_numbers = false` the number column collapses to 0 and
    // we just keep the 1-cell sign column + 1 space.
    const BLAME_W: usize = 22;
    let blame_on = buf.blame.is_some();
    let nums_on = app.config.ui.line_numbers || blame_on;
    let num_w = if !nums_on {
        0
    } else if blame_on {
        BLAME_W
    } else {
        line_count.to_string().len().max(3)
    };
    let gutter_w = (num_w + 2) as u16;
    let text_x = area.x + gutter_w;
    // Reserve three columns on the right edge when there's room: a
    // 1-cell padding (so body text isn't flush against the strip), an
    // inner thin change-density indicator (`▎` glyph per cell, in
    // green/blue/red/yellow based on git signs), and an outer 1-cell
    // scrollbar (track + thumb).
    let want_scrollbar = app.config.ui.scrollbar && area.width >= gutter_w + 4;
    let scrollbar_w: u16 = if want_scrollbar { 1 } else { 0 };
    let change_w: u16 = if want_scrollbar { 1 } else { 0 };
    let pad_w: u16 = if want_scrollbar { 1 } else { 0 };
    let text_w = area
        .width
        .saturating_sub(gutter_w)
        .saturating_sub(scrollbar_w)
        .saturating_sub(change_w)
        .saturating_sub(pad_w);
    let tw = text_w as usize;
    // Horizontal scrollbar — shown when wrap is OFF and some line is
    // wider than the text viewport. Reserves the bottom body row.
    // `max_line_w` is a capped whole-buffer scan (stable as you
    // scroll, cheap for typical files).
    let max_line_w: usize = buf
        .editor
        .text()
        .lines()
        .take(8000)
        .map(|l| l.chars().count())
        .max()
        .unwrap_or(0);
    let want_hscroll = !app.config.ui.wrap && tw > 0 && max_line_w > tw && area.height >= 3;
    let hscroll_h: u16 = if want_hscroll { 1 } else { 0 };
    let text_h = area.height.saturating_sub(hscroll_h) as usize;
    let cur_row_initial = buf.editor.row_col().0;
    // If the cursor landed in a fold's body (e.g. a fold was just toggled
    // while the cursor was mid-block), snap it onto the fold's start line.
    if let Some(owner) = buf.fold_owner_of(cur_row_initial) {
        buf.editor.place_cursor(owner, 0);
    }
    let (cur_row, cur_col) = buf.editor.row_col();

    // `scroll_pinned` is set by mouse wheel / scrollbar drag in viewport-
    // only mode (see `App::cursor_follows_wheel`). It bypasses the keep-
    // cursor-in-view clamps below — the user explicitly chose this
    // scroll. The flag self-clears the moment the cursor moves, because
    // moving the cursor is the unambiguous "I'm taking ownership back"
    // signal. We detect that by comparing this frame's cursor against
    // the snapshot we stored last frame.
    if buf.scroll_pinned {
        match buf.last_render_cursor {
            Some(prev) if prev == (cur_row, cur_col) => {} // unchanged — stay pinned
            _ => buf.scroll_pinned = false,
        }
    }
    buf.last_render_cursor = Some((cur_row, cur_col));

    // Vertical scroll — keep the cursor row in view. With folds, "row" is a
    // file-line index but visible distance is what matters. Snap `scroll` to
    // a visible line first (a fold body would render nothing as the top row).
    if buf.is_line_folded_body(buf.scroll)
        && let Some(snap) = buf.fold_owner_of(buf.scroll)
    {
        buf.scroll = snap;
    }
    // `[ui] scrolloff = N` ⇒ keep the cursor at least N lines from the
    // top / bottom of the viewport (vim canonical). Default 0.
    let scrolloff = app.config.ui.scrolloff.min(text_h.saturating_sub(1) / 2);
    if !buf.scroll_pinned {
        if cur_row < buf.scroll + scrolloff {
            buf.scroll = cur_row.saturating_sub(scrolloff);
        } else {
            let vis_offset = buf.file_to_visible_row(buf.scroll, cur_row);
            let max_offset = text_h.saturating_sub(scrolloff + 1);
            if vis_offset >= max_offset.max(1) {
                // Walk back `text_h - 1 - scrolloff` visible lines from cur_row.
                let target = text_h.saturating_sub(1).saturating_sub(scrolloff);
                let mut walk_back = target;
                let mut line = cur_row;
                while walk_back > 0 && line > 0 {
                    line -= 1;
                    if !buf.is_line_folded_body(line) {
                        walk_back -= 1;
                    }
                }
                buf.scroll = line;
            }
        }
    }
    // Tail clamp — runs even when pinned: never let `scroll` go past the
    // point where the last lines fit on screen. Pure document-bounds
    // guard, not a cursor-related clamp.
    buf.scroll = buf
        .scroll
        .min(line_count.saturating_sub(text_h.min(line_count)));

    // Wrap-aware vertical scroll correction: when wrap is on, the
    // file-line based scroll math above doesn't know that long lines
    // take multiple visual rows. Walk the visual rows from `buf.scroll`
    // and bump `buf.scroll` forward until the cursor's visual offset
    // fits in `text_h`. Pure correction — never moves scroll above
    // what the file-line logic computed. Skipped when pinned.
    if !buf.scroll_pinned && app.config.ui.wrap && tw > 0 && text_h > 0 {
        loop {
            let mut vy: usize = 0;
            let mut line = buf.scroll;
            let mut found = false;
            while line < line_count {
                if line == cur_row {
                    vy += cur_col / tw;
                    found = true;
                    break;
                }
                let h = if buf.is_line_folded_body(line) {
                    0
                } else {
                    buf.editor
                        .line_str(line)
                        .chars()
                        .count()
                        .div_ceil(tw)
                        .max(1)
                };
                vy += h;
                line += 1;
                if vy >= text_h {
                    break;
                }
            }
            if !found || vy >= text_h {
                if buf.scroll >= cur_row {
                    break;
                }
                buf.scroll += 1;
            } else {
                break;
            }
        }
    }

    // Horizontal scroll — keep the cursor column in view. Honors
    // `[ui] sidescrolloff` (vim canonical): keep cursor ≥ N cols from
    // the viewport's left/right edge. Skipped when `[ui] wrap` is on —
    // wrapping eliminates the need for horizontal scroll (and would
    // fight the wrap math), so we force `h_scroll = 0` there.
    let wrap_on = app.config.ui.wrap && tw > 0;
    if wrap_on {
        buf.h_scroll = 0;
    } else if tw > 0 {
        let side = app.config.ui.sidescrolloff.min(tw / 2);
        if cur_col < buf.h_scroll + side {
            buf.h_scroll = cur_col.saturating_sub(side);
        } else if cur_col + side >= buf.h_scroll + tw {
            buf.h_scroll = cur_col + 1 + side - tw;
        }
    }

    let selection = buf.editor.selection();
    // Per-extra-cursor selections (each `(anchor, cursor)` pair where they
    // differ). Used by the per-cell paint to highlight every selection,
    // not just the primary's.
    let extra_selections: Vec<(usize, usize)> = buf
        .editor
        .extra_cursors
        .iter()
        .zip(buf.editor.extra_anchors.iter())
        .filter_map(|(&c, &a_opt)| {
            let a = a_opt?;
            if a == c {
                None
            } else if a < c {
                Some((a, c))
            } else {
                Some((c, a))
            }
        })
        .collect();
    let block_sel = buf.editor.block_selection();
    let sel_bg = theme::cur().base16[0x02];
    let match_bg = theme::cur().bg2;
    let cur_match_bg = theme::cur().yellow;
    let cur_match_idx = buf.find.as_ref().and_then(|f| f.current);
    let guide_fg = theme::cur().base16[0x03];
    // Multi-cursor: precompute extra cursor (row, col) so the per-cell loop
    // can paint a block-style cursor at each.
    let extra_cursor_cells: Vec<(usize, usize)> = buf
        .editor
        .extra_cursors
        .iter()
        .map(|&b| buf.editor.row_col_at(b))
        .collect();
    // Bracket-match highlight: when the cursor sits on a bracket char, find
    // its matching counterpart and remember both positions so the render loop
    // can paint them with a contrasting bg. `None` ⇒ no highlight this frame.
    let bracket_pair: Option<[(usize, usize); 2]> =
        buf.editor.bracket_match().map(|m| [(cur_row, cur_col), m]);
    let bracket_bg = theme::cur().bg3;
    // Optional rainbow brackets: precompute (col, depth) per line for the
    // whole buffer when the config flag is on. Cheap — one walk of the text.
    // The renderer looks up each visible bracket cell's depth and recolors.
    let rainbow_depths: Option<Vec<Vec<(usize, u32)>>> = app
        .config
        .ui
        .bracket_rainbow
        .then(|| crate::editor::bracket_depths_per_line(buf.editor.text()));
    // 6-step palette pulled from the theme. Cycles by `depth % 6`.
    let rainbow_palette: [Color; 6] = [
        theme::cur().yellow,
        theme::cur().purple,
        theme::cur().blue,
        theme::cur().green,
        theme::cur().cyan,
        theme::cur().red,
    ];
    // "Highlight word under cursor" — when on, scan the buffer for every
    // occurrence of the identifier the cursor sits on (whole-word, case-
    // sensitive). Stored as `(byte_start, byte_end)` ranges so the render
    // loop can match cells by their absolute byte offset. Skips the
    // occurrence the cursor itself is in.
    let word_match_ranges: Vec<(usize, usize)> = if app.config.ui.highlight_word_under_cursor {
        let w = buf.editor.word_under_cursor();
        if w.is_empty() {
            Vec::new()
        } else {
            find_word_occurrences(buf.editor.text(), w)
        }
    } else {
        Vec::new()
    };
    let word_match_bg = theme::cur().bg2;
    // TODO/FIXME/HACK/XXX highlights — a buffer-wide scan when the flag's
    // on. Each entry is a (start_byte, end_byte) for the keyword's range.
    // Cheap — single pass over the whole text per render.
    let todo_ranges: Vec<(usize, usize)> = if app.config.ui.highlight_todo_keywords {
        let mut out = Vec::new();
        for kw in ["TODO", "FIXME", "HACK", "XXX"] {
            out.extend(crate::editor::find_whole_word_occurrences(
                buf.editor.text(),
                kw,
            ));
        }
        out
    } else {
        Vec::new()
    };
    let sign_color = |k: SignKind| match k {
        SignKind::Added => theme::cur().green,
        SignKind::Modified => theme::cur().blue,
        SignKind::Removed => theme::cur().red,
    };
    let diag_color = |s: crate::lsp::Severity| match s {
        crate::lsp::Severity::Error => theme::cur().red,
        crate::lsp::Severity::Warning => theme::cur().yellow,
        crate::lsp::Severity::Info => theme::cur().cyan,
        crate::lsp::Severity::Hint => theme::cur().comment,
    };

    let mut lines: Vec<Line> = Vec::with_capacity(text_h);
    // Collected fold-chip rects (visual row + file line) — pushed onto
    // `app.rects.fold_chips` after the `buf` borrow ends. Lets the click
    // handler find which fold to unfold.
    let mut chip_rects: Vec<(u16, usize)> = Vec::new();
    // Collected code-lens chip rects — `(visual_row, start_vc, end_vc,
    // lens_index)` per painted lens. Each `lens_index` is the position in
    // `Buffer.code_lenses`. Pushed onto `app.rects.code_lens_chips` after
    // the `buf` borrow ends. Lets the click handler dispatch the lens'
    // `workspace/executeCommand`.
    let mut lens_chip_rects: Vec<(u16, usize, usize, usize)> = Vec::new();
    // Per-row gutter mark hits — `(visual_row, line_no, kind)`.
    // Pushed onto `app.rects.gutter_marks` after the borrow ends so
    // the hover-tooltip layer can point-in-rect the sign column.
    // Continuation rows + blank sign cells are skipped.
    let mut gutter_mark_rows: Vec<(u16, usize, crate::GutterMarkKind)> = Vec::new();
    // VS Code-style fold-arrow cells — `(visual_row, line_no)`.
    // Pushed to `app.rects.fold_arrows` after the borrow ends.
    // 2026-07-11.
    let mut fold_arrow_rows: Vec<(u16, usize)> = Vec::new();
    // Build the per-visual-row plan: each entry is (line_no, char_start,
    // is_continuation). With wrap off, every file-line takes exactly one
    // visual row; with wrap on, long lines emit multiple rows where each
    // continuation reuses the same `line_no` with `char_start` advancing
    // by `tw` and `is_continuation = true`.
    struct VisRow {
        line_no: usize,
        char_start: usize,
        is_continuation: bool,
    }
    let mut vis_rows: Vec<VisRow> = Vec::with_capacity(text_h);
    let mut walk_line = buf.next_visible_line(buf.scroll).unwrap_or(line_count);
    while vis_rows.len() < text_h && walk_line < line_count {
        let chunks = if wrap_on {
            let nchars = buf.editor.line_str(walk_line).chars().count();
            nchars.div_ceil(tw.max(1)).max(1)
        } else {
            1
        };
        for chunk in 0..chunks {
            if vis_rows.len() >= text_h {
                break;
            }
            vis_rows.push(VisRow {
                line_no: walk_line,
                char_start: chunk * tw,
                is_continuation: chunk > 0,
            });
        }
        walk_line = buf.next_visible_line(walk_line + 1).unwrap_or(line_count);
    }
    while vis_rows.len() < text_h {
        vis_rows.push(VisRow {
            line_no: line_count,
            char_start: 0,
            is_continuation: false,
        });
    }

    for (r, vis_row) in vis_rows.iter().enumerate() {
        let line_no = vis_row.line_no;
        let view_col_start = vis_row.char_start;
        let is_continuation = vis_row.is_continuation;
        if line_no >= line_count {
            lines.push(Line::from(Span::styled(
                " ".repeat(area.width as usize),
                Style::default().bg(theme::cur().bg_dark),
            )));
            continue;
        }
        let is_cur = line_no == cur_row;
        let base_bg = if is_cur && app.config.ui.cursor_line {
            // Stronger tint when `[ui] cursor_line = true` (vim's
            // `:set cursorline`). Theme's `line` is the canonical color.
            theme::cur().line
        } else {
            theme::cur().bg_dark
        };
        let num_gutter = if is_continuation {
            // Continuation rows of a wrapped line — show `↪` glyph
            // (or `~` in ASCII mode) so users can tell it's the
            // same file line as the row above, not a separate line.
            // #polish 2026-07-06 — was blank; visually indistinct
            // from a real short line above it.
            let glyph = if app.config.ui.ascii_icons {
                "~"
            } else {
                "\u{21AA}"
            };
            let pad = num_w.saturating_sub(1);
            format!("{}{glyph} ", " ".repeat(pad))
        } else if blame_on {
            match buf.blame.as_ref().and_then(|v| v.get(line_no)) {
                Some(bl) => format!("{} ", bl.label(num_w)),
                None => format!("{} ", " ".repeat(num_w)),
            }
        } else if relnum && !is_cur {
            format!("{:>num_w$} ", line_no.abs_diff(cur_row))
        } else {
            format!("{:>num_w$} ", line_no + 1)
        };
        // Worst LSP + linter diagnostic severity touching this line (if any).
        let diag_sev: Option<crate::lsp::Severity> = buf
            .all_diagnostics()
            .filter(|d| {
                (d.range.start.line as usize) <= line_no && line_no <= (d.range.end.line as usize)
            })
            .map(|d| d.severity)
            .min_by_key(|s| match s {
                crate::lsp::Severity::Error => 0u8,
                crate::lsp::Severity::Warning => 1,
                crate::lsp::Severity::Info => 2,
                crate::lsp::Severity::Hint => 3,
            });
        let num_style = Style::default()
            .fg(if blame_on {
                if is_cur {
                    theme::cur().grey_fg
                } else {
                    theme::cur().comment
                }
            } else if let Some(s) = diag_sev {
                diag_color(s)
            } else if is_cur {
                theme::cur().fg
            } else {
                theme::cur().base16[0x03]
            })
            .bg(base_bg);
        // The 1-cell sign column: a DAP execution arrow wins (yellow `▶`),
        // then a breakpoint dot (red), then an LSP diagnostic severity
        // dot, then the git change mark.
        let has_bp = buf.has_breakpoint(line_no as u32);
        let has_cond_bp = has_bp && buf.breakpoint_conditions.contains_key(&(line_no as u32));
        let has_arrow = matches!(
            app.dap_arrow.as_ref(),
            Some((p, l)) if buf.path.as_deref() == Some(p) && (*l as usize) == line_no
        );
        let sign = signs.and_then(|v| {
            v.binary_search_by_key(&line_no, |&(l, _)| l)
                .ok()
                .map(|i| v[i].1)
        });
        // Sign column priority: continuation row → debug-arrow → breakpoint
        // → error/warning diagnostic → git change → info/hint diagnostic →
        // empty. Info+hint defer to git changes so a buffer full of hint
        // squiggles doesn't hide which lines were edited (the user's
        // real signal for "what's uncommitted").
        let hi_diag = diag_sev.filter(|s| {
            matches!(
                s,
                crate::lsp::Severity::Error | crate::lsp::Severity::Warning
            )
        });
        let lo_diag = diag_sev
            .filter(|s| matches!(s, crate::lsp::Severity::Info | crate::lsp::Severity::Hint));
        let mut mark_kind: Option<crate::GutterMarkKind> = None;
        // Fold state — computed up front so it can (a) always emit a
        // click rect regardless of which sign wins the paint and
        // (b) override lower-priority signs when the line is folded.
        // design-critic 2026-07-11 (HIGH): previously the arrow only
        // appeared when the sign column was empty — a folded line
        // with an uncommitted git change (very common) never showed
        // the arrow AND had no click rect, so unfolding was
        // impossible via mouse.
        let is_folded_line = buf.folds.contains_key(&line_no);
        let is_hovered_line = matches!(
            app.hover_editor_line,
            Some((hp, hl)) if hp == pane_id && hl == line_no
        );
        // mouse-round-8 SEV-2 2026-07-12 — when the always-show
        // config is on, treat every foldable header as "as if
        // hovered" so a persistent dim arrow sits in the gutter
        // and the click rect is always registered.
        let always_show = app.config.ui.always_show_fold_arrows;
        let is_foldable_line = !is_folded_line
            && (is_hovered_line || always_show)
            && is_foldable_header(buf.editor.line_str(line_no));
        let is_foldable_hover = is_foldable_line;
        if is_folded_line || is_foldable_line {
            fold_arrow_rows.push((r as u16, line_no));
        }
        let sign_span = if is_continuation {
            Span::styled(" ", Style::default().bg(base_bg))
        } else if has_arrow {
            mark_kind = Some(crate::GutterMarkKind::DapArrow);
            Span::styled("▶", Style::default().fg(theme::cur().yellow).bg(base_bg))
        } else if has_cond_bp {
            // Conditional breakpoints render as a diamond so the user
            // can see at a glance which stops are gated by a condition.
            mark_kind = Some(crate::GutterMarkKind::ConditionalBreakpoint);
            Span::styled("◆", Style::default().fg(theme::cur().red).bg(base_bg))
        } else if has_bp {
            mark_kind = Some(crate::GutterMarkKind::Breakpoint);
            Span::styled("●", Style::default().fg(theme::cur().red).bg(base_bg))
        } else if is_folded_line {
            // Folded state is critical navigation info — override
            // anything below breakpoint priority so it's ALWAYS
            // visible. Higher-priority marks (DAP arrow, breakpoint)
            // still win — folded lines are rare mid-debug, and if
            // both apply, the `⋯ N hidden` chip past EOL still
            // signals the fold.
            // 2026-07-12 user feedback — the `▸` / `▾` unicode
            // triangles read as tiny in the gutter. Swap to the
            // codicon chevrons already verified working in the tree
            // header + palette dropdown for visual continuity
            // (chevron-down for expanded, chevron-right for folded).
            let glyph = if app.config.ui.ascii_icons {
                ">"
            } else {
                "▶" // U+25B6 — Nerd Font chevrons rendered as tofu (see tree_view.rs)
            };
            Span::styled(glyph, Style::default().fg(theme::cur().purple).bg(base_bg))
        } else if let Some(s) = hi_diag {
            mark_kind = Some(crate::GutterMarkKind::Diagnostic(s));
            Span::styled("●", Style::default().fg(diag_color(s)).bg(base_bg))
        } else if let Some(k) = sign {
            mark_kind = Some(crate::GutterMarkKind::GitChange(k));
            Span::styled("▎", Style::default().fg(sign_color(k)).bg(base_bg))
        } else if let Some(s) = lo_diag {
            mark_kind = Some(crate::GutterMarkKind::Diagnostic(s));
            Span::styled("●", Style::default().fg(diag_color(s)).bg(base_bg))
        } else if is_foldable_hover {
            // Same codicon chevron as the folded state for visual
            // continuity — expanded uses chevron-down. 2026-07-12
            // user feedback (see the fold-arrow comment above).
            let glyph = if app.config.ui.ascii_icons {
                "v"
            } else {
                "▼" // U+25BC — matches the tree section chevrons
            };
            Span::styled(glyph, Style::default().fg(theme::cur().comment).bg(base_bg))
        } else {
            Span::styled(" ", Style::default().bg(base_bg))
        };
        if let Some(k) = mark_kind {
            gutter_mark_rows.push((r as u16, line_no, k));
        }

        // Word-match ranges (in char cols) on this line, converted from the
        // pre-computed buffer-wide byte ranges. Same shape as the find-match
        // list; non-cursor cells in these ranges get a subtle bg tint.
        let (ls, le) = buf.editor.line_byte_range(line_no);
        let word_matches_on_line: Vec<(usize, usize)> = word_match_ranges
            .iter()
            .filter(|(s, e)| *s >= ls && *e <= le)
            .map(|(s, e)| (buf.editor.byte_to_col(*s), buf.editor.byte_to_col(*e)))
            .collect();
        // TODO/FIXME keyword ranges on this line (in char cols).
        let todo_on_line: Vec<(usize, usize)> = todo_ranges
            .iter()
            .filter(|(s, e)| *s >= ls && *e <= le)
            .map(|(s, e)| (buf.editor.byte_to_col(*s), buf.editor.byte_to_col(*e)))
            .collect();
        // LSP document-highlight ranges on this line (`(start_col, end_col)`).
        // We trust the server to give us single-line ranges (multi-line were
        // dropped at parse time).
        let doc_highlights_on_line: Vec<(usize, usize)> = buf
            .document_highlights
            .iter()
            .filter(|(l, _, el, _)| (*l as usize) == line_no && (*el as usize) == line_no)
            .map(|&(_, s, _, e)| (s as usize, e as usize))
            .collect();
        let (sel_lo, sel_hi, extend_eol) = match selection {
            Some((lo, hi)) if hi > ls && lo <= le => (
                buf.editor.byte_to_col(lo.clamp(ls, le)),
                buf.editor.byte_to_col(hi.clamp(ls, le)),
                hi > le,
            ),
            _ => (0, 0, false),
        };
        // Per-extra-cursor selections that touch this line, converted to
        // char-column ranges. Each entry is `(col_lo, col_hi, extend_eol)`.
        let extra_line_sels: Vec<(usize, usize, bool)> = extra_selections
            .iter()
            .filter_map(|&(lo, hi)| {
                if hi <= ls || lo > le {
                    return None;
                }
                Some((
                    buf.editor.byte_to_col(lo.clamp(ls, le)),
                    buf.editor.byte_to_col(hi.clamp(ls, le)),
                    hi > le,
                ))
            })
            .collect();

        // Find-match ranges (in char columns) on this line — assumes single-line
        // matches (the find prompt is single-line, so queries can't contain '\n').
        let line_matches: Vec<(usize, usize, bool)> = buf
            .find
            .as_ref()
            .map(|f| {
                f.matches
                    .iter()
                    .enumerate()
                    .filter(|(_, (s, e))| *s >= ls && *e <= le)
                    .map(|(i, (s, e))| {
                        (
                            buf.editor.byte_to_col(*s),
                            buf.editor.byte_to_col(*e),
                            cur_match_idx == Some(i),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();

        let raw = buf.editor.line_str(line_no);
        let chars: Vec<char> = raw.chars().collect();
        let n = chars.len();
        let indent_cols = chars.iter().take_while(|c| **c == ' ').count();
        let has_content = indent_cols < n;
        let spans_for_line: &[crate::highlight::ColoredSpan] = if app.config.ui.syntax {
            buf.line_spans(line_no)
        } else {
            &[]
        };
        // Project semantic tokens to just this line (sorted by
        // start_char) so the per-cell loop below can binary-search
        // instead of linear-scanning the whole buffer's token list.
        // Empty for buffers without an LSP attached — the per-cell
        // lookup short-circuits on an empty slice.
        let line_sem_tokens = if buf.semantic_tokens.is_empty() {
            Vec::new()
        } else {
            tokens_for_line(&buf.semantic_tokens, line_no)
        };
        // Bake the tree-sitter span list into a per-cell color grid
        // once per row, so the per-cell loop below indexes O(1) into
        // it instead of doing a reverse linear scan over every span.
        // Worth ~5-10x on Rust files with many small identifier spans
        // per line (typical 50-80 spans on a dense line).
        let line_color_grid = line_color_grid(spans_for_line, n);
        // When `highlight_trailing_ws` is on, find where the trailing-ws run
        // begins. `None` ⇒ no trailing ws on this line (or a blank line —
        // we don't highlight pure-whitespace lines since the user isn't
        // looking at "stray" trailing space, just intentional indentation).
        let trailing_start = if app.config.ui.highlight_trailing_ws && has_content {
            let mut idx = n;
            while idx > 0 && matches!(chars.get(idx - 1), Some(' ') | Some('\t')) {
                idx -= 1;
            }
            if idx < n { Some(idx) } else { None }
        } else {
            None
        };

        // Per-visible-cell (char, fg, bg, modifier), then coalesce into
        // spans. The modifier carries BOLD / DIM / ITALIC / CROSSED_OUT
        // bits from LSP semantic-token modifiers (`static` / `defaultLibrary`
        // / `readonly` / `deprecated`) so deprecated APIs render with a
        // strikethrough, stdlib symbols dim, etc.
        let mut cells: Vec<(char, Color, Color, ratatui::style::Modifier)> = Vec::with_capacity(tw);
        for vc in 0..tw {
            let c = view_col_start + vc;
            let in_sel = (sel_hi > sel_lo && c >= sel_lo && c < sel_hi)
                || (extend_eol && c >= sel_lo)
                || extra_line_sels
                    .iter()
                    .any(|&(lo, hi, eol)| (hi > lo && c >= lo && c < hi) || (eol && c >= lo));
            // Visual-block rectangle: highlight every cell where row is in
            // [rmin..=rmax] and col in [cmin..=cmax], regardless of whether
            // the line actually has text at that column (vim convention —
            // rectangle paints over EOL too).
            let in_block = block_sel
                .map(|(rmin, cmin, rmax, cmax)| {
                    line_no >= rmin && line_no <= rmax && c >= cmin && c <= cmax
                })
                .unwrap_or(false);
            let in_match = line_matches
                .iter()
                .find(|(s, e, _)| c >= *s && c < *e)
                .map(|(_, _, cur)| *cur);
            let is_bracket = bracket_pair
                .as_ref()
                .map(|pair| pair.iter().any(|&(l, k)| l == line_no && k == c))
                .unwrap_or(false);
            let is_trailing = trailing_start.is_some_and(|s| c >= s && c < n);
            // "Other occurrence of the word under the cursor" — skip the
            // range the cursor itself sits in (no point highlighting that one).
            let in_word_match = word_matches_on_line.iter().any(|&(s, e)| {
                c >= s && c < e && !(line_no == cur_row && cur_col >= s && cur_col < e)
            });
            let in_doc_highlight = doc_highlights_on_line.iter().any(|&(s, e)| c >= s && c < e);
            let is_color_col = color_col_idx == Some(c);
            let is_extra_cursor = extra_cursor_cells
                .iter()
                .any(|&(r, cc)| r == line_no && cc == c);
            let bg = if is_extra_cursor {
                // Paint the extra cursor as a bright block — easy to spot
                // and visually distinct from the primary cursor (which
                // ratatui sets via the terminal cursor).
                theme::cur().fg
            } else if in_sel || in_block {
                sel_bg
            } else if is_bracket {
                bracket_bg
            } else if is_trailing {
                // Strong red bg so the user can't miss it. Selection / find
                // matches still win above so a selection over trailing ws
                // doesn't look broken.
                theme::cur().red
            } else {
                match in_match {
                    Some(true) => cur_match_bg,
                    Some(false) => match_bg,
                    None => {
                        if in_word_match || in_doc_highlight {
                            word_match_bg
                        } else if is_color_col {
                            // `[ui] color_column = N` — subtle line-length
                            // marker. Lowest priority so it doesn't override
                            // selection / find / cursor-line tints.
                            theme::cur().bg2
                        } else {
                            base_bg
                        }
                    }
                }
            };
            let (ch, mut fg, mut style_mod) = if c < n {
                let raw_ch = chars[c];
                if raw_ch == ' '
                    && has_content
                    && c >= tab_w
                    && c.is_multiple_of(tab_w)
                    && c < indent_cols
                {
                    ('│', guide_fg, ratatui::style::Modifier::empty())
                } else if show_ws && raw_ch == ' ' {
                    ('·', guide_fg, ratatui::style::Modifier::empty())
                } else if show_ws && raw_ch == '\t' {
                    ('→', guide_fg, ratatui::style::Modifier::empty())
                } else {
                    // LSP semantic tokens win over tree-sitter at overlapping
                    // cells (per LSP convention — server has more context
                    // than a pure syntactic grammar). When LSP doesn't cover
                    // this cell, fall back to tree-sitter; if both empty,
                    // use the theme foreground. Semantic tokens may carry
                    // a modifier-bitmask style (DIM / BOLD / ITALIC / etc.).
                    let (fg, sem_mod) = match semantic_style(&line_sem_tokens, c) {
                        Some((c, m)) => (c, m),
                        None => (
                            // O(1) grid lookup; falls back to the
                            // original linear-scan helper for cells
                            // past the grid (shouldn't happen in
                            // practice — `n` covers the line).
                            line_color_grid
                                .get(c)
                                .and_then(|x| *x)
                                .or_else(|| syntax_color(spans_for_line, c))
                                .unwrap_or(theme::cur().fg),
                            ratatui::style::Modifier::empty(),
                        ),
                    };
                    (raw_ch, fg, sem_mod)
                }
            } else if show_ws && c == n {
                // `:set list` end-of-line marker (vim canonical `$`). Paint
                // it in the same dim guide color as the other whitespace
                // glyphs so it doesn't shout.
                ('$', guide_fg, ratatui::style::Modifier::empty())
            } else {
                (' ', theme::cur().fg, ratatui::style::Modifier::empty())
            };
            // Rainbow-brackets override: when enabled and this cell holds a
            // `()[]{}`, recolor it from the depth-cycling palette. Beats the
            // syntax-highlight color (the whole point is to see nesting).
            if let Some(table) = rainbow_depths.as_ref()
                && matches!(ch, '(' | ')' | '[' | ']' | '{' | '}')
                && let Some(row_entries) = table.get(line_no)
                && let Some(&(_, depth)) = row_entries.iter().find(|&&(col, _)| col == c)
            {
                fg = rainbow_palette[(depth as usize) % rainbow_palette.len()];
                style_mod = ratatui::style::Modifier::empty();
            }
            // The "current" find match: force dark fg so it stays readable on
            // the bright bg.
            if matches!(in_match, Some(true)) {
                fg = theme::cur().bg_dark;
            }
            // Extra-cursor cells: invert fg so the char stays readable on
            // the bright bg.
            if is_extra_cursor {
                fg = theme::cur().bg_dark;
            }
            // TODO/FIXME/HACK/XXX — force a bright red fg so the keywords
            // pop. Applied after rainbow/syntax so it wins. Cells in
            // selection / cursor-line still keep their bg.
            if todo_on_line.iter().any(|&(s, e)| c >= s && c < e) {
                fg = theme::cur().red;
                style_mod = ratatui::style::Modifier::empty();
            }
            cells.push((ch, fg, bg, style_mod));
        }

        // Fold marker — painted into the trailing space cells of a fold's
        // start line (`  ⋯ N hidden`). Same "overlay into trailing space"
        // approach as the inline-diagnostic chip below.
        if let Some(&end_line) = buf.folds.get(&line_no) {
            let hidden = end_line.saturating_sub(line_no);
            let chip = format!("  ⋯ {hidden} hidden");
            let start_c = n + 2;
            let mcolor = theme::cur().purple;
            for (i, mc) in chip.chars().enumerate() {
                let c = start_c + i;
                if c < view_col_start {
                    continue;
                }
                let vc = c - view_col_start;
                if vc >= cells.len() {
                    break;
                }
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, mcolor, base_bg, ratatui::style::Modifier::empty());
                }
            }
            // Remember the rect so click-to-unfold can find this fold.
            chip_rects.push((r as u16, line_no));
        }

        // Inline diagnostic: when this line has an LSP error/warning, overlay
        // the first non-empty message line in dim severity color starting two
        // cells past the line's content. Only paints into trailing space
        // cells (won't clobber actual code or selection bg).
        if let Some(sev) = diag_sev
            && let Some(msg) = buf
                .all_diagnostics()
                .find(|d| (d.range.start.line as usize) == line_no)
                .and_then(|d| {
                    d.message
                        .lines()
                        .map(str::trim)
                        .find(|l| !l.is_empty())
                        .map(str::to_string)
                })
        {
            let start_c = n + 2;
            let dcolor = diag_color(sev);
            for (i, mc) in msg.chars().enumerate() {
                let c = start_c + i;
                if c < view_col_start {
                    continue;
                }
                let vc = c - view_col_start;
                if vc >= cells.len() {
                    break;
                }
                // Only paint where the line's natural content ended (a space
                // cell with the line bg) — never over selection / find-match.
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, dcolor, base_bg, ratatui::style::Modifier::empty());
                }
            }
        }

        // Color decorations: server-supplied `(start_char, end_char, rgb)`
        // for each color literal on this line. We override the foreground
        // color of every cell in the literal's char range so the value
        // renders in its own color (so `#ff0000` literally looks red).
        for cd in buf.color_decorations.iter() {
            if cd.line as usize != line_no {
                continue;
            }
            let fg = Color::Rgb(
                ((cd.rgb >> 16) & 0xff) as u8,
                ((cd.rgb >> 8) & 0xff) as u8,
                (cd.rgb & 0xff) as u8,
            );
            for cc in cd.start_char..cd.end_char {
                let c = n + (cc as usize);
                if c < view_col_start {
                    continue;
                }
                let vc = c - view_col_start;
                if vc >= cells.len() {
                    break;
                }
                cells[vc].1 = fg;
            }
        }

        // Inlay hints: collect every hint on this line, sort by
        // column, join with a single-space separator, and paint
        // just past the code's end. Painting at hint.character
        // directly corrupts the visible line whenever a hint's
        // slot lands on real code (partial writes into gaps between
        // tokens splice the label into the identifier). Trade
        // strict VS Code adjacency for a clean end-of-line strip
        // that never damages code cells.
        // 2026-07-12 iterations — earlier MVP joined with "  ",
        // then a hint.character-aware pass mangled tokens; back to
        // end-of-line but with tighter packing (single space
        // lead, single space between hints) and column-sorted so
        // hints appear in file order.
        let hints_on_line: Vec<&crate::lsp::InlayHint> = if app.config.editor.inlay_hints {
            let mut v: Vec<&crate::lsp::InlayHint> = buf
                .inlay_hints
                .iter()
                .filter(|h| (h.line as usize) == line_no)
                .collect();
            v.sort_by_key(|h| h.character);
            v
        } else {
            Vec::new()
        };
        if !hints_on_line.is_empty() {
            // Separate hints with ` · ` (middle dot) instead of a
            // single space — some labels carry their own leading
            // punctuation (`: void`, `: string`) and a bare-space
            // separator against `param:` gave a visually-double
            // space at the seam (`param:  : void`). The middot is
            // a clean punctuation-agnostic delimiter. 2026-07-12.
            let chip = hints_on_line
                .iter()
                .map(|h| h.label.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" · ");
            let with_lead = format!(" {chip}");
            let start_c = n + 1;
            let hcolor = theme::cur().comment;
            for (i, mc) in with_lead.chars().enumerate() {
                let c = start_c + i;
                if c < view_col_start {
                    continue;
                }
                let vc = c - view_col_start;
                if vc >= cells.len() {
                    break;
                }
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, hcolor, base_bg, ratatui::style::Modifier::empty());
                }
            }
        }

        // Code lenses: paint as dim chips at end-of-line in a slightly
        // different color (purple) so they're distinguishable from
        // inlay hints. Same "overlay into trailing space" approach.
        //
        // Each lens gets its own rect tracked in `lens_chip_rects` so the
        // mouse handler can route clicks to the right command. The space
        // separator between lenses is kept inside the rect (1-cell-wide
        // hit zone past the title) — feels natural since the eye sees the
        // whole `<title> | ` as one chip.
        let lenses_on_line: Vec<(usize, &crate::lsp::CodeLens)> = if app.config.editor.code_lens {
            buf.code_lenses
                .iter()
                .enumerate()
                .filter(|(_, l)| (l.line as usize) == line_no)
                .collect()
        } else {
            Vec::new()
        };
        if !lenses_on_line.is_empty() {
            let start_c = n + 2;
            let lcolor = theme::cur().purple;
            // Lead `  ⚡ ` (4 chars) is uniform across all lenses on this line.
            let lead = "  ⚡ ";
            let mut col = start_c;
            // Paint lead
            for mc in lead.chars() {
                if col >= view_col_start {
                    let vc = col - view_col_start;
                    if vc >= cells.len() {
                        break;
                    }
                    if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                        cells[vc] = (mc, lcolor, base_bg, ratatui::style::Modifier::empty());
                    }
                }
                col += 1;
            }
            // Paint each lens; record its rect; emit ` | ` separator before
            // every non-first lens (rolled into the prior lens's rect so
            // clicks on the separator still route somewhere). Rect bounds
            // are stored in cells[] index space (vc) so screen-x conversion
            // is a simple `text_x + vc` below.
            for (i, (lens_idx, lens)) in lenses_on_line.iter().enumerate() {
                let title = lens.title.trim();
                if title.is_empty() {
                    continue;
                }
                let prefix = if i > 0 { " | " } else { "" };
                // Convert `col` (line-char column) to cell index `vc`. Clamp
                // to 0 when the chip's start is left-of-visible (h-scrolled
                // past) so the rect still covers the on-screen portion.
                let rect_start_vc = col.saturating_sub(view_col_start);
                for mc in prefix.chars().chain(title.chars()) {
                    if col >= view_col_start {
                        let vc = col - view_col_start;
                        if vc >= cells.len() {
                            break;
                        }
                        if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                            cells[vc] = (mc, lcolor, base_bg, ratatui::style::Modifier::empty());
                        }
                    }
                    col += 1;
                }
                let rect_end_vc = (col.saturating_sub(view_col_start)).min(cells.len());
                if rect_end_vc > rect_start_vc {
                    lens_chip_rects.push((r as u16, rect_start_vc, rect_end_vc, *lens_idx));
                }
            }
        }

        let mut spans: Vec<Span> = vec![sign_span, Span::styled(num_gutter, num_style)];
        let mut i = 0;
        while i < cells.len() {
            let (_, fg, bg, m) = cells[i];
            let mut s = String::new();
            while i < cells.len() && cells[i].1 == fg && cells[i].2 == bg && cells[i].3 == m {
                s.push(cells[i].0);
                i += 1;
            }
            let mut style = Style::default().fg(fg).bg(bg);
            if !m.is_empty() {
                style = style.add_modifier(m);
            }
            spans.push(Span::styled(s, style));
        }
        lines.push(Line::from(spans));
    }
    // Sticky scroll: when a fold's body extends past the top of the
    // viewport, paint that fold's start line as a sticky header in row 0.
    // Heuristic — only "real" overlap (fold actually started above).
    // Picks the smallest such fold (closest enclosing).
    if !buf.folds.is_empty() {
        let scroll = buf.scroll;
        let mut sticky: Option<(usize, usize)> = None; // (size, start_line)
        for (&start, &end) in &buf.folds {
            if start < scroll && end >= scroll {
                let size = end - start;
                if sticky.is_none_or(|(s, _)| size < s) {
                    sticky = Some((size, start));
                }
            }
        }
        if let Some((_, start_line)) = sticky
            && let Some(line) = lines.first_mut()
        {
            let raw = buf.editor.line_str(start_line).to_string();
            let pad: String = " ".repeat(area.width as usize);
            let txt = format!("{raw}{pad}");
            let txt: String = txt.chars().take(area.width as usize).collect();
            let t = theme::cur();
            let style = Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(ratatui::style::Modifier::BOLD);
            *line = Line::from(Span::styled(txt, style));
        }
    }
    // Treesitter-context — when `[ui] sticky_context` is on, paint the
    // chain of enclosing scopes (function → class → method → …) that
    // contain the cursor's row but whose header is ABOVE the viewport.
    // Capped at 3 rows so the editor doesn't lose too much real estate.
    // Reuses `regex_outline::extract_symbols` so it covers rust/py/js/ts/
    // go/rb/c/cpp without an LSP. Other languages: no chain ⇒ no paint.
    if app.config.ui.sticky_context
        && let Some(ext) = buf.language_ext.as_deref()
    {
        let symbols = crate::regex_outline::extract_symbols(buf.editor.text(), ext);
        if !symbols.is_empty() {
            // Build the enclosing chain by walking symbols in source order
            // and maintaining a depth-monotonic stack. A symbol `s` enters
            // the chain when its line precedes the cursor; any symbol of
            // equal-or-greater depth than `s.depth` already on top of the
            // stack is popped first (since they're no longer enclosing).
            let cur_line = buf.editor.row_col().0 as u32;
            let scroll = buf.scroll as u32;
            let mut stack: Vec<&crate::lsp::DocumentSymbol> = Vec::new();
            for s in &symbols {
                if s.line > cur_line {
                    break;
                }
                while stack.last().is_some_and(|top| top.depth >= s.depth) {
                    stack.pop();
                }
                stack.push(s);
            }
            // Only include symbols whose header is ABOVE the viewport —
            // otherwise the user can already see it.
            let chain: Vec<&crate::lsp::DocumentSymbol> =
                stack.into_iter().filter(|s| s.line < scroll).collect();
            const MAX_ROWS: usize = 3;
            let rows = chain.len().min(MAX_ROWS).min(lines.len());
            if rows > 0 {
                let t = theme::cur();
                // Skip the outermost when over-the-cap so the closest
                // enclosing scope is always shown.
                let start = chain.len().saturating_sub(rows);
                for (i, sym) in chain.iter().skip(start).enumerate() {
                    if let Some(line) = lines.get_mut(i) {
                        let raw = buf.editor.line_str(sym.line as usize).to_string();
                        let pad: String = " ".repeat(area.width as usize);
                        let txt = format!("{raw}{pad}");
                        let txt: String = txt.chars().take(area.width as usize).collect();
                        let style = Style::default()
                            .fg(t.fg)
                            .bg(t.bg2)
                            .add_modifier(ratatui::style::Modifier::BOLD);
                        *line = Line::from(Span::styled(txt, style));
                    }
                }
            }
        }
    }
    frame.render_widget(Paragraph::new(lines), area);

    // Horizontal scrollbar — bottom row, spanning the text area (not the
    // gutter / vertical-scrollbar columns). Draggable via the same
    // ScrollbarHit machinery, tagged `EditorHScroll` so the dispatcher
    // maps the X axis.
    if want_hscroll && text_w > 0 {
        let t = theme::cur();
        let hbar = ratatui::layout::Rect {
            x: text_x,
            y: area.y + area.height - 1,
            width: text_w,
            height: 1,
        };
        crate::ui::scrollbar::paint_horizontal_scrollbar(
            frame,
            hbar,
            &t,
            max_line_w,
            tw,
            buf.h_scroll,
        );
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: hbar,
            pane_id,
            total: max_line_w,
            viewport: tw,
            kind: crate::app::ScrollbarKind::EditorHScroll,
        });
    }

    if want_scrollbar && text_h > 0 {
        let bar_x = area.x + area.width - 1;
        let change_x = bar_x - change_w;
        let t = theme::cur();
        // Register the scrollbar rect for click + drag routing
        // (jump-to-position + grab-and-scroll).
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: ratatui::layout::Rect {
                x: bar_x,
                y: area.y,
                width: 1,
                height: text_h as u16,
            },
            pane_id,
            total: line_count,
            viewport: text_h,
            kind: crate::app::ScrollbarKind::Editor,
        });
        // ── Change-density strip (inner col, left of the scrollbar) ──
        // One thin `▏` glyph per cell, fg = green / blue / red / yellow
        // based on the git sign mix in that file-row range. Blank when
        // no changes fall in the range.
        if change_w > 0 {
            for r in 0..text_h {
                let color = signs.filter(|v| !v.is_empty()).and_then(|signs| {
                    let lo = r * line_count / text_h;
                    let hi = ((r + 1) * line_count / text_h).max(lo + 1).min(line_count);
                    let mut has_added = false;
                    let mut has_modified = false;
                    let mut has_removed = false;
                    for &(ln, k) in signs.iter() {
                        if ln >= lo && ln < hi {
                            match k {
                                SignKind::Added => has_added = true,
                                SignKind::Modified => has_modified = true,
                                SignKind::Removed => has_removed = true,
                            }
                        }
                    }
                    match (has_added, has_modified, has_removed) {
                        (false, false, false) => None,
                        (true, false, false) => Some(t.green),
                        (false, true, false) => Some(t.blue),
                        (false, false, true) => Some(t.red),
                        _ => Some(t.yellow),
                    }
                });
                let (glyph, style) = if let Some(c) = color {
                    ("▎", Style::default().fg(c).bg(t.bg_dark))
                } else {
                    (" ", Style::default().bg(t.bg_dark))
                };
                frame.render_widget(
                    Paragraph::new(glyph).style(style),
                    Rect {
                        x: change_x,
                        y: area.y + r as u16,
                        width: 1,
                        height: 1,
                    },
                );
            }
        }
        // ── Scrollbar (outer col) ──
        // Track: bg2 across the column.
        for r in 0..text_h {
            frame.render_widget(
                Paragraph::new(" ").style(Style::default().bg(t.bg2)),
                Rect {
                    x: bar_x,
                    y: area.y + r as u16,
                    width: 1,
                    height: 1,
                },
            );
        }
        // Thumb: solid `comment` bg over the visible-range rows.
        if line_count > text_h {
            let thumb_h = ((text_h * text_h) / line_count).max(1);
            let max_scroll = line_count - text_h;
            let max_thumb_top = text_h.saturating_sub(thumb_h);
            let thumb_top = (buf.scroll * max_thumb_top)
                .checked_div(max_scroll)
                .unwrap_or(0);
            for r in thumb_top..(thumb_top + thumb_h).min(text_h) {
                frame.render_widget(
                    Paragraph::new(" ").style(Style::default().bg(t.comment)),
                    Rect {
                        x: bar_x,
                        y: area.y + r as u16,
                        width: 1,
                        height: 1,
                    },
                );
            }
        }
    }

    if gutter_w > 0 && area.height > 0 {
        app.rects.editor_gutters.push((
            Rect {
                x: area.x,
                y: area.y,
                width: gutter_w,
                height: area.height,
            },
            pane_id,
        ));
    }
    app.rects.editor_panes.push((
        Rect {
            x: text_x,
            y: area.y,
            width: text_w,
            height: area.height,
        },
        pane_id,
    ));
    // Per-render fold chip rects — clicked to unfold.
    for (visual_row, line_no) in chip_rects {
        app.rects.fold_chips.push((
            Rect {
                x: text_x,
                y: area.y + visual_row,
                width: text_w,
                height: 1,
            },
            pane_id,
            line_no,
        ));
    }
    // VS Code-style fold arrows — 1-cell rect at the sign column
    // position for each foldable / folded line rendered above. The
    // sign_span is the FIRST span in the row (line 1035), so it
    // paints at column 0 of the pane (`area.x`), not the previously
    // assumed `text_x - 1`. vscode-user-mouse round 2 (2026-07-11)
    // caught the visible-vs-clickable mismatch — visible ▾ at area.x,
    // click rect was 4+ cells to the right.
    for (visual_row, line_no) in fold_arrow_rows {
        app.rects.fold_arrows.push((
            Rect {
                x: area.x,
                y: area.y + visual_row,
                width: 1,
                height: 1,
            },
            pane_id,
            line_no,
        ));
    }
    // Per-render gutter mark rects (sign column). One 1×1 cell per
    // painted mark; hover picks the tooltip via `HoverChip::GutterMark`.
    for (visual_row, line_no, kind) in gutter_mark_rows {
        app.rects.gutter_marks.push((
            Rect {
                x: area.x,
                y: area.y + visual_row,
                width: 1,
                height: 1,
            },
            pane_id,
            line_no,
            kind,
        ));
    }
    // Per-render code-lens chip rects — clicked to fire the lens command.
    // `start_vc` / `end_vc` are cell-index bounds in the painted cells[]
    // array, so screen-x is `text_x + start_vc` directly.
    for (visual_row, start_vc, end_vc, lens_idx) in lens_chip_rects {
        if end_vc <= start_vc || end_vc > text_w as usize {
            continue;
        }
        app.rects.code_lens_chips.push((
            Rect {
                x: text_x + start_vc as u16,
                y: area.y + visual_row,
                width: (end_vc - start_vc) as u16,
                height: 1,
            },
            pane_id,
            lens_idx,
        ));
    }

    if !focused {
        return None;
    }
    let (cy, cx) = if wrap_on {
        // Wrap-aware cursor: walk visible rows from buf.scroll, summing
        // wrap heights of each file line; on the cursor's line, add
        // `cur_col / tw` for the wrap offset within that line.
        let mut visual_y: usize = 0;
        let mut line = buf.scroll;
        let mut found = false;
        while line < line_count {
            if line == cur_row {
                visual_y += cur_col / tw.max(1);
                found = true;
                break;
            }
            if !buf.is_line_folded_body(line) {
                let nchars = buf.editor.line_str(line).chars().count();
                visual_y += nchars.div_ceil(tw.max(1)).max(1);
            }
            line += 1;
        }
        if !found {
            // Cursor is above the viewport — render the cell off-screen so
            // ratatui hides the caret rather than placing it incorrectly.
            return None;
        }
        let cy = area.y + visual_y as u16;
        let cx = text_x + (cur_col % tw.max(1)) as u16;
        (cy, cx)
    } else {
        let cy = area.y + buf.file_to_visible_row(buf.scroll, cur_row) as u16;
        let cx = text_x + (cur_col.saturating_sub(buf.h_scroll)) as u16;
        (cy, cx)
    };
    if cy < area.y + area.height && cx < area.x.saturating_add(area.width) {
        Some((cx, cy))
    } else {
        None
    }
}

/// Local alias so the per-render bg paint still calls into the public helper.
/// True when `line` looks like a fold-header: its trimmed-right form
/// ends with an open bracket (`{`, `[`, `(`) or a colon (Python-style
/// blocks). Cheap trailing-char check — the actual fold semantics
/// (matching close, block span) run at click time via
/// `toggle_fold_at_line`. Deliberately permissive: a false positive
/// only means the hover arrow appears on a line that doesn't
/// actually toggle-fold anything, which is a mild UX cost. A false
/// negative would hide the affordance entirely.
fn is_foldable_header(line: &str) -> bool {
    // Strip trailing whitespace + trailing line comment. Comments
    // vary per language (// / # / --). Cheap common-case check:
    // find the last non-space char and see if it's a fold trigger.
    let trimmed = line.trim_end();
    if trimmed.is_empty() {
        return false;
    }
    let last = trimmed.chars().next_back().unwrap_or(' ');
    matches!(last, '{' | '[' | '(' | ':')
}

fn find_word_occurrences(text: &str, word: &str) -> Vec<(usize, usize)> {
    crate::editor::find_whole_word_occurrences(text, word)
}

fn syntax_color(spans: &[crate::highlight::ColoredSpan], c: usize) -> Option<Color> {
    spans
        .iter()
        .rev()
        .find(|&&(s, e, _)| c >= s && c < e)
        .map(|&(_, _, color)| color)
}

/// Precompute the per-cell syntax color for one line. Iterates spans
/// in source order, writing each span's color to every covered cell —
/// so later (more specific / innermost) spans overwrite earlier ones.
/// Mirrors the `spans.iter().rev().find(...)` semantics of
/// [`syntax_color`] but amortizes the work across the row: cost is
/// O(sum_of_span_widths + line_width) instead of O(spans × cells).
///
/// `line_width_chars` caps the array — spans extending past EOL get
/// clipped (cheap to do here vs. checking per-cell). Returns an empty
/// vec when there are no spans (caller short-circuits to theme fg).
fn line_color_grid(
    spans: &[crate::highlight::ColoredSpan],
    line_width_chars: usize,
) -> Vec<Option<Color>> {
    if spans.is_empty() || line_width_chars == 0 {
        return Vec::new();
    }
    let mut grid: Vec<Option<Color>> = vec![None; line_width_chars];
    for &(s, e, color) in spans {
        let lo = s.min(line_width_chars);
        let hi = e.min(line_width_chars);
        for slot in &mut grid[lo..hi] {
            *slot = Some(color);
        }
    }
    grid
}

/// LSP semantic-tokens style override for cell `(line, c)`. Returns `Some`
/// when a token covers this cell — caller layers this on top of the
/// tree-sitter `syntax_color` (LSP wins where they overlap, per spec).
/// `None` ⇒ no semantic token here, fall back to tree-sitter.
///
/// The return carries both the type-derived color *and* a `Modifier`
/// derived from the token's modifier list (deprecated ⇒ CROSSED_OUT,
/// readonly ⇒ ITALIC, static ⇒ BOLD, defaultLibrary ⇒ DIM); multiple
/// modifiers OR together via `Modifier`'s bitflags semantics.
///
/// Binary-search for the semantic token that covers column `c` on the
/// pre-filtered list of tokens already known to be on this line and
/// sorted by `start_char`. The caller builds the per-line list once
/// (see [`tokens_for_line`]) and re-uses it across every cell on that
/// line, taking us from O(tokens × cells × lines) for the whole buffer
/// to O(log(tokens_on_line) × cells × lines). On a 12k-line Rust file
/// that's the difference between syntax highlighting blocking a
/// render frame and not.
fn semantic_style(
    line_tokens: &[&crate::lsp::SemanticToken],
    c: usize,
) -> Option<(Color, ratatui::style::Modifier)> {
    if line_tokens.is_empty() {
        return None;
    }
    let c_u32 = c as u32;
    // Binary-search for the right-most token whose `start_char` ≤ c.
    // Since tokens on one line don't overlap (per LSP spec), at most
    // one candidate can contain c; we either hit it or get None.
    let idx = match line_tokens.binary_search_by(|tok| tok.start_char.cmp(&c_u32)) {
        Ok(i) => i,
        Err(0) => return None,
        Err(i) => i - 1,
    };
    let tok = line_tokens[idx];
    if c_u32 < tok.start_char + tok.length {
        Some((
            semantic_token_color(&tok.type_name),
            semantic_token_modifier(&tok.modifiers),
        ))
    } else {
        None
    }
}

/// Build the per-line token slice (sorted by `start_char`) from the
/// buffer's flat token list. Called once per rendered line before
/// the per-cell loop. LSP guarantees tokens within one line don't
/// overlap, but doesn't guarantee they arrive sorted — the sort
/// here makes the binary-search in [`semantic_style`] correct.
fn tokens_for_line(
    tokens: &[crate::lsp::SemanticToken],
    line: usize,
) -> Vec<&crate::lsp::SemanticToken> {
    let line_u32 = line as u32;
    let mut out: Vec<&crate::lsp::SemanticToken> =
        tokens.iter().filter(|t| t.line == line_u32).collect();
    out.sort_by_key(|t| t.start_char);
    out
}

/// Map an LSP semantic-token type name to a theme color. Mirrors the
/// HIGHLIGHT_NAMES → color mapping in `highlight.rs` so semantic tokens
/// and tree-sitter highlights look consistent. Unknown types fall back to
/// the theme's foreground (effectively a no-op vs. the tree-sitter layer).
fn semantic_token_color(type_name: &str) -> Color {
    let t = theme::cur();
    match type_name {
        "keyword" | "modifier" => t.purple,
        "string" | "regexp" => t.green,
        "number" => t.yellow,
        "comment" => t.comment,
        "function" | "method" | "macro" | "decorator" => t.blue,
        "type" | "class" | "struct" | "enum" | "interface" | "typeParameter" => t.yellow,
        "namespace" | "event" => t.cyan,
        "variable" | "parameter" | "property" | "enumMember" => t.fg,
        "operator" => t.fg,
        _ => t.fg,
    }
}

/// Map an LSP semantic-token modifier list to a `ratatui::style::Modifier`
/// bitmask. The visual hooks are picked to match common-IDE conventions:
///
/// * `deprecated` → `CROSSED_OUT` — the strongest signal; deprecated APIs
///   should be impossible to use accidentally.
/// * `readonly` → `ITALIC` — by convention, immutable / `const`-ish refs.
/// * `static` → `BOLD` — class-level / module-level binding.
/// * `defaultLibrary` → `DIM` — stdlib / built-in symbols recede.
///
/// Other LSP-standard modifiers (`declaration`, `definition`, `abstract`,
/// `async`, `modification`, `documentation`) have no visual mapping —
/// they could each get a hook in a future cut, but the four above cover
/// the visually-distinct cases at the terminal palette's resolution.
fn semantic_token_modifier(modifiers: &[String]) -> ratatui::style::Modifier {
    use ratatui::style::Modifier;
    let mut m = Modifier::empty();
    for name in modifiers {
        match name.as_str() {
            "deprecated" => m |= Modifier::CROSSED_OUT,
            "readonly" => m |= Modifier::ITALIC,
            "static" => m |= Modifier::BOLD,
            "defaultLibrary" => m |= Modifier::DIM,
            _ => {}
        }
    }
    m
}

/// Workspace-relative *parent directory* of the pane's file, suitable for
/// breadcrumb display. `None` when the pane isn't an editor, the buffer has
/// no path, or the file sits at the workspace root (no parent dir → no
/// useful breadcrumb, since the filename is already on the bufferline tab).
fn breadcrumb_label(app: &App, pane_id: PaneId) -> Option<String> {
    let Some(Pane::Editor(b)) = app.panes.get(pane_id) else {
        return None;
    };
    let path = b.path.as_ref()?;
    let rel = path.strip_prefix(&app.workspace).unwrap_or(path);
    let parent = rel.parent()?;
    let s = parent.to_string_lossy();
    if s.is_empty() {
        return None;
    }
    Some(format!("{}/", s))
}

/// One-row breadcrumb header (dim) above the editor body. Caller has
/// already resolved the label via [`breadcrumb_label`] and decided to
/// render. Truncates the middle with `…` if the label is wider than
/// the pane.
fn draw_breadcrumb(frame: &mut Frame, area: Rect, label: &str) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_darker)),
        area,
    );
    let max = area.width.saturating_sub(2) as usize;
    let display = if label.chars().count() <= max {
        label.to_string()
    } else if max > 3 {
        let half = (max - 1) / 2;
        let chars: Vec<char> = label.chars().collect();
        let head: String = chars.iter().take(half).collect();
        let tail: String = chars.iter().rev().take(max - 1 - half).collect();
        let tail: String = tail.chars().rev().collect();
        format!("{head}…{tail}")
    } else {
        label.chars().take(max).collect()
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(t.bg_darker)),
            Span::styled(display, Style::default().fg(t.comment).bg(t.bg_darker)),
        ])),
        area,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Modifier;

    #[test]
    fn foldable_header_detects_common_shapes() {
        assert!(is_foldable_header("fn foo() {"));
        assert!(is_foldable_header("  let x = ["));
        assert!(is_foldable_header("def foo():"));
        assert!(is_foldable_header("if True:  "));
        assert!(is_foldable_header("array.map((x) => ("));
        assert!(!is_foldable_header("let x = 1;"));
        assert!(!is_foldable_header(""));
        assert!(!is_foldable_header("    "));
        assert!(!is_foldable_header("return x + 1"));
    }

    #[test]
    fn semantic_token_modifier_maps_known_names() {
        assert_eq!(
            semantic_token_modifier(&["deprecated".to_string()]),
            Modifier::CROSSED_OUT
        );
        assert_eq!(
            semantic_token_modifier(&["readonly".to_string()]),
            Modifier::ITALIC
        );
        assert_eq!(
            semantic_token_modifier(&["static".to_string()]),
            Modifier::BOLD
        );
        assert_eq!(
            semantic_token_modifier(&["defaultLibrary".to_string()]),
            Modifier::DIM
        );
    }

    #[test]
    fn semantic_token_modifier_combines_multiple() {
        // deprecated + static ⇒ CROSSED_OUT | BOLD
        let m = semantic_token_modifier(&["deprecated".to_string(), "static".to_string()]);
        assert!(m.contains(Modifier::CROSSED_OUT));
        assert!(m.contains(Modifier::BOLD));
    }

    #[test]
    fn line_color_grid_matches_linear_scan_innermost_wins() {
        // Tree-sitter span shape: outer "function" span (cols 0-10),
        // inner "identifier" span (cols 4-7). Innermost (later in
        // source order) should win the overlap.
        let spans: Vec<crate::highlight::ColoredSpan> = vec![
            (0, 10, Color::Red),
            (4, 7, Color::Blue), // inner
        ];
        let grid = line_color_grid(&spans, 10);
        for c in 0..10 {
            let expected = syntax_color(&spans, c);
            let got = grid.get(c).copied().unwrap_or(None);
            assert_eq!(got, expected, "mismatch at col {c}");
        }
        // The blue inner span won the overlap (cols 4..7).
        assert_eq!(grid[5], Some(Color::Blue));
        // Outer span owns the edges.
        assert_eq!(grid[0], Some(Color::Red));
        assert_eq!(grid[9], Some(Color::Red));
    }

    #[test]
    fn line_color_grid_empty_when_no_spans() {
        let grid = line_color_grid(&[], 10);
        assert!(grid.is_empty());
        let grid = line_color_grid(&[(0, 5, Color::Red)], 0);
        assert!(grid.is_empty());
    }

    #[test]
    fn line_color_grid_clips_spans_past_eol() {
        // A span extending past EOL shouldn't OOB the grid.
        let spans: Vec<crate::highlight::ColoredSpan> = vec![(2, 50, Color::Green)];
        let grid = line_color_grid(&spans, 5);
        assert_eq!(grid.len(), 5);
        assert_eq!(grid[0], None);
        assert_eq!(grid[1], None);
        assert_eq!(grid[2], Some(Color::Green));
        assert_eq!(grid[4], Some(Color::Green));
    }

    #[test]
    fn semantic_token_modifier_drops_unknown_names() {
        // Unmapped names contribute nothing; known names still apply.
        let m = semantic_token_modifier(&[
            "declaration".to_string(),
            "abstract".to_string(),
            "deprecated".to_string(),
        ]);
        assert_eq!(m, Modifier::CROSSED_OUT);
    }

    #[test]
    fn semantic_token_modifier_empty_when_no_input() {
        assert_eq!(semantic_token_modifier(&[]), Modifier::empty());
    }

    #[test]
    fn semantic_style_returns_color_and_modifier_for_overlap() {
        let tokens = vec![crate::lsp::SemanticToken {
            line: 3,
            start_char: 4,
            length: 5,
            type_name: "function".to_string(),
            modifiers: vec!["deprecated".to_string()],
        }];
        let line_tokens = tokens_for_line(&tokens, 3);
        let Some((_, m)) = semantic_style(&line_tokens, 6) else {
            panic!("expected token coverage");
        };
        assert_eq!(m, Modifier::CROSSED_OUT);
        // Outside the range ⇒ None.
        assert!(semantic_style(&line_tokens, 9).is_none());
        // Different line ⇒ empty per-line projection.
        let line2 = tokens_for_line(&tokens, 2);
        assert!(semantic_style(&line2, 5).is_none());
    }

    #[test]
    fn tokens_for_line_sorts_by_start_char() {
        // Server can emit tokens out of order; the binary-search in
        // semantic_style requires sorted-by-start_char input.
        let tokens = vec![
            crate::lsp::SemanticToken {
                line: 0,
                start_char: 20,
                length: 3,
                type_name: "function".to_string(),
                modifiers: vec![],
            },
            crate::lsp::SemanticToken {
                line: 0,
                start_char: 5,
                length: 3,
                type_name: "keyword".to_string(),
                modifiers: vec![],
            },
            crate::lsp::SemanticToken {
                line: 0,
                start_char: 12,
                length: 4,
                type_name: "variable".to_string(),
                modifiers: vec![],
            },
        ];
        let projected = tokens_for_line(&tokens, 0);
        let starts: Vec<u32> = projected.iter().map(|t| t.start_char).collect();
        assert_eq!(starts, vec![5, 12, 20]);
        // Binary-search resolves each column to the right token.
        assert!(semantic_style(&projected, 6).is_some());
        assert!(semantic_style(&projected, 13).is_some());
        assert!(semantic_style(&projected, 21).is_some());
        // Gaps between tokens ⇒ None.
        assert!(semantic_style(&projected, 9).is_none());
        assert!(semantic_style(&projected, 17).is_none());
    }
}
