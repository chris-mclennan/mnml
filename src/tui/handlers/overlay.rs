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
        match key.code {
            KeyCode::Esc => {
                if let Some(state) = app.help_overlay.as_mut() {
                    state.filter_focused = false;
                }
            }
            KeyCode::Enter => {
                if let Some(state) = app.help_overlay.as_mut() {
                    state.filter_focused = false;
                }
            }
            KeyCode::Backspace => {
                if let Some(state) = app.help_overlay.as_mut() {
                    state.query.pop();
                    state.scroll = 0;
                }
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(state) = app.help_overlay.as_mut() {
                    state.query.push(c);
                    state.scroll = 0;
                }
            }
            _ => {}
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

/// Key dispatch for the integration-edit overlay (right-click chip
/// → Edit / Add custom). Steals every key until Enter saves or Esc
/// cancels.
pub(crate) fn handle_integration_edit_key(app: &mut App, key: KeyEvent) {
    use crate::app::discovery::IntegrationEditField;
    let glyph_focused = app
        .integration_edit
        .as_ref()
        .is_some_and(|p| matches!(p.focused_field, IntegrationEditField::Glyph));
    match key.code {
        KeyCode::Esc => app.integration_edit_cancel(),
        // Enter on the Glyph field opens the 3-option chooser (Choose
        // from library / Edit current / Create custom). Enter on any
        // other field saves.
        KeyCode::Enter if glyph_focused => app.open_glyph_action_menu(),
        KeyCode::Enter => app.integration_edit_save(),
        // → on the Glyph field opens the picker (Glyph is a menu-style
        // choice, not a text field). → on Color cycles the palette.
        KeyCode::Right if glyph_focused => app.open_icon_picker(),
        KeyCode::Right => app.integration_edit_color_cycle(1),
        // Ctrl+N on the Glyph field opens the glyph builder — bake a
        // custom SVG into MnmlSymbols and route the codepoint back
        // into this edit panel's Glyph field on commit.
        KeyCode::Char('n') if glyph_focused && key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.open_glyph_builder_from_edit();
        }
        KeyCode::Tab => app.integration_edit_cycle_field(1),
        KeyCode::BackTab => app.integration_edit_cycle_field(-1),
        KeyCode::Left => app.integration_edit_color_cycle(-1),
        KeyCode::Up => app.integration_edit_cycle_field(-1),
        KeyCode::Down => app.integration_edit_cycle_field(1),
        KeyCode::Backspace => app.integration_edit_backspace(),
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
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
    match key.code {
        KeyCode::Esc => app.close_glyph_builder(),
        KeyCode::Enter => app.glyph_builder_commit(),
        KeyCode::Tab => app.glyph_builder_cycle_field(1),
        KeyCode::BackTab => app.glyph_builder_cycle_field(-1),
        KeyCode::Up => app.glyph_builder_cycle_field(-1),
        KeyCode::Down => app.glyph_builder_cycle_field(1),
        // Left / Right cycle values on the non-text fields; on text
        // fields they'd normally move the cursor but this panel keeps
        // text single-line + append-only, so ignore.
        KeyCode::Left if !text_field => app.glyph_builder_cycle_value(-1),
        KeyCode::Right if !text_field => app.glyph_builder_cycle_value(1),
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
        match key.code {
            KeyCode::Esc => app.settings_filter_cancel(),
            KeyCode::Enter => app.settings_filter_commit(),
            KeyCode::Backspace => app.settings_filter_backspace(),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.settings_filter_push(c);
            }
            _ => {}
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
        KeyCode::Char(c) if !ctrl => picker.type_char(c),
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
                app.run_delete_button(crate::ui::prompt::DELETE_BTN_CANCEL);
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
                    'd' | 'y' => Some(crate::ui::prompt::DELETE_BTN_DELETE),
                    'c' | 'n' => Some(crate::ui::prompt::DELETE_BTN_CANCEL),
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
