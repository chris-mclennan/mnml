//! Settings overlay — schema + state + apply dispatcher.
//!
//! The renderer lives at `src/ui/settings_overlay.rs`. See the "Family
//! settings UI convention" in `CLAUDE.md` for the visual idiom we
//! match across mnml + tmnl + mixr.
//!
//! Design notes:
//! - `build_settings(&Config)` recomputes the row list each render —
//!   no separate schema cache. Cheap (a Vec of ~20 small structs);
//!   keeps the source of truth as the config itself.
//! - `apply_setting(&mut Config, key, opt_idx)` is the single
//!   chokepoint for writes. Match-arm dispatch by `key` — adding a
//!   row means adding to `build_settings` + an arm here.
//! - On open, `SettingsOverlayState` snapshots the Config as
//!   `original` so Esc/cancel can revert.
//! - v1: discrete-choice rows only. Number / Text / Color row kinds
//!   are v2 — when we add them, extend `SettingKind` instead of
//!   piling more match arms onto `apply_setting`.

use super::*;

/// State carried across renders while the settings overlay is open.
/// `None` on `App.settings_overlay` ⇒ overlay closed.
#[derive(Debug, Clone)]
pub struct SettingsOverlayState {
    /// The Config snapshot taken at open time. `Esc` reverts to this.
    pub original: Config,
    /// Currently-focused row, indexes into the rendered row list.
    /// Section headers are not rows for this counter — `selected_row`
    /// only counts `SettingRow`s.
    pub selected_row: usize,
}

impl SettingsOverlayState {
    pub fn open(cfg: &Config) -> Self {
        Self {
            original: cfg.clone(),
            selected_row: 0,
        }
    }
}

/// One item in the rendered settings list. Either a section header
/// (decorative, not focusable) or a row (focusable, edits a setting).
#[derive(Debug, Clone)]
pub enum SettingItem {
    /// Section header — painted as `── <name> ──` on the row above
    /// the first item of that section.
    Section(&'static str),
    /// An editable setting row.
    Row(SettingRow),
}

/// One editable setting in the overlay.
///
/// `key` is the stable identifier `apply_setting` dispatches on —
/// renaming a key breaks dispatch.
#[derive(Debug, Clone)]
pub struct SettingRow {
    pub key: &'static str,
    pub label: &'static str,
    pub options: Vec<String>,
    /// Index into `options` for the value currently in the live
    /// `Config`. The renderer paints this as `[bracketed]`.
    pub current_idx: usize,
    /// `true` when the row's current value differs from the
    /// equivalent `Config::default()` slot. Drives the `*` modified
    /// marker.
    pub modified: bool,
}

/// Sentinel `key` value for the "Reset all to defaults" row. Treated
/// specially by both the renderer (no choice list) and the dispatcher.
pub const RESET_ALL_KEY: &str = "__reset_all__";

/// Build the full settings list for the current `Config`. Recomputed
/// per render — cheap.
pub fn build_settings(cfg: &Config) -> Vec<SettingItem> {
    let d = Config::default();
    let mut out = Vec::new();

    // ── UI ─────────────────────────────────────────────────────────
    out.push(SettingItem::Section("UI"));

    // Line numbers — combined relative + line_numbers into one
    // 3-state choice. Maps:
    //   "relative" → relative_line_numbers=true,  line_numbers=true
    //   "absolute" → relative_line_numbers=false, line_numbers=true
    //   "off"      → line_numbers=false (relative ignored)
    let line_numbers_idx = if !cfg.ui.line_numbers {
        2
    } else if cfg.ui.relative_line_numbers {
        0
    } else {
        1
    };
    let line_numbers_default_idx = if !d.ui.line_numbers {
        2
    } else if d.ui.relative_line_numbers {
        0
    } else {
        1
    };
    out.push(SettingItem::Row(SettingRow {
        key: "ui.line_numbers",
        label: "Line numbers",
        options: vec!["relative".into(), "absolute".into(), "off".into()],
        current_idx: line_numbers_idx,
        modified: line_numbers_idx != line_numbers_default_idx,
    }));

    out.push(bool_row(
        "ui.cursor_line",
        "Cursor line",
        cfg.ui.cursor_line,
        d.ui.cursor_line,
    ));
    out.push(bool_row(
        "ui.scrollbar",
        "Scrollbar",
        cfg.ui.scrollbar,
        d.ui.scrollbar,
    ));
    out.push(bool_row(
        "ui.syntax",
        "Syntax highlighting",
        cfg.ui.syntax,
        d.ui.syntax,
    ));
    out.push(bool_row(
        "ui.show_whitespace",
        "Show whitespace",
        cfg.ui.show_whitespace,
        d.ui.show_whitespace,
    ));
    out.push(bool_row(
        "ui.bracket_rainbow",
        "Bracket rainbow",
        cfg.ui.bracket_rainbow,
        d.ui.bracket_rainbow,
    ));
    out.push(bool_row(
        "ui.highlight_trailing_ws",
        "Highlight trailing whitespace",
        cfg.ui.highlight_trailing_ws,
        d.ui.highlight_trailing_ws,
    ));
    out.push(bool_row(
        "ui.clock",
        "Statusline clock",
        cfg.ui.clock,
        d.ui.clock,
    ));
    out.push(bool_row(
        "ui.highlight_word_under_cursor",
        "Highlight word under cursor",
        cfg.ui.highlight_word_under_cursor,
        d.ui.highlight_word_under_cursor,
    ));
    out.push(bool_row("ui.wrap", "Soft wrap", cfg.ui.wrap, d.ui.wrap));
    out.push(bool_row(
        "ui.sticky_context",
        "Sticky scope context",
        cfg.ui.sticky_context,
        d.ui.sticky_context,
    ));
    out.push(bool_row(
        "ui.render_markdown",
        "Inline markdown rendering",
        cfg.ui.render_markdown,
        d.ui.render_markdown,
    ));
    out.push(bool_row(
        "ui.auto_md_preview",
        "Auto-open markdown preview",
        cfg.ui.auto_md_preview,
        d.ui.auto_md_preview,
    ));

    // Picker position — center vs top.
    let picker_idx = if cfg.ui.picker_position == "top" {
        1
    } else {
        0
    };
    let picker_default_idx = if d.ui.picker_position == "top" { 1 } else { 0 };
    out.push(SettingItem::Row(SettingRow {
        key: "ui.picker_position",
        label: "Palette / picker position",
        options: vec!["center".into(), "top".into()],
        current_idx: picker_idx,
        modified: picker_idx != picker_default_idx,
    }));

    // ── Editor ─────────────────────────────────────────────────────
    out.push(SettingItem::Section("Editor"));

    // Input style — vim vs standard.
    let input_idx = if cfg.editor.input_style == "vim" {
        0
    } else {
        1
    };
    let input_default_idx = if d.editor.input_style == "vim" { 0 } else { 1 };
    out.push(SettingItem::Row(SettingRow {
        key: "editor.input_style",
        label: "Input style",
        options: vec!["vim".into(), "standard".into()],
        current_idx: input_idx,
        modified: input_idx != input_default_idx,
    }));

    // Tab width — 2 / 4 / 8.
    let tab_idx = match cfg.editor.tab_width {
        2 => 0,
        4 => 1,
        8 => 2,
        _ => 1, // out-of-range live value falls back to the 4-tab default in the UI
    };
    let tab_default_idx = match d.editor.tab_width {
        2 => 0,
        4 => 1,
        8 => 2,
        _ => 1,
    };
    out.push(SettingItem::Row(SettingRow {
        key: "editor.tab_width",
        label: "Tab width",
        options: vec!["2".into(), "4".into(), "8".into()],
        current_idx: tab_idx,
        modified: tab_idx != tab_default_idx,
    }));

    out.push(bool_row(
        "editor.trim_trailing_ws_on_save",
        "Trim trailing whitespace on save",
        cfg.editor.trim_trailing_ws_on_save,
        d.editor.trim_trailing_ws_on_save,
    ));
    out.push(bool_row(
        "editor.auto_pair",
        "Auto-pair brackets / quotes",
        cfg.editor.auto_pair,
        d.editor.auto_pair,
    ));
    out.push(bool_row(
        "editor.auto_indent",
        "Auto-indent on Enter",
        cfg.editor.auto_indent,
        d.editor.auto_indent,
    ));
    out.push(bool_row(
        "editor.format_on_save",
        "Format on save (LSP)",
        cfg.editor.format_on_save,
        d.editor.format_on_save,
    ));
    out.push(bool_row(
        "editor.inlay_hints",
        "Inlay hints",
        cfg.editor.inlay_hints,
        d.editor.inlay_hints,
    ));
    out.push(bool_row(
        "editor.code_lens",
        "Code lens",
        cfg.editor.code_lens,
        d.editor.code_lens,
    ));
    out.push(bool_row(
        "editor.breadcrumb",
        "Breadcrumb",
        cfg.editor.breadcrumb,
        d.editor.breadcrumb,
    ));

    // ── Session ─────────────────────────────────────────────────────
    out.push(SettingItem::Section("Session"));
    out.push(bool_row(
        "session.restore",
        "Restore open buffers on launch",
        cfg.session.restore,
        d.session.restore,
    ));

    // ── Reset ─────────────────────────────────────────────────────
    out.push(SettingItem::Section("Reset"));
    out.push(SettingItem::Row(SettingRow {
        key: RESET_ALL_KEY,
        label: "Reset all to defaults",
        options: Vec::new(), // sentinel — no options
        current_idx: 0,
        modified: false,
    }));

    out
}

fn bool_row(key: &'static str, label: &'static str, cur: bool, default: bool) -> SettingItem {
    SettingItem::Row(SettingRow {
        key,
        label,
        options: vec!["on".into(), "off".into()],
        current_idx: if cur { 0 } else { 1 },
        modified: cur != default,
    })
}

/// Apply a row's choice to the live `Config`. `key` matches
/// `SettingRow.key`; `opt_idx` indexes the row's `options`.
/// Unknown keys are no-op'd (defensive — a stale shortcut shouldn't
/// crash mnml). Returns `true` when the value actually changed.
pub fn apply_setting(cfg: &mut Config, key: &str, opt_idx: usize) -> bool {
    match key {
        "ui.line_numbers" => {
            let (rel, on) = match opt_idx {
                0 => (true, true),   // relative
                1 => (false, true),  // absolute
                _ => (false, false), // off
            };
            let changed = cfg.ui.relative_line_numbers != rel || cfg.ui.line_numbers != on;
            cfg.ui.relative_line_numbers = rel;
            cfg.ui.line_numbers = on;
            changed
        }
        "ui.cursor_line" => set_bool(&mut cfg.ui.cursor_line, opt_idx),
        "ui.scrollbar" => set_bool(&mut cfg.ui.scrollbar, opt_idx),
        "ui.syntax" => set_bool(&mut cfg.ui.syntax, opt_idx),
        "ui.show_whitespace" => set_bool(&mut cfg.ui.show_whitespace, opt_idx),
        "ui.bracket_rainbow" => set_bool(&mut cfg.ui.bracket_rainbow, opt_idx),
        "ui.highlight_trailing_ws" => set_bool(&mut cfg.ui.highlight_trailing_ws, opt_idx),
        "ui.clock" => set_bool(&mut cfg.ui.clock, opt_idx),
        "ui.highlight_word_under_cursor" => {
            set_bool(&mut cfg.ui.highlight_word_under_cursor, opt_idx)
        }
        "ui.wrap" => set_bool(&mut cfg.ui.wrap, opt_idx),
        "ui.sticky_context" => set_bool(&mut cfg.ui.sticky_context, opt_idx),
        "ui.render_markdown" => set_bool(&mut cfg.ui.render_markdown, opt_idx),
        "ui.auto_md_preview" => set_bool(&mut cfg.ui.auto_md_preview, opt_idx),
        "ui.picker_position" => {
            let new = if opt_idx == 1 { "top" } else { "center" };
            let changed = cfg.ui.picker_position != new;
            cfg.ui.picker_position = new.to_string();
            changed
        }
        "editor.input_style" => {
            let new = if opt_idx == 0 { "vim" } else { "standard" };
            let changed = cfg.editor.input_style != new;
            cfg.editor.input_style = new.to_string();
            changed
        }
        "editor.tab_width" => {
            let new: usize = match opt_idx {
                0 => 2,
                1 => 4,
                _ => 8,
            };
            let changed = cfg.editor.tab_width != new;
            cfg.editor.tab_width = new;
            changed
        }
        "editor.trim_trailing_ws_on_save" => {
            set_bool(&mut cfg.editor.trim_trailing_ws_on_save, opt_idx)
        }
        "editor.auto_pair" => set_bool(&mut cfg.editor.auto_pair, opt_idx),
        "editor.auto_indent" => set_bool(&mut cfg.editor.auto_indent, opt_idx),
        "editor.format_on_save" => set_bool(&mut cfg.editor.format_on_save, opt_idx),
        "editor.inlay_hints" => set_bool(&mut cfg.editor.inlay_hints, opt_idx),
        "editor.code_lens" => set_bool(&mut cfg.editor.code_lens, opt_idx),
        "editor.breadcrumb" => set_bool(&mut cfg.editor.breadcrumb, opt_idx),
        "session.restore" => set_bool(&mut cfg.session.restore, opt_idx),
        _ => false,
    }
}

/// `opt_idx == 0` ⇒ `true`; anything else ⇒ `false`. Returns whether
/// the value changed.
fn set_bool(slot: &mut bool, opt_idx: usize) -> bool {
    let new = opt_idx == 0;
    let changed = *slot != new;
    *slot = new;
    changed
}

impl App {
    /// Open the settings overlay. Snapshots the current config for
    /// revert-on-cancel. Idempotent — re-opening replaces the snapshot
    /// (so a second `view.settings` from inside the overlay would
    /// "commit" the current state as the new baseline).
    pub fn open_settings_overlay(&mut self) {
        self.settings_overlay = Some(SettingsOverlayState::open(&self.config));
    }

    /// Close the settings overlay, keeping all current changes (the
    /// snapshot in `original` is discarded). The Enter / save path.
    pub fn close_settings_overlay_save(&mut self) {
        self.settings_overlay = None;
    }

    /// Close the settings overlay, reverting the live config back to
    /// the snapshot taken on open. The Esc / cancel path.
    pub fn close_settings_overlay_cancel(&mut self) {
        if let Some(state) = self.settings_overlay.take() {
            self.config = state.original;
        }
    }

    /// Move the focused row by `delta` (positive = down). Skips
    /// section headers — `selected_row` only counts editable rows.
    pub fn settings_move_row(&mut self, delta: isize) {
        if let Some(state) = self.settings_overlay.as_mut() {
            let items = build_settings(&self.config);
            let row_count = items
                .iter()
                .filter(|i| matches!(i, SettingItem::Row(_)))
                .count();
            if row_count == 0 {
                return;
            }
            let new = (state.selected_row as isize + delta).rem_euclid(row_count as isize);
            state.selected_row = new as usize;
        }
    }

    /// Adjust the focused row's value by `delta` (-1 = left, 1 = right).
    /// On the reset-all sentinel row, fires the reset directly.
    pub fn settings_adjust_value(&mut self, delta: isize) {
        let Some(state) = self.settings_overlay.as_ref() else {
            return;
        };
        let items = build_settings(&self.config);
        let rows: Vec<&SettingRow> = items
            .iter()
            .filter_map(|i| match i {
                SettingItem::Row(r) => Some(r),
                _ => None,
            })
            .collect();
        let Some(row) = rows.get(state.selected_row) else {
            return;
        };
        // Reset-all sentinel — `←/→` doesn't make sense; ignore. The
        // user fires it with Enter.
        if row.key == RESET_ALL_KEY {
            return;
        }
        if row.options.is_empty() {
            return;
        }
        let n = row.options.len() as isize;
        let new_idx = (row.current_idx as isize + delta).rem_euclid(n) as usize;
        let key = row.key;
        apply_setting(&mut self.config, key, new_idx);
    }

    /// `Enter` on the focused row. For the reset-all sentinel, resets
    /// every setting to its default. For normal rows, cycles forward
    /// (equivalent to `→`).
    pub fn settings_enter_row(&mut self) {
        let Some(state) = self.settings_overlay.as_ref() else {
            return;
        };
        let items = build_settings(&self.config);
        let rows: Vec<&SettingRow> = items
            .iter()
            .filter_map(|i| match i {
                SettingItem::Row(r) => Some(r),
                _ => None,
            })
            .collect();
        let Some(row) = rows.get(state.selected_row) else {
            return;
        };
        if row.key == RESET_ALL_KEY {
            // Wipe the live config back to defaults. `original` stays
            // — Esc would still revert to the pre-open snapshot if
            // the user changes their mind.
            self.config = Config::default();
            self.toast("settings: all reset to defaults");
            return;
        }
        // Cycle forward like a `→` press.
        self.settings_adjust_value(1);
    }

    /// `r` on the focused row — reset just this row's setting to its
    /// `Config::default()` value.
    pub fn settings_reset_row(&mut self) {
        let Some(state) = self.settings_overlay.as_ref() else {
            return;
        };
        let items = build_settings(&self.config);
        let rows: Vec<&SettingRow> = items
            .iter()
            .filter_map(|i| match i {
                SettingItem::Row(r) => Some(r),
                _ => None,
            })
            .collect();
        let Some(row) = rows.get(state.selected_row) else {
            return;
        };
        if row.key == RESET_ALL_KEY {
            return;
        }
        // Find the default's current_idx for this key by building a
        // default settings list and copying out the same row.
        let default_cfg = Config::default();
        let default_items = build_settings(&default_cfg);
        let default_row = default_items.iter().find_map(|i| match i {
            SettingItem::Row(r) if r.key == row.key => Some(r),
            _ => None,
        });
        if let Some(d) = default_row {
            let key = row.key;
            apply_setting(&mut self.config, key, d.current_idx);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_settings_includes_known_rows() {
        let cfg = Config::default();
        let items = build_settings(&cfg);
        // At least one section header and the reset sentinel.
        assert!(items.iter().any(|i| matches!(i, SettingItem::Section(_))));
        let reset = items.iter().find_map(|i| match i {
            SettingItem::Row(r) if r.key == RESET_ALL_KEY => Some(r),
            _ => None,
        });
        assert!(reset.is_some(), "reset sentinel row missing");
    }

    #[test]
    fn apply_bool_setting_round_trips() {
        let mut cfg = Config::default();
        assert!(!cfg.ui.cursor_line);
        let changed = apply_setting(&mut cfg, "ui.cursor_line", 0); // on
        assert!(changed);
        assert!(cfg.ui.cursor_line);
        let changed = apply_setting(&mut cfg, "ui.cursor_line", 1); // off
        assert!(changed);
        assert!(!cfg.ui.cursor_line);
    }

    #[test]
    fn apply_line_numbers_tri_state() {
        let mut cfg = Config::default();
        // Default is absolute (line_numbers=true, relative=false).
        assert!(cfg.ui.line_numbers);
        assert!(!cfg.ui.relative_line_numbers);

        apply_setting(&mut cfg, "ui.line_numbers", 0); // relative
        assert!(cfg.ui.line_numbers);
        assert!(cfg.ui.relative_line_numbers);

        apply_setting(&mut cfg, "ui.line_numbers", 2); // off
        assert!(!cfg.ui.line_numbers);

        apply_setting(&mut cfg, "ui.line_numbers", 1); // absolute
        assert!(cfg.ui.line_numbers);
        assert!(!cfg.ui.relative_line_numbers);
    }

    #[test]
    fn apply_tab_width_choices_map_correctly() {
        let mut cfg = Config::default();
        apply_setting(&mut cfg, "editor.tab_width", 0);
        assert_eq!(cfg.editor.tab_width, 2);
        apply_setting(&mut cfg, "editor.tab_width", 1);
        assert_eq!(cfg.editor.tab_width, 4);
        apply_setting(&mut cfg, "editor.tab_width", 2);
        assert_eq!(cfg.editor.tab_width, 8);
    }

    #[test]
    fn unknown_key_is_noop() {
        let mut cfg = Config::default();
        let changed = apply_setting(&mut cfg, "does.not.exist", 0);
        assert!(!changed);
    }

    #[test]
    fn modified_marker_lights_up_after_change() {
        let mut cfg = Config::default();
        let items = build_settings(&cfg);
        // Pick `ui.cursor_line` (default off) and verify it's unmodified.
        let pre = items.iter().find_map(|i| match i {
            SettingItem::Row(r) if r.key == "ui.cursor_line" => Some(r),
            _ => None,
        });
        assert!(!pre.unwrap().modified);

        apply_setting(&mut cfg, "ui.cursor_line", 0);

        let items = build_settings(&cfg);
        let post = items.iter().find_map(|i| match i {
            SettingItem::Row(r) if r.key == "ui.cursor_line" => Some(r),
            _ => None,
        });
        assert!(post.unwrap().modified);
    }

    #[test]
    fn esc_revert_restores_original() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        assert!(!app.config.ui.cursor_line);
        app.open_settings_overlay();
        apply_setting(&mut app.config, "ui.cursor_line", 0); // on
        assert!(app.config.ui.cursor_line);
        app.close_settings_overlay_cancel();
        assert!(
            !app.config.ui.cursor_line,
            "Esc should revert to pre-open value"
        );
    }

    #[test]
    fn enter_save_keeps_changes() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_settings_overlay();
        apply_setting(&mut app.config, "ui.cursor_line", 0); // on
        app.close_settings_overlay_save();
        assert!(app.config.ui.cursor_line, "save path keeps the change");
    }
}
