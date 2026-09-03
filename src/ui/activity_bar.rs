//! VSCode-style activity bar — a 4-cell vertical strip on the far left
//! of the rail, with one icon per [`ActivitySection`]. Clicking an
//! icon switches `App.active_section`, which the rail layout uses to
//! pick which content pane fills the area to the right of this strip.
//!
//! Every section ships live content: Explorer (file tree), Search
//! (ripgrep), Git (branch + worktrees), Debug (DAP), Integrations
//! (installed integration chips), Sessions (open Pty tabs), Agents
//! (Claude/Codex dashboard), Cloud Agents (ECS runner), HTTP
//! (`.http` / `.curl` files), Notes (`.mnml/notes/*.md`), TODOs
//! (workspace grep for TODO/FIXME/HACK), Findings
//! (`.mnml/findings/*.md`). Plus LauncherIcon (pinned integration
//! chip) and Mount (integration-owned side panel) that individual
//! integration repos add via the marketplace flow.

//!
//! TODO (user ask 2026-09-03) — give the activity bar the same three
//! visibility modes the menu bar has (`[ui] menu_bar`): `always` (the
//! current and only behaviour), `auto`, and `hidden`. Reuse that
//! config shape and its vocabulary rather than inventing a second set
//! of mode names — a user who has set one should be able to guess the
//! other.
//!
//! `auto` is the one with a real design question. The menu bar's
//! trigger is unambiguous because the chrome row is the top edge of
//! the terminal, so "pointer on that row" cannot mean anything else.
//! The activity bar is a vertical strip against the left edge, and the
//! cells immediately right of it belong to the tree — so a naive
//! "pointer within N columns" reveal would flash the bar while the
//! user is aiming at a tree row. Start with pointer in column 0 only,
//! and widen it only if that proves too fussy in practice.
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::Line;
use ratatui::widgets::Paragraph;

use crate::app::{ActivitySection, App};
use crate::ui::theme;

/// Width of the activity bar strip in cells. 3 cells = 1 padding + 1
/// glyph + 1 padding. Was 4 (trailing spacer column) but the extra
/// cell read as a too-wide gap between the window edge and the
/// rail. Matches vscode's visual weight at this terminal-cell
/// density.
pub const ACTIVITY_BAR_WIDTH: u16 = 3;

/// Pulse duty cycle for the activity-bar notification badge. Icon
/// shows for `PULSE_ICON_SECS`, then the count shows for
/// `PULSE_COUNT_SECS`, then repeat. Time source is a process-static
/// `Instant` so the cycle is stable within a session and there's no
/// tick state to thread through `App`.
const PULSE_ICON_SECS: u64 = 4;
const PULSE_COUNT_SECS: u64 = 1;

fn badge_pulse_showing_count() -> bool {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(std::time::Instant::now);
    let elapsed = start.elapsed().as_secs();
    let period = PULSE_ICON_SECS + PULSE_COUNT_SECS;
    elapsed % period >= PULSE_ICON_SECS
}

/// Paint the activity bar into `area`. Registers a click rect per
/// icon on `app.rects.activity_bar_icons` so mouse handling can
/// resolve a click → `ActivitySection`.
pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    app.rects.activity_bar_icons.clear();
    app.rects.activity_bar_gear = None;

    let t = theme::cur();
    let bar_bg = t.bg_darker;
    let nerd = !app.config.ui.ascii_icons;

    // Solid background fill so the strip is visually distinct from
    // the section content area to its right.
    frame.render_widget(
        ratatui::widgets::Block::default().style(Style::default().bg(bar_bg)),
        area,
    );

    // Gear icon at the BOTTOM of the activity bar (VS Code's
    // customary settings position). Click pops a context menu with
    // Settings / Command Palette / Cheatsheet / Themes / About.
    // Painted before the section icons so it has dibs on the bottom
    // row; sections that would overflow into it are clipped.
    let gear_glyph = if nerd { "\u{F013}" } else { "*" }; // nf-fa-cog
    if area.height >= 2 {
        let gear_y = area.y + area.height - 2;
        let gear_row = Rect {
            x: area.x,
            y: gear_y,
            width: area.width,
            height: 1,
        };
        let gear_rect = Rect {
            x: area.x + 1,
            y: gear_y,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(gear_glyph)).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bar_bg)
                    .add_modifier(Modifier::DIM),
            ),
            gear_rect,
        );
        app.rects.activity_bar_gear = Some(gear_row);
    }
    // The notifications bell used to live here, directly above the
    // gear. It was added when the only other route to the message
    // history was a statusline badge HIDDEN until something went wrong,
    // so nothing on screen said the feature existed.
    //
    // That reason is gone: the statusline bell is now ALWAYS present
    // (quiet when idle) and sits beside the clock, where the user asked
    // for it and prefers it. Two permanent bells for one history is one
    // too many, so this one is removed rather than kept "just in case"
    // — the rect field and its click handler are removed too, rather
    // than left as dead code.

    // Carve the section-icon paint area so it stops above the gear.
    // Was `- 4` to also clear the bell that used to sit above it; the
    // sections get that row back now.
    let icons_end_y = area.y + area.height.saturating_sub(3);

    let icon_x = area.x + 1; // 1 cell of left padding
    let mut y = area.y + 1; // start 1 row down for top padding

    // Row step: 2 (icon + a blank spacer) when everything fits, 1 when
    // it does not.
    //
    // The loops below simply BREAK at `icons_end_y`, so a short terminal
    // silently dropped whatever came last — at 28 rows a tester found
    // TODOS, FINDINGS and every launcher gone, with no overflow marker
    // and no way to reach them by mouse at all.
    //
    // Halving the step doubles capacity and degrades gracefully: the
    // rail gets denser rather than shorter. Truncation is still possible
    // on a genuinely tiny terminal, but it now takes half the height to
    // reach it.
    let items = ActivitySection::all().len()
        + app.mount_manifests.len()
        + app.config.ui.activity_bar_pinned_integrations.len();
    let avail = icons_end_y.saturating_sub(area.y + 1) as usize;
    let step: u16 = if items * 2 > avail { 1 } else { 2 };

    for section in ActivitySection::all() {
        if y >= icons_end_y {
            break;
        }
        let (glyph_nerd, fallback, _tooltip, _cmd) = section.meta();
        let glyph = if nerd { glyph_nerd } else { fallback };
        let is_active = app.active_section == *section;

        // Active icon: blue fg, bold, with a left-edge accent bar.
        // Inactive: dim fg, no accent.
        let style = if is_active {
            Style::default()
                .fg(t.blue)
                .bg(bar_bg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
                .fg(t.comment)
                .bg(bar_bg)
                .add_modifier(Modifier::DIM)
        };
        let row = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        // Accent bar on the leftmost column when active.
        if is_active && area.width >= 1 {
            let accent_rect = Rect {
                x: area.x,
                y,
                width: 1,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from("▌")).style(Style::default().fg(t.blue).bg(bar_bg)),
                accent_rect,
            );
        }
        let glyph_rect = Rect {
            x: icon_x,
            y,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(glyph)).style(style), glyph_rect);
        // Notification badge — small orange dot or digit on the
        // right edge of the icon row when an integration has set one
        // via the `set-activity-badge` IPC command. Goal: surface
        // queue depth / action-needed counts without taking focus.
        let badge_count = section
            .badge_key(app)
            .map(|k| app.activity_badge_for(&k))
            .unwrap_or(0);
        // 2026-08-24 (user ask) — badge PULSES over the icon instead
        // of statically covering it. The 3-cell activity strip is too
        // narrow for a real superscript, and the prior badge_rect at
        // `x + width - 2` (col 1 of a 3-cell strip) sat directly on
        // top of the 2-cell nerd font glyph, so the terminal blanked
        // the wide char and the "2" read as if it had replaced the
        // icon entirely. Pulse: icon shown ~4s, badge shown ~1s,
        // repeat. Icon stays the primary signal; count still surfaces
        // periodically. Only the last render's second-precision is
        // needed — no per-tick state on App.
        if badge_count > 0 && area.width >= 3 && badge_pulse_showing_count() {
            let badge_glyph = if badge_count == 1 {
                "•".to_string()
            } else if badge_count <= 9 {
                badge_count.to_string()
            } else {
                "+".to_string()
            };
            // Full glyph column so the count is legible; overwriting
            // the icon is fine during the ~1s pulse window.
            let badge_rect = Rect {
                x: icon_x,
                y,
                width: area.width.saturating_sub(1),
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(badge_glyph)).style(
                    Style::default()
                        .fg(t.orange)
                        .bg(bar_bg)
                        .add_modifier(Modifier::BOLD),
                ),
                badge_rect,
            );
        }
        app.rects.activity_bar_icons.push((row, *section));
        // 2 rows per icon for breathing room.
        y = y.saturating_add(step);
    }
    // Manifest-registered Mount sections. Rendered after the
    // builtins so they live in the "this workspace's tools" zone
    // visually distinct from the always-on builtins.
    for (idx, manifest) in app.mount_manifests.clone().iter().enumerate() {
        if y >= icons_end_y {
            break;
        }
        let section = crate::app::ActivitySection::Mount(idx as u16);
        let is_active = app.active_section == section;
        let glyph = if nerd {
            manifest.icon.as_str()
        } else {
            // Fall back to the first character of the name.
            manifest.name.get(..1).unwrap_or("M")
        };
        let color = manifest.color_for_theme(&t);
        let style = if is_active {
            Style::default()
                .fg(color)
                .bg(bar_bg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
                .fg(t.comment)
                .bg(bar_bg)
                .add_modifier(Modifier::DIM)
        };
        let row = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        if is_active && area.width >= 1 {
            let accent_rect = Rect {
                x: area.x,
                y,
                width: 1,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from("▌")).style(Style::default().fg(color).bg(bar_bg)),
                accent_rect,
            );
        }
        let glyph_rect = Rect {
            x: icon_x,
            y,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(glyph)).style(style), glyph_rect);
        // Notification badge for manifest mounts — same shape as
        // for builtins above.
        let badge_count = app.activity_badge_for(&manifest.id);
        // 2026-08-24 (user ask) — badge PULSES over the icon instead
        // of statically covering it. The 3-cell activity strip is too
        // narrow for a real superscript, and the prior badge_rect at
        // `x + width - 2` (col 1 of a 3-cell strip) sat directly on
        // top of the 2-cell nerd font glyph, so the terminal blanked
        // the wide char and the "2" read as if it had replaced the
        // icon entirely. Pulse: icon shown ~4s, badge shown ~1s,
        // repeat. Icon stays the primary signal; count still surfaces
        // periodically. Only the last render's second-precision is
        // needed — no per-tick state on App.
        if badge_count > 0 && area.width >= 3 && badge_pulse_showing_count() {
            let badge_glyph = if badge_count == 1 {
                "•".to_string()
            } else if badge_count <= 9 {
                badge_count.to_string()
            } else {
                "+".to_string()
            };
            // Full glyph column so the count is legible; overwriting
            // the icon is fine during the ~1s pulse window.
            let badge_rect = Rect {
                x: icon_x,
                y,
                width: area.width.saturating_sub(1),
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(badge_glyph)).style(
                    Style::default()
                        .fg(t.orange)
                        .bg(bar_bg)
                        .add_modifier(Modifier::BOLD),
                ),
                badge_rect,
            );
        }
        app.rects.activity_bar_icons.push((row, section));
        y = y.saturating_add(step);
    }
    // 2026-07-20 — user-pinned integration launcher icons. Each
    // fires the integration chip's `command` on click (spawns a
    // Pty pane), no side panel. Rendered AFTER Mount manifests so
    // the visual grouping is: builtins · manifest mounts · pins.
    let pinned = app.config.ui.activity_bar_pinned_integrations.clone();
    for (idx, integ_id) in pinned.iter().enumerate() {
        if y >= icons_end_y {
            break;
        }
        let Some(icon) = app
            .config
            .ui
            .integration_icons
            .iter()
            .find(|i| &i.id == integ_id)
        else {
            // Pinned id vanished from integration list — skip
            // silently. The right-click menu will offer "Add" (not
            // "Remove") next time since integration_is_docked
            // reads the list.
            continue;
        };
        let section = crate::app::ActivitySection::LauncherIcon(idx as u16);
        let is_active = app.active_section == section;
        let glyph = if nerd {
            icon.glyph.as_str()
        } else {
            icon.fallback.as_str()
        };
        let color = crate::ui::theme::color_from_slot(&icon.color, &t);
        let style = if is_active {
            Style::default()
                .fg(color)
                .bg(bar_bg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
                .fg(color)
                .bg(bar_bg)
                .add_modifier(Modifier::DIM)
        };
        let row = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let glyph_rect = Rect {
            x: icon_x,
            y,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(glyph)).style(style), glyph_rect);
        app.rects.activity_bar_icons.push((row, section));
        y = y.saturating_add(step);
    }
}

#[cfg(test)]
mod density_tests {
    use crate::app::App;
    use crate::config::Config;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;

    fn sections_drawn(h: u16) -> usize {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let w = 4u16;
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
        app.rects.activity_bar_icons.len()
    }

    /// TESTER SEV-2 — a short terminal silently dropped sections from
    /// the rail, with no overflow marker and no way to reach them by
    /// mouse. The loops simply broke at the carve line.
    ///
    /// The step halves when things do not fit, so the rail gets DENSER
    /// rather than shorter.
    ///
    /// Measured at 16 rows, not the tester's 28: with only the built-in
    /// sections, 12 icons still fit at 28 even with the old fixed step,
    /// so 28 does not reproduce it. Their instance had launchers pinned,
    /// which this test cannot fake — a pinned id only draws if it
    /// resolves to a real `integration_icon`. 16 rows exercises the same
    /// code path honestly.
    #[test]
    fn a_short_terminal_keeps_every_section() {
        let tall = sections_drawn(44);
        let short = sections_drawn(16);
        assert!(tall > 0, "setup: nothing drawn even at 44 rows");
        assert_eq!(
            short, tall,
            "a 16-row terminal shows {short} sections vs {tall} at 44 — \
             the rest are unreachable by mouse"
        );
    }

    /// The dense mode must only kick in when it is needed — a tall
    /// terminal keeps its spacing.
    #[test]
    fn a_tall_terminal_keeps_the_spacing() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let (w, h) = (4u16, 44u16);
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
        let mut ys: Vec<u16> = app
            .rects
            .activity_bar_icons
            .iter()
            .map(|(r, _)| r.y)
            .collect();
        ys.sort_unstable();
        assert!(ys.len() >= 2, "setup: too few sections");
        assert_eq!(
            ys[1] - ys[0],
            2,
            "a 44-row terminal went dense when it did not need to"
        );
    }
}
