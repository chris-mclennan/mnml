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
    /// vim `Ctrl+U` — scroll the cursor up by half the visible page.
    HalfPageUp,
    /// vim `Ctrl+D` — scroll the cursor down by half the visible page.
    HalfPageDown,

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
    /// vim text object: `iw` selects the identifier under the cursor. `aw`
    /// extends the selection to include trailing whitespace (vim "around"
    /// semantics). The cursor lands at the end of the selected range.
    SelectInnerWord,
    SelectAroundWord,
    /// vim quote text object: `i"`, `i'`, `` i` `` (inner — between the
    /// quotes), `a"` etc (around — including the quote chars). Scans the
    /// current line for the surrounding pair; no-op when the cursor isn't
    /// between two matching quote chars on the same line.
    SelectInnerQuote(char),
    SelectAroundQuote(char),
    /// vim bracket text object: `i(`, `i[`, `i{` / `a(`, `a[`, `a{`. The
    /// `char` is the open bracket (the editor derives the matching close).
    /// Spans multiple lines — finds the enclosing pair by depth-counting
    /// from the cursor outward.
    SelectInnerBracket(char),
    SelectAroundBracket(char),
    /// vim `gv` — restore the editor's last remembered selection (anchor +
    /// cursor). No-op when no selection has been made yet.
    RestoreLastSelection,
    /// vim visual `o` — swap the anchor and cursor of the current selection
    /// (move the "active end" to the other side). No-op without a selection.
    SwapAnchorCursor,
    /// vim `f`/`F`/`t`/`T` — find char on the cursor's line. `forward=true`
    /// scans rightward, `forward=false` scans leftward. `before=true` (`t`/`T`)
    /// stops one cell before the match instead of on it. When `inclusive=true`
    /// (used as a motion after an operator — `df<c>` / `cf<c>`), the cursor
    /// lands on the cell *after* the target's natural stop so the operator's
    /// range covers the find char in the `f`/`F` case and ends at the find
    /// char in the `t`/`T` case (the vim conventions). No-op when the char
    /// isn't present on the line in that direction.
    FindCharOnLine {
        ch: char,
        forward: bool,
        before: bool,
        inclusive: bool,
    },
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
    /// Replace the bytes `[start, end)` with `text`, leaving the cursor after the
    /// inserted text. Offsets must be valid char boundaries in the *current*
    /// buffer (callers applying several edits should sort them descending by
    /// `start` so earlier offsets stay valid). Used by LSP rename / code actions.
    ReplaceRange {
        start: usize,
        end: usize,
        text: String,
    },
    /// Indent the current line / each line of the selection by one tab-width.
    Indent,
    Outdent,
    /// Toggle a line comment on the current line / selection (language token wired later; `//` for now).
    ToggleLineComment,
    /// Swap the current line with the one above / below.
    MoveLineUp,
    MoveLineDown,
    /// Duplicate the current line below itself (VSCode `Ctrl+Shift+D`).
    DuplicateLine,

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
            MoveLeft
            | MoveRight
            | MoveUp
            | MoveDown
            | MoveWordLeft
            | MoveWordRight
            | MoveWordEnd
            | MoveLineStart
            | MoveLineFirstNonWs
            | MoveLineEnd
            | MoveBufferStart
            | MoveBufferEnd
            | MoveToLine(_)
            | PageUp
            | PageDown
            | HalfPageUp
            | HalfPageDown
            | SelectStart
            | SelectClear
            | SelectLine
            | SelectAll
            | SelectWord
            | SelectInnerWord
            | SelectAroundWord
            | SelectInnerQuote(_)
            | SelectAroundQuote(_)
            | SelectInnerBracket(_)
            | SelectAroundBracket(_)
            | RestoreLastSelection
            | SwapAnchorCursor
            | FindCharOnLine { .. }
            | AddCursorBelow
            | AddCursorAbove
            | YankLine
            | YankSelection
            | Undo
            | Redo => false,
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
