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

    // Optional breadcrumb row at the top — the workspace-relative file path,
    // dim, on its own row. Especially useful with splits (you can tell which
    // pane is which without scanning the bufferline). Off ⇒ the editor uses
    // the whole `area`.
    let want_breadcrumb = app.config.editor.breadcrumb && area.height >= 3;
    let (crumb_area, area) = if want_breadcrumb {
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
    if let Some(ca) = crumb_area {
        draw_breadcrumb(frame, app, pane_id, ca);
    }

    let tab_w = app.config.editor.tab_width.max(1);
    let relnum = app.config.ui.relative_line_numbers;
    let show_ws = app.config.ui.show_whitespace;
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
    const BLAME_W: usize = 22;
    let blame_on = buf.blame.is_some();
    let num_w = if blame_on {
        BLAME_W
    } else {
        line_count.to_string().len().max(3)
    };
    let gutter_w = (num_w + 2) as u16;
    let text_x = area.x + gutter_w;
    // Reserve the last column for the scrollbar when enabled (and the pane is
    // wide enough to spare it). Rendered after the body paragraph.
    let want_scrollbar = app.config.ui.scrollbar && area.width >= gutter_w + 2;
    let scrollbar_w: u16 = if want_scrollbar { 1 } else { 0 };
    let text_w = area
        .width
        .saturating_sub(gutter_w)
        .saturating_sub(scrollbar_w);
    let tw = text_w as usize;
    let text_h = area.height as usize;
    let cur_row_initial = buf.editor.row_col().0;
    // If the cursor landed in a fold's body (e.g. a fold was just toggled
    // while the cursor was mid-block), snap it onto the fold's start line.
    if let Some(owner) = buf.fold_owner_of(cur_row_initial) {
        buf.editor.place_cursor(owner, 0);
    }
    let (cur_row, cur_col) = buf.editor.row_col();

    // Vertical scroll — keep the cursor row in view. With folds, "row" is a
    // file-line index but visible distance is what matters. Snap `scroll` to
    // a visible line first (a fold body would render nothing as the top row).
    if buf.is_line_folded_body(buf.scroll)
        && let Some(snap) = buf.fold_owner_of(buf.scroll)
    {
        buf.scroll = snap;
    }
    if cur_row < buf.scroll {
        buf.scroll = cur_row;
    } else {
        let vis_offset = buf.file_to_visible_row(buf.scroll, cur_row);
        if vis_offset >= text_h {
            // Walk back `text_h - 1` visible lines from cur_row.
            let mut walk_back = text_h.saturating_sub(1);
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
    buf.scroll = buf
        .scroll
        .min(line_count.saturating_sub(text_h.min(line_count)));

    // Horizontal scroll — keep the cursor column in view.
    if tw > 0 {
        if cur_col < buf.h_scroll {
            buf.h_scroll = cur_col;
        } else if cur_col >= buf.h_scroll + tw {
            buf.h_scroll = cur_col + 1 - tw;
        }
    }

    let selection = buf.editor.selection();
    let block_sel = buf.editor.block_selection();
    let sel_bg = theme::cur().base16[0x02];
    let match_bg = theme::cur().bg2;
    let cur_match_bg = theme::cur().yellow;
    let cur_match_idx = buf.find.as_ref().and_then(|f| f.current);
    let guide_fg = theme::cur().base16[0x03];
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
    // Walk visible file lines starting at buf.scroll, skipping any folded
    // body. `next_line` is the file line for the next render row.
    let mut next_line = buf.next_visible_line(buf.scroll).unwrap_or(line_count);
    for r in 0..text_h {
        let line_no = next_line;
        if line_no >= line_count {
            lines.push(Line::from(Span::styled(
                " ".repeat(area.width as usize),
                Style::default().bg(theme::cur().bg_dark),
            )));
            continue;
        }
        // Schedule the next visible line for the next iteration.
        next_line = buf.next_visible_line(line_no + 1).unwrap_or(line_count);
        let is_cur = line_no == cur_row;
        let base_bg = if is_cur {
            theme::cur().line
        } else {
            theme::cur().bg_dark
        };
        let num_gutter = if blame_on {
            match buf.blame.as_ref().and_then(|v| v.get(line_no)) {
                Some(bl) => format!("{} ", bl.label(num_w)),
                None => format!("{} ", " ".repeat(num_w)),
            }
        } else if relnum && !is_cur {
            format!("{:>num_w$} ", line_no.abs_diff(cur_row))
        } else {
            format!("{:>num_w$} ", line_no + 1)
        };
        // Worst LSP diagnostic severity touching this line (if any).
        let diag_sev: Option<crate::lsp::Severity> = buf
            .diagnostics
            .iter()
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
        // The 1-cell sign column: an LSP severity dot wins, else the git change mark.
        let sign = signs.and_then(|v| {
            v.binary_search_by_key(&line_no, |&(l, _)| l)
                .ok()
                .map(|i| v[i].1)
        });
        let sign_span = if let Some(s) = diag_sev {
            Span::styled("●", Style::default().fg(diag_color(s)).bg(base_bg))
        } else {
            match sign {
                Some(k) => Span::styled("▎", Style::default().fg(sign_color(k)).bg(base_bg)),
                None => Span::styled(" ", Style::default().bg(base_bg)),
            }
        };

        // Word-match ranges (in char cols) on this line, converted from the
        // pre-computed buffer-wide byte ranges. Same shape as the find-match
        // list; non-cursor cells in these ranges get a subtle bg tint.
        let (ls, le) = buf.editor.line_byte_range(line_no);
        let word_matches_on_line: Vec<(usize, usize)> = word_match_ranges
            .iter()
            .filter(|(s, e)| *s >= ls && *e <= le)
            .map(|(s, e)| (buf.editor.byte_to_col(*s), buf.editor.byte_to_col(*e)))
            .collect();
        let (sel_lo, sel_hi, extend_eol) = match selection {
            Some((lo, hi)) if hi > ls && lo <= le => (
                buf.editor.byte_to_col(lo.clamp(ls, le)),
                buf.editor.byte_to_col(hi.clamp(ls, le)),
                hi > le,
            ),
            _ => (0, 0, false),
        };

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

        // Per-visible-cell (char, fg, bg), then coalesce into spans.
        let mut cells: Vec<(char, Color, Color)> = Vec::with_capacity(tw);
        for vc in 0..tw {
            let c = buf.h_scroll + vc;
            let in_sel =
                (sel_hi > sel_lo && c >= sel_lo && c < sel_hi) || (extend_eol && c >= sel_lo);
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
            let bg = if in_sel || in_block {
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
                        if in_word_match {
                            word_match_bg
                        } else {
                            base_bg
                        }
                    }
                }
            };
            let (ch, mut fg) = if c < n {
                let raw_ch = chars[c];
                if raw_ch == ' ' && has_content && c >= tab_w && c % tab_w == 0 && c < indent_cols {
                    ('│', guide_fg)
                } else if show_ws && raw_ch == ' ' {
                    ('·', guide_fg)
                } else if show_ws && raw_ch == '\t' {
                    ('→', guide_fg)
                } else {
                    (
                        raw_ch,
                        syntax_color(spans_for_line, c).unwrap_or(theme::cur().fg),
                    )
                }
            } else {
                (' ', theme::cur().fg)
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
            }
            // The "current" find match: force dark fg so it stays readable on
            // the bright bg.
            if matches!(in_match, Some(true)) {
                fg = theme::cur().bg_dark;
            }
            cells.push((ch, fg, bg));
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
                if c < buf.h_scroll {
                    continue;
                }
                let vc = c - buf.h_scroll;
                if vc >= cells.len() {
                    break;
                }
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, mcolor, base_bg);
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
                .diagnostics
                .iter()
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
                if c < buf.h_scroll {
                    continue;
                }
                let vc = c - buf.h_scroll;
                if vc >= cells.len() {
                    break;
                }
                // Only paint where the line's natural content ended (a space
                // cell with the line bg) — never over selection / find-match.
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, dcolor, base_bg);
                }
            }
        }

        // Inlay hints: collect every hint on this line, format as one
        // joined string, paint into trailing space cells in dim color.
        // (Vim canonical position is inline — we render end-of-line for
        // the MVP because it doesn't shift real code cells.)
        let hints_on_line: Vec<&crate::lsp::InlayHint> = if app.config.editor.inlay_hints {
            buf.inlay_hints
                .iter()
                .filter(|h| (h.line as usize) == line_no)
                .collect()
        } else {
            Vec::new()
        };
        if !hints_on_line.is_empty() {
            let chip = hints_on_line
                .iter()
                .map(|h| h.label.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("  ");
            let with_lead = format!("  {chip}");
            let start_c = n + 2;
            let hcolor = theme::cur().comment;
            for (i, mc) in with_lead.chars().enumerate() {
                let c = start_c + i;
                if c < buf.h_scroll {
                    continue;
                }
                let vc = c - buf.h_scroll;
                if vc >= cells.len() {
                    break;
                }
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, hcolor, base_bg);
                }
            }
        }

        // Code lenses: paint as dim chips at end-of-line in a slightly
        // different color (purple) so they're distinguishable from
        // inlay hints. Same "overlay into trailing space" approach.
        let lenses_on_line: Vec<&crate::lsp::CodeLens> = if app.config.editor.code_lens {
            buf.code_lenses
                .iter()
                .filter(|l| (l.line as usize) == line_no)
                .collect()
        } else {
            Vec::new()
        };
        if !lenses_on_line.is_empty() {
            let chip = lenses_on_line
                .iter()
                .map(|l| l.title.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" | ");
            let with_lead = format!("  ⚡ {chip}");
            let start_c = n + 2;
            let lcolor = theme::cur().purple;
            for (i, mc) in with_lead.chars().enumerate() {
                let c = start_c + i;
                if c < buf.h_scroll {
                    continue;
                }
                let vc = c - buf.h_scroll;
                if vc >= cells.len() {
                    break;
                }
                if cells[vc].0 == ' ' && cells[vc].2 == base_bg {
                    cells[vc] = (mc, lcolor, base_bg);
                }
            }
        }

        let mut spans: Vec<Span> = vec![sign_span, Span::styled(num_gutter, num_style)];
        let mut i = 0;
        while i < cells.len() {
            let (_, fg, bg) = cells[i];
            let mut s = String::new();
            while i < cells.len() && cells[i].1 == fg && cells[i].2 == bg {
                s.push(cells[i].0);
                i += 1;
            }
            spans.push(Span::styled(s, Style::default().fg(fg).bg(bg)));
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
    frame.render_widget(Paragraph::new(lines), area);

    if want_scrollbar && text_h > 0 {
        let bar_x = area.x + area.width - 1;
        let t = theme::cur();
        // Track first — paints every cell with the dim track color.
        for r in 0..text_h {
            frame.render_widget(
                Paragraph::new(" ").style(Style::default().bg(t.bg_dark)),
                Rect {
                    x: bar_x,
                    y: area.y + r as u16,
                    width: 1,
                    height: 1,
                },
            );
        }
        // Thumb — height proportional to (visible / total), top proportional
        // to (scroll / max_scroll). Both bounded so it's always visible.
        if line_count > text_h {
            let thumb_h = ((text_h * text_h) / line_count).max(1);
            let max_scroll = line_count - text_h;
            let max_thumb_top = text_h.saturating_sub(thumb_h);
            let thumb_top = (buf.scroll * max_thumb_top)
                .checked_div(max_scroll)
                .unwrap_or(0);
            for r in thumb_top..(thumb_top + thumb_h).min(text_h) {
                frame.render_widget(
                    Paragraph::new(" ").style(Style::default().bg(t.bg3)),
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

    if !focused {
        return None;
    }
    let cy = area.y + buf.file_to_visible_row(buf.scroll, cur_row) as u16;
    let cx = text_x + (cur_col.saturating_sub(buf.h_scroll)) as u16;
    if cy < area.y + area.height && cx < area.x.saturating_add(area.width) {
        Some((cx, cy))
    } else {
        None
    }
}

/// Color for char column `c`, picking the innermost (last-pushed) covering span.
/// Byte ranges of every whole-word, case-sensitive occurrence of `word` in
/// `text`. "Whole word" means the chars immediately before and after the
/// match aren't `[A-Za-z0-9_]`. Used by the "highlight word under cursor"
/// render feature — a buffer-wide single scan, cheap enough to do every frame.
fn find_word_occurrences(text: &str, word: &str) -> Vec<(usize, usize)> {
    if word.is_empty() || word.len() > text.len() {
        return Vec::new();
    }
    let bytes = text.as_bytes();
    let is_id = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let wlen = word.len();
    let mut out: Vec<(usize, usize)> = Vec::new();
    let mut start = 0usize;
    while let Some(off) = text[start..].find(word) {
        let s = start + off;
        let e = s + wlen;
        let before_ok = s == 0 || !is_id(bytes[s - 1]);
        let after_ok = e == text.len() || !is_id(bytes[e]);
        if before_ok && after_ok {
            out.push((s, e));
        }
        start = s + 1; // overlap-safe: step one byte past the start
    }
    out
}

fn syntax_color(spans: &[crate::highlight::ColoredSpan], c: usize) -> Option<Color> {
    spans
        .iter()
        .rev()
        .find(|&&(s, e, _)| c >= s && c < e)
        .map(|&(_, _, color)| color)
}

/// One-row workspace-relative path header (dim) above the editor body. Drawn
/// when `[editor] breadcrumb = true` and the pane has enough room. Truncates
/// the middle with `…` if the path is wider than the pane.
fn draw_breadcrumb(frame: &mut Frame, app: &App, pane_id: PaneId, area: Rect) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_darker)),
        area,
    );
    let label = match app.panes.get(pane_id) {
        Some(Pane::Editor(b)) => match &b.path {
            Some(p) => p
                .strip_prefix(&app.workspace)
                .unwrap_or(p)
                .to_string_lossy()
                .into_owned(),
            None => b.display_name(),
        },
        _ => return,
    };
    let max = area.width.saturating_sub(2) as usize;
    let display = if label.chars().count() <= max {
        label
    } else if max > 3 {
        // `start…end` — keep the leading "domain" + the trailing filename.
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
