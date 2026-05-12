//! The editor operation vocabulary. Input handlers (`vim`, `standard`) translate
//! key events into a `Vec<EditOp>`; `Editor::apply` (in `editor.rs`) is the single
//! interpreter that owns undo-grouping and clipboard policy. Nothing downstream of
//! `apply` knows which handler produced the op — that's the whole point.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditOp {
    // ── motion (moves the selection head too if a selection is active) ──
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    MoveWordLeft,
    MoveWordRight,
    MoveWordEnd,
    MoveLineStart,
    MoveLineFirstNonWs,
    MoveLineEnd,
    MoveBufferStart,
    MoveBufferEnd,
    /// 1-based line; clamps.
    MoveToLine(usize),
    PageUp,
    PageDown,

    // ── selection ──
    /// Drop the selection anchor at the cursor (start extending).
    SelectStart,
    /// Forget the selection.
    SelectClear,
    /// Select the current line (including its trailing newline if present).
    SelectLine,
    SelectAll,
    /// Select the word under the cursor.
    SelectWord,
    /// Multi-cursor — stubbed; a no-op until that "later" lands.
    AddCursorBelow,
    AddCursorAbove,

    // ── text mutation ──
    InsertChar(char),
    InsertStr(String),
    InsertNewline,
    /// vim `o`
    InsertNewlineBelow,
    /// vim `O`
    InsertNewlineAbove,
    Backspace,
    /// vim `x`, standard Del
    DeleteForward,
    DeleteWordLeft,
    DeleteWordRight,
    DeleteToLineStart,
    DeleteToLineEnd,
    /// vim `dd`
    DeleteLine,
    /// Delete the current selection (no-op if none).
    DeleteSelection,
    ReplaceSelection(String),
    /// Indent the current line / each line of the selection by one tab-width.
    Indent,
    Outdent,
    /// Toggle a line comment on the current line / selection (language token wired later; `//` for now).
    ToggleLineComment,
    /// Swap the current line with the one above / below.
    MoveLineUp,
    MoveLineDown,

    // ── clipboard / registers ──
    /// vim `yy`
    YankLine,
    /// vim `y` (visual) / standard Ctrl+C
    YankSelection,
    /// standard Ctrl+X
    CutSelection,
    /// vim `p`
    PasteAfter,
    /// vim `P`
    PasteBefore,
    /// standard Ctrl+V — paste at the cursor, replacing the selection if any.
    Paste,

    // ── history ──
    Undo,
    Redo,

    /// Apply `op` `n` times (vim counts: `3w`, `5dd`). The editor never learns counts exist.
    Repeat(u32, Box<EditOp>),
}

impl EditOp {
    /// True for ops that can change buffer contents — used by `apply` to decide
    /// whether to snapshot for undo. (Pure motions / selection ops return false.)
    pub fn is_mutation(&self) -> bool {
        use EditOp::*;
        match self {
            MoveLeft | MoveRight | MoveUp | MoveDown | MoveWordLeft | MoveWordRight | MoveWordEnd
            | MoveLineStart | MoveLineFirstNonWs | MoveLineEnd | MoveBufferStart | MoveBufferEnd
            | MoveToLine(_) | PageUp | PageDown | SelectStart | SelectClear | SelectLine
            | SelectAll | SelectWord | AddCursorBelow | AddCursorAbove | YankLine | YankSelection
            | Undo | Redo => false,
            Repeat(_, inner) => inner.is_mutation(),
            _ => true,
        }
    }
}

/// What `Editor::apply` reports back so the caller (`Buffer`) can sync dirty
/// state, the system clipboard, scroll, and (later) the LSP.
#[derive(Debug, Default, Clone)]
pub struct EditOutcome {
    pub buffer_changed: bool,
    pub cursor_moved: bool,
    /// The op produced text that should also go to the system clipboard.
    pub clipboard_set: Option<String>,
    /// True when the clipboard was set linewise (`YankLine`/`CutLine`).
    pub clipboard_linewise: bool,
}
