//! Renders the right-click context menu — a small bordered floating list at the
//! click cell (clamped to the screen), the selected row highlighted. State lives
//! in `crate::context_menu`; key + mouse handling is in `tui.rs` (it records the
//! per-row hitboxes here).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(menu) = &app.context_menu else {
        return;
    };
    app.rects.context_menu_items.clear();
    app.rects.context_menu_kebab = None;
    app.rects.context_menu_box = None;
    if menu.items.is_empty() || screen.width < 4 || screen.height < 3 {
        return;
    }

    let inner_w = menu.content_width(app.config.ui.ascii_icons);
    let w = ((inner_w as u16) + 2).min(screen.width.saturating_sub(1));
    // Rows: optional title + one per item.
    let title_rows = if menu.title.is_some() { 1u16 } else { 0 };
    let h = (menu.items.len() as u16 + title_rows + 2).min(screen.height.saturating_sub(1));

    // Anchor near the click, but keep the box on screen.
    let (ax, ay) = menu.anchor;
    let x = ax.min(screen.x + screen.width.saturating_sub(w));
    let y = ay.min(screen.y + screen.height.saturating_sub(h));
    let area = Rect {
        x: x.max(screen.x),
        y: y.max(screen.y),
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    // Context menus use the quiet menu chrome — square border,
    // default fg color, `bg2` fill — so visual weight sits on the
    // selected row, not the frame. Matches macOS / VS Code menus.
    let block = crate::ui::design_tokens::popup_menu(menu.title.as_deref().unwrap_or(""));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let curatable = menu.curatable;
    // Window the rows instead of truncating them. A menu taller than
    // the screen silently dropped its LAST rows — which in the TODO
    // agent menu are the two actions the menu exists for.
    let rows = inner.height as usize;
    let scroll = {
        let sel = menu.selected;
        let mut s = menu.scroll.min(menu.items.len().saturating_sub(rows));
        if sel < s {
            s = sel;
        } else if rows > 0 && sel >= s + rows {
            s = sel + 1 - rows;
        }
        s
    };
    let more_above = scroll > 0;
    let more_below = scroll + rows < menu.items.len();
    let visible = rows.min(menu.items.len().saturating_sub(scroll));
    for (row, item) in menu.items.iter().skip(scroll).take(visible).enumerate() {
        let r = Rect::new(inner.x, inner.y + row as u16, inner.width, 1);
        // Only paint the highlight once the user has interacted
        // (mouse hover or arrow keys). On first open with no
        // interaction, rows render plain — matches the macOS /
        // VS Code menu-bar look the user prefers. Enter / click
        // still fire whatever's at `selected` (0 by default), so
        // the no-highlight state isn't inert.
        let selected = row == menu.selected && menu.interacted;
        let mut style = if selected {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        // Destructive rows (Close / Delete) paint red when idle.
        // Selection style still wins so the row isn't red-on-red-
        // highlight — matches the widget-kebab convention in
        // `src/ui/dock.rs`.
        if item.destructive && !selected {
            style = style.fg(crate::ui::theme::cur().red);
        }
        // Pad the label so the highlight fills the row. A submenu row
        // reserves its last two cells for the `\u{25b8}` — the visible
        // affordance that is the whole reason to prefer a submenu over a
        // right-click for grouping.
        let want = inner.width as usize;
        // A curatable row shows its kebab ONLY while focused — the
        // hover-reveal idiom (GitHub, Slack). Discoverable when you are
        // on the row, and it does not put a marker on all fifteen rows
        // the way making every row a submenu parent would.
        let kebab = curatable && selected && !item.has_submenu();
        let marker = if item.has_submenu() {
            "\u{25b8} "
        } else if kebab {
            "\u{22ee} "
        } else {
            ""
        };
        // Leading glyph column — see `ui::menu_glyph`. Blank rows emit
        // an empty column rather than a placeholder, and the padding
        // below is computed from the finished string, so mixed
        // glyph/no-glyph menus still fill the row.
        let g = crate::ui::menu_glyph::column_for(
            item.icon.as_deref(),
            &item.action,
            app.config.ui.ascii_icons,
        );
        let mut label = format!(" {g}{} ", item.label);
        let room = want.saturating_sub(marker.chars().count());
        if label.chars().count() < room {
            label.push_str(&" ".repeat(room - label.chars().count()));
        }
        label.push_str(marker);
        frame.render_widget(Paragraph::new(Line::from(Span::styled(label, style))), r);
        if kebab {
            // Its own hit-rect: clicking the row runs it, clicking the
            // kebab opens the options. Two outcomes in one row means the
            // targets must not overlap.
            app.rects.context_menu_kebab = Some((
                Rect::new(r.x + r.width.saturating_sub(2), r.y, 2, 1),
                row + scroll,
            ));
        }
        // `row + scroll`: `row` is the position in the WINDOW now, and
        // every consumer of this rect (click routing, kebab) wants the
        // index into `items`.
        app.rects.context_menu_items.push((r, row + scroll));
    }
    // Say so when rows are off-screen, rather than ending the list
    // silently at whatever fits — the truncation was invisible.
    if more_above || more_below {
        let t = crate::ui::theme::cur();
        let hint = match (more_above, more_below) {
            (true, true) => "\u{2195}",
            (true, false) => "\u{2191}",
            _ => "\u{2193}",
        };
        let hx = area.x + area.width.saturating_sub(3);
        let hy = area.y + area.height.saturating_sub(1);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!(" {hint}"),
                ratatui::style::Style::default().fg(t.comment).bg(t.bg2),
            ))),
            Rect::new(hx, hy, 2, 1),
        );
    }
    // Persist the windowed offset once the immutable borrow of
    // `app.context_menu` above has ended.
    if let Some(m) = app.context_menu.as_mut() {
        m.scroll = scroll;
    }
    app.rects.context_menu_box = Some(area);

    draw_submenu(frame, app, screen, area);
}

/// Paint the open child menu beside its parent row.
///
/// Opens rightward, and flips to the left when there is no room — the
/// pointer has to be able to travel from the parent row into the child
/// without leaving the chain, and a child clipped at the screen edge
/// makes that impossible.
fn draw_submenu(frame: &mut Frame, app: &mut App, screen: Rect, parent: Rect) {
    app.rects.context_submenu_items.clear();
    app.rects.context_submenu_box = None;
    let Some((prow, menu)) = &app.context_submenu else {
        return;
    };
    if menu.items.is_empty() {
        return;
    }
    let inner_w = menu.content_width(app.config.ui.ascii_icons);
    let w = ((inner_w as u16) + 2).min(screen.width.saturating_sub(1));
    let h = (menu.items.len() as u16 + 2).min(screen.height.saturating_sub(1));

    // Prefer the right edge of the parent; flip left when that would run
    // off screen.
    let right = parent.x + parent.width;
    let x = if right + w <= screen.x + screen.width {
        right
    } else {
        parent.x.saturating_sub(w)
    };
    // Line the child's first row up with its parent row, then clamp.
    let y = (parent.y + 1 + *prow as u16)
        .min(screen.y + screen.height.saturating_sub(h))
        .max(screen.y);
    let area = Rect {
        x: x.max(screen.x),
        y,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu("");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }
    // Windowed, like the parent menu. This is the one that actually
    // bit: the agent list under a TODO row is a SUBMENU, and it dropped
    // `Fix with Claude Code` and `Fix with Codex` off the bottom.
    let rows = inner.height as usize;
    let scroll = {
        let sel = menu.selected;
        let mut sc = menu.scroll.min(menu.items.len().saturating_sub(rows));
        if sel < sc {
            sc = sel;
        } else if rows > 0 && sel >= sc + rows {
            sc = sel + 1 - rows;
        }
        sc
    };
    let more_above = scroll > 0;
    let more_below = scroll + rows < menu.items.len();
    let visible = rows.min(menu.items.len().saturating_sub(scroll));
    for (row, item) in menu.items.iter().skip(scroll).take(visible).enumerate() {
        let r = Rect::new(inner.x, inner.y + row as u16, inner.width, 1);
        let selected = row == menu.selected && menu.interacted;
        let mut style = if selected {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        if item.destructive && !selected {
            style = style.fg(crate::ui::theme::cur().red);
        }
        let g = crate::ui::menu_glyph::column_for(
            item.icon.as_deref(),
            &item.action,
            app.config.ui.ascii_icons,
        );
        let mut label = format!(" {g}{} ", item.label);
        let want = inner.width as usize;
        if label.chars().count() < want {
            label.push_str(&" ".repeat(want - label.chars().count()));
        }
        frame.render_widget(Paragraph::new(Line::from(Span::styled(label, style))), r);
        app.rects.context_submenu_items.push((r, row + scroll));
    }
    if more_above || more_below {
        let hint = match (more_above, more_below) {
            (true, true) => "\u{2195}",
            (true, false) => "\u{2191}",
            _ => "\u{2193}",
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!(" {hint}"),
                ratatui::style::Style::default()
                    .fg(crate::ui::theme::cur().comment)
                    .bg(crate::ui::theme::cur().bg2),
            ))),
            Rect::new(
                area.x + area.width.saturating_sub(3),
                area.y + area.height.saturating_sub(1),
                2,
                1,
            ),
        );
    }
    if let Some((_, m)) = app.context_submenu.as_mut() {
        m.scroll = scroll;
    }
    app.rects.context_submenu_box = Some(area);
}

#[cfg(test)]
mod glyph_render_tests {
    use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;

    fn render_menu(ascii: bool) -> String {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = crate::config::Config::default();
        cfg.ui.ascii_icons = ascii;
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        app.context_menu = Some(ContextMenu::new(
            Some("a.txt".to_string()),
            (2, 2),
            vec![
                MenuItem::new("Copy path", MenuAction::CopyText("/a".into())),
                MenuItem::new("Save", MenuAction::SavePane(0)),
            ],
        ));
        let (w, h) = (80u16, 24u16);
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The glyph must reach the SCREEN, not merely exist in the table.
    /// The table's own tests pass even if the renderer never calls it.
    #[test]
    fn menu_rows_paint_their_glyph() {
        let screen = render_menu(false);
        let copy = crate::ui::menu_glyph::for_action(&MenuAction::CopyText("/a".into()));
        assert!(
            screen.contains(copy),
            "the Copy row painted no glyph — the table is wired to nothing:\n{screen}"
        );
        assert!(screen.contains("Copy path"), "the row label vanished");
    }

    /// ASCII mode must render the labels and NO glyphs.
    #[test]
    fn ascii_mode_paints_labels_without_glyphs() {
        let screen = render_menu(true);
        assert!(screen.contains("Copy path"), "label missing in ascii mode");
        let copy = crate::ui::menu_glyph::for_action(&MenuAction::CopyText("/a".into()));
        assert!(
            !screen.contains(copy),
            "ascii mode painted a nerd glyph:\n{screen}"
        );
    }
}

#[cfg(test)]
mod truncation_tests {
    use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;

    fn render(app: &mut crate::app::App, w: u16, h: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| {
            super::draw(
                f,
                app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: h,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn app_with_long_menu(n: usize) -> (tempfile::TempDir, crate::app::App) {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let mut items: Vec<MenuItem> = (0..n)
            .map(|i| MenuItem::new(format!("agent-{i:02}"), MenuAction::Command("scratch.new")))
            .collect();
        // The two rows that actually matter sit LAST, exactly as in the
        // real TODO menu.
        items.push(MenuItem::new(
            "Fix with Claude Code",
            MenuAction::Command("ai.claude_code"),
        ));
        items.push(MenuItem::new(
            "Fix with Codex",
            MenuAction::Command("ai.codex_new"),
        ));
        app.context_menu = Some(ContextMenu::new(Some("TODO".into()), (2, 1), items));
        (d, app)
    }

    /// TESTER SEV-2, confirmed — a menu taller than the screen dropped
    /// its LAST rows silently. In the real case those were `Fix with
    /// Claude Code` and `Fix with Codex`: the two actions the menu
    /// exists for. Neither wheel nor arrows moved it.
    #[test]
    fn a_long_menu_can_reach_its_last_row() {
        let (_d, mut app) = app_with_long_menu(40);
        let first = render(&mut app, 40, 20);
        assert!(
            !first.contains("Fix with Codex"),
            "setup: the menu fits, so nothing is being truncated"
        );

        // Select the last row, as arrowing to the bottom would.
        let last = app.context_menu.as_ref().unwrap().items.len() - 1;
        app.context_menu.as_mut().unwrap().selected = last;
        let scrolled = render(&mut app, 40, 20);
        assert!(
            scrolled.contains("Fix with Codex"),
            "the last row is unreachable — the menu is still truncated:\n{scrolled}"
        );
    }

    /// Truncation must not be SILENT: say that rows are off-screen.
    #[test]
    fn an_overflowing_menu_shows_an_indicator() {
        let (_d, mut app) = app_with_long_menu(40);
        let painted = render(&mut app, 40, 20);
        assert!(
            painted.contains('\u{2193}') || painted.contains('\u{2195}'),
            "no overflow indicator — the list just ends:\n{painted}"
        );
    }

    /// A menu that FITS must be unchanged — no indicator, no offset.
    #[test]
    fn a_short_menu_is_untouched() {
        let (_d, mut app) = app_with_long_menu(3);
        let painted = render(&mut app, 40, 20);
        assert!(painted.contains("Fix with Codex"), "short menu lost a row");
        assert!(
            !painted.contains('\u{2193}') && !painted.contains('\u{2195}'),
            "a menu that fits painted an overflow indicator:\n{painted}"
        );
    }

    /// Click routing must map to the ITEM index, not the window row —
    /// otherwise a scrolled menu runs the wrong action.
    #[test]
    fn click_rects_carry_the_item_index_not_the_window_row() {
        let (_d, mut app) = app_with_long_menu(40);
        let last = app.context_menu.as_ref().unwrap().items.len() - 1;
        app.context_menu.as_mut().unwrap().selected = last;
        let _ = render(&mut app, 40, 20);
        let max_idx = app
            .rects
            .context_menu_items
            .iter()
            .map(|(_, i)| *i)
            .max()
            .expect("no rows registered");
        assert_eq!(
            max_idx, last,
            "the bottom row registered index {max_idx}, not {last} — a \
             click on a scrolled menu would run the wrong action"
        );
    }
}
