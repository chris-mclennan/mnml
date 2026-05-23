//! mixr DJ panel host — spawns the sibling `mixr` binary as a
//! tmnl-protocol native client, blits its frames into a docked
//! pane, routes keys/mouse back to the child.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//! (`.local/PLAN.md` Phase C.6). Pure non-destructive move.

use super::*;

fn mixr_on_path() -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join("mixr");
        if let Ok(meta) = std::fs::metadata(&candidate)
            && meta.is_file()
        {
            return true;
        }
    }
    false
}

impl App {
    /// Open / toggle the native mixr panel — mnml hosts `mixr --blit`
    /// itself (`mixr_host::MixrPanel`). First call launches it as a
    /// bottom strip; later calls cycle: bottom strip → full →
    /// minimized → bottom strip (the `♪` statusline chip is the
    /// minimized state). Refuses cleanly when `mixr` isn't on PATH.
    pub fn open_mixr_pane(&mut self) {
        if !mixr_on_path() {
            self.toast("mixr not found on PATH — install mixr-rs first");
            return;
        }
        if let Some(p) = self.mixr_panel.as_mut() {
            use crate::mixr_host::MixrSize;
            // Cycle: minimized → bottom strip → full → minimized.
            p.size = match p.size {
                MixrSize::Minimized => MixrSize::BottomStrip,
                MixrSize::BottomStrip => MixrSize::Full,
                // Floating (drag-entered) also cycles back to hidden.
                MixrSize::Full | MixrSize::Floating => MixrSize::Minimized,
            };
            p.focused = p.size != MixrSize::Minimized;
            return;
        }
        // First open — launch `mixr --blit` sized to the bottom strip
        // (best-effort; `tick` keeps it sized to its rect).
        let (cols, rows) = self
            .rects
            .body
            .map(|b| {
                (
                    b.width.min(crate::mixr_host::MAX_WIDTH),
                    crate::mixr_host::STRIP_ROWS.min(b.height),
                )
            })
            .unwrap_or((80, 22));
        // Hand mixr mnml's active theme so it re-themes to match: the
        // editor-body background, primary text, and an accent (blue).
        let theme = crate::ui::theme::cur();
        let palette = (
            crate::mixr_host::pack_color(theme.bg_dark),
            crate::mixr_host::pack_color(theme.fg),
            crate::mixr_host::pack_color(theme.blue),
        );
        match crate::mixr_host::MixrPanel::launch(cols, rows, palette) {
            Ok(mut p) => {
                p.focused = true;
                self.mixr_panel = Some(p);
            }
            Err(e) => self.toast(format!("mixr: {e}")),
        }
    }

    /// Drain frames from the hosted mixr panel + keep it sized to its
    /// docked rect. No-op until `mixr.show` launches the panel.
    pub(super) fn drain_mixr_panel(&mut self) {
        let rect = self.rects.mixr_panel;
        if let Some(p) = self.mixr_panel.as_mut() {
            if p.drain_frames() {
                self.redraw_requested = true;
            }
            if let Some(r) = rect {
                p.resize(r.width, r.height);
            }
        }
    }
}
