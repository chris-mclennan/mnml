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
///
/// Task #886 — `icon` is optional, rendered in a dedicated
/// left-column so labels line up across items with mixed icon
/// presence / widths. When every item in a menu has `icon: None`,
/// the renderer skips the column entirely (no wasted space).
#[derive(Debug, Clone)]
pub enum MenuItem {
    /// `(icon, label, palette_command_id)`. Click / Enter fires the
    /// command id via `crate::command::run` — same as the palette.
    /// The label is what the user sees; the command id is internal.
    /// `icon` is an optional single glyph rendered in the left icon
    /// column with a dim fg (comment color) so it reads as a chrome
    /// affordance, not part of the label text.
    Action {
        icon: Option<String>,
        label: String,
        command_id: String,
    },
    /// Nested dropdown. On mouse click / Enter / Right-arrow, opens
    /// a submenu panel to the RIGHT of the parent, listing `items`.
    /// The rendered row shows a trailing `▸` to signal nesting.
    /// Only one level of nesting is supported — a Submenu inside a
    /// Submenu is currently not rendered.
    Submenu {
        icon: Option<String>,
        label: String,
        items: Vec<MenuItem>,
    },
    /// Visual separator. Skipped during keyboard nav.
    Separator,
}

impl MenuItem {
    /// Iconless action — label rendered with no left-column icon.
    /// Use for items whose semantic doesn't map to a glyph.
    pub fn action(label: impl Into<String>, command_id: impl Into<String>) -> Self {
        MenuItem::Action {
            icon: None,
            label: label.into(),
            command_id: command_id.into(),
        }
    }
    /// Icon + label. `icon` is a single glyph string (typically a
    /// Nerd Font codepoint); the renderer draws it in the left
    /// column with a dim fg. Task #886.
    pub fn action_with_icon(
        icon: impl Into<String>,
        label: impl Into<String>,
        command_id: impl Into<String>,
    ) -> Self {
        MenuItem::Action {
            icon: Some(icon.into()),
            label: label.into(),
            command_id: command_id.into(),
        }
    }
    /// Iconless submenu.
    pub fn submenu(label: impl Into<String>, items: Vec<MenuItem>) -> Self {
        MenuItem::Submenu {
            icon: None,
            label: label.into(),
            items,
        }
    }
    /// Submenu with a left-column icon.
    pub fn submenu_with_icon(
        icon: impl Into<String>,
        label: impl Into<String>,
        items: Vec<MenuItem>,
    ) -> Self {
        MenuItem::Submenu {
            icon: Some(icon.into()),
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
    /// #1097 (2026-08-20) — inline filter shown at the top of the
    /// dropdown. Empty = "no filter, all items visible + mnemonic
    /// cycling active". Non-empty = "filter mode: only items whose
    /// label contains this substring are surfaced". Toggled with
    /// `/` (like the palette + help overlay). Backspace shortens,
    /// Esc clears (first press) then closes menu (second press).
    pub filter: String,
    /// `true` when `/` was pressed and typed chars append to
    /// `filter`. `false` = classic mnemonic-cycle mode (a-z keys
    /// jump between first-letter matches).
    pub filter_focused: bool,
}

impl MenuOpenState {
    /// #1097 — returns the item indexes visible under the current
    /// filter. Empty filter → every non-separator index. Non-empty
    /// filter → case-insensitive substring match on the label.
    /// Separators are dropped when filter is active (rendering
    /// them between two disjoint filtered slices looks broken).
    pub fn visible_indexes(&self, items: &[MenuItem]) -> Vec<usize> {
        if self.filter.is_empty() {
            return (0..items.len()).collect();
        }
        let needle = self.filter.to_lowercase();
        items
            .iter()
            .enumerate()
            .filter_map(|(i, it)| match it {
                MenuItem::Action { label, .. } | MenuItem::Submenu { label, .. } => {
                    if label.to_lowercase().contains(&needle) {
                        Some(i)
                    } else {
                        None
                    }
                }
                MenuItem::Separator => None,
            })
            .collect()
    }

    pub fn new_keyboard(menu_idx: usize) -> Self {
        Self {
            menu_idx,
            item_idx: 0,
            keyboard_opened: true,
            last_mnemonic: None,
            sub_item_idx: None,
            filter: String::new(),
            filter_focused: false,
        }
    }

    pub fn new_mouse(menu_idx: usize) -> Self {
        Self {
            menu_idx,
            item_idx: usize::MAX,
            keyboard_opened: false,
            last_mnemonic: None,
            sub_item_idx: None,
            filter: String::new(),
            filter_focused: false,
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
            MenuItem::action_with_icon("\u{F129}", "About mnml…", "view.about"),
            MenuItem::action_with_icon("\u{F013}", "Settings…", "view.settings"),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F011}", "Quit mnml", "app.quit"),
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
            MenuItem::action_with_icon("\u{F0224}", "New file", "file.new"),
            MenuItem::action_with_icon("\u{F115}", "Open file…", "picker.files"),
            MenuItem::action_with_icon(
                "\u{EEC7}",
                "Add folder to workspace…",
                "view.add_workspace",
            ),
            MenuItem::submenu_with_icon("\u{F1DA}", "Open recent file", recent_items),
            MenuItem::action_with_icon("\u{F443}", "Switch workspace…", "view.switch_workspace"),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F0193}", "Save", "file.save"),
            MenuItem::action_with_icon("\u{F0194}", "Save all", "file.save_all"),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F00D}", "Close tab", "buffer.close"),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F013}", "Settings…", "view.settings"),
            MenuItem::action_with_icon("\u{F011}", "Quit", "app.quit"),
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
            MenuItem::action_with_icon(crate::ui::search_glyph::NERD, "Find…", "find.find"),
            MenuItem::action_with_icon("\u{F063}", "Find next", "find.next"),
            MenuItem::action_with_icon("\u{F062}", "Find previous", "find.prev"),
            MenuItem::action_with_icon("\u{F0EC}", "Replace…", "find.replace"),
            MenuItem::Separator,
            MenuItem::action_with_icon(
                crate::ui::search_glyph::NERD,
                "Find in files…",
                "find.grep",
            ),
            MenuItem::action_with_icon("\u{F0EC}", "Replace in files…", "find.grep_replace"),
        ],
    }
}

fn selection_menu() -> MenuDef {
    MenuDef {
        label: "Selection".to_string(),
        items: vec![
            MenuItem::action_with_icon("\u{F065}", "Expand selection", "lsp.selection_expand"),
            MenuItem::action_with_icon("\u{F066}", "Shrink selection", "lsp.selection_shrink"),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F062}", "Add cursor above", "editor.add_cursor_above"),
            MenuItem::action_with_icon("\u{F063}", "Add cursor below", "editor.add_cursor_below"),
            MenuItem::action_with_icon(
                "\u{F067}",
                "Add cursor at next match",
                "editor.add_cursor_at_next_word",
            ),
            MenuItem::action_with_icon(
                "\u{EB85}",
                "Select all occurrences",
                "editor.select_all_occurrences",
            ),
            MenuItem::action_with_icon(
                "\u{F00D}",
                "Clear extra cursors",
                "editor.clear_extra_cursors",
            ),
        ],
    }
}

fn view_menu() -> MenuDef {
    MenuDef {
        label: "View".to_string(),
        items: vec![
            MenuItem::action_with_icon("\u{F0770}", "File browser pane", "files.open"),
            MenuItem::action_with_icon(
                "\u{F0770}",
                "Dual file panes (commander)",
                "files.open_split",
            ),
            // #1226 (2026-08-28) — was `view.discovery`, which only
            // toggles the F1 click-discovery overlay. The most
            // discoverable route to the palette for a mouse user
            // opened a debug panel instead.
            MenuItem::action_with_icon("\u{F4B5}", "Command palette", "palette"),
            MenuItem::Separator,
            // Same codicon glyphs as the palette-bar chips
            // (`layout-sidebar-left-off` EC02, `layout-sidebar-right-off`
            // EC00) so the menu-bar entry and the toolbar chip read
            // as the same control. "Left panel" reads as parallel to
            // "Right panel" and no longer implies the panel is only
            // for files — it also hosts GIT / Integrations / Agents /
            // HTTP / Findings depending on activity-bar selection.
            MenuItem::action_with_icon("\u{EC02}", "Toggle left panel", "view.toggle_tree"),
            MenuItem::action_with_icon("\u{EC00}", "Toggle right panel", "view.toggle_right_panel"),
            // codicon-layout-panel — mirrors the sidebar codicons above;
            // R7 vscode-mouse SEV-2 F4 (no visible mouse path to open
            // the bottom panel before this).
            MenuItem::action_with_icon(
                "\u{EC17}",
                "Toggle bottom panel",
                "view.toggle_bottom_panel",
            ),
            MenuItem::action_with_icon(
                "\u{F0C9}",
                "Cycle menu bar (always / auto / hidden)",
                "view.menu_bar_cycle",
            ),
            MenuItem::action_with_icon("\u{EB80}", "Toggle line wrap", "view.toggle_wrap"),
            // fa-eye — zen = single-focus, not dark mode (F186 moon
            // was wrong; that reads as theme-dark).
            MenuItem::action_with_icon("\u{F06E}", "Toggle full screen", "view.fullscreen"),
            MenuItem::action_with_icon("\u{F02D6}", "Toggle hover-help", "view.toggle_hover_help"),
            // mdi-circle-outline — "dot marker" semantic. If tofu,
            // swap to a spacer per the R6 glyph convention.
            MenuItem::action_with_icon(
                "\u{F0130}",
                "Toggle workspace dots",
                "view.toggle_workspace_dots",
            ),
            MenuItem::Separator,
            MenuItem::action_with_icon(
                "\u{F02D}",
                "Commands reference…",
                "view.commands_reference",
            ),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F1FC}", "Pick theme…", "theme.pick"),
            MenuItem::action_with_icon("\u{F042}", "Toggle theme", "theme.toggle"),
        ],
    }
}

fn go_menu() -> MenuDef {
    MenuDef {
        label: "Go".to_string(),
        items: vec![
            // #1226 — `view.discovery` opened the click-discovery
            // overlay, not a file picker. `picker.files` is the fuzzy
            // file picker this label promises.
            MenuItem::action_with_icon(
                crate::ui::search_glyph::NERD,
                "Go to file…",
                "picker.files",
            ),
            // fa-hashtag — universal "line #N" mark.
            MenuItem::action_with_icon("\u{F292}", "Go to line…", "editor.goto_line"),
            // codicon-arrow-right — "jump-to" (distinct from Prev/Next
            // fa-arrow-* below which are wider single arrows).
            MenuItem::action_with_icon("\u{EAB5}", "Go to definition", "lsp.goto_definition"),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F060}", "Previous buffer", "buffer.prev"),
            MenuItem::action_with_icon("\u{F061}", "Next buffer", "buffer.next"),
            // fa-step-forward — media-control "to the end" shape,
            // same-family as Prev/Next arrows but distinct.
            MenuItem::action_with_icon("\u{F050}", "Last buffer", "buffer.last"),
        ],
    }
}

fn run_menu() -> MenuDef {
    MenuDef {
        label: "Run".to_string(),
        items: vec![
            MenuItem::action_with_icon("\u{F04B}", "Start debugging", "dap.run"),
            MenuItem::action_with_icon("\u{F111}", "Toggle breakpoint", "dap.toggle_breakpoint"),
            MenuItem::action_with_icon(
                "\u{EA97}",
                "Conditional breakpoint…",
                "dap.toggle_breakpoint_conditional",
            ),
            MenuItem::Separator,
            // fa-angle-double-down / -up — "step in" descends into a
            // frame, "step out" ascends out. Prior draft used single
            // arrows (F062/F063) which read as generic move, not
            // debug semantics. F103/F102 mirror VS Code's chevron-
            // pair convention. Step-back stays F048 (media
            // step-backward) — a distinct action, distinct shape.
            MenuItem::action_with_icon("\u{F103}", "Step in", "dap.step_in"),
            MenuItem::action_with_icon("\u{F102}", "Step out", "dap.step_out"),
            MenuItem::action_with_icon("\u{F048}", "Step back", "dap.step_back"),
        ],
    }
}

fn terminal_menu() -> MenuDef {
    MenuDef {
        label: "Terminal".to_string(),
        items: vec![
            MenuItem::action_with_icon("\u{F120}", "New terminal (split below)", "term.shell"),
            MenuItem::action_with_icon(
                "\u{F120}",
                "Toggle scratch terminal",
                "term.scratch_toggle",
            ),
            MenuItem::action_with_icon("\u{F040}", "Rename terminal", "term.rename"),
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
            MenuItem::action_with_icon("\u{F0E2}", "Reopen closed tab", "buffer.reopen"),
            MenuItem::action_with_icon("\u{F00D}", "Close other tabs", "view.close_others"),
            MenuItem::action_with_icon("\u{F08D}", "Pin / unpin tab", "buffer.pin_toggle"),
            MenuItem::Separator,
            // Split ── side by side / stacked / close / equalize.
            // EB56/EB57 mirror the H/V chips in the top-right cluster
            // so the menu item and the toolbar icon read as the same
            // control.
            MenuItem::action_with_icon("\u{EB56}", "Split right", "view.split_right"),
            MenuItem::action_with_icon("\u{EB57}", "Split down", "view.split_down"),
            MenuItem::action_with_icon("\u{F00D}", "Close split", "view.close_split"),
            MenuItem::action_with_icon("\u{F02C1}", "Equalize splits", "view.equalize_splits"),
            MenuItem::action_with_icon(
                "\u{F0758}",
                "Auto-equalize on split / close (toggle)",
                "view.toggle_auto_equalize_splits",
            ),
            MenuItem::Separator,
            // #856/#857 — reversible layout reshape. Merge collapses
            // the whole split tree into one leaf's tabs; spread lays
            // each tab out into its own split via the auto-tile
            // shape heuristic. Reversible via each other.
            // fa-object-group / -ungroup — "combine into one" vs
            // "break out into many". First-round MDI picks (F0575 /
            // F0577) tofu'd in the user's Nerd Font subset.
            MenuItem::action_with_icon(
                "\u{F247}",
                "Merge splits into tabs",
                "layout.merge_to_tabs",
            ),
            MenuItem::action_with_icon(
                "\u{F248}",
                "Spread tabs into splits",
                "layout.spread_to_splits",
            ),
            MenuItem::Separator,
            // Resize the active split. fa-arrows-alt-h / -v — universal
            // horizontal / vertical two-headed arrows.
            MenuItem::action_with_icon("\u{F07E}", "Grow split width", "view.split_grow_width"),
            MenuItem::action_with_icon("\u{F07D}", "Grow split height", "view.split_grow_height"),
            MenuItem::Separator,
            // Focus a neighbouring split — the "Halves" of macOS.
            MenuItem::action_with_icon("\u{F060}", "Focus split left", "view.focus_left"),
            MenuItem::action_with_icon("\u{F061}", "Focus split right", "view.focus_right"),
            MenuItem::action_with_icon("\u{F062}", "Focus split up", "view.focus_up"),
            MenuItem::action_with_icon("\u{F063}", "Focus split down", "view.focus_down"),
            MenuItem::Separator,
            // AI layout mode toggle (grid ↔ tabs). Same command
            // the palette-bar AI chip menu fires.
            // fa-th (3x3 grid) vs fa-list-alt (stacked rows) — clear
            // visual contrast for the grid-vs-stack choice.
            MenuItem::action_with_icon(
                "\u{F00A}",
                "AI layout: Grid (splits)",
                "view.ai_layout_grid",
            ),
            MenuItem::action_with_icon(
                "\u{F022}",
                "AI layout: Tabs (stack in leaf)",
                "view.ai_layout_tabs",
            ),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F021}", "Restart mnml", "app.restart"),
        ],
    }
}

fn help_menu() -> MenuDef {
    MenuDef {
        label: "Help".to_string(),
        items: vec![
            MenuItem::action_with_icon("\u{F0EB}", "Welcome", "view.welcome"),
            MenuItem::action_with_icon("\u{F11C}", "Keybindings & help", "view.help"),
            MenuItem::action_with_icon(
                "\u{F02D}",
                "Commands reference…",
                "view.commands_reference",
            ),
            MenuItem::Separator,
            MenuItem::action_with_icon("\u{F129}", "About mnml", "view.about"),
        ],
    }
}

#[cfg(test)]
mod wiring_tests {
    use super::*;

    /// Collect `(label, command_id)` for every action in a menu,
    /// descending into submenus.
    fn actions(items: &[MenuItem]) -> Vec<(String, String)> {
        let mut out = Vec::new();
        for it in items {
            match it {
                MenuItem::Action {
                    label, command_id, ..
                } => out.push((label.clone(), command_id.clone())),
                MenuItem::Submenu { items, .. } => out.extend(actions(items)),
                MenuItem::Separator => {}
            }
        }
        out
    }

    fn command_for(menu: &MenuDef, label: &str) -> String {
        actions(&menu.items)
            .into_iter()
            .find(|(l, _)| l == label)
            .unwrap_or_else(|| panic!("no `{label}` item in the {} menu", menu.label))
            .1
    }

    /// #1226 — these two entries ran `view.discovery`, which only
    /// toggles the F1 click-discovery overlay. The View menu's
    /// "Command palette" is the most discoverable route to the palette
    /// for a mouse user, and it opened a debug panel instead.
    ///
    /// A label is a promise. Pin the ones that name a specific surface
    /// to the command that opens it — "does the id resolve" would have
    /// stayed green through the entire bug, because `view.discovery`
    /// resolves fine.
    #[test]
    fn menu_labels_that_name_a_surface_fire_the_command_that_opens_it() {
        assert_eq!(command_for(&view_menu(), "Command palette"), "palette");
        assert_eq!(command_for(&go_menu(), "Go to file…"), "picker.files");
    }

    /// Every menu action must resolve to a registered command — a
    /// typo'd id is a silently dead row.
    #[test]
    fn every_menu_action_resolves_to_a_registered_command() {
        let ids: std::collections::HashSet<&str> = crate::command::registry()
            .all()
            .iter()
            .map(|c| c.id)
            .collect();
        let mut dead: Vec<String> = Vec::new();
        for menu in [view_menu(), go_menu()] {
            for (label, id) in actions(&menu.items) {
                if !ids.contains(id.as_str()) {
                    dead.push(format!("{} → \"{label}\" → `{id}`", menu.label));
                }
            }
        }
        assert!(
            dead.is_empty(),
            "menu rows pointing at unregistered commands:\n  {}",
            dead.join("\n  ")
        );
    }
}
