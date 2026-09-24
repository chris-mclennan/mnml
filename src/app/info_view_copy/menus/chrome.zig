//! Hover help for the chrome's chip menus (`context_menus.openButtonMenu`
//! and the launcher dock's own menu): the palette bar's sidebar and
//! right-column toggles, the ← / → / ▾ chips, the ` TABS ` label, the
//! window `×`, the split strip's split / maximize chips, a tab page's
//! chip, the right column's strip, the `Add panel` `+`, the `Sidebar`
//! menu the column's ground opens, the launcher dock's menu (also the
//! dock edge grip's), the gear's rows, the theme pill's static rows and
//! a strip tab's own menu.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../../../app.zig").App;
const copy = @import("../../info_view_copy.zig");
const menus = @import("../menus.zig");
const command = @import("../../../core/command.zig");
const Row = menus.Row;
const Entry = copy.Entry;
const ask = copy.ask_link;

pub const rows = [_]Row{
    // ── the launcher dock's own menu (the strip's, the pin chip's and
    // the dock edge grip's); the same rows sit under an item's menu,
    // so they are not qualified by the title ──
    .{ .label = "Pin dock open", .entry = .{
        .title = "Pin dock open",
        .body = "Docks the strip for the rest of the session: it stops hiding itself and is carved out of the frame like any other chrome, whatever `ui.dock.mode` says. The pin is remembered in the session file rather than the config, so it comes back with the session and unpinning is one press. *Cycle mode* is the other way round — it rewrites the config key instead.",
        .links = &.{ .{ .command = .{ .id = .@"view.dock_pin", .label = "Pin it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.mode"), .label = "Dock mode in Settings" } }, copy.docsSection("The launcher dock") },
    } },
    .{ .label = "Unpin dock", .entry = .{
        .title = "Unpin dock",
        .body = "Ends the session pin and hands the strip back to `ui.dock.mode` — under auto-hide it waits for the pointer at its edge again, under hidden it goes until a command summons it. The strip is put down at once rather than at the next hide clock. Nothing in the config changes either way.",
        .links = &.{ .{ .command = .{ .id = .@"view.dock_pin", .label = "Unpin it" } }, .{ .command = .{ .id = .@"view.dock_toggle", .label = "Summon it once" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.mode"), .label = "Dock mode in Settings" } } },
    } },
    .{ .label = "Cycle mode (always / auto-hide / hidden)", .entry = .{
        .title = "Cycle the dock's mode",
        .body = "Steps `ui.dock.mode` one place on — always → auto-hide → hidden → always — and writes it to the home config, so the choice holds in every workspace. Any session pin is dropped by the step. Under hidden there is no hover door left: `view.dock_toggle` becomes the only way to bring the strip up.",
        .links = &.{ .{ .command = .{ .id = .@"view.dock_cycle_mode", .label = "Cycle it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.mode"), .label = "Dock mode in Settings" } }, copy.docsSection("The launcher dock") },
    } },
    .{ .label = "Move to the next edge (bottom / left / right)", .entry = .{
        .title = "Move the dock to the next edge",
        .body = "Steps `ui.dock.edge` bottom → left → right → bottom and writes it home. A revealed strip moves with the edge rather than being dismissed, and its hide clock starts again from there. There is no top edge — that row belongs to the menu bar — and a side strip takes the outermost column, with the sidebar's own reveal edge shifting one cell inwards to make room.",
        .links = &.{ .{ .command = .{ .id = .@"view.dock_move", .label = "Move it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.edge"), .label = "Dock edge in Settings" } }, copy.docsSection("The launcher dock") },
    } },
    .{ .label = "Show: icons and labels", .prefix = true, .kind = .set_dock_labels, .entry = dockLabels("icons and labels", "icon_label", "each item's glyph with its name beside it — the widest form, and the one that makes an unfamiliar icon readable") },
    .{ .label = "Show: icons only", .prefix = true, .kind = .set_dock_labels, .entry = dockLabels("icons only", "icon", "the glyphs alone, so a long run of launchers still fits across one row") },
    .{ .label = "Show: labels only", .prefix = true, .kind = .set_dock_labels, .entry = dockLabels("labels only", "label", "the names alone, for a terminal whose font has no Nerd Font glyphs to draw") },
    .{ .label = "Place: above the statusline", .prefix = true, .kind = .set_dock_placement, .entry = dockPlacement("above the statusline", "inner", "inside the frame's bottom rows, with the statusline and the `:` line below it") },
    .{ .label = "Place: below the command line", .prefix = true, .kind = .set_dock_placement, .entry = dockPlacement("below the command line", "outer", "outermost, under the `:` line, so the strip is the very last row of the terminal") },
    .{ .label = "Align: centre", .kind = .set_dock_align, .entry = dockAlign("centre", "center", "centred in the band, the run growing out from the middle as items are added") },
    .{ .label = "Align: start", .kind = .set_dock_align, .entry = dockAlign("start", "start", "packed against the start of the band — the left of a bottom strip, the top of a side one") },
    .{ .label = "Align: end", .kind = .set_dock_align, .entry = dockAlign("end", "end", "packed against the end of the band — the right of a bottom strip, the foot of a side one") },
    .{ .label = "+ at the right end", .kind = .set_dock_plus_at, .entry = dockPlusAt("right end", "right", "the end of the run — the right of a bottom strip") },
    .{ .label = "+ at the bottom end", .kind = .set_dock_plus_at, .entry = dockPlusAt("bottom end", "right", "the end of the run — the foot of a side strip") },
    .{ .label = "+ at the left end", .kind = .set_dock_plus_at, .entry = dockPlusAt("left end", "left", "the head of the run — the left of a bottom strip") },
    .{ .label = "+ at the top end", .kind = .set_dock_plus_at, .entry = dockPlusAt("top end", "left", "the head of the run — the top of a side strip") },
    .{ .label = "Running mark: bright icon", .kind = .set_dock_running_mark, .entry = dockRunningMark("bright icon", "bright", "paints the item's glyph in its full colour while a session or shell of its kind is running, and dims it otherwise") },
    .{ .label = "Running mark: small dot", .kind = .set_dock_running_mark, .entry = dockRunningMark("small dot", "dot", "adds a small dot beside the item while a session or shell of its kind is running, the glyph itself unchanged") },
    .{ .label = "Running mark: none", .kind = .set_dock_running_mark, .entry = dockRunningMark("none", "none", "shows nothing on the strip about what is running — the SESSIONS section and the tab strip still do") },
    .{ .label = "Move left", .command = .@"view.dock_item_move_prev", .entry = dockItemMove("left", "one place earlier along a bottom strip", .@"view.dock_item_move_prev") },
    .{ .label = "Move up", .command = .@"view.dock_item_move_prev", .entry = dockItemMove("up", "one place earlier along a side strip", .@"view.dock_item_move_prev") },
    .{ .label = "Move right", .command = .@"view.dock_item_move_next", .entry = dockItemMove("right", "one place later along a bottom strip", .@"view.dock_item_move_next") },
    .{ .label = "Move down", .command = .@"view.dock_item_move_next", .entry = dockItemMove("down", "one place later along a side strip", .@"view.dock_item_move_next") },
    .{ .label = "Move to start", .command = .@"view.dock_item_move_first", .entry = dockItemMove("to start", "to the head of the run", .@"view.dock_item_move_first") },
    .{ .label = "Move to end", .command = .@"view.dock_item_move_last", .entry = dockItemMove("to end", "to the foot of the run", .@"view.dock_item_move_last") },
    .{ .label = "Show the + button", .kind = .set_dock_plus, .entry = .{
        .title = "Show the + button",
        .body = "Puts the `+` on the strip — the same *Create…* menu the tab bar's `+` opens, one reach away from the dock — at the end `ui.dock.plus_at` names, the far end out of the box. The row ticks while it is on and the press writes `ui.dock.plus` to the home config. Off, the strip ends at its last item and the `+` is the tab bar's alone.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.plus"), .label = "The dock's + in Settings" } }, copy.docsSection("The launcher dock") },
    } },
    .{ .menu = "Launcher dock", .label = "Settings…", .entry = .{
        .title = "Settings…",
        .body = "Opens the Settings overlay so the dock's keys can be picked outright rather than cycled — mode, edge, placement, labels, align and the `+` all have rows under UI. Enter writes the home config, Esc puts the opened state back. The rows above this one change the same keys one step at a time.",
        .keys = &.{.{ .command = .@"view.settings", .label = "Settings" }},
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.mode"), .label = "Dock mode in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.align"), .label = "Dock alignment in Settings" } }, copy.docsSection("The launcher dock") },
    } },
    .{ .label = "Pin to dock", .entry = .{
        .title = "Pin to dock",
        .body = "Adds this item's command to `ui.dock.pins` in the home config, so it keeps a place on the strip in every workspace — even one where the integration that offered it is not enabled. The pinned copy sits at the tail of the strip, after the terminals, in the order it was pinned. Its own menu then reads *Unpin from dock*.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.pin_to_dock", .label = "Pin it" } }, .{ .command = .{ .id = .@"view.focus_dock", .label = "Put the keys in the strip" } }, copy.docsSection("The launcher dock") },
    } },
    .{ .label = "Unpin from dock", .entry = .{
        .title = "Unpin from dock",
        .body = "Takes this item's command out of `ui.dock.pins` and writes the shorter list home; the strip loses it on the next frame. An enabled integration's own item is unaffected — that one comes from the installed manifest, so only the pinned copy goes. Unpinning something that was not pinned toasts and changes nothing.",
        .links = &.{ .{ .command = .{ .id = .@"integrations.unpin_from_dock", .label = "Unpin it" } }, .{ .command = .{ .id = .@"view.activity_integrations", .label = "The integrations section" } }, copy.docsSection("The launcher dock") },
    } },

    // ── the side column's own menu: the ground's right press, the
    // left edge grip, and the last row of every rail section's menu ──
    .{ .label = "Pin (dock for this session)", .entry = .{
        .title = "Pin the column open",
        .body = "Docks the revealed column for the rest of the session: the panes give it their width instead of it painting over them, and it stops sliding away when the pointer leaves. Nothing is written to the config — the next launch reads `ui.sidebar` again. Under `ui.sidebar = always` there is nothing to pin and it says so rather than doing nothing.",
        .keys = &.{.{ .command = .@"view.sidebar_pin", .label = "Pin the column" }},
        .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Pin it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode in Settings" } } },
    } },
    .{ .label = "Unpin (back to auto-hide)", .entry = .{
        .title = "Unpin the column",
        .body = "Hands the column back to `ui.sidebar`: it goes on the next hide clock, and the pointer resting at the screen edge brings it in over the editor again. No pane is resized on the way out, because a revealed column never took a pane's rect. The pin was never in the config, so nothing has to be unwritten.",
        .keys = &.{.{ .command = .@"view.sidebar_pin", .label = "Unpin the column" }},
        .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Unpin it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode in Settings" } } },
    } },
    .{ .label = "Sidebar", .entry = .{
        .title = "Sidebar ▸ — how the column behaves",
        .body = "Opens the three words `ui.sidebar` takes — always docked, auto-hide, hidden — with the one in force ticked. Every rail section's menu carries this same submenu, because the rail is the column's edge and that is where a user goes looking for *stop doing that*. Picking a word writes the home config and drops any session pin.",
        .keys = &.{.{ .chord = "→ / ←", .label = "Open / close the submenu" }},
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode in Settings" } }, .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Pin it for the session" } } },
    } },
    .{ .parent = "Sidebar", .label = "Always (docked)", .entry = sidebarMode("always", .@"view.sidebar_mode_always", "the column is carved out of the frame and the panes share what is left — no hover, no sliding, the shape most editors have") },
    .{ .parent = "Sidebar", .label = "Auto-hide (reveal on the edge)", .entry = sidebarMode("auto", .@"view.sidebar_mode_auto", "the column stays down until the pointer rests in its one-cell screen edge, then paints over the editor — no pane moves and no terminal is resized") },
    .{ .parent = "Sidebar", .label = "Hidden (keyboard only)", .entry = sidebarMode("hidden", .@"view.sidebar_mode_hidden", "hover is off entirely; a command that targets the column still brings it up as a one-shot overlay, which is the only door left") },

    // ── the palette bar's sidebar toggle ──
    .{ .label = "Hide sidebar", .entry = .{
        .title = "Hide sidebar",
        .body = "Puts the left column away and gives its width to the panes; the rail's icons stay, so a section is one click from coming back. Under `ui.sidebar = auto` or `hidden` there is no docked column to close and this takes the revealed overlay down instead.",
        .keys = &.{ .{ .command = .@"view.toggle_tree", .label = "Toggle the left column" }, .{ .command = .@"view.focus_tree", .label = "Focus the tree" } },
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_tree", .label = "Hide it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode in Settings" } } },
    } },
    .{ .label = "Show sidebar", .entry = .{
        .title = "Show sidebar",
        .body = "Brings the left column back on whatever section it showed last, else the first that lives on that side — the explorer, as a rule. With nothing assigned to the left it toasts and points at a rail icon's *Move to left* row. In the vim profile the tree takes the keys as it opens.",
        .keys = &.{ .{ .command = .@"view.toggle_tree", .label = "Toggle the left column" }, .{ .command = .@"view.focus_tree", .label = "Focus the tree" } },
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_tree", .label = "Show it" } }, .{ .command = .{ .id = .@"view.focus_tree", .label = "Open it with the keys" } }, .{ .settings = .{ .row = copy.settingsRow("ui.tree_width"), .label = "Column width" } } },
    } },
    .{ .label = "Reset sidebar width", .entry = .{
        .title = "Reset sidebar width",
        .body = "Puts the left column back to thirty columns — the width a fresh mnml starts at — undoing a drag of its divider. It is the live width only: `ui.tree_width` in the config is neither read nor written here, so a custom default is safe but is not what you get back. *Reset view to default* does this along with everything else the frame hides.",
        .links = &.{ .{ .command = .{ .id = .@"view.reset_tree_width", .label = "Reset the width" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the whole view" } }, .{ .settings = .{ .row = copy.settingsRow("ui.tree_width"), .label = "Column width in Settings" } } },
    } },
    .{ .label = "Focus sidebar", .entry = .{
        .title = "Focus sidebar",
        .body = "Puts the keyboard in the file tree, opening the column first when it was closed — NvChad's `<leader>e`. The cursor lands where the tree left it; Esc or a click in a pane hands the keys back. A section other than the explorer is reached from its own rail icon rather than here.",
        .keys = &.{ .{ .command = .@"view.focus_tree", .label = "Focus the tree" }, .{ .command = .@"view.toggle_tree", .label = "Toggle the column" } },
        .links = &.{ .{ .command = .{ .id = .@"view.focus_tree", .label = "Focus it" } }, .{ .command = .{ .id = .@"picker.files", .label = "Fuzzy-open a file instead" } } },
    } },

    // ── the palette bar's right-column toggle ──
    .{ .label = "Show right column", .entry = .{
        .title = "Show right column",
        .body = "Opens the right column on the section it showed last, else the first that lives on that side — the outline and the problems list start there. With nothing assigned to the right it toasts and points at a rail icon's *Move to right* row. The panes give up the width; the keys stay where they are.",
        .keys = &.{ .{ .command = .@"view.toggle_right_panel", .label = "Toggle the right column" }, .{ .command = .@"view.focus_right_panel", .label = "Focus it" } },
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Show it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.right_panel_visible"), .label = "Right column in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.right_panel_width"), .label = "Its width" } } },
    } },
    .{ .label = "Hide right column", .entry = .{
        .title = "Hide right column",
        .body = "Closes the right column and hands its width back to the panes; the section it held is remembered, so showing it again lands on the same one. The rail keeps that section's icon, which is the one-click way back. Nothing is unloaded — the outline is still built when it returns.",
        .keys = &.{ .{ .command = .@"view.toggle_right_panel", .label = "Toggle the right column" }, .{ .command = .@"view.right_panel_close_tab", .label = "Close the section" } },
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Hide it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.right_panel_visible"), .label = "Right column in Settings" } } },
    } },
    .{ .label = "Focus right column", .entry = .{
        .title = "Focus right column",
        .body = "Puts the keyboard into the right column's section, opening the column first when it was closed. The section's own keys take over — j / k or the arrows walk its rows, Enter opens one — and Esc hands them back to the pane. With nothing living on the right it toasts instead.",
        .keys = &.{ .{ .command = .@"view.focus_right_panel", .label = "Focus the right column" }, .{ .command = .@"view.toggle_right_panel", .label = "Toggle it" } },
        .links = &.{ .{ .command = .{ .id = .@"view.focus_right_panel", .label = "Focus it" } }, .{ .command = .{ .id = .@"view.right_panel_next_tab", .label = "The next section" } } },
    } },
    .{ .label = "Add Outline", .entry = .{
        .title = "Add Outline",
        .body = "Builds the symbol outline for the active editor — into the right column when that column is open, otherwise as a split beside the file. The symbols come from the language server, so a file whose language has none — or one still starting up — lists nothing rather than a tree. Enter on a row jumps the editor to that symbol.",
        .links = &.{ .{ .command = .{ .id = .@"outline.show", .label = "Add it" } }, .{ .command = .{ .id = .@"lsp.symbols", .label = "Symbols as a picker instead" } }, .{ .command = .{ .id = .@"lsp.status", .label = "Which servers are running" } } },
    } },
    .{ .label = "Add Problems", .entry = .{
        .title = "Add Problems",
        .body = "Puts the project's diagnostics list in its column — every error, warning and hint the language servers have reported, with the file and line on each row. Enter opens that file at the line. An empty list means the servers have nothing to say yet, not that the project is clean: they report as they index.",
        .keys = &.{ .{ .command = .@"lsp.diagnostics", .label = "Problems" }, .{ .command = .@"lsp.next_diagnostic", .label = "Next diagnostic" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Add it" } }, .{ .command = .{ .id = .@"lsp.diagnostics_filter", .label = "Filter by severity" } }, ask },
    } },

    // ── the right column's strip: its chip and its `×` ──
    .{ .label = "Focus", .entry = .{
        .title = "Focus",
        .body = "Hands the keyboard to the section this strip is showing, without moving or closing anything. Its rows answer j / k and the arrows from there, and Esc gives the keys back to the pane that had them. A click anywhere inside the section does the same thing.",
        .keys = &.{.{ .command = .@"view.focus_right_panel", .label = "Focus the right column" }},
        .links = &.{ .{ .command = .{ .id = .@"view.focus_right_panel", .label = "Focus it" } }, .{ .command = .{ .id = .@"view.right_panel_next_tab", .label = "The next section" } } },
    } },
    .{ .label = "Next section", .entry = .{
        .title = "Next section",
        .body = "Shows the next section that lives on the right side, in rail order, wrapping from the last to the first — the column shows one at a time, so this is how the others are reached. The keyboard follows only when it was already in the column. With one section on that side it is a no-op.",
        .links = &.{ .{ .command = .{ .id = .@"view.right_panel_next_tab", .label = "Next" } }, .{ .command = .{ .id = .@"view.right_panel_prev_tab", .label = "Previous" } }, .{ .command = .{ .id = .@"view.focus_right_panel", .label = "Focus the column" } } },
    } },
    .{ .label = "Previous section", .entry = .{
        .title = "Previous section",
        .body = "Steps back one along the right side's list of sections, wrapping from the first to the last — the reverse of *Next section* over the same rail order. Which sections are on that side is a per-section choice: a rail icon's *Move to right* row puts one here.",
        .links = &.{ .{ .command = .{ .id = .@"view.right_panel_prev_tab", .label = "Previous" } }, .{ .command = .{ .id = .@"view.right_panel_next_tab", .label = "Next" } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar_side"), .label = "Which side sections start on" } } },
    } },
    .{ .label = "Close section", .entry = .{
        .title = "Close section",
        .body = "Closes the section the column is showing — and since a column shows one at a time, the column goes with it and the panes take the width. Unlike the toggle it only ever closes: *Show right column* is what brings it back, on the same section. *Next section* is the row when the other sections were what you wanted.",
        .keys = &.{.{ .command = .@"view.right_panel_close_tab", .label = "Close the section" }},
        .links = &.{ .{ .command = .{ .id = .@"view.right_panel_close_tab", .label = "Close it" } }, .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Toggle the column instead" } } },
    } },

    // ── the right column's ` + ` (Add panel) ──
    .{ .label = "Outline", .entry = .{
        .title = "Outline",
        .body = "The symbol tree of the active editor — functions, types, fields — in its column, indented the way the code nests and rebuilt as the file changes. Enter or a click jumps the editor to the symbol. It is language-server work, so a file with no server attached lists nothing however long you wait.",
        .links = &.{ .{ .command = .{ .id = .@"outline.show", .label = "Open the outline" } }, .{ .command = .{ .id = .@"lsp.symbols", .label = "Symbols in this file…" } }, .{ .command = .{ .id = .@"lsp.workspace_symbols", .label = "Symbols across the workspace…" } } },
    } },
    .{ .label = "Problems", .entry = .{
        .title = "Problems",
        .body = "The project-wide diagnostics list, one row per error or warning with its file and line. It reads what the language servers have pushed so far, so it fills in as they index rather than all at once. The statusline's diagnostics chip counts the same set and its menu filters it.",
        .keys = &.{.{ .command = .@"lsp.diagnostics", .label = "Problems" }},
        .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Open it" } }, .{ .command = .{ .id = .@"lsp.diagnostics_filter", .label = "All / warnings / errors" } }, ask },
    } },
    .{ .label = "AI chat", .entry = .{
        .title = "AI chat",
        .body = "Asks for a question and sends it to Claude with the active file and the selection attached as context, the answer landing in the AI pane. It is a one-shot ask, not a conversation — the Claude Code chip is what starts a session you can keep talking to. With `ai.routing.claude.backend = off` the box still opens and the refusal comes when you send.",
        .links = &.{ .{ .command = .{ .id = .@"ai.chat", .label = "Ask Claude" } }, .{ .command = .{ .id = .@"ai.claude_code", .label = "A full session instead" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.claude.backend"), .label = "Claude backend in Settings" } } },
    } },
    .{ .label = "Grep", .entry = .{
        .title = "Grep",
        .body = "Asks for a pattern and searches the workspace with `rg` when it is installed, falling back to a vim pattern when it is not. The hits open as a results pane rather than in the right column, which is where this row differs from its neighbours; the box is seeded with the active find's query. Each row opens its file at the line.",
        .keys = &.{.{ .command = .@"find.grep", .label = "Find in files" }},
        .links = &.{ .{ .command = .{ .id = .@"find.grep", .label = "Search the workspace" } }, .{ .command = .{ .id = .@"find.live_grep", .label = "Live grep with a preview" } }, .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace across the hits" } } },
    } },
    .{ .label = "Tests", .entry = .{
        .title = "Tests",
        .body = "Runs the whole suite for whichever project this workspace is and shows it in a runner terminal beside you — `cargo test`, `npm test`, `go test ./...` or pytest — while a .NET solution streams into the Tests pane a row per test. A workspace none of those fit says so rather than guessing a command. Re-run last-failed is the quick loop once something is red.",
        .links = &.{ .{ .command = .{ .id = .@"test.run_all", .label = "Run them" } }, .{ .command = .{ .id = .@"test.rerun_failed", .label = "Re-run the failures" } }, ask },
    } },

    // ── the palette bar's ` ← ` / ` → ` ──
    .{ .label = "Previous buffer", .entry = .{
        .title = "Previous buffer",
        .body = "Steps one tab to the left in this leaf's strip, wrapping round at the front — the same thing the ← chip's own left click does, so this row is the menu's spelling of the button. It is by position, not by history: `buffer.last` is the one that retraces where you have been. A leaf with one tab has nowhere to step.",
        .keys = &.{ .{ .command = .@"buffer.prev", .label = "Previous buffer" }, .{ .command = .@"buffer.next", .label = "Next buffer" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.prev", .label = "Step back" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Pick one instead" } } },
    } },
    .{ .label = "Next buffer", .entry = .{
        .title = "Next buffer",
        .body = "Steps one tab to the right in this leaf's strip, wrapping round at the end — again by position, so a tab dragged along the strip changes where this lands. Only this leaf's tabs are walked; another split keeps its own strip and its own place in it.",
        .keys = &.{ .{ .command = .@"buffer.next", .label = "Next buffer" }, .{ .command = .@"buffer.prev", .label = "Previous buffer" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.next", .label = "Step on" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Pick one instead" } } },
    } },
    .{ .label = "Buffers…", .entry = .{
        .title = "Buffers…",
        .body = "Opens a fuzzy picker over every open buffer, across every leaf and every tab page — type any part of a path and Enter brings that buffer to the front of whichever leaf holds it. The unsaved ones carry their dot. It is the way out of a strip too crowded to read.",
        .keys = &.{.{ .command = .@"picker.buffers", .label = "Switch buffer" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.buffers", .label = "Pick a buffer" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files instead" } } },
    } },
    .{ .label = "Clear history", .command = .@"buffer.clear_mru", .entry = .{
        .title = "Clear history",
        .body = "Empties the focus trail — the order panes were last in, which `buffer.last` reads to jump you back — leaving only the buffer you are on. The two arrow chips are unaffected: they step by tab position, so ← still walks the strip. No tab is closed and nothing is saved or lost; this is the trail, not the buffers.",
        .links = &.{ .{ .command = .{ .id = .@"buffer.clear_mru", .label = "Clear it" } }, .{ .command = .{ .id = .@"buffer.last", .label = "Jump back along the trail" } } },
    } },

    // ── the palette bar's ` ▾ ` ──
    .{ .label = "Recent files", .entry = .{
        .title = "Recent files",
        .body = "Opens a picker over the files opened most recently in this workspace, newest first and the file you are on left out, so the top row is the one to switch back to; the one under the cursor previews. The list is per workspace and survives a restart; the File menu's submenu and the welcome screen read the same one. A file moved or deleted since opens empty.",
        .keys = &.{.{ .command = .@"picker.recent", .label = "Recent files" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "Open the picker" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear the list" } } },
    } },
    .{ .label = "Recent commands", .entry = .{
        .title = "Recent commands",
        .body = "A picker over the commands run recently, newest first — the short list the palette floats to its own top as ★ rows, on its own here so a command used a minute ago is one press away. Enter runs the row. The list rides in the session file, so it is the one you left — per workspace, not per launch.",
        .links = &.{ .{ .command = .{ .id = .@"picker.recent_commands", .label = "Open it" } }, .{ .command = .{ .id = .palette, .label = "Every command" } } },
    } },
    .{ .label = "All files", .entry = .{
        .title = "All files",
        .body = "Opens the fuzzy picker over the workspace's files rather than the recent list — the recents first, then everything the tree would list, then files opened in other workspaces a tier below; type any part of a path and Enter opens the match in the active leaf. `.gitignore` decides what is in it, and no query gets past that. Beyond five thousand files the title says so and the tail is cut.",
        .keys = &.{.{ .command = .@"picker.files", .label = "Open file" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "Find a file" } }, .{ .command = .{ .id = .@"find.grep", .label = "Search their contents instead" } }, .{ .command = .{ .id = .@"files.open", .label = "A file browser pane" } } },
    } },
    .{ .label = "Command palette", .entry = .{
        .title = "Command palette",
        .body = "Everything mnml can do, as one fuzzy list — the three rows above are the openers that earn a place on the bar, and this is the rest of them. Each row shows its chord under the active profile, so the palette doubles as the place to look a shortcut up. Enter runs the row.",
        .keys = &.{.{ .command = .palette, .label = "Command palette" }},
        .links = &.{ .{ .command = .{ .id = .palette, .label = "Open it" } }, .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } }, .{ .command = .{ .id = .@"keys.edit", .label = "Rebind a key" } } },
    } },

    // ── the ` TABS ` label ──
    .{ .label = "Expanded", .entry = clusterMode("Expanded", "every chip of the top-right cluster drawn with its label, whatever the terminal's width", .@"view.cluster_mode_expanded") },
    .{ .label = "Compact", .entry = clusterMode("Compact", "the cluster's chips down to their glyphs, which buys the tab strip several columns", .@"view.cluster_mode_compact") },
    .{ .label = "Auto", .entry = clusterMode("Auto", "expanded while there is room and compact once the tabs need it, decided per frame", .@"view.cluster_mode_auto") },
    .{ .label = "Tab pages…", .entry = .{
        .title = "Tab pages…",
        .body = "A fuzzy picker over the tab pages — each row is a page's number, the title of its first pane, and how many splits it holds, with the current one marked. Enter switches to that page. It is the way round when there are more pages than the cluster has room to draw chips for.",
        .links = &.{ .{ .command = .{ .id = .@"tab.picker", .label = "Pick a page" } }, .{ .command = .{ .id = .@"tab.new", .label = "A new page" } }, .{ .command = .{ .id = .@"tab.reopen", .label = "Reopen the last closed page" } } },
    } },

    // ── a tab page's chip and its `×` ──
    .{ .label = "Close page", .entry = .{
        .title = "Close page",
        .body = "Closes this tab page — opening the menu made it current, so the rows always act on the page you pressed. Its clean panes close and any with unsaved work are re-homed into the page that takes focus, so nothing dirty drops out of every strip. The last page is never closed; it toasts instead.",
        .links = &.{ .{ .command = .{ .id = .@"tab.close", .label = "Close it" } }, .{ .command = .{ .id = .@"tab.reopen", .label = "Reopen the last closed page" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save everything first" } } },
    } },
    .{ .label = "Close other pages", .entry = .{
        .title = "Close other pages",
        .body = "Keeps this page and closes every other one, re-homing their unsaved panes into this page rather than dropping them — so the strip can end up longer than it was. There is one step back: *Reopen last closed tab page* brings the most recent of them round again, not the whole batch.",
        .links = &.{ .{ .command = .{ .id = .@"tab.only", .label = "Close the others" } }, .{ .command = .{ .id = .@"tab.reopen", .label = "Reopen the last closed page" } }, ask },
    } },
    .{ .label = "New tab page", .entry = .{
        .title = "New tab page",
        .body = "Adds an empty page at the end of the cluster, makes it current and opens a scratch buffer in it — a split tree of its own, with its own strip and its own layout. The other pages keep their splits exactly as they were. Alt+1…9 jump straight to a page by number.",
        .keys = &.{.{ .command = .@"tab.new", .label = "New tab page" }},
        .links = &.{ .{ .command = .{ .id = .@"tab.new", .label = "Add a page" } }, .{ .command = .{ .id = .@"view.move_to_new_tab", .label = "Move this pane to a new page" } }, .{ .command = .{ .id = .@"tab.picker", .label = "Tab pages…" } } },
    } },
    .{ .label = "Move left", .command = .@"tab.move_left", .entry = tabPageMove("left", "one place earlier", .@"tab.move_left", .@"tab.move_right") },
    .{ .label = "Move right", .command = .@"tab.move_right", .entry = tabPageMove("right", "one place later", .@"tab.move_right", .@"tab.move_left") },

    // ── a strip tab's own menu ──
    .{ .label = "Close", .command = .@"buffer.close", .entry = .{
        .title = "Close",
        .body = "Closes the tab the menu was opened on — the press made it active first, so it is always the one under the pointer. Unsaved work asks: save, discard, or cancel. The split goes with the last tab — the neighbour takes its space — and *Reopen closed tab* brings the buffer back with its cursor where it was.",
        .keys = &.{ .{ .command = .@"buffer.close", .label = "Close tab" }, .{ .command = .@"buffer.reopen", .label = "Reopen the last closed" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.close", .label = "Close it" } }, .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen the last closed" } }, .{ .command = .{ .id = .@"file.save", .label = "Save it first" } } },
    } },
    .{ .label = "Close all", .command = .@"view.close_others", .entry = .{
        .title = "Close all",
        .body = "Closes every pane in the frame except this one — every leaf, every split, not just this strip — which is why the tab under the pointer survives a row that says all. A buffer with unsaved work is kept rather than prompted for, and a toast counts the unsaved ones it kept; pinned tabs are kept too, uncounted.",
        .keys = &.{.{ .command = .@"view.close_others", .label = "Close all other panes" }},
        .links = &.{ .{ .command = .{ .id = .@"view.close_others", .label = "Close them" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save everything first" } }, ask },
    } },
    .{ .label = "Split right", .entry = .{
        .title = "Split right",
        .body = "Divides this leaf into two side by side and puts the same buffer in the new right half, focused — two views of one file, each with its own cursor and its own scroll. From a tab's menu it is that tab's buffer that is doubled. Closing either half leaves the other holding it.",
        .keys = &.{ .{ .command = .@"view.split_right", .label = "Split right" }, .{ .command = .@"view.split_down", .label = "Split down" } },
        .links = &.{ .{ .command = .{ .id = .@"view.split_right", .label = "Split it" } }, .{ .command = .{ .id = .@"view.focus_right", .label = "Focus the new half" } }, .{ .command = .{ .id = .@"view.close_split", .label = "Close a split again" } } },
    } },
    .{ .label = "Split down", .entry = .{
        .title = "Split down",
        .body = "Divides this leaf top and bottom and puts the same buffer in the new lower half, focused — the stacked form of the split beside it, which suits a long file better than a wide one. A terminal pane splits too, the shell staying with the original half. The divider between them can be dragged.",
        .keys = &.{ .{ .command = .@"view.split_down", .label = "Split down" }, .{ .command = .@"view.split_right", .label = "Split right" } },
        .links = &.{ .{ .command = .{ .id = .@"view.split_down", .label = "Split it" } }, .{ .command = .{ .id = .@"view.focus_down", .label = "Focus the lower half" } }, .{ .command = .{ .id = .@"view.close_split", .label = "Close a split again" } } },
    } },

    // ── the split strip's split chips ──
    .{ .label = "Equalize splits", .entry = .{
        .title = "Equalize splits",
        .body = "Re-shares this tab page's splits so every pane is the same size again — vim's Ctrl+W = — undoing the grow and shrink rows and any divider you have dragged. Only this page is touched; the other pages keep their shapes. Auto-equalize is the setting that does it after every split and close without being asked.",
        .links = &.{ .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize now" } }, .{ .command = .{ .id = .@"view.toggle_auto_equalize_splits", .label = "Do it automatically" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the whole view" } } },
    } },
    .{ .label = "Grow width", .entry = splitResize("Grow", "width", "wider", "columns", .@"view.split_grow_width", .@"view.split_shrink_width", "Ctrl+W >") },
    .{ .label = "Shrink width", .entry = splitResize("Shrink", "width", "narrower", "columns", .@"view.split_shrink_width", .@"view.split_grow_width", "Ctrl+W <") },
    .{ .label = "Grow height", .entry = splitResize("Grow", "height", "taller", "rows", .@"view.split_grow_height", .@"view.split_shrink_height", "Ctrl+W +") },
    .{ .label = "Shrink height", .entry = splitResize("Shrink", "height", "shorter", "rows", .@"view.split_shrink_height", .@"view.split_grow_height", "Ctrl+W -") },
    .{ .label = "Close active pane", .entry = .{
        .title = "Close active pane",
        .body = "Closes the active pane's tab rather than the split around it: with other tabs in that leaf the next one takes its place, and only the last tab leaves the leaf empty for its neighbour to absorb. Unsaved work asks first. *Close split* is the row for the split itself, whatever it is holding.",
        .keys = &.{.{ .command = .@"buffer.close", .label = "Close tab" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.close", .label = "Close it" } }, .{ .command = .{ .id = .@"view.close_split", .label = "Close the split instead" } }, .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen the last closed" } } },
    } },

    // ── the split strip's maximize chip ──
    .{ .label = "Zoom the split / restore", .entry = .{
        .title = "Zoom the split / restore",
        .body = "Gives the whole body to the active pane's leaf, and the same press hands it back; the chrome — tree, strips, statusline — stays, and the split tree underneath is untouched, so Ctrl+W and the dividers still address the real layout. The tick marks which command the chip's LEFT click runs, but picking here only runs it once: `ui.maximize_click` is what re-points the button.",
        .keys = &.{.{ .command = .@"view.toggle_zoom", .label = "Zoom the pane" }},
        .links = &.{ .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom it" } }, .{ .settings = .{ .row = copy.settingsRow("ui.maximize_click"), .label = "What the chip's click does" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the view" } } },
    } },
    .{ .label = "Full screen / restore", .entry = .{
        .title = "Full screen / restore",
        .body = "Hides the chrome outright — the tree, the bufferline, the menu bar and the statusline — leaving the panes and the `:` line, and the same press brings it all back. Entering toasts the way out, and Esc twice inside the chord timeout leaves as well. Like its neighbour it runs once here and does not re-point the chip's left click.",
        .keys = &.{ .{ .command = .@"view.fullscreen", .label = "Full screen" }, .{ .command = .@"view.toggle_zoom", .label = "Zoom one pane instead" } },
        .links = &.{ .{ .command = .{ .id = .@"view.fullscreen", .label = "Go full screen" } }, .{ .settings = .{ .row = copy.settingsRow("ui.maximize_click"), .label = "What the chip's click does" } }, .{ .command = .{ .id = .@"view.reset_layout", .label = "Reset the view" } } },
    } },

    // ── the window `×` ──
    .{ .label = "Quit (with confirm)", .entry = .{
        .title = "Quit (with confirm)",
        .body = "Ends the session, and the label means it: the box names every unsaved buffer — Save all, Quit anyway, Cancel, with Cancel holding the focus — and with nothing dirty `ui.confirm_quit` still asks once. A file copy in flight refuses the quit before either box. Tabs, splits and terminals are written to the session on the way out.",
        .keys = &.{.{ .command = .@"app.quit", .label = "Quit" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all first" } }, .{ .settings = .{ .row = copy.settingsRow("ui.confirm_quit"), .label = "Confirm on quit" } }, ask },
    } },
    .{ .label = "Save all", .entry = .{
        .title = "Save all",
        .body = "Writes every dirty buffer to disk in one pass before the window closes — the dot on each tab clears as its file lands. A scratch buffer with no path is skipped rather than prompted for one, so it is still unsaved when the quit box counts. Format-on-save and the trailing-whitespace rules run per file as usual.",
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save them" } }, .{ .command = .{ .id = .@"buffer.next_dirty", .label = "Go to the next unsaved one" } }, .{ .settings = .{ .row = copy.settingsRow("editor.format_on_save"), .label = "Format on save" } } },
    } },
    .{ .label = "Restart", .command = .@"app.restart", .entry = .{
        .title = "Restart",
        .body = "Quits with the exit code `run.sh`'s loop reads as rebuild-and-relaunch, so a fresh build comes back on the same workspace with the config and every file re-read from disk. The session is written first and restored after — tabs, splits and terminals included. Launched outside that loop there is nothing to relaunch mnml, so this is simply a quit.",
        .links = &.{ .{ .command = .{ .id = .@"app.restart", .label = "Restart" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save all first" } }, ask },
    } },

    // ── the theme pill's static rows (and the same menu from the
    // bufferline's theme chip) ──
    .{ .label = "Auto: match system (light / dark)", .entry = .{
        .title = "Auto: match system (light / dark)",
        .body = "Asks the OS whether it is in light or dark right now and paints whichever of `ui.theme` and its `ui.theme_toggle` partner matches, then re-checks every fifteen seconds so the editor turns over with the desktop. `theme.reset` is what stops the follow. Nothing is written: the next launch starts on `ui.theme` again.",
        .links = &.{ .{ .command = .{ .id = .@"theme.auto_system", .label = "Follow the system" } }, .{ .command = .{ .id = .@"theme.reset", .label = "Stop following" } }, copy.docsSection("Themes") },
    } },
    .{ .label = "Reset to config default", .entry = .{
        .title = "Reset to config default",
        .body = "Paints `ui.theme` from the config again — the way back after trying themes down this menu — and stops the system follow if it was on. The file's value wins, so a theme picked here and never written is simply forgotten. Nothing is saved by this row: the config already says what it puts back.",
        .links = &.{ .{ .command = .{ .id = .@"theme.reset", .label = "Reset it" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Edit config.zon" } }, copy.docsSection("Themes") },
    } },
    .{ .label = "Pick theme…  (fuzzy)", .entry = .{
        .title = "Pick theme…  (fuzzy)",
        .body = "Opens the theme picker instead of this menu's long tail: type part of a name and every theme paints live as the cursor passes over it, so the choice is made on the real editor rather than a swatch. Enter keeps the one under the cursor and writes `ui.theme` home; Esc puts back the one you had.",
        .links = &.{ .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, .{ .settings = .{ .row = copy.settingsRow("ui.theme"), .label = "Theme in Settings" } }, copy.docsSection("Themes") },
    } },

    // ── the activity bar's gear (its `Settings…` is the brand menu's
    // row — the gear's menu is titled `mnml` too) ──
    .{ .label = "Command Palette…", .entry = .{
        .title = "Command Palette…",
        .body = "Opens the fuzzy list of every registered command — the gear's way in, for a hand already down on the rail. Type a title or an id and Enter runs it; the ★ rows at the top are the ones run recently, and each row carries its chord under the active profile.",
        .keys = &.{.{ .command = .palette, .label = "Command palette" }},
        .links = &.{ .{ .command = .{ .id = .palette, .label = "Open it" } }, .{ .command = .{ .id = .@"picker.recent_commands", .label = "Recent commands only" } } },
    } },
    .{ .label = "Cheatsheet…", .entry = .{
        .title = "Cheatsheet…",
        .body = "Opens the keymap reference as an overlay: every chord in the profile you are in with the command it runs, your rebinds included, generated from the live keymap rather than a page that can drift. `/` filters it, `c` and `e` collapse and expand every group, Esc or F1 closes. It reads, it does not run — the palette is where a command is fired; the cheatsheet pane is the same list as a tab you can leave open.",
        .keys = &.{ .{ .command = .@"view.help", .label = "Keybindings & help" }, .{ .command = .@"view.cheatsheet", .label = "The cheatsheet pane" } },
        .links = &.{ .{ .command = .{ .id = .@"view.help", .label = "Open it" } }, .{ .command = .{ .id = .@"keys.edit", .label = "Rebind a key" } }, .{ .command = .{ .id = .@"keys.doctor", .label = "The keyboard doctor" } } },
    } },
    .{ .label = "Themes…", .entry = .{
        .title = "Themes…",
        .body = "Opens the theme picker from the rail: the names fuzzy-match and each one paints live as the cursor passes it, so a theme is judged on your own code. Enter writes `ui.theme` to the home config; Esc restores the theme you were on. The bufferline's theme pill lists the same set as rows you can walk.",
        .links = &.{ .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, .{ .settings = .{ .row = copy.settingsRow("ui.theme"), .label = "Theme in Settings" } }, copy.docsSection("Themes") },
    } },
    .{ .menu = "mnml", .label = "About mnml", .entry = .{
        .title = "About mnml",
        .body = "Opens the About box from the gear: the version, the workspace, how many commands are implemented of the registry's total, the active keymap profile with its binding count, and the zig the binary was built with. It is the first thing a maintainer asks for, so paste it into a bug report whole; a newer release is a separate check.",
        .links = &.{ .{ .command = .{ .id = .@"view.about", .label = "Open it" } }, .{ .command = .{ .id = .@"app.check_updates", .label = "Check for a newer release" } } },
    } },
};

// ─── the templated families ─────────────────────────────────────────────

/// The launcher dock's three *Show:* rows — one form of
/// `ui.dock.labels` each. On a side edge the label carries a
/// `(bottom edge only)` tail, so the rows match by prefix.
fn dockLabels(comptime form: []const u8, comptime value: []const u8, comptime what: []const u8) Entry {
    return .{
        .title = "Show: " ++ form,
        .body = "Draws the strip's items as " ++ what ++ ", writing `ui.dock.labels = " ++ value ++ "` to the home config; the tick marks the form in use. A dock on the left or right edge draws icons alone whatever this says — the other two rows admit that with a *(bottom edge only)* tail and still write the key, which takes hold when the strip moves back to the bottom.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.labels"), .label = "Dock labels in Settings" } }, .{ .command = .{ .id = .@"view.dock_move", .label = "Move it to the bottom edge" } }, copy.docsSection("The launcher dock") },
    };
}

/// Its two *Place:* rows — which of the frame's bottom rows a bottom
/// strip takes (`ui.dock.placement`).
fn dockPlacement(comptime where: []const u8, comptime value: []const u8, comptime what: []const u8) Entry {
    return .{
        .title = "Place: " ++ where,
        .body = "Puts a bottom strip " ++ what ++ ", written to the home config as `ui.dock.placement = " ++ value ++ "`. A revealed strip is put down as the row moves, since the one that is up is at the old place. On a side edge the row reads *(bottom edge only)* and still writes the key — it is the bottom strip's question, and moving back answers it.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.placement"), .label = "Dock placement in Settings" } }, .{ .command = .{ .id = .@"view.dock_move", .label = "Move it to the bottom edge" } }, copy.docsSection("The launcher dock") },
    };
}

/// Its two *+ at the … end* rows — which end of the run the `+` sits
/// at; the words follow the edge (right / left on a bottom strip, bottom
/// / top on a side one).
fn dockPlusAt(comptime where: []const u8, comptime value: []const u8, comptime what: []const u8) Entry {
    return .{
        .title = "+ at the " ++ where,
        .body = "Puts the strip's `+` at " ++ what ++ ", written home as `ui.dock.plus_at = " ++ value ++ "`; the tick marks the end in force. The `+` stays out of the item order — *Move …* rows and `Alt+←` / `Alt+→` reorder the items around it, never it. With the `+` off (*Show the + button*) the row still writes the key for the next time it is on.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.plus_at"), .label = "The +'s end in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.plus"), .label = "The + itself" } }, copy.docsSection("The launcher dock") },
    };
}

/// Its three *Running mark:* rows — how an item whose thing is running
/// (a shell, a Claude or Codex session, an integration's pane) is told
/// apart from one that is not.
fn dockRunningMark(comptime form: []const u8, comptime value: []const u8, comptime what: []const u8) Entry {
    return .{
        .title = "Running mark: " ++ form,
        .body = "Marks a running item by " ++ form ++ ": " ++ what ++ ". Written home as `ui.dock.running_mark = " ++ value ++ "`; the tick marks the form in use, and `:dock mark bright|dot|none` is the same switch from the command line. The mark reads the same state the SESSIONS section and the tab strip's chips do, so the three never disagree.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.running_mark"), .label = "Running mark in Settings" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } }, copy.docsSection("The launcher dock") },
    };
}

/// A dock item's own *Move …* rows — the item's place in the run, kept
/// in `ui.dock.order`.
fn dockItemMove(comptime word: []const u8, comptime how: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Move " ++ word,
        .body = "Moves this item " ++ how ++ " and writes the strip's order to `ui.dock.order` in the home config, so it holds across launches and workspaces. Items the list does not name follow in the strip's default order; the `+` keeps its end (*+ at the … end*) whatever the order says. `Alt+←` / `Alt+→` on a focused item step the same way.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Move it" } }, .{ .command = .{ .id = .@"view.focus_dock", .label = "Focus the dock" } }, copy.docsSection("The launcher dock") },
    };
}

/// Its three *Align:* rows — where the run of items sits along the
/// band (`ui.dock.align`).
fn dockAlign(comptime word: []const u8, comptime value: []const u8, comptime what: []const u8) Entry {
    return .{
        .title = "Align: " ++ word,
        .body = "Lays the strip's items out " ++ what ++ ", written home as `ui.dock.align = " ++ value ++ "`; the tick marks the one in force. It is the run that moves, never the band, so the reveal edge and the hover zone stay exactly where they were. A side dock takes this too — there it aligns the items down the column.",
        .links = &.{ .{ .settings = .{ .row = copy.settingsRow("ui.dock.align"), .label = "Dock alignment in Settings" } }, .{ .settings = .{ .row = copy.settingsRow("ui.dock.plus"), .label = "The + at the head of the run" } }, copy.docsSection("The launcher dock") },
    };
}

/// The `Sidebar ▸` submenu's three rows — the words `ui.sidebar`
/// takes. They ride on every rail section's menu as well as the
/// column's own.
fn sidebarMode(comptime value: []const u8, comptime id: command.CommandId, comptime what: []const u8) Entry {
    return .{
        .title = "Sidebar — " ++ value,
        .body = "Writes `ui.sidebar = " ++ value ++ "` to the home config, so the side column behaves this way in every workspace: " ++ what ++ ". The tick marks the word in force, and any session pin is dropped as the mode changes. The rail and its icons stay whichever is picked.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Use this mode" } }, .{ .settings = .{ .row = copy.settingsRow("ui.sidebar"), .label = "Sidebar mode in Settings" } }, .{ .command = .{ .id = .@"view.toggle_tree", .label = "Toggle the column now" } } },
    };
}

/// The ` TABS ` label's three mode rows (`ui.top_bar_cluster_mode`).
fn clusterMode(comptime label: []const u8, comptime what: []const u8, comptime id: command.CommandId) Entry {
    return .{
        .title = "Tab cluster — " ++ label,
        .body = "Sets how the top-right cluster draws itself: this row is " ++ what ++ ". The tick marks the mode in use, and the press writes `ui.top_bar_cluster_mode` to the home config. Whatever the mode, the chips do the same things — only their labels come and go.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Use this mode" } }, .{ .settings = .{ .row = copy.settingsRow("ui.top_bar_cluster_mode"), .label = "Cluster mode in Settings" } } },
    };
}

/// A tab page's *Move left* / *Move right* rows.
fn tabPageMove(comptime dir: []const u8, comptime where: []const u8, comptime id: command.CommandId, comptime back: command.CommandId) Entry {
    return .{
        .title = "Move " ++ dir,
        .body = "Swaps this page with its neighbour so it sits " ++ where ++ " in the cluster, carrying its splits and its tabs with it; the page stays current, so the chips move under a pointer that has not. At the " ++ dir ++ " end there is nowhere to go and the press does nothing. Alt+1…9 address the pages by their new positions.",
        .links = &.{ .{ .command = .{ .id = id, .label = "Move it " ++ dir } }, .{ .command = .{ .id = back, .label = "Move it back" } }, .{ .command = .{ .id = .@"tab.picker", .label = "Tab pages…" } } },
    };
}

/// The split chips' grow / shrink pair, per axis — one template over
/// (grow | shrink) × (width | height).
fn splitResize(comptime verb: []const u8, comptime axis: []const u8, comptime how: []const u8, comptime unit: []const u8, comptime id: command.CommandId, comptime back: command.CommandId, comptime vim: []const u8) Entry {
    return .{
        .title = verb ++ " " ++ axis,
        .body = "Shifts the enclosing split five points of its ratio toward the active pane, " ++ how ++ " in " ++ unit ++ " at its neighbours' expense — vim's " ++ vim ++ " — and by that much again on each further press, clamped at a tenth and nine tenths. The divider can be dragged for the same thing by hand, and *Equalize splits* puts every size back at once. A leaf with no neighbour along that axis has nothing to take from.",
        .links = &.{ .{ .command = .{ .id = id, .label = verb ++ " the " ++ axis } }, .{ .command = .{ .id = back, .label = "The other way" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } } },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn closeMenu(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
}

fn expectCurated(app: *App) !void {
    if (try menus.firstUncovered(app, app.frame.allocator())) |label| {
        std.debug.print("chrome: no entry for `{s}` in menu `{s}`\n", .{ label, app.overlay.menu.title });
        return error.Uncovered;
    }
}

test "chrome: every row of the chip menus, the dock's menu and a tab's menu resolves to a curated entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const cm = @import("../../context_menus.zig");
    const render = @import("../../render.zig");
    const id = try app.openScratch();

    const buttons = [_]render.Button{ .toggle_tree, .toggle_right_panel, .right_tab, .right_new, .back, .forward, .dropdown, .tabs_label, .theme_toggle, .window_close, .split_right, .split_down, .split_max, .edge_grip_sidebar_left, .edge_grip_dock };
    for (buttons) |b| {
        closeMenu(&app);
        _ = try cm.openButtonMenu(&app, @intFromEnum(b), 5, 5);
        try expectCurated(&app);
    }
    closeMenu(&app);
    _ = try cm.openButtonMenu(&app, render.Button.tabPage(0), 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try @import("../../launcher_dock.zig").openDockMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openSidebarModeMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openGearMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openThemeMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openAddPanelMenu(&app, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);
    try cm.openTabMenu(&app, id, 5, 5);
    try expectCurated(&app);
    closeMenu(&app);

    // The qualifiers that matter. `Restart` is three commands in three
    // menus: the window `×` runs `app.restart`, a terminal tab's row
    // runs `term.restart`.
    try t.expectEqualStrings("Restart", menus.lookupItem("mnml", null, "Restart", .{ .command = .@"app.restart" }).?.title);
    try t.expectEqualStrings("Restart the terminal", menus.lookupItem("Terminal", null, "Restart", .{ .command = .@"term.restart" }).?.title);
    // `Settings…` in the dock's menu is about the dock's own keys; the
    // gear's menu, titled `mnml` too, takes the brand menu's row.
    try t.expect(std.mem.indexOf(u8, menus.lookup("Launcher dock", null, "Settings…").?.body, "mode, edge, placement") != null);
    // A templated row: each `Align:` row names its own layout.
    try t.expectEqualStrings("Align: end", menus.lookup("Launcher dock", null, "Align: end").?.title);
    try t.expect(std.mem.indexOf(u8, menus.lookup("Launcher dock", null, "Align: start").?.body, "start of the band") != null);
    // A `Show:` row matches its `(bottom edge only)` form by prefix.
    try t.expectEqualStrings("Show: labels only", menus.lookup("Launcher dock", null, "Show: labels only (bottom edge only)").?.title);
    // The `Sidebar ▸` children are the same three wherever the parent
    // row is carried — every rail section's menu included.
    try t.expectEqualStrings("Sidebar — hidden", menus.lookup("Explorer", "Sidebar", "Hidden (keyboard only)").?.title);
}
