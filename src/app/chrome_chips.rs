//! Chrome chips → tmnl chrome integration. 2026-06-21.
//!
//! When mnml runs as a tmnl native pane, the bufferline's right
//! cluster (launcher icons / `+` / TABS chips / theme toggle /
//! window close) gets projected onto tmnl's chrome row via the
//! `Message::ChromeChips` wire message. Clicks on those chips
//! round-trip back via `Message::ChromeChipClick` (the blit
//! reader thread forwards them to `dispatch_chrome_chip_click`).
//!
//! Chip ids encode the action, no protocol-level enum required:
//!   `launcher:<idx>`       fire `[[ui.launcher_icon]]` #idx
//!   `newtab`               `tab_new(None)`
//!   `tabpage:<idx>`        `switch_tab(idx)`
//!   `tabpage:<idx>:close`  `tab_close_at(idx)`
//!   `theme_toggle`         `toggle_theme` / `open_theme_picker`
//!   `window_close`         `close_active_pane`

use super::*;
use tmnl_protocol::{ChromeChip, pack_rgba_u8};

impl App {
    /// Rebuild the chrome chip snapshot from the current bufferline
    /// state. If the new snapshot differs from `last_sent_chrome_chips`,
    /// store it in `pending_chrome_chips` for the blit loop to flush.
    /// Called once per tick from the blit main loop.
    pub fn refresh_chrome_chips(&mut self) {
        if !self.under_tmnl {
            return;
        }
        let chips = build_chrome_chips(self);
        if chips != self.last_sent_chrome_chips {
            self.last_sent_chrome_chips = chips.clone();
            self.pending_chrome_chips = Some(chips);
        }
    }

    /// Handle a `ChromeChipClick` event forwarded by the blit
    /// reader thread. `id` is one of the strings emitted by
    /// `build_chrome_chips`.
    pub fn dispatch_chrome_chip_click(&mut self, id: &str) {
        if id == "newtab" {
            self.tab_new(None);
            return;
        }
        if id == "theme_toggle" {
            if self.config.ui.theme_toggle.is_some() {
                self.toggle_theme();
            } else {
                self.open_theme_picker();
            }
            return;
        }
        if id == "window_close" {
            self.close_active_pane();
            return;
        }
        if let Some(rest) = id.strip_prefix("launcher:")
            && let Ok(idx) = rest.parse::<usize>()
            && let Some(icon) = self.config.ui.launcher_icons.get(idx)
        {
            let cmd = icon.command.clone();
            if let Some(rest) = cmd.strip_prefix(':') {
                self.run_ex_command(rest);
            } else {
                crate::command::run(&cmd, self);
            }
            return;
        }
        if let Some(rest) = id.strip_prefix("tabpage:") {
            if let Some(idx_str) = rest.strip_suffix(":close")
                && let Ok(idx) = idx_str.parse::<usize>()
            {
                self.tab_close_at(idx);
                return;
            }
            if let Ok(idx) = rest.parse::<usize>() {
                self.switch_tab(idx);
                return;
            }
        }
        // Unknown id — silently drop. Could indicate a protocol
        // version skew (tmnl forwards a chip id mnml's current
        // build doesn't know about) or a buggy id encoding;
        // toasting would be noisy.
    }
}

/// Build the chip Vec from the current App state. Mirrors the
/// order + appearance of `ui::bufferline::paint_right_cluster`
/// so what tmnl chrome shows matches what standalone mnml shows.
fn build_chrome_chips(app: &App) -> Vec<ChromeChip> {
    let t = crate::ui::theme::cur();
    let nerd = !app.config.ui.ascii_icons;
    let mut chips: Vec<ChromeChip> = Vec::new();

    // Each chip's FULL cell content (glyph + surrounding padding)
    // goes into `label` — tmnl paints every cell with the chip's
    // bg color, so ` X ` gives a 3-cell pill visually identical
    // to the standalone palette-bar version. `glyph` is unused
    // here (kept in the protocol shape for future expansion).

    // Launcher icons — NOT sent under tmnl. Tmnl has its own
    // `[[launcher_icon]]` config and paints its own row of icons
    // on the chrome strip; sending mnml's would duplicate them
    // visually. (`build_chrome_chips` only runs when
    // `app.under_tmnl == true` — see `refresh_chrome_chips`.)
    // In standalone (Apple Terminal etc) this code path doesn't
    // run at all and mnml's launcher icons still render via its
    // own palette-bar paint.
    // 2026-06-22 — user feedback: drop `+` newtab (tmnl has its
    // own `+` add-integration chip immediately to the left; ours
    // duplicated it visually) and `TABS` decorative label (too
    // wordy; the numbered chips communicate the same thing). The
    // chrome chip set is now just: tab pages + theme + close.

    // Per-tab-page chips — ` <n> ` or ` ●<n> ` for dirty. Active
    // tab page gets a separate ` × ` chip after it so the close
    // hit-rect maps to `tabpage:<i>:close` distinctly.
    for i in 0..app.layouts.len() {
        let active = i == app.active_layout;
        let dirty = app.tab_has_dirty_buffer(i);
        let label_inner = if dirty {
            format!(" \u{25CF}{} ", i + 1)
        } else {
            format!(" {} ", i + 1)
        };
        let (chip_fg, chip_bg) = if active {
            (t.bg_darker, t.blue)
        } else {
            (t.fg, t.bg2)
        };
        chips.push(ChromeChip {
            id: format!("tabpage:{i}"),
            label: label_inner,
            glyph: String::new(),
            fg: color_to_packed(chip_fg),
            bg: color_to_packed(chip_bg),
            bold: active,
        });
        if active {
            let close = if nerd { "\u{F0156}".to_string() } else { "x".to_string() };
            chips.push(ChromeChip {
                id: format!("tabpage:{i}:close"),
                label: format!("{close} "),
                glyph: String::new(),
                fg: color_to_packed(chip_fg),
                bg: color_to_packed(chip_bg),
                bold: false,
            });
        }
    }
    // Theme toggle — 4 cells: ` ●━ ` or ` ━● ` (handle position
    // tracks which theme is active).
    let on_alt = app
        .config
        .ui
        .theme_toggle
        .as_deref()
        .is_some_and(|alt| t.name.eq_ignore_ascii_case(alt));
    let pill = if on_alt {
        " \u{2501}\u{25CF} "
    } else {
        " \u{25CF}\u{2501} "
    };
    chips.push(ChromeChip {
        id: "theme_toggle".to_string(),
        label: pill.to_string(),
        glyph: String::new(),
        fg: color_to_packed(t.fg),
        bg: color_to_packed(t.bg2),
        bold: false,
    });
    // ` × ` window close — 3 cells, red bg + bold dark fg.
    let close_glyph = if nerd { "\u{F0156}".to_string() } else { "x".to_string() };
    chips.push(ChromeChip {
        id: "window_close".to_string(),
        label: format!(" {close_glyph} "),
        glyph: String::new(),
        fg: color_to_packed(t.bg_darker),
        bg: color_to_packed(t.red),
        bold: true,
    });
    chips
}

/// Convert a ratatui `Color` to the protocol's packed RGBA. The
/// theme palette only uses `Rgb(r,g,b)`; other variants fall back
/// to `pack_rgba_u8(0xff, 0xff, 0xff, 0xff)` (white) — should
/// never fire in practice.
fn color_to_packed(c: ratatui::style::Color) -> u32 {
    match c {
        ratatui::style::Color::Rgb(r, g, b) => pack_rgba_u8(r, g, b, 0xff),
        _ => pack_rgba_u8(0xff, 0xff, 0xff, 0xff),
    }
}
