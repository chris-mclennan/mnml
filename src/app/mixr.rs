//! mixr DJ panel host — spawns the sibling `mixr` binary as a
//! tmnl-protocol native client, blits its frames into a docked
//! pane, routes keys/mouse back to the child.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move.

use super::*;

/// True iff `mixr` resolves to an executable on `$PATH`. Walks `$PATH`
/// entries and probes for the binary; cheap, sync, no extra crate.
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
        // A mixr is already alive that mnml doesn't own — the user
        // launched it standalone (its own terminal / tmnl tab), or it
        // outlived a previous mnml. Hosting it in a blit pane is
        // impossible (it renders to its own screen, not our socket), and
        // spawning a *second* mixr would make two processes fight over
        // the one audio device and the shared `~/.mixr/command` channel.
        // So don't spawn — the ♪ transport chips already remote-control
        // it via the command file (see `tui::send_mixr_command`).
        if crate::now_playing::mixr::is_running() {
            self.toast("mixr already running — control it from the ♪ chip");
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

    /// Launch mixr in its own durable home — the "music keeps playing
    /// after I close mnml" path. Under tmnl it becomes a sibling
    /// **native tab** that survives mnml's exit (via [`Self::launch_tool`],
    /// the same promote-to-own-tab machinery `htop`/`claude` use).
    /// Standalone it opens mixr's full TUI in a `Pane::Pty` — which,
    /// like any in-mnml pane, still dies with mnml; durable *standalone*
    /// needs mixr's headless audio daemon (a later phase).
    ///
    /// Unlike [`Self::open_mixr_pane`] (an ephemeral blit panel mnml
    /// owns and kills on close), this hands mixr off so mnml is no
    /// longer its owner. Won't start a *second* mixr next to a live one
    /// — the same audio-device / `~/.mixr/command` contention the pane
    /// guard avoids.
    pub fn launch_mixr(&mut self) {
        if crate::now_playing::mixr::is_running() {
            self.toast("mixr already running — control it from the ♪ chip");
            return;
        }
        self.launch_tool("mixr", Vec::new());
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
