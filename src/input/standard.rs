//! Modeless, VSCode-style keymap. Typing inserts; arrows move (Shift extends a
//! selection); Ctrl+C/X/V/Z/Y/A do the usual; Ctrl+←/→ are word motions;
//! Ctrl+Backspace/Del delete words; Ctrl+/ toggles a line comment; Alt+↑/↓ move
//! the line; Ctrl+S saves; Esc clears a selection (then falls through so the
//! tree gets focus).
//!
//! `[keys.standard]` config overlays: any entry there is checked FIRST, so a
//! user can rebind chords or unbind them entirely without touching the code.
//! Context-sensitive behaviors (smart Ctrl+C, Shift+arrow selection extend,
//! Tab-with-selection = Indent, Esc-with-selection = Clear) stay hardcoded —
//! they can't be expressed as a static chord → op mapping. Overrides for those
//! chords still work; the hardcoded smart behavior is only the fallback.

use std::collections::HashMap;

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::config::Config;
use crate::edit_op::EditOp;
use crate::input::keymap::{Chord, parse_key_spec};
use crate::input::{AppCommand, EditCtx, EditingMode, InputHandler, InputResult};

/// What a `[keys.standard]` entry can bind a chord to. Constructed by parsing
/// the config value string via `StandardAction::parse`.
#[derive(Debug, Clone)]
enum StandardAction {
    /// Fire one EditOp.
    Op(EditOp),
    /// Fire an ordered sequence of EditOps.
    Ops(Vec<EditOp>),
    /// Escalate to an App-level command (`Save`).
    App(AppCommand),
    /// Explicit unbind — the chord is silently ignored, no fallback to
    /// the hardcoded logic. Config value `"none"` / `"unbound"` / `""`.
    Unbound,
}

impl StandardAction {
    /// Vocabulary the config accepts. Case-insensitive. Composite / smart
    /// actions (Ctrl+C context-sensitive yank, Tab-with-selection Indent)
    /// aren't in the vocabulary — they can only be OVERRIDDEN, not
    /// invoked by name.
    fn parse(s: &str) -> Option<StandardAction> {
        use EditOp::*;
        let t = s.trim().to_ascii_lowercase();
        // Composite: `"move_line_end; insert_newline"` produces an ordered
        // sequence. Lets users configure `ctrl+enter` = open-new-line-below
        // (VS Code's Ctrl+Enter behavior) without a special action name.
        if t.contains(';') {
            let mut ops: Vec<EditOp> = Vec::new();
            for part in t.split(';') {
                match StandardAction::parse(part)? {
                    StandardAction::Op(op) => ops.push(op),
                    _ => return None,
                }
            }
            return Some(if ops.len() == 1 {
                StandardAction::Op(ops.remove(0))
            } else {
                StandardAction::Ops(ops)
            });
        }
        Some(match t.as_str() {
            "" | "none" | "unbound" => StandardAction::Unbound,
            "app.save" | "save" => StandardAction::App(AppCommand::Save),
            "select_all" => StandardAction::Op(SelectAll),
            "select_word" => StandardAction::Op(SelectWord),
            "select_line_to_end" => StandardAction::Op(SelectLineToEnd),
            "select_clear" => StandardAction::Op(SelectClear),
            "yank_selection" => StandardAction::Op(YankSelection),
            "yank_line" => StandardAction::Op(YankLine),
            "cut_selection" => StandardAction::Op(CutSelection),
            "paste" => StandardAction::Op(Paste),
            "undo" => StandardAction::Op(Undo),
            "redo" => StandardAction::Op(Redo),
            "delete_line" => StandardAction::Op(DeleteLine),
            "duplicate_line" => StandardAction::Op(DuplicateLine),
            "toggle_line_comment" => StandardAction::Op(ToggleLineComment),
            "indent" => StandardAction::Op(Indent),
            "outdent" => StandardAction::Op(Outdent),
            "backspace" => StandardAction::Op(Backspace),
            "delete_forward" => StandardAction::Op(DeleteForward),
            "delete_word_left" => StandardAction::Op(DeleteWordLeft),
            "delete_word_right" => StandardAction::Op(DeleteWordRight),
            "move_left" => StandardAction::Op(MoveLeft),
            "move_right" => StandardAction::Op(MoveRight),
            "move_up" => StandardAction::Op(MoveUp),
            "move_down" => StandardAction::Op(MoveDown),
            "move_word_left" => StandardAction::Op(MoveWordLeft),
            "move_word_right" => StandardAction::Op(MoveWordRight),
            "move_line_up" => StandardAction::Op(MoveLineUp),
            "move_line_down" => StandardAction::Op(MoveLineDown),
            "move_line_start" => StandardAction::Op(MoveLineStart),
            "move_line_end" => StandardAction::Op(MoveLineEnd),
            "move_buffer_start" => StandardAction::Op(MoveBufferStart),
            "move_buffer_end" => StandardAction::Op(MoveBufferEnd),
            "page_up" => StandardAction::Op(PageUp),
            "page_down" => StandardAction::Op(PageDown),
            "insert_newline" => StandardAction::Op(InsertNewline),
            _ => return None,
        })
    }
}

#[derive(Debug)]
pub struct StandardInputHandler {
    tab_width: usize,
    /// `[keys.standard]` overrides — user rebindings. Consulted BEFORE
    /// the hardcoded logic so users can remap or unbind any chord.
    /// Parsed once at construction. Empty when no config entries exist.
    overrides: HashMap<Chord, StandardAction>,
}

impl StandardInputHandler {
    pub fn new(cfg: &Config) -> Self {
        // Merge `[keys.global]` + `[keys.standard]` in that order so a
        // standard-specific override wins. Same precedence as the
        // app-level `Keymap::build`.
        let mut overrides: HashMap<Chord, StandardAction> = HashMap::new();
        for section in ["global", "standard"] {
            let Some(entries) = cfg.keys.get(section) else {
                continue;
            };
            for (spec, action) in entries {
                let Some(ev) = parse_key_spec(spec) else {
                    eprintln!("mnml: [keys.{section}] `{spec}` doesn't parse as a chord — ignored",);
                    continue;
                };
                let Some(parsed) = StandardAction::parse(action) else {
                    // Unknown action names go to the app-level Keymap,
                    // not here. Skip silently so app.* commands don't
                    // trigger a warning.
                    continue;
                };
                overrides.insert(Chord::of(&ev), parsed);
            }
        }
        StandardInputHandler {
            tab_width: cfg.editor.tab_width.max(1),
            overrides,
        }
    }

    /// Look up a chord in the config overrides. Returns:
    /// - `Some(InputResult::…)` — fire the override (may be Ignored if unbound).
    /// - `None` — no override registered; caller falls through to hardcoded logic.
    fn override_lookup(&self, key: &KeyEvent) -> Option<InputResult> {
        let chord = Chord::of(key);
        Some(match self.overrides.get(&chord)? {
            StandardAction::Op(op) => InputResult::Ops(vec![op.clone()]),
            StandardAction::Ops(ops) => InputResult::Ops(ops.clone()),
            StandardAction::App(cmd) => InputResult::App(cmd.clone()),
            StandardAction::Unbound => InputResult::Ignored,
        })
    }
}

impl InputHandler for StandardInputHandler {
    fn handle_key(&mut self, key: KeyEvent, ctx: &EditCtx) -> InputResult {
        use EditOp::*;

        // Config-driven overrides win over the hardcoded logic. Any chord
        // registered in `[keys.global]` or `[keys.standard]` fires the
        // configured action (or `Ignored` when unbound), so users can
        // rebind chords WITHOUT touching source. Plain typed characters
        // (no modifiers) bypass the override table so a stray
        // `"a" = "cut_selection"` in the config doesn't turn a-key into
        // a cut — chords the override table handles are the ones with
        // at least one modifier or a named key.
        let is_plain_typed = matches!(key.code, KeyCode::Char(_))
            && !key.modifiers.contains(KeyModifiers::CONTROL)
            && !key.modifiers.contains(KeyModifiers::ALT)
            && !key.modifiers.contains(KeyModifiers::SUPER);
        if !is_plain_typed && let Some(result) = self.override_lookup(&key) {
            return result;
        }

        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);

        // A plain typed character (no Ctrl/Alt/Super). vscode-user SEV-2 —
        // SUPER guard prevents Cmd+letter from inserting on Kitty /
        // WezTerm / any macOS terminal that forwards SUPER (the user
        // means to hit Cmd+P, gets a literal `p` in their file).
        if let KeyCode::Char(c) = key.code
            && !ctrl
            && !alt
            && !key.modifiers.contains(KeyModifiers::SUPER)
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
                // qa-7th vscode SEV-2 2026-06-30 — was SelectLine
                // (vim V semantics — cursor stays put, only
                // line_start..cursor highlights). Standard mode
                // matches VS Code: cursor jumps to line end so
                // the WHOLE line shows selected regardless of
                // cursor column.
                'l' => InputResult::Ops(vec![SelectLineToEnd]),
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
            // VS Code parity (bug-hunt seed #274 from 2026-06-07):
            // Shift+Alt+↓ / ↑ duplicates the current line down / up.
            // Plain Alt+↓ / ↑ stays "move line" — distinct from
            // Ctrl+Shift+D (which also duplicates but doesn't choose
            // direction).
            KeyCode::Up if alt && shift => InputResult::Ops(vec![DuplicateLine, MoveUp]),
            KeyCode::Down if alt && shift => InputResult::Ops(vec![DuplicateLine]),
            KeyCode::Up if alt => InputResult::Ops(vec![MoveLineUp]),
            KeyCode::Down if alt => InputResult::Ops(vec![MoveLineDown]),
            // Vim-aligned aliases for line shift in standard mode too.
            KeyCode::Char('k' | 'K') if alt => InputResult::Ops(vec![MoveLineUp]),
            KeyCode::Char('j' | 'J') if alt => InputResult::Ops(vec![MoveLineDown]),
            KeyCode::Up => mv(MoveUp),
            KeyCode::Down => mv(MoveDown),

            KeyCode::Home if ctrl && !alt => mv(MoveBufferStart),
            // vscode-user 2026-06-28 SEV-2: Ctrl+End in VS Code
            // lands at the END of the last line, not the start.
            // MoveBufferEnd is vim G semantics (start of last
            // line, intentional). Compose with MoveLineEnd for the
            // standard-mode meaning.
            //
            // vscode-user 2026-07-10 SEV-2 follow-up: this branch
            // used to bypass the `mv` helper entirely, so
            // Ctrl+Shift+End didn't extend the selection (missing
            // SelectStart) and plain Ctrl+End didn't clear a
            // pre-existing selection (missing SelectClear). Mirror
            // `mv`'s shift/has_selection logic but keep the two-op
            // motion composition.
            KeyCode::End if ctrl && !alt => {
                let motion = vec![MoveBufferEnd, MoveLineEnd];
                if shift {
                    if ctx.has_selection {
                        InputResult::Ops(motion)
                    } else {
                        let mut ops = vec![SelectStart];
                        ops.extend(motion);
                        InputResult::Ops(ops)
                    }
                } else {
                    let mut ops = vec![SelectClear];
                    ops.extend(motion);
                    InputResult::Ops(ops)
                }
            }
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

    /// Shift+Alt+↓ / ↑ duplicate the current line (VS Code parity,
    /// bug-hunt seed #274). Plain Alt+↓ / ↑ still moves the line —
    /// the Shift modifier is what distinguishes "duplicate" from
    /// "move."
    #[test]
    fn shift_alt_down_duplicates_line() {
        let mods = KeyModifiers::SHIFT | KeyModifiers::ALT;
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Down, mods), &ctx(false))),
            vec![EditOp::DuplicateLine]
        );
        // Shift+Alt+Up: duplicate, then move up to land cursor on
        // the new copy above (matches VS Code's "duplicate up").
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Up, mods), &ctx(false))),
            vec![EditOp::DuplicateLine, EditOp::MoveUp]
        );
        // Plain Alt+Down still moves the line (didn't regress).
        assert_eq!(
            ops(h().handle_key(key(KeyCode::Down, KeyModifiers::ALT), &ctx(false))),
            vec![EditOp::MoveLineDown]
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

    // ── [keys.standard] config overrides ──────────────────────────

    fn cfg_with_binding(spec: &str, action: &str) -> Config {
        let mut cfg = Config::default();
        let mut section = std::collections::BTreeMap::new();
        section.insert(spec.to_string(), action.to_string());
        cfg.keys.insert("standard".to_string(), section);
        cfg
    }

    #[test]
    fn config_override_replaces_a_default_chord() {
        // Rebind Ctrl+A from SelectAll to Undo — deliberately weird so
        // the test proves the override wins.
        let cfg = cfg_with_binding("ctrl+a", "undo");
        let mut h = StandardInputHandler::new(&cfg);
        assert_eq!(
            ops(h.handle_key(key(KeyCode::Char('a'), KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::Undo]
        );
    }

    #[test]
    fn config_override_none_unbinds_a_chord() {
        let cfg = cfg_with_binding("ctrl+z", "none");
        let mut h = StandardInputHandler::new(&cfg);
        assert!(matches!(
            h.handle_key(key(KeyCode::Char('z'), KeyModifiers::CONTROL), &ctx(false)),
            InputResult::Ignored
        ));
    }

    #[test]
    fn config_override_supports_composite_sequences() {
        // VS Code's `ctrl+enter` = "move to line end, then insert newline".
        let cfg = cfg_with_binding("ctrl+enter", "move_line_end; insert_newline");
        let mut h = StandardInputHandler::new(&cfg);
        assert_eq!(
            ops(h.handle_key(key(KeyCode::Enter, KeyModifiers::CONTROL), &ctx(false))),
            vec![EditOp::MoveLineEnd, EditOp::InsertNewline]
        );
    }

    #[test]
    fn config_override_leaves_plain_typing_untouched() {
        // Even if the user tries to bind `a` to something, plain
        // character keys should still insert their literal char.
        let cfg = cfg_with_binding("a", "undo");
        let mut h = StandardInputHandler::new(&cfg);
        assert_eq!(
            ops(h.handle_key(key(KeyCode::Char('a'), KeyModifiers::NONE), &ctx(false))),
            vec![EditOp::InsertChar('a')]
        );
    }

    #[test]
    fn config_override_can_bind_a_new_chord() {
        // Chord that has no default binding in the standard handler:
        // Ctrl+Shift+K. Should be Ignored without config, and the
        // configured action with config.
        let mut without = StandardInputHandler::new(&Config::default());
        assert!(matches!(
            without.handle_key(
                key(
                    KeyCode::Char('k'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                &ctx(false)
            ),
            InputResult::Ignored
        ));
        let cfg = cfg_with_binding("ctrl+shift+k", "delete_line");
        let mut with = StandardInputHandler::new(&cfg);
        assert_eq!(
            ops(with.handle_key(
                key(
                    KeyCode::Char('k'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                &ctx(false)
            )),
            vec![EditOp::DeleteLine]
        );
    }

    #[test]
    fn global_section_bindings_apply_to_standard_handler() {
        // `[keys.global]` also overlays — a global entry should
        // reach the standard handler.
        let mut cfg = Config::default();
        let mut section = std::collections::BTreeMap::new();
        section.insert("ctrl+shift+p".to_string(), "duplicate_line".to_string());
        cfg.keys.insert("global".to_string(), section);
        let mut h = StandardInputHandler::new(&cfg);
        assert_eq!(
            ops(h.handle_key(
                key(
                    KeyCode::Char('p'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                &ctx(false)
            )),
            vec![EditOp::DuplicateLine]
        );
    }
}
