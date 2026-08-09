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
            MenuItem::action("\u{F129}  About mnml…", "view.about"),
            MenuItem::action("\u{F013}  Settings…", "view.settings"),
            MenuItem::Separator,
            MenuItem::action("\u{F011}  Quit mnml", "app.quit"),
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
    // 2026-08-07 — glyph-prefix experiment for File menu.
    // Prefixing the icon directly into the label is the simplest
    // way to eyeball this without touching MenuItem's shape. If the
    // look holds up across menus, refactor to a dedicated `icon:`
    // field on MenuItem::Action with a render-time column so the
    // labels stay left-aligned even when some rows lack an icon.
    MenuDef {
        label: "File".to_string(),
        items: vec![
            // 2026-08-08 — glyph audit per user feedback ("some of
            // these are wrong; trash for Save all is bad"). Rule of
            // thumb: icon only where a widely-recognized nerd glyph
            // matches the action semantically; drop the icon (spacer
            // preserves alignment) where the closest glyph is
            // ambiguous or misleading. Verified icons: file_plus,
            // folder_open (nf-fa), history, save (single floppy),
            // close, cog, power_off.
            MenuItem::action("\u{F0224}  New file", "file.new"),
            MenuItem::action("\u{F115}  Open file…", "picker.files"),
            MenuItem::action("     Add folder to workspace…", "view.add_workspace"),
            MenuItem::submenu("\u{F1DA}  Open recent file", recent_items),
            MenuItem::action("\u{F1DA}  Open recent file (picker)…", "picker.recent"),
            MenuItem::action("     Switch workspace…", "view.switch_workspace"),
            MenuItem::Separator,
            MenuItem::action("\u{F0193}  Save", "file.save"),
            // No confidently-correct "save all" glyph — the previous
            // F0819 rendered as a trash can. Use the same floppy as
            // Save; the label carries the "all".
            MenuItem::action("\u{F0193}  Save all", "file.save_all"),
            MenuItem::Separator,
            MenuItem::action("\u{F00D}  Close tab", "buffer.close"),
            MenuItem::Separator,
            MenuItem::action("\u{F013}  Settings…", "view.settings"),
            MenuItem::action("\u{F011}  Quit", "app.quit"),
        ],
    }
}

fn edit_menu() -> MenuDef {
    // Same glyph-audit rule as File (2026-08-08): icon only where a
    // widely-recognized nerd glyph matches semantically; 5-space
    // spacer preserves alignment where no confidently-correct glyph
    // exists.
    MenuDef {
        label: "Edit".to_string(),
        items: vec![
            MenuItem::action("\u{F002}  Find…", "find.find"),
            MenuItem::action("     Find next", "find.next"),
            MenuItem::action("     Find previous", "find.prev"),
            MenuItem::action("\u{F0EC}  Replace…", "find.replace"),
            MenuItem::Separator,
            MenuItem::action("\u{F002}  Find in files…", "find.grep"),
            MenuItem::action("\u{F0EC}  Replace in files…", "find.grep_replace"),
        ],
    }
}

fn selection_menu() -> MenuDef {
    MenuDef {
        label: "Selection".to_string(),
        items: vec![
            MenuItem::action("\u{F065}  Expand selection", "lsp.selection_expand"),
            MenuItem::action("\u{F066}  Shrink selection", "lsp.selection_shrink"),
            MenuItem::Separator,
            MenuItem::action("\u{F062}  Add cursor above", "editor.add_cursor_above"),
            MenuItem::action("\u{F063}  Add cursor below", "editor.add_cursor_below"),
            MenuItem::action(
                "\u{F067}  Add cursor at next match",
                "editor.add_cursor_at_next_word",
            ),
            MenuItem::action(
                "     Select all occurrences",
                "editor.select_all_occurrences",
            ),
            MenuItem::action(
                "\u{F00D}  Clear extra cursors",
                "editor.clear_extra_cursors",
            ),
        ],
    }
}

fn view_menu() -> MenuDef {
    MenuDef {
        label: "View".to_string(),
        items: vec![
            MenuItem::action("\u{F0C9}  Command palette", "view.discovery"),
            MenuItem::Separator,
            MenuItem::action("     Toggle file tree", "view.toggle_tree"),
            MenuItem::action("     Toggle right panel", "view.toggle_right_panel"),
            MenuItem::action(
                "     Cycle menu bar (always / auto / hidden)",
                "view.menu_bar_cycle",
            ),
            MenuItem::action("     Toggle bufferline", "view.toggle_bufferline"),
            MenuItem::action("     Toggle word wrap", "view.toggle_wrap"),
            // fa-eye — zen = single-focus, not dark mode (F186 moon
            // was wrong; that reads as theme-dark).
            MenuItem::action("\u{F06E}  Toggle zen mode", "view.zen"),
            MenuItem::action("     Toggle hover-help strip", "view.toggle_hover_help"),
            MenuItem::Separator,
            MenuItem::action("\u{F02D}  Commands reference…", "view.commands_reference"),
            MenuItem::Separator,
            MenuItem::action("\u{F1FC}  Pick theme…", "theme.pick"),
            MenuItem::action("\u{F042}  Toggle theme", "theme.toggle"),
        ],
    }
}

fn go_menu() -> MenuDef {
    MenuDef {
        label: "Go".to_string(),
        items: vec![
            MenuItem::action("\u{F002}  Go to file…", "view.discovery"),
            // No confidently-correct "go to line number" glyph in the
            // Nerd Font subset — F149 (level-down) was a corner arrow
            // and read as "return" not "jump to line". Spacer for now.
            MenuItem::action("     Go to line…", "editor.goto_line"),
            MenuItem::action("     Go to definition", "lsp.peek_definition"),
            MenuItem::Separator,
            MenuItem::action("\u{F060}  Previous buffer", "buffer.prev"),
            MenuItem::action("\u{F061}  Next buffer", "buffer.next"),
            MenuItem::action("     Last buffer", "buffer.last"),
        ],
    }
}

fn run_menu() -> MenuDef {
    MenuDef {
        label: "Run".to_string(),
        items: vec![
            MenuItem::action("\u{F04B}  Start debugging", "dap.run"),
            MenuItem::action("\u{F111}  Toggle breakpoint", "dap.toggle_breakpoint"),
            MenuItem::action(
                "     Conditional breakpoint…",
                "dap.toggle_breakpoint_conditional",
            ),
            MenuItem::Separator,
            // fa-angle-double-down / -up — "step in" descends into a
            // frame, "step out" ascends out. Prior draft used single
            // arrows (F062/F063) which read as generic move, not
            // debug semantics. F103/F102 mirror VS Code's chevron-
            // pair convention. Step-back stays F048 (media
            // step-backward) — a distinct action, distinct shape.
            MenuItem::action("\u{F103}  Step in", "dap.step_in"),
            MenuItem::action("\u{F102}  Step out", "dap.step_out"),
            MenuItem::action("\u{F048}  Step back", "dap.step_back"),
        ],
    }
}

fn terminal_menu() -> MenuDef {
    MenuDef {
        label: "Terminal".to_string(),
        items: vec![
            MenuItem::action("\u{F120}  New terminal (split below)", "term.shell"),
            MenuItem::action("\u{F120}  Toggle scratch terminal", "term.scratch_toggle"),
            MenuItem::action("\u{F040}  Rename terminal", "term.rename"),
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
            MenuItem::action("\u{F0E2}  Reopen closed tab", "buffer.reopen"),
            MenuItem::action("\u{F00D}  Close other tabs", "view.close_others"),
            MenuItem::action("\u{F08D}  Pin / unpin tab", "buffer.pin_toggle"),
            MenuItem::Separator,
            // Split ── side by side / stacked / close / equalize.
            MenuItem::action("\u{F0DB}  Split right", "view.split_right"),
            MenuItem::action("     Split down", "view.split_down"),
            MenuItem::action("\u{F00D}  Close split", "view.close_split"),
            MenuItem::action("     Equalize splits", "view.equalize_splits"),
            MenuItem::action(
                "     Auto-equalize on split / close (toggle)",
                "view.toggle_auto_equalize_splits",
            ),
            MenuItem::Separator,
            // #856/#857 — reversible layout reshape. Merge collapses
            // the whole split tree into one leaf's tabs; spread lays
            // each tab out into its own split via the auto-tile
            // shape heuristic. Reversible via each other.
            MenuItem::action("     Merge splits into tabs", "layout.merge_to_tabs"),
            MenuItem::action("     Spread tabs into splits", "layout.spread_to_splits"),
            MenuItem::Separator,
            // Resize the active split.
            MenuItem::action("     Grow split width", "view.split_grow_width"),
            MenuItem::action("     Grow split height", "view.split_grow_height"),
            MenuItem::Separator,
            // Focus a neighbouring split — the "Halves" of macOS.
            MenuItem::action("\u{F060}  Focus split left", "view.focus_left"),
            MenuItem::action("\u{F061}  Focus split right", "view.focus_right"),
            MenuItem::action("\u{F062}  Focus split up", "view.focus_up"),
            MenuItem::action("\u{F063}  Focus split down", "view.focus_down"),
            MenuItem::Separator,
            // AI layout mode toggle (grid ↔ tabs). Same command
            // the palette-bar AI chip menu fires.
            MenuItem::action("     AI layout: Grid (splits)", "view.ai_layout_grid"),
            MenuItem::action(
                "     AI layout: Tabs (stack in leaf)",
                "view.ai_layout_tabs",
            ),
            MenuItem::Separator,
            MenuItem::action("\u{F021}  Restart mnml", "app.restart"),
        ],
    }
}

fn help_menu() -> MenuDef {
    MenuDef {
        label: "Help".to_string(),
        items: vec![
            MenuItem::action("\u{F0EB}  Welcome", "view.welcome"),
            MenuItem::action("\u{F11C}  Keybindings & help", "view.help"),
            MenuItem::action("\u{F02D}  Commands reference…", "view.commands_reference"),
            MenuItem::Separator,
            MenuItem::action("\u{F129}  About mnml", "view.about"),
        ],
    }
}
