//! Hover help for the chrome: the top bar's buttons (`render.Button`),
//! the menu bar's words, the tab strip's chips and the cluster at its
//! right end, the tabs themselves, breadcrumbs, dividers, scrollbars,
//! the edge grips, the toasts, and the surface line of every pane
//! kind — what the box says when the pointer rests on a pane's body.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const hit = @import("../../ui/hit.zig");
const render = @import("../render.zig");
const Button = render.Button;
const menu_bar = @import("../menu_bar.zig");
const zen = @import("../zen.zig");
const side = @import("../side.zig");
const ai_app = @import("../ai.zig");
const integrations = @import("../integrations.zig");
const integrations_view = @import("../../ui/integrations_view.zig");
const toast_mod = @import("../../ui/toast.zig");
const md_preview = @import("../md_preview.zig");
const zon_pane = @import("../zon_pane.zig");
const command = @import("../../core/command.zig");
const pty_pane = @import("../pty_pane.zig");
const sessions = @import("../../sessions.zig");
const icons = @import("../../ui/icons.zig");

const ask = copy.ask_link;

// ─── buttons ────────────────────────────────────────────────────────────

pub fn button(app: *App, arena: Allocator, id: u32) Allocator.Error!?Entry {
    if (menu_bar.buttonOf(id)) |m| return try menuWord(app, arena, m);
    if (id == menu_bar.overflow_button) return .{
        .title = "More menus",
        .body = "The menu bar is wider than the terminal, so the words that did not fit are behind this `»`. Click lists them; each row opens that menu where it would have been. Widen the terminal and the words come back onto the bar on their own.",
        .links = &.{.{ .settings = .{ .row = comptime copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } }},
    };
    if (Button.tabPageOf(id)) |page| return try tabPage(app, arena, page);
    if (Button.tabPageCloseOf(id) != null) return .{
        .title = "Close this tab page",
        .body = "Closes the whole tab page — every split and tab in it — and shows the page before it. Nothing asks: a buffer with unsaved edits moves to the page that stays as a background tab, and the clean ones close. On the last page the `×` is still painted and the click only says there is one tab page.",
        .links = &.{ .{ .command = .{ .id = .@"tab.close", .label = "Close this page" } }, .{ .command = .{ .id = .@"tab.only", .label = "Close every other page" } } },
    };
    if (Button.tabScrollOf(id)) |ts| return .{
        .title = if (ts.dir == .left) "Previous page of tabs" else "Next page of tabs",
        .body = "The strip holds more tabs than fit, so they are cut into pages of whole tabs and `‹ 2/5 ›` says which page is on show. Click turns one page that way — before the first comes the last, after the last the first; the wheel over the strip moves one tab at a time. The control is gone when every tab fits. The buffer picker lists every tab, shown or hidden; the active tab is always brought into view when it changes.",
        .keys = &.{ .{ .command = .@"buffer.next", .label = "Next buffer" }, .{ .command = .@"buffer.prev", .label = "Previous buffer" }, .{ .command = .@"picker.buffers", .label = "Buffer picker" } },
        .links = &.{ .{ .command = .{ .id = .@"picker.buffers", .label = "Pick a buffer" } }, .{ .command = .{ .id = .@"buffer.close_others", .label = "Close the other tabs" } } },
    };
    if (Button.newTabLeaf(id) != null) return .{
        .title = "+ New tab",
        .body = "Click or right-click opens the *Create…* menu, aimed at this split: a new file, a shell, a Claude or Codex session, a panel, a tool, an integration; rows can be pinned to the top of that menu or hidden from it. In git mode a left click brings a closed repo back instead. The launcher dock's `+` opens the same menu.",
        .keys = &.{ .{ .command = .@"file.new", .label = "New file" }, .{ .command = .@"term.shell", .label = "New shell" } },
        .links = &.{ .{ .command = .{ .id = .@"scratch.new", .label = "New scratch buffer" } }, .{ .command = .{ .id = .@"file.new", .label = "New file…" } }, .{ .command = .{ .id = .@"term.shell", .label = "Open a shell" } } },
    };
    if (id == md_preview.button_edit) return .{
        .title = "Edit the markdown",
        .body = "Swaps the raw editor in for this rendered preview — the same document, so the cursor lands at the top of the source and edits show in the preview when you come back. With `ui.markdown_opens_rendered` on, opening a `.md` lands here first; `:e` on the path opens the source directly.",
        .links = &.{ .{ .command = .{ .id = .@"markdown.edit_raw", .label = "Edit the source" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.markdown_opens_rendered"), .label = "Markdown opens rendered" } } },
    };
    if (id == md_preview.button_preview) return .{
        .title = "Preview the markdown",
        .body = "Opens the rendered view of this markdown file beside the source — headings, lists, code blocks, and images where the terminal can draw them (`ui.md_image_rows` sets their height). Links are clickable in the preview; the source stays where it was and the two follow each other on save.",
        .links = &.{ .{ .command = .{ .id = .@"markdown.preview", .label = "Open the preview" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.auto_md_preview"), .label = "Auto markdown preview" } } },
    };
    if (id == zon_pane.button_view) return .{
        .title = "View the ZON as a tree",
        .body = "Opens the field tree beside this `.zon` text: every key as a row with its value, Enter to edit one, `←→` to step an enum or a bool, `/` to filter by path. The tree writes the file when a value changes, so the text tab updates under it. For config.zon each row's doc line comes from docs/CONFIG.md.",
        .links = &.{.{ .command = .{ .id = .@"zon.view", .label = "Open the tree" } }},
    };
    if (id == zon_pane.button_source) return .{
        .title = "Back to the ZON source",
        .body = "Reveals the raw text tab of this `.zon` file — the tree stays open in its own tab, and a save from either side is read by the other. Editing the text directly is the way to add a key the tree does not list yet.",
        .links = &.{.{ .command = .{ .id = .@"zon.source", .label = "Show the source" } }},
    };
    if (id == toast_mod.undo_button) return .{
        .title = if (app.undo_chip) |u| try std.fmt.allocPrint(arena, "Undo: {s}", .{u.label}) else "Undo the last close",
        .body = "The chip that appears after a batch close — `closed 3 tabs`, a workspace switch — and puts it back while it is up. Click undoes; right-click drops the offer. It goes on its own after a few seconds, and only the most recent batch is offered, so an undo a minute later is the buffer picker's reopen row instead.",
        .keys = &.{.{ .command = .@"buffer.reopen", .label = "Reopen the last closed buffer" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen the last closed buffer" } }, .{ .command = .{ .id = .@"toast.dismiss_current", .label = "Dismiss" } } },
    };
    if (@import("../session_attention.zig").isSessionToast(app, id)) return .{
        .title = "A session needs input",
        .body = "A Claude Code or Codex session stopped to ask you something — a permission, a choice, a question. Click the box (or its Focus button) to go to it: its pane comes on screen with the keys, the same as a double-click on its SESSIONS card; a session no pane here runs is shown selected in the sessions table instead. The bell's right-click lists every session waiting right now.",
        .links = &.{ .{ .command = .{ .id = .@"sessions.next_waiting", .label = "Next session ready for you" } }, .{ .command = .{ .id = .@"toast.dismiss_current", .label = "Dismiss" } }, ask },
    };
    if (@import("../ipc_gate.zig").isGateToast(app, id)) return .{
        .title = "A program asks to run a command",
        .body = "Something running in a pane wrote a command to mnml's file channel (`.mnml/ipc/command`) that can change more than the view — edit a buffer, write a file, start a process. Nothing has run. Click the box (or its Review button) for the full request and the answers: Allow once, Allow that class for the rest of this run, Deny, or Cancel to leave it waiting. Unanswered, it is denied after two minutes. Every answer is written to `.mnml/ipc/audit.jsonl`.",
        .links = &.{ .{ .command = .{ .id = .@"toast.run_action", .label = "Review it" } }, .{ .command = .{ .id = .@"messages.show", .label = "Open the history" } }, ask },
    };
    if (id >= toast_mod.button_base) return .{
        .title = "Toast",
        .body = "A message from something that just happened — a save, a git result, an error from a server — in the bottom-right corner, kept in the message history after it fades so the bell can find it again. Click dismisses this one; right-click offers dismiss, copy the text, dismiss all. A red toast is an error and its full text is in the history if the line was cut.",
        .links = &.{ .{ .command = .{ .id = .@"messages.show", .label = "Open the history" } }, .{ .command = .{ .id = .@"toast.copy_clicked", .label = "Copy the text" } }, ask },
    };
    if (id >= integrations_view.chip_base and id < integrations_view.chip_base + integrations_view.max_chips) {
        const list = try integrations.chips(app, arena);
        const i = id - integrations_view.chip_base;
        if (i >= list.len) return null;
        const c = list[i];
        return .{
            .title = try std.fmt.allocPrint(arena, "{s}{s}", .{ c.tooltip, if (c.enabled) "" else " — disabled" }),
            .body = try std.fmt.allocPrint(arena, "The `{s}` integration's chip on the top bar, one of the icons in `ui.integration_icons`. Click runs it — an integration pane opens, or its tool starts in a terminal split; right-click is its menu: disable, pin to the rail or the dock, take it off the bar, copy id. {s}The bar shows the chips the integrations mark for it; the Integrations section lists them all.", .{ c.id, if (c.enabled) "" else "It is disabled, so the click toasts instead; enable it from the menu. " }),
            .keys = &.{.{ .command = .@"view.activity_integrations", .label = "Integrations" }},
            .links = &.{ .{ .command = .{ .id = .@"integrations.pin_to_dock", .label = "Pin to the dock" } }, .{ .command = .{ .id = .@"integrations.toggle_palette_bar", .label = "Show / hide the bar's chips" } }, .{ .command = .{ .id = .@"integrations.configure_picker", .label = "Configure it" } } },
        };
    }
    if (id >= @intFromEnum(Button.new_tab_base)) return null;
    const n = app.panes.count();
    return switch (@as(Button, @enumFromInt(id))) {
        .palette => .{
            .title = "Workspace chip — the pickers",
            .body = "The chip that names the workspace at the left of the strip is the door to the pickers: click opens the command palette, right-click the recent-files list. The file picker (fuzzy, over every file the tree knows, `.git/` excluded) is the same picker over the files; type a `>` first in it and it becomes the palette.",
            .keys = &.{ .{ .command = .@"picker.files", .label = "Files" }, .{ .command = .palette, .label = "Commands" }, .{ .command = .@"picker.recent", .label = "Recent files" } },
            .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "Open a file" } }, .{ .command = .{ .id = .palette, .label = "The command palette" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files" } } },
        },
        .toggle_tree => .{
            .title = if (app.tree.visible) "Left column — open" else "Left column — hidden",
            .body = "Shows or hides the left column: the file tree, or whichever section is on that side, with this info box under it. Click toggles; right-click is Show or Hide, Reset sidebar width and Focus sidebar. The column's mode — always, auto (slides in when the pointer rests at the edge), hidden — is `ui.sidebar` in Settings; under auto, with `ui.edge_grips` on, a `⋮` grip marks the edge.",
            .keys = &.{ .{ .command = .@"view.toggle_tree", .label = "Toggle the left column" }, .{ .command = .@"view.focus_tree", .label = "Focus the tree" } },
            .links = &.{ .{ .command = .{ .id = .@"view.toggle_tree", .label = "Toggle it" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.sidebar"), .label = "Side columns in Settings" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.tree_width"), .label = "Tree width" } } },
        },
        .toggle_right_panel => .{
            .title = if (side.shown(app, .right) != null) "Right column — open" else "Right column — hidden",
            .body = "Shows or hides the right column — the outline, diagnostics, or any section moved to that side from its rail menu. Click toggles; right-click lists what can go there. Its width is `ui.right_panel_width`; whether it opens at start is `ui.right_panel_visible`, both per workspace.",
            .keys = &.{.{ .command = .@"view.toggle_right_panel", .label = "Toggle the right column" }},
            .links = &.{ .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Toggle it" } }, .{ .command = .{ .id = .@"view.focus_right_panel", .label = "Focus it" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.right_panel_width"), .label = "Right panel width" } } },
        },
        .ai_claude => try aiLauncher(app, .claude),
        .ai_codex => try aiLauncher(app, .codex),
        .back => .{
            .title = "Back — the previous buffer",
            .body = if (n <= 1) "Steps to the previous tab of the active split, by position, wrapping at the start; terminal tabs are stepped over. With one buffer open the click does nothing. Right-click is Previous, Next, Buffers… and Clear history." else try std.fmt.allocPrint(arena, "Steps to the previous tab of the active split, by position along the strip, wrapping at the start; terminal tabs are stepped over ({d} panes are open). Right-click is Previous, Next, Buffers… (the picker) and Clear history. The jumplist (`nav.back`) is the other history: positions inside files rather than tabs.", .{n}),
            .keys = &.{ .{ .command = .@"buffer.prev", .label = "Previous buffer" }, .{ .command = .@"nav.back", .label = "Back in the jumplist" } },
            .links = &.{ .{ .command = .{ .id = .@"buffer.prev", .label = "Previous buffer" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Pick a buffer" } } },
        },
        .forward => .{
            .title = "Forward — the next buffer",
            .body = if (n <= 1) "Steps to the next tab of the active split, by position, wrapping at the end; terminal tabs are stepped over. With one buffer open the click does nothing. Right-click is Previous, Next, Buffers… and Clear history." else try std.fmt.allocPrint(arena, "Steps to the next tab of the active split, by position along the strip, wrapping at the end — the reverse of Back ({d} panes are open). Right-click is Previous, Next, Buffers… and Clear history. The jumplist (`nav.forward`) is the other history: positions inside files rather than tabs.", .{n}),
            .keys = &.{ .{ .command = .@"buffer.next", .label = "Next buffer" }, .{ .command = .@"nav.forward", .label = "Forward in the jumplist" } },
            .links = &.{ .{ .command = .{ .id = .@"buffer.next", .label = "Next buffer" } }, .{ .command = .{ .id = .@"picker.buffers", .label = "Pick a buffer" } } },
        },
        .dropdown => .{
            .title = "Recent files",
            .body = "The `▾` beside the workspace chip lists the files opened most recently in this workspace, newest first, kept across restarts in the session. Click opens the list as a picker; right-click is the Open… menu — Recent files, Recent commands, All files, Command palette. `file.clear_recent` empties it.",
            .keys = &.{.{ .command = .@"picker.recent", .label = "Recent files" }},
            .links = &.{ .{ .command = .{ .id = .@"picker.recent", .label = "Open the list" } }, .{ .command = .{ .id = .@"file.clear_recent", .label = "Clear it" } } },
        },
        .new_tab_page => .{
            .title = "New tab page",
            .body = "A tab page is a whole layout — its own splits and tabs — the way a vim tab page or a tmux window is. Click makes an empty one and switches to it; the page chips in the cluster switch back, Alt+1..9 too. Sessions restore every page, so a page for the tests and a page for the code both come back.",
            .keys = &.{.{ .command = .@"tab.new", .label = "New tab page" }},
            .links = &.{ .{ .command = .{ .id = .@"tab.new", .label = "New tab page" } }, .{ .command = .{ .id = .@"tab.list", .label = "List the pages" } } },
        },
        .tabs_label => .{
            .title = if (app.layouts.layouts.items.len <= 1) "TABS — one tab page" else try std.fmt.allocPrint(arena, "TABS — {d} tab pages", .{app.layouts.layouts.items.len}),
            .body = "The cluster's label for the tab pages; the numbered chips after it are the pages, the active one lit. Click opens the tab-page picker; right-click is the cluster's menu — how much of the cluster shows (`ui.top_bar_cluster_mode`: expanded, compact, auto) and Tab pages…. On a narrow terminal the cluster compacts to the chips alone.",
            .links = &.{ .{ .command = .{ .id = .@"tab.picker", .label = "Pick a page" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.top_bar_cluster_mode"), .label = "Top bar cluster" } } },
        },
        .theme_toggle => .{
            .title = try std.fmt.allocPrint(arena, "Theme — {s}", .{app.theme.name}),
            .body = "The theme pill names the active theme. Click toggles to the alternate `ui.theme_toggle` names (`theme.toggle`), or opens the picker when none is set; right-click is the theme menu — pick from every shipped and user theme, follow the system's light/dark, reset. Picking one writes `ui.theme` to the home config, so it holds across workspaces.",
            .keys = &.{.{ .command = .@"theme.toggle", .label = "Toggle the theme" }},
            .links = &.{ .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, .{ .command = .{ .id = .@"theme.auto_system", .label = "Follow the system" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.theme"), .label = "Theme in Settings" } } },
        },
        .window_close => .{
            .title = "Quit mnml",
            .body = "Closes the app. With unsaved buffers the quit box asks — Save all, Quit anyway, Cancel — and with nothing to lose it still confirms once when `ui.confirm_quit` is on. The session (tabs, splits, the cursor in each file) is written on the way out and restored at the next start, so quitting is cheap. Right-click is the Window menu.",
            .keys = &.{.{ .command = .@"app.quit", .label = "Quit" }},
            .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save everything" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.confirm_quit"), .label = "Confirm on quit" } }, .{ .command = .{ .id = .@"app.quit", .label = "Quit" } } },
        },
        .split_term => .{
            .title = "Terminal chip",
            .body = "Opens a shell in a split beside the active pane — your `$SHELL`, in the workspace directory, driven by libghostty-vt so it renders like ghostty does. Right-click picks where it goes (left, right, top, bottom half), toggles the scratch terminal, and has the *Icon* submenu: whether this chip and every terminal tab wear the ghost or the plain terminal mark (`ui.terminal_glyph`). Closing the tab ends the shell.",
            .keys = &.{ .{ .command = .@"term.shell", .label = "New shell" }, .{ .command = .@"term.scratch_toggle", .label = "Scratch terminal" } },
            .links = &.{ .{ .command = .{ .id = .@"term.shell", .label = "Open a shell" } }, .{ .command = .{ .id = .@"term.scratch_toggle", .label = "The scratch terminal" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.terminal_glyph"), .label = "Terminal icon" } } },
        },
        .split_right => .{
            .title = "Split right",
            .body = "Splits the active pane side by side and opens the same buffer in the new half, focused. Right-click is the split menu — split the other way, grow or shrink, equalize, close the active pane. Splits are per tab page and come back with the session.",
            .keys = &.{.{ .command = .@"view.split_right", .label = "Split right" }},
            .links = &.{ .{ .command = .{ .id = .@"view.split_right", .label = "Split right" } }, .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } } },
        },
        .split_down => .{
            .title = "Split down",
            .body = "Splits the active pane top and bottom and opens the same buffer in the new half, focused. Right-click is the split menu — split the other way, grow or shrink, equalize, close the active pane. A shell below the code is the usual reason; the terminal chip's own menu puts one there directly.",
            .keys = &.{ .{ .command = .@"view.split_down", .label = "Split down" }, .{ .command = .@"term.shell_bottom", .label = "A shell below" } },
            .links = &.{ .{ .command = .{ .id = .@"view.split_down", .label = "Split down" } }, .{ .command = .{ .id = .@"term.shell_bottom", .label = "A shell in the bottom half" } } },
        },
        .split_max => if (app.zen or app.zoomedPane() != null) .{
            .title = "Restore",
            .body = if (app.zen) "Full screen is on: the chrome — the rail, the columns, the bars — is hidden and the panes have the whole terminal. Click brings the frame back; so does Esc Esc, or the corner mark at the top right. Right-click lists the two maximize modes." else "This pane is zoomed: it has its leaf's whole area and the other splits are hidden, not closed. Click restores the splits; right-click lists the two maximize modes. The zoom is per tab page.",
            .keys = &.{ .{ .command = .@"view.fullscreen", .label = "Full screen" }, .{ .command = .@"view.toggle_zoom", .label = "Zoom the split" } },
            .links = if (app.zen) &.{ .{ .command = .{ .id = .@"view.fullscreen", .label = "Bring the frame back" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.maximize_click"), .label = "Maximize button in Settings" } } } else &.{ .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Bring the splits back" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.maximize_click"), .label = "Maximize button in Settings" } } },
        } else .{
            .title = try std.fmt.allocPrint(arena, "Maximize — {s}", .{zen.modeLabel(app.cfg.ui.maximize_click)}),
            .body = switch (app.cfg.ui.maximize_click) {
                .zoom_pane => "One button, two modes; `ui.maximize_click` picks which a left click runs, and here it is *Zoom the split*: the active pane takes its leaf's whole area and the other splits hide until you click again. Right-click lists both modes and runs the one you pick once, without re-pointing the button; Settings → UI re-points it. Full screen is the other mode — it hides the chrome as well.",
                .fullscreen => "One button, two modes; `ui.maximize_click` picks which a left click runs, and here it is *Full screen*: the rail, the columns and the bars hide and the panes take the whole terminal, Esc Esc or the corner mark to come back. Right-click lists both modes and runs the one you pick once, without re-pointing the button; Settings → UI re-points it. Zoom is the other mode — one pane over its splits, chrome kept.",
            },
            .keys = &.{ .{ .command = .@"view.toggle_zoom", .label = "Zoom the split" }, .{ .command = .@"view.fullscreen", .label = "Full screen" } },
            .links = switch (app.cfg.ui.maximize_click) {
                .zoom_pane => &.{ .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom the split" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.maximize_click"), .label = "Maximize button in Settings" } } },
                .fullscreen => &.{ .{ .command = .{ .id = .@"view.fullscreen", .label = "Full screen" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.maximize_click"), .label = "Maximize button in Settings" } } },
            },
        },
        .all_tabs => .{
            .title = "All tabs",
            .body = "The strip has more tabs than it can show at once, so it pages them: `‹ n/m ›` beside this chip turns the page. The `⋯` jumps instead — click opens the buffer picker, every tab by name with its path, on this page or another; type to filter, Enter shows the one you pick. Closing the tabs you are done with is the other cure.",
            .keys = &.{.{ .command = .@"picker.buffers", .label = "Buffer picker" }},
            .links = &.{ .{ .command = .{ .id = .@"picker.buffers", .label = "List every tab" } }, .{ .command = .{ .id = .@"buffer.close_others", .label = "Close the other tabs" } } },
        },
        .right_close => .{
            .title = "Close this right-column tab",
            .body = "The `×` on the right column's strip closes the pane on show there — the outline, diagnostics, a pane sent to the right — and shows the next one; with nothing left the column hides. A section moved to the right is not a tab and is closed from its rail menu instead.",
            .keys = &.{ .{ .command = .@"view.right_panel_close_tab", .label = "Close the tab" }, .{ .command = .@"view.toggle_right_panel", .label = "Hide the column" } },
            .links = &.{ .{ .command = .{ .id = .@"view.right_panel_close_tab", .label = "Close it" } }, .{ .command = .{ .id = .@"view.toggle_right_panel", .label = "Hide the column" } } },
        },
        .right_tab => .{
            .title = "Right column — the pane on show",
            .body = "The right column's strip names the pane it is showing; click focuses the column so the keys go to it. Right-click is the column's menu — next and previous tab, close, hide the column. F6 cycles focus through the columns and the panes from the keyboard.",
            .keys = &.{.{ .command = .@"focus.cycle", .label = "Cycle focus" }},
            .links = &.{ .{ .command = .{ .id = .@"view.focus_right_panel", .label = "Focus it" } }, .{ .command = .{ .id = .@"view.right_panel_next_tab", .label = "Next tab" } } },
        },
        .right_new => .{
            .title = "Add a panel to the right column",
            .body = "Click opens the Add panel menu: Outline, Problems, AI chat, Grep, Tests — each row runs its command, which opens that panel where it lives. A section on the left is moved over from its rail menu's *Move to right side* instead.",
            .keys = &.{.{ .command = .@"lsp.diagnostics", .label = "Diagnostics" }},
            .links = &.{ .{ .command = .{ .id = .@"outline.show", .label = "The outline" } }, .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Diagnostics" } } },
        },
        .fullscreen_exit => .{
            .title = "Exit full screen",
            .body = "Full screen keeps one cell of chrome: this mark at the body's top-right corner. Click brings the rail, the columns and the bars back; Esc Esc does the same, and so does the maximize chip once the frame is back. The panes keep their layout underneath.",
            .keys = &.{.{ .command = .@"view.fullscreen", .label = "Leave full screen" }},
            .links = &.{.{ .command = .{ .id = .@"view.fullscreen", .label = "Bring the frame back" } }},
        },
        .bottom_close => .{
            .title = "Hide the bottom panel",
            .body = "The `×` on the bottom panel's header hides the panel — the sections and panes hosted under the editor (`ui.bottom_panel_*`), not the launcher dock. Its rows are `ui.bottom_panel_height`; whether it opens at start is `ui.bottom_panel_visible`. `view.toggle_bottom_panel` brings it back.",
            .keys = &.{.{ .command = .@"view.toggle_bottom_panel", .label = "Toggle the bottom panel" }},
            .links = &.{ .{ .command = .{ .id = .@"view.toggle_bottom_panel", .label = "Toggle it" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.bottom_panel_height"), .label = "Bottom dock rows" } } },
        },
        .cmdline_bar => .{
            .title = "The command line",
            .body = "The row under the statusline is the `:` line: click it (or press the chord) and type an ex command — `:e path`, `:42`, `:set wrap`, `:!make` — with Tab completion and a history on the arrows. While HTTP work is in flight — a send, a bench, a chain, a sync — the row's right end shows a `⟳ … running…` indicator; an echoed toast's `[name]` here reveals the pane it names.",
            .keys = &.{.{ .command = .@"app.command_line", .label = "Open the : line" }},
            .links = &.{ .{ .command = .{ .id = .@"app.command_line", .label = "Open the command line" } }, .{ .command = .{ .id = .@"view.cmdline_history", .label = "Show the history" } } },
        },
        .cmdline_inflight => .{
            .title = "Work in flight",
            .body = "HTTP work is running — a send, a bench, an env fan-out, a sync, a chain — and the command-line row names it, with how long it has been going. Click aborts every in-flight send (`http.abort`). The indicator goes when the last of them finishes.",
            .links = &.{ .{ .command = .{ .id = .@"http.abort", .label = "Abort every send" } }, ask },
        },
        .cmdline_mention => .{
            .title = "The pane this message names",
            .body = "A toast echoed onto the command-line row named a pane in `[brackets]` — a terminal that finished, a session waiting on you. Click reveals that pane: its tab is shown and focused, in whatever split and page it lives on. The plain toast has the same text without the jump.",
            .links = &.{.{ .command = .{ .id = .@"messages.show", .label = "The message history" } }},
        },
        .sidebar_overlay => .{
            .title = "A side column, slid in",
            .body = "The column is set to `auto` and the pointer at its edge brought it out over the editor — painted over, so no pane moved. It slides back when the pointer leaves, unless the keyboard is in it. Click keeps the press from falling through to the editor; right-click lists the column's modes; the pin chip at its edge docks it for the session.",
            .keys = &.{ .{ .command = .@"view.sidebar_pin", .label = "Pin the column" }, .{ .command = .@"view.toggle_tree", .label = "Toggle the left column" } },
            .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Pin it for the session" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.sidebar"), .label = "Side columns in Settings" } } },
        },
        .sidebar_pin => .{
            .title = "Pin the column",
            .body = "The chip at the edge of a slid-in column. Click docks the column for the session — it stops sliding away and the frame is carved out for it as under `always`; click again to let it go. The pin, unlike the mode, is remembered in the session, so a pinned column is pinned again at the next start. The chip has no menu: a right press toggles the pin too.",
            .keys = &.{.{ .command = .@"view.sidebar_pin", .label = "Pin / unpin" }},
            .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Pin / unpin" } }, .{ .command = .{ .id = .@"view.sidebar_mode_always", .label = "Always show it" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.sidebar"), .label = "Side columns in Settings" } } },
        },
        .menu_bar_pin => .{
            .title = if (app.menu_bar.pinned) "Menu bar — pinned" else "Pin the menu bar",
            .body = "The chip past the menu bar's words, painted only while `ui.menu_bar` lets the bar hide. Click keeps the words up for this session so the bar stops sliding away; click again to let it go. Right-click has two rows: pin or unpin, and one that steps `ui.menu_bar` to its next mode. The pin is remembered in the session; the mode is the config's.",
            .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Pin / unpin" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } } },
        },
        .edge_grip_menu_bar => .{
            .title = "The menu bar hides here",
            .body = "The `⋯` in the middle of the run the menu words take marks the band that brings the menu bar back: rest the pointer on it and the words slide in over the top row. Click reveals AND pins the bar for the session — the same pin the chip past its words toggles — and right-click is that chip's menu: pin, and step to the next mode. `ui.edge_grips` turns all three grips off if you know the bands by heart.",
            .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Reveal and pin the bar" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.edge_grips"), .label = "Edge grips" } } },
        },
        .edge_grip_sidebar_left, .edge_grip_sidebar_right => .{
            .title = "The side column hides here",
            .body = "The `⋮` at the middle of this edge marks the band that slides the column in: rest the pointer on it and the column paints over the editor, going back when the pointer leaves. Click reveals AND pins it for the session — the pin chip at the column's edge lets it go — and right-click lists the column's modes. The grip is not painted while the column is pinned: there is nothing left to summon.",
            .keys = &.{ .{ .command = .@"view.sidebar_pin", .label = "Reveal and pin" }, .{ .command = .@"view.toggle_tree", .label = "Toggle the left column" } },
            .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Reveal and pin the column" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.sidebar"), .label = "Side columns in Settings" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.edge_grips"), .label = "Edge grips" } } },
        },
        .edge_grip_dock => .{
            .title = "The launcher dock hides here",
            .body = "The three dots at the middle of this edge mark the band that brings the launcher dock up: rest the pointer on it and the strip — integrations, terminals, launchers, pinned commands — comes up on this same row, over the editor's edge. Click reveals AND pins it for the session; right-click is the dock's menu — its mode, its edge, placement, labels, settings. A pinned dock shows no grip.",
            .links = &.{ .{ .command = .{ .id = .@"view.dock_pin", .label = "Reveal and pin the dock" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.mode"), .label = "Launcher dock in Settings" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.edge_grips"), .label = "Edge grips" } } },
        },
        .session_prev => .{
            .title = "Previous session",
            .body = "The `‹` of this session's `‹ 3/7 ›`: the session before it in the ring of every Claude Code and Codex pane — page by page, then left to right, tabs in strip order — on whichever tab page holds it, which comes on screen with the keys. Before the first it wraps to the last. `3/7` is this session's place and the count; a narrow strip drops the number first. In the sessions mode the strip counts its column's stack instead, and `‹` shows the session stacked before this one in the same column (Ctrl+Shift+Tab there). With one session there is nothing to step and the control is gone.",
            .keys = &.{ .{ .command = .@"ai.focus_prev_session", .label = "Previous session" }, .{ .command = .@"ai.focus_next_session", .label = "Next session" } },
            .links = &.{ .{ .command = .{ .id = .@"ai.focus_prev_session", .label = "Go back one" } }, .{ .command = .{ .id = .@"sessions.mode", .label = "Sessions side by side" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
        },
        .session_next => .{
            .title = "Next session",
            .body = "The `›` of this session's `‹ 3/7 ›`: the session after it in the ring of every Claude Code and Codex pane — page by page, then left to right, tabs in strip order — on whichever tab page holds it, which comes on screen with the keys. Past the last it wraps to the first. `3/7` is this session's place and the count; a narrow strip drops the number first. In the sessions mode the strip counts its column's stack instead, and `›` shows the session stacked after this one in the same column (Ctrl+Tab there). With one session there is nothing to step and the control is gone.",
            .keys = &.{ .{ .command = .@"ai.focus_next_session", .label = "Next session" }, .{ .command = .@"ai.focus_prev_session", .label = "Previous session" } },
            .links = &.{ .{ .command = .{ .id = .@"ai.focus_next_session", .label = "Go forward one" } }, .{ .command = .{ .id = .@"sessions.mode", .label = "Sessions side by side" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
        },
        else => null,
    };
}

fn menuWord(app: *App, arena: Allocator, m: menu_bar.Menu) Allocator.Error!Entry {
    _ = app;
    const accel = std.ascii.toUpper(m.accelerator());
    const body: []const u8 = switch (m) {
        .brand => "The wordmark opens the app's own menu: About, Settings, the data layout, check for updates, restart, quit. Alt+M opens it from the keyboard; ←→ walk the menus once one is open. The bar itself hides under `ui.menu_bar = auto` and comes back when the pointer rests on the top row.",
        .file => "New, open, recent, save, save all, close, the settings file, quit — the rows are the same commands the palette lists, with their chords beside them. Alt+F opens it; ←→ walk the menus once one is open. *Open recent file* is a submenu of the last ten.",
        .edit => "Undo and redo, the clipboard, select all, the line and comment edits, find and replace. Under the vim profile most of these have their vim spelling too; the chord beside each row is the active profile's.",
        .selection => "The selection commands: expand and shrink by syntax, add cursors above and below, select every occurrence of the word, the bracket match. Multi-cursor edits type in every cursor at once until Esc clears the extras.",
        .view => "What is on screen: the columns, the bottom panel, the menu bar and rail modes, wrap, line numbers, whitespace, the theme, full screen and zoom, the command palette. Most rows toggle a config key and say so in a toast; Settings → UI is the same set as rows.",
        .go => "Moving around: go to line, the jumplist back and forward, go to definition and references, the next and previous diagnostic and change, the symbol pickers. The language rows need a server running for the file.",
        .run => "The runners: the tests for this file or the workspace, the task, the debugger — run, continue, step — and the per-toolchain rows (cargo, npm, go, dotnet, pytest) that appear when the workspace has that toolchain's manifest.",
        .terminal => "Shells: a new one beside, or in a named half; the scratch terminal; rename, restart and clear the active one; the tools (htop, lazygit, gh…) as terminal panes. A shell opens in the workspace directory with mnml's environment.",
        .window => "Splits and tab pages: split right and down, focus by direction, equalize, rotate, zoom, close the split; new tab page, next, previous, close. The layout rows act on the active pane's leaf.",
        .help => "The cheatsheet (every chord → command), the keymap reference, the click-discovery panel that outlines every click target, the commands reference, About. F1 is the keymap reference.",
    };
    return .{
        .title = try std.fmt.allocPrint(arena, "{s} menu", .{m.title()}),
        .body = body,
        .keys = &.{ .{ .chord = "→ / ←", .label = "The next / previous menu" }, .{ .chord = "Esc", .label = "Close" } },
        .aside = if (accel != 0) try std.fmt.allocPrint(arena, "Alt+{c} opens it from the keyboard.", .{accel}) else null,
        .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_open", .label = "Open a menu by key" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.menu_bar"), .label = "Menu bar in Settings" } } },
    };
}

fn tabPage(app: *App, arena: Allocator, page: usize) Allocator.Error!Entry {
    const n = app.layouts.layouts.items.len;
    const active = page == app.layouts.active;
    return .{
        .title = try std.fmt.allocPrint(arena, "Tab page {d} of {d}{s}", .{ page + 1, n, if (active) " — active" else "" }),
        .body = if (active) "This is the page on screen: its splits and tabs are what you see. Click on the other chips switches page; right-click on any chip is the page menu — close, close the others, a new page, move left or right, the page picker. Alt+1..9 switch by number." else "Another layout — its own splits and tabs, kept as you left them. Click switches to it; right-click is the page menu — rename, close, close the others, move. Alt+1..9 switch by number, and the session restores every page.",
        .links = &.{ .{ .command = .{ .id = .@"tab.picker", .label = "Pick a page" } }, .{ .command = .{ .id = .@"tab.new", .label = "New page" } } },
    };
}

fn aiLauncher(app: *App, product: enum { claude, codex }) Allocator.Error!Entry {
    return switch (product) {
        .claude => .{
            .title = "Claude Code chip",
            .body = if (ai_app.findSession(app, .claude) != null) "A Claude Code session is running. Click shows the SESSIONS section, where its card is; the session's own tab is in the editor area. Right-click is the launcher menu — toggle the existing pane, a new session in a named half, the grid-or-tabs layout for several sessions, and the *Icon* submenu: whether the chip and the session tabs wear the Claude figure or the Anthropic spark (`ui.claude_mark`)." else "No Claude Code session is running. Click shows the SESSIONS section and starts one in the workspace — the `claude` CLI in a terminal pane, on the account it is signed in as. Right-click is the launcher menu — a new session in a named half, the grid-or-tabs layout for several, and the *Icon* submenu: the Claude figure or the Anthropic spark (`ui.claude_mark`).",
            .links = &.{ .{ .command = .{ .id = .@"ai.claude_code_new", .label = "New Claude session" } }, .{ .command = .{ .id = .@"ai.claude_usage", .label = "Usage" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.claude_mark"), .label = "Claude icon in Settings" } } },
        },
        .codex => .{
            .title = "Codex chip",
            .body = if (ai_app.findSession(app, .codex) != null) "A Codex session is running. Click shows the SESSIONS section, where its card is; the session's tab is in the editor area. Right-click is the launcher menu — toggle the existing pane, a new session in a named half, the grid-or-tabs layout for several sessions, and the glyph rows." else "No Codex session is running. Click shows the SESSIONS section and starts one — the `codex` CLI in a terminal pane, in the workspace. Right-click is the launcher menu — a new session in a named half, the grid-or-tabs layout for several, and the glyph rows. `ui.tab_bar_ai_icon` picks which AI chips the bar shows.",
            .links = &.{ .{ .command = .{ .id = .@"ai.codex_new", .label = "New Codex session" } }, .{ .command = .{ .id = .@"ai.codex_usage", .label = "Usage" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.tab_bar_ai_icon"), .label = "AI icons in the bar" } } },
        },
    };
}

// ─── tabs, breadcrumbs, dividers, scrollbars, popups ────────────────────

pub fn tab(app: *App, arena: Allocator, tb: hit.TabRef) Allocator.Error!?Entry {
    const layout = app.layouts.current();
    const lid = (try layout.leafAt(arena, tb.leaf)) orelse return null;
    const leaf = layout.leaf(lid) orelse return null;
    if (tb.idx >= leaf.tabs.items.len) return null;
    const id = leaf.tabs.items[tb.idx];
    const p = app.panes.get(id) orelse return null;
    const dirty = p.dirty();
    return switch (p.*) {
        .pty => |*pt| blk: {
            const claude = if (@import("../launch_profiles.zig").productOfPane(app, pt)) |prod| prod == .claude else false;
            // The raised hand: this tab's child is blocked on the user.
            if (sessions.needsYou(app, id)) break :blk .{
                .title = try std.fmt.allocPrint(arena, "Tab: {s} — needs you", .{p.title()}),
                .body = "The raised hand after the name: the program in this pane is stopped on a question — a permission prompt, a `(y/n)`, a numbered choice — or its session's transcript says it is waiting. It stays up until the screen stops asking. Click shows it so you can answer; the jump keys walk every tab wearing it, the SESSIONS card wears the same mark, and the Waiting sort puts every such session first.",
                .keys = &.{ .{ .command = .@"sessions.next_waiting", .label = "Next ready for you" }, .{ .command = .@"sessions.prev_waiting", .label = "Previous ready for you" } },
                .links = &.{ .{ .command = .{ .id = .@"sessions.sort_waiting", .label = "Sort SESSIONS waiting first" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The SESSIONS section" } } },
            };
            // The link mark: the session has mnml as its IDE (`ide.zig`).
            if (@import("../ide.zig").linked(app, id)) break :blk .{
                .title = try std.fmt.allocPrint(arena, "Tab: {s} — linked to mnml", .{p.title()}),
                .body = "The `⇄` after the name: this Claude Code session is linked to mnml as its IDE. It hears your selection as you make it, opens files, reads diagnostics, and shows its edits in the review pane for you to accept or reject; an accepted edit lands in the buffer unsaved. A save it asks for waits on you. Made when the session started; it goes when the pane closes or the API is turned off.",
                .keys = &.{.{ .command = .@"ai.send_selection", .label = "Point it at the selection" }},
                .links = &.{.{ .command = .{ .id = .@"view.activity_sessions", .label = "The SESSIONS section" } }},
            };
            break :blk .{
                .title = try std.fmt.allocPrint(arena, "Tab: {s} — {s}", .{ p.title(), if (claude) "a Claude Code session" else "a terminal" }),
                .body = if (claude) "A Claude Code session in a terminal pane, driven by libghostty-vt; its card in SESSIONS shows the branch, cwd and what it is doing, and the colour on its rail matches. Click shows it; middle-click closes it (which ends the session — the transcript stays on disk); drag reorders. Right-click has Rename, Restart, Clear, the accent colour and the *Icon* submenu for the mark it wears." else "A shell in a terminal pane, driven by libghostty-vt so it renders as ghostty would — in the workspace directory, with mnml's environment. Click shows it; middle-click closes it, which ends the shell; drag reorders. Right-click has Rename, Restart, Clear, the accent colour and the *Icon* submenu — the ghost or the plain terminal mark for every terminal tab.",
                .keys = &.{.{ .command = .@"buffer.close", .label = "Close" }},
                .links = if (claude) &.{ .{ .command = .{ .id = .@"term.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"ai.claude_code_new", .label = "Another Claude session" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.claude_mark"), .label = "Claude icon in Settings" } } } else &.{ .{ .command = .{ .id = .@"term.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"term.shell", .label = "Another shell" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.terminal_glyph"), .label = "Terminal icon in Settings" } } },
            };
        },
        else => .{
            .title = try std.fmt.allocPrint(arena, "Tab: {s}{s}", .{ p.title(), if (dirty) " — unsaved" else "" }),
            .body = if (dirty) "One tab per open pane; the ● means this buffer has edits not on disk, and closing it will ask. Click shows it; middle-click closes it; drag moves it along the strip or into another split. Right-click has Save, the close rows, pin, split, reveal in the tree, copy the path. A preview tab (`ui.preview_tabs`, italic) is replaced by the next single-click open until you edit it." else "One tab per open pane. Click shows it; middle-click closes it; drag moves it along the strip or into another split. Right-click has the close rows, pin (a pinned tab stays at the front), split right and down, reveal in the tree, copy the path. A preview tab (`ui.preview_tabs`, italic) is replaced by the next single-click open until you edit or pin it.",
            .keys = &.{ .{ .command = .@"buffer.close", .label = "Close" }, .{ .command = .@"buffer.next", .label = "Next tab" } },
            .links = &.{ .{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Pin / unpin it" } }, .{ .command = .{ .id = .@"view.reveal_in_tree", .label = "Reveal in the tree" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.preview_tabs"), .label = "Preview tabs" } } },
        },
    };
}

pub fn tabClose() Entry {
    return .{
        .title = "Close tab",
        .body = "The badge at the tab's right edge: a `×`, or the diagnostics count when `ui.bufferline_diag_style` puts it there, or the ● of unsaved edits. Click closes the pane — a dirty buffer asks first; a terminal's shell ends. Middle-click anywhere on the tab does the same, and the last closed one can be reopened.",
        .keys = &.{ .{ .command = .@"buffer.close", .label = "Close" }, .{ .command = .@"buffer.reopen", .label = "Reopen the last closed" } },
        .links = &.{ .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen the last closed" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.bufferline_diag_style"), .label = "Diag chip on tabs" } } },
    };
}

pub fn breadcrumb(app: *App, arena: Allocator, pane_id: PaneId, idx: u16) Allocator.Error!?Entry {
    const e = app.panes.editor(pane_id) orelse return null;
    const path = e.buf.doc.path orelse return null;
    const names = try render.breadcrumbNames(app, arena, path);
    if (idx >= names.len) return null;
    return .{
        .title = try std.fmt.allocPrint(arena, "Breadcrumb: {s}", .{names[idx]}),
        .body = "The row over the editor spells the file's path from the workspace root, one segment per folder and the file's name last. Click a segment to open a Files pane at that folder (the file's own segment opens its parent); right-click offers the folder's rows. `editor.breadcrumb` in Settings hides the row.",
        .links = &.{ .{ .command = .{ .id = .@"view.reveal_in_tree", .label = "Reveal in the tree" } }, .{ .settings = .{ .row = comptime copy.settingsRow("editor.breadcrumb"), .label = "Breadcrumb in Settings" } } },
    };
}

pub fn divider(id: u32) Entry {
    if (id == @import("../render.zig").info_divider_id) return .{
        .title = "Info panel's top edge",
        .body = "Drag it up or down to give this box more rows or fewer — the height is written to your home config (`ui.hover_help_height`), as the Settings row writes it. The box keeps at least four rows and leaves the section above it six. Double-click puts back the default eight.",
        .keys = &.{ .{ .chord = "Drag", .label = "Resize" }, .{ .chord = "Double-click", .label = "Default height" } },
        .links = &.{.{ .settings = .{ .row = comptime copy.settingsRow("ui.hover_help_height"), .label = "Hover help rows" } }},
    };
    if (id == @import("../render.zig").tree_divider_id) return .{
        .title = "Sidebar divider",
        .body = "The edge between the left column and the editor. Drag it to resize; the dragged width holds through a window resize and comes back with the session. Out of the box the column is a fifth of the window — 30 cells up to 150 columns wide, growing to 48 — unless `ui.tree_width` names a number. Right-click for the width, hiding the column, and the side it lives on.",
        .keys = &.{ .{ .chord = "Drag", .label = "Resize" }, .{ .chord = "Right-click", .label = "Width, hide, side" } },
        .links = &.{ .{ .command = .{ .id = .@"view.reset_tree_width", .label = "Reset the width" } }, .{ .command = .{ .id = .@"view.set_tree_width", .label = "Set a width" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.tree_width"), .label = "Tree width" } } },
    };
    return .{
        .title = "Divider",
        .body = "The line between two panes, or between a column and the editor area. Drag it to resize; the column widths are per workspace (`ui.tree_width`, `ui.right_panel_width`) and the split ratios live in the session. The keyboard resizes too: the Window menu grows a split's width or height, and equalizes every split at once.",
        .keys = &.{.{ .chord = "Drag", .label = "Resize" }},
        .links = &.{ .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize the splits" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.tree_width"), .label = "Tree width" } } },
    };
}

pub fn scrollbar(s: anytype) Entry {
    return .{
        .title = switch (s.owner) {
            .tree => "The tree's scrollbar",
            .panel => "A section's scrollbar",
            .welcome => "A start-surface list's scrollbar",
            .pane => if (s.axis == .h) "The pane's horizontal scrollbar" else "The pane's scrollbar",
        },
        .body = "The thumb is where you are in the content and how much of it shows. Drag it, click the track to jump, or use the wheel over the content — `ui.wheel_lines` is how many lines a notch moves. `ui.scrollbar` turns the bars off for people who navigate by keyboard; the wheel still works.",
        .keys = &.{ .{ .chord = "Drag", .label = "Scroll" }, .{ .chord = "Wheel", .label = "Scroll by lines" } },
        .links = &.{ .{ .settings = .{ .row = comptime copy.settingsRow("ui.scrollbar"), .label = "Scrollbar in Settings" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.wheel_lines"), .label = "Lines per wheel notch" } } },
    };
}

pub fn hoverPopup() Entry {
    return .{
        .title = "LSP hover",
        .body = "The language server's word on the symbol under the cursor — its type, its doc comment, or the signature help while you type a call. The wheel scrolls it two lines at a time; a click, Esc or any movement puts it away. Empty or slow for a file the server has not indexed yet.",
        .keys = &.{ .{ .command = .@"lsp.hover", .label = "Hover" }, .{ .command = .@"lsp.signature_help", .label = "Signature help" }, .{ .command = .@"lsp.goto_definition", .label = "Go to definition" } },
        .links = &.{ .{ .command = .{ .id = .@"lsp.goto_definition", .label = "Go to the definition" } }, .{ .command = .{ .id = .@"lsp.references", .label = "Find references" } }, ask },
    };
}

// ─── the surface line of a pane ─────────────────────────────────────────

/// A pane's body under the pointer: the kind's surface line.
pub fn pane(app: *App, arena: Allocator, id: PaneId) Allocator.Error!?Entry {
    const p = app.panes.get(id) orelse return null;
    var e = paneKind(std.meta.activeTag(p.*));
    e.title = try std.fmt.allocPrint(arena, "{s} — {s}", .{ p.title(), e.title });
    return e;
}

/// The surface line per pane kind — what the pane is and how it is
/// driven; `pane` prefixes the pane's own title.
pub fn paneKind(kind: std.meta.Tag(app_mod.Pane)) Entry {
    return switch (kind) {
        .editor => .{
            .title = "editor",
            .body = "A text buffer. Click places the cursor, drag selects, the wheel scrolls; right-click is the editor menu — the clipboard, go to definition and references, rename, the AI rows, save. The colour stripe down the left edge is the pane rail: it says which pane this is, and a Claude session's card wears the same colour. Ctrl+S saves; the file chip in the statusline shows ● while it is dirty.",
            .keys = &.{ .{ .command = .@"file.save", .label = "Save" }, .{ .command = .palette, .label = "Command palette" }, .{ .command = .@"lsp.code_action", .label = "Code actions" } },
            .links = &.{ .{ .command = .{ .id = .@"lsp.code_action", .label = "Code actions" } }, .{ .command = .{ .id = .@"ai.explain", .label = "Explain the selection" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.pane_rail"), .label = "Pane colour rail" } } },
        },
        .pty => .{
            .title = "terminal",
            .body = "A shell, or a program started as one, in a libghostty-vt terminal: keys go straight to it while it is focused, except the Ctrl and Alt chords mnml binds — Ctrl+C, D, Z and L always reach the program. Click focuses and places nothing; the wheel scrolls its history; right-click is the pane menu — rename, restart, clear, paste, the accent colour. Closing the tab ends the child.",
            .keys = &.{.{ .command = .@"focus.cycle", .label = "Cycle focus out" }},
            .links = &.{ .{ .command = .{ .id = .@"term.restart", .label = "Restart the shell" } }, .{ .command = .{ .id = .@"term.rename", .label = "Rename" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.pty_cursor.blink"), .label = "Terminal cursor blinks" } } },
        },
        .ai => .{
            .title = "AI pane",
            .body = "A Claude job's transcript — the question at the top, the answer streaming under it, and for an action (explain, fix, refactor) an Apply row that puts the result into the buffer it came from. Type at the bottom prompt to continue; right-click is the pane menu — re-ask, cancel, promote to an interactive session, apply. The pane is the API or CLI route `ai.routing` picks, not a session tab.",
            .links = &.{ .{ .command = .{ .id = .@"ai.reask", .label = "Ask again" } }, .{ .command = .{ .id = .@"ai.apply", .label = "Apply the result" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ai.routing.claude.backend"), .label = "Claude backend" } } },
        },
        .request => .{
            .title = "HTTP request",
            .body = "A request being edited: method, URL, headers and body in fields, with `{{VAR}}` references resolved from the picked env at send time. Ctrl+Enter sends and the response fills the pane's Response half; Enter on a field starts editing it; Ctrl+S saves it into a collection. Right-click on a field is its own menu — send, paste or copy curl, cycle the method, format the body, insert a header, save.",
            .links = &.{ .{ .command = .{ .id = .@"http.send", .label = "Send the request" } }, .{ .command = .{ .id = .@"http.pick_env", .label = "Pick an env" } }, .{ .command = .{ .id = .@"http.ai_debug", .label = "Debug it with AI" } } },
        },
        .md_preview => .{
            .title = "markdown preview",
            .body = "The rendered view of a markdown file — headings, lists, code, images where the terminal can draw them. Links open on click; the header chip swaps the raw editor in. The preview reads the editor's text as you type, so an edit shows on the next frame. `ui.render_markdown` is the inline renderer inside the editor, a different thing.",
            .links = &.{ .{ .command = .{ .id = .@"markdown.edit_raw", .label = "Edit the source" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.md_image_rows"), .label = "Markdown image rows" } } },
        },
        .zon => .{
            .title = "ZON tree",
            .body = "A `.zon` file as a tree of fields: Enter edits the focused value, `←→` step an enum or a bool, `/` filters by path, `e` opens the text. For config.zon each row's doc line is docs/CONFIG.md's comment for that key. The tree writes the file on change; the text tab picks the change up.",
            .keys = &.{ .{ .chord = "Enter", .label = "Edit the value" }, .{ .chord = "←→", .label = "Step an enum" } },
            .links = &.{ .{ .command = .{ .id = .@"zon.source", .label = "Show the source" } }, .{ .command = .{ .id = .@"view.settings", .label = "The Settings overlay" } } },
        },
        .git_graph => .{
            .title = "commit graph",
            .body = "The repo's history as a graph, in git mode: arrows walk commits, Enter opens the detail, the filters narrow by branch, author, date or subject. Right-click on a commit is its menu — details, diff, cherry-pick, revert, the rebase rows, reset, checkout, a branch or worktree from here. The graph is the active repo's; the repo pill in the palette switches it.",
            .links = &.{ .{ .command = .{ .id = .@"git.graph_filter_branch", .label = "Filter by branch" } }, .{ .command = .{ .id = .@"git.graph_filter_reset_all", .label = "Clear the filters" } }, ask },
        },
        .git_status => .{
            .title = "git status",
            .body = "The working tree's changes, unstaged above staged: Enter opens the diff, `s` / `u` stage and unstage a file, `-` toggles it (Space too under standard), `a` stages all, `c` commits. Right-click on a row is the file's git menu. Conflicted files lead in a section of their own, and Enter opens the editor on one rather than a diff. A submodule reads `sub/  (submodule, modified)`: its changes are committed inside it, so Enter opens it in the file tree rather than a diff.",
            .keys = &.{.{ .command = .@"git.commit", .label = "Commit" }},
            .links = &.{ .{ .command = .{ .id = .@"git.commit", .label = "Commit" } }, .{ .command = .{ .id = .@"git.ai_commit", .label = "Write the message with AI" } }, ask },
        },
        .session_changes => .{
            .title = "what this session changed",
            .body = "The files one Claude or Codex session changed since it started: dirty now and not at the start, written after it (`ui.session_changes`), or in a commit since its HEAD — Unstaged and Staged are what is still uncommitted, Committed since start what it already committed. Enter opens the file's diff, `s` / `u` / space stage and unstage, `c` or the Commit… row commits with the session's title as the message. A name in orange after a path is another session that touched the same file.",
            .keys = &.{ .{ .chord = "Enter", .label = "Open the diff" }, .{ .chord = "s", .label = "Stage the file" }, .{ .chord = "c", .label = "Commit with the session's title" }, .{ .chord = "r", .label = "Read git again" } },
            .links = &.{ .{ .command = .{ .id = .@"sessions.refresh", .label = "Refresh the sessions" } }, .{ .command = .{ .id = .@"git.status_pane", .label = "The whole repo's status" } }, ask },
        },
        .diff => .{
            .title = "diff",
            .body = "A diff — a file against the index or a base, as hunks, inline or split (`git.diff_toggle_view` cycles the three). Select lines and stage, unstage, discard or stash just those; Enter on a hunk opens the file at that line. `]c` / `[c` step hunks and `]f` / `[f` files, in both profiles. Conflict hunks have their own rows — ours, theirs, both.",
            .keys = &.{.{ .command = .@"git.diff_next_file", .label = "Next file" }},
            .links = &.{ .{ .command = .{ .id = .@"git.diff_toggle_view", .label = "Cycle hunk / inline / split" } }, .{ .command = .{ .id = .@"ai.explain_diff", .label = "Explain the diff" } }, ask },
        },
        .grep => .{
            .title = "search results",
            .body = "A workspace search's hits grouped by file, from ripgrep: Enter jumps to the line, Space toggles a hit for the replace, the folds collapse a file. Right-click on a hit is its menu — open, skip or include it on replace, copy `path:line` and the text. The query and its flags are on the SEARCH section's header.",
            .links = &.{ .{ .command = .{ .id = .@"grep.refresh", .label = "Rerun the search" } }, .{ .command = .{ .id = .@"find.grep_replace", .label = "Replace across the hits" } } },
        },
        .debug => .{
            .title = "debugger",
            .body = "The debug session's console: the adapter's output, evaluate at the prompt, the stop reason when a breakpoint hits. The variables, watches, call stack and breakpoints are in the Debug column; the toolbar row above the editor (`ui.debug_toolbar`) has continue, step over, into, out, stop.",
            .keys = &.{ .{ .command = .@"dap.continue", .label = "Continue" }, .{ .command = .@"dap.next", .label = "Step over" }, .{ .command = .@"dap.terminate", .label = "Stop" } },
            .links = &.{ .{ .command = .{ .id = .@"dap.continue", .label = "Continue" } }, .{ .command = .{ .id = .@"dap.repl", .label = "The REPL" } }, ask },
        },
        .sessions_table => .{
            .title = "sessions table",
            .body = "Every Claude Code and Codex session across your workspaces, as a table — state, workspace, branch, age — with a filter, multi-select and the batch verbs (kill, resume in a pane, open the transcript). Enter opens a session's pane; right-click on a row is its menu. The SESSIONS section is this workspace's slice of the same list.",
            .links = &.{ .{ .command = .{ .id = .@"sessions.refresh", .label = "Refresh" } }, .{ .command = .{ .id = .@"sessions.all_workspaces", .label = "Every workspace" } } },
        },
        .integrations => .{
            .title = "integrations",
            .body = "The Installed tab lists what is on this machine with its state; the Marketplace tab what can be installed; Dev the ones built from a checkout. Enter opens an integration or installs it; right-click is its menu — configure, disable, pin, uninstall. An integration's manifest is the source of its chips, segments and settings.",
            .links = &.{ .{ .command = .{ .id = .@"integrations.show_marketplace", .label = "The marketplace" } }, .{ .command = .{ .id = .@"integrations.diag", .label = "Diagnostics" } } },
        },
        .files => .{
            .title = "Files pane",
            .body = "A folder as a list — a file manager rather than the tree: ← or Backspace goes up (`h` too), Enter opens or enters, Space marks, the marked files copy or move to a destination, Delete trashes them. The sort and hidden-files toggles are on its header. Transfers run on a worker and report in the statusline's transfer chip.",
            .links = &.{ .{ .command = .{ .id = .@"files.toggle_hidden", .label = "Show hidden files" } }, .{ .command = .{ .id = .@"files.restore_from_trash", .label = "Restore from the trash" } } },
        },
        .tests => .{
            .title = "test results",
            .body = "The last test run — each test with pass / fail and, opened, its output; Enter jumps to the failing line. The runner is the workspace's — playwright, dotnet, zig, vitest or pytest. Rerun-failed reruns only the red ones; the statusline's test chip carries the tally.",
            .links = &.{ .{ .command = .{ .id = .@"test.rerun_failed", .label = "Rerun the failures" } }, .{ .command = .{ .id = .@"test.heal", .label = "Heal a failing test" } }, ask },
        },
        .browser => .{
            .title = "browser",
            .body = "A Chrome page driven over CDP: navigate, back and forward, a screenshot or a DOM snapshot into a pane, the network log captured into the HTTP panel's CAPTURED section. Headless or headed is `browser.headless`; the profile is `browser.profile_mode`. Devtools opens Chrome's own.",
            .links = &.{ .{ .command = .{ .id = .@"browser.navigate", .label = "Go to a URL" } }, .{ .command = .{ .id = .@"http.capture_start", .label = "Capture the network" } }, .{ .settings = .{ .row = comptime copy.settingsRow("browser.headless"), .label = "Headless browser" } } },
        },
        .outline => .{
            .title = "outline",
            .body = "The active file's symbols as a tree from its language server; Enter jumps, the cursor's own symbol is followed. Empty until a server has the file. It lives in the right column.",
            .keys = &.{.{ .command = .@"lsp.symbols", .label = "Symbol picker" }},
            .links = &.{.{ .command = .{ .id = .@"lsp.symbols", .label = "Pick a symbol" } }},
        },
        .cheatsheet => .{
            .title = "cheatsheet",
            .body = "Every chord in the active profile with the command it runs, grouped by area — the reference for the keymap you have, rebinds included. `/` filters; Enter runs the row. The keymap reference (F1) is the same list as an overlay.",
            .keys = &.{ .{ .command = .@"view.cheatsheet", .label = "Open it" }, .{ .command = .@"view.help", .label = "The keymap reference" } },
            .links = &.{ .{ .command = .{ .id = .@"keys.edit", .label = "Customize the keys" } }, .{ .command = .{ .id = .@"keys.doctor", .label = "Keymap doctor" } } },
        },
        .list => .{
            .title = "list",
            .body = "A list pane — rows with a filter, a sort chip and per-row kebabs, the same widget the sections use, hosted as a tab. Enter acts on the row, right-click is its menu, `/` focuses the filter.",
            .keys = &.{ .{ .chord = "Enter", .label = "Open the row" }, .{ .chord = "/", .label = "Filter" } },
        },
        .image => .{
            .title = "image",
            .body = "A raster image drawn with the terminal's own image protocol (kitty or sixel) where it has one; elsewhere the pane names the file and its size. The wheel pans a large one. `ui.md_image_rows` is the height images take inside a markdown preview.",
            .links = &.{.{ .settings = .{ .row = comptime copy.settingsRow("ui.md_image_rows"), .label = "Markdown image rows" } }},
        },
        .spend_report, .ai_usage => .{
            .title = "AI usage",
            .body = "The Claude and Codex usage for the linked accounts — the five-hour and weekly windows, the tokens today, spend where the API route is on. Refresh asks the account's endpoint again; the statusline chips are the compact form of the same figures.",
            .links = &.{ .{ .command = .{ .id = .@"ai.refresh_usage", .label = "Refresh the figures" } }, .{ .command = .{ .id = .@"ai.link_claude_token", .label = "Link an account" } } },
        },
        .websocket => .{
            .title = "websocket",
            .body = "A WebSocket connection: the messages sent and received in order, a prompt to send another. Connect and disconnect from the header; the history stays after a disconnect so the exchange can be read back.",
            .links = &.{.{ .command = .{ .id = .@"ws.connect", .label = "Connect" } }},
        },
        .script => .{
            .title = "script pane",
            .body = "A pane a Lua script owns: its rows and keys are the script's, from `mnml.pane{}`. A reload of the script rebuilds it. Errors in the script's handlers land in the Scripts section rather than here.",
            .links = &.{.{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } }},
        },
        .mount => .{
            .title = "integration pane",
            .body = "An integration's own pane, mounted over the bridge: what it draws and what its keys do are the integration's, and its right-click menu is the rows it declared. A disconnected integration leaves the pane saying so; reopening it from the Integrations section reconnects.",
            .keys = &.{.{ .command = .@"view.activity_integrations", .label = "Integrations" }},
            .links = &.{ .{ .command = .{ .id = .@"mounts.refresh", .label = "Refresh the mounts" } }, .{ .command = .{ .id = .@"integrations.diag", .label = "Integration diagnostics" } } },
        },
        .ai_apply => .{
            .title = "AI apply",
            .body = "A proposed change — an AI action's answer, or a Claude Code session's edit — against the buffer as it stands, in the git diff pane's Hunk / Inline / Split views (`t` cycles them). Space accepts or skips the focused hunk, Enter applies the accepted ones as one undo step, `Y` or Accept all takes every hunk; nothing is written until then. Esc rejects and leaves the buffer as it was.",
            .links = &.{ .{ .command = .{ .id = .@"ai.apply_accept_all", .label = "Accept all and apply" } }, .{ .command = .{ .id = .@"git.diff_toggle_view", .label = "Cycle hunk / inline / split" } }, .{ .command = .{ .id = .@"ai.reask", .label = "Ask again" } } },
        },
        .flaky => .{
            .title = "flaky tests",
            .body = "Tests that have both passed and failed across recent runs, with the ratio — the ones worth a second look before trusting a green run. Enter opens the test; the tests pane's runs feed it.",
            .links = &.{.{ .command = .{ .id = .@"test.rerun_failed", .label = "Rerun the failures" } }},
        },
        .requests => .{
            .title = "request log",
            .body = "Every HTTP send in order — method, URL, status, time — with the response opened on Enter and a replay from its row. The RECENT section in the HTTP panel is the short form; this is the whole log from `.rqst/history.jsonl`.",
            .links = &.{ .{ .command = .{ .id = .@"http.history_global", .label = "Every workspace's history" } }, .{ .command = .{ .id = .@"http.clear_recent", .label = "Clear the history" } } },
        },
    };
}

/// For the AI: which button, and what its click runs.
pub fn askContext(app: *App, arena: Allocator, id: u32) Allocator.Error!?[]const u8 {
    if (menu_bar.buttonOf(id)) |m| return try std.fmt.allocPrint(arena, "- the menu bar's {s} menu\n", .{m.title()});
    if (id >= @intFromEnum(Button.new_tab_base)) return null;
    return switch (@as(Button, @enumFromInt(id))) {
        .split_max => try std.fmt.allocPrint(arena, "- the maximize button; ui.maximize_click = {s}; full screen on: {}; a pane zoomed: {}\n", .{ @tagName(app.cfg.ui.maximize_click), app.zen, app.zoomedPane() != null }),
        .theme_toggle => try std.fmt.allocPrint(arena, "- theme: {s}\n", .{app.theme.name}),
        else => null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every named button, every menu word and every pane kind has an entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    inline for (comptime std.enums.values(Button)) |b| {
        const id = @intFromEnum(b);
        if (id < @intFromEnum(Button.tab_page_base)) {
            const e = (try button(&app, a, id)) orelse {
                std.debug.print("no entry for button {s}\n", .{@tagName(b)});
                return error.MissingEntry;
            };
            try t.expect(e.body.len >= 40);
        }
    }
    try t.expect((try button(&app, a, Button.tabPage(0))) != null);
    try t.expect((try button(&app, a, Button.tabPageClose(0))) != null);
    try t.expect((try button(&app, a, Button.tabScroll(0, .left))) != null);
    try t.expect((try button(&app, a, Button.newTab(0))) != null);
    try t.expect((try button(&app, a, menu_bar.overflow_button)) != null);
    try t.expect((try button(&app, a, toast_mod.undo_button)) != null);
    try t.expect((try button(&app, a, toast_mod.button_base)) != null);
    try t.expect((try button(&app, a, md_preview.button_edit)) != null);
    try t.expect((try button(&app, a, zon_pane.button_view)) != null);
    inline for (comptime std.enums.values(menu_bar.Menu)) |m| try t.expect((try button(&app, a, menu_bar.button_base + @intFromEnum(m))) != null);
    inline for (comptime std.enums.values(std.meta.Tag(app_mod.Pane))) |k| try t.expect(paneKind(k).body.len >= 40);
    // The maximize button names the mode a click runs, and the way
    // back while something is maximized.
    try t.expectEqualStrings("Maximize — Zoom the split", (try button(&app, a, @intFromEnum(Button.split_max))).?.title);
    app.zen = true;
    try t.expectEqualStrings("Restore", (try button(&app, a, @intFromEnum(Button.split_max))).?.title);
}
