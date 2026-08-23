//! Runtime UI / editor toggles that mutate `[ui]` / `[editor]` config
//! fields. Every `set_*` here persists to the user config so an
//! interactive off/on survives restart; the paired `toggle_*` is a
//! thin flip helper. Palette + menu-bar + right-click + `:set` all
//! funnel through these.
//!
//! Extracted from `src/app/mod.rs` — see `persist_config_scalar` in
//! `src/app/discovery.rs` for the shared writer.

use crate::app::App;
use crate::pane::Pane;

impl App {
    // ─── side-panel auto-hide predicate ────────────────────────────
    /// Task #891 — true when the terminal is narrower than
    /// `[ui] auto_hide_narrow_width` and the auto-hide feature is
    /// enabled (`> 0`). Consumed by `ui/mod.rs::draw` (both the
    /// split-carve sites AND the palette-bar toggle chips) so all
    /// three surfaces agree on whether the panels are visible in
    /// the current frame. Persistent `tree_visible` /
    /// `right_panel_visible` state is untouched — this is a
    /// per-frame OVERRIDE, not a mutation.
    pub fn side_panels_auto_hidden(&self, area_width: u16) -> bool {
        let threshold = self.config.ui.auto_hide_narrow_width;
        threshold > 0 && area_width < threshold
    }

    // ─── keymap (vim ⇄ standard) ────────────────────────────────────
    /// Swap every editor buffer's input handler to `style` (`"vim"` | `"standard"`),
    /// remember it as the new default, and toast the result.
    pub fn set_input_style(&mut self, style: &str) {
        let style = match style {
            "vim" => "vim",
            "standard" | "vscode" => "standard",
            other => {
                self.toast(format!("unknown input style: {other}"));
                return;
            }
        };
        self.config.editor.input_style = style.to_string();
        let _ = crate::app::discovery::persist_editor_string("input_style", style);
        for pane in &mut self.panes {
            if let Pane::Editor(b) = pane {
                b.input = crate::input::make_handler_for(style, &self.config);
            }
        }
        // A `[keys.<style>]` section may rebind chords — re-resolve the table.
        self.keymap = crate::input::keymap::Keymap::build(&self.config);
        self.toast(format!("input: {style}"));
    }
    pub fn toggle_input_style(&mut self) {
        let next = if self.is_vim_mode() {
            "standard"
        } else {
            "vim"
        };
        self.set_input_style(next);
    }

    /// Turn hybrid relative line numbers on/off (`:set [no]relativenumber`,
    /// `view.toggle_relative_numbers`).
    pub fn set_relative_line_numbers(&mut self, on: bool) {
        self.config.ui.relative_line_numbers = on;
        let _ = crate::app::discovery::persist_ui_bool("relative_line_numbers", on);
        self.toast(if on {
            "relative line numbers: on"
        } else {
            "relative line numbers: off"
        });
    }
    pub fn toggle_relative_line_numbers(&mut self) {
        self.set_relative_line_numbers(!self.config.ui.relative_line_numbers);
    }

    /// nvchad-parity #1142 (2026-08-22) — line-number gutter toggle,
    /// counterpart to the existing relative-numbers toggle. Persists.
    pub fn set_line_numbers(&mut self, on: bool) {
        self.config.ui.line_numbers = on;
        let _ = crate::app::discovery::persist_ui_bool("line_numbers", on);
        self.toast(if on {
            "line numbers: on"
        } else {
            "line numbers: off"
        });
    }
    pub fn toggle_line_numbers(&mut self) {
        self.set_line_numbers(!self.config.ui.line_numbers);
    }

    /// Toggle visible whitespace markers (`:set list` / `:set nolist`).
    pub fn set_show_whitespace(&mut self, on: bool) {
        self.config.ui.show_whitespace = on;
        let _ = crate::app::discovery::persist_ui_bool("show_whitespace", on);
        self.toast(if on {
            "whitespace: on"
        } else {
            "whitespace: off"
        });
    }
    pub fn toggle_show_whitespace(&mut self) {
        self.set_show_whitespace(!self.config.ui.show_whitespace);
    }

    /// Toggle rainbow-brackets (`:set rainbow` / `:set norainbow`).
    pub fn set_bracket_rainbow(&mut self, on: bool) {
        self.config.ui.bracket_rainbow = on;
        let _ = crate::app::discovery::persist_ui_bool("bracket_rainbow", on);
        self.toast(if on {
            "rainbow brackets: on"
        } else {
            "rainbow brackets: off"
        });
    }
    pub fn toggle_bracket_rainbow(&mut self) {
        self.set_bracket_rainbow(!self.config.ui.bracket_rainbow);
    }

    /// Toggle the editor scrollbar (`:set scrollbar` / `:set noscrollbar`).
    pub fn set_scrollbar(&mut self, on: bool) {
        self.config.ui.scrollbar = on;
        let _ = crate::app::discovery::persist_ui_bool("scrollbar", on);
        self.toast(if on {
            "scrollbar: on"
        } else {
            "scrollbar: off"
        });
    }
    pub fn toggle_scrollbar(&mut self) {
        self.set_scrollbar(!self.config.ui.scrollbar);
    }

    /// `:set wrap` / `:set nowrap` — toggle visual line wrapping for long
    /// lines. Char-break MVP (no word-boundary heuristic); h_scroll is
    /// forced to 0 in `editor_view` when wrap is on.
    pub fn set_wrap(&mut self, on: bool) {
        self.config.ui.wrap = on;
        let _ = crate::app::discovery::persist_ui_bool("wrap", on);
        self.toast(if on { "wrap: on" } else { "wrap: off" });
    }
    pub fn toggle_wrap(&mut self) {
        self.set_wrap(!self.config.ui.wrap);
    }

    /// `:set wsdots` / `view.toggle_workspace_dots` — flip the
    /// `[ui] show_workspace_dots` config field. R6 R2 request
    /// 2026-08-09: opt-out for the `● ` / `○ ` workspace-status
    /// markers to the left of every workspace-root row. When off,
    /// the two cells reclaim as label width and the active/inactive
    /// distinction lives in the label's color + weight.
    pub fn toggle_workspace_dots(&mut self) {
        let new_value = !self.config.ui.show_workspace_dots;
        self.set_workspace_dots(new_value);
    }

    /// Set + persist `[ui] show_workspace_dots`. Every mutation
    /// site (palette toggle, menu-bar entry, right-click, `:set
    /// wsdots` / `:set nowsdots`) funnels through here so the
    /// disk write can't be forgotten — the reason the toggle
    /// used to revert on restart.
    pub fn set_workspace_dots(&mut self, value: bool) {
        self.config.ui.show_workspace_dots = value;
        let msg = if value {
            "workspace dots: on"
        } else {
            "workspace dots: off"
        };
        match crate::app::discovery::persist_ui_bool("show_workspace_dots", value) {
            Ok(_) => self.toast(msg),
            Err(e) => self.toast(format!("{msg} (not saved: {e})")),
        }
    }

    /// `:set [no]todohl` / `view.toggle_todo_highlight` — paint
    /// TODO/FIXME/HACK/XXX keywords in bright red across the editor.
    pub fn set_todo_highlight(&mut self, on: bool) {
        self.config.ui.highlight_todo_keywords = on;
        let _ = crate::app::discovery::persist_ui_bool("highlight_todo_keywords", on);
        self.toast(if on {
            "todo highlight: on"
        } else {
            "todo highlight: off"
        });
    }
    pub fn toggle_todo_highlight(&mut self) {
        self.set_todo_highlight(!self.config.ui.highlight_todo_keywords);
    }

    pub fn set_render_markdown(&mut self, on: bool) {
        self.config.ui.render_markdown = on;
        let _ = crate::app::discovery::persist_ui_bool("render_markdown", on);
        self.toast(if on {
            "render markdown: on"
        } else {
            "render markdown: off"
        });
    }
    pub fn toggle_render_markdown(&mut self) {
        self.set_render_markdown(!self.config.ui.render_markdown);
    }

    pub fn set_sticky_context(&mut self, on: bool) {
        self.config.ui.sticky_context = on;
        let _ = crate::app::discovery::persist_ui_bool("sticky_context", on);
        self.toast(if on {
            "sticky context: on"
        } else {
            "sticky context: off"
        });
    }
    pub fn toggle_sticky_context(&mut self) {
        self.set_sticky_context(!self.config.ui.sticky_context);
    }

    /// Toggle the editor breadcrumb row (`:set [no]breadcrumb`).
    pub fn set_breadcrumb(&mut self, on: bool) {
        self.config.editor.breadcrumb = on;
        let _ = crate::app::discovery::persist_editor_bool("breadcrumb", on);
        self.toast(if on {
            "breadcrumb: on"
        } else {
            "breadcrumb: off"
        });
    }
    pub fn toggle_breadcrumb(&mut self) {
        self.set_breadcrumb(!self.config.editor.breadcrumb);
    }

    /// Toggle bracket / quote auto-pairing (`:set [no]autopair`).
    /// Also propagates the new value onto every open editor's editor instance
    /// so the change takes effect for the buffers already open, not just for
    /// future opens.
    pub fn set_auto_pair(&mut self, on: bool) {
        self.config.editor.auto_pair = on;
        let _ = crate::app::discovery::persist_editor_bool("auto_pair", on);
        for p in self.panes.iter_mut() {
            if let Pane::Editor(b) = p {
                b.editor.auto_pair = on;
            }
        }
        self.toast(if on {
            "auto-pair: on"
        } else {
            "auto-pair: off"
        });
    }
    pub fn toggle_auto_pair(&mut self) {
        self.set_auto_pair(!self.config.editor.auto_pair);
    }

    /// Toggle trailing-whitespace highlight (`:set [no]trailing`).
    pub fn set_highlight_trailing_ws(&mut self, on: bool) {
        self.config.ui.highlight_trailing_ws = on;
        let _ = crate::app::discovery::persist_ui_bool("highlight_trailing_ws", on);
        self.toast(if on {
            "trailing ws: highlighted"
        } else {
            "trailing ws: off"
        });
    }
    pub fn toggle_highlight_trailing_ws(&mut self) {
        self.set_highlight_trailing_ws(!self.config.ui.highlight_trailing_ws);
    }

    /// Toggle "highlight word under cursor" (`:set [no]hlword`).
    pub fn set_highlight_word_under_cursor(&mut self, on: bool) {
        self.config.ui.highlight_word_under_cursor = on;
        let _ = crate::app::discovery::persist_ui_bool("highlight_word_under_cursor", on);
        self.toast(if on {
            "highlight word: on"
        } else {
            "highlight word: off"
        });
    }
    pub fn toggle_highlight_word_under_cursor(&mut self) {
        self.set_highlight_word_under_cursor(!self.config.ui.highlight_word_under_cursor);
    }

    pub fn set_color_column(&mut self, col: usize) {
        self.config.ui.color_column = col;
        let _ = crate::app::discovery::persist_ui_int("color_column", col as i64);
        if col == 0 {
            self.toast("colorcolumn: off");
        } else {
            self.toast(format!("colorcolumn: {col}"));
        }
    }
    pub fn toggle_color_column(&mut self) {
        let next = if self.config.ui.color_column == 0 {
            80
        } else {
            0
        };
        self.set_color_column(next);
    }
}
