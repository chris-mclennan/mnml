//! App-level glue for the generic blit-host facility. Opens a new
//! `Pane::BlitHost` by spawning an arbitrary binary that speaks the
//! tmnl-protocol blit wire (`<binary> --blit <socket>`). The
//! `:host.launch <binary> [args…]` ex-command lands here.

use super::*;
use crate::pane_host::{BlitChannel, BlitHostPane, HostPalette, pack_color};
use crate::ui::theme;

impl App {
    /// Launch `binary` (with optional `args`) as a `Pane::BlitHost` in
    /// a split below the focused leaf. The binary must accept a
    /// `--blit <socket>` argument and speak tmnl-protocol — see
    /// `docs/PLUGINS.md` for the blit-host integration class. Toasts
    /// on failure (socket bind, child spawn).
    pub fn host_launch(&mut self, binary: String, args: Vec<String>) {
        // Initial grid is a placeholder — mnml's draw pass will fire a
        // `Resize` to the actual pane area on its first frame, and the
        // child's first `Frame` will reshape `cells`.
        const INIT_COLS: u16 = 80;
        const INIT_ROWS: u16 = 24;
        let palette = blit_host_palette();
        let channel = match BlitChannel::launch(&binary, &args, INIT_COLS, INIT_ROWS, palette) {
            Ok(c) => c,
            Err(e) => {
                self.toast(format!("host.launch: {e}"));
                return;
            }
        };
        let pane = Pane::BlitHost(BlitHostPane::new(channel));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
        self.toast(format!("host: launched {binary}"));
    }

    /// Drain pending frames from every open `Pane::BlitHost`. Cheap
    /// when channels are idle. Called from `App::tick`.
    pub(super) fn drain_blit_host_events(&mut self) {
        // First pass: drain frames + collect any OpenFile messages
        // the hosted children have sent. We can't open files
        // mid-iteration because that mutates `self.panes`; collect
        // the paths, then process them after the loop.
        let mut pending_open_paths: Vec<String> = Vec::new();
        for pane in self.panes.iter_mut() {
            if let Pane::BlitHost(p) = pane {
                p.channel.drain_frames();
                pending_open_paths.extend(p.channel.drain_open_files());
            }
        }
        for path in pending_open_paths {
            self.host_open_file(path);
        }
    }

    /// Open a file path that a hosted blit-host child sent via
    /// `Message::OpenFile`. Resolves the path, opens it as an
    /// editor buffer (existing behaviour from
    /// [`Self::open_path`]), and toasts the outcome.
    pub(super) fn host_open_file(&mut self, path: String) {
        let p = std::path::PathBuf::from(&path);
        if !p.exists() {
            self.toast(format!("blit-host OpenFile: {path} does not exist"));
            return;
        }
        self.open_path(&p);
        self.toast(format!("opened from blit-host: {path}"));
    }
}

/// Build the `(bg, fg, accent)` palette to hand to the child on
/// connect — mnml's active theme, packed as the wire format.
fn blit_host_palette() -> HostPalette {
    let t = theme::cur();
    (pack_color(t.bg), pack_color(t.fg), pack_color(t.blue))
}
