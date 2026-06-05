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
    /// When `Some`, the focused Text or Color row is in greedy edit
    /// mode — printable keys append to `buffer`, Backspace removes,
    /// Enter commits, Esc cancels (restores `pre_edit_value`).
    pub text_edit: Option<TextEditState>,
}

/// Captured state for the active text-edit on a Text/Color row.
/// `key` is the SettingRow key being edited; `pre_edit_value` is the
/// snapshot the live config gets restored to on Esc.
#[derive(Debug, Clone)]
pub struct TextEditState {
    pub key: &'static str,
    pub buffer: String,
    pub pre_edit_value: String,
}

impl SettingsOverlayState {
    pub fn open(cfg: &Config) -> Self {
        Self {
            original: cfg.clone(),
            selected_row: 0,
            text_edit: None,
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
    /// An editable discrete-choice row (v1 row kind).
    Row(SettingRow),
    /// An editable numeric row (v2 row kind) — `←/→` step the value
    /// within `[min, max]`. Display: `[ <value><unit> ]`.
    Number(NumberRow),
    /// Free-form text row (v2 row kind). v1 of this variant is
    /// display-only — the value renders bracketed with a "TOML for
    /// now" hint. Live editing needs an `edit_mode` state machine on
    /// the overlay (printable keys → buffer append vs the existing
    /// `←/→` stepping); that's a v2.x follow-up.
    Text(TextRow),
    /// Color hex row (v2 row kind). Like `Text`, v1 is display-only:
    /// renders the value as `#RRGGBB` followed by a small swatch
    /// using the parsed color. Live editing is the same follow-up
    /// as `Text`. No `build_settings` callers wire a `ColorRow` yet;
    /// the variant is reserved for future overrides (e.g. theme
    /// accent color picker).
    #[allow(dead_code)]
    Color(ColorRow),
}

impl SettingItem {
    /// Returns the dispatch key for editable rows (any non-Section
    /// variant), or `None` for section headers. Used by the overlay's
    /// navigation + apply paths.
    pub fn row_key(&self) -> Option<&'static str> {
        match self {
            Self::Section(_) => None,
            Self::Row(r) => Some(r.key),
            Self::Number(n) => Some(n.key),
            Self::Text(r) => Some(r.key),
            Self::Color(r) => Some(r.key),
        }
    }

    pub fn is_row(&self) -> bool {
        matches!(
            self,
            Self::Row(_) | Self::Number(_) | Self::Text(_) | Self::Color(_)
        )
    }
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

/// Numeric setting row. `←/→` adjusts by `step`, clamped to `[min, max]`.
/// `unit` is a suffix shown after the value (e.g. `"ms"`, `"px"`, `""`).
#[derive(Debug, Clone)]
pub struct NumberRow {
    pub key: &'static str,
    pub label: &'static str,
    pub value: i32,
    pub min: i32,
    pub max: i32,
    pub step: i32,
    pub default: i32,
    pub unit: &'static str,
    pub modified: bool,
}

/// Free-form text row. v1 is display-only — value renders bracketed
/// with a "TOML for now" hint; live editing needs an overlay-side
/// edit-mode state machine (v2.x follow-up).
#[derive(Debug, Clone)]
pub struct TextRow {
    pub key: &'static str,
    pub label: &'static str,
    pub value: String,
    pub default: String,
    pub modified: bool,
}

/// Color hex row — value is a `RRGGBB` string (6-char, no `#`).
/// Renderer adds the `#` prefix + a `█` swatch in the parsed color.
/// v1 display-only; live editing is the same follow-up as `Text`.
#[derive(Debug, Clone)]
pub struct ColorRow {
    pub key: &'static str,
    pub label: &'static str,
    /// 6-char hex without `#`. Invalid values render the swatch as
    /// fg-color and append " (invalid)" in dim.
    pub value: String,
    pub default: String,
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

    // Scrolloff (number row — v2). Range 0..=20; step 1.
    out.push(SettingItem::Number(NumberRow {
        key: "ui.scrolloff",
        label: "Scrolloff (rows of context above/below cursor)",
        value: cfg.ui.scrolloff as i32,
        min: 0,
        max: 20,
        step: 1,
        default: d.ui.scrolloff as i32,
        unit: "",
        modified: cfg.ui.scrolloff != d.ui.scrolloff,
    }));

    // Sidescrolloff (number row — v2). Range 0..=20; step 1.
    out.push(SettingItem::Number(NumberRow {
        key: "ui.sidescrolloff",
        label: "Sidescrolloff (cols of context left/right of cursor)",
        value: cfg.ui.sidescrolloff as i32,
        min: 0,
        max: 20,
        step: 1,
        default: d.ui.sidescrolloff as i32,
        unit: "",
        modified: cfg.ui.sidescrolloff != d.ui.sidescrolloff,
    }));

    // Theme name (text row — v2, display-only in v1 of this variant).
    // Lives in `~/.config/mnml/config.toml` under `[ui] theme = "..."`.
    // Edit there directly for now; live edit is a v2.x follow-up.
    out.push(SettingItem::Text(TextRow {
        key: "ui.theme",
        label: "Theme",
        value: cfg.ui.theme.clone(),
        default: d.ui.theme.clone(),
        modified: cfg.ui.theme != d.ui.theme,
    }));

    // Tree width (number row — v2). 16..=60; step 2.
    out.push(SettingItem::Number(NumberRow {
        key: "ui.tree_width",
        label: "File tree width",
        value: cfg.ui.tree_width as i32,
        min: 16,
        max: 60,
        step: 2,
        default: d.ui.tree_width as i32,
        unit: " cols",
        modified: cfg.ui.tree_width != d.ui.tree_width,
    }));

    // Now-playing source — auto / mixr / macos.
    let npsrc_idx = match cfg.ui.now_playing_source.as_str() {
        "mixr" => 1,
        "macos" => 2,
        _ => 0,
    };
    let npsrc_default_idx = match d.ui.now_playing_source.as_str() {
        "mixr" => 1,
        "macos" => 2,
        _ => 0,
    };
    out.push(SettingItem::Row(SettingRow {
        key: "ui.now_playing_source",
        label: "Now-playing source",
        options: vec!["auto".into(), "mixr".into(), "macos".into()],
        current_idx: npsrc_idx,
        modified: npsrc_idx != npsrc_default_idx,
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
        "ui.now_playing_source" => {
            let new = match opt_idx {
                1 => "mixr",
                2 => "macos",
                _ => "auto",
            };
            let changed = cfg.ui.now_playing_source != new;
            cfg.ui.now_playing_source = new.to_string();
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

/// Apply a NumberRow's clamped new value to the live `Config`. Returns
/// `true` when the value actually changed. Unknown keys are no-op'd.
/// `value` is already clamped to `[min, max]` by the caller.
pub fn apply_number_setting(cfg: &mut Config, key: &str, value: i32) -> bool {
    match key {
        "ui.scrolloff" => {
            let new = value.max(0) as usize;
            let changed = cfg.ui.scrolloff != new;
            cfg.ui.scrolloff = new;
            changed
        }
        "ui.sidescrolloff" => {
            let new = value.max(0) as usize;
            let changed = cfg.ui.sidescrolloff != new;
            cfg.ui.sidescrolloff = new;
            changed
        }
        "ui.tree_width" => {
            let new = value.max(0) as u16;
            let changed = cfg.ui.tree_width != new;
            cfg.ui.tree_width = new;
            changed
        }
        _ => false,
    }
}

/// Apply a Text/Color row's new value to the live `Config`. Returns
/// `true` when the value actually changed. Unknown keys are no-op'd.
/// Used primarily by the `r` reset path in v1 (writes the default
/// back) — live edit support is a v2.x follow-up.
pub fn apply_text_setting(cfg: &mut Config, key: &str, value: &str) -> bool {
    match key {
        "ui.theme" => {
            let changed = cfg.ui.theme != value;
            cfg.ui.theme = value.to_string();
            changed
        }
        _ => false,
    }
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
            let row_count = items.iter().filter(|i| i.is_row()).count();
            if row_count == 0 {
                return;
            }
            let new = (state.selected_row as isize + delta).rem_euclid(row_count as isize);
            state.selected_row = new as usize;
        }
    }

    /// Adjust the focused row's value by `delta` (-1 = left, 1 = right).
    /// On the reset-all sentinel row, fires the reset directly.
    /// Discrete rows cycle through their options; number rows step by
    /// `step` and clamp to `[min, max]`.
    pub fn settings_adjust_value(&mut self, delta: isize) {
        let Some(state) = self.settings_overlay.as_ref() else {
            return;
        };
        let items = build_settings(&self.config);
        let rows: Vec<&SettingItem> = items.iter().filter(|i| i.is_row()).collect();
        let Some(row) = rows.get(state.selected_row) else {
            return;
        };
        match row {
            SettingItem::Row(r) => {
                if r.key == RESET_ALL_KEY {
                    return;
                }
                if r.options.is_empty() {
                    return;
                }
                let n = r.options.len() as isize;
                let new_idx = (r.current_idx as isize + delta).rem_euclid(n) as usize;
                let key = r.key;
                apply_setting(&mut self.config, key, new_idx);
            }
            SettingItem::Number(n) => {
                let new_value = (n.value as isize + (delta * n.step as isize))
                    .clamp(n.min as isize, n.max as isize) as i32;
                let key = n.key;
                apply_number_setting(&mut self.config, key, new_value);
            }
            // Text + Color rows are display-only in v1 of v2-row-kinds.
            // ←/→ is a no-op; the user edits the value in TOML for now.
            // Live editing requires an overlay-side edit-mode state
            // machine (v2.x follow-up).
            SettingItem::Text(_) | SettingItem::Color(_) => {}
            SettingItem::Section(_) => {}
        }
    }

    /// `Enter` on the focused row. For the reset-all sentinel, resets
    /// every setting to its default. For normal rows, cycles forward
    /// (equivalent to `→`).
    pub fn settings_enter_row(&mut self) {
        let Some(state) = self.settings_overlay.as_ref() else {
            return;
        };
        let items = build_settings(&self.config);
        let rows: Vec<&SettingItem> = items.iter().filter(|i| i.is_row()).collect();
        let Some(row) = rows.get(state.selected_row) else {
            return;
        };
        if row.row_key() == Some(RESET_ALL_KEY) {
            // Wipe the live config back to defaults. `original` stays
            // — Esc would still revert to the pre-open snapshot if
            // the user changes their mind.
            self.config = Config::default();
            self.toast("settings: all reset to defaults");
            return;
        }
        // Text + Color rows: Enter starts greedy edit mode. The next
        // keystrokes go into the buffer until Enter commits or Esc
        // cancels.
        let start_edit = match row {
            SettingItem::Text(r) => Some((r.key, r.value.clone())),
            SettingItem::Color(r) => Some((r.key, r.value.clone())),
            _ => None,
        };
        if let Some((key, value)) = start_edit {
            if let Some(state) = self.settings_overlay.as_mut() {
                state.text_edit = Some(TextEditState {
                    key,
                    buffer: value.clone(),
                    pre_edit_value: value,
                });
            }
            return;
        }
        // Cycle forward like a `→` press.
        self.settings_adjust_value(1);
    }

    /// True iff the settings overlay is open AND a Text/Color row is
    /// in greedy edit mode. The tui dispatcher checks this to route
    /// printable keys to the buffer instead of the navigation chords.
    pub fn settings_text_edit_active(&self) -> bool {
        self.settings_overlay
            .as_ref()
            .is_some_and(|s| s.text_edit.is_some())
    }

    /// Append a printable character to the edit buffer. Live-writes
    /// the partial value through `apply_text_setting` so the renderer
    /// reflects the in-progress edit (useful for color preview).
    pub fn settings_text_edit_insert(&mut self, c: char) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let Some(edit) = state.text_edit.as_mut() else {
            return;
        };
        edit.buffer.push(c);
        let key = edit.key;
        let value = edit.buffer.clone();
        apply_text_setting(&mut self.config, key, &value);
    }

    /// Drop the trailing char from the edit buffer. No-op when empty.
    pub fn settings_text_edit_backspace(&mut self) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let Some(edit) = state.text_edit.as_mut() else {
            return;
        };
        if edit.buffer.is_empty() {
            return;
        }
        edit.buffer.pop();
        let key = edit.key;
        let value = edit.buffer.clone();
        apply_text_setting(&mut self.config, key, &value);
    }

    /// Commit the edit buffer — leaves the live config as-is (already
    /// written by every insert/backspace) and just exits edit mode.
    pub fn settings_text_edit_commit(&mut self) {
        if let Some(state) = self.settings_overlay.as_mut() {
            state.text_edit = None;
        }
    }

    /// Cancel — restore the live config to `pre_edit_value` and exit
    /// edit mode. `Esc` flows here while editing.
    pub fn settings_text_edit_cancel(&mut self) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let Some(edit) = state.text_edit.take() else {
            return;
        };
        apply_text_setting(&mut self.config, edit.key, &edit.pre_edit_value);
    }

    /// `r` on the focused row — reset just this row's setting to its
    /// `Config::default()` value.
    pub fn settings_reset_row(&mut self) {
        let Some(state) = self.settings_overlay.as_ref() else {
            return;
        };
        let items = build_settings(&self.config);
        let rows: Vec<&SettingItem> = items.iter().filter(|i| i.is_row()).collect();
        let Some(row) = rows.get(state.selected_row) else {
            return;
        };
        let Some(key) = row.row_key() else {
            return;
        };
        if key == RESET_ALL_KEY {
            return;
        }
        // Find the default for this key in the default-config settings
        // list. Dispatch to the right apply function based on row kind.
        let default_cfg = Config::default();
        let default_items = build_settings(&default_cfg);
        let default_row = default_items.iter().find(|i| i.row_key() == Some(key));
        match default_row {
            Some(SettingItem::Row(d)) => {
                apply_setting(&mut self.config, key, d.current_idx);
            }
            Some(SettingItem::Number(d)) => {
                apply_number_setting(&mut self.config, key, d.value);
            }
            Some(SettingItem::Text(d)) => {
                apply_text_setting(&mut self.config, key, &d.value);
            }
            Some(SettingItem::Color(d)) => {
                apply_text_setting(&mut self.config, key, &d.value);
            }
            _ => {}
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
    fn build_settings_includes_number_rows() {
        let cfg = Config::default();
        let items = build_settings(&cfg);
        let scrolloff = items.iter().find_map(|i| match i {
            SettingItem::Number(n) if n.key == "ui.scrolloff" => Some(n),
            _ => None,
        });
        let row = scrolloff.expect("scrolloff number row missing");
        assert_eq!(row.value, cfg.ui.scrolloff as i32);
        assert_eq!(row.min, 0);
        assert_eq!(row.max, 20);
        assert_eq!(row.step, 1);
        assert!(!row.modified);
    }

    #[test]
    fn build_settings_includes_text_rows() {
        let cfg = Config::default();
        let items = build_settings(&cfg);
        let theme = items.iter().find_map(|i| match i {
            SettingItem::Text(t) if t.key == "ui.theme" => Some(t),
            _ => None,
        });
        let row = theme.expect("ui.theme text row missing");
        assert_eq!(row.value, cfg.ui.theme);
        assert!(!row.modified);
    }

    #[test]
    fn apply_text_setting_writes_and_returns_changed() {
        let mut cfg = Config::default();
        let was = cfg.ui.theme.clone();
        let other = if was == "tokyonight-night" {
            "tokyonight-storm".to_string()
        } else {
            "tokyonight-night".to_string()
        };
        assert!(apply_text_setting(&mut cfg, "ui.theme", &other));
        assert_eq!(cfg.ui.theme, other);
        // Same value ⇒ false.
        assert!(!apply_text_setting(&mut cfg, "ui.theme", &other));
    }

    #[test]
    fn text_edit_insert_then_commit_writes_buffer() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_settings_overlay();
        // Focus the ui.theme row.
        let items = build_settings(&app.config);
        let rows: Vec<&SettingItem> = items.iter().filter(|i| i.is_row()).collect();
        let pos = rows
            .iter()
            .position(|r| r.row_key() == Some("ui.theme"))
            .unwrap();
        if let Some(state) = app.settings_overlay.as_mut() {
            state.selected_row = pos;
        }
        // Enter edit mode; insert chars; commit.
        app.settings_enter_row();
        assert!(app.settings_text_edit_active());
        // Replace existing text with "z" by backspacing it all + typing.
        for _ in 0..50 {
            app.settings_text_edit_backspace();
        }
        for c in "rosepine".chars() {
            app.settings_text_edit_insert(c);
        }
        app.settings_text_edit_commit();
        assert!(!app.settings_text_edit_active());
        assert_eq!(app.config.ui.theme, "rosepine");
    }

    #[test]
    fn text_edit_cancel_restores_pre_edit_value() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let original = app.config.ui.theme.clone();
        app.open_settings_overlay();
        let items = build_settings(&app.config);
        let rows: Vec<&SettingItem> = items.iter().filter(|i| i.is_row()).collect();
        let pos = rows
            .iter()
            .position(|r| r.row_key() == Some("ui.theme"))
            .unwrap();
        if let Some(state) = app.settings_overlay.as_mut() {
            state.selected_row = pos;
        }
        app.settings_enter_row();
        app.settings_text_edit_insert('X');
        // Half-typed; user cancels.
        app.settings_text_edit_cancel();
        assert!(!app.settings_text_edit_active());
        assert_eq!(app.config.ui.theme, original);
    }

    #[test]
    fn settings_reset_row_works_for_text() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let default_theme = app.config.ui.theme.clone();
        // Change the theme directly to mark as modified.
        app.config.ui.theme = "ratchet-test".to_string();
        app.open_settings_overlay();
        // Find the ui.theme row index and focus it.
        let items = build_settings(&app.config);
        let rows: Vec<&SettingItem> = items.iter().filter(|i| i.is_row()).collect();
        let pos = rows
            .iter()
            .position(|r| r.row_key() == Some("ui.theme"))
            .expect("ui.theme row not in build_settings");
        if let Some(state) = app.settings_overlay.as_mut() {
            state.selected_row = pos;
        }
        app.settings_reset_row();
        assert_eq!(app.config.ui.theme, default_theme);
    }

    #[test]
    fn apply_number_setting_clamps_and_writes() {
        let mut cfg = Config::default();
        cfg.ui.scrolloff = 5;
        assert!(apply_number_setting(&mut cfg, "ui.scrolloff", 12));
        assert_eq!(cfg.ui.scrolloff, 12);
        // Same value ⇒ false.
        assert!(!apply_number_setting(&mut cfg, "ui.scrolloff", 12));
        // Negative input is treated as 0 (defensive — the caller
        // clamps, but apply guards against bad usage).
        apply_number_setting(&mut cfg, "ui.scrolloff", -3);
        assert_eq!(cfg.ui.scrolloff, 0);
    }

    #[test]
    fn number_row_modified_marker_lights_after_change() {
        let mut cfg = Config::default();
        let default_value = cfg.ui.scrolloff;
        // Pick a value different from default — guaranteed within 0..=20.
        let new_value: i32 = if default_value == 5 { 6 } else { 5 };
        apply_number_setting(&mut cfg, "ui.scrolloff", new_value);
        let items = build_settings(&cfg);
        let row = items
            .iter()
            .find_map(|i| match i {
                SettingItem::Number(n) if n.key == "ui.scrolloff" => Some(n),
                _ => None,
            })
            .unwrap();
        assert!(row.modified);
        assert_eq!(row.value, new_value);
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
