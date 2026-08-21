//! Key handlers for modal overlays — help, git-commit textarea,
//! search section, discovery overlay, settings overlay, picker,
//! prompt. Each function is called from `dispatch_key` in
//! `src/tui/mod.rs` after `dispatch_key` has determined which
//! overlay (if any) is consuming keystrokes.
//!
//! Extracted from `src/tui/mod.rs` (T-3 of the file-split refactor —
//! 2026-06-28). Pure non-destructive move: each function keeps its
//! signature and visibility, only the file location changes.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::app::App;

/// Per-integration Settings pane key handler. Two modes:
///   NAV — arrows move focus, Enter starts text edit on the focused
///         field, Ctrl+S saves + closes, Esc closes without saving.
///   EDIT — printable keys append, Backspace deletes, Enter commits
///          (returns to NAV keeping the change), Esc cancels
///          (returns to NAV, restoring the original value).
pub(crate) fn handle_integration_settings_key(app: &mut App, key: KeyEvent) {
    let Some(state) = app.integration_settings.as_ref() else {
        return;
    };
    let editing = state.editing.is_some();
    if editing {
        match key.code {
            KeyCode::Esc => app.integration_settings_edit_cancel(),
            KeyCode::Enter => app.integration_settings_edit_commit(),
            KeyCode::Backspace => app.integration_settings_edit_backspace(),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.integration_settings_edit_push(c)
            }
            _ => {}
        }
        return;
    }
    // NAV mode.
    match key.code {
        KeyCode::Esc => app.close_integration_settings(),
        KeyCode::Char('s') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.save_integration_settings()
        }
        KeyCode::Enter => app.integration_settings_begin_edit(),
        KeyCode::Up | KeyCode::Char('k') => app.integration_settings_move_focus(-1),
        KeyCode::Down | KeyCode::Char('j') => app.integration_settings_move_focus(1),
        _ => {}
    }
}

/// First-launch wizard key handler. Sections + widgets described in
/// `src/app/first_launch.rs`. Keys:
///   Esc          — Ask me later (does NOT set complete)
///   Enter        — Finish (commits + sets complete)
///   ↑ ↓ / j k    — Move focused section (or, in AiRouting, sub-row)
///   1-6          — Jump directly to section N
///   ← → / h l    — For radio sections: cycle choice; for others: no-op
///   Space        — For AiRouting: cycle the focused row's choice
///   y / n        — For Nerd Font section: quick yes/no
pub(crate) fn handle_first_launch_key(app: &mut App, key: KeyEvent) {
    use crate::app::first_launch::WizardSection;
    let Some(state) = app.first_launch.as_ref() else {
        return;
    };
    let section = state.section();
    let sub_row = state.focused_ai_route_row;

    // Global keys first. Up/Down inside the AiRouting section moves the
    // sub-row (Claude ↔ Codex) instead of the section — the section
    // itself only advances when we're already at the last sub-row
    // moving down (or first sub-row moving up). Prevents "j drops out
    // of routing before I've picked Codex" surprise.
    match key.code {
        KeyCode::Esc => {
            app.close_first_launch_defer();
            return;
        }
        KeyCode::Enter => {
            app.close_first_launch_finish();
            return;
        }
        KeyCode::Up | KeyCode::Char('k') => {
            if matches!(section, WizardSection::AiRouting) && sub_row > 0 {
                if let Some(s) = app.first_launch.as_mut() {
                    s.focused_ai_route_row -= 1;
                }
                return;
            }
            if let Some(s) = app.first_launch.as_mut() {
                s.move_focus(-1);
                // Landing on AiRouting from above (via section wrap
                // from the first section) should focus the last row so
                // Down-arrow doesn't skip Codex on the way back.
                if matches!(s.section(), WizardSection::AiRouting) {
                    s.focused_ai_route_row = 1;
                }
            }
            return;
        }
        KeyCode::Down | KeyCode::Char('j') => {
            if matches!(section, WizardSection::AiRouting) && sub_row == 0 {
                if let Some(s) = app.first_launch.as_mut() {
                    s.focused_ai_route_row = 1;
                }
                return;
            }
            if let Some(s) = app.first_launch.as_mut() {
                s.move_focus(1);
            }
            return;
        }
        KeyCode::Char(c @ '1'..='6') => {
            if let Some(s) = app.first_launch.as_mut() {
                s.focused_section = (c as u8 - b'1') as usize;
                s.focused_ai_route_row = 0;
            }
            return;
        }
        _ => {}
    }

    // Section-specific handling.
    match section {
        WizardSection::AiBackend => match key.code {
            KeyCode::Left | KeyCode::Char('h') => cycle_ai_backend(app, -1),
            KeyCode::Right | KeyCode::Char('l') => cycle_ai_backend(app, 1),
            _ => {}
        },
        WizardSection::InputStyle => match key.code {
            KeyCode::Left | KeyCode::Char('h') => cycle_input_style(app, -1),
            KeyCode::Right | KeyCode::Char('l') => cycle_input_style(app, 1),
            _ => {}
        },
        WizardSection::NerdFont => match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => app.wizard_set_nerd_font_ok(true),
            KeyCode::Char('n') | KeyCode::Char('N') => app.wizard_set_nerd_font_ok(false),
            KeyCode::Left | KeyCode::Char('h') => app.wizard_set_nerd_font_ok(true),
            KeyCode::Right | KeyCode::Char('l') => app.wizard_set_nerd_font_ok(false),
            // Space fires the auto-install (brew / winget / curl per
            // OS). Wizard closes so the install-Pty is visible.
            KeyCode::Char(' ') => app.wizard_install_nerd_font(),
            _ => {}
        },
        WizardSection::AiRouting => match key.code {
            KeyCode::Left | KeyCode::Char('h') => cycle_ai_routing(app, sub_row, -1),
            KeyCode::Right | KeyCode::Char('l') | KeyCode::Char(' ') => {
                cycle_ai_routing(app, sub_row, 1)
            }
            _ => {}
        },
        WizardSection::ClaudeCode => {
            // Space fires the install (npm install -g …) in a Pty
            // pane. Wizard closes so the Pty is visible.
            if matches!(key.code, KeyCode::Char(' ')) {
                app.wizard_install_ai_clis();
            }
        }
        WizardSection::VscodeShim => {
            if matches!(key.code, KeyCode::Char(' ')) {
                app.wizard_install_vscode_shim();
            }
        }
    }
}

/// Cycle the focused AI-routing row's backend chip. Row 0 = Claude
/// (Auto / Sub / API / Off), row 1 = Codex (Auto / Sub / API / Off).
fn cycle_ai_routing(app: &mut App, row: usize, delta: i32) {
    // Codex supports both ChatGPT Plus/Team sub auth AND the
    // OpenAI API key (`$OPENAI_API_KEY`) — same option set as
    // Claude. Empty string ("") = Auto. Corrected 2026-08-17
    // (was missing "api" — user flag).
    let (choices_claude, choices_codex): (&[&str], &[&str]) =
        (&["", "sub", "api", "off"], &["", "sub", "api", "off"]);
    match row {
        0 => {
            let cur = app
                .first_launch
                .as_ref()
                .map(|s| s.answers.route_claude.clone())
                .unwrap_or_default();
            let idx = choices_claude.iter().position(|c| *c == cur).unwrap_or(0) as i32;
            let next = (idx + delta).rem_euclid(choices_claude.len() as i32) as usize;
            app.wizard_set_route_claude(choices_claude[next]);
        }
        1 => {
            let cur = app
                .first_launch
                .as_ref()
                .map(|s| s.answers.route_codex.clone())
                .unwrap_or_default();
            let idx = choices_codex.iter().position(|c| *c == cur).unwrap_or(0) as i32;
            let next = (idx + delta).rem_euclid(choices_codex.len() as i32) as usize;
            app.wizard_set_route_codex(choices_codex[next]);
        }
        _ => {}
    }
}

fn cycle_ai_backend(app: &mut App, delta: i32) {
    const CHOICES: [&str; 4] = ["claude-code", "claude-api", "local", "skip"];
    let cur = app
        .first_launch
        .as_ref()
        .map(|s| s.answers.ai_backend.clone())
        .unwrap_or_default();
    let idx = CHOICES.iter().position(|c| *c == cur).unwrap_or(0) as i32;
    let next = (idx + delta).rem_euclid(CHOICES.len() as i32) as usize;
    app.wizard_set_ai_backend(CHOICES[next]);
}

fn cycle_input_style(app: &mut App, delta: i32) {
    const CHOICES: [&str; 2] = ["vim", "standard"];
    let cur = app
        .first_launch
        .as_ref()
        .map(|s| s.answers.input_style.clone())
        .unwrap_or_default();
    let idx = CHOICES.iter().position(|c| *c == cur).unwrap_or(0) as i32;
    let next = (idx + delta).rem_euclid(CHOICES.len() as i32) as usize;
    // wizard_set_input_style also flips `input_style_touched = true`
    // (see src/app/first_launch.rs) so persist-on-Finish knows the
    // user actively picked rather than just accepting the pre-select.
    app.wizard_set_input_style(CHOICES[next]);
}

pub(crate) fn handle_help_overlay_key(app: &mut App, key: KeyEvent) {
    // #polish 2026-07-06 — filter-input mode. `/` enters; typed
    // chars append; Backspace removes; Enter or Esc leaves the
    // input focused-out (query stays). Esc a second time closes
    // the overlay.
    let filter_focused = app
        .help_overlay
        .as_ref()
        .map(|s| s.filter_focused)
        .unwrap_or(false);
    if filter_focused {
        // Enter / Esc first — they exit filter mode.
        match key.code {
            KeyCode::Esc | KeyCode::Enter => {
                if let Some(state) = app.help_overlay.as_mut() {
                    state.filter_focused = false;
                }
                return;
            }
            _ => {}
        }
        // 2026-08-08 — common Ctrl/Cmd shortcuts: Ctrl+U clears,
        // Ctrl+W kills the trailing word, Ctrl+V pastes.
        if let Some(state) = app.help_overlay.as_mut() {
            let before_len = state.query.len();
            let r = crate::ui::text_input::handle_filter_shortcut(
                key,
                &mut state.query,
                Some(&mut app.clipboard),
            );
            if r == crate::ui::text_input::TextKeyResult::Handled {
                if let Some(state) = app.help_overlay.as_mut()
                    && state.query.len() != before_len
                {
                    state.scroll = 0;
                }
                return;
            }
        }
        if let KeyCode::Char(c) = key.code
            && !key.modifiers.contains(KeyModifiers::CONTROL)
            && let Some(state) = app.help_overlay.as_mut()
        {
            state.query.push(c);
            state.scroll = 0;
        }
        return;
    }
    match key.code {
        KeyCode::Esc | KeyCode::F(1) => app.close_help_overlay(),
        KeyCode::Up | KeyCode::Char('k') => app.help_scroll(-1),
        KeyCode::Down | KeyCode::Char('j') => app.help_scroll(1),
        KeyCode::PageUp => app.help_scroll(-10),
        KeyCode::PageDown => app.help_scroll(10),
        KeyCode::Home => app.help_scroll(-1_000_000),
        KeyCode::End => app.help_scroll(1_000_000),
        // `/` focuses the filter input.
        KeyCode::Char('/') => {
            if let Some(state) = app.help_overlay.as_mut() {
                state.filter_focused = true;
            }
        }
        // `c` collapses ALL sections; `e` expands all. Quick way
        // to scan or focus.
        KeyCode::Char('c') => {
            if let Some(state) = app.help_overlay.as_mut() {
                // Collect all section names from current registry
                // — match what the renderer iterates over.
                let rows = crate::app::help::build_help(&app.keymap);
                for r in &rows {
                    if let crate::app::help::HelpRow::Section(name) = r {
                        state.collapsed.insert((*name).to_string());
                    }
                }
                state.scroll = 0;
            }
        }
        KeyCode::Char('e') => {
            if let Some(state) = app.help_overlay.as_mut() {
                state.collapsed.clear();
                state.scroll = 0;
            }
        }
        _ => {}
    }
}

pub(crate) fn handle_git_section_commit_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    // Enter / Esc first — surface-specific meaning.
    match key.code {
        KeyCode::Esc => {
            app.git_section_commit_blur();
            return;
        }
        KeyCode::Enter if ctrl => {
            app.git_section_commit_submit();
            return;
        }
        _ => {}
    }
    // 2026-08-08 — common Ctrl+U / Ctrl+W / Ctrl+V shortcuts on the
    // git commit input. This buffer is append-only (no caret model),
    // so the filter-shortcut helper is the right level.
    let r = crate::ui::text_input::handle_filter_shortcut(
        key,
        &mut app.git_section_commit_buffer,
        Some(&mut app.clipboard),
    );
    if r == crate::ui::text_input::TextKeyResult::Handled {
        return;
    }
    if let KeyCode::Char(c) = key.code
        && !ctrl
    {
        app.git_section_commit_insert_char(c);
    }
}

pub(crate) fn handle_search_section_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    // Enter / Esc / arrow-select first — surface-specific meaning.
    match key.code {
        KeyCode::Esc => {
            app.search_section_blur();
            return;
        }
        KeyCode::Enter => {
            if app.search_query.trim().is_empty() && !app.search_hits.is_empty() {
                app.search_section_open_selected();
            } else {
                app.search_section_run();
            }
            return;
        }
        // #1112 (2026-08-20) — Alt+Up/Alt+Down walks the MRU query
        // history (VS Code parity). Preserves the older behavior:
        // bare Up/Down still moves the results-list selection.
        KeyCode::Up if key.modifiers.contains(KeyModifiers::ALT) => {
            app.search_section_history_step(-1);
            return;
        }
        KeyCode::Down if key.modifiers.contains(KeyModifiers::ALT) => {
            app.search_section_history_step(1);
            return;
        }
        KeyCode::Up if !ctrl => {
            app.search_section_select(-1);
            return;
        }
        KeyCode::Down if !ctrl => {
            app.search_section_select(1);
            return;
        }
        _ => {}
    }
    // 2026-08-08 — common Ctrl+U / Ctrl+W / Ctrl+V shortcuts. The
    // search cursor field lives alongside `search_query`; keep it
    // in sync after any mutation.
    let before = app.search_query.len();
    let r = crate::ui::text_input::handle_filter_shortcut(
        key,
        &mut app.search_query,
        Some(&mut app.clipboard),
    );
    if r == crate::ui::text_input::TextKeyResult::Handled {
        if app.search_query.len() != before {
            app.search_cursor = app.search_query.chars().count();
        }
        return;
    }
    if let KeyCode::Char(c) = key.code
        && !ctrl
    {
        app.search_section_insert_char(c);
    }
}

/// Key dispatch for the integration-edit overlay (right-click chip
/// → Edit / Add custom). Steals every key until Enter saves or Esc
/// cancels.
pub(crate) fn handle_integration_edit_key(app: &mut App, key: KeyEvent) {
    use crate::app::discovery::IntegrationEditField;
    let focused = app.integration_edit.as_ref().map(|p| p.focused_field);
    let glyph_focused = matches!(focused, Some(IntegrationEditField::Glyph));
    let color_focused = matches!(focused, Some(IntegrationEditField::Color));
    // Text-editable field (not Color, not Glyph — Glyph is a
    // menu-style single-char, not typed inline).
    let text_field = matches!(
        focused,
        Some(IntegrationEditField::Id)
            | Some(IntegrationEditField::Command)
            | Some(IntegrationEditField::Fallback)
            | Some(IntegrationEditField::Label)
    );
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    // Ctrl+V paste (2026-07-11 user request — was missing).
    if ctrl && matches!(key.code, KeyCode::Char('v' | 'V')) && text_field {
        app.integration_edit_paste();
        return;
    }
    // 2026-08-08 — Ctrl+A/E (home/end), Ctrl+U (kill to start),
    // Ctrl+W (word back), Ctrl+K (kill to end). Prompt-tier
    // shortcut coverage on every text field.
    if text_field {
        use crate::ui::text_input::{TextKeyResult, TextOps, handle_common_text_key};
        let mut ops = TextOps::new(app);
        ops.backspace = Some(|app| app.integration_edit_backspace());
        ops.delete_forward = Some(|app| app.integration_edit_delete_forward());
        ops.delete_word_back = Some(|app| app.integration_edit_delete_word_back());
        ops.delete_to_start = Some(|app| app.integration_edit_delete_to_start());
        ops.delete_to_end = Some(|app| app.integration_edit_delete_to_end());
        ops.move_left = Some(|app| app.integration_edit_move_left());
        ops.move_right = Some(|app| app.integration_edit_move_right());
        ops.move_home = Some(|app| app.integration_edit_move_home());
        ops.move_end = Some(|app| app.integration_edit_move_end());
        if handle_common_text_key(key, None, ops) == TextKeyResult::Handled {
            return;
        }
    }
    match key.code {
        KeyCode::Esc => app.integration_edit_cancel(),
        // Enter on the Glyph field opens the 3-option chooser (Choose
        // from library / Edit current / Create custom). Enter on any
        // other field saves.
        KeyCode::Enter if glyph_focused => app.open_glyph_action_menu(),
        KeyCode::Enter => app.integration_edit_save(),
        // → on the Glyph field opens the picker (Glyph is a menu-style
        // choice, not a text field). → on Color cycles the palette.
        // → on text fields moves the caret one char.
        KeyCode::Right if glyph_focused => app.open_icon_picker(),
        KeyCode::Right if color_focused => app.integration_edit_color_cycle(1),
        KeyCode::Right if text_field => app.integration_edit_move_right(),
        // Ctrl+N on the Glyph field opens the glyph builder — bake a
        // custom SVG into MnmlSymbols and route the codepoint back
        // into this edit panel's Glyph field on commit.
        KeyCode::Char('n') if glyph_focused && ctrl => {
            app.open_glyph_builder_from_edit();
        }
        // Some terminals emit Shift+Tab as `Tab` + SHIFT modifier
        // instead of `BackTab` (crossterm normalization varies by
        // terminal). Treat both as reverse cycling. vscode-user-kb
        // round 4 (2026-07-11).
        KeyCode::Tab if key.modifiers.contains(KeyModifiers::SHIFT) => {
            app.integration_edit_cycle_field(-1)
        }
        KeyCode::Tab => app.integration_edit_cycle_field(1),
        KeyCode::BackTab => app.integration_edit_cycle_field(-1),
        KeyCode::Left if color_focused => app.integration_edit_color_cycle(-1),
        KeyCode::Left if text_field => app.integration_edit_move_left(),
        KeyCode::Home if text_field => app.integration_edit_move_home(),
        KeyCode::End if text_field => app.integration_edit_move_end(),
        KeyCode::Delete if text_field => app.integration_edit_delete_forward(),
        KeyCode::Up => app.integration_edit_cycle_field(-1),
        KeyCode::Down => app.integration_edit_cycle_field(1),
        KeyCode::Backspace => app.integration_edit_backspace(),
        KeyCode::Char(c) if !ctrl => {
            app.integration_edit_type_char(c);
        }
        _ => {}
    }
}

/// Key dispatch for the glyph builder panel — path/name/codepoint
/// are text fields, category/width/height/center cycle with ←→.
pub(crate) fn handle_glyph_builder_key(app: &mut App, key: KeyEvent) {
    use crate::glyph_builder::BuilderField;
    let text_field = matches!(
        app.glyph_builder.as_ref().map(|s| s.focused_field),
        Some(BuilderField::Path) | Some(BuilderField::Name) | Some(BuilderField::Codepoint)
    );
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    // Ctrl+V paste — user request 2026-07-11.
    if ctrl && matches!(key.code, KeyCode::Char('v' | 'V')) && text_field {
        app.glyph_builder_paste();
        return;
    }
    // Ctrl+O opens the SVG fuzzy picker — keyboard parallel to
    // the [Browse] chip. Only meaningful when the path field is
    // focused, but harmless from any field.
    if ctrl && matches!(key.code, KeyCode::Char('o' | 'O')) {
        app.open_glyph_builder_svg_picker();
        return;
    }
    // 2026-08-08 — Ctrl+A/E (home/end), Ctrl+U (kill to start),
    // Ctrl+W (word back), Ctrl+K (kill to end), Alt+←→ / Ctrl+←→
    // (word motion), Cmd+Backspace (kill to start), Alt+Backspace
    // (word back). Same shortcut coverage as the prompt overlay so
    // typing feels the same regardless of which panel is open.
    if text_field {
        use crate::ui::text_input::{TextKeyResult, TextOps, handle_common_text_key};
        let mut ops = TextOps::new(app);
        ops.backspace = Some(|app| app.glyph_builder_backspace());
        ops.delete_forward = Some(|app| app.glyph_builder_delete_forward());
        ops.delete_word_back = Some(|app| app.glyph_builder_delete_word_back());
        ops.delete_to_start = Some(|app| app.glyph_builder_delete_to_start());
        ops.delete_to_end = Some(|app| app.glyph_builder_delete_to_end());
        ops.move_left = Some(|app| app.glyph_builder_move_left());
        ops.move_right = Some(|app| app.glyph_builder_move_right());
        ops.move_home = Some(|app| app.glyph_builder_move_home());
        ops.move_end = Some(|app| app.glyph_builder_move_end());
        if handle_common_text_key(key, None, ops) == TextKeyResult::Handled {
            return;
        }
    }
    match key.code {
        KeyCode::Esc => app.close_glyph_builder(),
        KeyCode::Enter => app.glyph_builder_commit(),
        // Shift+Tab normalization — same as integration_edit above.
        KeyCode::Tab if key.modifiers.contains(KeyModifiers::SHIFT) => {
            app.glyph_builder_cycle_field(-1)
        }
        KeyCode::Tab => app.glyph_builder_cycle_field(1),
        KeyCode::BackTab => app.glyph_builder_cycle_field(-1),
        KeyCode::Up => app.glyph_builder_cycle_field(-1),
        KeyCode::Down => app.glyph_builder_cycle_field(1),
        // Left / Right cycle values on the non-text fields; on text
        // fields they move the caret one char (fixes the reported
        // "can't arrow back to fix mid-string typos" — 2026-07-11).
        KeyCode::Left if !text_field => app.glyph_builder_cycle_value(-1),
        KeyCode::Right if !text_field => app.glyph_builder_cycle_value(1),
        // Reset focused numeric field to its default: `r`. Reset
        // all numeric fields: `R` (Shift+r). Text fields ignore
        // both (nothing sensible to reset to). 2026-07-19 user
        // request.
        KeyCode::Char('r') if !text_field && !key.modifiers.contains(KeyModifiers::SHIFT) => {
            app.glyph_builder_reset_focused();
        }
        KeyCode::Char('R') if !text_field => app.glyph_builder_reset_all(),
        KeyCode::Left if text_field => app.glyph_builder_move_left(),
        KeyCode::Right if text_field => app.glyph_builder_move_right(),
        KeyCode::Home if text_field => app.glyph_builder_move_home(),
        KeyCode::End if text_field => app.glyph_builder_move_end(),
        KeyCode::Delete if text_field => app.glyph_builder_delete_forward(),
        KeyCode::Backspace => app.glyph_builder_backspace(),
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.glyph_builder_type_char(c);
        }
        _ => {}
    }
}

pub(crate) fn handle_settings_overlay_key(app: &mut App, key: KeyEvent) {
    // Filter input has priority when focused — chars append to the
    // query, Enter commits + unfocuses, Esc clears + unfocuses.
    let filter_focused = app
        .settings_overlay
        .as_ref()
        .is_some_and(|s| s.filter_focused);
    if filter_focused {
        // Enter / Esc first — commit / cancel.
        match key.code {
            KeyCode::Esc => {
                // 2026-08-10 e2e-fix — Esc on an EMPTY filter should
                // close the overlay outright; only clear+unfocus the
                // filter when it has query text. Matches VS Code +
                // the settings-overlay contract "Esc dismisses".
                // Without this, R9's filter-focused-by-default made
                // Esc need two presses to close an untouched overlay.
                let is_empty = app
                    .settings_overlay
                    .as_ref()
                    .is_some_and(|s| s.filter.is_empty());
                if is_empty {
                    app.close_settings_overlay_cancel();
                } else {
                    app.settings_filter_cancel();
                }
                return;
            }
            KeyCode::Enter => {
                app.settings_filter_commit();
                return;
            }
            // 2026-08-10 e2e-fix — nav keys (arrows / hjkl) always
            // route to row nav + value adjust even when filter is
            // focused. Filter has no visible cursor to move so
            // trapping arrows there was just a keystroke sink;
            // pairs with R9's auto-focus-on-open so `→` still
            // adjusts row 0 without a `/` detour.
            KeyCode::Up => {
                app.settings_move_row(-1);
                return;
            }
            KeyCode::Down => {
                app.settings_move_row(1);
                return;
            }
            KeyCode::Left => {
                app.settings_adjust_value(-1);
                return;
            }
            KeyCode::Right => {
                app.settings_adjust_value(1);
                return;
            }
            _ => {}
        }
        // 2026-08-08 — common Ctrl+U / Ctrl+W / Ctrl+V shortcuts on
        // the settings filter buffer.
        if let Some(state) = &mut app.settings_overlay {
            let r = crate::ui::text_input::handle_filter_shortcut(
                key,
                &mut state.filter,
                Some(&mut app.clipboard),
            );
            if r == crate::ui::text_input::TextKeyResult::Handled {
                return;
            }
        }
        if let KeyCode::Char(c) = key.code
            && !key.modifiers.contains(KeyModifiers::CONTROL)
        {
            app.settings_filter_push(c);
        }
        return;
    }
    // `/` at the top level focuses the filter (matches the
    // Integrations / Agents rail idiom).
    if let KeyCode::Char('/') = key.code
        && !key.modifiers.contains(KeyModifiers::CONTROL)
        && !app.settings_text_edit_active()
    {
        app.settings_filter_focus();
        return;
    }
    // Text/Color rows enter a greedy edit mode on Enter — every
    // keystroke goes to the buffer until Enter commits (or Esc
    // cancels). Other navigation keys are intercepted to avoid the
    // overlay reacting twice.
    if app.settings_text_edit_active() {
        // Enter / Esc first — commit / cancel.
        match key.code {
            KeyCode::Esc => {
                app.settings_text_edit_cancel();
                return;
            }
            KeyCode::Enter => {
                app.settings_text_edit_commit();
                return;
            }
            _ => {}
        }
        // 2026-08-08 — route common Ctrl/Cmd shortcuts through the
        // shared helper: Ctrl+A/E (home/end), Ctrl+U (kill to
        // start), Ctrl+W (word back), Ctrl+K (kill to end), Ctrl+V
        // (paste), Alt+←→ / Ctrl+←→ (word motion),
        // Cmd+Backspace (kill to start), Alt+Backspace (word back).
        use crate::ui::text_input::{
            TextKeyResult, TextOps, clipboard_text_if_paste, handle_common_text_key,
        };
        let paste_text = clipboard_text_if_paste(key, &mut app.clipboard);
        let mut ops = TextOps::new(app);
        ops.insert_str = Some(|app, s| {
            for c in s.chars() {
                if !c.is_control() {
                    app.settings_text_edit_insert(c);
                }
            }
        });
        ops.backspace = Some(|app| app.settings_text_edit_backspace());
        ops.delete_forward = Some(|app| app.settings_text_edit_delete());
        ops.delete_word_back = Some(|app| {
            // Repeated backspace until we've crossed a
            // whitespace-run + a non-whitespace-run boundary.
            // Cheap-and-correct: read the buffer, compute the cut
            // point, then apply as many backspaces as needed so
            // apply_text_setting fires once per char (keeps the
            // live-update semantics settings_text_edit relies on).
            let (cur, cut) = {
                let Some(state) = app.settings_overlay.as_ref() else {
                    return;
                };
                let Some(edit) = state.text_edit.as_ref() else {
                    return;
                };
                let cur = edit.cursor.min(edit.buffer.len());
                let head = &edit.buffer[..cur];
                let trimmed = head.trim_end_matches(char::is_whitespace);
                let cut = trimmed
                    .char_indices()
                    .rev()
                    .find(|&(_, c)| c.is_whitespace())
                    .map(|(i, c)| i + c.len_utf8())
                    .unwrap_or(0);
                (cur, cut)
            };
            let mut remaining = cur - cut;
            while remaining > 0 {
                let before = app
                    .settings_overlay
                    .as_ref()
                    .and_then(|s| s.text_edit.as_ref())
                    .map(|e| e.cursor)
                    .unwrap_or(0);
                app.settings_text_edit_backspace();
                let after = app
                    .settings_overlay
                    .as_ref()
                    .and_then(|s| s.text_edit.as_ref())
                    .map(|e| e.cursor)
                    .unwrap_or(0);
                if after == before {
                    break;
                }
                remaining = remaining.saturating_sub(before - after);
            }
        });
        ops.delete_to_start = Some(|app| {
            while app
                .settings_overlay
                .as_ref()
                .and_then(|s| s.text_edit.as_ref())
                .map(|e| e.cursor > 0)
                .unwrap_or(false)
            {
                app.settings_text_edit_backspace();
            }
        });
        ops.delete_to_end = Some(|app| {
            while app
                .settings_overlay
                .as_ref()
                .and_then(|s| s.text_edit.as_ref())
                .map(|e| e.cursor < e.buffer.len())
                .unwrap_or(false)
            {
                app.settings_text_edit_delete();
            }
        });
        ops.move_left = Some(|app| app.settings_text_edit_move_left());
        ops.move_right = Some(|app| app.settings_text_edit_move_right());
        ops.move_home = Some(|app| app.settings_text_edit_home());
        ops.move_end = Some(|app| app.settings_text_edit_end());
        if handle_common_text_key(key, paste_text.as_deref(), ops) == TextKeyResult::Handled {
            return;
        }
        if let KeyCode::Char(c) = key.code
            && !key.modifiers.contains(KeyModifiers::CONTROL)
        {
            app.settings_text_edit_insert(c);
        }
        return;
    }
    match key.code {
        KeyCode::Esc => app.close_settings_overlay_cancel(),
        KeyCode::Enter => app.settings_enter_row(),
        KeyCode::Up | KeyCode::Char('k') => app.settings_move_row(-1),
        KeyCode::Down | KeyCode::Char('j') => app.settings_move_row(1),
        KeyCode::Left | KeyCode::Char('h') => app.settings_adjust_value(-1),
        KeyCode::Right | KeyCode::Char('l') => app.settings_adjust_value(1),
        // keyboard-round-11 SEV-3 F5 2026-07-14 — dispatch by the
        // SHIFT modifier, not the char case. Real terminals deliver
        // Shift+R as `Char('R')` naked (no SHIFT bit); IPC harnesses
        // deliver it as `Char('r') + SHIFT`. Was: `Char('r')` alone
        // handled reset-row, `Char('R')` alone handled reset-all —
        // so IPC's `shift+r` (case-lowered `r` with SHIFT) matched
        // the first arm and only reset the row. Now: SHIFT-any-case
        // → reset-all, plain `r` → reset-row. Also allows `R` under
        // Caps Lock without Shift to still reset-all (matches the
        // pre-fix terminal behavior).
        KeyCode::Char(c) if c.eq_ignore_ascii_case(&'r') => {
            if key.modifiers.contains(KeyModifiers::SHIFT) || c == 'R' {
                app.config = crate::config::Config::default();
                app.toast("settings: all reset to defaults");
            } else {
                app.settings_reset_row();
            }
        }
        _ => {}
    }
}

pub(crate) fn handle_picker_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    // R11 vscode-keyboard SEV-2 — Ctrl+Shift+P used to reopen the
    // palette on top of itself instead of toggling it closed
    // (VS Code convention: same chord opens AND dismisses).
    // Catch it at the top of the picker handler and close the
    // palette when it's the active picker.
    if ctrl
        && key.modifiers.contains(KeyModifiers::SHIFT)
        && matches!(key.code, KeyCode::Char('P') | KeyCode::Char('p'))
        && let Some(p) = app.picker.as_ref()
    {
        // R11: Commands picker → toggle closed (VS Code convention).
        // R12 nvchad SEV-2: any OTHER picker (Files/Recent/Grep/…) →
        // close the current picker AND open the palette, so the
        // chord always reaches the palette regardless of what's
        // already open.
        if matches!(p.kind, crate::picker::PickerKind::Commands) {
            app.close_picker();
        } else {
            app.close_picker();
            crate::command::run("palette", app);
        }
        return;
    }
    let Some(picker) = app.picker.as_mut() else {
        return;
    };
    match key.code {
        KeyCode::Esc => app.close_picker(),
        // Tab on a picker → "secondary accept" — picker-specific
        // behavior. No-op for every kind right now; left as a hook
        // for future per-kind use (the 2026-06 SCM split removed the
        // cross-host PR picker that originally drove this).
        KeyCode::Tab => app.picker_accept_secondary(),
        KeyCode::Enter => app.picker_accept(),
        KeyCode::Up => {
            picker.move_up();
            app.on_picker_moved();
        }
        KeyCode::Down => {
            picker.move_down();
            app.on_picker_moved();
        }
        // Left / Right only navigate in grid mode (icon picker). List
        // pickers ignore them so typing arrow-shaped modifiers into
        // paths doesn't disturb the selection.
        KeyCode::Left => {
            picker.move_left();
            app.on_picker_moved();
        }
        KeyCode::Right => {
            picker.move_right();
            app.on_picker_moved();
        }
        KeyCode::Char('p') if ctrl => {
            picker.move_up();
            app.on_picker_moved();
        }
        KeyCode::Char('n') if ctrl => {
            picker.move_down();
            app.on_picker_moved();
        }
        KeyCode::Char('u') if ctrl => picker.clear_query(),
        // 2026-08-08 — Ctrl+W kill-word-back on the picker filter,
        // matching every other filter surface.
        KeyCode::Char('w') if ctrl => {
            crate::ui::text_input::delete_word_back_in_string(&mut picker.query);
            picker.refilter();
        }
        // R7 nvchad SEV-3 2026-08-08 — Ctrl+V paste on picker filter.
        // Previously only bracketed (Cmd+V) paste worked because the
        // Event::Paste path routed to `picker.insert_str`. Users on
        // Linux terminals that don't emit bracketed-paste got no
        // paste at all. `Picker::insert_str` already strips control
        // chars + newlines internally, so no separate sanitize pass
        // is needed here.
        KeyCode::Char('v' | 'V') if ctrl => {
            let clip = app.clipboard.text();
            if !clip.is_empty() {
                picker.insert_str(&clip);
            }
        }
        // Ctrl+E on the icon picker: re-tune the currently-highlighted
        // custom glyph via the glyph builder, pre-filled from its
        // stored metadata. No-op when the selected glyph wasn't baked
        // via mnml (no meta entry) — toasts a hint. Ctrl is required
        // so bare 'e' can still filter the query string.
        KeyCode::Char('e')
            if ctrl && matches!(picker.kind, crate::picker::PickerKind::IconGlyphs) =>
        {
            let sel = picker.selected_item().cloned();
            match sel {
                // On the "+ Create custom glyph" banner: Ctrl+E is a
                // no-op ("nothing to edit"). Toast so the user knows
                // Ctrl+E was received but doesn't apply here.
                Some(it) if it.id == "new" => {
                    app.toast("Ctrl+E edits an existing glyph — move to a glyph first");
                }
                Some(it) => {
                    if let Ok(cp) = u32::from_str_radix(&it.id, 16) {
                        if !app.open_glyph_builder_for_edit_cp(cp) {
                            app.toast(format!(
                                "glyph U+{cp:04X} wasn't built via mnml — no metadata to edit"
                            ));
                        }
                    } else {
                        app.toast(format!("Ctrl+E: can't parse codepoint from id {:?}", it.id));
                    }
                }
                None => {
                    app.toast("Ctrl+E: no glyph selected");
                }
            }
        }
        KeyCode::Backspace => picker.backspace(),
        KeyCode::Char(c) if !ctrl => {
            // keyboard-round-8 SEV-3 2026-07-11 — VS Code Ctrl+P
            // mode-switch prefixes when the query is empty and the
            // picker kind is Files/Recent:
            //   `>` → command palette
            //   `@` → LSP document symbols (current file)
            //   `#` → LSP workspace symbols
            if picker.query.is_empty()
                && matches!(
                    picker.kind,
                    crate::picker::PickerKind::Files | crate::picker::PickerKind::Recent
                )
            {
                match c {
                    '>' => {
                        app.close_picker();
                        crate::command::run("palette", app);
                        return;
                    }
                    '@' => {
                        // keyboard-round-9 SEV-2 2026-07-14 — the `@`
                        // mode-switch closes the picker and fires an
                        // async `textDocument/documentSymbol` request.
                        // On a small file (or before the LSP has fully
                        // initialized) the reply either doesn't arrive
                        // or arrives with 0 symbols — either way the
                        // user saw a black hole: picker gone, no
                        // feedback. Toast at fire-time so the picker
                        // close has visible cause even if the reply
                        // is empty / delayed. design-round-4 issue 6
                        // 2026-07-14 — lowercased to match the
                        // `noun: state` toast convention (`"inlay
                        // hints: on"`, `"tab-bar AI chips: hidden"`).
                        app.close_picker();
                        app.toast("symbols: fetching…");
                        crate::command::run("lsp.symbols", app);
                        return;
                    }
                    '#' => {
                        // design-round-4 issue 5 2026-07-14 — same
                        // async-black-hole risk as `@`; `#` opens a
                        // query prompt but the prompt itself + the
                        // downstream `workspace/symbol` reply can
                        // both be slow / empty on unwarmed LSPs. Add
                        // the integration toast so the pair behaves the
                        // same way.
                        app.close_picker();
                        app.toast("workspace symbols: fetching…");
                        crate::command::run("lsp.workspace_symbols", app);
                        return;
                    }
                    // R8 audit follow-up (2026-08-20) — `?` on an
                    // empty file-picker query surfaces the other
                    // prefixes as a single toast. Simpler than a
                    // dedicated help pane and matches how VS Code's
                    // quick-open `?` behaves. Toast lands over the
                    // picker; the picker itself stays open so the
                    // user can type the prefix they just learned
                    // about.
                    '?' => {
                        app.toast(
                            "picker prefixes:  >  commands  ·  @  file symbols  ·  #  workspace symbols",
                        );
                        return;
                    }
                    _ => {}
                }
            }
            picker.type_char(c);
        }
        _ => {}
    }
}

fn run_quit_button(app: &mut App, code: u8) {
    use crate::ui::prompt::{
        QUIT_BTN_CANCEL, QUIT_BTN_QUIT_ANYWAY, QUIT_BTN_QUIT_CLEAN, QUIT_BTN_SAVE_ALL,
    };
    match code {
        QUIT_BTN_SAVE_ALL => {
            app.save_all();
            app.should_quit = true;
        }
        QUIT_BTN_QUIT_ANYWAY | QUIT_BTN_QUIT_CLEAN => {
            app.should_quit = true;
        }
        QUIT_BTN_CANCEL => {
            // Prompt already cleared by caller.
        }
        _ => {}
    }
}

/// #20 Pattern B — confirm-modal key routing. Handled before
/// the regular prompt path in dispatch_key.
pub(crate) fn handle_confirm_modal_key(app: &mut App, key: KeyEvent) {
    let Some(c) = app.pending_confirm.as_mut() else {
        return;
    };
    match key.code {
        KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('N') => {
            app.dismiss_pending_confirm();
        }
        KeyCode::Char('y') | KeyCode::Char('Y') => {
            app.commit_pending_confirm();
        }
        KeyCode::Left | KeyCode::Right | KeyCode::Tab | KeyCode::BackTab => {
            c.focused = 1 - c.focused;
        }
        KeyCode::Enter | KeyCode::Char(' ') => {
            if c.focused == 1 {
                app.commit_pending_confirm();
            } else {
                app.dismiss_pending_confirm();
            }
        }
        _ => {}
    }
}

pub(crate) fn handle_prompt_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    // R10 vscode-keyboard SEV-2 — Ctrl+Shift+P from inside a prompt
    // used to be swallowed by the prompt input handler below, so
    // the palette-open path (which now dismisses the underlying
    // prompt in `open_command_palette`) never ran. Escape the
    // prompt first, then run the palette command; `open_command_palette`
    // itself will re-clear `app.prompt` for extra safety.
    if ctrl
        && key.modifiers.contains(KeyModifiers::SHIFT)
        && matches!(key.code, KeyCode::Char('P') | KeyCode::Char('p'))
    {
        app.prompt = None;
        crate::command::run("palette", app);
        return;
    }
    let Some(p) = app.prompt.as_mut() else { return };
    // #polish 2026-07-06 — DeleteConfirm — button dialog. Same
    // shape as QuitConfirm: Left/Right cycle, Enter fires focused
    // button, hotkeys D/C, Esc cancels.
    if matches!(p.kind, crate::prompt::PromptKind::DeleteConfirm) {
        let buttons = crate::ui::prompt::delete_buttons();
        let n = buttons.len();
        match key.code {
            KeyCode::Esc => {
                app.prompt = None;
                app.run_delete_button(crate::ui::prompt::CONFIRM_BTN_CANCEL);
                return;
            }
            KeyCode::Left | KeyCode::BackTab => {
                p.cursor = (p.cursor + n - 1) % n;
                return;
            }
            KeyCode::Right | KeyCode::Tab => {
                p.cursor = (p.cursor + 1) % n;
                return;
            }
            KeyCode::Enter => {
                let selected = p.cursor.min(buttons.len() - 1);
                let code = buttons[selected].1;
                app.prompt = None;
                app.run_delete_button(code);
                return;
            }
            KeyCode::Char(c) => {
                let low = c.to_ascii_lowercase();
                let hit = match low {
                    'd' | 'y' => Some(crate::ui::prompt::CONFIRM_BTN_PRIMARY),
                    'c' | 'n' => Some(crate::ui::prompt::CONFIRM_BTN_CANCEL),
                    _ => None,
                };
                if let Some(code) = hit {
                    app.prompt = None;
                    app.run_delete_button(code);
                }
                return;
            }
            _ => return,
        }
    }
    // #polish 2026-07-06 — every other destructive confirm
    // (git delete branch / stash drop / worktree remove / tag
    // delete / hunk discard / claude kill / merge / rebase).
    // Same shape as DeleteConfirm above; per-kind label + magic
    // input come from `confirm_buttons` + `run_confirm_button`.
    if let Some(buttons) = crate::ui::prompt::confirm_buttons(&p.kind) {
        let n = buttons.len();
        match key.code {
            KeyCode::Esc => {
                app.run_confirm_button(false);
                return;
            }
            KeyCode::Left | KeyCode::BackTab => {
                p.cursor = (p.cursor + n - 1) % n;
                return;
            }
            KeyCode::Right | KeyCode::Tab => {
                p.cursor = (p.cursor + 1) % n;
                return;
            }
            KeyCode::Enter => {
                let selected = p.cursor.min(n - 1);
                let primary = selected == 0;
                app.run_confirm_button(primary);
                return;
            }
            KeyCode::Char(c) => {
                let low = c.to_ascii_lowercase();
                // Hotkey: first alpha of primary label matches primary,
                // first alpha of cancel label matches cancel, `y`
                // always primary, `n` always cancel. Reading BOTH
                // labels dynamically fixes the design-critic 2026-07-06
                // finding — `AiToolConfirm`'s cancel label is "Deny"
                // (not "Cancel"), so `d` is the correct hotkey there;
                // hardcoding `c`/`n` made the underline dead.
                let (primary_label, cancel_label) =
                    crate::ui::prompt::confirm_labels(&p.kind).unwrap();
                let first_alpha = |s: &str| {
                    s.chars()
                        .find(|c| c.is_ascii_alphabetic())
                        .map(|c| c.to_ascii_lowercase())
                };
                let primary_hk = first_alpha(primary_label);
                let cancel_hk = first_alpha(cancel_label);
                let hit_primary = matches!(primary_hk, Some(pk) if pk == low) || low == 'y';
                let hit_cancel =
                    matches!(cancel_hk, Some(ck) if ck == low) || low == 'c' || low == 'n';
                // Primary and cancel could collide (unlikely — e.g.
                // both "Continue" and "Cancel" start with `c`). Prefer
                // cancel in that case; safer default for a destructive
                // action. AiToolConfirm's `d` (Deny) doesn't collide
                // with `a` (Allow), so this only bites theoretical
                // future dialogs.
                if hit_cancel {
                    app.run_confirm_button(false);
                } else if hit_primary {
                    app.run_confirm_button(true);
                }
                return;
            }
            _ => return,
        }
    }
    // Quit confirm — button dialog. Left/Right cycle, Enter fires
    // the focused button, S/Q/C are hotkeys, Esc cancels.
    if matches!(p.kind, crate::prompt::PromptKind::QuitConfirm) {
        let has_dirty = !app.dirty_buffer_names().is_empty();
        let buttons = crate::ui::prompt::quit_buttons(has_dirty);
        let n = buttons.len();
        let Some(p) = app.prompt.as_mut() else { return };
        match key.code {
            KeyCode::Esc => {
                app.prompt = None;
                return;
            }
            KeyCode::Left | KeyCode::BackTab => {
                p.cursor = (p.cursor + n - 1) % n;
                return;
            }
            KeyCode::Right | KeyCode::Tab => {
                p.cursor = (p.cursor + 1) % n;
                return;
            }
            KeyCode::Enter => {
                let selected = p.cursor.min(buttons.len() - 1);
                let code = buttons[selected].1;
                app.prompt = None;
                run_quit_button(app, code);
                return;
            }
            KeyCode::Char(c) => {
                let low = c.to_ascii_lowercase();
                // Match by first-letter hotkey. Dirty state: s / q / c.
                // Clean state: q / c. `y` → primary (Save all when
                // dirty, else Quit); `n` → cancel.
                let hit = match low {
                    's' if has_dirty => Some(crate::ui::prompt::QUIT_BTN_SAVE_ALL),
                    'q' if has_dirty => Some(crate::ui::prompt::QUIT_BTN_QUIT_ANYWAY),
                    'q' => Some(crate::ui::prompt::QUIT_BTN_QUIT_CLEAN),
                    'c' | 'n' => Some(crate::ui::prompt::QUIT_BTN_CANCEL),
                    'y' if has_dirty => Some(crate::ui::prompt::QUIT_BTN_SAVE_ALL),
                    'y' => Some(crate::ui::prompt::QUIT_BTN_QUIT_CLEAN),
                    _ => None,
                };
                if let Some(code) = hit {
                    app.prompt = None;
                    run_quit_button(app, code);
                }
                return;
            }
            _ => return,
        }
    }
    // Ctrl+K inside the LinkClaudeToken prompt = "auto-fetch from
    // macOS Keychain via `security find-generic-password`". Puts the
    // whole `claudeAiOauth` JSON in the prompt input so the user can
    // just hit Enter. Falls back to a toast on failure.
    // Ctrl+K inside the LinkClaudeToken prompt = "auto-fetch from
    // macOS Keychain via `security find-generic-password`". Puts the
    // whole `claudeAiOauth` JSON in the prompt input so the user can
    // just hit Enter. 2026-08-08 (reviewer follow-up) — the
    // subprocess is spawned on a worker thread; macOS's auth-prompt
    // modal on `security` can block indefinitely on user response,
    // and running it inline froze the whole TUI. Drained per-tick
    // by `App::drain_pending_keychain`, which splices the fetched
    // blob back into this prompt (if still open) + toasts the outcome.
    if matches!(p.kind, crate::prompt::PromptKind::LinkClaudeToken)
        && ctrl
        && matches!(key.code, KeyCode::Char('k' | 'K'))
    {
        // No-op if a lookup is already in flight (avoid piling up
        // Keychain modals).
        if app.pending_keychain_fetch.is_none() {
            app.pending_keychain_fetch = Some(crate::ai_usage::spawn_keychain_claude_token());
            app.toast("fetching from Keychain…".to_string());
        }
        return;
    }
    let was_find = matches!(p.kind, crate::prompt::PromptKind::Find);
    // Ctrl+H inside the Find prompt = "accept find + open replace" —
    // a single fluid chord instead of Ctrl+F, type, Enter, Ctrl+H, type.
    // Matches VS Code's unified find/replace bar behavior without a
    // full two-field prompt refactor. Empty query ⇒ just toast the hint.
    if was_find
        && ctrl
        && matches!(key.code, KeyCode::Char('h'))
        && !crate::input::is_vim_style(&app.config)
    {
        let query = p.input.clone();
        if query.trim().is_empty() {
            app.toast("type a find pattern first, then Ctrl+H");
            return;
        }
        // Design-critic #7 2026-07-07 — accept the find FIRST while
        // the prompt is still up. `accept_find` populates the buffer's
        // find state; if there are zero matches, keep the Find prompt
        // in place so the user can adjust the query. Only drop the
        // prompt and open Replace when we know there are matches to
        // splice over.
        app.accept_find(query);
        let has_matches = app
            .active
            .and_then(|cur| app.panes.get(cur))
            .and_then(|pane| {
                if let crate::pane::Pane::Editor(b) = pane {
                    b.find.as_ref().map(|f| !f.matches.is_empty())
                } else {
                    None
                }
            })
            .unwrap_or(false);
        if !has_matches {
            // Toast fired inside accept_find. Leave the Find prompt
            // up so the user can refine without hitting Ctrl+F again.
            return;
        }
        app.prompt = None;
        app.open_replace_prompt();
        return;
    }
    // Up/Down on the Find prompt cycle through the find-history (shell-style).
    if was_find && matches!(key.code, KeyCode::Up | KeyCode::Down) {
        match key.code {
            KeyCode::Up => app.find_history_prev(),
            KeyCode::Down => app.find_history_next(),
            _ => {}
        }
        return;
    }
    // Path-typed prompts (AddWorkspace) get a live directory listing
    // alongside the input. ↑↓ navigate the list, Tab autocompletes,
    // typing keeps working in parallel.
    if p.is_path_kind() {
        match key.code {
            KeyCode::Up => {
                p.suggestion_prev();
                return;
            }
            KeyCode::Down => {
                p.suggestion_next();
                return;
            }
            KeyCode::Tab => {
                p.autocomplete();
                return;
            }
            _ => {}
        }
    }
    // Enter / Esc first — they bypass the common-text router because
    // they mean "submit / cancel" here, not text-editing.
    match key.code {
        KeyCode::Esc => {
            app.prompt_cancel();
            return;
        }
        KeyCode::Enter => {
            app.prompt_accept();
            return;
        }
        _ => {}
    }
    // 2026-08-08 — common Ctrl/Cmd text shortcuts route through
    // the shared helper so every prompt gets consistent Ctrl+K /
    // Alt+←→ / Cmd+Backspace etc. without each surface reinventing
    // the switch statement.
    use crate::ui::text_input::{
        TextKeyResult, TextOps, clipboard_text_if_paste, handle_common_text_key,
    };
    let paste_text = clipboard_text_if_paste(key, &mut app.clipboard);
    let Some(p) = app.prompt.as_mut() else { return };
    let mut ops = TextOps::new(p);
    ops.insert_str = Some(|p, s| p.insert_str(s));
    ops.backspace = Some(|p| p.backspace());
    ops.delete_forward = Some(|p| p.delete_forward());
    ops.delete_word_back = Some(|p| p.delete_word());
    ops.delete_to_start = Some(|p| {
        p.input.clear();
        p.cursor = 0;
    });
    ops.delete_to_end = Some(|p| p.kill_to_end());
    ops.move_left = Some(|p| p.move_left());
    ops.move_right = Some(|p| p.move_right());
    ops.move_word_left = Some(|p| p.move_word_left());
    ops.move_word_right = Some(|p| p.move_word_right());
    ops.move_home = Some(|p| p.move_home());
    ops.move_end = Some(|p| p.move_end());
    if handle_common_text_key(key, paste_text.as_deref(), ops) == TextKeyResult::Handled {
        // Live-preview handled below after the outer match.
    } else {
        // Fall back to insertion for plain printable chars. Ctrl-
        // modified chars that didn't match a common shortcut are
        // swallowed (matches the historical behavior).
        if let KeyCode::Char(c) = key.code
            && !ctrl
            && let Some(p) = app.prompt.as_mut()
        {
            p.insert_char(c);
        }
    }
    // Incremental find — live-update the editor's find state as the query
    // grows / shrinks so the user can see matches before Enter.
    if was_find && let Some(p) = app.prompt.as_ref() {
        let q = p.input.clone();
        app.update_live_find_preview(q);
    }
}
