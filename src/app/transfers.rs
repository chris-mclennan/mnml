//! `App`-side wiring for background file transfers.
//!
//! #files item 6. The file operations used to run synchronously on the
//! render thread: `copy_recursively` on a large directory froze mnml
//! until it finished. Everything now goes through `crate::transfer`'s
//! worker — the user chose "everything async" over a size threshold, so
//! there is ONE path and a small copy behaves exactly like a large one.
//!
//! The cost of that choice, named rather than hidden: a paste no longer
//! completes before the next frame, so the listing refreshes a tick
//! later. In exchange nothing can ever freeze the editor, and a 4 GB
//! copy is cancellable.

use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use crate::transfer::{Transfer, TransferKind, TransferMsg, TransferState};

impl crate::app::App {
    /// Start a transfer and return its id.
    ///
    /// One channel shared by every worker (each gets a `Sender` clone),
    /// so the render loop drains a single receiver per tick regardless of
    /// how many transfers are running.
    pub fn start_transfer(
        &mut self,
        kind: TransferKind,
        items: Vec<(std::path::PathBuf, std::path::PathBuf)>,
    ) -> u64 {
        let id = self.next_transfer_id;
        self.next_transfer_id += 1;
        let cancel = Arc::new(AtomicBool::new(false));
        let sources: Vec<std::path::PathBuf> = items.iter().map(|(s, _)| s.clone()).collect();
        let dest = items.first().map(|(_, d)| d.clone());
        self.transfers
            .push(Transfer::new(id, kind, sources, dest, Arc::clone(&cancel)));
        crate::transfer::spawn(id, kind, items, cancel, self.transfer_tx.clone());
        id
    }

    /// Drain worker messages. Called once per tick from the event loop.
    ///
    /// Returns true when anything changed, so the caller can redraw —
    /// progress that only appears on the next unrelated keystroke reads
    /// as a hang, which is the thing this whole subsystem exists to
    /// avoid.
    pub fn poll_transfers(&mut self) -> bool {
        let mut changed = false;
        let mut finished: Vec<u64> = Vec::new();
        while let Ok(msg) = self.transfer_rx.try_recv() {
            changed = true;
            let id = match &msg {
                TransferMsg::Total { id, .. }
                | TransferMsg::Progress { id, .. }
                | TransferMsg::Done { id, .. }
                | TransferMsg::Failed { id, .. }
                | TransferMsg::Cancelled { id, .. } => *id,
            };
            if let Some(t) = self.transfers.iter_mut().find(|t| t.id == id)
                && t.apply(&msg)
            {
                finished.push(id);
            }
        }
        for id in finished {
            let Some(t) = self.transfers.iter().find(|t| t.id == id) else {
                continue;
            };
            let verb = t.kind.verb();
            let msg = match &t.state {
                TransferState::Done => {
                    let n = t.files_done;
                    // Skipped files are named, never swallowed: a copy
                    // that quietly left things behind is worse than one
                    // that failed loudly.
                    let skipped = t.files_total.saturating_sub(t.files_done);
                    if skipped > 0 {
                        format!("{verb} finished — {n} items, {skipped} skipped")
                    } else {
                        format!("{verb} finished — {n} items")
                    }
                }
                TransferState::Failed(e) => format!("{verb} failed: {e}"),
                TransferState::Cancelled => format!("{verb} cancelled"),
                _ => continue,
            };
            self.toast(msg);
            // The filesystem moved under every Files pane and the tree.
            self.refresh_after_fs_change();
        }
        // Keep finished transfers only until they have been reported, so
        // the chip does not accumulate a history nobody asked for. The
        // Transfers detail view (deferred) is where a history would live.
        self.transfers.retain(|t| !t.state.is_terminal());
        changed
    }

    /// Cancel every running transfer. Bound to the chip and the palette.
    pub fn cancel_all_transfers(&mut self) {
        let mut n = 0;
        for t in &self.transfers {
            if !t.state.is_terminal() {
                t.cancel();
                n += 1;
            }
        }
        if n > 0 {
            self.toast(format!(
                "cancelling {n} transfer{}",
                if n == 1 { "" } else { "s" }
            ));
        }
    }

    /// Aggregate chip text, or `None` when nothing is running.
    ///
    /// Constant-ish width and hidden entirely at rest, following the
    /// Sonos chip rule — the statusline's right lane is right-aligned, so
    /// a chip that changes width slides every neighbour.
    pub fn transfer_chip(&self) -> Option<String> {
        let running: Vec<&Transfer> = self
            .transfers
            .iter()
            .filter(|t| !t.state.is_terminal())
            .collect();
        if running.is_empty() {
            return None;
        }
        let done: u64 = running.iter().map(|t| t.bytes_done).sum();
        let total: u64 = running.iter().map(|t| t.bytes_total).sum();
        let pct = if total == 0 {
            0
        } else {
            ((done as f64 / total as f64) * 100.0).clamp(0.0, 100.0) as u8
        };
        // Speed is summed across transfers; `None` from any of them just
        // contributes nothing rather than suppressing the whole reading.
        let speed: f64 = running.iter().filter_map(|t| t.speed_bytes_per_sec()).sum();
        let n = running.len();
        let prefix = if n > 1 {
            format!("\u{21c4}{n} ")
        } else {
            "\u{21c4} ".to_string()
        };
        if speed > 0.0 {
            Some(format!(
                "{prefix}{pct}% {}/s",
                crate::transfer::human_bytes(speed as u64)
            ))
        } else {
            Some(format!("{prefix}{pct}%"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::App;
    use crate::config::Config;

    fn app() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        (d, app)
    }

    /// Nothing running ⇒ no chip at all. A permanent "0%" in the
    /// statusline is noise, and the right lane is right-aligned so an
    /// always-present chip shifts every neighbour for no reason.
    #[test]
    fn the_chip_is_absent_when_nothing_is_running() {
        let (_d, app) = app();
        assert!(app.transfer_chip().is_none());
    }

    #[test]
    fn a_copy_runs_to_completion_through_the_app() {
        let (d, mut app) = app();
        let src = d.path().join("a.txt");
        std::fs::write(&src, vec![0u8; 4096]).unwrap();
        let dst_dir = d.path().join("out");
        std::fs::create_dir(&dst_dir).unwrap();

        app.start_transfer(TransferKind::Copy, vec![(src, dst_dir.join("a.txt"))]);
        // Drain until the worker finishes; bounded so a hang fails the
        // test rather than wedging the suite.
        let t0 = std::time::Instant::now();
        while !app.transfers.is_empty() && t0.elapsed() < std::time::Duration::from_secs(10) {
            app.poll_transfers();
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(
            dst_dir.join("a.txt").is_file(),
            "the file never landed at the destination"
        );
        assert!(
            app.transfers.is_empty(),
            "a finished transfer was never retired"
        );
    }

    /// The whole point of moving off the render thread: starting a
    /// transfer must RETURN, not block until the copy is done.
    #[test]
    fn starting_a_transfer_does_not_block() {
        let (d, mut app) = app();
        let src = d.path().join("big");
        std::fs::create_dir(&src).unwrap();
        for i in 0..200 {
            std::fs::write(src.join(format!("f{i}")), vec![0u8; 8192]).unwrap();
        }
        let out = d.path().join("out");
        std::fs::create_dir(&out).unwrap();

        let t0 = std::time::Instant::now();
        app.start_transfer(TransferKind::Copy, vec![(src, out.join("big"))]);
        let elapsed = t0.elapsed();
        assert!(
            elapsed < std::time::Duration::from_millis(200),
            "start_transfer blocked for {elapsed:?} — it is still doing the \
             copy on the calling thread"
        );
        app.cancel_all_transfers();
    }
}
