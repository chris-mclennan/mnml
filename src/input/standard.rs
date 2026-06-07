//! Modeless, VSCode-style keymap. Typing inserts; arrows move (Shift extends a
//! selection); Ctrl+C/X/V/Z/Y/A do the usual; Ctrl+←/→ are word motions;
//! Ctrl+Backspace/Del delete words; Ctrl+/ toggles a line comment; Alt+↑/↓ move
//! the line; Ctrl+S saves; Esc clears a selection (then falls through so the
//! tree gets focus).
//!
//! TODO(P3): make the bindings data-driven from `[keys.standard]` config — for
//! now it's a hardcoded match. The `[keys.*]` resolver lands alongside the vim
//! handler since both need the same `KeySpec`→action machinery.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::config::Config;
use crate::edit_op::EditOp;
use crate::input::{AppCommand, EditCtx, EditingMode, InputHandler, InputResult};

#[derive(Debug)]
pub struct StandardInputHandler {
    tab_width: usize,
}

impl StandardInputHandler {
    pub fn new(cfg: &Config) -> Self {
        StandardInputHandler {
            tab_width: cfg.editor.tab_width.max(1),
        }
    }
}

impl InputHandler for StandardInputHandler {
    fn handle_key(&mut self, key: KeyEvent, ctx: &EditCtx) -> InputResult {
        use EditOp::*;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);

        // A plain typed character (no Ctrl/Alt; Shift just gives an uppercase char).
        if let KeyCode::Char(c) = key.code
            && !ctrl
            && !alt
        {
            return InputResult::Ops(vec![InsertChar(c)]);
        }

        // A motion that should extend the selection when Shift is held, else replace it.
        let mv = |op: EditOp| -> InputResult {
            if shift {
                if ctx.has_selection {
                    InputResult::Ops(vec![op])
                } else {
                    InputResult::Ops(vec![SelectStart, op])
                }
            } else {
                InputResult::Ops(vec![SelectClear, op])
            }
        };

        match key.code {
            KeyCode::Char(c) if ctrl && !alt => match c.to_ascii_lowercase() {
                'a' => InputResult::Ops(vec![SelectAll]),
                'c' => InputResult::Ops(vec![if ctx.has_selection {
                    YankSelection
                } else {
                    YankLine
                }]),
                'x' => InputResult::Ops(if ctx.has_selection {
                    vec![CutSelection]
                } else {
                    vec![YankLine, DeleteLine]
                }),
                'v' => InputResult::Ops(vec![Paste]),
                'z' if shift => InputResult::Ops(vec![Redo]),
                'z' => InputResult::Ops(vec![Undo]),
                'y' => InputResult::Ops(vec![Redo]),
                '/' => InputResult::Ops(vec![ToggleLineComment]),
                's' => InputResult::App(AppCommand::Save),
                'd' if shift => InputResult::Ops(vec![DuplicateLine]),
                'd' => InputResult::Ops(vec![SelectWord]), // closest we have to "select occurrence" for now
                'l' => InputResult::Ops(vec![SelectLine]),
                'g' => InputResult::Ignored, // "go to line" → palette/prompt later
                _ => InputResult::Ignored,
            },

            // `Ctrl+Enter` = open new line below (cursor lands at start of
            // the new line, indented to match the current line). VS Code
            // muscle memory. `Ctrl+Shift+Enter` opens above. Plain Enter is
            // the standard newline-at-cursor.
            KeyCode::Enter if ctrl && !alt && key.modifiers.contains(KeyModifiers::SHIFT) => {
                InputResult::Ops(vec![MoveLineStart, InsertNewline, MoveUp])
            }
            KeyCode::Enter if ctrl && !alt => InputResult::Ops(vec![MoveLineEnd, InsertNewline]),
            KeyCode::Enter => InputResult::Ops(vec![InsertNewline]),
            KeyCode::Tab => {
                if ctx.has_selection {
                    InputResult::Ops(vec![Indent])
                } else {
                    InputResult::Ops(vec![InsertStr(" ".repeat(self.tab_width))])
                }
            }
            KeyCode::BackTab => InputResult::Ops(vec![Outdent]),

            KeyCode::Backspace if ctrl && !alt => InputResult::Ops(vec![DeleteWordLeft]),
            KeyCode::Backspace => InputResult::Ops(vec![Backspace]),
            KeyCode::Delete if ctrl && !alt => InputResult::Ops(vec![DeleteWordRight]),
            KeyCode::Delete => InputResult::Ops(vec![DeleteForward]),

            KeyCode::Left if ctrl && !alt => mv(MoveWordLeft),
            KeyCode::Right if ctrl && !alt => mv(MoveWordRight),
            KeyCode::Left => mv(MoveLeft),
            KeyCode::Right => mv(MoveRight),
            KeyCode::Up if alt => InputResult::Ops(vec![MoveLineUp]),
            KeyCode::Down if alt => InputResult::Ops(vec![MoveLineDown]),
            // Vim-aligned aliases for line shift in standard mode too.
            KeyCode::Char('k' | 'K') if alt => InputResult::Ops(vec![MoveLineUp]),
            KeyCode::Char('j' | 'J') if alt => InputResult::Ops(vec![MoveLineDown]),
            KeyCode::Up => mv(MoveUp),
            KeyCode::Down => mv(MoveDown),

            KeyCode::Home if ctrl && !alt => mv(MoveBufferStart),
            KeyCode::End if ctrl && !alt => mv(MoveBufferEnd),
            KeyCode::Home => mv(MoveLineStart),
            KeyCode::End => mv(MoveLineEnd),
            KeyCode::PageUp => mv(PageUp),
            KeyCode::PageDown => mv(PageDown),

            KeyCode::Esc => {
                if ctx.has_selection {
                    InputResult::Ops(vec![SelectClear])
                } else {
                    InputResult::Ignored
                }
            }

            _ => InputResult::Ignored,
        }
    }

    fn mode(&self) -> EditingMode {
        EditingMode::None
    }

    fn name(&self) -> &'static str {
        "standard"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use ratatui::crossterm::event::KeyEvent;

    fn h() -> StandardInputHandler {
        StandardInputHandler::new(&Config::default())
    }
    fn ctx(has_sel: bool) -> EditCtx {
        EditCtx {
            cursor: 0,
            line_len: 0,
            line_idx: 0,
            line_count: 1,
            at_line_start: true,
            at_line_end: true,
            has_selection: has_sel,
            next_find_match: None,
            prev_find_match: None,
            wrap_width: None,
        }
    }
    fn key(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }
    fn ops(r: InputResult) -> Vec<EditOp> {
        match r {
            InputResult::Ops(v) => v,
            _ => panic!("expected Ops"),
        }
    }

    #[test]
    fn typing_inserts() {
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('a'), KeyModifiers::NONE), &ctx(false))),
            vec![EditOp::InsertChar('a')]
        );
        // Shift'd capital still inserts.
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('A'), KeyModifiers::SHIFT), &ctx(false))),
            vec![EditOp::InsertChar('A')]
        );
    }

    #[test]
    fn enter_backspace_tab() {
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Enter, KeyModifiers::NONE), &ctx(false))),
            vec![EditOp::InsertNewline]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Backspace, KeyModifiers::NONE), &ctx(false))),
            vec![EditOp::Backspace]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Tab, KeyModifiers::NONE), &ctx(false))),
            vec![EditOp::InsertStr("    ".to_string())]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Tab, KeyModifiers::NONE), &ctx(true))),
            vec![EditOp::Indent]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::BackTab, KeyModifiers::NONE), &ctx(false))),
            vec![EditOp::Outdent]
        );
    }

    #[test]
    fn arrows_and_selection() {
        // plain arrow clears any selection then moves
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Left, KeyModifiers::NONE), &ctx(true))),
            vec![EditOp::SelectClear, EditOp::MoveLeft]
        );
        // shift arrow with no selection: start one, then move
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Right, KeyModifiers::SHIFT), &ctx(false))),
            vec![EditOp::SelectStart, EditOp::MoveRight]
        );
        // shift arrow with an active selection: just extend
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Right, KeyModifiers::SHIFT), &ctx(true))),
            vec![EditOp::MoveRight]
        );
        // ctrl arrow → word motion
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Left, KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::SelectClear, EditOp::MoveWordLeft]
        );
        // alt up/down → move line
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Up, KeyModifiers::ALT), &ctx(false))),
            vec![EditOp::MoveLineUp]
        );
    }

    #[test]
    fn clipboard_and_history() {
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('a'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::SelectAll]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('c'), KeyModifiers::CONTROL), &ctx(true))),
            vec![EditOp::YankSelection]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('c'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::YankLine]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('x'), KeyModifiers::CONTROL), &ctx(true))),
            vec![EditOp::CutSelection]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('x'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::YankLine, EditOp::DeleteLine]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('v'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::Paste]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('z'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::Undo]
        );
        assert_eq!(
            ops(h().handle_key(
                key(
                    KeyCode::Char('z'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                &ctx(false)
            )),
            vec![EditOp::Redo]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('y'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::Redo]
        );
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Char('/'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::ToggleLineComment]
        );
    }

    #[test]
    fn ctrl_s_is_save_app_command() {
        match h().handle_key(key(KeyCode::Char('s'), KeyModifiers::CONTROL), &ctx(false)) {
            InputResult::App(AppCommand::Save) => {}
            _ => panic!("Ctrl+S should be App(Save)"),
        }
    }

    #[test]
    fn esc_clears_selection_else_ignored() {
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Esc, KeyModifiers::NONE), &ctx(true))),
            vec![EditOp::SelectClear]
        );
        assert!(matches!(
            h().handle_key(key(KeyCode::Esc, KeyModifiers::NONE), &ctx(false)),
            InputResult::Ignored
        ));
    }

    #[test]
    fn mode_is_none() {
        assert_eq!(h().mode(), EditingMode::None);
    }

    /// Regression for the 2026-06-07 bug-hunt SEV-2 finding: any
    /// extra modifier (Alt, Super) on top of Ctrl+<char> used to
    /// silently fall into the Ctrl+<char> arm — e.g. Ctrl+Alt+X cut
    /// the current line, Ctrl+Alt+A selected all, Ctrl+Alt+S saved.
    /// macOS keyboards emit Ctrl+Alt+* for OS-level shortcuts; the
    /// leak was easy to hit accidentally.
    #[test]
    fn ctrl_plus_alt_is_not_treated_as_plain_ctrl() {
        let cases = ['a', 'c', 'x', 'v', 'z', 'y', 's', 'd', 'l', '/'];
        for c in cases {
            let r = h().handle_key(
                key(KeyCode::Char(c), KeyModifiers::CONTROL | KeyModifiers::ALT),
                &ctx(false),
            );
            assert!(
                matches!(r, InputResult::Ignored),
                "Ctrl+Alt+{c} should be Ignored, was not"
            );
        }
        // Named keys (Enter, Backspace, Delete, arrows, Home, End)
        // also have ctrl arms — those now require `!alt` too, so
        // Ctrl+Alt+<key> doesn't execute the ctrl version. The named
        // keys fall through to their no-modifier handlers (e.g.
        // Ctrl+Alt+Enter ⇒ plain InsertNewline) instead of doing the
        // word-jump / line-end action. Tested separately:
        let r = h().handle_key(
            key(KeyCode::Left, KeyModifiers::CONTROL | KeyModifiers::ALT),
            &ctx(false),
        );
        // Ctrl+Left = MoveWordLeft; Ctrl+Alt+Left should NOT word-jump.
        // It falls through to plain MoveLeft (cursor-left-one).
        let want_one_cell_left = vec![EditOp::SelectClear, EditOp::MoveLeft];
        assert_eq!(
            ops(r),
            want_one_cell_left,
            "Ctrl+Alt+Left should be a plain MoveLeft, not MoveWordLeft"
        );
    }

    /// Ctrl+Shift+<char> still works for the arms that explicitly
    /// opt into shift (Ctrl+Shift+Z = Redo, Ctrl+Shift+D =
    /// DuplicateLine) — the modifier-leak fix only blocks Alt.
    #[test]
    fn ctrl_plus_shift_still_dispatches() {
        // Ctrl+Shift+Z → Redo
        assert_eq!(
            ops(h().handle_key(
                key(
                    KeyCode::Char('z'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                &ctx(false)
            )),
            vec![EditOp::Redo]
        );
        // Ctrl+Shift+D → DuplicateLine
        assert_eq!(
            ops(h().handle_key(
                key(
                    KeyCode::Char('d'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                &ctx(false)
            )),
            vec![EditOp::DuplicateLine]
        );
    }
}
