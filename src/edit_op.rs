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
    /// vim `g_` — move to the last non-whitespace char of the current line.
    /// (Vim's $ goes to EOL; g_ stops on the last non-blank.) On a blank line
    /// behaves like `MoveLineStart`.
    MoveLineLastNonWs,
    /// vim `{` / `}` — move to the previous / next blank-line boundary
    /// (paragraph navigation). `forward=true` ⇒ `}`. Lands on the *blank
    /// line* itself (or BOF/EOF when none found).
    MoveParagraph {
        forward: bool,
    },
    /// vim `(` / `)` — move to the previous / next sentence boundary.
    /// Sentence = end-of-line OR `.`/`!`/`?` followed by whitespace/EOF.
    /// `forward=true` ⇒ `)`.
    MoveSentence {
        forward: bool,
    },
    MoveLineEnd,
    MoveBufferStart,
    MoveBufferEnd,
    /// 1-based line; clamps.
    MoveToLine(usize),
    /// Set the cursor to byte offset `usize` directly. Clamps to text bounds
    /// and to the next char boundary if needed. Used by vim's `gn`
    /// operator-pending dispatch (place cursor at a known match end before
    /// SelectStart drops the anchor at the match start).
    SetCursorByte(usize),
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
    /// vim `iq` / `aq` (mnml extension) — smart-pick the enclosing quote
    /// pair from `"`, `'`, `` ` ``. The smallest enclosing range wins.
    /// `around` includes the quote chars themselves.
    SelectInnerSmartQuote,
    SelectAroundSmartQuote,
    /// vim-surround `ys{motion}<c>` — wrap the active selection with the
    /// `open` char on the left and `close` on the right. Both chars come
    /// from a single user keystroke after motion completes — quotes are
    /// symmetric (open == close) and brackets pair canonically (handled
    /// in the editor by the `surround_open_close` mapping). Cursor lands
    /// at the post-edit cursor of the closing char.
    SurroundSelection {
        open: char,
        close: char,
    },
    /// vim-surround `ds<c>` — find the enclosing pair of `<c>` (quote
    /// or bracket; `c`'s match is implied — e.g. `ds(` matches `(...)`)
    /// and delete just the open + close chars, leaving the inner content
    /// intact. No-op when no enclosing pair on the cursor's line (quotes)
    /// or surrounding the cursor (brackets).
    DeleteSurround(char),
    /// vim-surround `cs<from><to>` — change the enclosing pair of `<from>`
    /// to a `<to>` pair (e.g. `cs"'` ⇒ `"foo"` becomes `'foo'`). Tracks
    /// vim-surround's char ⇒ pair mapping (`(` opens with `(`, closes
    /// with `)`; quotes are symmetric). No-op when no enclosing pair.
    ChangeSurround {
        from: char,
        to: char,
    },
    /// vim bracket text object: `i(`, `i[`, `i{` / `a(`, `a[`, `a{`. The
    /// `char` is the open bracket (the editor derives the matching close).
    /// Spans multiple lines — finds the enclosing pair by depth-counting
    /// from the cursor outward.
    SelectInnerBracket(char),
    SelectAroundBracket(char),
    /// vim paragraph text object: `ip` selects the cursor's paragraph
    /// (the run of non-blank lines bounded by blank lines or buffer
    /// edges). `ap` extends to include trailing blank lines.
    SelectInnerParagraph,
    SelectAroundParagraph,
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
    /// vim `Ctrl+V` — start visual-block selection. Sets the editor's
    /// `block_anchor` to the current cursor; subsequent motions (h/j/k/l,
    /// w/b/e, etc.) extend the rectangle.
    BlockSelectStart,
    /// Forget the visual-block rectangle. Mirror of `SelectClear` for the
    /// block-mode state.
    BlockSelectClear,
    /// vim visual-block `y` — yank the rectangle as block-shaped text
    /// (rows joined by `\n`, every row's slice — including empty slices for
    /// short rows — included). Stored as charwise + a leading `\n` is NOT
    /// added (the receiver pastes line-aligned via PasteAfter / Before).
    YankBlock,
    /// vim visual-block `d` / `x` — delete the rectangle. Each row in the
    /// range loses its `[col_min..=col_max]` slice (rows shorter than
    /// `col_min` keep their content). Cursor lands at the rectangle's
    /// top-left after.
    DeleteBlock,

    // ── text mutation ──
    InsertChar(char),
    InsertStr(String),
    /// vim insert `Ctrl+Y` / `Ctrl+E` — insert the char at the cursor's
    /// column from the line above (`above=true`) or below (`above=false`).
    /// No-op when the source line doesn't have a char at that column (or
    /// the cursor is at the first/last line).
    InsertCharFromLine {
        above: bool,
    },
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
    /// vim normal `r<c>` — replace the char under the cursor with `c`. Cursor
    /// stays at the same byte position (vim convention). No-op at EOL/EOF or
    /// on a newline. With a selection, replaces every char in the selection
    /// with `c` (vim visual `r<c>`); newlines inside the selection are kept.
    ReplaceCharAtCursor(char),
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
    /// vim `J` — join the next line into the current one. Trims trailing
    /// whitespace from the current line + leading whitespace from the next,
    /// then inserts a single space (unless the current line is empty or
    /// already ends with whitespace, in which case no separator is inserted —
    /// vim convention). Cursor lands at the join boundary. No-op on the
    /// last line. `keep_space=false` ⇒ no space inserted (vim `gJ`).
    JoinLines {
        keep_space: bool,
    },
    /// Transform the active selection's text in place. Vim visual `u` /
    /// `U` / `~` (lower / upper / toggle). No-op without a selection.
    TransformSelectionCase(CaseTransform),
    /// Toggle the case of the ASCII letter under the cursor and advance one
    /// char to the right. Vim normal-mode `~` (without `g~`); operates on
    /// one char at a time, count repeats it. Non-letter chars just advance
    /// the cursor.
    ToggleCaseChar,
    /// Find the next decimal integer on the cursor's line at-or-after the
    /// cursor; add `delta` to it, replace in place, leave the cursor on the
    /// last digit. Vim `Ctrl+A` (delta=+1) / `Ctrl+X` (delta=-1), with
    /// counts `[count]<C-a>` (delta=+count). A leading `-` is treated as a
    /// sign when the char before it isn't an identifier char (so `x-5` is
    /// "5 with no sign", but `(-5)` is "-5"). No-op when no digit is
    /// present at-or-after the cursor on its line.
    ChangeNumberAtCursor {
        delta: i64,
    },
    /// Greedy word-wrap the cursor's paragraph to `width` chars per line
    /// (vim `gqq`). Preserves the leading whitespace prefix of the first
    /// line on every wrapped line so indented prose stays indented.
    /// Multi-paragraph selections aren't supported in this MVP — the op
    /// always reflows the cursor's paragraph (use the visual variant in a
    /// follow-up). Cursor lands at the start of the reflowed range.
    ReflowParagraph {
        width: usize,
    },

    // ── clipboard / registers ──
    /// Sets the clipboard's `pending_register` hint, consumed by the next
    /// `set` / `text` call. Vim handler emits `[SetRegisterHint(Some(c)),
    /// <clipboard op>]` after a `"<c>` prefix. `None` clears any prior hint.
    /// Pure side-effect on the Clipboard; doesn't touch the editor.
    SetRegisterHint(Option<char>),
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
    /// vim `gp` — same as `PasteAfter` but cursor lands at the END of the
    /// pasted text instead of at the start (linewise) / end (charwise).
    /// Difference is meaningful for linewise pastes only.
    PasteAfterEnd,
    /// vim `gP` — same as `PasteBefore` but cursor at end of pasted text.
    PasteBeforeEnd,
    /// standard Ctrl+V — paste at the cursor, replacing the selection if any.
    Paste,

    // ── history ──
    Undo,
    Redo,

    /// Apply `op` `n` times (vim counts: `3w`, `5dd`). The editor never learns counts exist.
    Repeat(u32, Box<EditOp>),
}

/// Letter-case transform variant for `EditOp::TransformSelectionCase`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaseTransform {
    /// `a-z` ← `A-Z`; non-alphabetic chars untouched.
    Lower,
    /// `A-Z` ← `a-z`.
    Upper,
    /// Swap each ASCII letter's case.
    Toggle,
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
            | MoveLineLastNonWs
            | MoveParagraph { .. }
            | MoveSentence { .. }
            | MoveLineEnd
            | MoveBufferStart
            | MoveBufferEnd
            | MoveToLine(_)
            | SetCursorByte(_)
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
            | SelectInnerSmartQuote
            | SelectAroundSmartQuote
            | SelectInnerBracket(_)
            | SelectAroundBracket(_)
            | SelectInnerParagraph
            | SelectAroundParagraph
            | RestoreLastSelection
            | SwapAnchorCursor
            | FindCharOnLine { .. }
            | AddCursorBelow
            | AddCursorAbove
            | BlockSelectStart
            | BlockSelectClear
            | SetRegisterHint(_)
            | YankLine
            | YankSelection
            | YankBlock
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
