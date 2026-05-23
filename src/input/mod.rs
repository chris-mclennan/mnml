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
    /// vim Replace mode (`R`) — overwrite under cursor. Cursor is an
    /// underline. Distinct from Insert so the mode chip can render
    /// `REPLACE`.
    Replace,
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
            EditingMode::Replace => CursorShape::Underline,
            EditingMode::Normal | EditingMode::Visual => CursorShape::Block,
        }
    }
    /// `None` ⇒ render no mode chip at all.
    pub fn label(self) -> Option<&'static str> {
        match self {
            EditingMode::None => None,
            EditingMode::Normal => Some("NORMAL"),
            EditingMode::Insert => Some("INSERT"),
            EditingMode::Replace => Some("REPLACE"),
            EditingMode::Visual => Some("VISUAL"),
        }
    }
}

/// A small, *closed* set of buffer/app-level intents the editor can't express.
/// Bigger features become registered `Command`s; this stays tiny on purpose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppCommand {
    Save,
    /// A vim `:`-line — the interpreter lives in `app.rs`, not in the handler.
    ExCommand(String),
    /// Bridge into the command registry by id (e.g. vim `gd` → `"lsp.goto_definition"`).
    RunCommand(String),
    /// vim `m<letter>` — remember the cursor as a buffer-local mark named
    /// `letter` (`a`-`z`). Subsequent jumps via `'<letter>` / `` `<letter>``.
    SetMark(char),
    /// vim `'<letter>` — jump to the mark's *line*, cursor at the first
    /// non-whitespace character (vim convention). Toasts if unset.
    JumpToMarkLine(char),
    /// vim `` `<letter>`` — jump to the mark's exact `(row, col)`.
    JumpToMarkExact(char),
    /// vim `q<reg>` — pin the macro register, then toggle recording.
    /// `'@'` ⇒ anonymous (the chord `qq` from idle). The App's
    /// `macro_toggle` is state-aware: idle ⇒ start recording into `reg`;
    /// already recording ⇒ stop (the new `reg` is ignored).
    MacroRecordInto(char),
    /// vim `@<reg>` — replay the macro stored in `reg`. `'@'` ⇒ anonymous.
    MacroReplayFrom(char),
    /// vim visual-block `I` / `A` — enter Insert mode at the leftmost / right-of-
    /// rightmost column of the block, with the App tracking the rect so that on
    /// Esc the typed run is replayed at the same column on every other row.
    BlockInsertStart {
        append: bool,
    },
    /// vim visual-block `c` / `s` — delete the rectangular selection first,
    /// then enter the same multi-row insert dance at the rect's leftmost
    /// column (now collapsed since the slice is gone). On Esc the typed run
    /// is replayed on every other row.
    BlockChangeStart,
    /// vim `<count>o` / `<count>O` — open `count` new lines below / above,
    /// enter Insert at the first one; on Esc, replicate the typed text on
    /// the remaining (count - 1) lines.
    RepeatInsertStart {
        count: u32,
        above: bool,
    },
    /// Tab pressed on the `:` cmdline — ask the App to compute completion
    /// candidates and cycle them. The handler can't do path completion on
    /// its own (no workspace access), so the App owns the cycle state and
    /// rewrites the cmdline via `InputHandler::cmdline_set`.
    CmdlineTabComplete,
    /// flash/leap-style 2-char jump motion. Handler accumulates the two
    /// chars (`s<a><b>`) and hands them up; App computes every visible
    /// occurrence in the active editor, assigns each a label, paints them,
    /// and waits for the user to press the matching label key.
    FlashStart(char, char),
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
    /// Byte range `(start, end)` of the closest find-match strictly *after*
    /// the cursor (wraps to first). `None` when the buffer has no active find
    /// state or the matches list is empty. Used by vim's `gn` text-object
    /// (especially in operator-pending state — `cgn` / `dgn` / `ygn` need
    /// the range up-front to chain the operator's effect).
    pub next_find_match: Option<(usize, usize)>,
    /// Mirror for vim's `gN` (closest match strictly *before* the cursor;
    /// wraps to last).
    pub prev_find_match: Option<(usize, usize)>,
    /// When `[ui] wrap` is on, the active editor pane's text width in
    /// columns (so vim's display-line chords `gj` / `gk` / `g0` / `g$`
    /// can walk visual rows). `None` ⇒ wrap is off; those chords alias
    /// to their logical-line equivalents.
    pub wrap_width: Option<usize>,
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
    /// Pre-seed the handler's `:`-line history from a persisted list.
    /// Default no-op (standard mode has no `:` line).
    fn set_ex_history(&mut self, _entries: Vec<String>) {}
    /// Snapshot of the handler's current `:`-line history (newest at the
    /// end). Default empty. Used by App to persist across sessions.
    fn ex_history(&self) -> Vec<String> {
        Vec::new()
    }
    /// Ask the handler to enter Insert mode. Vim's impl flips its internal
    /// VimMode + clears any pending chord; Standard mode is no-op (it has
    /// no modes). Used by `App::block_insert_start` so the App can drive the
    /// handler into Insert without going through a keystroke.
    fn request_insert_mode(&mut self) {}
    /// Ask the handler to enter Visual (charwise) mode. Vim's impl flips
    /// `VimMode::Visual`; Standard mode is no-op (its "selection" mode is
    /// driven entirely by the editor's anchor, not by handler state).
    /// Used by `App::lsp_selection_expand` so a server-supplied range
    /// shows up as a real Visual selection.
    fn request_visual_mode(&mut self) {}
    /// Current `:` cmdline text, if the handler has one open. Default `None`
    /// (Standard mode has no cmdline). Used by `App::cmdline_tab_complete`.
    fn cmdline_get(&self) -> Option<String> {
        None
    }
    /// Replace the `:` cmdline text (e.g. after Tab completion picks a match).
    /// Default no-op. Used by `App::cmdline_tab_complete`.
    fn cmdline_set(&mut self, _text: Option<String>) {}
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
