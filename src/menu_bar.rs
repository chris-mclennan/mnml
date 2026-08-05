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
    pub label: String,
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
    Action { label: String, command_id: String },
    /// Nested dropdown. On mouse click / Enter / Right-arrow, opens
    /// a submenu panel to the RIGHT of the parent, listing `items`.
    /// The rendered row shows a trailing `▸` to signal nesting.
    /// Only one level of nesting is supported — a Submenu inside a
    /// Submenu is currently not rendered.
    Submenu { label: String, items: Vec<MenuItem> },
    /// Visual separator. Skipped during keyboard nav.
    Separator,
}

impl MenuItem {
    pub fn action(label: impl Into<String>, command_id: impl Into<String>) -> Self {
        MenuItem::Action {
            label: label.into(),
            command_id: command_id.into(),
        }
    }
    pub fn submenu(label: impl Into<String>, items: Vec<MenuItem>) -> Self {
        MenuItem::Submenu {
            label: label.into(),
            items,
        }
    }
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
    /// When the currently-highlighted item is a `Submenu` and it's
    /// been opened (Right / Enter / click), this tracks the item
    /// index in the child list. `None` when no submenu is open.
    /// Only one level of nesting is currently supported.
    pub sub_item_idx: Option<usize>,
}

impl MenuOpenState {
    pub fn new_keyboard(menu_idx: usize) -> Self {
        Self {
            menu_idx,
            item_idx: 0,
            keyboard_opened: true,
            last_mnemonic: None,
            sub_item_idx: None,
        }
    }

    pub fn new_mouse(menu_idx: usize) -> Self {
        Self {
            menu_idx,
            item_idx: usize::MAX,
            keyboard_opened: false,
            last_mnemonic: None,
            sub_item_idx: None,
        }
    }
}

/// The full menu bar — all menus left to right. The leading brand
/// menu (`\u{e795}  mnml`) sits at the far left like the Apple
/// menu on macOS.
pub fn bar(app: &crate::app::App) -> Vec<MenuDef> {
    vec![
        brand_menu(),
        file_menu(app),
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
        label: "❯_  mnml".to_string(),
        items: vec![
            MenuItem::action("About mnml…", "view.about"),
            MenuItem::action("Settings…", "view.settings"),
            MenuItem::Separator,
            MenuItem::action("Quit mnml", "app.quit"),
        ],
    }
}

fn file_menu(app: &crate::app::App) -> MenuDef {
    // Build the Open Recent submenu from the live recent-files list
    // (capped at 10 for menu sanity). Each entry fires
    // `file.open_recent_N` — see command.rs registration.
    let mut recent_items: Vec<MenuItem> = app
        .recent_files
        .iter()
        .take(10)
        .enumerate()
        .map(|(i, p)| {
            let label = p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| p.to_string_lossy().into_owned());
            MenuItem::action(label, format!("file.open_recent_{i}"))
        })
        .collect();
    if recent_items.is_empty() {
        recent_items.push(MenuItem::action("(no recent files)", "noop"));
    } else {
        recent_items.push(MenuItem::Separator);
        recent_items.push(MenuItem::action("Clear recent files", "file.clear_recent"));
    }
    MenuDef {
        label: "File".to_string(),
        items: vec![
            MenuItem::action("New file", "file.new"),
            MenuItem::action("Open file…", "picker.files"),
            MenuItem::action("Open folder…", "view.add_workspace"),
            MenuItem::submenu("Open recent file", recent_items),
            MenuItem::action("Open recent file (picker)…", "picker.recent"),
            MenuItem::action("Switch workspace…", "view.switch_workspace"),
            MenuItem::Separator,
            MenuItem::action("Save", "file.save"),
            MenuItem::action("Save all", "file.save_all"),
            MenuItem::Separator,
            MenuItem::action("Close tab", "buffer.close"),
            MenuItem::Separator,
            MenuItem::action("Settings…", "view.settings"),
            MenuItem::action("Quit", "app.quit"),
        ],
    }
}

fn edit_menu() -> MenuDef {
    MenuDef {
        label: "Edit".to_string(),
        items: vec![
            MenuItem::action("Find…", "find.find"),
            MenuItem::action("Find next", "find.next"),
            MenuItem::action("Find previous", "find.prev"),
            MenuItem::action("Replace…", "find.replace"),
            MenuItem::Separator,
            MenuItem::action("Find in files…", "find.grep"),
            MenuItem::action("Replace in files…", "find.grep_replace"),
        ],
    }
}

fn selection_menu() -> MenuDef {
    MenuDef {
        label: "Selection".to_string(),
        items: vec![
            MenuItem::action("Expand selection", "lsp.selection_expand"),
            MenuItem::action("Shrink selection", "lsp.selection_shrink"),
            MenuItem::Separator,
            MenuItem::action("Add cursor above", "editor.add_cursor_above"),
            MenuItem::action("Add cursor below", "editor.add_cursor_below"),
            MenuItem::action("Add cursor at next match", "editor.add_cursor_at_next_word"),
            MenuItem::action("Select all occurrences", "editor.select_all_occurrences"),
            MenuItem::action("Clear extra cursors", "editor.clear_extra_cursors"),
        ],
    }
}

fn view_menu() -> MenuDef {
    MenuDef {
        label: "View".to_string(),
        items: vec![
            MenuItem::action("Command palette", "view.discovery"),
            MenuItem::Separator,
            MenuItem::action("Toggle file tree", "view.toggle_tree"),
            MenuItem::action("Toggle right panel", "view.toggle_right_panel"),
            MenuItem::action(
                "Cycle menu bar (always / auto / hidden)",
                "view.menu_bar_cycle",
            ),
            MenuItem::action("Toggle bufferline", "view.toggle_bufferline"),
            MenuItem::action("Toggle word wrap", "view.toggle_wrap"),
            MenuItem::action("Toggle zen mode", "view.zen"),
            MenuItem::action("Toggle hover-help strip", "view.toggle_hover_help"),
            MenuItem::Separator,
            MenuItem::action("Commands reference…", "view.commands_reference"),
            MenuItem::Separator,
            MenuItem::action("Pick theme…", "theme.pick"),
            MenuItem::action("Toggle theme", "theme.toggle"),
        ],
    }
}

fn go_menu() -> MenuDef {
    MenuDef {
        label: "Go".to_string(),
        items: vec![
            MenuItem::action("Go to file…", "view.discovery"),
            MenuItem::action("Go to line…", "editor.goto_line"),
            MenuItem::action("Go to definition", "lsp.peek_definition"),
            MenuItem::Separator,
            MenuItem::action("Previous buffer", "buffer.prev"),
            MenuItem::action("Next buffer", "buffer.next"),
            MenuItem::action("Last buffer", "buffer.last"),
        ],
    }
}

fn run_menu() -> MenuDef {
    MenuDef {
        label: "Run".to_string(),
        items: vec![
            MenuItem::action("Start debugging", "dap.run"),
            MenuItem::action("Toggle breakpoint", "dap.toggle_breakpoint"),
            MenuItem::action(
                "Conditional breakpoint…",
                "dap.toggle_breakpoint_conditional",
            ),
            MenuItem::Separator,
            MenuItem::action("Step in", "dap.step_in"),
            MenuItem::action("Step out", "dap.step_out"),
            MenuItem::action("Step back", "dap.step_back"),
        ],
    }
}

fn terminal_menu() -> MenuDef {
    MenuDef {
        label: "Terminal".to_string(),
        items: vec![
            MenuItem::action("New terminal (split below)", "term.shell"),
            MenuItem::action("Toggle scratch terminal", "term.scratch_toggle"),
            MenuItem::action("Rename terminal", "term.rename"),
        ],
    }
}

fn window_menu() -> MenuDef {
    // User request 2026-07-19: the Window menu should include a
    // Split section modelled on macOS's Move & Resize submenu —
    // splits (right / down / close / equalize), directional focus
    // (halves), and the AI-grid Layout toggle. Menu bar's MenuItem
    // enum only supports flat items (no submenu nesting yet), so
    // group by Separator instead. Every action maps to an existing
    // palette command so no new command wiring is needed here.
    MenuDef {
        label: "Window".to_string(),
        items: vec![
            MenuItem::action("Reopen closed tab", "buffer.reopen"),
            MenuItem::action("Close other tabs", "view.close_others"),
            MenuItem::action("Pin / unpin tab", "buffer.pin_toggle"),
            MenuItem::Separator,
            // Split ── side by side / stacked / close / equalize.
            MenuItem::action("Split right", "view.split_right"),
            MenuItem::action("Split down", "view.split_down"),
            MenuItem::action("Close split", "view.close_split"),
            MenuItem::action("Equalize splits", "view.equalize_splits"),
            MenuItem::action(
                "Auto-equalize on split / close (toggle)",
                "view.toggle_auto_equalize_splits",
            ),
            MenuItem::Separator,
            // #856/#857 — reversible layout reshape. Merge collapses
            // the whole split tree into one leaf's tabs; spread lays
            // each tab out into its own split via the auto-tile
            // shape heuristic. Reversible via each other.
            MenuItem::action("Merge splits into tabs", "layout.merge_to_tabs"),
            MenuItem::action("Spread tabs into splits", "layout.spread_to_splits"),
            MenuItem::Separator,
            // Resize the active split.
            MenuItem::action("Grow split width", "view.split_grow_width"),
            MenuItem::action("Grow split height", "view.split_grow_height"),
            MenuItem::Separator,
            // Focus a neighbouring split — the "Halves" of macOS.
            MenuItem::action("Focus split left", "view.focus_left"),
            MenuItem::action("Focus split right", "view.focus_right"),
            MenuItem::action("Focus split up", "view.focus_up"),
            MenuItem::action("Focus split down", "view.focus_down"),
            MenuItem::Separator,
            // AI layout mode toggle (grid ↔ tabs). Same command
            // the palette-bar AI chip menu fires.
            MenuItem::action("AI layout: Grid (splits)", "view.ai_layout_grid"),
            MenuItem::action("AI layout: Tabs (stack in leaf)", "view.ai_layout_tabs"),
            MenuItem::Separator,
            MenuItem::action("Restart mnml", "app.restart"),
        ],
    }
}

fn help_menu() -> MenuDef {
    MenuDef {
        label: "Help".to_string(),
        items: vec![
            MenuItem::action("Welcome", "view.welcome"),
            MenuItem::action("Keybindings & help", "view.help"),
            MenuItem::action("Commands reference…", "view.commands_reference"),
            MenuItem::Separator,
            MenuItem::action("About mnml", "view.about"),
        ],
    }
}
