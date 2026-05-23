//! Persistent undo — write `Editor.undo` + `Editor.redo` to disk in
//! `<workspace>/.mnml/undo/<hash>.json` and load them back on file open.
//!
//! Extracted from `editor.rs` per the post-refactor guidebook (the
//! cleanest extraction candidate — closed system, no cross-couple with
//! `apply_one` or the motion/selection internals).

use std::path::{Path, PathBuf};

use super::{Editor, Snapshot, UNDO_LIMIT};

/// On-disk shape of [`Editor`]'s undo + redo stacks plus the text those stacks
/// are valid against. Pinned with `text_hash` so a file edited outside mnml
/// (or by another tool) silently discards the stale history rather than
/// restoring offsets that no longer map onto the buffer.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub(crate) struct PersistedHistory {
    /// FNV-1a 64-bit hash of the file's text at save time.
    text_hash: u64,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
}

/// Cap on how many snapshots get written to disk per file — separate from the
/// in-memory [`UNDO_LIMIT`] so the on-disk file doesn't bloat for a buffer
/// you've heavily edited in one sitting.
pub(crate) const PERSISTED_UNDO_LIMIT: usize = 100;

/// Where to write `path`'s persistent undo file inside `workspace`.
/// `<workspace>/.mnml/undo/<fnv-hex>.json` — fnv hash of the absolute path,
/// keeping the filename stable across renames-as-text (a rename of the file
/// on disk would change the path → new history file).
pub fn undo_path_for(workspace: &Path, file_path: &Path) -> PathBuf {
    let key = file_path.to_string_lossy();
    let hash = fnv1a_64(&key);
    workspace
        .join(".mnml")
        .join("undo")
        .join(format!("{hash:016x}.json"))
}

/// Best-effort write of `editor`'s history to `path`. I/O errors are swallowed
/// (this is a UX nicety, not load-bearing) but the function returns whether
/// the write succeeded so callers can log + tests can assert.
pub fn save_history_to(editor: &Editor, path: &Path) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    if std::fs::create_dir_all(parent).is_err() {
        return false;
    }
    let snapshot = editor.snapshot_history();
    let Ok(json) = serde_json::to_string(&snapshot) else {
        return false;
    };
    std::fs::write(path, json).is_ok()
}

/// Best-effort load of an undo file at `path` into `editor`. Returns `true` if
/// the snapshot loaded AND its text-hash matched the editor's current text
/// (i.e. the file wasn't changed outside mnml since the history was saved).
/// Missing / corrupt / mismatched files just return `false`.
pub fn load_history_from(editor: &mut Editor, path: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(h) = serde_json::from_str::<PersistedHistory>(&text) else {
        return false;
    };
    editor.restore_history(h)
}

/// FNV-1a 64-bit — a fast, dependency-free string hash. Stable across runs;
/// not cryptographic. Good enough as a "did the file change?" guard.
pub(crate) fn fnv1a_64(s: &str) -> u64 {
    const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut h = FNV_OFFSET;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

impl Editor {
    // ─── persistent undo ────────────────────────────────────────────
    /// Take a serializable snapshot of the current undo + redo stacks pinned
    /// to the current text. The on-disk file is keyed by path's hash by the
    /// caller; we only return the bytes here so the I/O layer can decide.
    pub(crate) fn snapshot_history(&self) -> PersistedHistory {
        let take_tail = |v: &[Snapshot]| -> Vec<Snapshot> {
            let n = v.len();
            let start = n.saturating_sub(PERSISTED_UNDO_LIMIT);
            v[start..].to_vec()
        };
        PersistedHistory {
            text_hash: fnv1a_64(&self.text),
            undo: take_tail(&self.undo),
            redo: take_tail(&self.redo),
        }
    }

    /// Restore an undo+redo stack previously produced by [`Self::snapshot_history`].
    /// Returns `true` if the text-hash matches (so the offsets in the
    /// snapshots still map onto the current buffer); returns `false` and
    /// leaves history empty otherwise.
    pub(crate) fn restore_history(&mut self, h: PersistedHistory) -> bool {
        if h.text_hash != fnv1a_64(&self.text) {
            return false;
        }
        self.undo = h.undo;
        self.redo = h.redo;
        // Cap the in-memory stack at the runtime UNDO_LIMIT in case the
        // disk constant ever exceeded it.
        let trim = |v: &mut Vec<Snapshot>| {
            if v.len() > UNDO_LIMIT {
                let drop = v.len() - UNDO_LIMIT;
                v.drain(..drop);
            }
        };
        trim(&mut self.undo);
        trim(&mut self.redo);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_64_is_stable() {
        // Sanity — same input ⇒ same hash, different inputs ⇒ different.
        assert_eq!(fnv1a_64("hello"), fnv1a_64("hello"));
        assert_ne!(fnv1a_64("hello"), fnv1a_64("hellp"));
    }

    #[test]
    fn undo_path_includes_hex_hash() {
        let p = undo_path_for(Path::new("/ws"), Path::new("/ws/src/main.rs"));
        // .mnml/undo/<16 hex chars>.json
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        assert!(name.ends_with(".json"));
        assert_eq!(name.len(), 16 + ".json".len());
    }
}
