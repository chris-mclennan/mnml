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

pub(crate) fn handle_help_overlay_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Esc | KeyCode::F(1) => app.close_help_overlay(),
        KeyCode::Up | KeyCode::Char('k') => app.help_scroll(-1),
        KeyCode::Down | KeyCode::Char('j') => app.help_scroll(1),
        KeyCode::PageUp => app.help_scroll(-10),
        KeyCode::PageDown => app.help_scroll(10),
        KeyCode::Home => app.help_scroll(-1_000_000),
        KeyCode::End => app.help_scroll(1_000_000),
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
    match key.code {
        KeyCode::Esc => app.git_section_commit_blur(),
        KeyCode::Enter if ctrl => app.git_section_commit_submit(),
        KeyCode::Backspace => app.git_section_commit_backspace(),
        KeyCode::Char(c) if !ctrl => app.git_section_commit_insert_char(c),
        _ => {}
    }
}

pub(crate) fn handle_search_section_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Esc => app.search_section_blur(),
        KeyCode::Enter => {
            // If the input has any text, Enter commits — runs the grep.
            // If there are hits AND the input is empty, Enter jumps to
            // the highlighted hit instead. Either way, after running
            // the user can ↑↓ navigate without re-focusing.
            if app.search_query.trim().is_empty() && !app.search_hits.is_empty() {
                app.search_section_open_selected();
            } else {
                app.search_section_run();
            }
        }
        KeyCode::Backspace => app.search_section_backspace(),
        KeyCode::Up if !ctrl => app.search_section_select(-1),
        KeyCode::Down if !ctrl => app.search_section_select(1),
        KeyCode::Char(c) if !ctrl => app.search_section_insert_char(c),
        _ => {}
    }
}

pub(crate) fn handle_discovery_overlay_key(app: &mut App, key: KeyEvent) {
    // Integration-edit panel is greedy when open — every keystroke
    // routes to the panel until Enter saves or Esc cancels. Tab /
    // ←→ cycle field + color; text fields accept char + backspace.
    let edit_panel_open = app
        .discovery_overlay
        .as_ref()
        .is_some_and(|s| s.edit_panel.is_some());
    if edit_panel_open {
        match key.code {
            KeyCode::Esc => app.integration_edit_cancel(),
            KeyCode::Enter => app.integration_edit_save(),
            KeyCode::Tab => app.integration_edit_cycle_field(1),
            KeyCode::BackTab => app.integration_edit_cycle_field(-1),
            KeyCode::Left => app.integration_edit_color_cycle(-1),
            KeyCode::Right => app.integration_edit_color_cycle(1),
            KeyCode::Up => app.integration_edit_cycle_field(-1),
            KeyCode::Down => app.integration_edit_cycle_field(1),
            KeyCode::Backspace => app.integration_edit_backspace(),
            // Ctrl+G — browse glyphs. 2026-07-03 user feedback:
            // the Glyph field is text-only; users want a picker
            // that shows every configured icon (including the
            // 24 mnml-patched AWS variants) with click-to-choose.
            // The picker's accept handler routes back into the
            // Glyph field when the edit panel is open (see
            // `PickerKind::IconGlyphs` handler in app/picker.rs).
            KeyCode::Char('g') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.open_icon_picker();
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.integration_edit_type_char(c);
            }
            _ => {}
        }
        return;
    }
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') => app.close_discovery_overlay(),
        KeyCode::Up | KeyCode::Char('k') => app.discovery_move_row(-1),
        KeyCode::Down | KeyCode::Char('j') => app.discovery_move_row(1),
        KeyCode::Enter => app.discovery_enter(),
        // `i` spawns `cargo install --git <url> --tag <ver>` in a
        // pty pane the user can watch live; `y` yanks the command for
        // out-of-mnml install. Both come back to the rail via
        // `integrations.refresh` (auto-cleared on next + overlay open).
        KeyCode::Char('i') => app.discovery_install_selected(),
        KeyCode::Char('y') => app.discovery_yank_install(),
        // `e` opens the edit panel for the focused rail row. No-op
        // on non-InRail rows (the others aren't in the config yet).
        KeyCode::Char('e') => app.open_integration_edit_from_focused(),
        // `a` opens the edit panel in AddCustom mode — blank fields,
        // user fills in id + command + glyph + color + fallback +
        // tooltip from scratch.
        KeyCode::Char('a') => app.open_integration_edit_add_custom(),
        // `t` flips between Installed and Marketplace tabs at the
        // top of the overlay.
        KeyCode::Char('t') => app.discovery_toggle_tab(),
        _ => {}
    }
}

pub(crate) fn handle_settings_overlay_key(app: &mut App, key: KeyEvent) {
    // Text/Color rows enter a greedy edit mode on Enter — every
    // keystroke goes to the buffer until Enter commits (or Esc
    // cancels). Other navigation keys are intercepted to avoid the
    // overlay reacting twice.
    if app.settings_text_edit_active() {
        // 2026-06-19 — user-reported: couldn't arrow-cursor inside
        // the edit buffer, forcing backspace from the end to fix
        // mid-string typos. Added Left/Right/Home/End/Delete.
        match key.code {
            KeyCode::Esc => app.settings_text_edit_cancel(),
            KeyCode::Enter => app.settings_text_edit_commit(),
            KeyCode::Backspace => app.settings_text_edit_backspace(),
            KeyCode::Delete => app.settings_text_edit_delete(),
            KeyCode::Left => app.settings_text_edit_move_left(),
            KeyCode::Right => app.settings_text_edit_move_right(),
            KeyCode::Home => app.settings_text_edit_home(),
            KeyCode::End => app.settings_text_edit_end(),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.settings_text_edit_insert(c);
            }
            _ => {}
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
        KeyCode::Char('r') => app.settings_reset_row(),
        KeyCode::Char('R') => {
            // Shift+r — reset all to defaults (the explicit reset-all
            // path; the same as Enter on the sentinel row).
            app.config = crate::config::Config::default();
            app.toast("settings: all reset to defaults");
        }
        _ => {}
    }
}

pub(crate) fn handle_picker_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
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
        KeyCode::Char('p') if ctrl => {
            picker.move_up();
            app.on_picker_moved();
        }
        KeyCode::Char('n') if ctrl => {
            picker.move_down();
            app.on_picker_moved();
        }
        KeyCode::Char('u') if ctrl => picker.clear_query(),
        KeyCode::Backspace => picker.backspace(),
        KeyCode::Char(c) if !ctrl => picker.type_char(c),
        _ => {}
    }
}

pub(crate) fn handle_prompt_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let Some(p) = app.prompt.as_mut() else { return };
    let was_find = matches!(p.kind, crate::prompt::PromptKind::Find);
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
    match key.code {
        KeyCode::Esc => {
            app.prompt_cancel();
            return;
        }
        KeyCode::Enter => {
            app.prompt_accept();
            return;
        }
        KeyCode::Backspace => {
            if ctrl {
                p.delete_word();
            } else {
                p.backspace();
            }
        }
        KeyCode::Char('w') if ctrl => p.delete_word(),
        KeyCode::Char('u') if ctrl => {
            p.input.clear();
            p.cursor = 0;
        }
        KeyCode::Left => p.move_left(),
        KeyCode::Right => p.move_right(),
        KeyCode::Home => p.move_home(),
        KeyCode::End => p.move_end(),
        KeyCode::Char(c) if !ctrl => p.insert_char(c),
        _ => {}
    }
    // Incremental find — live-update the editor's find state as the query
    // grows / shrinks so the user can see matches before Enter.
    if was_find && let Some(p) = app.prompt.as_ref() {
        let q = p.input.clone();
        app.update_live_find_preview(q);
    }
}
