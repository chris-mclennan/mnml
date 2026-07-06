//! The single-line text-input overlay (commit message, …) — a small centered
//! box with a title and one editable line. State lives in `crate::prompt`; key
//! handling lives in `tui.rs`. Records the caret cell in `app.rects.prompt_caret`
//! so `ui::draw` can place the terminal cursor here.
//!
//! Path-typed prompts (`AddWorkspace`) also render a live directory
//! listing below the input — the user can keep typing OR navigate the
//! list with ↑↓, Tab autocompletes, Enter accepts the focused row.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(p) = &app.prompt else { return };
    // Quit confirm renders as a button dialog — no text input, no
    // submit hint. Kept inside the Prompt state machine because
    // Enter / Esc already route through it; the buttons just pick
    // which action to take on Enter.
    if matches!(p.kind, crate::prompt::PromptKind::QuitConfirm) {
        draw_quit_confirm(frame, app, screen);
        return;
    }
    // #polish 2026-07-06 — DeleteConfirm renders as a two-button
    // `[ Delete ] [ Cancel ]` dialog, replacing the "type the
    // filename to confirm" text-input pattern. Matches the quit
    // dialog's shape so the confirmation-modal primitive reads
    // the same across the app.
    if matches!(p.kind, crate::prompt::PromptKind::DeleteConfirm) {
        draw_delete_confirm(frame, app, screen);
        return;
    }
    // The same button-dialog pattern for every other destructive
    // confirm: git delete branch / stash drop / worktree remove /
    // tag delete / discard hunk / claude kill / merge / rebase.
    if let Some(buttons) = confirm_buttons(&p.kind) {
        draw_generic_confirm(frame, app, screen, buttons);
        return;
    }
    let title = format!(" {} ", p.title);
    let input = p.input.clone();
    let caret_col = p.caret_col();

    // Browse-mode prompts grow taller to fit the directory listing.
    let suggestion_count = p.suggestions.len() as u16;
    let extra_rows = if p.is_path_kind() && suggestion_count > 0 {
        suggestion_count + 1 // suggestions + a thin separator hint
    } else {
        0
    };

    let w = (title.chars().count().max(56) as u16 + 4).min(screen.width.saturating_sub(2));
    let base_h = 5u16;
    let h = (base_h + extra_rows).min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }

    // Place the input field at a fixed offset from the top of the inner
    // area (row 1). For the no-suggestions case this matches the prior
    // centered layout pretty closely; with suggestions, the field moves
    // up so the suggestion list has room below.
    let field_y = inner.y + 1;
    let pad = 1u16;
    let avail = inner.width.saturating_sub(pad) as usize;
    let chars: Vec<char> = input.chars().collect();
    let start = caret_col.saturating_sub(avail.saturating_sub(1));
    let shown: String = chars.iter().skip(start).take(avail).collect();
    // Placeholder shown when the input is empty — dimmed hint that
    // clears on the first keystroke. Mirrors browser address-bar
    // + Bruno URL-field semantics. Kind-driven so different prompts
    // can carry different hints without special-casing at the callsite.
    let placeholder_span = if input.is_empty() {
        placeholder_for(&p.kind).map(|hint| {
            Span::styled(
                hint,
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg2)
                    .add_modifier(Modifier::ITALIC),
            )
        })
    } else {
        None
    };
    let line = if let Some(ph) = placeholder_span {
        Line::from(vec![ph])
    } else {
        Line::from(Span::styled(
            shown,
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2),
        ))
    };
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(theme::cur().bg2)),
        Rect::new(inner.x + pad, field_y, inner.width.saturating_sub(pad), 1),
    );

    // Hint row.
    let hint_y = field_y + 1;
    let hint = if p.is_path_kind() && !p.suggestions.is_empty() {
        "  enter submit · ↑↓ browse · tab complete · esc cancel"
    } else if p.is_path_kind() {
        "  enter submit · type to browse · esc cancel"
    } else {
        "  enter to submit · esc to cancel"
    };
    if hint_y < inner.y + inner.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                hint,
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg2),
            ))),
            Rect::new(inner.x, hint_y, inner.width, 1),
        );
    }

    // Suggestion list (path-typed prompts only). Each row shows the
    // full path with the parent dim and the basename bold; the focused
    // row gets a cyan background highlight.
    if p.is_path_kind() && !p.suggestions.is_empty() {
        let list_top = hint_y + 1;
        for (i, path) in p.suggestions.iter().enumerate() {
            let y = list_top + i as u16;
            if y >= inner.y + inner.height {
                break;
            }
            let focused = p.selected_suggestion == Some(i);
            let row_rect = Rect::new(inner.x, y, inner.width, 1);
            let (parent, name) = split_for_display(path);
            // Focused row uses the menu-family highlight (cyan bg,
            // bg_dark fg); unfocused rows match the panel's own bg2.
            let bg = if focused {
                theme::cur().cyan
            } else {
                theme::cur().bg2
            };
            let fg_main = if focused {
                theme::cur().bg_dark
            } else {
                theme::cur().fg
            };
            let cursor = if focused { "▸" } else { " " };
            let line = Line::from(vec![
                Span::styled(format!(" {cursor} "), Style::default().fg(fg_main).bg(bg)),
                Span::styled(
                    parent,
                    Style::default()
                        .fg(if focused {
                            theme::cur().bg_dark
                        } else {
                            theme::cur().comment
                        })
                        .bg(bg),
                ),
                Span::styled(
                    name,
                    Style::default()
                        .fg(fg_main)
                        .bg(bg)
                        .add_modifier(if focused {
                            Modifier::BOLD
                        } else {
                            Modifier::empty()
                        }),
                ),
            ]);
            frame.render_widget(
                Paragraph::new(line).style(Style::default().bg(bg)),
                row_rect,
            );
        }
    }

    let cx = inner.x + pad + (caret_col - start) as u16;
    app.rects.prompt_caret = Some((cx.min(inner.x + inner.width.saturating_sub(1)), field_y));
}

/// Quit-confirm buttons. Order matches `App::quit_prompt_buttons()`;
/// the u8 payload is what `App::run_quit_button` dispatches on.
pub const QUIT_BTN_SAVE_ALL: u8 = 0;
pub const QUIT_BTN_QUIT_ANYWAY: u8 = 1;
pub const QUIT_BTN_CANCEL: u8 = 2;
pub const QUIT_BTN_QUIT_CLEAN: u8 = 3;

/// Delete-confirm buttons. Order matches the Vec returned by
/// `delete_buttons`; the u8 payload is what `App::run_delete_button`
/// dispatches on.
pub const CONFIRM_BTN_PRIMARY: u8 = 0;
pub const CONFIRM_BTN_CANCEL: u8 = 1;

/// Two-button set for the delete-confirm dialog. Returns
/// `(label, action_code, hotkey_char_idx)` per button. Cancel is the
/// default focus (safety first) — see `open_fs_delete_prompt`.
pub fn delete_buttons() -> Vec<(&'static str, u8, usize)> {
    vec![
        ("  Delete  ", CONFIRM_BTN_PRIMARY, 2),
        (" Cancel ", CONFIRM_BTN_CANCEL, 1),
    ]
}

/// Button set for the current dirty state — driven by [`App::dirty_buffer_names`].
/// Returns `(label, action_code, hotkey_char_idx)` per button.
pub fn quit_buttons(has_dirty: bool) -> Vec<(&'static str, u8, usize)> {
    if has_dirty {
        vec![
            ("  Save all  ", QUIT_BTN_SAVE_ALL, 2),
            (" Quit anyway ", QUIT_BTN_QUIT_ANYWAY, 1),
            (" Cancel ", QUIT_BTN_CANCEL, 1),
        ]
    } else {
        vec![
            ("  Quit  ", QUIT_BTN_QUIT_CLEAN, 2),
            (" Cancel ", QUIT_BTN_CANCEL, 1),
        ]
    }
}

fn draw_quit_confirm(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(p) = &app.prompt else { return };
    let dirty = app.dirty_buffer_names();
    let has_dirty = !dirty.is_empty();
    let buttons = quit_buttons(has_dirty);
    let selected = p.cursor.min(buttons.len().saturating_sub(1));

    let title = p.title.clone();
    let msg = if has_dirty {
        format!("  Unsaved: {}", dirty.join(", "))
    } else {
        "  This will close mnml.".to_string()
    };

    let buttons_w: usize = buttons.iter().map(|(l, _, _)| l.chars().count() + 1).sum();
    let inner_w = msg
        .chars()
        .count()
        .max(buttons_w + 2)
        .max(title.chars().count() + 4)
        .max(32);
    let w = (inner_w as u16 + 2).min(screen.width.saturating_sub(2));
    // 3 rows of content: message + blank + buttons. +2 for borders.
    let h = 5u16.min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu(format!(" {title} "));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }

    // Row 0: the message. Fill to inner width so the panel bg reads clean.
    let msg_padded = format!("{msg:<width$}", width = inner.width as usize);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg_padded,
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2),
        ))),
        Rect::new(inner.x, inner.y, inner.width, 1),
    );

    // Last inner row: right-aligned buttons. Focused button gets the
    // menu-family highlight (cyan + bg_dark + bold) so it reads as the
    // same primitive as menu bar / context menu selection.
    let by = inner.y + inner.height - 1;
    let total_bw: u16 = buttons
        .iter()
        .map(|(l, _, _)| l.chars().count() as u16 + 1)
        .sum();
    let mut bx = inner.x + inner.width.saturating_sub(total_bw);
    app.rects.quit_prompt_buttons.clear();
    for (i, (label, code, hk_idx)) in buttons.iter().enumerate() {
        let focused = i == selected;
        let style = if focused {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        let bw = label.chars().count() as u16;
        if bx + bw > inner.x + inner.width {
            break;
        }
        // Split so the hotkey letter is underlined.
        let chars: Vec<char> = label.chars().collect();
        let mut spans: Vec<Span> = Vec::new();
        spans.push(Span::styled(
            chars[..*hk_idx].iter().collect::<String>(),
            style,
        ));
        if let Some(&hk) = chars.get(*hk_idx) {
            spans.push(Span::styled(
                hk.to_string(),
                style.add_modifier(Modifier::UNDERLINED),
            ));
        }
        spans.push(Span::styled(
            chars[(hk_idx + 1)..].iter().collect::<String>(),
            style,
        ));
        let rect = Rect::new(bx, by, bw, 1);
        frame.render_widget(Paragraph::new(Line::from(spans)), rect);
        app.rects.quit_prompt_buttons.push((rect, *code));
        bx += bw + 1;
    }
}

/// #polish 2026-07-06 — for any destructive confirm-style PromptKind
/// (git delete branch / stash drop / worktree remove / tag delete /
/// hunk discard / claude kill / merge / rebase), return the
/// `[ primary_label, cancel_label ]` pair for a two-button dialog.
/// Returns `None` for other kinds (regular text-input prompts).
///
/// Rendering + key/mouse dispatch checks this table to decide
/// whether to draw the standard input field or a button dialog.
pub fn confirm_labels(kind: &crate::prompt::PromptKind) -> Option<(&'static str, &'static str)> {
    use crate::prompt::PromptKind::*;
    Some(match kind {
        GitDeleteBranch | GitDeleteBranchConfirm => ("  Delete  ", " Cancel "),
        GitWorktreeRemove | WorktreeRemoveConfirm => ("  Remove  ", " Cancel "),
        GitStashDrop => ("  Drop  ", " Cancel "),
        GitTagDelete => ("  Delete  ", " Cancel "),
        DiffDiscardHunk | GitDiscardFile => ("  Discard  ", " Cancel "),
        ClaudeKillConfirm => ("  Kill  ", " Cancel "),
        GitMergeConfirm => ("  Merge  ", " Cancel "),
        GitRebaseConfirm => ("  Rebase  ", " Cancel "),
        TreeMoveConfirm => ("  Move  ", " Cancel "),
        AiToolConfirm => ("  Allow  ", " Deny "),
        ToolInstallConfirm | SiblingInstallConfirm => ("  Install  ", " Cancel "),
        _ => return None,
    })
}

/// Buttons for a generic confirm dialog — matches the shape of
/// `quit_buttons` / `delete_buttons`. Underscored hotkey char is
/// the third field (`d` for Delete, `c` for Cancel, etc.).
pub fn confirm_buttons(kind: &crate::prompt::PromptKind) -> Option<Vec<(&'static str, u8, usize)>> {
    let (primary, cancel) = confirm_labels(kind)?;
    // Hotkey index — pick the first alpha char in each label.
    let hk = |label: &str| {
        label
            .char_indices()
            .find(|(_, c)| c.is_ascii_alphabetic())
            .map(|(i, _)| i)
            .unwrap_or(0)
    };
    Some(vec![
        (primary, CONFIRM_BTN_PRIMARY, hk(primary)),
        (cancel, CONFIRM_BTN_CANCEL, hk(cancel)),
    ])
}

/// #polish 2026-07-06 — DeleteConfirm dialog. Two buttons
/// `[ Delete ] [ Cancel ]`; Cancel is the default focus. The title
/// text is the full "Delete <rel> (N entries)" string prepared by
/// `open_fs_delete_prompt`.
fn draw_delete_confirm(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(p) = &app.prompt else { return };
    let buttons = delete_buttons();
    let selected = p.cursor.min(buttons.len().saturating_sub(1));
    let title = p.title.clone();

    let buttons_w: usize = buttons.iter().map(|(l, _, _)| l.chars().count() + 1).sum();
    let inner_w = title.chars().count().max(buttons_w + 2).max(40);
    let w = (inner_w as u16 + 2).min(screen.width.saturating_sub(2));
    let h = 5u16.min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu(" Delete ");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }

    // Row 0: the title (which contains the file name + entry count).
    let msg_padded = format!(
        " {title:<width$}",
        width = (inner.width as usize).saturating_sub(1)
    );
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg_padded,
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2),
        ))),
        Rect::new(inner.x, inner.y, inner.width, 1),
    );

    // Last inner row: right-aligned buttons.
    let by = inner.y + inner.height - 1;
    let total_bw: u16 = buttons
        .iter()
        .map(|(l, _, _)| l.chars().count() as u16 + 1)
        .sum();
    let mut bx = inner.x + inner.width.saturating_sub(total_bw);
    app.rects.confirm_dialog_buttons.clear();
    for (i, (label, code, hk_idx)) in buttons.iter().enumerate() {
        let focused = i == selected;
        let style = if focused {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        let bw = label.chars().count() as u16;
        if bx + bw > inner.x + inner.width {
            break;
        }
        let chars: Vec<char> = label.chars().collect();
        let mut spans: Vec<Span> = Vec::new();
        spans.push(Span::styled(
            chars[..*hk_idx].iter().collect::<String>(),
            style,
        ));
        if let Some(&hk) = chars.get(*hk_idx) {
            spans.push(Span::styled(
                hk.to_string(),
                style.add_modifier(Modifier::UNDERLINED),
            ));
        }
        spans.push(Span::styled(
            chars[(hk_idx + 1)..].iter().collect::<String>(),
            style,
        ));
        let rect = Rect::new(bx, by, bw, 1);
        frame.render_widget(Paragraph::new(Line::from(spans)), rect);
        app.rects.confirm_dialog_buttons.push((rect, *code));
        bx += bw + 1;
    }
}

/// Generic two-button confirm dialog — used by every destructive
/// PromptKind whose accept handler used to gate on a "type X to
/// confirm" magic string. The primary button label + hotkey come
/// from `confirm_buttons(kind)`; the title text is
/// `Prompt.title` (already set by the opening code).
fn draw_generic_confirm(
    frame: &mut Frame,
    app: &mut App,
    screen: Rect,
    buttons: Vec<(&'static str, u8, usize)>,
) {
    let Some(p) = &app.prompt else { return };
    let selected = p.cursor.min(buttons.len().saturating_sub(1));
    let title = p.title.clone();

    let buttons_w: usize = buttons.iter().map(|(l, _, _)| l.chars().count() + 1).sum();
    let inner_w = title.chars().count().max(buttons_w + 2).max(40);
    let w = (inner_w as u16 + 2).min(screen.width.saturating_sub(2));
    let h = 5u16.min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu(" Confirm ");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }
    let msg_padded = format!(
        " {title:<width$}",
        width = (inner.width as usize).saturating_sub(1)
    );
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg_padded,
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2),
        ))),
        Rect::new(inner.x, inner.y, inner.width, 1),
    );
    let by = inner.y + inner.height - 1;
    let total_bw: u16 = buttons
        .iter()
        .map(|(l, _, _)| l.chars().count() as u16 + 1)
        .sum();
    let mut bx = inner.x + inner.width.saturating_sub(total_bw);
    app.rects.confirm_dialog_buttons.clear();
    for (i, (label, code, hk_idx)) in buttons.iter().enumerate() {
        let focused = i == selected;
        let style = if focused {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        let bw = label.chars().count() as u16;
        if bx + bw > inner.x + inner.width {
            break;
        }
        let chars: Vec<char> = label.chars().collect();
        let mut spans: Vec<Span> = Vec::new();
        spans.push(Span::styled(
            chars[..*hk_idx].iter().collect::<String>(),
            style,
        ));
        if let Some(&hk) = chars.get(*hk_idx) {
            spans.push(Span::styled(
                hk.to_string(),
                style.add_modifier(Modifier::UNDERLINED),
            ));
        }
        spans.push(Span::styled(
            chars[(hk_idx + 1)..].iter().collect::<String>(),
            style,
        ));
        let rect = Rect::new(bx, by, bw, 1);
        frame.render_widget(Paragraph::new(Line::from(spans)), rect);
        app.rects.confirm_dialog_buttons.push((rect, *code));
        bx += bw + 1;
    }
}

/// Dimmed placeholder hint for empty prompt inputs. Mirrors browser
/// address-bar + Bruno URL-field semantics — clears on first keystroke.
fn placeholder_for(kind: &crate::prompt::PromptKind) -> Option<&'static str> {
    use crate::prompt::PromptKind::*;
    match kind {
        BrowserUrl => Some("https://example.com"),
        _ => None,
    }
}

/// Split a path into a dimmed parent prefix (with trailing `/`) and
/// the basename for highlighted rendering.
fn split_for_display(p: &std::path::Path) -> (String, String) {
    let parent = p
        .parent()
        .map(|q| {
            let mut s = q.to_string_lossy().to_string();
            if !s.ends_with('/') {
                s.push('/');
            }
            s
        })
        .unwrap_or_default();
    let name = p
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    (parent, name)
}
