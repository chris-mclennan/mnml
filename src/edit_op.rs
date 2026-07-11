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
    /// vim `ge` — move to the END of the previous word (one char left of the
    /// boundary `MoveWordLeft` lands on, walking past whitespace first).
    MoveWordEndBack,
    /// vim `W` — move to the start of the next WORD (whitespace-delimited).
    MoveBigWordRight,
    /// vim `B` — move to the start of the previous WORD (whitespace-delimited).
    MoveBigWordLeft,
    /// vim `E` — move to the end of the current/next WORD (whitespace-delimited).
    MoveBigWordEnd,
    /// vim `gE` — move to the end of the previous WORD (whitespace-delimited).
    MoveBigWordEndBack,
    MoveLineStart,
    MoveLineFirstNonWs,
    /// vim `+` (or `<CR>` in normal) — move down N lines then to the first
    /// non-whitespace char. Clamps to last line. On a blank line lands at col 0.
    MoveDownFirstNonWs,
    /// vim `-` — move up N lines then to the first non-whitespace char.
    /// Clamps to first line.
    MoveUpFirstNonWs,
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
    /// vim `$` — the LAST printable char of the current line (the byte
    /// the block cursor visually covers). Unlike `MoveLineEnd` which
    /// lands on the `\n` byte (or EOF) — vim's `$` lands one byte
    /// earlier so the cursor block sits ON the last char.
    /// On an empty line, lands at the line start (same as
    /// MoveLineEnd). 2026-06-13 nvchad-user SEV-3 S3-02 fix.
    MoveLineLastChar,
    /// vim `gj` — move down one visual row under wrap. `usize` is the
    /// viewport text width (char cells). When the cursor's col + width
    /// would stay on the same file line, the cursor moves forward by
    /// `width` chars; otherwise advances to the next visible line at the
    /// column `cur_col % width`.
    MoveVisualDown(usize),
    /// vim `gk` — inverse of `MoveVisualDown`.
    MoveVisualUp(usize),
    /// vim `g0` — start of the current *visual* row (`(cur_col / width) *
    /// width`). When the cursor is already in the first visual segment
    /// this is the same as `MoveLineStart`.
    MoveVisualLineStart(usize),
    /// vim `g$` — end of the current *visual* row (`(cur_col / width) *
    /// width + width - 1`, clamped to line length).
    MoveVisualLineEnd(usize),
    MoveBufferStart,
    MoveBufferEnd,
    /// 1-based line; clamps.
    MoveToLine(usize),
    /// 1-based character column on the current line; clamps to line length.
    /// Vim's `<count>|`.
    MoveToCol(usize),
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
    /// Vim `V` semantics: anchor at line_start, cursor stays put — the
    /// selection MODEL is line-wise so visual rendering shows the full
    /// line regardless of cursor column.
    SelectLine,
    /// VS Code `Ctrl+L` semantics: anchor at line_start, cursor jumps
    /// to line_end+1 so the visual selection literally covers the
    /// whole line. Repeated calls extend down one line at a time.
    /// qa-7th vscode SEV-2 2026-06-30 — was using SelectLine, which
    /// only highlights line_start..cursor (mid-line cursor → partial).
    SelectLineToEnd,
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
    /// HTML/XML/JSX tag text objects (`it` / `at`). `SelectInnerTag`
    /// selects the body between the opening and closing tag (excludes
    /// both `<TagName>` and `</TagName>`); `SelectAroundTag` includes
    /// both tags. Uses `enclosing_tag_pair` to find the innermost
    /// enclosing pair around the cursor. No-op when the cursor isn't
    /// inside a matched tag pair (self-closing / void / top-level
    /// text). nvchad-user SEV-2 2026-07-10.
    SelectInnerTag,
    SelectAroundTag,
    /// vim paragraph text object: `ip` selects the cursor's paragraph
    /// (the run of non-blank lines bounded by blank lines or buffer
    /// edges). `ap` extends to include trailing blank lines.
    SelectInnerParagraph,
    SelectAroundParagraph,
    /// Tree-sitter text object — `if` / `af`. Selects the body of the
    /// enclosing function (inner: between the braces, around: the whole
    /// def including signature + braces). Driven by
    /// `regex_outline::extract_symbols` for the header line + bracket
    /// matching for the body extent. Indent-scoped languages (py) use
    /// the indent rule instead. No-op when no enclosing function.
    SelectInnerFunction,
    SelectAroundFunction,
    /// Tree-sitter text object — `ic` / `ac`. Selects the body of the
    /// enclosing class / struct / enum / trait / interface / module.
    /// Same scan as the function variant but accepts a different symbol
    /// kind set.
    SelectInnerClass,
    SelectAroundClass,
    /// Tree-sitter text object — `ia` / `aa`. Selects a single argument
    /// (function call or definition param list). Walks back to find the
    /// nearest unmatched `(`, walks forward to the matching `)`, then
    /// splits on top-level commas. `inner` = just the arg, `around` =
    /// arg + adjacent comma + adjacent whitespace.
    SelectInnerArgument,
    SelectAroundArgument,
    /// vim-indent-object text object — `ii` / `ai` / `aI`. Selects the
    /// contiguous block of lines whose indent is ≥ the cursor line's
    /// (blank lines inside the run don't break it). `Inner` (`ii`) = the
    /// block itself; `Around` (`ai`) = the block plus the less-indented
    /// header line above it (the `def:` / `if:` / `key:`); `Outer`
    /// (`aI`) = header above *and* the line below. Language-agnostic —
    /// the right tool for YAML and any indented file.
    SelectInnerIndentBlock,
    SelectAroundIndentBlock,
    SelectOuterIndentBlock,
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
    /// Multi-cursor — add a cursor at the same char-column as the primary
    /// on the row below / above. No-op if there's no row that direction.
    /// Multiple presses add a chain.
    AddCursorBelow,
    AddCursorAbove,
    /// Drop every extra cursor; the primary stays put. Vim Normal-mode Esc
    /// emits this so the user has a quick "back to single cursor" gesture.
    ClearExtraCursors,
    /// VS Code's `Ctrl+D` — add a cursor at the next occurrence of the word
    /// under the bottom-most existing cursor. Word boundaries match the
    /// "highlight word under cursor" semantics. No-op when there's no word.
    AddCursorAtNextWord,
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
    /// vim Replace mode (`R`) — overwrite the char under the cursor with `c`
    /// (or insert when sitting on a newline / EOF), then advance the cursor
    /// by one. Pushes the displaced char (or `None` for an EOL insertion)
    /// onto the editor's `replace_stack` so `ReplaceUndoOne` can roll it back.
    OverwriteCharAndAdvance(char),
    /// vim Replace mode `Backspace` — pop the most recent
    /// `OverwriteCharAndAdvance` and undo it: move cursor back one cell;
    /// either restore the original char (if any) or just delete what was
    /// inserted. No-op when the stack is empty (cursor at the original
    /// R-entry position).
    ReplaceUndoOne,
    /// Begin a vim Replace mode session — clears the editor's replace stack.
    /// Emitted by the vim handler on `R`-entry so previous-session entries
    /// don't leak in.
    ReplaceSessionBegin,
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
    /// Toggle a line comment on the current line / selection. Uses the
    /// editor's per-language `(open, close)` tokens — `// ` / `# ` / `-- `
    /// for line-comment languages; `<!-- … -->` / `/* … */` for
    /// block-comment-only families (HTML / CSS / XML / Vue / Svelte).
    /// See `comment_token_for` in `buffer.rs`.
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
    /// mini.align — for every line covered by the active selection, find
    /// the first occurrence of `on_char` and pad each line with spaces
    /// before that char so all occurrences line up at the same column. No-op
    /// without a selection. Lines without `on_char` are left untouched.
    /// Cursor lands at the start of the first aligned line.
    AlignSelection {
        on_char: char,
    },

    // ── clipboard / registers ──
    /// Sets the clipboard's `pending_register` hint, consumed by the next
    /// `set` / `text` call. Vim handler emits `[SetRegisterHint(Some(c)),
    /// <clipboard op>]` after a `"<c>` prefix. `None` clears any prior hint.
    /// Pure side-effect on the Clipboard; doesn't touch the editor.
    SetRegisterHint(Option<char>),
    /// vim `yy`
    YankLine,
    /// Yank N consecutive lines starting at the cursor's line into
    /// the unnamed register, LINEWISE. Used by vim's `y{N}j` /
    /// `y{N}k` / `Y{N}` — a naive `YankLine × N` overwrites the
    /// register each time and only ever captures the cursor line.
    /// nvchad round 6 SEV-2 2026-07-11 fix.
    YankLinesCount(u32),
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
            | MoveWordEndBack
            | MoveBigWordRight
            | MoveBigWordLeft
            | MoveBigWordEnd
            | MoveBigWordEndBack
            | MoveLineStart
            | MoveLineFirstNonWs
            | MoveDownFirstNonWs
            | MoveUpFirstNonWs
            | MoveLineLastNonWs
            | MoveParagraph { .. }
            | MoveSentence { .. }
            | MoveLineEnd
            | MoveVisualDown(_)
            | MoveVisualUp(_)
            | MoveVisualLineStart(_)
            | MoveVisualLineEnd(_)
            | MoveBufferStart
            | MoveBufferEnd
            | MoveToLine(_)
            | MoveToCol(_)
            | SetCursorByte(_)
            | PageUp
            | PageDown
            | HalfPageUp
            | HalfPageDown
            | SelectStart
            | SelectClear
            | SelectLine
            | SelectLineToEnd
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
            | SelectInnerIndentBlock
            | SelectAroundIndentBlock
            | SelectOuterIndentBlock
            | RestoreLastSelection
            | SwapAnchorCursor
            | FindCharOnLine { .. }
            | AddCursorBelow
            | AddCursorAbove
            | ClearExtraCursors
            | AddCursorAtNextWord
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

/// A byte-range edit hint for incremental tree-sitter reparse.
/// Each `(start_byte, old_end_byte, new_end_byte)` triple matches the shape of
/// `tree_sitter::InputEdit`; the points are derived later from the buffer's
/// line-start index. Offsets are in the **pre-edit** text's coordinate space
/// (each edit's "before" state is the text after the previous edit in the same
/// batch was applied).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TextEdit {
    pub start_byte: usize,
    pub old_end_byte: usize,
    pub new_end_byte: usize,
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
    /// Byte-range hints for the caller to fold into a cached tree-sitter
    /// `Tree` via `Tree::edit` before reparsing. **Convention:** when
    /// `buffer_changed` is `true` but `text_edits` is empty, the op modified
    /// the text in a way the editor doesn't track (multi-cursor fan-out,
    /// auto-pair insert that adds two chars but moves the cursor by one,
    /// indent/outdent across N lines, etc.) — the caller should drop any
    /// cached parse tree and reparse from scratch. When `text_edits` is
    /// non-empty, the parser can reuse the prior tree.
    pub text_edits: Vec<TextEdit>,
    /// Byte range `(start, end)` of text that was just yanked or deleted —
    /// used by `App.yank_flash` for the inc-yank highlight overlay. None
    /// when the op didn't yank/delete anything user-visible.
    pub yanked_range: Option<(usize, usize)>,
}
