//! VS Code-style menu bar — File / Edit / Selection / View / Go / Run /
//! Terminal / Help — rendered on the chrome row above the bufferline.
//!
//! Each menu's items dispatch existing palette commands; the menu UI
//! is pure presentation on top of the command registry. Visibility +
//! interaction are gated by `[ui] menu_bar = "always" | "auto" |
//! "hidden"` (see `UiConfig::menu_bar`).
//!
//! ## Interaction model
//!
//! - **Mouse**: click a menu word → drops a vertical overlay below it.
//!   Click an item → fire its palette command + close the overlay.
//!   Click outside / Esc → close without firing.
//! - **Keyboard**: `Alt+<letter>` opens the menu whose label starts
//!   with that letter (Alt+F → File). `F10` summons + focuses the
//!   first menu when nothing is open. Once open: ←→ to navigate
//!   between menus, ↑↓ to move within a menu, Enter to fire, Esc to
//!   close. Type-ahead jumps to items by first letter.
//!
//! ## Layout
//!
//! Menus render on the chrome row immediately after the back/
//! forward chips, left of the centered workspace chip. Each word is
//! `" Label "` (2-cell padding) so the click target has comfortable
//! mouse hit area; total width is the sum of all word widths.

/// One menu in the bar. The label is what's painted on the chrome
/// row + drives the Alt+letter accelerator (first char, case-
/// insensitive). Items are dispatched into the palette command
/// system — same path as Ctrl+Shift+P would take them.
#[derive(Debug, Clone)]
pub struct MenuDef {
    /// Word painted on the chrome row (e.g. `"File"`).
    pub label: &'static str,
    /// Items in the dropdown, top-to-bottom.
    pub items: Vec<MenuItem>,
}

/// One row inside a menu dropdown. Either a fire-able item (label +
/// palette command id) or a visual separator.
#[derive(Debug, Clone)]
pub enum MenuItem {
    /// `(label, palette_command_id)`. Click / Enter fires the
    /// command id via `crate::command::run` — same as the palette.
    /// The label is what the user sees; the command id is internal.
    Action {
        label: &'static str,
        command_id: &'static str,
    },
    /// Visual separator. Skipped during keyboard nav.
    Separator,
}

/// Active menu-bar state. `None` when no menu is open.
#[derive(Debug, Clone)]
pub struct MenuOpenState {
    /// Which menu (index into the bar's `MenuDef` list) is dropped.
    pub menu_idx: usize,
    /// Which item is highlighted (index into `MenuDef::items`, OR
    /// usize::MAX when nothing is highlighted — fresh mouse-open).
    pub item_idx: usize,
    /// Set when the menu was summoned via keyboard so the dropdown
    /// shows the highlight by default. Mouse-opened menus leave it
    /// `false` and only highlight on hover.
    pub keyboard_opened: bool,
    /// Last mnemonic letter that was matched inside this dropdown.
    /// Set when a printable-char press finds an Action; consecutive
    /// presses of the same letter cycle through the remaining matches
    /// (highlight-only) before Enter commits — VS Code / GTK / Win32
    /// convention. Cleared on arrow-nav so re-pressing the letter
    /// starts fresh. design-round-4 issue 1 2026-07-14.
    pub last_mnemonic: Option<char>,
}

impl MenuOpenState {
    pub fn new_keyboard(menu_idx: usize) -> Self {
        Self {
            menu_idx,
            item_idx: 0,
            keyboard_opened: true,
            last_mnemonic: None,
        }
    }

    pub fn new_mouse(menu_idx: usize) -> Self {
        Self {
            menu_idx,
            item_idx: usize::MAX,
            keyboard_opened: false,
            last_mnemonic: None,
        }
    }
}

/// The full menu bar — all menus left to right. The leading brand
/// menu (`\u{e795}  mnml`) sits at the far left like the Apple
/// menu on macOS.
pub fn bar() -> Vec<MenuDef> {
    vec![
        brand_menu(),
        file_menu(),
        edit_menu(),
        selection_menu(),
        view_menu(),
        go_menu(),
        run_menu(),
        terminal_menu(),
        window_menu(),
        help_menu(),
    ]
}

fn brand_menu() -> MenuDef {
    MenuDef {
        // `\u{e795}` brand glyph + program name, macOS-style:
        // single combined menu word at the far-left, opens the
        // "app" menu (About / Settings / Updates / Quit). The
        // first char isn't an Alt accelerator letter, so Alt+M
        // is reserved for the user; the brand menu opens only
        // via mouse click or arrow-left from File.
        label: ">_  mnml",
        items: vec![
            MenuItem::Action {
                label: "About mnml…",
                command_id: "view.about",
            },
            MenuItem::Action {
                label: "Settings…",
                command_id: "view.settings",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Quit mnml",
                command_id: "app.quit",
            },
        ],
    }
}

fn file_menu() -> MenuDef {
    MenuDef {
        label: "File",
        items: vec![
            MenuItem::Action {
                label: "New file",
                command_id: "file.new",
            },
            MenuItem::Action {
                // #polish 2026-07-07 (vscode-user SEV-2 #1) — was
                // wired to view.discovery (click-hint overlay); VS
                // Code users hit "Open file..." expecting a file
                // picker. Now routes to picker.files.
                label: "Open file…",
                command_id: "picker.files",
            },
            MenuItem::Action {
                label: "Open folder…",
                command_id: "view.add_workspace",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Save",
                command_id: "file.save",
            },
            MenuItem::Action {
                label: "Save all",
                command_id: "file.save_all",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Close tab",
                command_id: "buffer.close",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Settings…",
                command_id: "view.settings",
            },
            MenuItem::Action {
                label: "Quit",
                command_id: "app.quit",
            },
        ],
    }
}

fn edit_menu() -> MenuDef {
    MenuDef {
        label: "Edit",
        items: vec![
            MenuItem::Action {
                label: "Find…",
                command_id: "find.find",
            },
            MenuItem::Action {
                label: "Find next",
                command_id: "find.next",
            },
            MenuItem::Action {
                label: "Find previous",
                command_id: "find.prev",
            },
            MenuItem::Action {
                label: "Replace…",
                command_id: "find.replace",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Find in files…",
                command_id: "find.grep",
            },
            MenuItem::Action {
                label: "Replace in files…",
                command_id: "find.grep_replace",
            },
        ],
    }
}

fn selection_menu() -> MenuDef {
    MenuDef {
        label: "Selection",
        items: vec![
            MenuItem::Action {
                label: "Expand selection",
                command_id: "lsp.selection_expand",
            },
            MenuItem::Action {
                label: "Shrink selection",
                command_id: "lsp.selection_shrink",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Add cursor above",
                command_id: "editor.add_cursor_above",
            },
            MenuItem::Action {
                label: "Add cursor below",
                command_id: "editor.add_cursor_below",
            },
            MenuItem::Action {
                label: "Add cursor at next match",
                command_id: "editor.add_cursor_at_next_word",
            },
            MenuItem::Action {
                label: "Select all occurrences",
                command_id: "editor.select_all_occurrences",
            },
            MenuItem::Action {
                label: "Clear extra cursors",
                command_id: "editor.clear_extra_cursors",
            },
        ],
    }
}

fn view_menu() -> MenuDef {
    MenuDef {
        label: "View",
        items: vec![
            MenuItem::Action {
                label: "Command palette",
                command_id: "view.discovery",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Toggle file tree",
                command_id: "view.toggle_tree",
            },
            MenuItem::Action {
                label: "Toggle right panel",
                command_id: "view.toggle_right_panel",
            },
            MenuItem::Action {
                label: "Cycle menu bar (always / auto / hidden)",
                command_id: "view.menu_bar_cycle",
            },
            MenuItem::Action {
                label: "Toggle bufferline",
                command_id: "view.toggle_bufferline",
            },
            MenuItem::Action {
                label: "Toggle word wrap",
                command_id: "view.toggle_wrap",
            },
            MenuItem::Action {
                label: "Toggle zen mode",
                command_id: "view.zen",
            },
            MenuItem::Action {
                label: "Toggle hover-help strip",
                command_id: "view.toggle_hover_help",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Commands reference…",
                command_id: "view.commands_reference",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Pick theme…",
                command_id: "theme.pick",
            },
            MenuItem::Action {
                label: "Toggle theme",
                command_id: "theme.toggle",
            },
        ],
    }
}

fn go_menu() -> MenuDef {
    MenuDef {
        label: "Go",
        items: vec![
            MenuItem::Action {
                label: "Go to file…",
                command_id: "view.discovery",
            },
            MenuItem::Action {
                label: "Go to line…",
                command_id: "editor.goto_line",
            },
            MenuItem::Action {
                label: "Go to definition",
                command_id: "lsp.peek_definition",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Previous buffer",
                command_id: "buffer.prev",
            },
            MenuItem::Action {
                label: "Next buffer",
                command_id: "buffer.next",
            },
            MenuItem::Action {
                label: "Last buffer",
                command_id: "buffer.last",
            },
        ],
    }
}

fn run_menu() -> MenuDef {
    MenuDef {
        label: "Run",
        items: vec![
            MenuItem::Action {
                label: "Start debugging",
                command_id: "dap.run",
            },
            MenuItem::Action {
                label: "Toggle breakpoint",
                command_id: "dap.toggle_breakpoint",
            },
            MenuItem::Action {
                label: "Conditional breakpoint…",
                command_id: "dap.toggle_breakpoint_conditional",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Step in",
                command_id: "dap.step_in",
            },
            MenuItem::Action {
                label: "Step out",
                command_id: "dap.step_out",
            },
            MenuItem::Action {
                label: "Step back",
                command_id: "dap.step_back",
            },
        ],
    }
}

fn terminal_menu() -> MenuDef {
    MenuDef {
        label: "Terminal",
        items: vec![
            MenuItem::Action {
                label: "New terminal (split below)",
                command_id: "term.shell",
            },
            MenuItem::Action {
                label: "Toggle scratch terminal",
                command_id: "term.scratch_toggle",
            },
            MenuItem::Action {
                label: "Rename terminal",
                command_id: "term.rename",
            },
        ],
    }
}

fn window_menu() -> MenuDef {
    MenuDef {
        label: "Window",
        items: vec![
            MenuItem::Action {
                label: "Reopen closed tab",
                command_id: "buffer.reopen",
            },
            MenuItem::Action {
                label: "Close other tabs",
                command_id: "view.close_others",
            },
            MenuItem::Action {
                label: "Pin / unpin tab",
                command_id: "buffer.pin_toggle",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "Restart mnml",
                command_id: "app.restart",
            },
        ],
    }
}

fn help_menu() -> MenuDef {
    MenuDef {
        label: "Help",
        items: vec![
            MenuItem::Action {
                label: "Welcome",
                command_id: "view.welcome",
            },
            MenuItem::Action {
                label: "Keybindings & help",
                command_id: "view.help",
            },
            MenuItem::Action {
                label: "Commands reference…",
                command_id: "view.commands_reference",
            },
            MenuItem::Separator,
            MenuItem::Action {
                label: "About mnml",
                command_id: "view.about",
            },
        ],
    }
}
