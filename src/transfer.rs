//! Background file transfers — copy / move / delete with progress.
//!
//! #files item 6. **User ask 2026-08-30:** "we might need somewhere to
//! show transfer info like progress and speed."
//!
//! This is also the GATE on everything bulk in the Files pane. The file
//! operations are synchronous on the render thread today: a
//! `copy_recursively` of a 4 GB directory freezes mnml and reports by
//! toast when it eventually finishes. That is unacceptable for a file
//! manager, so the worker has to exist before cross-pane drag or
//! multi-select operations on large sets.
//!
//! Shape follows the Sonos worker and the git loader — one worker thread
//! reporting over an mpsc channel, the render loop never blocking on the
//! filesystem.
//!
//! Speed and ETA are DERIVED from bytes + elapsed rather than stored, so
//! they cannot go stale while a transfer sits between progress messages.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferKind {
    Copy,
    Move,
    Delete,
}

impl TransferKind {
    pub fn verb(self) -> &'static str {
        match self {
            TransferKind::Copy => "Copying",
            TransferKind::Move => "Moving",
            TransferKind::Delete => "Deleting",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransferState {
    /// Walking the sources to compute a byte total. Progress is not yet
    /// meaningful, so the UI shows an indeterminate state rather than a
    /// misleading 0%.
    Sizing,
    Running,
    Done,
    Failed(String),
    Cancelled,
}

impl TransferState {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            TransferState::Done | TransferState::Failed(_) | TransferState::Cancelled
        )
    }
}

/// What a worker sends back. Every variant carries the id because the
/// app multiplexes several transfers onto one receiver.
#[derive(Debug, Clone)]
pub enum TransferMsg {
    /// The sizing pass finished — totals are now known.
    Total {
        id: u64,
        bytes_total: u64,
        files_total: usize,
    },
    Progress {
        id: u64,
        bytes_done: u64,
        files_done: usize,
    },
    Done {
        id: u64,
        /// Entries left behind because they could not be read or had
        /// vanished. A transfer that quietly skipped files must say so.
        skipped: usize,
    },
    Failed {
        id: u64,
        err: String,
        /// Whether the partial destination was cleaned up — the same
        /// promise `Cancelled` makes. A hard failure is no different
        /// from the user's side.
        cleaned_up: bool,
    },
    Cancelled {
        id: u64,
        /// Whether the partial destination was cleaned up. A cancel that
        /// leaves debris must SAY so — silently leaving half a directory
        /// behind is worse than not offering cancel.
        cleaned_up: bool,
    },
}

#[derive(Debug)]
pub struct Transfer {
    pub id: u64,
    pub kind: TransferKind,
    pub sources: Vec<PathBuf>,
    /// Destination directory. `None` for a delete.
    pub dest: Option<PathBuf>,
    pub bytes_total: u64,
    pub bytes_done: u64,
    pub files_total: usize,
    pub files_done: usize,
    pub started_at: Instant,
    pub finished_at: Option<Instant>,
    pub state: TransferState,
    cancel_flag: Arc<AtomicBool>,
}

impl Transfer {
    pub fn new(
        id: u64,
        kind: TransferKind,
        sources: Vec<PathBuf>,
        dest: Option<PathBuf>,
        cancel_flag: Arc<AtomicBool>,
    ) -> Self {
        Transfer {
            id,
            kind,
            sources,
            dest,
            bytes_total: 0,
            bytes_done: 0,
            files_total: 0,
            files_done: 0,
            started_at: Instant::now(),
            finished_at: None,
            state: TransferState::Sizing,
            cancel_flag,
        }
    }

    /// Request cancellation. The worker checks the flag between files, so
    /// a single enormous file still finishes copying — cancelling mid-file
    /// would leave a truncated destination that looks complete.
    pub fn cancel(&self) {
        self.cancel_flag.store(true, Ordering::Relaxed);
    }

    pub fn is_cancelling(&self) -> bool {
        self.cancel_flag.load(Ordering::Relaxed) && !self.state.is_terminal()
    }

    /// 0..=100. Reports 100 for a finished transfer even when the byte
    /// total was wrong (a file that shrank between the sizing pass and
    /// the copy), because "Done at 97%" reads as a failure.
    pub fn percent(&self) -> u8 {
        if self.state == TransferState::Done {
            return 100;
        }
        if self.bytes_total == 0 {
            return 0;
        }
        let pct = (self.bytes_done as f64 / self.bytes_total as f64 * 100.0).round();
        pct.clamp(0.0, 100.0) as u8
    }

    /// Elapsed time — frozen at completion, so a finished transfer's
    /// average speed does not decay while it sits in the list.
    pub fn elapsed(&self) -> Duration {
        self.finished_at
            .unwrap_or_else(Instant::now)
            .saturating_duration_since(self.started_at)
    }

    /// Bytes per second, or `None` before there is enough signal to be
    /// honest about. A speed computed over the first few milliseconds is
    /// noise, and showing "1.4 GB/s" that immediately collapses is worse
    /// than showing nothing.
    pub fn speed_bytes_per_sec(&self) -> Option<f64> {
        let secs = self.elapsed().as_secs_f64();
        if secs < 0.25 || self.bytes_done == 0 {
            return None;
        }
        Some(self.bytes_done as f64 / secs)
    }

    pub fn eta(&self) -> Option<Duration> {
        if self.state.is_terminal() || self.bytes_total == 0 {
            return None;
        }
        let speed = self.speed_bytes_per_sec()?;
        if speed <= 0.0 {
            return None;
        }
        let remaining = self.bytes_total.saturating_sub(self.bytes_done);
        Some(Duration::from_secs_f64(remaining as f64 / speed))
    }

    /// Fold one worker message into this transfer. Returns true when the
    /// message moved it to a terminal state, so the caller can toast once.
    pub fn apply(&mut self, msg: &TransferMsg) -> bool {
        match msg {
            TransferMsg::Total {
                bytes_total,
                files_total,
                ..
            } => {
                self.bytes_total = *bytes_total;
                self.files_total = *files_total;
                // Sizing is over even if the total is zero (an empty
                // directory); leaving it in Sizing would stall the UI.
                self.state = TransferState::Running;
                false
            }
            TransferMsg::Progress {
                bytes_done,
                files_done,
                ..
            } => {
                self.bytes_done = *bytes_done;
                self.files_done = *files_done;
                false
            }
            TransferMsg::Done { .. } => {
                self.state = TransferState::Done;
                self.finished_at = Some(Instant::now());
                true
            }
            TransferMsg::Failed { err, .. } => {
                self.state = TransferState::Failed(err.clone());
                self.finished_at = Some(Instant::now());
                true
            }
            TransferMsg::Cancelled { .. } => {
                self.state = TransferState::Cancelled;
                self.finished_at = Some(Instant::now());
                true
            }
        }
    }
}

/// Total bytes and file count under `paths`, following the same rules the
/// copy will.
///
/// Symlinks are counted as one file of their own (link) size and never
/// followed — following them would double-count a link into the tree and
/// can loop forever on a cycle.
pub fn measure(paths: &[PathBuf], cancel: &AtomicBool) -> (u64, usize) {
    let mut bytes = 0u64;
    let mut files = 0usize;
    let mut stack: Vec<PathBuf> = paths.to_vec();
    while let Some(p) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let Ok(md) = std::fs::symlink_metadata(&p) else {
            continue;
        };
        if md.is_dir() {
            if let Ok(rd) = std::fs::read_dir(&p) {
                for e in rd.flatten() {
                    stack.push(e.path());
                }
            }
        } else {
            bytes = bytes.saturating_add(md.len());
            files += 1;
        }
    }
    (bytes, files)
}

/// Format a byte count for a chip — always 3-4 visible characters plus a
/// unit, so the statusline chip keeps a constant width.
pub fn human_bytes(n: u64) -> String {
    // Through E: a u64 byte count reaches 16 EiB, and stopping at T
    // rendered that as "16777216T" — nine cells in a chip budgeted for
    // five. Caught by the width assertion below, not by inspection.
    const UNITS: [&str; 7] = ["B", "K", "M", "G", "T", "P", "E"];
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 {
        format!("{n}{}", UNITS[0])
    } else if v < 10.0 {
        format!("{v:.1}{}", UNITS[u])
    } else {
        format!("{v:.0}{}", UNITS[u])
    }
}

/// `1m 04s` / `12s` / `2h 05m`. Deliberately never "0s" for a live
/// transfer — that reads as finished.
pub fn human_eta(d: Duration) -> String {
    let s = d.as_secs().max(1);
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m {:02}s", s / 60, s % 60)
    } else {
        format!("{}h {:02}m", s / 3600, (s % 3600) / 60)
    }
}

// ─── the worker ────────────────────────────────────────────────────────

/// How often to report progress. Every file would flood the channel on a
/// tree of small files and the render loop would spend its tick draining
/// it; a time-based gate keeps the message rate bounded regardless of
/// file size.
const PROGRESS_EVERY: Duration = Duration::from_millis(100);

struct Reporter {
    id: u64,
    tx: Sender<TransferMsg>,
    bytes_done: u64,
    files_done: usize,
    last_sent: Instant,
}

impl Reporter {
    fn tick(&mut self, force: bool) {
        if !force && self.last_sent.elapsed() < PROGRESS_EVERY {
            return;
        }
        self.last_sent = Instant::now();
        let _ = self.tx.send(TransferMsg::Progress {
            id: self.id,
            bytes_done: self.bytes_done,
            files_done: self.files_done,
        });
    }
}

/// Run one transfer to completion on this thread. `spawn` wraps it; this
/// is separate so tests can drive it synchronously and assert on the
/// exact message sequence rather than racing a thread.
///
/// `items` is `(source, destination)` pairs; the destination is ignored
/// for a delete. Explicit pairs rather than a destination DIRECTORY
/// because the caller has already resolved collisions —
/// `file_paste_into` bumps a same-directory copy to `-copy`, and
/// re-deriving the name here would either lose that rule or duplicate
/// it.
/// Whether a copy ran to completion or stopped early on cancel.
///
/// This distinction is the whole reason the type exists. `copy_one` used
/// to return `Ok(())` on cancel, which is indistinguishable from success
/// — and the Move branch reads success as licence to delete the source.
/// A user cancelling a large cross-filesystem move therefore lost the
/// original while the destination held only part of the tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CopyOutcome {
    Completed,
    Stopped,
}

/// Run one transfer to completion on this thread. `spawn` wraps it; this
/// is separate so tests can drive it synchronously and assert on the
/// exact message sequence rather than racing a thread.
pub fn run(
    id: u64,
    kind: TransferKind,
    items: Vec<(PathBuf, PathBuf)>,
    cancel: Arc<AtomicBool>,
    tx: Sender<TransferMsg>,
) {
    // Per-source totals, not just an aggregate: the rename fast path
    // completes one source at a stroke and has to credit that source's
    // own size. Crediting the whole transfer's total (what it used to do)
    // showed 100% after the first of several sources, then counted past
    // the total as the rest copied.
    let per_source: Vec<(u64, usize)> = items
        .iter()
        .map(|(src, _)| measure(std::slice::from_ref(src), &cancel))
        .collect();
    let bytes_total: u64 = per_source.iter().map(|(b, _)| *b).sum();
    let files_total: usize = per_source.iter().map(|(_, f)| *f).sum();
    let _ = tx.send(TransferMsg::Total {
        id,
        bytes_total,
        files_total,
    });

    let mut rep = Reporter {
        id,
        tx: tx.clone(),
        bytes_done: 0,
        files_done: 0,
        last_sent: Instant::now(),
    };

    // Paths this transfer actually BROUGHT INTO EXISTENCE, youngest last.
    //
    // Recorded per entry as it is created, and only when it was not
    // already there. The earlier version pushed each top-level target
    // before writing it, without checking — so cancelling a paste over an
    // existing name deleted the user's original file, and cancelling a
    // merge into an existing folder called `remove_dir_all` on a tree
    // this transfer had only added to.
    let mut created: Vec<PathBuf> = Vec::new();
    // Entries skipped because they could not be read or had vanished. A
    // transfer that quietly leaves files behind must still say so.
    let mut skipped = 0usize;

    for ((src, target), (src_bytes, src_files)) in items.iter().zip(per_source.iter()) {
        if cancel.load(Ordering::Relaxed) {
            finish_cancelled(id, &created, &tx);
            return;
        }
        let res: Result<CopyOutcome, String> = match kind {
            TransferKind::Delete => delete_one(src, &mut rep, &cancel),
            TransferKind::Copy | TransferKind::Move => {
                let target_existed = target.exists();
                // A move within one filesystem is a rename — no bytes
                // cross the disk, so never fall back to copy+delete when
                // the cheap path is available.
                if kind == TransferKind::Move && std::fs::rename(src, target).is_ok() {
                    if !target_existed {
                        created.push(target.clone());
                    }
                    rep.bytes_done = rep.bytes_done.saturating_add(*src_bytes);
                    rep.files_done += *src_files;
                    // Forced: a rename finishes an entire source in one
                    // step, so the 100ms gate would otherwise swallow the
                    // only progress this source ever produces.
                    rep.tick(true);
                    Ok(CopyOutcome::Completed)
                } else {
                    match copy_one(src, target, &mut rep, &cancel, &mut created, &mut skipped) {
                        // A cross-filesystem move removes the source ONLY
                        // on a genuine full completion. `Stopped` means
                        // the user cancelled mid-tree and the destination
                        // is partial.
                        Ok(CopyOutcome::Completed) if kind == TransferKind::Move => {
                            remove_path(src).map(|_| CopyOutcome::Completed)
                        }
                        other => other,
                    }
                }
            }
        };
        match res {
            Err(e) => {
                // Failure cleans up too. Leaving debris silently is the
                // thing this module refuses to do on cancel; a hard
                // failure is no different from the user's side.
                let _ = tx.send(TransferMsg::Failed {
                    id,
                    err: e,
                    cleaned_up: cleanup(&created),
                });
                return;
            }
            Ok(CopyOutcome::Stopped) => {
                finish_cancelled(id, &created, &tx);
                return;
            }
            Ok(CopyOutcome::Completed) => {}
        }
    }

    if cancel.load(Ordering::Relaxed) {
        finish_cancelled(id, &created, &tx);
        return;
    }
    rep.tick(true);
    let _ = tx.send(TransferMsg::Done { id, skipped });
}

fn finish_cancelled(id: u64, created: &[PathBuf], tx: &Sender<TransferMsg>) {
    let cleaned = cleanup(created);
    let _ = tx.send(TransferMsg::Cancelled {
        id,
        cleaned_up: cleaned,
    });
}

pub fn spawn(
    id: u64,
    kind: TransferKind,
    items: Vec<(PathBuf, PathBuf)>,
    cancel: Arc<AtomicBool>,
    tx: Sender<TransferMsg>,
) {
    std::thread::spawn(move || run(id, kind, items, cancel, tx));
}

/// Remove the destinations this transfer created. Returns whether every
/// one went away — the caller has to be able to SAY when debris is left.
fn cleanup(created: &[PathBuf]) -> bool {
    let mut ok = true;
    // Youngest first: a directory is recorded before the entries written
    // into it, so reversing removes children before their parents and
    // `remove_dir` never meets a non-empty directory.
    for p in created.iter().rev() {
        if !p.exists() {
            continue;
        }
        if remove_path(p).is_err() {
            ok = false;
        }
    }
    ok
}

fn remove_path(p: &Path) -> Result<(), String> {
    let md = std::fs::symlink_metadata(p).map_err(|e| format!("stat {}: {e}", p.display()))?;
    if md.is_dir() {
        std::fs::remove_dir_all(p).map_err(|e| format!("rm -r {}: {e}", p.display()))
    } else {
        std::fs::remove_file(p).map_err(|e| format!("rm {}: {e}", p.display()))
    }
}

fn delete_one(src: &Path, rep: &mut Reporter, cancel: &AtomicBool) -> Result<CopyOutcome, String> {
    let (bytes, files) = measure(std::slice::from_ref(&src.to_path_buf()), cancel);
    remove_path(src)?;
    rep.bytes_done = rep.bytes_done.saturating_add(bytes);
    rep.files_done += files;
    rep.tick(false);
    Ok(CopyOutcome::Completed)
}

/// Copy `src` to `dst`, reporting bytes as they land.
///
/// Iterative rather than recursive, and it refuses to descend into its
/// own destination — the same self-copy guard `copy_recursively` carries,
/// for the same reason: without it the walk keeps finding what it just
/// wrote and the PROCESS ABORTS on a stack overflow. Reachable in one
/// keystroke by pasting a folder into itself.
///
/// Appends every path it brings into existence to `created`, and only
/// those — a directory that was already there is merged into, never
/// recorded, so a later cleanup cannot delete a tree this transfer merely
/// added to.
fn copy_one(
    src: &Path,
    dst: &Path,
    rep: &mut Reporter,
    cancel: &AtomicBool,
    created: &mut Vec<PathBuf>,
    skipped: &mut usize,
) -> Result<CopyOutcome, String> {
    if crate::app::util::is_self_or_descendant(src, dst) {
        return Err(format!(
            "cannot copy {} into itself",
            src.file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| src.display().to_string())
        ));
    }
    let mut stack = vec![(src.to_path_buf(), dst.to_path_buf())];
    while let Some((s, d)) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
            return Ok(CopyOutcome::Stopped);
        }
        // A source entry that has vanished since the sizing pass is
        // SKIPPED, matching `measure`, which does not count what it
        // cannot stat. Failing the whole transfer over a temp file that
        // another process cleaned up mid-copy is the wrong trade.
        let Ok(md) = std::fs::symlink_metadata(&s) else {
            *skipped += 1;
            continue;
        };
        if md.is_dir() {
            if !d.exists() {
                created.push(d.clone());
            }
            std::fs::create_dir_all(&d).map_err(|e| format!("mkdir {}: {e}", d.display()))?;
            let rd = std::fs::read_dir(&s).map_err(|e| format!("read_dir {}: {e}", s.display()))?;
            for e in rd {
                // An entry we cannot even read the name of is counted,
                // not silently dropped — `Done` carries the tally.
                let Ok(e) = e else {
                    *skipped += 1;
                    continue;
                };
                let Some(name) = e.path().file_name().map(|n| n.to_owned()) else {
                    *skipped += 1;
                    continue;
                };
                stack.push((e.path(), d.join(name)));
            }
        } else {
            if !d.exists() {
                created.push(d.clone());
            }
            if md.file_type().is_symlink() {
                copy_symlink(&s, &d)?;
            } else {
                std::fs::copy(&s, &d)
                    .map_err(|e| format!("copy {} → {}: {e}", s.display(), d.display()))?;
            }
            rep.bytes_done = rep.bytes_done.saturating_add(md.len());
            rep.files_done += 1;
            rep.tick(false);
        }
    }
    Ok(CopyOutcome::Completed)
}

#[cfg(unix)]
fn copy_symlink(s: &Path, d: &Path) -> Result<(), String> {
    let target = std::fs::read_link(s).map_err(|e| format!("readlink {}: {e}", s.display()))?;
    std::os::unix::fs::symlink(target, d).map_err(|e| format!("symlink {}: {e}", d.display()))
}

#[cfg(not(unix))]
fn copy_symlink(s: &Path, d: &Path) -> Result<(), String> {
    // Windows symlink creation needs a privilege most users lack, so copy
    // the target's contents instead of failing the whole transfer.
    std::fs::copy(s, d)
        .map(|_| ())
        .map_err(|e| format!("copy {} → {}: {e}", s.display(), d.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(kind: TransferKind) -> Transfer {
        Transfer::new(
            1,
            kind,
            vec![PathBuf::from("/a")],
            Some(PathBuf::from("/b")),
            Arc::new(AtomicBool::new(false)),
        )
    }

    #[test]
    fn a_transfer_starts_in_sizing_so_the_ui_does_not_show_a_fake_zero_percent() {
        let x = t(TransferKind::Copy);
        assert_eq!(x.state, TransferState::Sizing);
        assert!(!x.state.is_terminal());
    }

    /// The sizing pass must end even when the total is zero — an empty
    /// directory would otherwise leave the transfer stuck in Sizing
    /// forever with no progress bar and no completion.
    #[test]
    fn an_empty_total_still_leaves_sizing() {
        let mut x = t(TransferKind::Copy);
        x.apply(&TransferMsg::Total {
            id: 1,
            bytes_total: 0,
            files_total: 0,
        });
        assert_eq!(x.state, TransferState::Running);
    }

    /// "Done at 97%" reads as a failure. A file that shrank between the
    /// sizing pass and the copy makes that easy to hit.
    #[test]
    fn a_finished_transfer_reports_100_even_if_the_byte_total_was_wrong() {
        let mut x = t(TransferKind::Copy);
        x.apply(&TransferMsg::Total {
            id: 1,
            bytes_total: 1000,
            files_total: 1,
        });
        x.apply(&TransferMsg::Progress {
            id: 1,
            bytes_done: 970,
            files_done: 1,
        });
        assert_eq!(x.percent(), 97);
        x.apply(&TransferMsg::Done { id: 1, skipped: 0 });
        assert_eq!(x.percent(), 100, "a completed transfer showed short");
    }

    #[test]
    fn percent_is_clamped_when_more_bytes_arrive_than_were_measured() {
        let mut x = t(TransferKind::Copy);
        x.apply(&TransferMsg::Total {
            id: 1,
            bytes_total: 100,
            files_total: 1,
        });
        x.apply(&TransferMsg::Progress {
            id: 1,
            bytes_done: 250,
            files_done: 1,
        });
        assert_eq!(x.percent(), 100, "a file that grew produced >100%");
    }

    /// Speed over the first few milliseconds is noise. Reporting it makes
    /// the chip flash an absurd number that immediately collapses.
    #[test]
    fn speed_is_withheld_until_there_is_enough_signal() {
        let mut x = t(TransferKind::Copy);
        x.apply(&TransferMsg::Progress {
            id: 1,
            bytes_done: 4096,
            files_done: 1,
        });
        assert!(
            x.speed_bytes_per_sec().is_none(),
            "reported a speed measured over a few milliseconds"
        );

        // Backdate the start so elapsed is real, and it must appear.
        x.started_at = Instant::now() - Duration::from_secs(2);
        let speed = x.speed_bytes_per_sec().expect("no speed after 2s");
        assert!(
            (speed - 2048.0).abs() < 100.0,
            "4096 bytes in ~2s should be ~2048 B/s, got {speed}"
        );
    }

    #[test]
    fn eta_divides_the_remainder_by_the_measured_speed() {
        let mut x = t(TransferKind::Copy);
        x.apply(&TransferMsg::Total {
            id: 1,
            bytes_total: 10_000,
            files_total: 1,
        });
        x.apply(&TransferMsg::Progress {
            id: 1,
            bytes_done: 2_000,
            files_done: 1,
        });
        x.started_at = Instant::now() - Duration::from_secs(2);
        // 2000 bytes in 2s = 1000 B/s; 8000 left ⇒ ~8s.
        let eta = x.eta().expect("no eta");
        assert!(
            (eta.as_secs_f64() - 8.0).abs() < 1.0,
            "eta was {eta:?}, expected ~8s"
        );
    }

    /// A finished transfer has no ETA, and its average speed must FREEZE
    /// rather than decay towards zero while it sits in the list.
    #[test]
    fn a_finished_transfer_has_no_eta_and_a_frozen_speed() {
        let mut x = t(TransferKind::Copy);
        x.apply(&TransferMsg::Progress {
            id: 1,
            bytes_done: 1_000,
            files_done: 1,
        });
        x.started_at = Instant::now() - Duration::from_secs(1);
        x.apply(&TransferMsg::Done { id: 1, skipped: 0 });
        assert!(x.eta().is_none(), "a finished transfer advertised an ETA");

        let first = x.elapsed();
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(
            first,
            x.elapsed(),
            "elapsed kept climbing after the transfer finished"
        );
    }

    #[test]
    fn measure_counts_every_file_in_a_tree() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("a"), vec![0u8; 100]).unwrap();
        let sub = d.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(sub.join("b"), vec![0u8; 250]).unwrap();
        std::fs::write(sub.join("c"), vec![0u8; 150]).unwrap();

        let (bytes, files) = measure(&[d.path().to_path_buf()], &AtomicBool::new(false));
        assert_eq!(files, 3, "missed files in a nested directory");
        assert_eq!(bytes, 500, "byte total wrong: {bytes}");
    }

    /// A symlink pointing at its own ancestor must not send the sizing
    /// pass into an infinite loop — the classic file-manager hang.
    #[test]
    #[cfg(unix)]
    fn measure_does_not_follow_symlinks_into_a_cycle() {
        let d = tempfile::tempdir().unwrap();
        let sub = d.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(sub.join("a"), vec![0u8; 10]).unwrap();
        // sub/loop -> the directory that contains it.
        std::os::unix::fs::symlink(d.path(), sub.join("loop")).unwrap();

        let (_, files) = measure(&[d.path().to_path_buf()], &AtomicBool::new(false));
        // The link counts as one entry; the tree behind it is not walked.
        assert_eq!(files, 2, "followed a symlink cycle: {files} files");
    }

    #[test]
    fn measure_stops_when_cancelled() {
        let d = tempfile::tempdir().unwrap();
        for i in 0..50 {
            std::fs::write(d.path().join(format!("f{i}")), vec![0u8; 10]).unwrap();
        }
        let cancel = AtomicBool::new(true);
        let (_, files) = measure(&[d.path().to_path_buf()], &cancel);
        assert!(
            files < 50,
            "sizing ignored the cancel flag and walked everything"
        );
    }

    #[test]
    fn human_bytes_keeps_a_short_constant_ish_width() {
        assert_eq!(human_bytes(0), "0B");
        assert_eq!(human_bytes(999), "999B");
        assert_eq!(human_bytes(1024), "1.0K");
        assert_eq!(human_bytes(1536), "1.5K");
        assert_eq!(human_bytes(20 * 1024), "20K");
        assert_eq!(human_bytes(5 * 1024 * 1024), "5.0M");
        assert_eq!(human_bytes(3 * 1024 * 1024 * 1024), "3.0G");
        for n in [0u64, 1, 1023, 1024, 999_999, u64::MAX] {
            assert!(
                human_bytes(n).len() <= 5,
                "{n} rendered as {} — too wide for a constant-width chip",
                human_bytes(n)
            );
        }
    }

    /// "0s" on a live transfer reads as finished.
    #[test]
    fn human_eta_never_says_zero() {
        assert_eq!(human_eta(Duration::from_millis(10)), "1s");
        assert_eq!(human_eta(Duration::from_secs(12)), "12s");
        assert_eq!(human_eta(Duration::from_secs(64)), "1m 04s");
        assert_eq!(human_eta(Duration::from_secs(7500)), "2h 05m");
    }

    // ── the worker paths ───────────────────────────────────────────────
    //
    // Both data-loss bugs the review found lived here, in code with no
    // test at all. Everything below runs against tempdirs only.

    fn drain(rx: &std::sync::mpsc::Receiver<TransferMsg>) -> Vec<TransferMsg> {
        let mut v = Vec::new();
        while let Ok(m) = rx.try_recv() {
            v.push(m);
        }
        v
    }

    fn tree(root: &Path) {
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("top.txt"), vec![0u8; 100]).unwrap();
        std::fs::write(root.join("sub/a.txt"), vec![0u8; 50]).unwrap();
        std::fs::write(root.join("sub/b.txt"), vec![0u8; 25]).unwrap();
    }

    #[test]
    fn a_copy_lands_every_file_and_reports_done() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src");
        let dst = d.path().join("dst");
        tree(&src);
        std::fs::create_dir(&dst).unwrap();

        let (tx, rx) = std::sync::mpsc::channel();
        run(
            1,
            TransferKind::Copy,
            vec![(src.clone(), dst.join("src"))],
            Arc::new(AtomicBool::new(false)),
            tx,
        );

        assert!(dst.join("src/top.txt").is_file(), "top-level file missing");
        assert!(dst.join("src/sub/a.txt").is_file(), "nested file missing");
        assert!(src.join("top.txt").is_file(), "a COPY removed the source");

        let msgs = drain(&rx);
        assert!(
            matches!(msgs.last(), Some(TransferMsg::Done { skipped: 0, .. })),
            "did not finish cleanly: {msgs:?}"
        );
    }

    /// CRITICAL #1. `copy_one` used to return `Ok(())` when it stopped on
    /// cancel, which is indistinguishable from success — and the Move
    /// branch reads success as licence to delete the source. Cancelling a
    /// large cross-filesystem move therefore destroyed the original while
    /// the destination held only part of the tree.
    #[test]
    fn a_cancelled_copy_reports_stopped_not_completed() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src");
        tree(&src);
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut rep = Reporter {
            id: 1,
            tx,
            bytes_done: 0,
            files_done: 0,
            last_sent: Instant::now(),
        };
        let mut created = Vec::new();
        let mut skipped = 0;

        let out = copy_one(
            &src,
            &d.path().join("dst"),
            &mut rep,
            &AtomicBool::new(true),
            &mut created,
            &mut skipped,
        )
        .unwrap();
        assert_eq!(
            out,
            CopyOutcome::Stopped,
            "a cancelled copy reported success — a Move would now delete the source"
        );

        // And the uncancelled call must still say Completed, or Move
        // could never remove a source at all.
        let mut created = Vec::new();
        let out = copy_one(
            &src,
            &d.path().join("dst2"),
            &mut rep,
            &AtomicBool::new(false),
            &mut created,
            &mut skipped,
        )
        .unwrap();
        assert_eq!(out, CopyOutcome::Completed);
    }

    /// CRITICAL #2. `created` used to record each intended target before
    /// writing it, without checking whether it was already there. So a
    /// cancel after a paste over an existing name deleted the user's
    /// original file, and a cancel during a merge into an existing folder
    /// called `remove_dir_all` on a tree this transfer had only added to.
    #[test]
    fn cleanup_never_removes_something_the_transfer_did_not_create() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src");
        std::fs::create_dir(&src).unwrap();
        std::fs::write(src.join("new.txt"), b"new").unwrap();

        // The destination ALREADY exists and already holds a file.
        let dst = d.path().join("dst");
        std::fs::create_dir(&dst).unwrap();
        std::fs::write(dst.join("keep.txt"), b"precious").unwrap();

        let (tx, _rx) = std::sync::mpsc::channel();
        let mut rep = Reporter {
            id: 1,
            tx,
            bytes_done: 0,
            files_done: 0,
            last_sent: Instant::now(),
        };
        let mut created = Vec::new();
        let mut skipped = 0;
        copy_one(
            &src,
            &dst,
            &mut rep,
            &AtomicBool::new(false),
            &mut created,
            &mut skipped,
        )
        .unwrap();

        assert!(
            !created.contains(&dst),
            "recorded a directory that already existed: {created:?}"
        );
        assert!(
            created.contains(&dst.join("new.txt")),
            "did not record the file it actually created: {created:?}"
        );

        // Now the cancel path. It must take back only what it added.
        assert!(cleanup(&created), "cleanup reported debris");
        assert!(
            dst.join("keep.txt").is_file(),
            "cleanup deleted a file that predated the transfer"
        );
        assert!(dst.is_dir(), "cleanup deleted a pre-existing directory");
        assert!(
            !dst.join("new.txt").exists(),
            "cleanup left behind what the transfer created"
        );
    }

    /// The same rule for a plain file: pasting over an existing name and
    /// then cancelling must not leave the user with neither copy.
    #[test]
    fn cleanup_does_not_delete_a_file_it_overwrote() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src");
        std::fs::create_dir(&src).unwrap();
        std::fs::write(src.join("f.txt"), b"incoming").unwrap();
        let dst = d.path().join("dst");
        std::fs::create_dir(&dst).unwrap();
        std::fs::write(dst.join("f.txt"), b"original").unwrap();

        let (tx, _rx) = std::sync::mpsc::channel();
        let mut rep = Reporter {
            id: 1,
            tx,
            bytes_done: 0,
            files_done: 0,
            last_sent: Instant::now(),
        };
        let mut created = Vec::new();
        let mut skipped = 0;
        copy_one(
            &src,
            &dst,
            &mut rep,
            &AtomicBool::new(false),
            &mut created,
            &mut skipped,
        )
        .unwrap();
        cleanup(&created);
        assert!(
            dst.join("f.txt").is_file(),
            "cancelling an overwrite destroyed both copies"
        );
    }

    /// Warning #3 — the rename fast path assigned the WHOLE transfer's
    /// total after moving just one source, so a two-source move showed
    /// 100% before the second had started, then counted past the total.
    #[test]
    fn a_multi_source_move_never_reports_more_than_the_total() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("a");
        let b = d.path().join("b");
        std::fs::create_dir(&a).unwrap();
        std::fs::create_dir(&b).unwrap();
        std::fs::write(a.join("f"), vec![0u8; 100]).unwrap();
        std::fs::write(b.join("f"), vec![0u8; 300]).unwrap();
        let dst = d.path().join("dst");
        std::fs::create_dir(&dst).unwrap();

        let (tx, rx) = std::sync::mpsc::channel();
        run(
            1,
            TransferKind::Move,
            vec![(a.clone(), dst.join("a")), (b.clone(), dst.join("b"))],
            Arc::new(AtomicBool::new(false)),
            tx,
        );

        let msgs = drain(&rx);
        let total = msgs
            .iter()
            .find_map(|m| match m {
                TransferMsg::Total { bytes_total, .. } => Some(*bytes_total),
                _ => None,
            })
            .expect("no Total");
        assert_eq!(total, 400);
        let progress: Vec<u64> = msgs
            .iter()
            .filter_map(|m| match m {
                TransferMsg::Progress { bytes_done, .. } => Some(*bytes_done),
                _ => None,
            })
            .collect();
        assert!(!progress.is_empty(), "no progress at all: {msgs:?}");
        assert_eq!(
            progress[0], 100,
            "after moving only the 100-byte source, progress read {} of \
             {total} — the fast path credited the whole transfer",
            progress[0]
        );
        for b in &progress {
            assert!(*b <= total, "progress ran past the total: {b} > {total}");
        }
        assert_eq!(
            progress.last().copied(),
            Some(total),
            "the finished move never reached its total: {progress:?}"
        );
        assert!(dst.join("a/f").is_file() && dst.join("b/f").is_file());
        assert!(!a.exists() && !b.exists(), "a move left its sources behind");
    }

    /// Warning #4 — only cancel used to clean up. A hard failure left a
    /// partial destination with no signal, which is the exact thing the
    /// module refuses to do on cancel.
    #[test]
    fn a_failure_cleans_up_and_says_so() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("src");
        tree(&src);

        let (tx, rx) = std::sync::mpsc::channel();
        // Copying a directory into itself is the self-copy guard's case,
        // and one keystroke away in a file browser.
        run(
            1,
            TransferKind::Copy,
            vec![(src.clone(), src.join("src"))],
            Arc::new(AtomicBool::new(false)),
            tx,
        );
        let msgs = drain(&rx);
        assert!(
            msgs.iter().any(|m| matches!(
                m,
                TransferMsg::Failed {
                    cleaned_up: true,
                    ..
                }
            )),
            "no Failed carrying a cleanup verdict: {msgs:?}"
        );
    }

    #[test]
    fn cancelling_is_visible_before_the_worker_acknowledges_it() {
        let x = t(TransferKind::Move);
        assert!(!x.is_cancelling());
        x.cancel();
        assert!(
            x.is_cancelling(),
            "a requested cancel was invisible until the worker replied"
        );
    }

    /// Once terminal, `is_cancelling` must go quiet — otherwise a
    /// cancelled transfer renders as "cancelling…" forever.
    #[test]
    fn a_cancelled_transfer_stops_reporting_as_cancelling() {
        let mut x = t(TransferKind::Move);
        x.cancel();
        x.apply(&TransferMsg::Cancelled {
            id: 1,
            cleaned_up: true,
        });
        assert!(!x.is_cancelling());
        assert!(x.state.is_terminal());
    }
}
