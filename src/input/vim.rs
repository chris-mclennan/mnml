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
    /// vim-surround `ys{motion}<c>` — wrap the motion's range with a
    /// surround char chosen *after* the motion completes. The motion's
    /// select-ops get stashed in `pending_surround_ops`, then we transition
    /// to `Prefix::SurroundAddCharWait` for the char keystroke.
    SurroundAdd,
    /// mini.align `gA{motion}<char>` — align lines in the motion's range
    /// on `<char>`. Like `SurroundAdd`, the alignment char arrives *after*
    /// the motion completes (handler transitions to `Prefix::AlignCharWait`).
    Align,
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
    /// Saw lowercase `z` — vim's fold prefix. `a` toggles, `R` unfolds all,
    /// `M` (folds all — not yet wired). Distinct from [`Self::Z`] because
    /// vim uses both letters for different families.
    ZFold,
    /// Saw `r` — replace the char under the cursor with the next typed char.
    Replace,
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
            KeyCode::Char('$') | KeyCode::End => MoveLineEnd,
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
                // to end-of-line after Tab.
                self.cmdline = Some(line);
                InputResult::App(AppCommand::CmdlineTabComplete)
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
                    InputResult::App(AppCommand::ExCommand(line))
                }
            }
            KeyCode::Up => {
                if self.ex_history.is_empty() {
                    self.cmdline = Some(line);
                    return InputResult::Consumed;
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
                    return InputResult::Consumed;
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
                let valid = c.is_ascii_lowercase() || c == '0' || c == '+' || c == '_';
                if valid {
                    return InputResult::Ops(vec![SetRegisterHint(Some(c)), Paste]);
                }
                // `Ctrl+R Ctrl+W` — paste the word under the cursor inline
                // (vim canonical). Routed through an App command since
                // word-under-cursor isn't an EditOp primitive.
                if c == 'w' && ctrl {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_word_under_cursor".into(),
                    ));
                }
                // `Ctrl+R Ctrl+A` — paste WORD (whitespace-delimited) under
                // the cursor.
                if c == 'a' && ctrl {
                    return InputResult::App(AppCommand::RunCommand(
                        "editor.insert_bigword_under_cursor".into(),
                    ));
                }
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
            Prefix::ZFold => {
                self.reset_pending();
                return match key.code {
                    KeyCode::Char('a') | KeyCode::Char('o') | KeyCode::Char('c') => {
                        InputResult::App(AppCommand::RunCommand("editor.toggle_fold".into()))
                    }
                    // `zR` opens all folds; `zE` removes every fold (vim
                    // canon — same effect in mnml since folds are line-based
                    // and unfold = drop the entry).
                    KeyCode::Char('R') | KeyCode::Char('E') => {
                        InputResult::App(AppCommand::RunCommand("editor.unfold_all".into()))
                    }
                    // `zM` — fold all (mnml uses server-suggested ranges via
                    // textDocument/foldingRange; falls back to no-op when no
                    // LSP). Vim's `zM` closes every fold; ours installs +
                    // closes the server's recommended set.
                    KeyCode::Char('M') => {
                        InputResult::App(AppCommand::RunCommand("lsp.fold_all".into()))
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
                    // `gt` / `gT` — vim "next/prev tab page".
                    KeyCode::Char('t') => {
                        InputResult::App(AppCommand::RunCommand("tab.next".into()))
                    }
                    KeyCode::Char('T') => {
                        InputResult::App(AppCommand::RunCommand("tab.prev".into()))
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
                                | PendingOp::Align => {
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
                self.reset_pending();
                if key.code == KeyCode::Char('c') {
                    return InputResult::Ops(vec![ToggleLineComment]);
                }
                // `gc` + motion: select the motion's span, comment it, collapse.
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
                    let valid =
                        c.is_ascii_lowercase() || c.is_ascii_digit() || c == '+' || c == '_';
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
                if let KeyCode::Char(c) = key.code {
                    if c == '@' {
                        return InputResult::App(AppCommand::MacroReplayFrom('@'));
                    }
                    if c.is_ascii_lowercase() {
                        return InputResult::App(AppCommand::MacroReplayFrom(c));
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
                        InputResult::Ops(vec![SelectLine, ReplaceSelection(String::new())])
                    }
                    PendingOp::Indent => InputResult::Ops(Self::repeated(Indent, n)),
                    PendingOp::Outdent => InputResult::Ops(Self::repeated(Outdent, n)),
                    PendingOp::Reflow => InputResult::Ops(vec![ReflowParagraph {
                        width: self.text_width,
                    }]),
                    PendingOp::Lower => InputResult::Ops(vec![
                        SelectLine,
                        TransformSelectionCase(crate::edit_op::CaseTransform::Lower),
                        SelectClear,
                    ]),
                    PendingOp::Upper => InputResult::Ops(vec![
                        SelectLine,
                        TransformSelectionCase(crate::edit_op::CaseTransform::Upper),
                        SelectClear,
                    ]),
                    PendingOp::ToggleCase => InputResult::Ops(vec![
                        SelectLine,
                        TransformSelectionCase(crate::edit_op::CaseTransform::Toggle),
                        SelectClear,
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
            if let Some(m) = Self::motion(key.code) {
                let mut ops = vec![SelectStart];
                if n > 1 {
                    ops.push(Repeat(n, Box::new(m)));
                } else {
                    ops.push(m);
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
            KeyCode::Char('[') => {
                self.prefix = Prefix::BracketOpen;
                InputResult::Consumed
            }
            KeyCode::Char(']') => {
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
            // vim `.` — repeat the last change.
            KeyCode::Char('.') => {
                self.reset_pending();
                InputResult::App(AppCommand::RunCommand("vim.dot_repeat".into()))
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
                InputResult::Ops(vec![YankSelection, SelectClear])
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
                self.open_cmdline();
                InputResult::Consumed
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
                self.open_cmdline();
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
            VimMode::Visual | VimMode::VisualLine | VimMode::VisualBlock => EditingMode::Visual,
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
            }
        }
        match self.prefix {
            Prefix::G => s.push('g'),
            Prefix::Gc => s.push_str("gc"),
            Prefix::Gq => s.push_str("gq"),
            Prefix::Z => s.push('Z'),
            Prefix::ZFold => s.push('z'),
            Prefix::Replace => s.push('r'),
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
            InputResult::App(AppCommand::ExCommand(s)) => assert_eq!(s, "wq"),
            _ => panic!("expected ExCommand"),
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
