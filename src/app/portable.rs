//! Portable-mode first-launch choice — task #858 phase C (#867).
//!
//! Fires exactly once per user: on the first launch without a
//! [`crate::data_root::user_choice_marker_path`] marker, mnml pops
//! a 2-button dialog asking whether to install into the standard
//! `$HOME/.config/mnml/` layout (Normal) or into a self-contained
//! `<binary_dir>/mnml-data/` folder next to the binary (Portable).
//!
//! Default focus:
//! - `AwaitingConsent` (folder already exists but no `.opted-in`
//!   marker) → default Portable — user probably created the folder
//!   on purpose.
//! - `Absent` (no folder) → default Normal — safer default; portable
//!   is opt-in for users who know they want it.
//! - `Active` (folder + marker both present) → prompt is skipped,
//!   the marker gets written silently so the overlay never fires.
//!
//! Portable acceptance materializes the folder + `.opted-in` +
//! `.user-welcomed` marker and requests a restart (`exit(75)` →
//! `run.sh` rebuilds + relaunches). The restart is necessary
//! because `data_root()` caches its portable-vs-home probe once;
//! re-execing picks up the new layout naturally.

use crate::app::App;
use crate::data_root::{self, PortableState};

impl App {
    /// Startup entry point — called from `App::new`. Cheap and idempotent:
    /// checks the marker + portable state and either opens the prompt
    /// or silently records the current layout as the user's choice.
    pub fn maybe_show_portable_choice_on_launch(&mut self) {
        if data_root::user_has_chosen() {
            return;
        }
        match data_root::portable_state() {
            // Both signals present — the user already chose portable
            // externally (dropped folder + .opted-in themselves).
            // Silently record their choice so we don't ask again.
            PortableState::Active => {
                if let Err(e) = data_root::mark_user_choice() {
                    self.toast(format!("portable: mark_user_choice failed ({e})"));
                }
            }
            // Otherwise show the two-way choice. The dialog itself
            // handles the default-focus decision via `open_portable_choice_prompt`.
            PortableState::AwaitingConsent | PortableState::Absent => {
                self.open_portable_choice_prompt();
            }
        }
    }

    /// Open the two-button choice dialog. `cursor = 0` → Portable
    /// focused; `cursor = 1` → Normal focused. Focus follows
    /// portable_state per the module docs.
    pub fn open_portable_choice_prompt(&mut self) {
        let default_portable =
            matches!(data_root::portable_state(), PortableState::AwaitingConsent);
        let title = if default_portable {
            "First launch: `mnml-data/` folder detected next to the binary. \
             Use it as a self-contained Portable install, or fall back to \
             the standard Normal layout under ~/.config/mnml/?"
                .to_string()
        } else {
            "First launch: choose your data layout. Normal = ~/.config/mnml/ \
             (standard); Portable = mnml-data/ next to the binary \
             (self-contained, no HOME footprint)."
                .to_string()
        };
        let mut p =
            crate::prompt::Prompt::new(crate::prompt::PromptKind::PortableChoicePrompt, title);
        p.cursor = if default_portable { 0 } else { 1 };
        self.prompt = Some(p);
    }

    /// Accept branch of the choice dialog. `choice` is the synth
    /// string from `run_confirm_button`: `"portable"` or `"normal"`.
    /// Unknown input is treated as Normal (safe default).
    pub fn dispatch_portable_choice(&mut self, choice: &str) {
        match choice {
            "portable" => self.accept_portable_choice_portable(),
            _ => self.accept_portable_choice_normal(),
        }
    }

    /// Normal install: drop the marker in the current data root
    /// (which is HOME-scoped by definition here) and toast.
    fn accept_portable_choice_normal(&mut self) {
        if let Err(e) = data_root::mark_user_choice() {
            self.toast(format!("choice: mark failed ({e})"));
            return;
        }
        self.toast("mnml data will live under ~/.config/mnml/ (normal install)");
    }

    /// Portable install: create the `mnml-data/` folder + `.opted-in`
    /// gate + user-welcomed marker, then request a restart so
    /// `data_root()` re-resolves against the new layout. Any error
    /// leaves the user on Home mode — they can retry via
    /// `mnml.choose_data_layout` (registered in command.rs).
    fn accept_portable_choice_portable(&mut self) {
        match data_root::activate_portable() {
            Ok(path) => {
                // Toast BEFORE requesting restart — the restart hook
                // exits immediately and the user might miss any
                // in-app confirmation.
                self.toast(format!(
                    "portable install created at {} — restarting to apply",
                    path.display()
                ));
                // Emit `exit(75)` so run.sh relaunches. Cached
                // `PORTABLE_CACHE` in this process is stale after
                // the file appears; the new process picks up the
                // Active state cleanly.
                self.request_restart();
            }
            Err(e) => {
                self.toast(format!(
                    "portable: activate failed ({e}) — staying on normal"
                ));
                // Best-effort: still mark the choice as Normal so
                // we don't re-prompt every launch on a permission
                // error the user can't easily fix.
                let _ = data_root::mark_user_choice();
            }
        }
    }
}
