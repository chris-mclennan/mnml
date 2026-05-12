//! The pluggable input layer: `Box<dyn InputHandler>` translates key events into
//! `EditOp`s (text editing) or escalates to an `AppCommand` / a registered command.
//! The editor/buffer/render layers never branch on which handler is active — only
//! the statusline (mode chip) and the cursor-shape code read [`EditingMode`].
//!
//! Two handlers ship today: `StandardInputHandler` (modeless, VSCode-style) and
//! `VimInputHandler` (modal). They swap at runtime via `App::set_input_style`
//! (`editor.toggle_keymap` / `:set input=vim`). A config-driven `[keys.*]`
//! resolver — so both are fully remappable — lands with `keymap.rs` later.

pub mod keymap;
pub mod standard;
pub mod vim;

use ratatui::crossterm::event::KeyEvent;

use crate::config::Config;
use crate::edit_op::EditOp;

/// The *only* handler-derived fact the render layer may read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditingMode {
    /// Modeless handler — statusline shows no mode chip; cursor is a bar.
    None,
    Normal,
    Insert,
    Visual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Bar,
    Block,
    Underline,
}

impl EditingMode {
    pub fn cursor_shape(self) -> CursorShape {
        match self {
            EditingMode::Insert | EditingMode::None => CursorShape::Bar,
            EditingMode::Normal | EditingMode::Visual => CursorShape::Block,
        }
    }
    /// `None` ⇒ render no mode chip at all.
    pub fn label(self) -> Option<&'static str> {
        match self {
            EditingMode::None => None,
            EditingMode::Normal => Some("NORMAL"),
            EditingMode::Insert => Some("INSERT"),
            EditingMode::Visual => Some("VISUAL"),
        }
    }
}

/// A small, *closed* set of buffer/app-level intents the editor can't express.
/// Bigger features become registered `Command`s; this stays tiny on purpose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppCommand {
    Save,
    SaveAll,
    Quit,
    ForceQuit,
    CloseBuffer,
    NextBuffer,
    PrevBuffer,
    GotoLine(usize),
    /// A vim `:`-line — the interpreter lives in `app.rs`, not in the handler.
    ExCommand(String),
    /// Bridge into the command registry by id (e.g. vim `gd` → `"lsp.goto_definition"`).
    RunCommand(String),
}

/// Result of feeding one key to a handler.
pub enum InputResult {
    /// Apply these to the active buffer's editor, in order.
    Ops(Vec<EditOp>),
    /// Consumed, no edit (half a chord, typing into the `:` line) — caller should still redraw.
    Consumed,
    /// Not wanted — caller tries the keymap→command resolver, then global chords, then drops it.
    Ignored,
    /// Escalate to a buffer/app-level command.
    App(AppCommand),
}

/// Read-only buffer facts a handler may consult. Intentionally tiny.
#[derive(Debug, Clone, Copy)]
pub struct EditCtx {
    pub cursor: usize,
    pub line_len: usize,
    pub line_idx: usize,
    pub line_count: usize,
    pub at_line_start: bool,
    pub at_line_end: bool,
    pub has_selection: bool,
}

pub trait InputHandler: Send {
    fn handle_key(&mut self, key: KeyEvent, ctx: &EditCtx) -> InputResult;
    /// Current editing mode — the single sanctioned coupling point.
    fn mode(&self) -> EditingMode;
    /// Text for the statusline's command/keys area (vim `:` line, pending-chord hint). `None` for standard.
    fn pending_display(&self) -> Option<String> {
        None
    }
    /// Handler name, for config / "which handler is active" UI. `"vim"` | `"standard"`.
    fn name(&self) -> &'static str;
    /// Focus left this buffer — let a modal handler drop to its base mode and clear chords.
    fn on_blur(&mut self) {}
}

/// Build a handler for the given style name. Unknown names fall back to `"standard"`.
pub fn make_handler_for(style: &str, cfg: &Config) -> Box<dyn InputHandler> {
    match style {
        "vim" => Box::new(vim::VimInputHandler::new(cfg)),
        _ => Box::new(standard::StandardInputHandler::new(cfg)),
    }
}

/// Build the configured handler. Unknown style names fall back to `"standard"`.
pub fn make_handler(cfg: &Config) -> Box<dyn InputHandler> {
    make_handler_for(&cfg.editor.input_style, cfg)
}
