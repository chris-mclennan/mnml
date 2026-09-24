//! Hover help for the curated `+` menu (`context_menus.openNewTabMenu`,
//! titled `Create…`): the `New ▸` / `Open ▸` / `AI ▸` / `Dock ▸` groups
//! and their leaves, the `Reopen last closed (N)` row that leads while
//! there is something to reopen, the curation list a row's kebab opens
//! (pin, hide, copy id), and the Integrations group — a family, one
//! row per enabled integration, named.

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
    // ── the groups ──
    .{ .menu = "Create…", .label = "New", .entry = group("New", "the things made from nothing: a scratch buffer, one filled from the clipboard, a blank HTTP request, a shell, a browser tab, a tab page", .@"scratch.new", "A scratch buffer", .@"term.shell", "A shell") },
    .{ .menu = "Create…", .label = "Open", .entry = group("Open", "the ways to something that exists: the fuzzy file picker, the recent files, a file browser pane, the two-pane commander layout, the workspace trash", .@"picker.files", "The file picker", .@"files.open", "A file browser") },
    .{ .menu = "Create…", .label = "AI", .entry = group("AI", "the agents: a new Claude Code session, one in a git worktree of its own, a new Codex session — each a CLI in a terminal pane with a card in the SESSIONS section", .@"ai.claude_code_new", "A Claude Code session", .@"view.activity_sessions", "The sessions section") },
    .{ .menu = "Create…", .label = "Dock", .entry = group("Dock", "the two dock WIDGETS — the small panels pinned to a corner of the editor area, not the launcher dock along its edge: a note with your own text, and a tail of a log file", .@"dock.new_text", "A note widget", .@"dock.new_log_tail", "A log tail") },
    .{ .menu = "Create…", .label = "Integrations", .entry = .{
        .title = "Integrations ▸",
        .body = "Opens one row per enabled integration whose chip runs a command — Jira, Bitbucket, the browser, whatever is installed — each with its chip's own glyph; the group is built as the menu opens, so an integration disabled in the INTEGRATIONS section leaves it, and with none enabled the group is not here at all. → or a click opens it beside this row.",
        .keys = &.{.{ .chord = "→ / ←", .label = "Open / close the group" }},
        .links = &.{ .{ .command = .{ .id = .@"view.activity_integrations", .label = "The integrations section" } }, .{ .command = .{ .id = .@"integrations.show_marketplace", .label = "The marketplace" } }, copy.docsSection("Launchers and integration manifests") },
    } },
    // ── Reopen ──
    .{ .label = "Reopen last closed (", .prefix = true, .entry = .{
        .title = "Reopen last closed",
        .body = "Brings back the most recently closed buffer — the number in the label counts what can be reopened — with the cursor where it was, into the active leaf; the row leads the menu only while there is something to reopen, and again walks further back. A file deleted since it was closed reopens empty.",
        .keys = &.{.{ .command = .@"buffer.reopen", .label = "Reopen the last closed" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.reopen", .label = "Reopen it" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files" } } },
    } },
    // ── New ▸ ──
    .{ .label = "Scratch buffer", .entry = .{
        .title = "Scratch buffer",
        .body = "Opens an empty buffer with no file behind it in the active leaf — for a paste, a note, a command's output — that Save turns into a file by asking for a path. It is dirty from the first keystroke, so closing it asks, and one left untitled at quit is listed with the other dirty buffers.",
        .links = &.{ .{ .command = .{ .id = .@"scratch.new", .label = "Open one" } }, .{ .command = .{ .id = .@"scratch.from_clipboard", .label = "From the clipboard instead" } } },
    } },
    .{ .label = "From clipboard", .entry = .{
        .title = "From clipboard",
        .body = "Opens a scratch buffer already holding the clipboard's text with the cursor at the top — the one-step way to read, edit or save something copied elsewhere; an empty clipboard gives an empty buffer. Save asks for a path, as for any scratch.",
        .links = &.{ .{ .command = .{ .id = .@"scratch.from_clipboard", .label = "Open one" } }, .{ .command = .{ .id = .@"file.save", .label = "Save it as a file" } } },
    } },
    .{ .label = "HTTP request", .entry = .{
        .title = "HTTP request",
        .body = "Opens a blank Request pane as a tab in the active leaf — method, URL, headers and body to fill in; `http.send` sends it and the response paints in the same pane. It is scratch until *Save request* in its menu writes it as a `.http` file into the collection root, where the HTTP section lists it; *Paste curl* fills one from a copied command.",
        .links = &.{ .{ .command = .{ .id = .@"http.new", .label = "Open one" } }, .{ .command = .{ .id = .@"http.paste_curl", .label = "Paste a curl command" } }, .{ .command = .{ .id = .@"view.activity_http", .label = "The HTTP section" } } },
    } },
    .{ .label = "Shell", .entry = .{
        .title = "Shell",
        .body = "Opens a new `$SHELL` in a split beside the active pane, in the workspace directory with mnml's environment, rendered by libghostty-vt — the same shell the strip's terminal chip opens. Every open shell gets a tab and its own item in the launcher dock — the SESSIONS section lists only Claude and Codex panes; closing the tab ends it.",
        .keys = &.{.{ .command = .@"term.shell", .label = "New shell" }},
        .links = &.{ .{ .command = .{ .id = .@"term.shell", .label = "Open one" } }, .{ .command = .{ .id = .@"term.scratch_toggle", .label = "The scratch terminal" } } },
    } },
    .{ .label = "Browser tab", .entry = .{
        .title = "Browser tab",
        .body = "Opens a Browser pane on `about:blank` — a Chrome driven over CDP, with a navigate prompt, the page's console and an eval line in the pane, headless or not as `browser.headless` says. It needs a Chrome or Chromium the browser config can find; without one the pane says so instead of a page.",
        .links = &.{ .{ .command = .{ .id = .@"browser.open", .label = "Open one" } }, .{ .settings = .{ .row = copy.settingsRow("browser.headless"), .label = "Headless in Settings" } }, ask },
    } },
    .{ .label = "Tab page", .entry = .{
        .title = "Tab page",
        .body = "Adds a new tab page — a whole second layout of splits and tabs — switches to it and opens a scratch buffer there, so the page is never blank; a toast names it (`tab 2/2`). The cluster at the top right numbers the pages, a page chip's own menu closes or reorders them, and the pages come back with the session.",
        .keys = &.{.{ .command = .@"tab.new", .label = "New tab page" }},
        .links = &.{ .{ .command = .{ .id = .@"tab.new", .label = "Add one" } }, .{ .command = .{ .id = .@"tab.picker", .label = "The page picker" } } },
    } },
    // ── Open ▸ ──
    .{ .label = "File…", .entry = .{
        .title = "File…",
        .body = "The fuzzy file picker over the workspace, reached from `+` — the same list the file-picker chord opens: type a fragment of the path, Enter opens the match in the active leaf, the preview column showing the file under the cursor. A file the tree ignores is found only when the query names it.",
        .keys = &.{.{ .command = .@"picker.files", .label = "Open file" }},
        .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "Open the picker" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files" } } },
    } },
    .{ .label = "File browser", .entry = .{
        .title = "File browser",
        .body = "Opens a Files pane at the workspace root — a file manager as a tab: arrows and Enter walk the folders, Space marks rows, the marks move with cut / copy / paste, and Delete sends to the workspace trash. *Dual file panes* opens two side by side for a commander-style move.",
        .links = &.{ .{ .command = .{ .id = .@"files.open", .label = "Open one" } }, .{ .command = .{ .id = .@"files.open_split", .label = "Two, side by side" } }, .{ .command = .{ .id = .@"files.trash", .label = "The trash" } } },
    } },
    .{ .menu = "Create…", .label = "Dual file panes (commander)", .entry = .{
        .title = "Dual file panes (commander)",
        .body = "Two Files panes side by side — a focused Files pane becomes the left side and the new one opens at its folder, otherwise both start at the workspace root — each with its own sort and marks: mark on one side, paste on the other, and a move needs no typed destination. View → Dual file panes is the same pair from the menu bar.",
        .links = &.{ .{ .command = .{ .id = .@"files.open_split", .label = "Open the pair" } }, .{ .command = .{ .id = .@"files.open", .label = "One pane instead" } } },
    } },
    .{ .label = "Trash", .entry = .{
        .title = "Trash",
        .body = "Opens the workspace trash — its own folder under the data root, one per workspace — as a Files pane, where a file deleted from the tree or a Files pane waits: restore it from there, or empty the trash for good. An empty trash toasts and still opens; a trash pane already open is brought to the front.",
        .links = &.{ .{ .command = .{ .id = .@"files.trash", .label = "Open the trash" } }, .{ .command = .{ .id = .@"files.open", .label = "A file browser" } } },
    } },
    // ── AI ▸ ──
    .{ .label = "Claude Code session", .entry = .{
        .title = "Claude Code session",
        .body = "Starts a new Claude Code session — the `claude` CLI in a terminal pane — beside the active pane, with a card in the SESSIONS section; `ui.ai_layout_mode` says whether several sit as a grid of splits or as tabs in one leaf. The strip's Claude chip menu starts one in a chosen half instead. Claude routed off in `ai.routing` refuses.",
        .links = &.{ .{ .command = .{ .id = .@"ai.claude_code_new", .label = "Start one" } }, .{ .settings = .{ .row = copy.settingsRow("ui.ai_layout_mode"), .label = "AI session layout" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.claude.backend"), .label = "Claude routing" } } },
    } },
    .{ .label = "New session in a worktree…", .entry = .{
        .title = "New session in a worktree…",
        .body = "Asks for a branch name and starts a Claude Code session in a git worktree made for it, so the agent works on a checkout of its own and your files stay as they are; the branch name is on the session's card. The worktree outlives the session — merge or remove it from the worktrees list. Needs a git repo.",
        .links = &.{ .{ .command = .{ .id = .@"ai.new_session_worktree", .label = "Start one" } }, .{ .command = .{ .id = .@"git.worktrees", .label = "The worktrees list" } }, copy.docsSection("Session worktrees") },
    } },
    .{ .label = "Codex session", .entry = .{
        .title = "Codex session",
        .body = "Starts a new Codex session — the `codex` CLI in a terminal pane — beside the active pane, with a card in the SESSIONS section; under `ui.ai_layout_mode = tabs` it stacks as a tab in the active leaf instead of a split. The CLI must be on PATH, since Codex has no API route in this build; Codex routed off in `ai.routing` refuses.",
        .links = &.{ .{ .command = .{ .id = .@"ai.codex_new", .label = "Start one" } }, .{ .settings = .{ .row = copy.settingsRow("ai.routing.codex.backend"), .label = "Codex routing" } } },
    } },
    // ── Dock ▸ ──
    .{ .label = "Note", .entry = .{
        .title = "Note",
        .body = "Asks for a line of text and pins it as a small widget in the bottom-left corner of the editor area — a reminder that stays over every buffer. The widget's own kebab is where it is moved to another corner or removed; this is a dock WIDGET, nothing to do with the launcher dock along the edge.",
        .links = &.{ .{ .command = .{ .id = .@"dock.new_text", .label = "Add one" } }, .{ .command = .{ .id = .@"dock.new_log_tail", .label = "A log tail instead" } } },
    } },
    .{ .label = "Log tail", .entry = .{
        .title = "Log tail",
        .body = "Asks for a file — workspace-relative or absolute, a default offered — and pins its last lines as a widget in the bottom-left corner, following the file as it grows, like `tail -f` without a terminal. The widget's kebab moves or removes it; a path that does not exist shows an empty widget.",
        .links = &.{ .{ .command = .{ .id = .@"dock.new_log_tail", .label = "Add one" } }, .{ .command = .{ .id = .@"dock.new_text", .label = "A note instead" } } },
    } },
    // ── the curation list a row's kebab opens ──
    .{ .label = "Pin to top", .entry = .{
        .title = "Pin to top",
        .body = "Floats this row to the top of `+`, out of its group, after the rows pinned before it — a row you reach for daily is then the first thing under the button. The id goes into `ui.plus_menu_pinned` in the home config, so the pin holds in every workspace; *Unpin* in the same list puts it back.",
        .links = &.{.{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }},
    } },
    .{ .label = "Unpin", .entry = .{
        .title = "Unpin",
        .body = "Takes the row off the pinned run at the top of `+` and back into the group it came from; its id leaves `ui.plus_menu_pinned` in the home config. Hiding it altogether is the row below.",
        .links = &.{.{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }},
    } },
    .{ .label = "Hide this row", .entry = .{
        .title = "Hide this row",
        .body = "Drops the row from `+` — and its group with it once the group is empty — by adding the command id to `ui.plus_menu_hidden` in the home config. There is no unhide in the menu: take the id out of that key in config.zon and the row is back on the next open.",
        .links = &.{.{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }},
    } },
    .{ .label = "Copy command id", .entry = .{
        .title = "Copy command id",
        .body = "Puts the row's command id — `http.new`, `scratch.new` — on the clipboard, for a keybinding in config.zon, a `ui.dock.pins` entry, a script or the palette; the toast shows what was copied. The id is the palette's spelling, so a paste into the palette runs the same thing the row does.",
        .links = &.{ .{ .command = .{ .id = .@"keys.edit", .label = "Rebind a key" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } } },
    } },
    .{ .label = "(every row hidden — Settings restores them)", .entry = .{
        .title = "Every row hidden",
        .body = "Nothing is left to open here: every row of this group is pinned to the top of `+` or listed in `ui.plus_menu_hidden`. Unpin them, or take the ids out of that key in the home config.zon, and the group fills again on the next open.",
        .links = &.{.{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }},
    } },
};

/// A group row (`New ▸`, `Open ▸`, …): what the group holds and two
/// of its leaves as links.
fn group(comptime name: []const u8, comptime holds: []const u8, comptime a: command.CommandId, comptime a_label: []const u8, comptime b: command.CommandId, comptime b_label: []const u8) Entry {
    return .{
        .title = name ++ " ▸",
        .body = "Opens the group of " ++ holds ++ ". → or a click opens it beside this row, ← closes it; a child row's kebab (or a right press on it) pins that row to the top of `+` or hides it, which `ui.plus_menu_pinned` and `ui.plus_menu_hidden` remember.",
        .keys = &.{.{ .chord = "→ / ←", .label = "Open / close the group" }},
        .links = &.{ .{ .command = .{ .id = a, .label = a_label } }, .{ .command = .{ .id = b, .label = b_label } } },
    };
}

/// One enabled integration's row under `Integrations ▸`, named.
pub fn integration(arena: Allocator, label: []const u8) Allocator.Error!Entry {
    return .{
        .title = try std.fmt.allocPrint(arena, "Integrations — {s}", .{label}),
        .body = try std.fmt.allocPrint(arena, "Opens `{s}` — its pane, or its tool in a terminal split — the same as its chip on the top bar and its row's Enter in the INTEGRATIONS section. The group lists every enabled integration whose chip runs a command, with the chip's own glyph; disable one there and its row leaves this list. The row's kebab pins it to the top of `+` or hides it.", .{label}),
        .links = &.{ .{ .command = .{ .id = .@"view.activity_integrations", .label = "The integrations section" } }, .{ .command = .{ .id = .@"integrations.configure_picker", .label = "Configure an integration" } }, comptime copy.docsSection("Launchers and integration manifests") },
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "plus: every row of the + menu — groups, leaves, the curation list — resolves to a curated entry" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    const cm = @import("../../context_menus.zig");
    try app.closed.append(app.gpa, .{ .path = try app.gpa.dupe(u8, "/tmp/gone.txt"), .cursor = 0 });
    try cm.openNewTabMenu(&app, 5, 5);
    if (try menus.firstUncovered(&app, a)) |label| {
        std.debug.print("plus: no entry for `{s}` in menu `{s}`\n", .{ label, app.overlay.menu.title });
        return error.Uncovered;
    }
    try t.expectEqualStrings("Reopen last closed", menus.lookup("Create…", null, "Reopen last closed (3)").?.title);
    // `Open` is a label three menus share (a tree row's, a recent row's,
    // an integration's dynamic item); resolved as the pointer resolves
    // it — with the real item — the group's entry wins.
    var open_group: ?command.MenuItem = null;
    for (app.overlay.menu.items) |it| if (std.mem.eql(u8, it.label, "Open")) {
        open_group = it;
    };
    try t.expectEqualStrings("Open ▸", (try menus.resolve(&app, a, "Create…", null, open_group.?)).?.title);
    // The curation list: → on a child row. Reopened without a closed
    // buffer, so `New ▸` leads and the keys land on its second leaf.
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.gpa.free(app.closed.pop().?.path);
    try cm.openNewTabMenu(&app, 5, 5);
    try t.expectEqualStrings("New", app.overlay.menu.items[0].label);
    try app.handle(.{ .key = @import("../../../app.zig").Key.named(.right) });
    try app.handle(.{ .key = @import("../../../app.zig").Key.named(.down) });
    try app.handle(.{ .key = @import("../../../app.zig").Key.named(.right) });
    try t.expect(app.overlay.menu.sub != null);
    for (app.overlay.menu.sub.?.items) |it| try t.expect(menus.lookup("Create…", null, it.label) != null);
}

test "plus: an integration's row is named after it" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const e = try integration(arena_state.allocator(), "Browser");
    try t.expectEqualStrings("Integrations — Browser", e.title);
    try t.expect(std.mem.indexOf(u8, e.body, "Opens `Browser`") != null);
}
