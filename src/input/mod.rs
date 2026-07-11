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
    /// vim charwise visual (`v`) — `<motion>` extends.
    Visual,
    /// vim linewise visual (`V`) — selects whole lines. Distinct so
    /// the statusline can render `V-LINE` instead of just `VISUAL`.
    /// nvchad-user-2026-06-10 S3-03.
    VisualLine,
    /// vim blockwise visual (`Ctrl-V`) — rectangular selection.
    /// Statusline renders `V-BLOCK`.
    VisualBlock,
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
            EditingMode::Normal
            | EditingMode::Visual
            | EditingMode::VisualLine
            | EditingMode::VisualBlock => CursorShape::Block,
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
            EditingMode::VisualLine => Some("V-LINE"),
            EditingMode::VisualBlock => Some("V-BLOCK"),
        }
    }
    /// code-reviewer S1-1 — tooltip text for the mode chip. Owned by
    /// the enum so `src/ui/tooltip.rs` doesn't have to branch on
    /// EditingMode (spine: `grep -rn EditingMode src/ui` should hit
    /// only statusline.rs).
    pub fn tooltip_label(self) -> &'static str {
        match self {
            EditingMode::Insert => "green = INSERT",
            EditingMode::Replace => "orange = REPLACE",
            EditingMode::Visual => "purple = VISUAL",
            EditingMode::VisualLine => "purple = V-LINE",
            EditingMode::VisualBlock => "purple = V-BLOCK",
            EditingMode::Normal => "red = NORMAL",
            EditingMode::None => "green = EDIT (cyan = read-only)",
        }
    }
    /// `true` if any of the three visual variants. Convenience for
    /// match arms that want "is in visual mode" semantics without
    /// triple-matching every variant.
    pub fn is_visual(self) -> bool {
        matches!(
            self,
            EditingMode::Visual | EditingMode::VisualLine | EditingMode::VisualBlock
        )
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
    /// vim `.` (dot-repeat) with an armed count. Distinct from
    /// RunCommand("vim.dot_repeat") because the count needs to reach
    /// `dot_replay` — which the RunCommand-by-id path can't do.
    /// `n` = 1 for a bare `.`, higher for `3.`, `10.`, etc.
    /// nvchad-user SEV-3 2026-07-10 fix.
    DotRepeat(u32),
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
    /// vim `@<reg>` / `<count>@<reg>` — replay the macro stored in
    /// `reg`, `count` times. `'@'` ⇒ anonymous register. `count == 1`
    /// is the plain `@a` case; vim also accepts `5@a` to repeat
    /// (S2-06 of the 2026-06-10 nvchad hunt — `5@a` was silently
    /// dropping the count and replaying once).
    MacroReplayFrom {
        reg: char,
        count: u32,
    },
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
    /// Move the cmdline completion popup's highlight by ±1.
    /// `i8` so the variant stays small; -1 = up, +1 = down.
    CmdlinePopupMove(i8),
    /// Rewrite cmdline to the currently-highlighted popup match
    /// + commit (run it). Used by Enter when the popup is showing.
    CmdlinePopupAcceptCurrentAndCommit,
    /// User pressed Enter on the cmdline. If the popup is showing,
    /// accept the highlighted match and run that instead of the
    /// typed line; otherwise run the typed line as-is.
    /// Carries the typed line because the input handler has
    /// already closed its cmdline state by the time this fires.
    CmdlineEnter(String),
    /// qa-6th keyboard SEV-2 2026-06-29 — vim cmdline canonical
    /// `Ctrl+R Ctrl+W` (insert word under cursor) /
    /// `Ctrl+R Ctrl+A` (insert WORD). `true` = WORD (whitespace-
    /// delimited), `false` = word. App resolves from the active
    /// editor and writes back via `InputHandler::cmdline_set`.
    CmdlineInsertCursorWord(bool),
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
    /// 2026-06-21 — whichkey-style popup hint when the handler is
    /// in a multi-key prefix state (vim `g…`, `d…`, `Ctrl+W…`,
    /// `[…`, `]…`, `z…`). Returns `Some((prefix_label,
    /// continuations))` where continuations is
    /// `(key, label, is_group)` — same shape the leader
    /// whichkey popup consumes. Default `None` (standard mode
    /// has no prefix states).
    fn operator_menu_hint(&self) -> Option<(String, Vec<(char, &'static str, bool)>)> {
        None
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
    /// Current caret position (byte offset) within the cmdline text.
    /// Default None (Standard mode has no cmdline). Used by
    /// `App::cmdline_insert_cursor_word` to splice at the caret
    /// rather than the end.
    fn cmdline_caret(&self) -> Option<usize> {
        None
    }
    /// Move the caret. Default no-op. Used by cursor-word insert so
    /// the caret lands after the freshly-inserted text.
    fn set_cmdline_caret(&mut self, _byte_offset: usize) {}
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

/// input-handler-reviewer S3 (2026-06-28) — single source of truth
/// for "is the user configured to drive with vim semantics?" so the
/// string literal `"vim"` only lives in one place. `App::is_vim_mode()`
/// delegates here when you have an `&App`; call this directly when you
/// only have an `&Config` (settings overlay, keymap build).
pub fn is_vim_style(cfg: &Config) -> bool {
    cfg.editor.input_style == "vim"
}
