//! The modal handler: Normal / Insert / Visual / Visual-Line + a `:` command
//! line. ALL chord/count/operator/cmdline state is private to this file — the
//! rest of the app only ever sees `EditingMode` (via the trait) and the
//! `pending_display()` hint string. Counts never reach the editor: a `3w`
//! becomes `Repeat(3, MoveWordRight)` and `Editor::apply` loops.
//!
//! Coverage (P3a): `hjkl w b e 0 ^ $ gg G {N}G` motions; `i a I A o O` inserts;
//! `x X D C s S dd cc yy p P d{motion} c{motion} y{motion}`; `u` / `Ctrl-R`;
//! `v` / `V` visual with motions + `y d c x`; `gd`/`gD` → LSP commands;
//! `gcc`/`gc{motion}` → toggle-comment; `ZZ` → `:x`, `ZQ` → `:q!`; `:`-line →
//! `AppCommand::ExCommand`. Leader-key which-key and a full `[keys.vim]`
//! resolver land in P3b/P3c.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::config::Config;
use crate::edit_op::EditOp;
use crate::input::{AppCommand, EditCtx, EditingMode, InputHandler, InputResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VimMode {
    Normal,
    Insert,
    /// vim Replace mode (`R`) — typed chars overwrite existing chars and
    /// advance the cursor (insert past EOL). Esc returns to Normal.
    Replace,
    Visual,
    VisualLine,
    VisualBlock,
}

/// A pending operator awaiting a motion (`d`, `c`, `y`, `>`, `<`, `gq`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PendingOp {
    Delete,
    Change,
    Yank,
    Indent,
    Outdent,
    /// `gq` — paragraph reflow. Combined with a text object (currently `ip`
    /// / `ap`) to scope which paragraph(s) to reflow.
    Reflow,
    /// `gu{motion}` — lowercase the motion's range.
    Lower,
    /// `gU{motion}` — uppercase the motion's range.
    Upper,
    /// `g~{motion}` — toggle case of the motion's range.
    ToggleCase,
    /// `gc{motion}` / `gc{text-object}` — toggle line comment over
    /// the motion's / text object's range. 2026-07-07 fix — was:
    /// `gc` only handled simple motions (j/k/etc.), so `gcap`
    /// / `gcip` fell through to the operator-less parser and either
    /// dropped or misrouted (letter `p` was treated as paste).
    Comment,
    /// vim-surround `ys{motion}<c>` — wrap the motion's range with a
    /// surround char chosen *after* the motion completes. The motion's
    /// select-ops get stashed in `pending_surround_ops`, then we transition
    /// to `Prefix::SurroundAddCharWait` for the char keystroke.
    SurroundAdd,
    /// mini.align `gA{motion}<char>` — align lines in the motion's range
    /// on `<char>`. Like `SurroundAdd`, the alignment char arrives *after*
    /// the motion completes (handler transitions to `Prefix::AlignCharWait`).
    Align,
    /// vim `!{motion}` — filter the motion's line range through a shell
    /// command. Motion completes → prompt for the command → pipe the
    /// range's text on stdin, replace with stdout. Line-oriented
    /// (motion is expanded to whole lines like `>`/`<` `gc`).
    /// nvchad-round-9 SEV-2 2026-07-11.
    Filter,
}

/// A multi-key prefix that isn't an operator (`g…`, `Z…`, `r…`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Prefix {
    None,
    /// Saw `g` — expecting `g`, `d`, `D`, `c`, …
    G,
    /// Saw `gc` — expecting `c` (→ `gcc`) or a motion.
    Gc,
    /// Saw `gq` — expecting `q` (→ `gqq` reflow current paragraph) or a
    /// motion (not yet supported).
    Gq,
    /// Saw `Z` — expecting `Z` (→ `:x`) or `Q` (→ `:q!`).
    Z,
    /// Saw lowercase `z` — vim's fold prefix. `a`/`o`/`c` toggle a fold,
    /// `R`/`E` unfold all, `M` folds all (via `lsp.fold_all`). Distinct
    /// from [`Self::Z`] because vim uses both letters for different
    /// families.
    ZFold,
    /// Saw `r` — replace the char under the cursor with the next typed char.
    Replace,
    /// V-BLOCK `r` — replace every cell in the block rectangle with
    /// the next typed char. nvchad-round-7 SEV-2 2026-07-11.
    BlockReplaceChar,
    /// Saw `m` — expecting a letter to **set** a buffer-local mark.
    MarkSet,
    /// Saw `'` — expecting a letter to jump to a mark's **line**.
    MarkJumpLine,
    /// Saw `` ` `` — expecting a letter to jump to a mark's **exact position**.
    MarkJumpExact,
    /// In operator-pending state, the user typed `i` — expecting an object
    /// char (`w` so far, more in follow-ups). Operator is held in
    /// [`VimInputHandler::op`].
    TextObjectInner,
    /// Operator-pending + `a` — "around" variant; same expected next char.
    TextObjectAround,
    /// `f` / `F` / `t` / `T` — the next typed char is the find target.
    /// `(forward, before)` — `f`=(true, false), `F`=(false, false),
    /// `t`=(true, true), `T`=(false, true).
    FindChar(bool, bool),
    /// Saw `Ctrl+W` — vim's window/split navigation prefix. Next key picks a
    /// direction (`h`/`j`/`k`/`l` or arrows), cycles (`w`), or closes (`q`).
    Window,
    /// Saw `[` — bracket-prefix for "go to prev <kind>". `[c` = prev git
    /// hunk; `[d` = prev LSP diagnostic.
    BracketOpen,
    /// Saw `]` — bracket-prefix for "go to next <kind>". Mirror of
    /// [`Self::BracketOpen`].
    BracketClose,
    /// Saw `"` — named-register prefix. Next key (`a`-`z`, `0`, `+`, `_`)
    /// selects the register the following yank / paste / delete will go to
    /// (or read from). MVP supports `"a`-`"z` named, `"0` last yank,
    /// `"+` system clipboard, `"_` blackhole.
    Register,
    /// Saw `q` while idle — next key is the macro register letter to
    /// record into (or `q` to start anonymous recording for backwards
    /// compat with mnml's earlier behavior).
    MacroRecordTarget,
    /// Saw `@` — next key is the macro register letter to replay (or `@`
    /// for anonymous).
    MacroReplayTarget,
    /// vim-surround `ds` — next key is the surround char to delete
    /// (`"`, `'`, `` ` ``, `(`, `[`, `{`, `<`).
    SurroundDelete,
    /// vim-surround `cs<from>` — next key is the new surround char.
    SurroundChange(char),
    /// vim-surround `ys{motion}` waited for the motion to complete; now
    /// the next key is the surround char. The motion's select-ops are
    /// stashed in `pending_surround_ops` and merged into the final
    /// `[…select…, SurroundSelection(open, close), SelectClear]` Ops.
    SurroundAddCharWait,
    /// flash/leap: saw `s`, waiting for the first char of the 2-char
    /// target sequence. Esc cancels.
    Flash1,
    /// flash/leap: saw `s<a>`, waiting for the second char. Esc cancels.
    /// On the next char `<b>`, escalate to `AppCommand::FlashStart(a, b)`.
    Flash2(char),
    /// mini.align `gA{motion}` already completed — selection is live; the
    /// next typed char is the alignment column. Esc cancels.
    AlignCharWait,
}

/// Ex commands offered for Tab completion on the first word. Curated rather
/// than dynamically generated — most are matched as prefixes by the dispatcher,
/// so a few canonical names cover their short forms too. `pub(crate)` so the
/// App can consume the same list when computing completion matches.
/// Step backward one character boundary from `byte` in `s`. Returns `0` when
/// `byte == 0`. Char-boundary safe for UTF-8.
fn prev_char_boundary(s: &str, byte: usize) -> usize {
    if byte == 0 {
        return 0;
    }
    let mut i = byte - 1;
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}
/// Step forward one character boundary from `byte` in `s`. Clamps to `s.len()`.
fn next_char_boundary(s: &str, byte: usize) -> usize {
    if byte >= s.len() {
        return s.len();
    }
    let mut i = byte + 1;
    while i < s.len() && !s.is_char_boundary(i) {
        i += 1;
    }
    i
}

pub(crate) const EX_COMPLETION_NAMES: &[&str] = &[
    "ab",
    "abclear",
    "argdo",
    "ascii",
    "Ag",
    "badd",
    "BLines",
    "Buffers",
    "bdelete",
    "bfirst",
    "blast",
    "bnext",
    "bprev",
    "browse",
    "buffer",
    "buffers",
    "bufdo",
    "cclose",
    "cd",
    "cfirst",
    "clast",
    "close",
    "cnext",
    "colorscheme",
    "colo",
    "command",
    "copen",
    "copy",
    "cprev",
    "cwindow",
    "delcommand",
    "delete",
    "diff",
    "earlier",
    "edit",
    "enew",
    "execute",
    "files",
    "Files",
    "first",
    "Explore",
    "global",
    "goto",
    "grep",
    "help",
    "hide",
    "history",
    "History",
    "Keys",
    "jumps",
    "keepa",
    "keepalt",
    "keepjumps",
    "keepmarks",
    "last",
    "later",
    "Lex",
    "Lexplore",
    "Lines",
    "lclose",
    "lnext",
    "lopen",
    "lprev",
    "lwindow",
    "ls",
    "make",
    "marks",
    "Maps",
    "Marks",
    "messages",
    "move",
    "next",
    "noautocmd",
    "nohlsearch",
    "norm",
    "normal",
    "only",
    "previous",
    "put",
    "pwd",
    "qa",
    "qall",
    "quit",
    "quitall",
    "read",
    "redo",
    "redraw",
    "registers",
    "reload",
    "resize",
    "retab",
    "Rg",
    "saveas",
    "set",
    "setf",
    "setlocal",
    "Sex",
    "Sexplore",
    "Snippets",
    "silent",
    "sort",
    "source",
    "split",
    "sub",
    "substitute",
    "syntax",
    "tabclose",
    "tabe",
    "tabedit",
    "tabfirst",
    "tablast",
    "tabnew",
    "tabnext",
    "tabonly",
    "tabprev",
    "term",
    "Blame",
    "Branch",
    "Branches",
    "CA",
    "CodeAction",
    "Commands",
    "Commit",
    "Definition",
    "Diagnostics",
    "Format",
    "G",
    "Gblame",
    "Gcommit",
    "Gdiff",
    "Git",
    "Glog",
    "Hover",
    "Log",
    "QF",
    "QuickFix",
    "References",
    "Rename",
    "Stash",
    "StashPop",
    "Status",
    "Test",
    "Toast",
    "TestAll",
    "TestFailed",
    "TestFile",
    "Flaky",
    "Symbols",
    "Trim",
    "undo",
    "unique",
    "version",
    "Vex",
    "Vexplore",
    "view",
    "vimgrep",
    "vsplit",
    "wincmd",
    "winc",
    "wa",
    "wall",
    "wnext",
    "wprev",
    "wqa",
    "wqall",
    "write",
    "xall",
    "xit",
    "yank",
];

#[derive(Debug)]
pub struct VimInputHandler {
    mode: VimMode,
    /// The count being typed (e.g. `12` in `12dd`). `None` ⇒ 1.
    count: Option<u32>,
    op: Option<PendingOp>,
    prefix: Prefix,
    /// `Some` while the user is typing a `:`-line (without the leading `:`).
    cmdline: Option<String>,
    /// Byte offset of the caret within `cmdline`. `0` when no cmdline is
    /// open. Lets Left/Right/Home/End/Delete/Backspace edit mid-line and
    /// renders a `▏` marker in [`Self::pending_display`].
    cmdline_cursor: usize,
    tab_width: usize,
    /// Snapshot of `[editor] text_width` at construction — used by `gqap` /
    /// `gqip` to emit `EditOp::ReflowParagraph` directly. `gqq` goes
    /// through the App command (which reads the live config), so the only
    /// staleness window is between a `:set text_width=N` and the *next*
    /// time the input handler is rebuilt (e.g. via `editor.use_vim`).
    text_width: usize,
    /// Last `(ch, forward, before)` from an `f`/`F`/`t`/`T` so vim's `;`
    /// (repeat in same direction) and `,` (repeat in opposite direction)
    /// can re-fire it. `None` until the user has done one find-char.
    last_find_char: Option<(char, bool, bool)>,
    /// Named-register hint set by `"<reg>`. Persists for *one* yank /
    /// paste / delete (or operator combo: `"ayy`, `"ap`, `"add`). Cleared
    /// on use. `None` ⇒ default (unnamed) register.
    pending_register: Option<char>,
    /// Insert-mode `Ctrl+R` ⇒ next key is a register letter; paste that
    /// register's contents inline at the cursor (vim canonical).
    insert_waiting_for_register: bool,
    /// Set by insert-mode `Ctrl+V` / `Ctrl+Q` — the NEXT keystroke is inserted
    /// verbatim (Tab as `\t`, etc.) instead of going through the usual
    /// chord lookup.
    insert_literal_next: bool,
    /// Mirror of the App's macro recording state. Local because the vim
    /// handler needs to decide on `q` whether to enter `MacroRecordTarget`
    /// prefix (idle) or fire the stop toggle (recording). Kept in sync by
    /// `MacroRecordInto` dispatch (start) and the `q` stop arm.
    is_recording_macro: bool,
    /// vim-surround `ys{motion}<c>` builds an Ops sequence in two parts —
    /// the motion's selection (filled when motion completes), then the
    /// final `SurroundSelection(open, close)` (filled when the surround
    /// char arrives). This stash holds the partial selection ops while
    /// `Prefix::SurroundAddCharWait` waits for the surround char.
    pending_surround_ops: Vec<EditOp>,
    /// vim insert `Ctrl+O <cmd>` — flips temporarily to Normal for one
    /// command, then back to Insert. Set when Ctrl+O is pressed in
    /// Insert; checked at the bottom of `handle_key`. Cleared when we
    /// flip back (chord-aware: stays Normal while a chord is pending).
    insert_oneshot_normal: bool,
    /// `:`-line history — every accepted ex command is pushed (oldest
    /// first, capped at `EX_HISTORY_MAX`). Up / Down on the cmdline
    /// walks it. Volatile (not persisted across relaunches; that's a
    /// follow-up).
    ex_history: Vec<String>,
    /// Index past the newest entry while walking history. `None` ⇒ not
    /// walking. Set on the first Up; cleared on Enter / Esc.
    ex_history_cursor: Option<usize>,
    /// What the user had typed before they started walking history; restored
    /// on Down past the newest.
    ex_history_typing: Option<String>,
    /// qa-6th 2026-06-29 — `Ctrl+R` in cmdline armed the
    /// register-insert prefix. Vim's canonical follow-ups are
    /// `Ctrl+W` (insert word under cursor) and `Ctrl+A` (insert
    /// WORD). Auto-clears if the next key isn't one of those.
    cmdline_pending_ctrl_r: bool,
}

const EX_HISTORY_MAX: usize = 100;

impl VimInputHandler {
    pub fn new(cfg: &Config) -> Self {
        VimInputHandler {
            mode: VimMode::Normal,
            count: None,
            op: None,
            prefix: Prefix::None,
            cmdline: None,
            cmdline_cursor: 0,
            tab_width: cfg.editor.tab_width.max(1),
            text_width: cfg.editor.text_width.max(8),
            last_find_char: None,
            pending_register: None,
            insert_waiting_for_register: false,
            insert_literal_next: false,
            is_recording_macro: false,
            pending_surround_ops: Vec::new(),
            insert_oneshot_normal: false,
            ex_history: Vec::new(),
            ex_history_cursor: None,
            ex_history_typing: None,
            cmdline_pending_ctrl_r: false,
        }
    }

    fn reset_pending(&mut self) {
        self.count = None;
        self.op = None;
        self.prefix = Prefix::None;
    }

    fn count1(&self) -> u32 {
        self.count.unwrap_or(1).max(1)
    }

    /// `n` copies of `op`, collapsed into a single `Repeat` when `n > 1`.
    fn repeated(op: EditOp, n: u32) -> Vec<EditOp> {
        if n > 1 {
            vec![EditOp::Repeat(n, Box::new(op))]
        } else {
            vec![op]
        }
    }

    fn enter_insert(&mut self) {
        self.mode = VimMode::Insert;
        self.reset_pending();
    }

    /// Open the `:` cmdline with empty text and the caret at the start.
    /// Centralizes the "begin-cmdline" gesture so every entrypoint stays
    /// consistent with the cursor field.
    fn open_cmdline(&mut self) {
        self.cmdline = Some(String::new());
        self.cmdline_cursor = 0;
    }

    /// `:` pressed from Visual/VisualLine/VisualBlock — vim canonically
    /// prefixes the cmdline with `'<,'>` so the ex command targets the
    /// current visual selection. `'<`/`'>` resolves against
    /// `Editor::last_selection`, so the caller must have captured the
    /// live selection to that field before the mark parser runs. We
    /// can't do that from the input handler (no editor mut here), so
    /// we emit `RememberSelection` alongside the cmdline seed.
    fn open_cmdline_visual_range(&mut self) {
        self.cmdline = Some("'<,'>".to_string());
        self.cmdline_cursor = "'<,'>".len();
    }

    fn enter_normal(&mut self) {
        self.mode = VimMode::Normal;
        self.reset_pending();
        self.cmdline = None;
    }

    /// True when the op (or any wrapped inner op) touches the clipboard —
    /// used to decide whether a pending `"<reg>` hint should be consumed
    /// for this dispatch. Yank, paste, cut, line/word/selection delete
    /// (vim's `d` always yanks the deleted text). Pure motions / undo /
    /// editing-without-deletion don't.
    fn touches_clipboard(op: &EditOp) -> bool {
        use EditOp::*;
        matches!(
            op,
            YankLine
                | YankSelection
                | YankBlock
                | PasteAfter
                | PasteBefore
                | PasteAfterEnd
                | PasteBeforeEnd
                | Paste
                | CutSelection
                | DeleteSelection
                | DeleteLine
                | DeleteForward
                | DeleteWordLeft
                | DeleteWordRight
                | DeleteToLineStart
                | DeleteToLineEnd
                | DeleteBlock
        ) || matches!(op, Repeat(_, inner) if Self::touches_clipboard(inner))
    }

    /// Map a key to a pure cursor motion (used standalone and after an operator).
    /// `None` ⇒ not a motion.
    fn motion(code: KeyCode) -> Option<EditOp> {
        use EditOp::*;
        Some(match code {
            KeyCode::Char('h') | KeyCode::Left => MoveLeft,
            KeyCode::Char('l') | KeyCode::Right => MoveRight,
            KeyCode::Char('j') | KeyCode::Down => MoveDown,
            KeyCode::Char('k') | KeyCode::Up => MoveUp,
            KeyCode::Char('w') => MoveWordRight,
            KeyCode::Char('b') => MoveWordLeft,
            KeyCode::Char('e') => MoveWordEnd,
            // WORD motions (whitespace-delimited): `W` / `B` / `E`.
            KeyCode::Char('W') => MoveBigWordRight,
            KeyCode::Char('B') => MoveBigWordLeft,
            KeyCode::Char('E') => MoveBigWordEnd,
            KeyCode::Char('0') | KeyCode::Home => MoveLineStart,
            KeyCode::Char('^') | KeyCode::Char('_') => MoveLineFirstNonWs,
            // Vim `$` (and End) lands on the LAST printable char of
            // the line, not on the trailing `\n` (which is where
            // MoveLineEnd puts the cursor in standard mode). The
            // block-cursor visual difference is the bug nvchad
            // hunters keep catching: `$` and then a paste lands the
            // paste ONE column past where the user expected (the
            // cursor is sitting on `\n`, not the last char).
            // 2026-06-13 SEV-3 S3-02 fix.
            KeyCode::Char('$') | KeyCode::End => MoveLineLastChar,
            // `+` / `<CR>` — down N lines + first non-blank. `-` — up N lines + first non-blank.
            KeyCode::Char('+') | KeyCode::Enter => MoveDownFirstNonWs,
            KeyCode::Char('-') => MoveUpFirstNonWs,
            KeyCode::Char('G') => MoveBufferEnd,
            // `{` / `}` — paragraph nav (prev / next blank-line boundary).
            KeyCode::Char('{') => MoveParagraph { forward: false },
            KeyCode::Char('}') => MoveParagraph { forward: true },
            // `(` / `)` — sentence nav (prev / next sentence boundary).
            KeyCode::Char('(') => MoveSentence { forward: false },
            KeyCode::Char(')') => MoveSentence { forward: true },
            KeyCode::PageUp => PageUp,
            KeyCode::PageDown => PageDown,
            _ => return None,
        })
    }

    fn handle_cmdline(&mut self, key: KeyEvent, line: String) -> InputResult {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let cur = self.cmdline_cursor.min(line.len());
        // qa-6th keyboard SEV-2 2026-06-29 — vim's canonical
        // 2-key `Ctrl+R Ctrl+W` (insert word) /
        // `Ctrl+R Ctrl+A` (insert WORD). First Ctrl+R arms the
        // pending flag; the next Ctrl+W/Ctrl+A fires the App-side
        // resolver. Any other key clears the flag.
        if self.cmdline_pending_ctrl_r {
            self.cmdline_pending_ctrl_r = false;
            if ctrl && matches!(key.code, KeyCode::Char('w' | 'a')) {
                self.cmdline = Some(line);
                let want_big_word = matches!(key.code, KeyCode::Char('a'));
                return InputResult::App(AppCommand::CmdlineInsertCursorWord(want_big_word));
            }
            // Fall through with the flag cleared — the key now
            // means what it normally does (Ctrl+W still deletes
            // the prev word, etc.).
        }
        if matches!(key.code, KeyCode::Char('r')) && ctrl {
            self.cmdline_pending_ctrl_r = true;
            self.cmdline = Some(line);
            return InputResult::Consumed;
        }
        // Ctrl+W in cmdline ⇒ delete the previous word (cursor moves left
        // by the deleted span).
        if matches!(key.code, KeyCode::Char('w')) && ctrl {
            let mut end = cur;
            // Strip trailing whitespace BEFORE the cursor.
            while end > 0 {
                let prev = prev_char_boundary(&line, end);
                let c = line[prev..end].chars().next().unwrap_or(' ');
                if !c.is_whitespace() {
                    break;
                }
                end = prev;
            }
            // Strip the trailing run of non-whitespace.
            let mut new_start = end;
            while new_start > 0 {
                let prev = prev_char_boundary(&line, new_start);
                let c = line[prev..new_start].chars().next().unwrap_or(' ');
                if c.is_whitespace() {
                    break;
                }
                new_start = prev;
            }
            let mut s = line;
            s.replace_range(new_start..cur, "");
            self.cmdline_cursor = new_start;
            self.cmdline = Some(s);
            return InputResult::Consumed;
        }
        // Ctrl+U in cmdline ⇒ clear the whole line.
        if matches!(key.code, KeyCode::Char('u')) && ctrl {
            self.cmdline = Some(String::new());
            self.cmdline_cursor = 0;
            return InputResult::Consumed;
        }
        // Ctrl+A / Ctrl+E ⇒ jump to start / end of line (vim+readline canon).
        if matches!(key.code, KeyCode::Char('a')) && ctrl {
            self.cmdline_cursor = 0;
            self.cmdline = Some(line);
            return InputResult::Consumed;
        }
        if matches!(key.code, KeyCode::Char('e')) && ctrl {
            self.cmdline_cursor = line.len();
            self.cmdline = Some(line);
            return InputResult::Consumed;
        }
        match key.code {
            KeyCode::Tab => {
                // Stash the current line back on the handler so the App can
                // read it via `cmdline_get`, compute completions (which may
                // include workspace file paths the handler can't see), and
                // write the result back via `cmdline_set`. Cursor returns
                // to end-of-line after Tab. The App-level Tab handler also
                // bumps `cmdline_popup_selected` so the floating popup's
                // highlight stays in sync.
                self.cmdline = Some(line);
                InputResult::App(AppCommand::CmdlineTabComplete)
            }
            KeyCode::BackTab => {
                // 2026-06-19 — Shift+Tab retreats the popup
                // selection one step (Tab's inverse).
                self.cmdline = Some(line);
                InputResult::App(AppCommand::CmdlinePopupMove(-1))
            }
            KeyCode::Esc => {
                self.cmdline = None;
                self.cmdline_cursor = 0;
                self.ex_history_cursor = None;
                self.ex_history_typing = None;
                InputResult::Consumed
            }
            KeyCode::Enter => {
                self.cmdline = None;
                self.cmdline_cursor = 0;
                self.ex_history_cursor = None;
                self.ex_history_typing = None;
                if line.is_empty() {
                    InputResult::Consumed
                } else {
                    // Push onto history — de-dupe against the most-recent
                    // entry, cap length.
                    if self.ex_history.last() != Some(&line) {
                        self.ex_history.push(line.clone());
                        if self.ex_history.len() > EX_HISTORY_MAX {
                            let drop = self.ex_history.len() - EX_HISTORY_MAX;
                            self.ex_history.drain(..drop);
                        }
                    }
                    // CmdlineEnter (not ExCommand) so the App can
                    // accept the popup's highlighted match if the
                    // typed first-word isn't itself a valid
                    // command id.
                    InputResult::App(AppCommand::CmdlineEnter(line))
                }
            }
            KeyCode::Up => {
                // 2026-06-19 — when ex-history is empty (fresh
                // session) OR no history nav is active and the
                // popup is showing, route Up to popup nav.
                // Vim power users with history see no behavior
                // change; new users get popup nav out of the box.
                if self.ex_history.is_empty() {
                    self.cmdline = Some(line);
                    return InputResult::App(AppCommand::CmdlinePopupMove(-1));
                }
                if self.ex_history_cursor.is_none() {
                    self.ex_history_typing = Some(line.clone());
                    self.ex_history_cursor = Some(self.ex_history.len());
                }
                let curh = self.ex_history_cursor.unwrap_or(self.ex_history.len());
                let new = curh.saturating_sub(1);
                self.ex_history_cursor = Some(new);
                let entry = self.ex_history[new].clone();
                self.cmdline_cursor = entry.len();
                self.cmdline = Some(entry);
                InputResult::Consumed
            }
            KeyCode::Down => {
                if self.ex_history.is_empty() || self.ex_history_cursor.is_none() {
                    self.cmdline = Some(line);
                    return InputResult::App(AppCommand::CmdlinePopupMove(1));
                }
                let curh = self.ex_history_cursor.unwrap();
                let new = curh + 1;
                if new >= self.ex_history.len() {
                    let entry = self.ex_history_typing.take().unwrap_or_default();
                    self.cmdline_cursor = entry.len();
                    self.cmdline = Some(entry);
                    self.ex_history_cursor = None;
                } else {
                    self.ex_history_cursor = Some(new);
                    let entry = self.ex_history[new].clone();
                    self.cmdline_cursor = entry.len();
                    self.cmdline = Some(entry);
                }
                InputResult::Consumed
            }
            KeyCode::Left => {
                self.cmdline_cursor = prev_char_boundary(&line, cur);
                self.cmdline = Some(line);
                InputResult::Consumed
            }
            KeyCode::Right => {
                self.cmdline_cursor = next_char_boundary(&line, cur);
                self.cmdline = Some(line);
                InputResult::Consumed
            }
            KeyCode::Home => {
                self.cmdline_cursor = 0;
                self.cmdline = Some(line);
                InputResult::Consumed
            }
            KeyCode::End => {
                self.cmdline_cursor = line.len();
                self.cmdline = Some(line);
                InputResult::Consumed
            }
            KeyCode::Backspace => {
                if cur == 0 {
                    if line.is_empty() {
                        self.cmdline = None;
                        self.cmdline_cursor = 0;
                    } else {
                        self.cmdline = Some(line);
                    }
                    InputResult::Consumed
                } else {
                    let prev = prev_char_boundary(&line, cur);
                    let mut s = line;
                    s.replace_range(prev..cur, "");
                    self.cmdline_cursor = prev;
                    self.cmdline = Some(s);
                    self.ex_history_cursor = None;
                    self.ex_history_typing = None;
                    InputResult::Consumed
                }
            }
            KeyCode::Delete => {
                if cur < line.len() {
                    let next = next_char_boundary(&line, cur);
                    let mut s = line;
                    s.replace_range(cur..next, "");
                    self.cmdline = Some(s);
                    self.ex_history_cursor = None;
                    self.ex_history_typing = None;
                }
                InputResult::Consumed
            }
            KeyCode::Char(c) => {
                let mut s = line;
                s.insert(cur, c);
                self.cmdline_cursor = cur + c.len_utf8();
                self.cmdline = Some(s);
                self.ex_history_cursor = None;
                self.ex_history_typing = None;
                InputResult::Consumed
            }
            _ => {
                self.cmdline = Some(line);
                InputResult::Consumed
            }
        }
    }

    /// vim Replace mode (`R`) handler — each printable char overwrites the
    /// char under the cursor and advances. Esc returns to Normal. Arrow
    /// keys + Backspace move without overwriting (vim canonical behavior
    /// is "restore the original char on Backspace"; we just move left for
    /// the MVP).
    fn handle_replace(&mut self, key: KeyEvent, _ctx: &EditCtx) -> InputResult {
        use EditOp::*;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc => {
                self.enter_normal();
                InputResult::Ops(vec![MoveLeft])
            }
            KeyCode::Char('c') if ctrl => {
                self.enter_normal();
                InputResult::Consumed
            }
            KeyCode::Char(c) if !ctrl => InputResult::Ops(vec![OverwriteCharAndAdvance(c)]),
            KeyCode::Enter => InputResult::Ops(vec![InsertNewline]),
            KeyCode::Tab => InputResult::Ops(vec![InsertStr(" ".repeat(self.tab_width))]),
            // vim canonical: Backspace pops the last Replace overwrite —
            // restores the original char (or removes an EOL-inserted one).
            KeyCode::Backspace => InputResult::Ops(vec![ReplaceUndoOne]),
            KeyCode::Delete => InputResult::Ops(vec![DeleteForward]),
            KeyCode::Left => InputResult::Ops(vec![MoveLeft]),
            KeyCode::Right => InputResult::Ops(vec![MoveRight]),
            KeyCode::Up => InputResult::Ops(vec![MoveUp]),
            KeyCode::Down => InputResult::Ops(vec![MoveDown]),
            KeyCode::Home => InputResult::Ops(vec![MoveLineStart]),
            KeyCode::End => InputResult::Ops(vec![MoveLineEnd]),
            _ => InputResult::Ignored,
        }
    }

    fn handle_insert(&mut self, key: KeyEvent, _ctx: &EditCtx) -> InputResult {
        use EditOp::*;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        // Insert-mode literal-next (set by `Ctrl+V` / `Ctrl+Q`) — the next
        // keystroke is inserted verbatim. Tab ⇒ `\t`, Enter ⇒ `\n`, Esc ⇒ no-op.
        if self.insert_literal_next {
            self.insert_literal_next = false;
            return match key.code {
                KeyCode::Char(c) => InputResult::Ops(vec![InsertChar(c)]),
                KeyCode::Tab => InputResult::Ops(vec![InsertChar('\t')]),
                KeyCode::Enter => InputResult::Ops(vec![InsertChar('\n')]),
                KeyCode::Esc => InputResult::Consumed,
                _ => InputResult::Consumed,
            };
        }
        // Insert-mode `Ctrl+R <reg>` — paste the named register inline.
        // Was set on the previous keystroke (see the Ctrl+R arm below).
        if self.insert_waiting_for_register {
            self.insert_waiting_for_register = false;
            if let KeyCode::Char(c) = key.code {
                // nvchad-user 2026-06-28 SEV-2: check Ctrl-modifier
                // chord FIRST so `Ctrl+R Ctrl+W` and `Ctrl+R Ctrl+A`
                // don't get eaten by the lowercase register-paste
                // arm below (was: lowercase matched 'w'/'a' and
                // pasted register 'w'/'a' instead of firing the
                // word-under-cursor command).
                if c == 'w' && ctrl {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_word_under_cursor".into(),
                    ));
                }
                if c == 'a' && ctrl {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_bigword_under_cursor".into(),
                    ));
                }
                // nvchad-round-7 SEV-3 2026-07-11: special registers
                // `%` (current file), `/` (last search). `#`, `:`,
                // `.`, `=` fall through to the register-paste arm
                // below and toast "empty" (their state isn't threaded
                // yet).
                if c == '%' {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_current_filename".into(),
                    ));
                }
                if c == '#' {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_alt_filename".into(),
                    ));
                }
                if c == '/' {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_last_search".into(),
                    ));
                }
                if c == ':' {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_last_cmdline".into(),
                    ));
                }
                if c == '.' {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_last_inserted".into(),
                    ));
                }
                // nvchad-2nd 2026-06-28 SEV-2: `"` (unnamed register)
                // is the most-used INSERT-mode paste target and was
                // missing from the accepted list. Vim users reflexively
                // type `<C-R>"` to paste what they just yanked.
                let valid = c.is_ascii_lowercase() || c == '0' || c == '+' || c == '_' || c == '"';
                if valid {
                    return InputResult::Ops(vec![SetRegisterHint(Some(c)), Paste]);
                }
                // (Ctrl+R Ctrl+W and Ctrl+R Ctrl+A handled above
                // before the lowercase register-paste arm.)
            }
            return InputResult::Consumed;
        }
        match key.code {
            // vim insert `Ctrl+R` — followed by a register letter, pastes
            // that register's contents at the cursor (vim canonical).
            KeyCode::Char('r') if ctrl => {
                self.insert_waiting_for_register = true;
                InputResult::Consumed
            }
            // vim insert `Ctrl+O` — temporarily switch to Normal for one
            // command, then back to Insert. Cleared in the post-dispatch
            // hook in `handle_key` (chord-aware: stays Normal until chord
            // completes).
            KeyCode::Char('o') if ctrl => {
                self.mode = VimMode::Normal;
                self.insert_oneshot_normal = true;
                InputResult::Consumed
            }
            // vim insert `Ctrl+N` / `Ctrl+P` — keyword completion (scan
            // the active buffer for words matching the prefix). Routes
            // through the same completion popup as LSP completion.
            KeyCode::Char('n') if ctrl => {
                InputResult::App(AppCommand::RunCommand("editor.keyword_complete".into()))
            }
            KeyCode::Char('p') if ctrl => InputResult::App(AppCommand::RunCommand(
                "editor.keyword_complete_back".into(),
            )),
            // vim insert `Ctrl+F` — mnml maps this to the file picker
            // so vim's `Ctrl+X Ctrl+F` (file-path completion under the
            // cursor) has a discoverable mnml equivalent. Standard vim
            // gates this behind Ctrl+X first, but Ctrl+X in mnml's
            // Insert mode is a passthrough (see the docstring at
            // ex-cmd `Ctrl+X`), so `Ctrl+F` alone reaches the picker.
            // Without this arm the global find.find binding intercepts
            // Ctrl+F in Insert mode too and vim users have no path to
            // file completion. nvchad-round-10 SEV-2 2026-07-12.
            KeyCode::Char('f') if ctrl => {
                InputResult::App(AppCommand::RunCommand("picker.files".into()))
            }
            // vim insert `Ctrl+Y` / `Ctrl+E` — insert the char from the
            // line above / below at the same column. Useful for "copy this
            // structure" gestures.
            KeyCode::Char('y') if ctrl => {
                InputResult::Ops(vec![InsertCharFromLine { above: true }])
            }
            KeyCode::Char('e') if ctrl => {
                InputResult::Ops(vec![InsertCharFromLine { above: false }])
            }
            KeyCode::Esc => {
                // vim drifts the cursor one left when leaving Insert.
                self.enter_normal();
                InputResult::Ops(vec![MoveLeft])
            }
            KeyCode::Char('c') if ctrl => {
                self.enter_normal();
                InputResult::Consumed
            }
            // Insert-mode chords (vim canonical):
            // Ctrl+W ⇒ delete previous word
            // Ctrl+U ⇒ delete to start of line
            // Ctrl+H ⇒ backspace alias
            // Ctrl+T / Ctrl+D ⇒ indent / outdent current line
            KeyCode::Char('w') if ctrl => InputResult::Ops(vec![DeleteWordLeft]),
            KeyCode::Char('u') if ctrl => InputResult::Ops(vec![DeleteToLineStart]),
            KeyCode::Char('h') if ctrl => InputResult::Ops(vec![Backspace]),
            KeyCode::Char('t') if ctrl => InputResult::Ops(vec![Indent]),
            KeyCode::Char('d') if ctrl => InputResult::Ops(vec![Outdent]),
            // Ctrl+V / Ctrl+Q ⇒ literal-next (vim canonical). The next
            // keystroke is inserted verbatim (Tab as `\t`, etc.) instead of
            // going through the usual chord / tab-expand path.
            KeyCode::Char('v') if ctrl => {
                self.insert_literal_next = true;
                InputResult::Consumed
            }
            KeyCode::Char('q') if ctrl => {
                self.insert_literal_next = true;
                InputResult::Consumed
            }
            KeyCode::Char(c) if !ctrl => InputResult::Ops(vec![InsertChar(c)]),
            // nvchad-user 2026-06-28 SEV-1: Ctrl+J in vim INSERT
            // should insert a newline (vim's `<C-J>` is the same
            // code-point family as `<C-M>` / Enter). Stripping it
            // from the keymap got it to the editor; this handler
            // arm actually does the insert.
            KeyCode::Char('j') if ctrl => InputResult::Ops(vec![InsertNewline]),
            // (Ctrl+H in INSERT is already handled by the arm above
            // at line 871 — code-reviewer 2026-06-28 W-2 dead code
            // removal.)
            KeyCode::Enter => InputResult::Ops(vec![InsertNewline]),
            KeyCode::Tab => InputResult::Ops(vec![InsertStr(" ".repeat(self.tab_width))]),
            KeyCode::Backspace => InputResult::Ops(vec![Backspace]),
            KeyCode::Delete => InputResult::Ops(vec![DeleteForward]),
            KeyCode::Left => InputResult::Ops(vec![MoveLeft]),
            KeyCode::Right => InputResult::Ops(vec![MoveRight]),
            KeyCode::Up => InputResult::Ops(vec![MoveUp]),
            KeyCode::Down => InputResult::Ops(vec![MoveDown]),
            KeyCode::Home => InputResult::Ops(vec![MoveLineStart]),
            KeyCode::End => InputResult::Ops(vec![MoveLineEnd]),
            _ => InputResult::Ignored,
        }
    }

    fn handle_normal(&mut self, key: KeyEvent, ctx: &EditCtx) -> InputResult {
        use EditOp::*;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);

        // ── multi-key prefixes ───────────────────────────────────────
        match self.prefix {
            Prefix::Replace => {
                let n = self.count1().max(1) as usize;
                self.reset_pending();
                return match key.code {
                    KeyCode::Char(c) => {
                        // `[count]r<c>` — replace the next `count` chars with `<c>`.
                        // Cursor lands on the last replaced char (vim convention).
                        // Sequence: Replace, MoveRight, Replace, ... Replace
                        // (n replaces, n-1 MoveRights).
                        let mut ops: Vec<EditOp> = Vec::with_capacity(n.saturating_mul(2));
                        for i in 0..n {
                            ops.push(EditOp::ReplaceCharAtCursor(c));
                            if i + 1 < n {
                                ops.push(EditOp::MoveRight);
                            }
                        }
                        InputResult::Ops(ops)
                    }
                    KeyCode::Esc => InputResult::Consumed,
                    _ => InputResult::Consumed,
                };
            }
            Prefix::Z => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char('Z') => InputResult::App(AppCommand::ExCommand("x".into())),
                    KeyCode::Char('Q') => InputResult::App(AppCommand::ExCommand("q!".into())),
                    _ => InputResult::Consumed,
                };
            }
            Prefix::BlockReplaceChar => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char(c) => {
                        self.enter_normal();
                        InputResult::App(AppCommand::BlockReplaceWith { ch: c })
                    }
                    _ => InputResult::Consumed,
                };
            }
            Prefix::ZFold => {
                self.reset_pending();
                return match key.code {
                    // za / zo / zc → toggle at cursor. `zA` was
                    // previously unbound — nvchad round 5 SEV-3
                    // 2026-07-11. mnml folds are line-based (single
                    // level per header), so `zA` (toggle recursive)
                    // reduces to the same toggle in practice — bind
                    // it to the same action rather than leaving a
                    // dead chord that silently no-ops.
                    KeyCode::Char('a' | 'A' | 'o' | 'O' | 'c' | 'C') => {
                        InputResult::App(AppCommand::RunCommand("editor.toggle_fold".into()))
                    }
                    // `zR` opens all folds; `zE` removes every fold (vim
                    // canon — same effect in mnml since folds are line-based
                    // and unfold = drop the entry).
                    KeyCode::Char('R') | KeyCode::Char('E') => {
                        InputResult::App(AppCommand::RunCommand("editor.unfold_all".into()))
                    }
                    // `zM` — fold all (mnml uses server-suggested ranges via
                    // textDocument/foldingRange; falls back to bracket-scan
                    // when no LSP). Vim's `zM` closes every fold; ours
                    // first runs the bracket-scan fallback (so folds
                    // exist even without LSP) and then also asks the
                    // server. nvchad-round-7 SEV-2 2026-07-11.
                    KeyCode::Char('M') => {
                        InputResult::App(AppCommand::RunCommand("editor.fold_all_brackets".into()))
                    }
                    // vim cursor-position scroll chords: `zz` (center),
                    // `zt` (top), `zb` (bottom). Keep the cursor put,
                    // shift the viewport.
                    KeyCode::Char('z') => {
                        InputResult::App(AppCommand::RunCommand("view.cursor_to_center".into()))
                    }
                    KeyCode::Char('t') => {
                        InputResult::App(AppCommand::RunCommand("view.cursor_to_top".into()))
                    }
                    KeyCode::Char('b') => {
                        InputResult::App(AppCommand::RunCommand("view.cursor_to_bottom".into()))
                    }
                    // vim horizontal-scroll chords: `zh` / `zl` scroll left
                    // / right by one column; `zH` / `zL` by half a screen.
                    KeyCode::Char('h') => {
                        InputResult::App(AppCommand::RunCommand("view.hscroll_left".into()))
                    }
                    KeyCode::Char('l') => {
                        InputResult::App(AppCommand::RunCommand("view.hscroll_right".into()))
                    }
                    KeyCode::Char('H') => {
                        InputResult::App(AppCommand::RunCommand("view.hscroll_left_half".into()))
                    }
                    KeyCode::Char('L') => {
                        InputResult::App(AppCommand::RunCommand("view.hscroll_right_half".into()))
                    }
                    // nvchad-round-7 SEV-3 2026-07-11 — inter-fold nav.
                    // `zj` jumps to the start of the next fold; `zk` to
                    // the end of the previous.
                    KeyCode::Char('j') => {
                        InputResult::App(AppCommand::RunCommand("editor.fold_next".into()))
                    }
                    KeyCode::Char('k') => {
                        InputResult::App(AppCommand::RunCommand("editor.fold_prev".into()))
                    }
                    // nvchad-round-8 SEV-3 2026-07-11 — `zf` creates a
                    // fold. `zff` closes the enclosing bracket pair
                    // (same as `zc` on the header line — mnml's fold
                    // model treats "fold-here" and "close-fold" as one
                    // operation). Motion-based `zf<motion>` is a
                    // follow-up (needs motion parsing to get an end
                    // line); the common case is covered.
                    KeyCode::Char('f') => {
                        InputResult::App(AppCommand::RunCommand("editor.toggle_fold".into()))
                    }
                    _ => InputResult::Consumed,
                };
            }
            Prefix::G => {
                let n = self.count1();
                let count_was_explicit = self.count.is_some();
                // Stash the pending op (if any) — `reset_pending` would
                // clear it, but op-pending `gn` / `gN` etc. need it.
                let pending_op = self.op;
                self.reset_pending();
                return match key.code {
                    // `g Ctrl+G` — file stats toast (lines / words / chars /
                    // bytes / cursor position). Vim canonical "more
                    // detailed than `Ctrl+G`". Must come before the bare
                    // `g` arm.
                    KeyCode::Char('g') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        InputResult::App(AppCommand::RunCommand("editor.file_stats".into()))
                    }
                    KeyCode::Char('g') => {
                        // `gg` ⇒ first line. `<count>gg` ⇒ go to line `<count>`
                        // (vim canonical: same as `<count>G`).
                        if count_was_explicit {
                            InputResult::Ops(vec![EditOp::MoveToLine(n as usize)])
                        } else {
                            InputResult::Ops(vec![MoveBufferStart])
                        }
                    }
                    KeyCode::Char('d') => {
                        InputResult::App(AppCommand::RunCommand("lsp.goto_definition".into()))
                    }
                    KeyCode::Char('D') => {
                        InputResult::App(AppCommand::RunCommand("lsp.goto_declaration".into()))
                    }
                    // `gf` — open the path under the cursor (vim convention).
                    KeyCode::Char('f') => {
                        InputResult::App(AppCommand::RunCommand("editor.open_at_cursor".into()))
                    }
                    // `gx` — open the URL under the cursor in the OS browser.
                    KeyCode::Char('x') => {
                        InputResult::App(AppCommand::RunCommand("editor.open_url_at_cursor".into()))
                    }
                    // `gi` — jump to the most recent edit position + enter
                    // Insert mode (vim canon).
                    KeyCode::Char('i') => {
                        InputResult::App(AppCommand::RunCommand("vim.go_to_last_insert".into()))
                    }
                    // `gI` — insert at literal column 0 (vs. `I` which
                    // goes to first non-blank). Enters Insert mode.
                    KeyCode::Char('I') => {
                        self.enter_insert();
                        InputResult::Ops(vec![MoveLineStart])
                    }
                    KeyCode::Char('c') => {
                        self.prefix = Prefix::Gc;
                        self.count = if n > 1 { Some(n) } else { None };
                        InputResult::Consumed
                    }
                    KeyCode::Char('q') => {
                        self.prefix = Prefix::Gq;
                        InputResult::Consumed
                    }
                    KeyCode::Char('v') => {
                        // `gv` — re-establish the last visual selection.
                        // The editor restores `(anchor, cursor)`; we flip the
                        // handler into Visual mode so subsequent keys behave.
                        self.mode = VimMode::Visual;
                        InputResult::Ops(vec![RestoreLastSelection])
                    }
                    // `g;` / `g,` — walk backward / forward through the
                    // change list (vim's per-buffer edit-position history).
                    KeyCode::Char(';') => {
                        InputResult::App(AppCommand::RunCommand("editor.jump_prev_edit".into()))
                    }
                    KeyCode::Char(',') => {
                        InputResult::App(AppCommand::RunCommand("editor.jump_next_edit".into()))
                    }
                    // `gJ` — join lines verbatim (no space inserted, no
                    // whitespace trimmed). vim convention.
                    KeyCode::Char('J') => {
                        let times = n.max(1).saturating_sub(1).max(1);
                        InputResult::Ops(Self::repeated(JoinLines { keep_space: false }, times))
                    }
                    // `g_` — move to last non-blank char of the current line.
                    KeyCode::Char('_') => InputResult::Ops(vec![MoveLineLastNonWs]),
                    // `ge` / `gE` — end of previous word / WORD. Motions, so
                    // they compose with operators (`dge` deletes back to the
                    // end of the prior word).
                    KeyCode::Char('e') => InputResult::Ops(Self::repeated(MoveWordEndBack, n)),
                    KeyCode::Char('E') => InputResult::Ops(Self::repeated(MoveBigWordEndBack, n)),
                    // `g0` / `g^` / `g$` / `gj` / `gk` / `gm` — display-line
                    // motions. With `[ui] wrap` on, walk one visual row;
                    // otherwise alias to the logical-line equivalent. `gm`
                    // ⇒ middle of the (single) line — half the line width.
                    KeyCode::Char('0') => match ctx.wrap_width {
                        Some(w) => InputResult::Ops(vec![MoveVisualLineStart(w)]),
                        None => InputResult::Ops(vec![MoveLineStart]),
                    },
                    KeyCode::Char('^') => InputResult::Ops(vec![MoveLineFirstNonWs]),
                    KeyCode::Char('$') => match ctx.wrap_width {
                        Some(w) => InputResult::Ops(vec![MoveVisualLineEnd(w)]),
                        None => InputResult::Ops(vec![MoveLineEnd]),
                    },
                    KeyCode::Char('j') => match ctx.wrap_width {
                        Some(w) => InputResult::Ops(Self::repeated(EditOp::MoveVisualDown(w), n)),
                        None => InputResult::Ops(Self::repeated(EditOp::MoveDown, n)),
                    },
                    KeyCode::Char('k') => match ctx.wrap_width {
                        Some(w) => InputResult::Ops(Self::repeated(EditOp::MoveVisualUp(w), n)),
                        None => InputResult::Ops(Self::repeated(EditOp::MoveUp, n)),
                    },
                    // `gu{motion}` — lowercase. Sets a pending op + waits
                    // for a motion (or `u` for the doubled "current line"
                    // form). E.g. `guu` lowercases the line; `guw` the word.
                    KeyCode::Char('u') => {
                        self.op = Some(PendingOp::Lower);
                        InputResult::Consumed
                    }
                    // `gU{motion}` — uppercase.
                    KeyCode::Char('U') => {
                        self.op = Some(PendingOp::Upper);
                        InputResult::Consumed
                    }
                    // `g~{motion}` — toggle case.
                    KeyCode::Char('~') => {
                        self.op = Some(PendingOp::ToggleCase);
                        InputResult::Consumed
                    }
                    // `gn` / `gN` — find as text-object. Standalone (no
                    // pending operator) ⇒ run the App command which sets
                    // editor.anchor + cursor. Operator-pending form
                    // (`cgn` / `dgn` / `ygn` / `gugn` / etc.) builds the
                    // selection + operator effect from the pre-computed
                    // match range carried in `ctx`.
                    // `gp` / `gP` — paste; cursor lands at END of the pasted
                    // text (vs. plain `p`/`P` where it lands at the start of
                    // a linewise paste). Vim convention.
                    KeyCode::Char('p') => InputResult::Ops(vec![PasteAfterEnd]),
                    KeyCode::Char('P') => InputResult::Ops(vec![PasteBeforeEnd]),
                    // `g*` / `g#` — like `*` / `#` but match the word as a
                    // substring (no word-boundary requirement). mnml's
                    // find is already substring-based (no `\b` in literal
                    // mode) so we route to the same commands.
                    KeyCode::Char('*') => {
                        InputResult::App(AppCommand::RunCommand("find.word_forward".into()))
                    }
                    KeyCode::Char('#') => {
                        InputResult::App(AppCommand::RunCommand("find.word_backward".into()))
                    }
                    // `gt` / `gT` — vim "next/prev tab page". With a
                    // count, `[N]gt` jumps to absolute tab N and
                    // `[N]gT` jumps N tabs back.
                    KeyCode::Char('t') => {
                        let n = self.count.take();
                        match n {
                            Some(n) => {
                                InputResult::App(AppCommand::ExCommand(format!("tabnext {n}")))
                            }
                            None => InputResult::App(AppCommand::RunCommand("tab.next".into())),
                        }
                    }
                    KeyCode::Char('T') => {
                        let n = self.count.take();
                        match n {
                            Some(n) => {
                                InputResult::App(AppCommand::ExCommand(format!("tabprev {n}")))
                            }
                            None => InputResult::App(AppCommand::RunCommand("tab.prev".into())),
                        }
                    }
                    KeyCode::Char(c @ ('n' | 'N')) => {
                        let forward = c == 'n';
                        if let Some(op) = pending_op {
                            let range = if forward {
                                ctx.next_find_match
                            } else {
                                ctx.prev_find_match
                            };
                            // already reset above
                            let Some((start, end)) = range else {
                                let cmd = if forward {
                                    "find.select_match_forward"
                                } else {
                                    "find.select_match_backward"
                                };
                                return InputResult::App(AppCommand::RunCommand(cmd.into()));
                            };
                            let mut ops =
                                vec![SetCursorByte(start), SelectStart, SetCursorByte(end)];
                            match op {
                                PendingOp::Delete => ops.push(DeleteSelection),
                                PendingOp::Yank => {
                                    ops.push(YankSelection);
                                    ops.push(SelectClear);
                                }
                                PendingOp::Change => {
                                    ops.push(ReplaceSelection(String::new()));
                                    self.mode = VimMode::Insert;
                                }
                                PendingOp::Lower => {
                                    ops.push(TransformSelectionCase(
                                        crate::edit_op::CaseTransform::Lower,
                                    ));
                                    ops.push(SelectClear);
                                }
                                PendingOp::Upper => {
                                    ops.push(TransformSelectionCase(
                                        crate::edit_op::CaseTransform::Upper,
                                    ));
                                    ops.push(SelectClear);
                                }
                                PendingOp::ToggleCase => {
                                    ops.push(TransformSelectionCase(
                                        crate::edit_op::CaseTransform::Toggle,
                                    ));
                                    ops.push(SelectClear);
                                }
                                PendingOp::Indent
                                | PendingOp::Outdent
                                | PendingOp::Reflow
                                | PendingOp::SurroundAdd
                                | PendingOp::Align
                                | PendingOp::Comment
                                | PendingOp::Filter => {
                                    // Not meaningful for a find-match
                                    // range — drop silently.
                                    return InputResult::Consumed;
                                }
                            }
                            return InputResult::Ops(ops);
                        }
                        let cmd = if forward {
                            "find.select_match_forward"
                        } else {
                            "find.select_match_backward"
                        };
                        InputResult::App(AppCommand::RunCommand(cmd.into()))
                    }
                    // `ga` — show character info as a toast (decimal + hex).
                    KeyCode::Char('a') => {
                        InputResult::App(AppCommand::RunCommand("editor.char_info".into()))
                    }
                    // `g8` — show UTF-8 bytes of the char under the cursor.
                    KeyCode::Char('8') => {
                        InputResult::App(AppCommand::RunCommand("editor.char_utf8".into()))
                    }
                    // `gA{motion}<char>` — mini.align operator. Capital `A`
                    // because lowercase `ga` is taken by char-info above.
                    // Sets a pending op + waits for a motion (or `A` for
                    // the doubled current-line form, though aligning a
                    // single line is rarely useful).
                    KeyCode::Char('A') => {
                        self.op = Some(PendingOp::Align);
                        InputResult::Consumed
                    }
                    _ => InputResult::Consumed,
                };
            }
            Prefix::Gc => {
                if key.code == KeyCode::Char('c') {
                    self.reset_pending();
                    return InputResult::Ops(vec![ToggleLineComment]);
                }
                // `gcip` / `gcap` — text-object dispatch. Reuses the
                // same TextObjectInner / Around prefix machinery `gq`
                // relies on so paragraph / brackets / quotes all work
                // uniformly. 2026-07-07.
                if matches!(key.code, KeyCode::Char('i')) {
                    self.op = Some(PendingOp::Comment);
                    self.prefix = Prefix::TextObjectInner;
                    return InputResult::Consumed;
                }
                if matches!(key.code, KeyCode::Char('a')) {
                    self.op = Some(PendingOp::Comment);
                    self.prefix = Prefix::TextObjectAround;
                    return InputResult::Consumed;
                }
                self.reset_pending();
                // `gc` + simple motion: select the motion's span,
                // comment it, collapse.
                return match Self::motion(key.code) {
                    Some(m) => {
                        InputResult::Ops(vec![SelectStart, m, ToggleLineComment, SelectClear])
                    }
                    None => InputResult::Consumed,
                };
            }
            Prefix::Gq => {
                self.reset_pending();
                if key.code == KeyCode::Char('q') {
                    // `gqq` — reflow the cursor's paragraph. The width comes
                    // from `[editor] text_width`; the command resolves it.
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.reflow_paragraph".into(),
                    ));
                }
                // `gqip` / `gqap` — the inner-paragraph and around-paragraph
                // text objects. Set the operator + text-object prefix so the
                // existing TextObjectInner/Around dispatch picks it up.
                if matches!(key.code, KeyCode::Char('i')) {
                    self.op = Some(PendingOp::Reflow);
                    self.prefix = Prefix::TextObjectInner;
                    return InputResult::Consumed;
                }
                if matches!(key.code, KeyCode::Char('a')) {
                    self.op = Some(PendingOp::Reflow);
                    self.prefix = Prefix::TextObjectAround;
                    return InputResult::Consumed;
                }
                // `gq` + motion (other) isn't wired yet — treat as cancelled.
                return InputResult::Consumed;
            }
            Prefix::MarkSet => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char(c) if c.is_ascii_alphabetic() => {
                        InputResult::App(AppCommand::SetMark(c))
                    }
                    _ => InputResult::Consumed,
                };
            }
            Prefix::MarkJumpLine => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char(c) if c.is_ascii_alphabetic() => {
                        InputResult::App(AppCommand::JumpToMarkLine(c))
                    }
                    // `''` — jump to the previous cursor position (vim
                    // convention; alias of `nav.back`).
                    KeyCode::Char('\'') => {
                        InputResult::App(AppCommand::RunCommand("nav.back".into()))
                    }
                    _ => InputResult::Consumed,
                };
            }
            Prefix::MarkJumpExact => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char(c) if c.is_ascii_alphabetic() => {
                        InputResult::App(AppCommand::JumpToMarkExact(c))
                    }
                    // `` `` `` — exact jump to previous cursor position.
                    KeyCode::Char('`') => {
                        InputResult::App(AppCommand::RunCommand("nav.back".into()))
                    }
                    _ => InputResult::Consumed,
                };
            }
            Prefix::FindChar(forward, before) => {
                let op = self.op;
                self.reset_pending();
                let KeyCode::Char(c) = key.code else {
                    return InputResult::Consumed;
                };
                // Operator-pending find ⇒ inclusive (vim's `df<c>` / `cf<c>`
                // delete *up to and including* the target; `dt<c>` stops on
                // the target). Standalone find is just a motion.
                let inclusive = op.is_some();
                let motion = FindCharOnLine {
                    ch: c,
                    forward,
                    before,
                    inclusive,
                };
                // Stash for `;` / `,` repeat.
                self.last_find_char = Some((c, forward, before));
                // Standalone find — just move the cursor.
                let Some(op) = op else {
                    return InputResult::Ops(vec![motion]);
                };
                // Operator + find ("df<c>", "ct<c>", …) — select from cursor
                // to the find target, then apply the operator. The selection
                // is cleared at the end (or insert mode entered for Change).
                let mut ops = vec![SelectStart, motion];
                match op {
                    PendingOp::Delete => ops.push(DeleteSelection),
                    PendingOp::Yank => {
                        ops.push(YankSelection);
                        ops.push(SelectClear);
                    }
                    PendingOp::Change => {
                        ops.push(ReplaceSelection(String::new()));
                        self.mode = VimMode::Insert;
                    }
                    PendingOp::Indent => {
                        ops.push(Indent);
                        ops.push(SelectClear);
                    }
                    PendingOp::Outdent => {
                        ops.push(Outdent);
                        ops.push(SelectClear);
                    }
                    PendingOp::Reflow => {
                        // `gqf<c>` / `gqt<c>` — reflow doesn't honor an
                        // arbitrary span yet; fall back to the cursor's
                        // paragraph and ignore the find motion.
                        ops.clear();
                        ops.push(ReflowParagraph {
                            width: self.text_width,
                        });
                    }
                    PendingOp::Lower => {
                        ops.push(TransformSelectionCase(crate::edit_op::CaseTransform::Lower));
                        ops.push(SelectClear);
                    }
                    PendingOp::Upper => {
                        ops.push(TransformSelectionCase(crate::edit_op::CaseTransform::Upper));
                        ops.push(SelectClear);
                    }
                    PendingOp::ToggleCase => {
                        ops.push(TransformSelectionCase(
                            crate::edit_op::CaseTransform::Toggle,
                        ));
                        ops.push(SelectClear);
                    }
                    PendingOp::SurroundAdd => {
                        // Find-char + ys ⇒ stash the find selection ops
                        // and wait for the surround char.
                        self.pending_surround_ops = ops.clone();
                        self.prefix = Prefix::SurroundAddCharWait;
                        return InputResult::Consumed;
                    }
                    PendingOp::Align => {
                        // Find-char span is single-line — alignment needs
                        // multiple lines, so this is a no-op.
                        return InputResult::Consumed;
                    }
                    PendingOp::Comment => {
                        ops.push(ToggleLineComment);
                        ops.push(SelectClear);
                    }
                    PendingOp::Filter => {
                        // `!f<c>` — find-char span is a single row.
                        // Filter is linewise; drop.
                        return InputResult::Consumed;
                    }
                }
                return InputResult::Ops(ops);
            }
            Prefix::TextObjectInner | Prefix::TextObjectAround => {
                let around = matches!(self.prefix, Prefix::TextObjectAround);
                let op = self.op;
                self.reset_pending();
                let Some(op) = op else {
                    return InputResult::Consumed;
                };
                let select_op = match key.code {
                    KeyCode::Char('w') => {
                        if around {
                            SelectAroundWord
                        } else {
                            SelectInnerWord
                        }
                    }
                    KeyCode::Char('W') => {
                        if around {
                            SelectAroundBigWord
                        } else {
                            SelectInnerBigWord
                        }
                    }
                    KeyCode::Char(q @ ('"' | '\'' | '`')) => {
                        if around {
                            SelectAroundQuote(q)
                        } else {
                            SelectInnerQuote(q)
                        }
                    }
                    // `iq` / `aq` (mnml extension) — smart-pick the closest
                    // enclosing quote pair (`"`, `'`, or `` ` ``).
                    KeyCode::Char('q') => {
                        if around {
                            SelectAroundSmartQuote
                        } else {
                            SelectInnerSmartQuote
                        }
                    }
                    KeyCode::Char('p') => {
                        if around {
                            SelectAroundParagraph
                        } else {
                            SelectInnerParagraph
                        }
                    }
                    // Tree-sitter text objects — `if`/`af` = inner/around
                    // function, `ic`/`ac` = inner/around class, `ia`/`aa`
                    // = inner/around argument. Driven by `regex_outline`
                    // for the header lines + brace matching for the body.
                    KeyCode::Char('f') => {
                        if around {
                            SelectAroundFunction
                        } else {
                            SelectInnerFunction
                        }
                    }
                    KeyCode::Char('c') => {
                        if around {
                            SelectAroundClass
                        } else {
                            SelectInnerClass
                        }
                    }
                    KeyCode::Char('a') => {
                        if around {
                            SelectAroundArgument
                        } else {
                            SelectInnerArgument
                        }
                    }
                    // `ii` / `ai` — vim-indent-object: the cursor's
                    // indentation block (around = block + header line).
                    KeyCode::Char('i') => {
                        if around {
                            SelectAroundIndentBlock
                        } else {
                            SelectInnerIndentBlock
                        }
                    }
                    // `it` / `at` — HTML/XML/JSX tag text objects.
                    // Inner: body between `<Foo>` and `</Foo>`.
                    // Around: includes both tags.
                    // nvchad-user SEV-2 2026-07-10.
                    KeyCode::Char('t') => {
                        if around {
                            SelectAroundTag
                        } else {
                            SelectInnerTag
                        }
                    }
                    // `aI` — indent block + header line above *and* the
                    // line below. (`iI` isn't a vim-indent-object verb.)
                    KeyCode::Char('I') if around => SelectOuterIndentBlock,
                    // Brackets — vim accepts the open *or* the close as the
                    // text-object char; both mean "the surrounding pair".
                    // (`ib` / `iB` shorthands aren't wired yet — same shape.)
                    KeyCode::Char(c @ ('(' | ')' | '[' | ']' | '{' | '}' | '<' | '>')) => {
                        let open = match c {
                            ')' => '(',
                            ']' => '[',
                            '}' => '{',
                            '>' => '<',
                            other => other,
                        };
                        if around {
                            SelectAroundBracket(open)
                        } else {
                            SelectInnerBracket(open)
                        }
                    }
                    _ => return InputResult::Consumed,
                };
                let mut ops = vec![select_op];
                match op {
                    PendingOp::Delete => ops.push(DeleteSelection),
                    PendingOp::Yank => {
                        ops.push(YankSelection);
                        ops.push(SelectClear);
                    }
                    PendingOp::Change => {
                        ops.push(ReplaceSelection(String::new()));
                        self.mode = VimMode::Insert;
                    }
                    PendingOp::Indent => {
                        ops.push(Indent);
                        ops.push(SelectClear);
                    }
                    PendingOp::Outdent => {
                        ops.push(Outdent);
                        ops.push(SelectClear);
                    }
                    PendingOp::Reflow => {
                        // For paragraph reflow we don't actually use the
                        // selection — the ReflowParagraph op finds the
                        // paragraph from the cursor's line via
                        // `paragraph_bounds`. Emit it directly instead of
                        // the select_op above. (`gqip` ≡ `gqq`; `gqap` is
                        // identical for now since the paragraph extension
                        // doesn't change reflow output.)
                        ops.clear();
                        ops.push(ReflowParagraph {
                            width: self.text_width,
                        });
                    }
                    PendingOp::Lower => {
                        ops.push(TransformSelectionCase(crate::edit_op::CaseTransform::Lower));
                        ops.push(SelectClear);
                    }
                    PendingOp::Upper => {
                        ops.push(TransformSelectionCase(crate::edit_op::CaseTransform::Upper));
                        ops.push(SelectClear);
                    }
                    PendingOp::ToggleCase => {
                        ops.push(TransformSelectionCase(
                            crate::edit_op::CaseTransform::Toggle,
                        ));
                        ops.push(SelectClear);
                    }
                    PendingOp::SurroundAdd => {
                        // Stash the select-ops and wait for the surround
                        // char. `ops` was built from the text-object's
                        // `select_op`; we use those as the selection.
                        self.pending_surround_ops = ops.clone();
                        self.prefix = Prefix::SurroundAddCharWait;
                        return InputResult::Consumed;
                    }
                    PendingOp::Align => {
                        // Build a live selection out of the text-object
                        // (don't `SelectClear` — the alignment char arrives
                        // next and `AlignSelection` reads `self.selection`).
                        // The motion-emitted op produced the select_op
                        // already; emit `SelectStart` first so anchor=cursor,
                        // then the select_op extends. For text objects we
                        // need to seed the anchor at the start of the
                        // object — simplest path: emit the select_op
                        // alone (it already sets cursor + anchor via the
                        // editor's text-object implementation when no
                        // selection is live). The TextObject select ops
                        // (`SelectInnerParagraph`, etc.) all leave the
                        // selection set, so dispatching them now is
                        // enough.
                        self.prefix = Prefix::AlignCharWait;
                        // ops currently = [select_op]; return it so the
                        // selection is live by the time the next key
                        // arrives.
                        return InputResult::Ops(ops);
                    }
                    PendingOp::Comment => {
                        // `gcip` / `gcap` / `gci{`, etc. — the select_op
                        // established the range; ToggleLineComment
                        // reads the current selection to know which
                        // lines to comment. 2026-07-07 fix.
                        ops.push(ToggleLineComment);
                        ops.push(SelectClear);
                    }
                    PendingOp::Filter => {
                        // `!ip` / `!ap` — text-object filter. Complete
                        // via App: compute line range from the
                        // eventual selection at the App layer.
                        // Simpler MVP: no-op for text objects; users
                        // can drive via `!<motion>` (linewise motion
                        // path). Follow-up would extend to text objs.
                        return InputResult::Consumed;
                    }
                }
                return InputResult::Ops(ops);
            }
            Prefix::BracketOpen => {
                self.reset_pending();
                let cmd = match key.code {
                    KeyCode::Char('c') => "git.jump_prev_change",
                    KeyCode::Char('d') => "lsp.prev_diagnostic",
                    KeyCode::Char('q') => "qf.prev",
                    KeyCode::Char('t') => "project.prev_todo",
                    // nvchad-round-9 SEV-2 2026-07-11 — vim section
                    // navigation. `[[` = prev section (top-level
                    // header — first char at column 0 that opens
                    // a scope). `[]` = end of prev section.
                    KeyCode::Char('[') => "editor.section_prev_start",
                    KeyCode::Char(']') => "editor.section_prev_end",
                    _ => return InputResult::Consumed,
                };
                return InputResult::App(AppCommand::RunCommand(cmd.into()));
            }
            Prefix::BracketClose => {
                self.reset_pending();
                let cmd = match key.code {
                    KeyCode::Char('c') => "git.jump_next_change",
                    KeyCode::Char('d') => "lsp.next_diagnostic",
                    KeyCode::Char('q') => "qf.next",
                    KeyCode::Char('t') => "project.next_todo",
                    // `]]` = next section, `][` = end of next section.
                    KeyCode::Char(']') => "editor.section_next_start",
                    KeyCode::Char('[') => "editor.section_next_end",
                    _ => return InputResult::Consumed,
                };
                return InputResult::App(AppCommand::RunCommand(cmd.into()));
            }
            Prefix::Register => {
                // Pick the named register (`a`-`z`, `0`, `1`-`9`, `+`,
                // `_`); the hint persists for one yank / paste / delete
                // (or operator combo). `prefix` resets but `op` / `count`
                // are preserved so `"a3yy` works.
                self.prefix = Prefix::None;
                if let KeyCode::Char(c) = key.code {
                    // Vim allows uppercase register letters (A-Z) — they
                    // reference the SAME slot as their lowercase pair
                    // but APPEND on write instead of overwriting.
                    // Downstream yank code checks `c.is_ascii_uppercase()`
                    // to decide append vs overwrite; the validator just
                    // needs to accept them. nvchad-user SEV-2 2026-07-11.
                    let valid =
                        c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '+' || c == '_';
                    if valid {
                        self.pending_register = Some(c);
                    }
                }
                return InputResult::Consumed;
            }
            Prefix::MacroRecordTarget => {
                // `q<reg>` — start recording into <reg> (or stop if already
                // recording). `qq` toggles anonymous (`'@'`). Sets the
                // local `is_recording_macro` mirror so the next `q`
                // routes to "stop" instead of re-entering this prefix.
                self.prefix = Prefix::None;
                if let KeyCode::Char(c) = key.code {
                    // `q:` — open the cmdline-history pane (vim's
                    // command-line window).
                    if c == ':' {
                        return InputResult::App(AppCommand::RunCommand(
                            "view.cmdline_history".into(),
                        ));
                    }
                    if c == 'q' {
                        self.is_recording_macro = true;
                        return InputResult::App(AppCommand::RunCommand("vim.macro_toggle".into()));
                    }
                    if c.is_ascii_lowercase() {
                        self.is_recording_macro = true;
                        return InputResult::App(AppCommand::MacroRecordInto(c));
                    }
                }
                return InputResult::Consumed;
            }
            Prefix::MacroReplayTarget => {
                self.prefix = Prefix::None;
                // Vim `5@a` semantics — replay register `a` five times.
                // Consult the count prefix before clearing it.
                // 2026-06-13 nvchad-user SEV-2 S2-06 fix (`5@a` was a
                // silent no-op; only the count was being thrown away
                // because MacroReplayFrom carried only the register
                // letter).
                let count = self.count.take().unwrap_or(1).max(1);
                if let KeyCode::Char(c) = key.code {
                    if c == '@' {
                        return InputResult::App(AppCommand::MacroReplayFrom { reg: '@', count });
                    }
                    if c.is_ascii_lowercase() {
                        return InputResult::App(AppCommand::MacroReplayFrom { reg: c, count });
                    }
                }
                return InputResult::Consumed;
            }
            Prefix::SurroundDelete => {
                self.reset_pending();
                if let KeyCode::Char(c) = key.code {
                    let valid = matches!(
                        c,
                        '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
                    );
                    if valid {
                        return InputResult::Ops(vec![DeleteSurround(c)]);
                    }
                }
                return InputResult::Consumed;
            }
            Prefix::SurroundAddCharWait => {
                // `ys{motion}<c>` (or `yss<c>`) — char arrives now.
                // The selection ops are already in pending_surround_ops.
                let stash = std::mem::take(&mut self.pending_surround_ops);
                self.reset_pending();
                if let KeyCode::Char(c) = key.code {
                    let valid = matches!(
                        c,
                        '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
                    );
                    if valid {
                        let (open, close) = match c {
                            '"' | '\'' | '`' => (c, c),
                            '(' | ')' => ('(', ')'),
                            '[' | ']' => ('[', ']'),
                            '{' | '}' => ('{', '}'),
                            '<' | '>' => ('<', '>'),
                            _ => unreachable!(),
                        };
                        let mut ops = stash;
                        ops.push(SurroundSelection { open, close });
                        ops.push(SelectClear);
                        return InputResult::Ops(ops);
                    }
                }
                return InputResult::Consumed;
            }
            Prefix::AlignCharWait => {
                // mini.align — selection is already live; the next typed
                // char is the alignment column. Esc cancels (drop selection).
                self.reset_pending();
                if key.code == KeyCode::Esc {
                    return InputResult::Ops(vec![SelectClear]);
                }
                if let KeyCode::Char(c) = key.code {
                    return InputResult::Ops(vec![AlignSelection { on_char: c }, SelectClear]);
                }
                return InputResult::Consumed;
            }
            Prefix::SurroundChange(from) => {
                if from == '\0' {
                    // First key: capture the FROM char.
                    if let KeyCode::Char(c) = key.code {
                        let valid = matches!(
                            c,
                            '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
                        );
                        if valid {
                            self.prefix = Prefix::SurroundChange(c);
                            return InputResult::Consumed;
                        }
                    }
                    self.reset_pending();
                    return InputResult::Consumed;
                }
                // Second key: TO char.
                self.reset_pending();
                if let KeyCode::Char(c) = key.code {
                    let valid = matches!(
                        c,
                        '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
                    );
                    if valid {
                        return InputResult::Ops(vec![ChangeSurround { from, to: c }]);
                    }
                }
                return InputResult::Consumed;
            }
            Prefix::Window => {
                self.reset_pending();
                // vim `Ctrl+W <dir>` — focus the split in that direction.
                // h/j/k/l, arrow keys, plus `w` (cycle), `q` (close), `=`
                // (equalize), `o` (only).
                let cmd = match key.code {
                    KeyCode::Char('h') | KeyCode::Left => "view.focus_left",
                    KeyCode::Char('l') | KeyCode::Right => "view.focus_right",
                    KeyCode::Char('k') | KeyCode::Up => "view.focus_up",
                    KeyCode::Char('j') | KeyCode::Down => "view.focus_down",
                    KeyCode::Char('w') => "view.focus_next_split",
                    KeyCode::Char('q' | 'c') => "view.close_split",
                    KeyCode::Char('s') => "view.split_down",
                    KeyCode::Char('v') => "view.split_right",
                    KeyCode::Char('=') => "view.equalize_splits",
                    KeyCode::Char('o') => "view.close_others",
                    KeyCode::Char('r') => "view.rotate_splits",
                    // `Ctrl+W x` — exchange active leaf with sibling (vim
                    // canonical alias for the same operation). Vim also has
                    // `R` (reverse rotation) — for our 2-pane swap it's the
                    // same op.
                    KeyCode::Char('x') => "view.rotate_splits",
                    KeyCode::Char('R') => "view.rotate_splits",
                    KeyCode::Char('+') => "view.split_grow_height",
                    KeyCode::Char('-') => "view.split_shrink_height",
                    KeyCode::Char('>') => "view.split_grow_width",
                    KeyCode::Char('<') => "view.split_shrink_width",
                    // Move active split to far edge of immediate parent.
                    KeyCode::Char('H') => "view.move_split_left",
                    KeyCode::Char('L') => "view.move_split_right",
                    KeyCode::Char('K') => "view.move_split_up",
                    KeyCode::Char('J') => "view.move_split_down",
                    // `Ctrl+W p` — focus the previously-active leaf
                    // (vim's `:wincmd p`).
                    KeyCode::Char('p') => "buffer.last",
                    // `Ctrl+W f` — split + open the file under the cursor.
                    KeyCode::Char('f') => "view.split_open_file_under_cursor",
                    // `Ctrl+W d` — split + goto definition (vim canonical
                    // for tag-stack split).
                    KeyCode::Char('d') => "view.split_goto_definition",
                    // `Ctrl+W n` — open a fresh empty buffer in a horizontal
                    // split below.
                    KeyCode::Char('n') => "view.split_new_scratch",
                    // `Ctrl+W _` / `Ctrl+W |` — maximize active split's
                    // height / width by setting the enclosing parent's
                    // ratio toward the side that contains us.
                    KeyCode::Char('_') => "view.maximize_height",
                    KeyCode::Char('|') => "view.maximize_width",
                    // `Ctrl+W T` — move the active leaf out into a new
                    // tab page (vim canonical: "make the current window
                    // a new tab page"). When the tab has only one leaf,
                    // it's just a `tab.new` for the active buffer.
                    KeyCode::Char('T') => "view.move_to_new_tab",
                    _ => return InputResult::Consumed,
                };
                return InputResult::App(AppCommand::RunCommand(cmd.into()));
            }
            Prefix::Flash1 => {
                // First char of `s<a><b>`. Esc cancels; otherwise stash.
                if matches!(key.code, KeyCode::Esc) {
                    self.reset_pending();
                    return InputResult::Consumed;
                }
                if let KeyCode::Char(c) = key.code {
                    self.prefix = Prefix::Flash2(c);
                    return InputResult::Consumed;
                }
                self.reset_pending();
                return InputResult::Consumed;
            }
            Prefix::Flash2(a) => {
                // Second char arrives — escalate to the App which computes
                // visible matches, paints labels, and intercepts the next key.
                if matches!(key.code, KeyCode::Esc) {
                    self.reset_pending();
                    return InputResult::Consumed;
                }
                self.reset_pending();
                if let KeyCode::Char(b) = key.code {
                    return InputResult::App(AppCommand::FlashStart(a, b));
                }
                return InputResult::Consumed;
            }
            Prefix::None => {}
        }

        // ── operator-pending (we already saw d / c / y / > / <) ──────
        if let Some(op) = self.op {
            // A count between op and motion (`d3j`, `y5w`, `c2b`)
            // multiplies the motion. Accumulate into `self.count`
            // without touching `self.op` so the next keypress still
            // sees us in operator-pending. nvchad-user round 5
            // SEV-2 2026-07-11 — was falling through to
            // `reset_pending()` and dropping the operator entirely.
            if let KeyCode::Char(c @ '0'..='9') = key.code {
                let count_started = self.count.is_some();
                if !(c == '0' && !count_started) {
                    let d = c as u32 - '0' as u32;
                    self.count = Some(self.count.unwrap_or(0).saturating_mul(10).saturating_add(d));
                    return InputResult::Consumed;
                }
            }
            // A second copy of the operator key ⇒ linewise (`dd`, `yy`, `cc`, `>>`, `<<`).
            let doubled = matches!(
                (op, key.code),
                (PendingOp::Delete, KeyCode::Char('d'))
                    | (PendingOp::Change, KeyCode::Char('c'))
                    | (PendingOp::Yank, KeyCode::Char('y'))
                    | (PendingOp::Indent, KeyCode::Char('>'))
                    | (PendingOp::Outdent, KeyCode::Char('<'))
                    | (PendingOp::Lower, KeyCode::Char('u'))
                    | (PendingOp::Upper, KeyCode::Char('U'))
                    | (PendingOp::ToggleCase, KeyCode::Char('~'))
                    | (PendingOp::SurroundAdd, KeyCode::Char('s'))
                    | (PendingOp::Align, KeyCode::Char('A'))
                    | (PendingOp::Filter, KeyCode::Char('!'))
            );
            let n = self.count1();
            self.reset_pending();
            if key.code == KeyCode::Esc {
                return InputResult::Consumed;
            }
            if doubled {
                return match op {
                    PendingOp::Delete => InputResult::Ops(Self::repeated(DeleteLine, n)),
                    PendingOp::Yank => InputResult::Ops(Self::repeated(YankLine, n)),
                    PendingOp::Change => {
                        self.mode = VimMode::Insert;
                        // clear the line's contents but keep the line, then insert
                        // `MoveLineEnd` extends the selection to cover the
                        // whole line — see note on the case-transform branches
                        // below for why this is needed after the 2026-06-13
                        // SelectLine fix.
                        InputResult::Ops(vec![
                            SelectLine,
                            MoveLineEnd,
                            ReplaceSelection(String::new()),
                        ])
                    }
                    PendingOp::Indent => InputResult::Ops(Self::repeated(Indent, n)),
                    PendingOp::Outdent => InputResult::Ops(Self::repeated(Outdent, n)),
                    PendingOp::Reflow => InputResult::Ops(vec![ReflowParagraph {
                        width: self.text_width,
                    }]),
                    // `guu` / `gUU` / `g~~`. SelectLine sets
                    // `anchor = line_start` but (since the 2026-06-13
                    // V-doesn't-snap-down fix) leaves cursor where it
                    // was — selection = (anchor, cursor) covers only
                    // part of the line. Add `MoveLineEnd` after the
                    // SelectLine so the selection extends through the
                    // last printable char and the whole-line transform
                    // actually fires.
                    PendingOp::Lower => InputResult::Ops(vec![
                        SelectLine,
                        MoveLineEnd,
                        TransformSelectionCase(crate::edit_op::CaseTransform::Lower),
                        SelectClear,
                        // Vim convention: `guu` leaves the cursor at
                        // the START of the NEXT line, ready for a
                        // chord-chain (`guu`/`gUU`/`g~~` per line).
                        MoveDown,
                        MoveLineStart,
                    ]),
                    PendingOp::Upper => InputResult::Ops(vec![
                        SelectLine,
                        MoveLineEnd,
                        TransformSelectionCase(crate::edit_op::CaseTransform::Upper),
                        SelectClear,
                        MoveDown,
                        MoveLineStart,
                    ]),
                    PendingOp::ToggleCase => InputResult::Ops(vec![
                        SelectLine,
                        MoveLineEnd,
                        TransformSelectionCase(crate::edit_op::CaseTransform::Toggle),
                        SelectClear,
                        MoveDown,
                        MoveLineStart,
                    ]),
                    PendingOp::SurroundAdd => {
                        // `yss<c>` ⇒ surround the current line.
                        self.pending_surround_ops = vec![SelectLine];
                        self.prefix = Prefix::SurroundAddCharWait;
                        InputResult::Consumed
                    }
                    PendingOp::Align => {
                        // `gAA` — aligning a single line on a char is a
                        // no-op (only one occurrence in scope). Drop.
                        InputResult::Consumed
                    }
                    PendingOp::Comment => {
                        // `gcgc` (unusual but syntactically valid)
                        // fires ToggleLineComment on the current line.
                        InputResult::Ops(vec![ToggleLineComment])
                    }
                    PendingOp::Filter => {
                        // `!!` — filter the current line (n lines when
                        // count present). nvchad-round-9 SEV-2.
                        InputResult::App(AppCommand::FilterLinesFromCursor { count: n })
                    }
                };
            }
            // operator + `s` ⇒ vim-surround chord:
            // - `ds<c>` deletes a surround pair
            // - `cs<from><to>` changes a surround pair
            // - `ys{motion}<c>` adds a surround around the motion's range
            if matches!(key.code, KeyCode::Char('s')) {
                if matches!(op, PendingOp::Delete) {
                    self.prefix = Prefix::SurroundDelete;
                    return InputResult::Consumed;
                }
                if matches!(op, PendingOp::Change) {
                    self.prefix = Prefix::SurroundChange('\0');
                    return InputResult::Consumed;
                }
                if matches!(op, PendingOp::Yank) {
                    // `ys{motion}<c>` — motion comes next, then char.
                    // Mark with a SurroundAdd op so the motion handler
                    // stashes the select ops + transitions to char-wait.
                    self.op = Some(PendingOp::SurroundAdd);
                    self.pending_surround_ops.clear();
                    return InputResult::Consumed;
                }
            }
            // operator + `i` / `a` → text-object prefix (`diw`, `daw`, …).
            // `reset_pending()` above cleared `self.op`; put it back so the
            // prefix dispatcher knows which operator to apply.
            if matches!(key.code, KeyCode::Char('i')) {
                self.op = Some(op);
                self.prefix = Prefix::TextObjectInner;
                return InputResult::Consumed;
            }
            if matches!(key.code, KeyCode::Char('a')) {
                self.op = Some(op);
                self.prefix = Prefix::TextObjectAround;
                return InputResult::Consumed;
            }
            // operator + `g` → enter the G prefix with the operator
            // preserved. Used for op-pending `gn` / `gN` (vim's "find as
            // text object"). Other g-prefixed motions (`gg`, `gj`, etc.)
            // would also work here in principle but most aren't yet wired
            // to honor the pending op.
            if matches!(key.code, KeyCode::Char('g')) {
                self.op = Some(op);
                self.prefix = Prefix::G;
                return InputResult::Consumed;
            }
            // operator + f / F / t / T → find-char with operator applied.
            if let KeyCode::Char(c @ ('f' | 'F' | 't' | 'T')) = key.code {
                self.op = Some(op);
                self.prefix = match c {
                    'f' => Prefix::FindChar(true, false),
                    'F' => Prefix::FindChar(false, false),
                    't' => Prefix::FindChar(true, true),
                    _ => Prefix::FindChar(false, true),
                };
                return InputResult::Consumed;
            }
            // operator + word for delete/change has a tighter form (`dw`, `cw`).
            // nvchad-user 2026-06-28 SEV-2: vim's `:help cw` says
            // `cw` is identical to `ce` (and `cW` to `cE`) — change
            // word EXCLUDES the trailing whitespace. Swap the motion
            // before building the op chain.
            let effective_code = if matches!(op, PendingOp::Change) {
                match key.code {
                    KeyCode::Char('w') => KeyCode::Char('e'),
                    KeyCode::Char('W') => KeyCode::Char('E'),
                    other => other,
                }
            } else {
                key.code
            };
            // nvchad-user SEV-2 2026-07-11: vertical motion under an
            // operator is LINEWISE per vim convention. `dj` from
            // line 5 deletes lines 5 AND 6; `dk` deletes 4 AND 5;
            // `d3j` deletes 4 lines (cursor + 3 below). The generic
            // SelectStart + MoveDown + DeleteSelection path made a
            // charwise selection at cursor column, which for equal-
            // length lines silently produced "delete cursor line
            // only". Convert to N × DeleteLine (with a preceding
            // MoveUp × n for k-direction) so the operation is
            // genuinely linewise. Handles d/y/c/>/< over j/k/+/-/Enter.
            let vertical_dir: Option<i32> = match effective_code {
                KeyCode::Char('j') | KeyCode::Down => Some(1),
                KeyCode::Char('k') | KeyCode::Up => Some(-1),
                KeyCode::Char('+') | KeyCode::Enter => Some(1),
                KeyCode::Char('-') => Some(-1),
                _ => None,
            };
            if let Some(dir) = vertical_dir {
                let count = n;
                let total_lines = count + 1;
                let mut ops: Vec<EditOp> = Vec::new();
                if dir < 0 {
                    // Move up to the start of the affected block.
                    for _ in 0..count {
                        ops.push(MoveUp);
                    }
                }
                // Special-case yank — N × YankLine overwrites the
                // clipboard each iteration, silently reducing `y{N}j`
                // to `yy`. Use `YankLinesCount(N)` which does one
                // multi-line linewise capture. nvchad round 6 SEV-2
                // 2026-07-11 regression fix.
                if matches!(op, PendingOp::Yank) {
                    ops.push(YankLinesCount(total_lines));
                    self.reset_pending();
                    return InputResult::Ops(ops);
                }
                // `!{motion}` filter — walk the motion's line range
                // to fire an AppCommand that opens the shell prompt.
                // Line count captured before we reset. nvchad-round-9
                // SEV-2 2026-07-11.
                if matches!(op, PendingOp::Filter) {
                    self.reset_pending();
                    return InputResult::App(AppCommand::FilterLinesFromCursor {
                        count: total_lines,
                    });
                }
                let linewise_op: Option<EditOp> = match op {
                    PendingOp::Delete => Some(DeleteLine),
                    PendingOp::Change => Some(DeleteLine),
                    PendingOp::Indent => Some(Indent),
                    PendingOp::Outdent => Some(Outdent),
                    _ => None,
                };
                if let Some(line_op) = linewise_op {
                    for _ in 0..total_lines {
                        ops.push(line_op.clone());
                    }
                    if matches!(op, PendingOp::Change) {
                        // c<vertical> ends in Insert mode on a fresh
                        // line at the cursor position (vim
                        // convention: opens a blank line for typing).
                        ops.push(InsertNewline);
                        ops.push(MoveUp);
                        self.mode = VimMode::Insert;
                    }
                    self.reset_pending();
                    return InputResult::Ops(ops);
                }
                // Unsupported op falls through to the generic path.
            }
            if let Some(m) = Self::motion(effective_code) {
                let mut ops = vec![SelectStart];
                if n > 1 {
                    ops.push(Repeat(n, Box::new(m)));
                } else {
                    ops.push(m);
                }
                // nvchad-user SEV-2 (continued): `:help inclusive` —
                // `e` / `E` / `$` are INCLUSIVE motions. Operators
                // include the destination character. mnml's
                // SelectStart+motion+DeleteSelection deletes
                // [anchor, cursor) — exclusive at the cursor end.
                // For inclusive motions, push an extra MoveRight so
                // the destination char IS included.
                let inclusive = matches!(
                    effective_code,
                    KeyCode::Char('e') | KeyCode::Char('E') | KeyCode::Char('$') | KeyCode::End
                );
                if inclusive {
                    ops.push(MoveRight);
                }
                match op {
                    PendingOp::Delete => ops.push(DeleteSelection),
                    PendingOp::Yank => {
                        ops.push(YankSelection);
                        ops.push(SelectClear);
                    }
                    PendingOp::Change => {
                        ops.push(ReplaceSelection(String::new()));
                        self.mode = VimMode::Insert;
                    }
                    PendingOp::Indent => {
                        ops.push(Indent);
                        ops.push(SelectClear);
                    }
                    PendingOp::Outdent => {
                        ops.push(Outdent);
                        ops.push(SelectClear);
                    }
                    PendingOp::Reflow => {
                        // `gqw` / `gqj` etc. don't have a span-aware reflow;
                        // fall back to the cursor's paragraph.
                        ops.clear();
                        ops.push(ReflowParagraph {
                            width: self.text_width,
                        });
                    }
                    PendingOp::Lower => {
                        ops.push(TransformSelectionCase(crate::edit_op::CaseTransform::Lower));
                        ops.push(SelectClear);
                    }
                    PendingOp::Upper => {
                        ops.push(TransformSelectionCase(crate::edit_op::CaseTransform::Upper));
                        ops.push(SelectClear);
                    }
                    PendingOp::ToggleCase => {
                        ops.push(TransformSelectionCase(
                            crate::edit_op::CaseTransform::Toggle,
                        ));
                        ops.push(SelectClear);
                    }
                    PendingOp::SurroundAdd => {
                        // `ys{motion}` ⇒ stash select ops, await char.
                        self.pending_surround_ops = ops.clone();
                        self.prefix = Prefix::SurroundAddCharWait;
                        return InputResult::Consumed;
                    }
                    PendingOp::Align => {
                        // `gA{motion}` ⇒ leave the selection live, await
                        // the alignment char. `ops` is `[SelectStart,
                        // motion]` — exactly what we need.
                        self.prefix = Prefix::AlignCharWait;
                        return InputResult::Ops(ops);
                    }
                    PendingOp::Comment => {
                        ops.push(ToggleLineComment);
                        ops.push(SelectClear);
                    }
                    PendingOp::Filter => {
                        // Charwise motions don't map cleanly to a line
                        // filter. Callers should use `!<vertical>`
                        // (handled in the linewise branch above).
                        return InputResult::Consumed;
                    }
                }
                return InputResult::Ops(ops);
            }
            // Not a motion ⇒ abort the operator.
            return InputResult::Consumed;
        }

        // ── count prefix (`0` is a motion, not a count, when no count yet) ──
        if let KeyCode::Char(c @ '0'..='9') = key.code {
            if c == '0' && self.count.is_none() {
                // fallthrough to motion handling below
            } else {
                let d = c as u32 - '0' as u32;
                self.count = Some(self.count.unwrap_or(0).saturating_mul(10).saturating_add(d));
                return InputResult::Consumed;
            }
        }

        // ── `{N}G` → go to line N ────────────────────────────────────
        if key.code == KeyCode::Char('G')
            && let Some(n) = self.count
        {
            self.reset_pending();
            return InputResult::Ops(vec![MoveToLine(n as usize)]);
        }

        // ── plain motions ────────────────────────────────────────────
        // Skip when ctrl is held — chords like `Ctrl+W` / `Ctrl+H` would
        // otherwise misfire as `w` / `h` motions before the modifier arms
        // below get a chance.
        if !ctrl && let Some(m) = Self::motion(key.code) {
            let n = self.count1();
            self.reset_pending();
            return InputResult::Ops(Self::repeated(m, n));
        }

        let n = self.count1();
        match key.code {
            // vim `Ctrl+L` — force a screen redraw (vim canonical).
            KeyCode::Char('l') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("view.redraw".into()))
            }
            // vim `Ctrl+G` — toast file info (vim canonical).
            KeyCode::Char('g') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("editor.file_info".into()))
            }
            // vim `Ctrl+]` — jump to definition (vim's tag-follow chord;
            // mnml aliases to LSP `goto_definition`).
            KeyCode::Char(']') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("lsp.goto_definition".into()))
            }
            // vim `Ctrl+T` — jump back from tag (mnml aliases to nav.back).
            KeyCode::Char('t') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("nav.back".into()))
            }
            // vim `Ctrl+H` in NORMAL is equivalent to `h` (move left
            // one char). nvchad-user 2026-06-28 — was a no-op
            // because handle_normal's motion lookup gates on `!ctrl`.
            KeyCode::Char('h') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![EditOp::MoveLeft])
            }
            // vim `K` — keyword help / docs for word under cursor (LSP hover).
            KeyCode::Char('K') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("lsp.hover".into()))
            }
            // vim `H` / `M` / `L` — move cursor to top / middle / bottom of
            // the visible viewport (scroll stays put).
            KeyCode::Char('H') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("view.move_cursor_view_top".into()))
            }
            KeyCode::Char('M') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand(
                    "view.move_cursor_view_middle".into(),
                ))
            }
            KeyCode::Char('L') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand(
                    "view.move_cursor_view_bottom".into(),
                ))
            }
            // vim `Ctrl+I` — jumplist forward (alias of nav.forward).
            // Must come BEFORE the bare `i` arm.
            KeyCode::Char('i') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("nav.forward".into()))
            }
            // enter Insert in various places
            KeyCode::Char('i') => {
                self.enter_insert();
                InputResult::Consumed
            }
            KeyCode::Char('I') => {
                self.enter_insert();
                InputResult::Ops(vec![MoveLineFirstNonWs])
            }
            // vim `Ctrl+A` — increment the next number on the cursor's line.
            // Counts apply: `5<C-a>` adds 5. Must come before the bare `a`
            // arm (which would otherwise swallow Ctrl+a too).
            KeyCode::Char('a') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![ChangeNumberAtCursor { delta: n as i64 }])
            }
            // vim `Ctrl+E` / `Ctrl+Y` — scroll the buffer one line down / up
            // without moving the cursor. Counts repeat (`5<C-e>` scrolls 5).
            KeyCode::Char('e') if ctrl => {
                self.reset_pending();
                let times = n.max(1);
                let cmd = if times == 1 {
                    "view.scroll_buffer_down".to_string()
                } else {
                    // Repeat by re-routing through RunCommand isn't ergonomic;
                    // for now `[count]<C-e>` falls back to single-line. Future
                    // work: pass count through via AppCommand variant.
                    "view.scroll_buffer_down".to_string()
                };
                InputResult::App(AppCommand::RunCommand(cmd))
            }
            KeyCode::Char('y') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("view.scroll_buffer_up".into()))
            }
            KeyCode::Char('a') => {
                self.enter_insert();
                InputResult::Ops(vec![MoveRight])
            }
            KeyCode::Char('A') => {
                self.enter_insert();
                InputResult::Ops(vec![MoveLineEnd])
            }
            // vim `Ctrl+O` — jumplist back (alias of nav.back). Must come
            // BEFORE the bare `o` arm.
            KeyCode::Char('o') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("nav.back".into()))
            }
            KeyCode::Char('o') => {
                let n = self.count1();
                self.reset_pending();
                if n > 1 {
                    // <count>o — App opens the first line, drives Insert,
                    // and on Esc replicates the typed text on the rest.
                    InputResult::App(AppCommand::RepeatInsertStart {
                        count: n,
                        above: false,
                    })
                } else {
                    self.enter_insert();
                    InputResult::Ops(vec![InsertNewlineBelow])
                }
            }
            KeyCode::Char('O') => {
                let n = self.count1();
                self.reset_pending();
                if n > 1 {
                    InputResult::App(AppCommand::RepeatInsertStart {
                        count: n,
                        above: true,
                    })
                } else {
                    self.enter_insert();
                    InputResult::Ops(vec![InsertNewlineAbove])
                }
            }
            // single-char edits
            // `Ctrl+X` — decrement the next number on the cursor's line.
            // Counts apply: `5<C-x>` subtracts 5.
            KeyCode::Char('x') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![ChangeNumberAtCursor { delta: -(n as i64) }])
            }
            KeyCode::Char('x') => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(DeleteForward, n))
            }
            KeyCode::Char('X') => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(Backspace, n))
            }
            KeyCode::Char('D') => {
                self.reset_pending();
                InputResult::Ops(vec![DeleteToLineEnd])
            }
            KeyCode::Char('C') => {
                self.enter_insert();
                InputResult::Ops(vec![DeleteToLineEnd])
            }
            // flash/leap-style `s<a><b>` 2-char jump. mnml takes vim's
            // rarely-used substitute chord (`s`) and gives it to flash;
            // vim's substitute is still reachable via `cl`. The handler
            // accumulates two chars, then escalates to `AppCommand::FlashStart`.
            KeyCode::Char('s') => {
                self.reset_pending();
                self.prefix = Prefix::Flash1;
                InputResult::Consumed
            }
            KeyCode::Char('S') => {
                self.enter_insert();
                InputResult::Ops(vec![SelectLine, ReplaceSelection(String::new())])
            }
            KeyCode::Char('r') if ctrl => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(Redo, n))
            }
            // Note: terminals send Ctrl+I as Tab — we still wire both forms
            // so a terminal that distinguishes them (Kitty protocol) gets
            // the canonical chord, and Tab in normal mode (which has no
            // built-in meaning) does the right thing on the rest. Ctrl+O is
            // also wired for the canonical chord.
            KeyCode::Tab => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("nav.forward".into()))
            }
            // vim `Ctrl+W` — split/window prefix. Standard mode keeps
            // `Ctrl+W` bound to `buffer.close`; in vim it becomes a chord
            // ending in a direction (h/j/k/l) or `w`/`q`.
            KeyCode::Char('w') if ctrl => {
                self.prefix = Prefix::Window;
                InputResult::Consumed
            }
            // vim `q` — recording control:
            // - Idle  ⇒ enter `MacroRecordTarget` prefix; next key picks
            //   the register letter (or `q` for anonymous, mnml convenience).
            // - Recording ⇒ stop (route straight to `vim.macro_toggle`,
            //   which is state-aware: recording ⇒ stop).
            KeyCode::Char('q') => {
                if self.is_recording_macro {
                    self.is_recording_macro = false;
                    InputResult::App(AppCommand::RunCommand("vim.macro_toggle".into()))
                } else {
                    self.prefix = Prefix::MacroRecordTarget;
                    InputResult::Consumed
                }
            }
            KeyCode::Char('@') => {
                self.prefix = Prefix::MacroReplayTarget;
                InputResult::Consumed
            }
            // vim `Ctrl+^` / `Ctrl+6` — switch to the alternate (most
            // recently active) buffer. `^` and `6` are the same physical
            // key on US layouts; vim accepts both.
            KeyCode::Char('^') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("buffer.last".into()))
            }
            KeyCode::Char('6') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("buffer.last".into()))
            }
            // vim `;` / `,` — repeat last `f`/`F`/`t`/`T` in same /
            // opposite direction. No-op until the user has done at least
            // one find-char.
            KeyCode::Char(';') => {
                self.reset_pending();
                if let Some((c, forward, before)) = self.last_find_char {
                    InputResult::Ops(vec![FindCharOnLine {
                        ch: c,
                        forward,
                        before,
                        inclusive: false,
                    }])
                } else {
                    InputResult::Consumed
                }
            }
            KeyCode::Char(',') => {
                self.reset_pending();
                if let Some((c, forward, before)) = self.last_find_char {
                    InputResult::Ops(vec![FindCharOnLine {
                        ch: c,
                        forward: !forward,
                        before,
                        inclusive: false,
                    }])
                } else {
                    InputResult::Consumed
                }
            }
            // `[` / `]` — bracket prefix for jump-to-prev / jump-to-next
            // chords (`[c` / `]c` git hunks; `[d` / `]d` diagnostics).
            // nvchad-user SEV-2 2026-06-28: only consume the bare
            // bracket, not Ctrl+Shift+[ / Ctrl+Shift+] — those are
            // editor.toggle_fold / editor.unfold_all chords that
            // need to reach the chord-chain layer or fall through
            // to the global keymap.
            KeyCode::Char('[') if !ctrl => {
                self.prefix = Prefix::BracketOpen;
                InputResult::Consumed
            }
            KeyCode::Char(']') if !ctrl => {
                self.prefix = Prefix::BracketClose;
                InputResult::Consumed
            }
            // `"` — named-register prefix. Next key picks the register
            // (`a`-`z` named, `0` last-yank, `+` system, `_` blackhole).
            KeyCode::Char('"') => {
                self.prefix = Prefix::Register;
                InputResult::Consumed
            }
            // vim `~` — toggle case of char under cursor + advance.
            // `[count]~` repeats: `5~` toggles 5 chars.
            KeyCode::Char('~') => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(ToggleCaseChar, n))
            }
            // vim `.` — repeat the last change. `3.` runs it 3 times
            // (count REPLACES the count of the original op per
            // `:h .`). Read the count BEFORE reset_pending so a bare
            // `.` (no count typed) gets n=1.
            KeyCode::Char('.') => {
                let n = self.count1();
                self.reset_pending();
                InputResult::App(AppCommand::DotRepeat(n))
            }
            // vim `&` — repeat the last :s on the cursor's current line.
            KeyCode::Char('&') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand(
                    "editor.repeat_last_substitute".into(),
                ))
            }
            // vim half-page scroll: Ctrl+D (down) / Ctrl+U (up).
            KeyCode::Char('d') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![HalfPageDown])
            }
            KeyCode::Char('u') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![HalfPageUp])
            }
            // vim full-page scroll: Ctrl+F (forward) / Ctrl+B (back).
            // nvchad-round-10 SEV-2 follow-up 2026-07-12 — Ctrl+F is
            // now vim-owned in Normal mode (was falling to find.find);
            // this restores the canonical page-down. Ctrl+B stays
            // bound globally (sidebar) so page-up via Ctrl+B skips
            // this arm — use the PageUp key or `Ctrl+U` (half-page)
            // in vim mode.
            KeyCode::Char('f') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![PageDown])
            }
            KeyCode::Char('r') => {
                self.prefix = Prefix::Replace;
                InputResult::Consumed
            }
            // vim `R` — enter Replace mode (typed chars overwrite and
            // advance; Esc returns to Normal). Emit ReplaceSessionBegin so
            // the editor's replace-stack starts empty.
            KeyCode::Char('R') => {
                self.mode = VimMode::Replace;
                self.reset_pending();
                InputResult::Ops(vec![ReplaceSessionBegin])
            }
            KeyCode::Char('J') => {
                let n = self.count1();
                self.reset_pending();
                // vim `J` joins the next line in (with a single space, leading
                // whitespace eaten). `[count]J` joins `count - 1` more lines
                // — `3J` brings two lines up. `JoinLines` is a single op; we
                // repeat it to get the count right.
                let times = n.max(1).saturating_sub(1).max(1);
                InputResult::Ops(Self::repeated(JoinLines { keep_space: true }, times))
            }
            KeyCode::Char('Y') => {
                // vim `Y` — yank the current line (synonym for `yy`).
                self.reset_pending();
                InputResult::Ops(vec![YankLine])
            }
            // paste / undo / redo
            KeyCode::Char('p') => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(PasteAfter, n))
            }
            KeyCode::Char('P') => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(PasteBefore, n))
            }
            KeyCode::Char('u') => {
                self.reset_pending();
                InputResult::Ops(Self::repeated(Undo, n))
            }
            // operators
            KeyCode::Char('d') => {
                self.op = Some(PendingOp::Delete);
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            KeyCode::Char('c') => {
                self.op = Some(PendingOp::Change);
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            KeyCode::Char('y') => {
                self.op = Some(PendingOp::Yank);
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            KeyCode::Char('>') => {
                self.op = Some(PendingOp::Indent);
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            KeyCode::Char('<') => {
                self.op = Some(PendingOp::Outdent);
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            // `!{motion}` — filter operator. Wait for motion, then
            // prompt for the shell command. nvchad-round-9 SEV-2
            // 2026-07-11.
            KeyCode::Char('!') => {
                self.op = Some(PendingOp::Filter);
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            // vim `Ctrl+G` — toast file info. Standard mode keeps it
            // bound to `editor.goto_line` (the keymap resolver handles
            // that); the vim handler intercepts here first.
            KeyCode::Char('g') if ctrl => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("editor.file_info".into()))
            }
            // prefixes
            KeyCode::Char('g') => {
                self.prefix = Prefix::G;
                self.count = if n > 1 { Some(n) } else { None };
                InputResult::Consumed
            }
            KeyCode::Char('Z') => {
                self.prefix = Prefix::Z;
                InputResult::Consumed
            }
            // `z` (lowercase) — vim's fold prefix. `za` toggles, `zR` unfolds all.
            KeyCode::Char('z') => {
                self.prefix = Prefix::ZFold;
                InputResult::Consumed
            }
            // `<count>|` — jump to character column N on the current line
            // (1-based, vim canonical). Bare `|` (no count) ⇒ column 1.
            KeyCode::Char('|') => {
                let n = self.count1();
                self.reset_pending();
                InputResult::Ops(vec![EditOp::MoveToCol(n as usize)])
            }
            // % — `<count>%` jumps to that PERCENTAGE of the buffer (vim
            // canonical, e.g. `50%` ⇒ mid-buffer). Bare `%` (no count) falls
            // through to bracket-match.
            KeyCode::Char('%') => {
                let pct = self.count;
                self.reset_pending();
                if let Some(pct) = pct {
                    // line_count from ctx; clamp pct into [1, 100].
                    let pct = (pct as usize).clamp(1, 100);
                    let lc = ctx.line_count.max(1);
                    // vim formula: ((count * lc) + 99) / 100, then clamp.
                    let target = (pct * lc).div_ceil(100);
                    let target = target.clamp(1, lc);
                    InputResult::Ops(vec![EditOp::MoveToLine(target)])
                } else {
                    InputResult::App(AppCommand::RunCommand("editor.bracket_match".into()))
                }
            }
            // `*` / `#` — find next / prev occurrence of the word under the
            // cursor. Sets the buffer's find state and jumps.
            KeyCode::Char('*') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("find.word_forward".into()))
            }
            KeyCode::Char('#') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("find.word_backward".into()))
            }
            // vim `n` / `N` — step through the active find's matches.
            // `n` = next, `N` = previous (vim convention; both relative to
            // search direction, but mnml's find is direction-agnostic so
            // we map straight to find.next / find.prev).
            KeyCode::Char('n') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("find.next".into()))
            }
            KeyCode::Char('N') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("find.prev".into()))
            }
            // f / F / t / T — find char on the cursor's line. The next char
            // typed is the target; the prefix dispatcher emits the EditOp.
            KeyCode::Char('f') => {
                self.prefix = Prefix::FindChar(true, false);
                InputResult::Consumed
            }
            KeyCode::Char('F') => {
                self.prefix = Prefix::FindChar(false, false);
                InputResult::Consumed
            }
            KeyCode::Char('t') => {
                self.prefix = Prefix::FindChar(true, true);
                InputResult::Consumed
            }
            KeyCode::Char('T') => {
                self.prefix = Prefix::FindChar(false, true);
                InputResult::Consumed
            }
            // marks
            KeyCode::Char('m') => {
                self.prefix = Prefix::MarkSet;
                InputResult::Consumed
            }
            KeyCode::Char('\'') => {
                self.prefix = Prefix::MarkJumpLine;
                InputResult::Consumed
            }
            KeyCode::Char('`') => {
                self.prefix = Prefix::MarkJumpExact;
                InputResult::Consumed
            }
            // visual modes — Ctrl+V (block) MUST come before bare v.
            KeyCode::Char('v') if ctrl => {
                self.mode = VimMode::VisualBlock;
                self.reset_pending();
                InputResult::Ops(vec![BlockSelectStart])
            }
            KeyCode::Char('v') => {
                self.mode = VimMode::Visual;
                self.reset_pending();
                InputResult::Ops(vec![SelectStart])
            }
            KeyCode::Char('V') => {
                self.mode = VimMode::VisualLine;
                self.reset_pending();
                InputResult::Ops(vec![SelectLine])
            }
            // leader: space opens the which-key popup
            KeyCode::Char(' ') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("whichkey.leader".into()))
            }
            // command line
            KeyCode::Char(':') => {
                self.reset_pending();
                self.open_cmdline();
                InputResult::Consumed
            }
            KeyCode::Char('/') if ctrl => {
                self.reset_pending();
                InputResult::Ops(vec![ToggleLineComment])
            }
            // vim `/` — open the find prompt (forward search).
            KeyCode::Char('/') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("find.find".into()))
            }
            // vim `?` — open the find prompt with reverse-search direction
            // (the first accept jumps to the closest match BEFORE the cursor).
            KeyCode::Char('?') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("find.find_backward".into()))
            }
            KeyCode::Esc => {
                self.reset_pending();
                // Drop any extra multi-cursors on Esc — vim's "back to one
                // cursor" gesture. Cheap when there are none.
                InputResult::Ops(vec![EditOp::ClearExtraCursors])
            }
            _ => {
                self.reset_pending();
                InputResult::Ignored
            }
        }
    }

    fn handle_visual(&mut self, key: KeyEvent, _ctx: &EditCtx) -> InputResult {
        use EditOp::*;
        let linewise = self.mode == VimMode::VisualLine;

        // ── multi-key prefix arms that visual mode shares with normal ──
        // Only a small subset matters in Visual today; expand as needed.
        match self.prefix {
            Prefix::G => {
                self.reset_pending();
                return match key.code {
                    // `gA<char>` in Visual — the selection is already
                    // live; the next char is the alignment column.
                    KeyCode::Char('A') => {
                        self.op = Some(PendingOp::Align);
                        self.prefix = Prefix::AlignCharWait;
                        InputResult::Consumed
                    }
                    // `gv` in Visual is a no-op (selection already live).
                    KeyCode::Char('v') => InputResult::Consumed,
                    // Other `g`-prefixes fall through silently.
                    _ => InputResult::Consumed,
                };
            }
            Prefix::AlignCharWait => {
                self.reset_pending();
                if key.code == KeyCode::Esc {
                    self.enter_normal();
                    return InputResult::Ops(vec![SelectClear]);
                }
                if let KeyCode::Char(c) = key.code {
                    self.enter_normal();
                    return InputResult::Ops(vec![AlignSelection { on_char: c }, SelectClear]);
                }
                return InputResult::Consumed;
            }
            // Visual `z*` prefix — `zf` folds the selection, other
            // `z*` chords delegate to their normal-mode meaning
            // (they all end visual mode). nvchad-round-8 SEV-3
            // 2026-07-11.
            Prefix::ZFold => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char('f') => {
                        self.enter_normal();
                        InputResult::App(AppCommand::RunCommand("editor.fold_selection".into()))
                    }
                    KeyCode::Char('c' | 'a' | 'A' | 'C') => {
                        self.enter_normal();
                        InputResult::App(AppCommand::RunCommand("editor.toggle_fold".into()))
                    }
                    KeyCode::Char('M') => {
                        self.enter_normal();
                        InputResult::App(AppCommand::RunCommand("editor.fold_all_brackets".into()))
                    }
                    KeyCode::Char('R' | 'E') => {
                        self.enter_normal();
                        InputResult::App(AppCommand::RunCommand("editor.unfold_all".into()))
                    }
                    _ => InputResult::Consumed,
                };
            }
            // Visual text objects — `viw`, `viW`, `vip`, `vi(`, `va[`,
            // `vi"`, `vit`, etc. Selection stays live; the op just
            // sets anchor+cursor to the object's range. Stay in
            // Visual mode after. nvchad-round-8 SEV-2 2026-07-11.
            Prefix::TextObjectInner | Prefix::TextObjectAround => {
                let around = matches!(self.prefix, Prefix::TextObjectAround);
                self.reset_pending();
                let select_op = match key.code {
                    KeyCode::Char('w') => {
                        if around {
                            SelectAroundWord
                        } else {
                            SelectInnerWord
                        }
                    }
                    KeyCode::Char('W') => {
                        if around {
                            SelectAroundBigWord
                        } else {
                            SelectInnerBigWord
                        }
                    }
                    KeyCode::Char(q @ ('"' | '\'' | '`')) => {
                        if around {
                            SelectAroundQuote(q)
                        } else {
                            SelectInnerQuote(q)
                        }
                    }
                    KeyCode::Char('q') => {
                        if around {
                            SelectAroundSmartQuote
                        } else {
                            SelectInnerSmartQuote
                        }
                    }
                    KeyCode::Char('p') => {
                        if around {
                            SelectAroundParagraph
                        } else {
                            SelectInnerParagraph
                        }
                    }
                    KeyCode::Char('t') => {
                        if around {
                            SelectAroundTag
                        } else {
                            SelectInnerTag
                        }
                    }
                    // Tree-sitter text objects — parity with the
                    // operator-pending dispatch (line 1579+). Nvchad
                    // users hit `vif` / `vac` / `via` constantly.
                    // nvchad-round-9 SEV-2 2026-07-11.
                    KeyCode::Char('f') => {
                        if around {
                            SelectAroundFunction
                        } else {
                            SelectInnerFunction
                        }
                    }
                    KeyCode::Char('c') => {
                        if around {
                            SelectAroundClass
                        } else {
                            SelectInnerClass
                        }
                    }
                    KeyCode::Char('a') => {
                        if around {
                            SelectAroundArgument
                        } else {
                            SelectInnerArgument
                        }
                    }
                    KeyCode::Char('i') if around => SelectAroundIndentBlock,
                    KeyCode::Char('i') => SelectInnerIndentBlock,
                    KeyCode::Char('I') if around => SelectOuterIndentBlock,
                    KeyCode::Char(c @ ('(' | ')' | '[' | ']' | '{' | '}' | '<' | '>')) => {
                        let open = match c {
                            ')' => '(',
                            ']' => '[',
                            '}' => '{',
                            '>' => '<',
                            other => other,
                        };
                        if around {
                            SelectAroundBracket(open)
                        } else {
                            SelectInnerBracket(open)
                        }
                    }
                    _ => return InputResult::Consumed,
                };
                return InputResult::Ops(vec![select_op]);
            }
            _ => {}
        }

        // count prefix inside visual
        if let KeyCode::Char(c @ '1'..='9') = key.code {
            let d = c as u32 - '0' as u32;
            self.count = Some(self.count.unwrap_or(0).saturating_mul(10).saturating_add(d));
            return InputResult::Consumed;
        }
        if let KeyCode::Char(c @ '0'..='9') = key.code
            && self.count.is_some()
        {
            let d = c as u32 - '0' as u32;
            self.count = Some(self.count.unwrap().saturating_mul(10).saturating_add(d));
            return InputResult::Consumed;
        }

        if let Some(m) = Self::motion(key.code) {
            let n = self.count1();
            self.count = None;
            return InputResult::Ops(Self::repeated(m, n));
        }

        self.count = None;
        match key.code {
            KeyCode::Esc => {
                self.enter_normal();
                InputResult::Ops(vec![SelectClear])
            }
            KeyCode::Char('v') => {
                if linewise {
                    self.mode = VimMode::Visual;
                    InputResult::Consumed
                } else {
                    self.enter_normal();
                    InputResult::Ops(vec![SelectClear])
                }
            }
            KeyCode::Char('V') => {
                if linewise {
                    self.enter_normal();
                    InputResult::Ops(vec![SelectClear])
                } else {
                    self.mode = VimMode::VisualLine;
                    InputResult::Ops(vec![SelectLine])
                }
            }
            // Visual text-object prefix — `i`/`a` in Visual opens the
            // TextObject dispatch (`viw`, `vip`, `vi(`, etc.). Handled
            // in the top-of-fn prefix arm on the next key. Vim canonical.
            // nvchad-round-8 SEV-2 2026-07-11.
            KeyCode::Char('i') => {
                self.prefix = Prefix::TextObjectInner;
                InputResult::Consumed
            }
            KeyCode::Char('a') => {
                self.prefix = Prefix::TextObjectAround;
                InputResult::Consumed
            }
            // Visual `z` — enter ZFold prefix (matches normal mode).
            // Notably `zf` here folds the selection, `zc`/`zo` toggle,
            // etc. nvchad-round-8 SEV-3 2026-07-11.
            KeyCode::Char('z') => {
                self.prefix = Prefix::ZFold;
                InputResult::Consumed
            }
            KeyCode::Char('d') | KeyCode::Char('x') => {
                self.enter_normal();
                InputResult::Ops(vec![DeleteSelection])
            }
            KeyCode::Char('c') | KeyCode::Char('s') => {
                self.mode = VimMode::Insert;
                self.reset_pending();
                InputResult::Ops(vec![ReplaceSelection(String::new())])
            }
            KeyCode::Char('y') => {
                self.enter_normal();
                // In VisualLine mode the cursor sits at col 0 of the
                // last-touched line (V→down→down lands at start of
                // the third row). YankSelection saves
                // `last_selection = (anchor, cursor)` — and
                // `last_selection_rows`'s rollback logic
                // (`if c2 == 0 && byte[hi-1] == '\n' { r2 -= 1 }`)
                // would clip the last row off the `'<,'>` mark range.
                // Push cursor to the END of the current line BEFORE
                // YankSelection so the saved selection ends mid-row;
                // last_selection_rows's rollback skips it.
                if linewise {
                    InputResult::Ops(vec![MoveLineEnd, YankSelection, SelectClear])
                } else {
                    InputResult::Ops(vec![YankSelection, SelectClear])
                }
            }
            KeyCode::Char('o') => {
                // Swap which end of the selection the cursor sits on.
                InputResult::Ops(vec![SwapAnchorCursor])
            }
            KeyCode::Char('>') => {
                self.enter_normal();
                InputResult::Ops(vec![Indent, SelectClear])
            }
            KeyCode::Char('<') => {
                self.enter_normal();
                InputResult::Ops(vec![Outdent, SelectClear])
            }
            KeyCode::Char('g') => {
                self.prefix = Prefix::G;
                InputResult::Consumed
            }
            // vim visual case ops — `u` lowercase, `U` uppercase, `~` toggle.
            // The transform replaces the selection in place; the handler
            // returns to Normal mode (vim convention).
            KeyCode::Char('u') => {
                self.enter_normal();
                InputResult::Ops(vec![
                    TransformSelectionCase(crate::edit_op::CaseTransform::Lower),
                    SelectClear,
                ])
            }
            KeyCode::Char('U') => {
                self.enter_normal();
                InputResult::Ops(vec![
                    TransformSelectionCase(crate::edit_op::CaseTransform::Upper),
                    SelectClear,
                ])
            }
            KeyCode::Char('~') => {
                self.enter_normal();
                InputResult::Ops(vec![
                    TransformSelectionCase(crate::edit_op::CaseTransform::Toggle),
                    SelectClear,
                ])
            }
            // vim visual `*` / `#` — search for the literally-selected text
            // (preserves spaces / punctuation; no word-boundary check, unlike
            // normal-mode `*`).
            KeyCode::Char('*') => {
                self.enter_normal();
                InputResult::App(AppCommand::RunCommand("find.selection_forward".into()))
            }
            KeyCode::Char('#') => {
                self.enter_normal();
                InputResult::App(AppCommand::RunCommand("find.selection_backward".into()))
            }
            KeyCode::Char(':') => {
                // Save the live selection to `'<`/`'>` before the cmdline
                // parser resolves the pre-filled `'<,'>`.
                self.open_cmdline_visual_range();
                InputResult::Ops(vec![RememberSelection])
            }
            // Visual `S<c>` — vim-surround "wrap selection with <c>". The
            // selection is already live, so no prefix ops are needed; we
            // just wait for the surround char and then emit
            // [SurroundSelection, SelectClear]. Char-wait flow reused.
            KeyCode::Char('S') => {
                self.pending_surround_ops.clear();
                self.prefix = Prefix::SurroundAddCharWait;
                // Drop the user back to Normal once the surround completes
                // (vim convention). The SurroundAddCharWait arm does that
                // implicitly via reset_pending.
                self.mode = VimMode::Normal;
                InputResult::Consumed
            }
            _ => InputResult::Consumed,
        }
    }

    fn handle_visual_block(&mut self, key: KeyEvent, _ctx: &EditCtx) -> InputResult {
        use EditOp::*;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        // V-BLOCK `r<c>` prefix — next key is the fill char. Dispatched
        // here (not the normal-mode prefix arm) because pressing `r` in
        // V-BLOCK doesn't enter Normal mode; the follow-up char stays
        // in `handle_visual_block`. nvchad-round-8 regression fix
        // 2026-07-11 — round-7 wired the prefix but not this dispatch.
        if matches!(self.prefix, Prefix::BlockReplaceChar) {
            self.prefix = Prefix::None;
            return match key.code {
                KeyCode::Char(c) => {
                    self.enter_normal();
                    InputResult::App(AppCommand::BlockReplaceWith { ch: c })
                }
                _ => InputResult::Consumed,
            };
        }
        // count prefix
        if let KeyCode::Char(c @ '1'..='9') = key.code {
            let d = c as u32 - '0' as u32;
            self.count = Some(self.count.unwrap_or(0).saturating_mul(10).saturating_add(d));
            return InputResult::Consumed;
        }
        if let KeyCode::Char(c @ '0'..='9') = key.code
            && self.count.is_some()
        {
            let d = c as u32 - '0' as u32;
            self.count = Some(self.count.unwrap().saturating_mul(10).saturating_add(d));
            return InputResult::Consumed;
        }
        if let Some(m) = Self::motion(key.code) {
            // Motions extend the rectangle (the cursor moves; the anchor
            // stays where BlockSelectStart pinned it).
            let n = self.count1();
            self.count = None;
            return InputResult::Ops(Self::repeated(m, n));
        }
        self.count = None;
        match key.code {
            KeyCode::Esc => {
                self.enter_normal();
                InputResult::Ops(vec![BlockSelectClear])
            }
            // Cycle: Ctrl+V from block ⇒ exit. Bare v / V ⇒ switch to
            // charwise / linewise (close enough — clearing the block and
            // starting fresh charwise from the cursor; vim does smarter
            // handoff but this MVP keeps the simple invariant).
            KeyCode::Char('v') if ctrl => {
                self.enter_normal();
                InputResult::Ops(vec![BlockSelectClear])
            }
            KeyCode::Char('v') => {
                self.mode = VimMode::Visual;
                InputResult::Ops(vec![BlockSelectClear, SelectStart])
            }
            KeyCode::Char('V') => {
                self.mode = VimMode::VisualLine;
                InputResult::Ops(vec![BlockSelectClear, SelectLine])
            }
            // Block yank / delete.
            KeyCode::Char('y') => {
                self.enter_normal();
                InputResult::Ops(vec![YankBlock])
            }
            KeyCode::Char('d') | KeyCode::Char('x') => {
                self.enter_normal();
                InputResult::Ops(vec![DeleteBlock])
            }
            // Block insert / append: `I` ⇒ insert at leftmost col of rect on
            // every row; `A` ⇒ append after the rightmost col. The App
            // captures the rect, drives the handler to Insert, then replays
            // the typed run on every other row when the user presses Esc.
            KeyCode::Char('I') => {
                self.enter_normal();
                InputResult::App(AppCommand::BlockInsertStart { append: false })
            }
            KeyCode::Char('A') => {
                self.enter_normal();
                InputResult::App(AppCommand::BlockInsertStart { append: true })
            }
            // Block change: `c` / `s` — delete the rect then enter Insert
            // mode at the rect's leftmost column. On Esc the typed run is
            // replayed on every other row (same machinery as block `I`).
            KeyCode::Char('c') | KeyCode::Char('s') => {
                self.enter_normal();
                InputResult::App(AppCommand::BlockChangeStart)
            }
            // Swap which corner the cursor is in (vim's visual `o` works in
            // block mode too — but we only have a single anchor so this just
            // mirrors row/col by moving cursor to the opposite corner; the
            // simpler semantics — swap anchor and cursor — works because the
            // rectangle is computed from min/max anyway).
            KeyCode::Char('o') => {
                // No-op for block mode in this MVP — the rect is symmetric.
                InputResult::Consumed
            }
            KeyCode::Char(':') => {
                // Save the live selection to `'<`/`'>` before the cmdline
                // parser resolves the pre-filled `'<,'>`.
                self.open_cmdline_visual_range();
                InputResult::Ops(vec![RememberSelection])
            }
            // V-BLOCK `r<c>` — replace every cell in the rectangle with
            // `<c>`. nvchad-round-7 SEV-2 2026-07-11.
            KeyCode::Char('r') => {
                self.prefix = Prefix::BlockReplaceChar;
                InputResult::Consumed
            }
            _ => InputResult::Consumed,
        }
    }
}

impl InputHandler for VimInputHandler {
    fn handle_key(&mut self, key: KeyEvent, ctx: &EditCtx) -> InputResult {
        if let Some(line) = self.cmdline.take() {
            return self.handle_cmdline(key, line);
        }
        let result = match self.mode {
            VimMode::Insert => self.handle_insert(key, ctx),
            VimMode::Replace => self.handle_replace(key, ctx),
            VimMode::Normal => self.handle_normal(key, ctx),
            VimMode::Visual | VimMode::VisualLine => self.handle_visual(key, ctx),
            VimMode::VisualBlock => self.handle_visual_block(key, ctx),
        };
        // If a `"<reg>` prefix is still pending and we're returning Ops,
        // prepend `SetRegisterHint` so the inner clipboard op routes
        // through that register. Cleared after one use (vim convention —
        // `"a` only sticks for the next op). Only consume the hint when
        // the result is `Ops(...)` (the only path that touches Clipboard);
        // pure motions / app commands keep the hint alive.
        if let InputResult::Ops(ops) = &result
            && self.pending_register.is_some()
            && ops.iter().any(Self::touches_clipboard)
        {
            let reg = self.pending_register.take();
            let mut prefixed = Vec::with_capacity(ops.len() + 1);
            prefixed.push(EditOp::SetRegisterHint(reg));
            prefixed.extend(ops.iter().cloned());
            return InputResult::Ops(prefixed);
        }
        // Insert-mode `Ctrl+O` one-shot: after the next Normal-mode
        // command completes (chord done, no pending op), flip back to
        // Insert. Note the chord-await: `dd` from oneshot stays Normal
        // for the second `d`, then flips back.
        if self.insert_oneshot_normal
            && self.mode == VimMode::Normal
            && self.op.is_none()
            && matches!(self.prefix, Prefix::None)
        {
            // Check we actually consumed something — `Ctrl+O` itself
            // didn't (it just set the flag). Look at result.
            let consumed_more = !matches!(result, InputResult::Consumed)
                || !matches!(key.code, KeyCode::Char('o') if key.modifiers.contains(KeyModifiers::CONTROL));
            if consumed_more {
                self.insert_oneshot_normal = false;
                self.mode = VimMode::Insert;
            }
        }
        result
    }

    fn mode(&self) -> EditingMode {
        match self.mode {
            VimMode::Normal => EditingMode::Normal,
            VimMode::Insert => EditingMode::Insert,
            VimMode::Replace => EditingMode::Replace,
            VimMode::Visual => EditingMode::Visual,
            VimMode::VisualLine => EditingMode::VisualLine,
            VimMode::VisualBlock => EditingMode::VisualBlock,
        }
    }

    fn request_insert_mode(&mut self) {
        self.enter_insert();
    }

    fn request_visual_mode(&mut self) {
        self.mode = VimMode::Visual;
        self.prefix = Prefix::None;
    }

    fn cmdline_get(&self) -> Option<String> {
        self.cmdline.clone()
    }

    fn cmdline_set(&mut self, text: Option<String>) {
        self.cmdline_cursor = text.as_ref().map(String::len).unwrap_or(0);
        self.cmdline = text;
    }
    fn cmdline_caret(&self) -> Option<usize> {
        self.cmdline
            .as_ref()
            .map(|l| self.cmdline_cursor.min(l.len()))
    }
    fn set_cmdline_caret(&mut self, byte_offset: usize) {
        if let Some(l) = self.cmdline.as_ref() {
            self.cmdline_cursor = byte_offset.min(l.len());
        }
    }

    fn pending_display(&self) -> Option<String> {
        if let Some(line) = &self.cmdline {
            // Render with a `▏` caret at the byte position (clamped to a char
            // boundary). The cursor at end-of-line still gets a visible marker.
            let cur = self.cmdline_cursor.min(line.len());
            let (head, tail) = line.split_at(cur);
            return Some(format!(":{head}\u{258f}{tail}"));
        }
        let mut s = String::new();
        if let Some(r) = self.pending_register {
            s.push('"');
            s.push(r);
        }
        if let Some(n) = self.count {
            s.push_str(&n.to_string());
        }
        if let Some(op) = self.op {
            match op {
                PendingOp::Delete => s.push('d'),
                PendingOp::Change => s.push('c'),
                PendingOp::Yank => s.push('y'),
                PendingOp::Indent => s.push('>'),
                PendingOp::Outdent => s.push('<'),
                PendingOp::Reflow => s.push_str("gq"),
                PendingOp::Lower => s.push_str("gu"),
                PendingOp::Upper => s.push_str("gU"),
                PendingOp::ToggleCase => s.push_str("g~"),
                PendingOp::SurroundAdd => s.push_str("ys"),
                PendingOp::Align => s.push_str("gA"),
                PendingOp::Comment => s.push_str("gc"),
                PendingOp::Filter => s.push('!'),
            }
        }
        match self.prefix {
            Prefix::G => s.push('g'),
            Prefix::Gc => s.push_str("gc"),
            Prefix::Gq => s.push_str("gq"),
            Prefix::Z => s.push('Z'),
            Prefix::ZFold => s.push('z'),
            Prefix::Replace => s.push('r'),
            Prefix::BlockReplaceChar => s.push('r'),
            Prefix::MarkSet => s.push('m'),
            Prefix::MarkJumpLine => s.push('\''),
            Prefix::MarkJumpExact => s.push('`'),
            Prefix::TextObjectInner => s.push('i'),
            Prefix::TextObjectAround => s.push('a'),
            Prefix::FindChar(forward, before) => {
                let c = match (forward, before) {
                    (true, false) => 'f',
                    (false, false) => 'F',
                    (true, true) => 't',
                    (false, true) => 'T',
                };
                s.push(c);
            }
            Prefix::Window => s.push_str("^W"),
            Prefix::BracketOpen => s.push('['),
            Prefix::BracketClose => s.push(']'),
            Prefix::Register => s.push('"'),
            Prefix::MacroRecordTarget => s.push('q'),
            Prefix::MacroReplayTarget => s.push('@'),
            Prefix::SurroundDelete => s.push_str("ds"),
            Prefix::SurroundAddCharWait => s.push_str("ys"),
            Prefix::SurroundChange(from) => {
                if from == '\0' {
                    s.push_str("cs");
                } else {
                    s.push_str("cs");
                    s.push(from);
                }
            }
            Prefix::Flash1 => s.push('s'),
            Prefix::Flash2(a) => {
                s.push('s');
                s.push(a);
            }
            Prefix::AlignCharWait => s.push_str("gA"),
            Prefix::None => {}
        }
        if self.mode == VimMode::VisualLine {
            return Some(if s.is_empty() {
                "V-LINE".into()
            } else {
                format!("V-LINE {s}")
            });
        }
        if self.mode == VimMode::VisualBlock {
            return Some(if s.is_empty() {
                "V-BLOCK".into()
            } else {
                format!("V-BLOCK {s}")
            });
        }
        if s.is_empty() { None } else { Some(s) }
    }

    fn name(&self) -> &'static str {
        "vim"
    }

    /// 2026-06-21 — vim-operator whichkey popup. Returns the
    /// continuations available at the current `prefix` state.
    /// NvChad-style — the popup paints whenever the user is one
    /// keypress deep into a multi-key chord, hinting at what
    /// comes next.
    fn operator_menu_hint(&self) -> Option<(String, Vec<(char, &'static str, bool)>)> {
        // Only show in Normal / Visual modes. Insert + cmdline
        // don't have operator chords.
        if !matches!(
            self.mode,
            VimMode::Normal | VimMode::Visual | VimMode::VisualLine | VimMode::VisualBlock
        ) {
            return None;
        }
        match self.prefix {
            Prefix::G => Some((
                "g".to_string(),
                vec![
                    ('g', "top of file (gg)", false),
                    ('e', "back end-of-word (ge)", false),
                    ('d', "go to definition (LSP)", false),
                    ('D', "go to declaration (LSP)", false),
                    ('r', "find references (LSP)", false),
                    ('i', "go to implementation (LSP)", false),
                    ('h', "hover (LSP)", false),
                    ('t', "next tab", false),
                    ('T', "prev tab", false),
                    ('c', "+comment", true),
                    ('q', "+reflow", true),
                    ('u', "lowercase {motion}", false),
                    ('U', "uppercase {motion}", false),
                    ('v', "reselect last visual", false),
                    ('f', "open file under cursor", false),
                    ('x', "execute file under cursor", false),
                ],
            )),
            Prefix::Gc => Some((
                "gc".to_string(),
                vec![
                    ('c', "comment current line (gcc)", false),
                    ('w', "comment word", false),
                    ('p', "comment paragraph", false),
                ],
            )),
            Prefix::Z => Some((
                "Z".to_string(),
                vec![
                    ('Z', "save & quit (:x)", false),
                    ('Q', "quit without save (:q!)", false),
                ],
            )),
            Prefix::ZFold => Some((
                "z".to_string(),
                vec![
                    ('a', "toggle fold (cursor)", false),
                    ('o', "open fold (cursor)", false),
                    ('c', "close fold (cursor)", false),
                    ('R', "open all folds", false),
                    ('M', "close all folds (lsp.fold_all)", false),
                    ('E', "expand all folds", false),
                ],
            )),
            Prefix::Window => Some((
                "Ctrl+W".to_string(),
                vec![
                    ('h', "focus left split", false),
                    ('j', "focus down split", false),
                    ('k', "focus up split", false),
                    ('l', "focus right split", false),
                    ('w', "cycle splits", false),
                    ('q', "close current split", false),
                    ('s', "split horizontal", false),
                    ('v', "split vertical", false),
                ],
            )),
            Prefix::BracketOpen => Some((
                "[".to_string(),
                vec![
                    ('c', "prev git hunk", false),
                    ('d', "prev LSP diagnostic", false),
                    ('e', "prev error (LSP)", false),
                    ('q', "prev quickfix item", false),
                ],
            )),
            Prefix::BracketClose => Some((
                "]".to_string(),
                vec![
                    ('c', "next git hunk", false),
                    ('d', "next LSP diagnostic", false),
                    ('e', "next error (LSP)", false),
                    ('q', "next quickfix item", false),
                ],
            )),
            Prefix::Register => Some((
                "\"".to_string(),
                vec![
                    ('a', "+ register a-z (named)", true),
                    ('0', "last yank", false),
                    ('+', "system clipboard", false),
                    ('_', "blackhole (discard)", false),
                ],
            )),
            // Other prefixes (mark-set, find-char, replace,
            // text-object) are single-char terminators with no
            // useful menu — they want ANY char, not a list.
            _ => None,
        }
    }

    fn on_blur(&mut self) {
        // Drop to Normal and forget any half-typed chord / `:`-line.
        self.mode = VimMode::Normal;
        self.reset_pending();
        self.cmdline = None;
    }

    fn set_ex_history(&mut self, entries: Vec<String>) {
        // Cap on restore so a runaway session.json can't bloat us.
        let take_from = entries.len().saturating_sub(EX_HISTORY_MAX);
        self.ex_history = entries.into_iter().skip(take_from).collect();
        self.ex_history_cursor = None;
        self.ex_history_typing = None;
    }

    fn ex_history(&self) -> Vec<String> {
        self.ex_history.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::crossterm::event::KeyEvent;

    fn h() -> VimInputHandler {
        VimInputHandler::new(&Config::default())
    }
    fn ctx() -> EditCtx {
        EditCtx {
            cursor: 0,
            line_len: 4,
            line_idx: 0,
            line_count: 3,
            at_line_start: true,
            at_line_end: false,
            has_selection: false,
            next_find_match: None,
            prev_find_match: None,
            wrap_width: None,
        }
    }
    fn k(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
    }
    fn kc(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }
    fn kctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }
    fn ops(r: InputResult) -> Vec<EditOp> {
        match r {
            InputResult::Ops(v) => v,
            _ => panic!("expected Ops"),
        }
    }

    #[test]
    fn starts_in_normal() {
        assert_eq!(h().mode(), EditingMode::Normal);
    }

    #[test]
    fn i_enters_insert_esc_returns() {
        let mut v = h();
        assert!(matches!(
            v.handle_key(k('i'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(v.mode(), EditingMode::Insert);
        assert_eq!(
            ops(v.handle_key(k('a'), &ctx())),
            vec![EditOp::InsertChar('a')]
        );
        assert_eq!(
            ops(v.handle_key(kc(KeyCode::Esc), &ctx())),
            vec![EditOp::MoveLeft]
        );
        assert_eq!(v.mode(), EditingMode::Normal);
    }

    #[test]
    fn o_opens_line_below_and_inserts() {
        let mut v = h();
        assert_eq!(
            ops(v.handle_key(k('o'), &ctx())),
            vec![EditOp::InsertNewlineBelow]
        );
        assert_eq!(v.mode(), EditingMode::Insert);
    }

    #[test]
    fn hjkl_move() {
        let mut v = h();
        assert_eq!(ops(v.handle_key(k('h'), &ctx())), vec![EditOp::MoveLeft]);
        assert_eq!(ops(v.handle_key(k('j'), &ctx())), vec![EditOp::MoveDown]);
        assert_eq!(ops(v.handle_key(k('k'), &ctx())), vec![EditOp::MoveUp]);
        assert_eq!(ops(v.handle_key(k('l'), &ctx())), vec![EditOp::MoveRight]);
    }

    #[test]
    fn count_then_word_is_repeat() {
        let mut v = h();
        assert!(matches!(
            v.handle_key(k('5'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(
            ops(v.handle_key(k('w'), &ctx())),
            vec![EditOp::Repeat(5, Box::new(EditOp::MoveWordRight))]
        );
    }

    #[test]
    fn dw_deletes_word() {
        let mut v = h();
        assert!(matches!(
            v.handle_key(k('d'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(
            ops(v.handle_key(k('w'), &ctx())),
            vec![
                EditOp::SelectStart,
                EditOp::MoveWordRight,
                EditOp::DeleteSelection
            ]
        );
    }

    #[test]
    fn dd_deletes_line() {
        let mut v = h();
        assert!(matches!(
            v.handle_key(k('d'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(ops(v.handle_key(k('d'), &ctx())), vec![EditOp::DeleteLine]);
    }

    #[test]
    fn count_dd_repeats_delete_line() {
        let mut v = h();
        v.handle_key(k('3'), &ctx());
        v.handle_key(k('d'), &ctx());
        assert_eq!(
            ops(v.handle_key(k('d'), &ctx())),
            vec![EditOp::Repeat(3, Box::new(EditOp::DeleteLine))]
        );
    }

    #[test]
    fn yy_yanks_line() {
        let mut v = h();
        v.handle_key(k('y'), &ctx());
        assert_eq!(ops(v.handle_key(k('y'), &ctx())), vec![EditOp::YankLine]);
    }

    #[test]
    fn x_deletes_forward_p_pastes_u_undo_ctrlr_redo() {
        let mut v = h();
        assert_eq!(
            ops(v.handle_key(k('x'), &ctx())),
            vec![EditOp::DeleteForward]
        );
        assert_eq!(ops(v.handle_key(k('p'), &ctx())), vec![EditOp::PasteAfter]);
        assert_eq!(ops(v.handle_key(k('u'), &ctx())), vec![EditOp::Undo]);
        assert_eq!(ops(v.handle_key(kctrl('r'), &ctx())), vec![EditOp::Redo]);
    }

    #[test]
    fn gg_to_buffer_start_lone_g_pends() {
        let mut v = h();
        assert!(matches!(
            v.handle_key(k('g'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(v.pending_display().as_deref(), Some("g"));
        assert_eq!(
            ops(v.handle_key(k('g'), &ctx())),
            vec![EditOp::MoveBufferStart]
        );
        assert_eq!(v.pending_display(), None);
    }

    #[test]
    fn cap_g_to_buffer_end_count_g_to_line() {
        let mut v = h();
        assert_eq!(
            ops(v.handle_key(k('G'), &ctx())),
            vec![EditOp::MoveBufferEnd]
        );
        let mut v = h();
        v.handle_key(k('1'), &ctx());
        v.handle_key(k('2'), &ctx());
        assert_eq!(
            ops(v.handle_key(k('G'), &ctx())),
            vec![EditOp::MoveToLine(12)]
        );
    }

    #[test]
    fn visual_select_extend_yank() {
        let mut v = h();
        assert_eq!(ops(v.handle_key(k('v'), &ctx())), vec![EditOp::SelectStart]);
        assert_eq!(v.mode(), EditingMode::Visual);
        assert_eq!(ops(v.handle_key(k('l'), &ctx())), vec![EditOp::MoveRight]);
        assert_eq!(
            ops(v.handle_key(k('y'), &ctx())),
            vec![EditOp::YankSelection, EditOp::SelectClear]
        );
        assert_eq!(v.mode(), EditingMode::Normal);
    }

    #[test]
    fn cmdline_wq_becomes_excommand() {
        let mut v = h();
        assert!(matches!(
            v.handle_key(k(':'), &ctx()),
            InputResult::Consumed
        ));
        // pending_display embeds a `▏` caret marker at the cursor byte.
        assert_eq!(v.pending_display().as_deref(), Some(":\u{258f}"));
        v.handle_key(k('w'), &ctx());
        v.handle_key(k('q'), &ctx());
        assert_eq!(v.pending_display().as_deref(), Some(":wq\u{258f}"));
        match v.handle_key(kc(KeyCode::Enter), &ctx()) {
            // 2026-06-19 — vim cmdline Enter now emits
            // CmdlineEnter (the App-side handler decides whether
            // to accept a popup match) instead of ExCommand. Old
            // ExCommand path still exists for cases that send
            // commands directly.
            InputResult::App(AppCommand::CmdlineEnter(s)) => assert_eq!(s, "wq"),
            _ => panic!("expected CmdlineEnter"),
        }
    }

    #[test]
    fn cmdline_esc_cancels() {
        let mut v = h();
        v.handle_key(k(':'), &ctx());
        v.handle_key(k('q'), &ctx());
        assert!(matches!(
            v.handle_key(kc(KeyCode::Esc), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(v.pending_display(), None);
    }

    #[test]
    fn zz_and_zq() {
        let mut v = h();
        v.handle_key(k('Z'), &ctx());
        match v.handle_key(k('Z'), &ctx()) {
            InputResult::App(AppCommand::ExCommand(s)) => assert_eq!(s, "x"),
            _ => panic!("ZZ → :x"),
        }
        let mut v = h();
        v.handle_key(k('Z'), &ctx());
        match v.handle_key(k('Q'), &ctx()) {
            InputResult::App(AppCommand::ExCommand(s)) => assert_eq!(s, "q!"),
            _ => panic!("ZQ → :q!"),
        }
    }

    #[test]
    fn gd_runs_lsp_command() {
        let mut v = h();
        v.handle_key(k('g'), &ctx());
        match v.handle_key(k('d'), &ctx()) {
            InputResult::App(AppCommand::RunCommand(id)) => assert_eq!(id, "lsp.goto_definition"),
            _ => panic!("gd → lsp.goto_definition"),
        }
    }

    #[test]
    fn gcc_toggles_comment() {
        let mut v = h();
        v.handle_key(k('g'), &ctx());
        v.handle_key(k('c'), &ctx());
        assert_eq!(
            ops(v.handle_key(k('c'), &ctx())),
            vec![EditOp::ToggleLineComment]
        );
    }

    #[test]
    fn on_blur_resets() {
        let mut v = h();
        v.handle_key(k('i'), &ctx());
        v.handle_key(k('d'), &ctx());
        v.on_blur();
        assert_eq!(v.mode(), EditingMode::Normal);
        assert_eq!(v.pending_display(), None);
    }

    #[test]
    fn unknown_normal_key_is_ignored() {
        let mut v = h();
        assert!(matches!(v.handle_key(k('Q'), &ctx()), InputResult::Ignored));
    }

    #[test]
    fn marks_set_and_jump_via_app_command() {
        let mut v = h();
        // m a — set mark 'a'
        assert!(matches!(
            v.handle_key(k('m'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(v.pending_display().as_deref(), Some("m"));
        assert!(matches!(
            v.handle_key(k('a'), &ctx()),
            InputResult::App(AppCommand::SetMark('a'))
        ));
        assert_eq!(v.pending_display(), None);

        // ' a — line jump to mark 'a'
        assert!(matches!(
            v.handle_key(k('\''), &ctx()),
            InputResult::Consumed
        ));
        assert!(matches!(
            v.handle_key(k('a'), &ctx()),
            InputResult::App(AppCommand::JumpToMarkLine('a'))
        ));

        // ` a — exact jump
        assert!(matches!(
            v.handle_key(k('`'), &ctx()),
            InputResult::Consumed
        ));
        assert!(matches!(
            v.handle_key(k('a'), &ctx()),
            InputResult::App(AppCommand::JumpToMarkExact('a'))
        ));
    }

    #[test]
    fn marks_ignore_non_letter() {
        let mut v = h();
        // m followed by a digit ⇒ consumed but not a SetMark
        v.handle_key(k('m'), &ctx());
        assert!(matches!(
            v.handle_key(k('1'), &ctx()),
            InputResult::Consumed
        ));
        // m followed by punctuation ⇒ also consumed-only
        v.handle_key(k('m'), &ctx());
        assert!(matches!(
            v.handle_key(k('!'), &ctx()),
            InputResult::Consumed
        ));
    }

    #[test]
    fn diw_dispatches_select_inner_word_then_delete() {
        let mut v = h();
        // d — operator pending
        assert!(matches!(
            v.handle_key(k('d'), &ctx()),
            InputResult::Consumed
        ));
        // i — switch into TextObjectInner prefix
        assert!(matches!(
            v.handle_key(k('i'), &ctx()),
            InputResult::Consumed
        ));
        assert_eq!(v.pending_display().as_deref(), Some("di"));
        // w — emit the ops
        let ops = ops(v.handle_key(k('w'), &ctx()));
        assert_eq!(ops, vec![EditOp::SelectInnerWord, EditOp::DeleteSelection]);
        assert_eq!(v.pending_display(), None);
    }

    #[test]
    fn caw_dispatches_select_around_word_replace_and_enter_insert() {
        let mut v = h();
        v.handle_key(k('c'), &ctx());
        v.handle_key(k('a'), &ctx());
        let ops = ops(v.handle_key(k('w'), &ctx()));
        assert_eq!(
            ops,
            vec![
                EditOp::SelectAroundWord,
                EditOp::ReplaceSelection(String::new())
            ]
        );
        assert_eq!(v.mode(), EditingMode::Insert);
    }

    #[test]
    fn uppercase_marks_escalate_too() {
        let mut v = h();
        v.handle_key(k('m'), &ctx());
        // M-uppercase is a global mark — also escalates.
        assert!(matches!(
            v.handle_key(k('A'), &ctx()),
            InputResult::App(AppCommand::SetMark('A'))
        ));
    }
}
