//! Startup workspace-picker state.
//!
//! Drawn by `src/ui/startup_picker.rs`; routed by `src/tui.rs` via
//! `App::startup_picker`. See the UI module for the user-facing
//! description.

use crate::app::App;

/// Action the picker fires when the user commits a selection. The
/// caller (`tui.rs` keymap) translates this into the appropriate
/// `App` method calls.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartupPickerAction {
    /// Dismiss the picker; user continues in the workspace mnml was
    /// already launched at.
    NewFile,
    /// Dismiss + fire `view.discovery` (the fuzzy file picker).
    OpenFile,
    /// Dismiss + fire `view.add_workspace` (the path prompt that
    /// canonicalizes a path + adds it as an extra workspace).
    OpenFolder,
    /// Switch the file-tree focus to a configured `[[workspaces]]`
    /// row. Index matches `App::switch_workspace` (0 = primary,
    /// 1+ = extras).
    SwitchWorkspace(usize),
}

/// Mutable state for the startup picker — currently just which row
/// is highlighted. Lives on `App.startup_picker: Option<...>`; the
/// picker is shown iff that's `Some`.
#[derive(Debug, Default, Clone, Copy)]
pub struct StartupPickerState {
    pub selected: usize,
}

impl App {
    /// Should the picker be shown on startup? Triggered by
    /// `--startup-picker` CLI flag or `MNML_STARTUP_PICKER=1` env
    /// (the env var is how the mnml.app launcher plumbs the flag
    /// through, since LaunchServices doesn't forward arbitrary
    /// CLI args).
    pub fn want_startup_picker(cli_flag: bool) -> bool {
        if cli_flag {
            return true;
        }
        matches!(std::env::var("MNML_STARTUP_PICKER").as_deref(), Ok("1"))
    }

    pub fn dismiss_startup_picker(&mut self) {
        self.startup_picker = None;
    }

    pub fn startup_picker_move(&mut self, delta: isize) {
        let n = crate::ui::startup_picker::row_count(self);
        if n == 0 {
            return;
        }
        if let Some(p) = self.startup_picker.as_mut() {
            let cur = p.selected as isize;
            let new = (cur + delta).rem_euclid(n as isize) as usize;
            p.selected = new;
        }
    }

    /// Apply the user's selection. Returns `Some(action)` so the
    /// caller can fire downstream commands (`view.discovery` etc.)
    /// after `self.dismiss_startup_picker()` runs.
    pub fn startup_picker_commit(&mut self) -> Option<StartupPickerAction> {
        let p = self.startup_picker.as_ref()?;
        let action = crate::ui::startup_picker::action_for(self, p.selected);
        self.dismiss_startup_picker();
        action
    }

    /// Direct-jump variant — handles a `'1'..='9'` keystroke.
    pub fn startup_picker_press_digit(&mut self, ch: char) -> Option<StartupPickerAction> {
        let idx = crate::ui::startup_picker::row_for_key(self, ch)?;
        if let Some(p) = self.startup_picker.as_mut() {
            p.selected = idx;
        }
        self.startup_picker_commit()
    }
}
