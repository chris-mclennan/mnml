//! Chord-chain state machine (T-1 of the file-split refactor —
//! 2026-06-28). Drives the vim-style `timeoutlen` semantics for the
//! global keybinding chord chain (Ctrl+W h/j/k/l, Ctrl+K g, Ctrl+K
//! Ctrl+P, etc.).
//!
//! Extracted from `src/tui/mod.rs`. Pure non-destructive move — the
//! two functions and the constant are re-exported from `tui::mod` so
//! existing callers (`run_loop`, `headless`, `ipc::drain_commands`)
//! keep working without import changes.

use ratatui::crossterm::event::KeyEvent;

use crate::app::App;
use crate::command;

/// Vim's `timeoutlen` analogue — how long to wait for the next key
/// in a chord chain before giving up. `g:timeoutlen` defaults to
/// 1000ms in vim; VS Code uses a roughly comparable window. Could
/// become a config knob.
pub const CHORD_CHAIN_TIMEOUT_MS: u64 = 1000;

/// Maintains the App's `pending_chord_seq` + deadline + fallback.
/// Drives the vim-style `timeoutlen` semantics:
/// * `Run` → fire immediately, clear pending.
/// * `Pending` → keep the prefix, wait for the next key (with a
///   timeout for the case where the user gives up mid-chord).
/// * `PendingWithFallback` → same as Pending, but record the inner
///   command so the timeout fires it.
/// * `None` → if the prior pending had a fallback, fire that; then
///   try the current key as a fresh sequence start. If even that
///   doesn't bind, return false so the focused handler sees the key.
///
/// Returns `true` when the key was consumed (a command fired, or
/// the pending state advanced), `false` when the key should fall
/// through to the editor / tree.
pub fn dispatch_chord_chain(app: &mut App, key: KeyEvent) -> bool {
    use crate::input::keymap::{Chord, SeqResolution};
    // The chord-chain pending state must NEVER survive a focus
    // change or a modal overlay open/close — callers above us return
    // early, so we only reach here when no overlay is intercepting.
    let new_chord = Chord::of(&key);
    app.pending_chord_seq.push(new_chord);
    match app.keymap.resolve_seq(&app.pending_chord_seq) {
        SeqResolution::Run(id) => {
            let id = id.to_owned();
            app.pending_chord_seq.clear();
            app.pending_chord_deadline = None;
            app.pending_chord_fallback = None;
            command::run(&id, app);
            true
        }
        SeqResolution::PendingWithFallback(fallback) => {
            let fb = fallback.to_owned();
            app.pending_chord_fallback = Some(fb);
            app.pending_chord_deadline = Some(
                std::time::Instant::now()
                    + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
            );
            true
        }
        SeqResolution::Pending => {
            app.pending_chord_fallback = None;
            app.pending_chord_deadline = Some(
                std::time::Instant::now()
                    + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
            );
            true
        }
        SeqResolution::None => {
            // The extended sequence doesn't match anything. If
            // there was a prior pending state with a fallback,
            // fire it; then process this key as if it were a
            // fresh sequence start.
            let fallback = app.pending_chord_fallback.take();
            let was_first_key = app.pending_chord_seq.len() == 1;
            app.pending_chord_seq.clear();
            app.pending_chord_deadline = None;
            if let Some(id) = fallback {
                command::run(&id, app);
            }
            if was_first_key {
                // Lone key, no binding. Caller falls through to
                // the focused handler.
                return false;
            }
            // We were extending a chain; the chain bottomed out.
            // Try the CURRENT key on its own — it might start a
            // fresh chain or fire a single-chord binding. One
            // level of recursion is bounded (was_first_key would
            // be true on the inner call).
            app.pending_chord_seq.push(new_chord);
            match app.keymap.resolve_seq(&app.pending_chord_seq) {
                SeqResolution::Run(id) => {
                    let id = id.to_owned();
                    app.pending_chord_seq.clear();
                    command::run(&id, app);
                    true
                }
                SeqResolution::PendingWithFallback(fb) => {
                    let fb = fb.to_owned();
                    app.pending_chord_fallback = Some(fb);
                    app.pending_chord_deadline = Some(
                        std::time::Instant::now()
                            + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
                    );
                    true
                }
                SeqResolution::Pending => {
                    app.pending_chord_deadline = Some(
                        std::time::Instant::now()
                            + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
                    );
                    true
                }
                SeqResolution::None => {
                    app.pending_chord_seq.clear();
                    false
                }
            }
        }
    }
}

/// Fire the pending chord-chain's fallback (if any) when its
/// deadline has elapsed and clear pending state. Called from
/// `App::tick` each frame so the user doesn't have to press another
/// key to "kick" a dangling prefix.
pub fn tick_chord_chain(app: &mut App) {
    let Some(deadline) = app.pending_chord_deadline else {
        return;
    };
    if std::time::Instant::now() < deadline {
        return;
    }
    let fallback = app.pending_chord_fallback.take();
    app.pending_chord_seq.clear();
    app.pending_chord_deadline = None;
    if let Some(id) = fallback {
        command::run(&id, app);
    }
}
