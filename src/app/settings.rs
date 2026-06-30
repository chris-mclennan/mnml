//! Settings overlay — schema + state + apply dispatcher.
//!
//! The renderer lives at `src/ui/settings_overlay.rs`. See the "Family
//! settings UI convention" in `CLAUDE.md` for the visual idiom we
//! match across mnml + mixr.
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
    /// Raw text of `<workspace>/.mnml/config.toml` at open time, or `None`
    /// if the file didn't exist. Esc/cancel restores the workspace file to
    /// this snapshot (undoing the live per-setting disk writes); `None` ⇒
    /// the file is deleted on cancel if editing created it.
    pub original_workspace_file: Option<String>,
}

/// Captured state for the active text-edit on a Text/Color row.
/// `key` is the SettingRow key being edited; `pre_edit_value` is the
/// snapshot the live config gets restored to on Esc.
#[derive(Debug, Clone)]
pub struct TextEditState {
    pub key: &'static str,
    pub buffer: String,
    /// Byte position of the caret within `buffer` (always at a
    /// char boundary). Starts at the end of `pre_edit_value`
    /// when edit mode is entered. Moved by Left/Right/Home/End.
    pub cursor: usize,
    pub pre_edit_value: String,
}

impl SettingsOverlayState {
    pub fn open(cfg: &Config, workspace: &std::path::Path) -> Self {
        let original_workspace_file =
            std::fs::read_to_string(crate::config::workspace_config_path(workspace)).ok();
        Self {
            original: cfg.clone(),
            selected_row: 0,
            text_edit: None,
            original_workspace_file,
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

/// Sentinel `key` for the "Manage workspaces…" row. Enter opens
/// the dedicated workspaces editor overlay.
pub const MANAGE_WORKSPACES_KEY: &str = "__manage_workspaces__";

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

    // Menu bar visibility — always shown / auto-hide / hidden.
    let menu_bar_idx = match cfg.ui.menu_bar.as_str() {
        "auto" => 1,
        "hidden" => 2,
        _ => 0,
    };
    let menu_bar_default_idx = match d.ui.menu_bar.as_str() {
        "auto" => 1,
        "hidden" => 2,
        _ => 0,
    };
    out.push(SettingItem::Row(SettingRow {
        key: "ui.menu_bar",
        label: "Menu bar",
        options: vec!["always".into(), "auto".into(), "hidden".into()],
        current_idx: menu_bar_idx,
        modified: menu_bar_idx != menu_bar_default_idx,
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

    // 2026-06-20 — first Color row: cmdline popup border color.
    out.push(SettingItem::Color(ColorRow {
        key: "ui.cmdline_popup_border_color",
        label: "Cmdline popup border color",
        value: cfg.ui.cmdline_popup_border_color.clone(),
        default: d.ui.cmdline_popup_border_color.clone(),
        modified: cfg.ui.cmdline_popup_border_color != d.ui.cmdline_popup_border_color,
    }));

    // Default workspace path — what mnml opens when launched without
    // a `[WORKSPACE]` argument. Avoids landing on `$HOME` (which
    // triggers the TCC prompt cascade: Photos library, Documents,
    // Desktop, Downloads, etc.). Tilde-expanded when applied.
    // Lives in config.toml under `[startup] default_workspace`.
    let dws_current = cfg
        .default_workspace
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    let dws_default = d
        .default_workspace
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    out.push(SettingItem::Text(TextRow {
        key: "startup.default_workspace",
        label: "Default workspace",
        value: dws_current.clone(),
        default: dws_default.clone(),
        modified: dws_current != dws_default,
    }));

    // Projects folder — used by the startup picker to list immediate
    // subdirectories as one-click "Open project: foo" rows.
    // Tilde-expanded on save (`~/Projects` → `/Users/.../Projects`).
    // Empty string disables the feature.
    out.push(SettingItem::Text(TextRow {
        key: "ui.projects_dir",
        label: "Projects folder",
        value: cfg.ui.projects_dir.clone(),
        default: d.ui.projects_dir.clone(),
        modified: cfg.ui.projects_dir != d.ui.projects_dir,
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

    // design-critic Issue 10 — right-panel default visibility + width.
    out.push(SettingItem::Row(SettingRow {
        key: "ui.right_panel_visible",
        label: "Right side panel (default)",
        options: vec!["off".to_string(), "on".to_string()],
        current_idx: if cfg.ui.right_panel_visible { 1 } else { 0 },
        modified: cfg.ui.right_panel_visible != d.ui.right_panel_visible,
    }));
    out.push(SettingItem::Number(NumberRow {
        key: "ui.right_panel_width",
        label: "Right side panel width",
        value: cfg.ui.right_panel_width as i32,
        min: 16,
        max: 60,
        step: 2,
        default: d.ui.right_panel_width as i32,
        unit: " cols",
        modified: cfg.ui.right_panel_width != d.ui.right_panel_width,
    }));

    // 2026-06-20 — Editor.tab_width: 1..=12; step 1.
    out.push(SettingItem::Number(NumberRow {
        key: "editor.tab_width",
        label: "Tab width",
        value: cfg.editor.tab_width as i32,
        min: 1,
        max: 12,
        step: 1,
        default: d.editor.tab_width as i32,
        unit: " cols",
        modified: cfg.editor.tab_width != d.editor.tab_width,
    }));

    // UI.color_column: 0..=200; step 4. 0 = off.
    out.push(SettingItem::Number(NumberRow {
        key: "ui.color_column",
        label: "Color column (0 = off)",
        value: cfg.ui.color_column as i32,
        min: 0,
        max: 200,
        step: 4,
        default: d.ui.color_column as i32,
        unit: "",
        modified: cfg.ui.color_column != d.ui.color_column,
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

    // Preferred music app — drives the idle `♪ <app>` chip label and
    // the click-to-activate destination when nothing is currently
    // playing.
    let pma_idx = match cfg.ui.preferred_music_app.as_str() {
        "music" => 1,
        "spotify" => 2,
        _ => 0,
    };
    let pma_default_idx = match d.ui.preferred_music_app.as_str() {
        "music" => 1,
        "spotify" => 2,
        _ => 0,
    };
    out.push(SettingItem::Row(SettingRow {
        key: "ui.preferred_music_app",
        label: "Preferred music app",
        options: vec!["mixr".into(), "music".into(), "spotify".into()],
        current_idx: pma_idx,
        modified: pma_idx != pma_default_idx,
    }));

    // ── Editor ─────────────────────────────────────────────────────
    out.push(SettingItem::Section("Editor"));

    // Input style — vim vs standard.
    let input_idx = if crate::input::is_vim_style(cfg) {
        0
    } else {
        1
    };
    let input_default_idx = if crate::input::is_vim_style(&d) { 0 } else { 1 };
    out.push(SettingItem::Row(SettingRow {
        key: "editor.input_style",
        label: "Input style",
        options: vec!["vim".into(), "standard".into()],
        current_idx: input_idx,
        modified: input_idx != input_default_idx,
    }));

    // wheel_moves_cursor — auto / always / never.
    let wmc_idx = match cfg.editor.wheel_moves_cursor.as_str() {
        "always" => 1,
        "never" => 2,
        _ => 0, // "auto" / anything else
    };
    let wmc_default_idx = match d.editor.wheel_moves_cursor.as_str() {
        "always" => 1,
        "never" => 2,
        _ => 0,
    };
    out.push(SettingItem::Row(SettingRow {
        key: "editor.wheel_moves_cursor",
        label: "Mouse wheel drags cursor",
        options: vec!["auto".into(), "always".into(), "never".into()],
        current_idx: wmc_idx,
        modified: wmc_idx != wmc_default_idx,
    }));

    // qa-8th crash SEV-2 2026-06-30 — was a duplicate `editor.tab_width`
    // SettingRow here alongside the NumberRow above. With a NumberRow
    // value out of the {2,4,8} set (e.g. 3), the Row's _ => 1 fallback
    // displayed wrong + adjusting it would clobber back to 4. NumberRow
    // (1-12 step 1) is strictly more expressive — removed the Row.

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

    // ── Browser ────────────────────────────────────────────────────
    out.push(SettingItem::Section("Browser"));
    out.push(bool_row(
        "browser.autocapture_to_log",
        "Auto-append browser requests → captured/log.jsonl",
        cfg.browser.autocapture_to_log,
        d.browser.autocapture_to_log,
    ));

    // ── Session ─────────────────────────────────────────────────────
    out.push(SettingItem::Section("Session"));
    out.push(bool_row(
        "session.restore",
        "Restore open buffers on launch",
        cfg.session.restore,
        d.session.restore,
    ));

    // ── Workspaces ────────────────────────────────────────────────
    out.push(SettingItem::Section("Workspaces"));
    let ws_count = cfg.workspaces.len();
    out.push(SettingItem::Row(SettingRow {
        key: MANAGE_WORKSPACES_KEY,
        label: "Manage workspaces…",
        options: vec![format!("{ws_count} configured")],
        current_idx: 0,
        modified: false,
    }));

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
        "ui.right_panel_visible" => set_bool(&mut cfg.ui.right_panel_visible, opt_idx),
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
        "ui.menu_bar" => {
            let new = match opt_idx {
                1 => "auto",
                2 => "hidden",
                _ => "always",
            };
            let changed = cfg.ui.menu_bar != new;
            cfg.ui.menu_bar = new.to_string();
            changed
        }
        "ui.preferred_music_app" => {
            let new = match opt_idx {
                1 => "music",
                2 => "spotify",
                _ => "mixr",
            };
            let changed = cfg.ui.preferred_music_app != new;
            cfg.ui.preferred_music_app = new.to_string();
            changed
        }
        "editor.input_style" => {
            let new = if opt_idx == 0 { "vim" } else { "standard" };
            let changed = cfg.editor.input_style != new;
            cfg.editor.input_style = new.to_string();
            changed
        }
        "editor.wheel_moves_cursor" => {
            let new = match opt_idx {
                1 => "always",
                2 => "never",
                _ => "auto",
            };
            let changed = cfg.editor.wheel_moves_cursor != new;
            cfg.editor.wheel_moves_cursor = new.to_string();
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
        "browser.autocapture_to_log" => set_bool(&mut cfg.browser.autocapture_to_log, opt_idx),
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
        "ui.right_panel_width" => {
            let new = value.max(0) as u16;
            let changed = cfg.ui.right_panel_width != new;
            cfg.ui.right_panel_width = new;
            changed
        }
        "editor.tab_width" => {
            let new = value.max(1) as usize;
            let changed = cfg.editor.tab_width != new;
            cfg.editor.tab_width = new;
            changed
        }
        "ui.color_column" => {
            let new = value.max(0) as usize;
            let changed = cfg.ui.color_column != new;
            cfg.ui.color_column = new;
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
        "ui.cmdline_popup_border_color" => {
            let changed = cfg.ui.cmdline_popup_border_color != value;
            cfg.ui.cmdline_popup_border_color = value.to_string();
            changed
        }
        "startup.default_workspace" => {
            let trimmed = value.trim();
            let new = if trimmed.is_empty() {
                None
            } else {
                Some(std::path::PathBuf::from(trimmed))
            };
            let changed = cfg.default_workspace != new;
            cfg.default_workspace = new;
            changed
        }
        "ui.projects_dir" => {
            // Tilde-expand on save so consumers can use the value as
            // a path directly. Empty string disables the feature.
            let trimmed = value.trim();
            let expanded = if let Some(rest) = trimmed.strip_prefix("~/")
                && let Some(home) = std::env::var_os("HOME")
            {
                std::path::PathBuf::from(home)
                    .join(rest)
                    .to_string_lossy()
                    .into_owned()
            } else {
                trimmed.to_string()
            };
            let changed = cfg.ui.projects_dir != expanded;
            cfg.ui.projects_dir = expanded;
            changed
        }
        _ => false,
    }
}

/// Map a settings-overlay `key` to the `(toml_section, toml_key, value_toml)`
/// line(s) that persist its CURRENT value into `<workspace>/.mnml/config.toml`.
/// Reads the already-applied value off `cfg`. Most keys map to one line; the
/// combined `ui.line_numbers` row maps to two underlying fields.
///
/// `startup.default_workspace` returns empty — "which folder to open" is
/// inherently global (persisted to `~/.config/mnml/config.toml` via
/// [`crate::config::persist_default_workspace`]), not a per-project override.
/// Unknown keys return empty (no-op).
fn workspace_persist_lines(cfg: &Config, key: &str) -> Vec<(&'static str, &'static str, String)> {
    let q = crate::config::toml_quote;
    let b = |v: bool| v.to_string();
    match key {
        // ── ui (bool) ──
        "ui.line_numbers" => vec![
            (
                "ui",
                "relative_line_numbers",
                b(cfg.ui.relative_line_numbers),
            ),
            ("ui", "line_numbers", b(cfg.ui.line_numbers)),
        ],
        "ui.cursor_line" => vec![("ui", "cursor_line", b(cfg.ui.cursor_line))],
        "ui.scrollbar" => vec![("ui", "scrollbar", b(cfg.ui.scrollbar))],
        "ui.syntax" => vec![("ui", "syntax", b(cfg.ui.syntax))],
        "ui.show_whitespace" => vec![("ui", "show_whitespace", b(cfg.ui.show_whitespace))],
        "ui.bracket_rainbow" => vec![("ui", "bracket_rainbow", b(cfg.ui.bracket_rainbow))],
        "ui.highlight_trailing_ws" => vec![(
            "ui",
            "highlight_trailing_ws",
            b(cfg.ui.highlight_trailing_ws),
        )],
        "ui.clock" => vec![("ui", "clock", b(cfg.ui.clock))],
        "ui.highlight_word_under_cursor" => vec![(
            "ui",
            "highlight_word_under_cursor",
            b(cfg.ui.highlight_word_under_cursor),
        )],
        "ui.wrap" => vec![("ui", "wrap", b(cfg.ui.wrap))],
        "ui.sticky_context" => vec![("ui", "sticky_context", b(cfg.ui.sticky_context))],
        "ui.render_markdown" => vec![("ui", "render_markdown", b(cfg.ui.render_markdown))],
        "ui.auto_md_preview" => vec![("ui", "auto_md_preview", b(cfg.ui.auto_md_preview))],
        // ── ui (string) ──
        "ui.picker_position" => vec![("ui", "picker_position", q(&cfg.ui.picker_position))],
        "ui.now_playing_source" => {
            vec![("ui", "now_playing_source", q(&cfg.ui.now_playing_source))]
        }
        "ui.preferred_music_app" => {
            vec![("ui", "preferred_music_app", q(&cfg.ui.preferred_music_app))]
        }
        "ui.menu_bar" => vec![("ui", "menu_bar", q(&cfg.ui.menu_bar))],
        "ui.theme" => vec![("ui", "theme", q(&cfg.ui.theme))],
        "ui.cmdline_popup_border_color" => vec![(
            "ui",
            "cmdline_popup_border_color",
            q(&cfg.ui.cmdline_popup_border_color),
        )],
        // ── ui (int) ──
        "ui.scrolloff" => vec![("ui", "scrolloff", cfg.ui.scrolloff.to_string())],
        "ui.sidescrolloff" => vec![("ui", "sidescrolloff", cfg.ui.sidescrolloff.to_string())],
        "ui.tree_width" => vec![("ui", "tree_width", cfg.ui.tree_width.to_string())],
        "ui.right_panel_visible" => {
            vec![("ui", "right_panel_visible", b(cfg.ui.right_panel_visible))]
        }
        "ui.right_panel_width" => vec![(
            "ui",
            "right_panel_width",
            cfg.ui.right_panel_width.to_string(),
        )],
        "ui.color_column" => vec![("ui", "color_column", cfg.ui.color_column.to_string())],
        // ── editor ──
        "editor.input_style" => vec![("editor", "input_style", q(&cfg.editor.input_style))],
        "editor.wheel_moves_cursor" => vec![(
            "editor",
            "wheel_moves_cursor",
            q(&cfg.editor.wheel_moves_cursor),
        )],
        "editor.tab_width" => vec![("editor", "tab_width", cfg.editor.tab_width.to_string())],
        "editor.trim_trailing_ws_on_save" => vec![(
            "editor",
            "trim_trailing_ws_on_save",
            b(cfg.editor.trim_trailing_ws_on_save),
        )],
        "editor.auto_pair" => vec![("editor", "auto_pair", b(cfg.editor.auto_pair))],
        "editor.auto_indent" => vec![("editor", "auto_indent", b(cfg.editor.auto_indent))],
        "editor.format_on_save" => {
            vec![("editor", "format_on_save", b(cfg.editor.format_on_save))]
        }
        "editor.inlay_hints" => vec![("editor", "inlay_hints", b(cfg.editor.inlay_hints))],
        "editor.code_lens" => vec![("editor", "code_lens", b(cfg.editor.code_lens))],
        "editor.breadcrumb" => vec![("editor", "breadcrumb", b(cfg.editor.breadcrumb))],
        // ── browser / session ──
        "browser.autocapture_to_log" => vec![(
            "browser",
            "autocapture_to_log",
            b(cfg.browser.autocapture_to_log),
        )],
        "session.restore" => vec![("session", "restore", b(cfg.session.restore))],
        // Global / unknown — handled elsewhere or not persisted here.
        _ => Vec::new(),
    }
}

impl App {
    /// Open the settings overlay. Snapshots the current config for
    /// revert-on-cancel. Idempotent — re-opening replaces the snapshot
    /// (so a second `view.settings` from inside the overlay would
    /// "commit" the current state as the new baseline).
    pub fn open_settings_overlay(&mut self) {
        self.settings_overlay = Some(SettingsOverlayState::open(&self.config, &self.workspace));
    }

    /// Close the settings overlay, keeping all current changes (the
    /// snapshot in `original` is discarded). The Enter / save path.
    /// Also persists the `[startup] default_workspace` field to
    /// `~/.config/mnml/config.toml` when it differs from the snapshot
    /// — the only field today that needs cross-restart persistence
    /// (the others are in-memory or read-back via Config::load).
    pub fn close_settings_overlay_save(&mut self) {
        if let Some(state) = self.settings_overlay.as_ref()
            && self.config.default_workspace != state.original.default_workspace
        {
            match crate::config::persist_default_workspace(self.config.default_workspace.as_deref())
            {
                Ok(_) => {}
                Err(e) => {
                    self.toast(format!(
                        "default workspace saved in-memory (persist failed: {e})"
                    ));
                }
            }
        }
        self.settings_overlay = None;
    }

    /// Close the settings overlay, reverting the live config back to
    /// the snapshot taken on open. The Esc / cancel path. Also restores
    /// `<workspace>/.mnml/config.toml` to its pre-open state, undoing the
    /// live per-setting disk writes made during this session.
    pub fn close_settings_overlay_cancel(&mut self) {
        if let Some(state) = self.settings_overlay.take() {
            self.config = state.original;
            let path = crate::config::workspace_config_path(&self.workspace);
            let restore = match &state.original_workspace_file {
                // Existed at open — write the snapshot back.
                Some(text) => std::fs::write(&path, text).err().map(|e| e.to_string()),
                // Didn't exist at open — remove it if editing created it.
                None => {
                    if path.exists() {
                        std::fs::remove_file(&path).err().map(|e| e.to_string())
                    } else {
                        None
                    }
                }
            };
            if let Some(e) = restore {
                self.toast(format!("settings: revert of workspace file failed: {e}"));
            }
        }
    }

    /// Persist setting `key`'s current value to `<workspace>/.mnml/config.toml`
    /// (the checked-into-the-repo overrides file). Best-effort — a write
    /// failure toasts but the in-memory change already applied. No-op for keys
    /// that aren't workspace-persisted (e.g. `startup.default_workspace`, which
    /// is global). Call only after the apply reported the value changed.
    fn persist_setting_to_workspace(&mut self, key: &str) {
        for (section, toml_key, value) in workspace_persist_lines(&self.config, key) {
            if let Err(e) =
                crate::config::persist_workspace_setting(&self.workspace, section, toml_key, &value)
            {
                self.toast(format!("settings: saved in-memory (persist failed: {e})"));
                break;
            }
        }
    }

    /// `view.menu_bar_cycle` — cycle the menu-bar visibility
    /// (always → auto → hidden → …), persisting the choice. Surfaced in the
    /// View menu as a quick alternative to the Settings row.
    pub fn cycle_menu_bar(&mut self) {
        let next = match self.config.ui.menu_bar.as_str() {
            "always" => 1, // → auto
            "auto" => 2,   // → hidden
            _ => 0,        // hidden / anything → always
        };
        apply_setting(&mut self.config, "ui.menu_bar", next);
        self.persist_setting_to_workspace("ui.menu_bar");
        self.toast(format!("menu bar: {}", self.config.ui.menu_bar));
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
            // Clamp at the boundaries — was `rem_euclid` which wrapped
            // around. Same shape as the discovery-overlay clamp
            // (ea6bbd9); the wrap was equally wrong here — wheel
            // scrolling past the last row jumped the cursor back to
            // the top, and a click on a visible row would land on
            // whatever shifted under it. Kept the in-row option
            // cycler (`settings_adjust_value`) on `rem_euclid` since
            // wrapping value choices is the intended behavior there.
            let new = (state.selected_row as isize + delta).clamp(0, row_count as isize - 1);
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
        // When an apply changes the value, capture the key so we can persist
        // it to the workspace file once the read-borrows above are released.
        let mut persist_key: Option<&'static str> = None;
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
                if apply_setting(&mut self.config, key, new_idx) {
                    persist_key = Some(key);
                }
            }
            SettingItem::Number(n) => {
                let new_value = (n.value as isize + (delta * n.step as isize))
                    .clamp(n.min as isize, n.max as isize) as i32;
                let key = n.key;
                if apply_number_setting(&mut self.config, key, new_value) {
                    persist_key = Some(key);
                }
            }
            // Text + Color rows are display-only in v1 of v2-row-kinds.
            // ←/→ is a no-op; the user edits the value in TOML for now.
            // Live editing requires an overlay-side edit-mode state
            // machine (v2.x follow-up).
            SettingItem::Text(_) | SettingItem::Color(_) => {}
            SettingItem::Section(_) => {}
        }
        if let Some(key) = persist_key {
            self.persist_setting_to_workspace(key);
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
        if row.row_key() == Some(MANAGE_WORKSPACES_KEY) {
            // Defer to the dedicated overlay — see
            // `App::open_workspaces_editor`.
            self.open_workspaces_editor();
            return;
        }
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
                let cursor = value.len();
                state.text_edit = Some(TextEditState {
                    key,
                    buffer: value.clone(),
                    cursor,
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

    /// Insert a printable character at the caret. Live-writes the
    /// partial value through `apply_text_setting`.
    pub fn settings_text_edit_insert(&mut self, c: char) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let Some(edit) = state.text_edit.as_mut() else {
            return;
        };
        let pos = edit.cursor.min(edit.buffer.len());
        edit.buffer.insert(pos, c);
        edit.cursor = pos + c.len_utf8();
        let key = edit.key;
        let value = edit.buffer.clone();
        apply_text_setting(&mut self.config, key, &value);
    }

    /// Delete the character to the LEFT of the caret. No-op when
    /// the caret is at position 0.
    pub fn settings_text_edit_backspace(&mut self) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let Some(edit) = state.text_edit.as_mut() else {
            return;
        };
        let pos = edit.cursor.min(edit.buffer.len());
        if pos == 0 {
            return;
        }
        let prev = edit.buffer[..pos]
            .char_indices()
            .next_back()
            .map(|(i, _)| i)
            .unwrap_or(0);
        edit.buffer.replace_range(prev..pos, "");
        edit.cursor = prev;
        let key = edit.key;
        let value = edit.buffer.clone();
        apply_text_setting(&mut self.config, key, &value);
    }

    /// Delete the character to the RIGHT of the caret (Delete /
    /// fn-Backspace). No-op when the caret is at end-of-buffer.
    pub fn settings_text_edit_delete(&mut self) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let Some(edit) = state.text_edit.as_mut() else {
            return;
        };
        let pos = edit.cursor.min(edit.buffer.len());
        if pos >= edit.buffer.len() {
            return;
        }
        let next = edit.buffer[pos..]
            .char_indices()
            .nth(1)
            .map(|(i, _)| pos + i)
            .unwrap_or(edit.buffer.len());
        edit.buffer.replace_range(pos..next, "");
        let key = edit.key;
        let value = edit.buffer.clone();
        apply_text_setting(&mut self.config, key, &value);
    }

    /// Move the caret one char left.
    pub fn settings_text_edit_move_left(&mut self) {
        if let Some(state) = self.settings_overlay.as_mut()
            && let Some(edit) = state.text_edit.as_mut()
        {
            let pos = edit.cursor.min(edit.buffer.len());
            edit.cursor = edit.buffer[..pos]
                .char_indices()
                .next_back()
                .map(|(i, _)| i)
                .unwrap_or(0);
        }
    }

    /// Move the caret one char right.
    pub fn settings_text_edit_move_right(&mut self) {
        if let Some(state) = self.settings_overlay.as_mut()
            && let Some(edit) = state.text_edit.as_mut()
        {
            let pos = edit.cursor.min(edit.buffer.len());
            edit.cursor = edit.buffer[pos..]
                .char_indices()
                .nth(1)
                .map(|(i, _)| pos + i)
                .unwrap_or(edit.buffer.len());
        }
    }

    /// Caret → start of buffer.
    pub fn settings_text_edit_home(&mut self) {
        if let Some(state) = self.settings_overlay.as_mut()
            && let Some(edit) = state.text_edit.as_mut()
        {
            edit.cursor = 0;
        }
    }

    /// Caret → end of buffer.
    pub fn settings_text_edit_end(&mut self) {
        if let Some(state) = self.settings_overlay.as_mut()
            && let Some(edit) = state.text_edit.as_mut()
        {
            edit.cursor = edit.buffer.len();
        }
    }

    /// Commit the edit buffer — leaves the live config as-is (already
    /// written by every insert/backspace) and just exits edit mode.
    ///
    /// 2026-06-19 — user-reported: setting `default_workspace` via
    /// :settings + Enter looked successful but didn't persist
    /// across restart. Root cause was that
    /// `close_settings_overlay_save` (the only persist path) was
    /// only triggered by mouse-click-outside; keyboard users had
    /// no save path. Now commit-on-Enter ALSO persists any field
    /// that's hooked to disk (currently just default_workspace),
    /// so the keyboard-only flow matches the click-out flow.
    pub fn settings_text_edit_commit(&mut self) {
        let Some(state) = self.settings_overlay.as_mut() else {
            return;
        };
        let edited_key = state.text_edit.as_ref().map(|e| e.key);
        state.text_edit = None;
        // `startup.default_workspace` is global — persist to
        // `~/.config/mnml/config.toml` (its existing home), and rebaseline the
        // snapshot so a later Esc doesn't appear to revert a committed global
        // change.
        // `ui.projects_dir` is also global — same shape.
        // Clone everything off `state` up front so we can borrow `self`
        // mutably for `self.toast` without running into a double-borrow.
        let original_dws = state.original.default_workspace.clone();
        let current_dws = self.config.default_workspace.clone();
        let original_pd = state.original.ui.projects_dir.clone();
        let current_pd = self.config.ui.projects_dir.clone();
        let dws_result = if original_dws != current_dws {
            Some(crate::config::persist_default_workspace(
                current_dws.as_deref(),
            ))
        } else {
            None
        };
        let pd_result = if original_pd != current_pd {
            let opt = if current_pd.is_empty() {
                None
            } else {
                Some(current_pd.as_str())
            };
            Some(crate::config::persist_ui_projects_dir(opt))
        } else {
            None
        };
        // Now safe to reach back into `self.settings_overlay` /
        // `self.toast` — the `state` borrow above is dead.
        if let Some(result) = dws_result {
            match result {
                Ok(path) => {
                    if let Some(s) = self.settings_overlay.as_mut() {
                        s.original.default_workspace = current_dws.clone();
                    }
                    self.toast(format!("settings: saved → {}", path.display()));
                }
                Err(e) => self.toast(format!("settings: persist failed: {e}")),
            }
        }
        if let Some(result) = pd_result {
            match result {
                Ok(path) => {
                    if let Some(s) = self.settings_overlay.as_mut() {
                        s.original.ui.projects_dir = current_pd.clone();
                    }
                    self.toast(format!("settings: saved → {}", path.display()));
                }
                Err(e) => self.toast(format!("settings: persist failed: {e}")),
            }
        }
        // Other Text rows (theme, cmdline border color) persist to the
        // per-workspace file like the discrete rows. Esc still reverts them
        // via the workspace-file snapshot restore.
        if let Some(key) = edited_key
            && !matches!(key, "startup.default_workspace" | "ui.projects_dir")
        {
            self.persist_setting_to_workspace(key);
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
        let changed = match default_row {
            Some(SettingItem::Row(d)) => apply_setting(&mut self.config, key, d.current_idx),
            Some(SettingItem::Number(d)) => apply_number_setting(&mut self.config, key, d.value),
            Some(SettingItem::Text(d)) => apply_text_setting(&mut self.config, key, &d.value),
            Some(SettingItem::Color(d)) => apply_text_setting(&mut self.config, key, &d.value),
            _ => false,
        };
        if changed {
            // Reset writes the default as an explicit override into the
            // workspace file (the per-project intent). `startup.*` /
            // unknown keys are no-op'd by `workspace_persist_lines`.
            self.persist_setting_to_workspace(key);
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

    // ── workspace-config persistence ──────────────────────────────────

    fn focus_row(app: &mut App, key: &str) {
        let idx = build_settings(&app.config)
            .iter()
            .filter(|i| i.is_row())
            .position(|i| i.row_key() == Some(key))
            .expect("row exists");
        if let Some(s) = app.settings_overlay.as_mut() {
            s.selected_row = idx;
        }
    }

    #[test]
    fn adjust_persists_discrete_to_workspace_file() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        app.open_settings_overlay();
        focus_row(&mut app, "ui.cursor_line");
        app.settings_adjust_value(1);
        let path = ws.join(".mnml").join("config.toml");
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("[ui]"), "section written: {body}");
        assert!(
            body.contains(&format!("cursor_line = {}", app.config.ui.cursor_line)),
            "value written: {body}"
        );
        // Re-adjusting upserts in place — no duplicate lines accumulate.
        app.settings_adjust_value(1);
        app.settings_adjust_value(1);
        let body = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            body.matches("cursor_line = ").count(),
            1,
            "no dupes: {body}"
        );
    }

    #[test]
    fn workspace_file_round_trips_on_load() {
        // End-to-end: change a setting via the overlay → the workspace file it
        // writes, when merged onto a fresh (global-default) config the way
        // `Config::load`'s home→workspace layering does, reflects the new
        // value. Proves the write side round-trips through the read side.
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        let default_cursor_line = Config::default().ui.cursor_line;
        app.open_settings_overlay();
        focus_row(&mut app, "ui.cursor_line");
        app.settings_adjust_value(1);
        let set_value = app.config.ui.cursor_line;
        assert_ne!(set_value, default_cursor_line, "adjust changed the value");

        // Layer the just-written workspace file onto a fresh default config —
        // the same merge `Config::load` applies (global defaults, then the
        // workspace override). The workspace value must win.
        let mut merged = Config::default();
        merged.apply_file_pub(&ws.join(".mnml").join("config.toml"));
        assert_eq!(
            merged.ui.cursor_line, set_value,
            "workspace override applied on load"
        );
    }

    #[test]
    fn adjust_persists_tab_width_editor_section() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        app.open_settings_overlay();
        focus_row(&mut app, "editor.tab_width");
        app.settings_adjust_value(1);
        let body = std::fs::read_to_string(ws.join(".mnml").join("config.toml")).unwrap();
        assert!(body.contains("[editor]"), "{body}");
        assert!(
            body.contains(&format!("tab_width = {}", app.config.editor.tab_width)),
            "{body}"
        );
    }

    #[test]
    fn esc_deletes_workspace_file_created_during_edit() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        let path = ws.join(".mnml").join("config.toml");
        assert!(!path.exists());
        app.open_settings_overlay();
        focus_row(&mut app, "ui.cursor_line");
        app.settings_adjust_value(1);
        assert!(path.exists(), "edit created the file");
        app.close_settings_overlay_cancel();
        assert!(!path.exists(), "Esc removed the edit-created file");
    }

    #[test]
    fn esc_restores_prior_workspace_file_and_preserves_comments() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        std::fs::create_dir_all(ws.join(".mnml")).unwrap();
        let path = ws.join(".mnml").join("config.toml");
        let original = "# project settings\n[editor]\ntab_width = 4  # ours\n";
        std::fs::write(&path, original).unwrap();
        // Reload so the workspace override is reflected in app.config.
        let cfg = Config::load(None, &ws);
        let mut app = App::new(ws.clone(), cfg).unwrap();
        app.open_settings_overlay();
        focus_row(&mut app, "ui.cursor_line");
        app.settings_adjust_value(1);
        let mid = std::fs::read_to_string(&path).unwrap();
        assert!(mid.contains("cursor_line = "), "wrote during edit");
        assert!(mid.contains("# ours"), "comment preserved during edit");
        app.close_settings_overlay_cancel();
        let restored = std::fs::read_to_string(&path).unwrap();
        assert_eq!(restored, original, "Esc restored the exact prior file");
    }
}
