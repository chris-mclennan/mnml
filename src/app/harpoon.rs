//! Harpoon — 9 pinned-file slots the user jumps to via `<leader>1`..`<leader>9`.
//! Pins live on `App.harpoon: [Option<PathBuf>; 9]` (workspace-relative
//! paths, deduped, persisted at quit through `session.json`).
//!
//! Extracted from `src/app/mod.rs`.

use crate::app::App;
use crate::app::util::rel_path;
use crate::picker::{Picker, PickerItem, PickerKind};

impl App {
    /// Harpoon: pin the active editor's file into the lowest free slot
    /// (1..=9). Toasts if the buffer has no path, the file is already
    /// pinned, or every slot is full.
    pub fn harpoon_add_active(&mut self) {
        let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
            self.toast("harpoon: no file");
            return;
        };
        if self.harpoon.iter().any(|s| s.as_ref() == Some(&path)) {
            self.toast(format!(
                "harpoon: already pinned ({})",
                rel_path(&self.workspace, &path)
            ));
            return;
        }
        if let Some(slot) = self.harpoon.iter_mut().position(|s| s.is_none()) {
            self.harpoon[slot] = Some(path.clone());
            self.toast(format!(
                "harpoon: slot {} = {}",
                slot + 1,
                rel_path(&self.workspace, &path)
            ));
        } else {
            self.toast("harpoon: all 9 slots full (use harpoon.menu to free one)");
        }
    }

    /// Harpoon: jump to slot N (1-based; the call sites `<leader>1`-`<leader>9`
    /// pass the user's digit). Toasts if the slot is empty or the file
    /// disappeared.
    pub fn harpoon_goto(&mut self, slot1: usize) {
        if !(1..=9).contains(&slot1) {
            return;
        }
        let path = match self.harpoon[slot1 - 1].clone() {
            Some(p) => p,
            None => {
                self.toast(format!("harpoon: slot {slot1} is empty"));
                return;
            }
        };
        if !path.exists() {
            self.toast(format!(
                "harpoon: slot {slot1} → file missing ({})",
                path.display()
            ));
            return;
        }
        self.open_path(&path);
    }

    /// Harpoon: open a picker over the occupied slots. Accept ⇒ jump to
    /// that slot's pinned file. Toasts if every slot is empty.
    pub fn harpoon_open_menu(&mut self) {
        let items: Vec<PickerItem> = self
            .harpoon
            .iter()
            .enumerate()
            .filter_map(|(i, slot)| {
                let path = slot.as_ref()?;
                let rel = rel_path(&self.workspace, path);
                let exists = path.exists();
                let detail = if exists {
                    format!("slot {}", i + 1)
                } else {
                    format!("slot {} · missing", i + 1)
                };
                Some(PickerItem::new((i + 1).to_string(), rel, detail))
            })
            .collect();
        if items.is_empty() {
            self.toast("harpoon: nothing pinned (use <leader>Ha to pin the active file)");
            return;
        }
        self.open_picker(Picker::new(PickerKind::Harpoon, "Harpoon", items));
    }
}
