//! Hover help for an overlay's rows (`.overlay_item`), which mean
//! different things under each overlay: a Settings row, a confirm
//! box's button, a picker's candidate, a help header. The open overlay
//! decides, so `entry` switches on `app.overlay` first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const settings_copy = @import("settings.zig");

const ask = copy.ask_link;

pub fn entry(app: *App, arena: Allocator, id: u32) Allocator.Error!?Entry {
    return switch (app.overlay) {
        .settings => try settings_copy.entry(app, arena, id),
        .confirm => |*c| try confirm(app, arena, c.purpose, c.state.choices, id),
        .picker => |*p| try picker(app, arena, p.kind, id),
        .help => .{
            .title = "Keymap reference",
            .body = "Every chord of the active profile grouped by area, with the command it runs — a header row folds its group on click or Enter. Esc or F1 closes it. The cheatsheet pane is the same list as a tab, with a filter, for keeping open beside the code.",
            .keys = &.{ .{ .chord = "Enter", .label = "Fold / unfold the group" }, .{ .chord = "Esc", .label = "Close" } },
            .links = &.{ .{ .command = .{ .id = .@"view.cheatsheet", .label = "Open the cheatsheet pane" } }, .{ .command = .{ .id = .@"keys.edit", .label = "Rebind keys" } } },
        },
        .which_key => .{
            .title = "Leader menu",
            .body = "The chords that continue from the key you pressed — vim's leader menu, which-key style: each row is the next key and what the full chord runs, a `+` row a group that opens another page. Press the key, or click the row; Esc backs out. The rows come from the keymap, rebinds included.",
            .keys = &.{ .{ .chord = "Esc", .label = "Back out" }, .{ .command = .@"whichkey.leader", .label = "The leader menu" } },
            .links = &.{ .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } }, .{ .command = .{ .id = .@"keys.edit", .label = "Rebind keys" } } },
        },
        .discovery => .{
            .title = "Click-discovery panel",
            .body = "Every family of click target the app paints, with a green count of how many are on screen right now and what a click there does. Click a row to flash its rects yellow for two seconds — the way to find a control you have read about. F1, Esc or a click elsewhere closes it.",
            .keys = &.{.{ .chord = "Esc", .label = "Close" }},
            .links = &.{ .{ .command = .{ .id = .@"view.discovery", .label = "Toggle it" } }, .{ .command = .{ .id = .@"debug.toggle_click_inspector", .label = "The click inspector" } } },
        },
        .wizard => .{
            .title = "First-launch wizard",
            .body = "The one-time setup: the input style (vim or standard), the theme, whether the fonts are installed, and where the data root goes. Every choice is a Settings row you can change later; Esc skips the rest and keeps the defaults. `first_launch.show` opens it again.",
            .keys = &.{ .{ .chord = "Enter", .label = "Next" }, .{ .chord = "Esc", .label = "Skip" } },
            .links = &.{ .{ .command = .{ .id = .@"view.settings", .label = "Settings" } }, .{ .command = .{ .id = .@"first_launch.show", .label = "Run the wizard again" } } },
        },
        .info => |kind| switch (kind) {
            .welcome => .{
                .title = "Welcome",
                .body = "The pane mnml opens on with no session to restore: the recent files, the shortcuts that matter first, and the workspace's name. A recent row opens the file; a shortcut row runs it. It closes itself when you open something. `view.welcome` brings it back.",
                .keys = &.{.{ .command = .@"picker.recent", .label = "Recent files" }},
                .links = &.{ .{ .command = .{ .id = .@"picker.files", .label = "Open a file" } }, .{ .command = .{ .id = .@"session.restore", .label = "Restore the session" } } },
            },
            .about => .{
                .title = "About mnml",
                .body = "The version, the build's profile, the workspace and data root paths, and the terminal mnml is running in. Copy from here when filing an issue — the version line is what a bug report needs first. Esc closes it.",
                .links = &.{ .{ .command = .{ .id = .@"app.check_updates", .label = "Check for updates" } }, .{ .url = .{ .url = "https://github.com/chris-mclennan/mnml-zig/issues", .label = "File an issue" } } },
            },
        },
        else => null,
    };
}

fn confirm(app: *App, arena: Allocator, purpose: app_mod.ConfirmPurpose, choices: []const app_mod.Confirm.Choice, idx: u32) Allocator.Error!?Entry {
    if (idx >= choices.len) return null;
    const label = choices[idx].label;
    return switch (purpose) {
        .quit => try quitChoice(app, arena, label, false),
        .quit_clean => try quitChoice(app, arena, label, true),
        .restart => try restartChoice(app, arena, label),
        .close_pane => closeChoice(label),
        else => .{
            .title = try std.fmt.allocPrint(arena, "{s}", .{label}),
            .body = try std.fmt.allocPrint(arena, "One of the box's answers — `{s}`. Click it, press its underlined key, or Tab to it and Enter; Esc is Cancel, as is a click outside the box. The box holds the keys until it closes, so the pane under it does not see them.", .{label}),
            .keys = &.{ .{ .chord = "Enter", .label = "The focused answer" }, .{ .chord = "Esc", .label = "Cancel" } },
        },
    };
}

fn quitChoice(app: *App, arena: Allocator, label: []const u8, clean: bool) Allocator.Error!Entry {
    var dirty: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.dirty()) {
        dirty += 1;
    };
    if (std.mem.eql(u8, label, "Save all")) return .{
        .title = "Save all, then quit",
        .body = try std.fmt.allocPrint(arena, "Writes every dirty buffer to disk — {d} of them — and then quits; a buffer that has never been saved asks for a path first, and Cancel on that prompt stops the quit. The session is written on the way out either way, so the tabs come back at the next start.", .{dirty}),
        .keys = &.{.{ .chord = "s", .label = "Save all" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all and stay" } }, .{ .command = .{ .id = .@"buffer.next_dirty", .label = "Go to the next dirty buffer" } } },
    };
    if (std.mem.eql(u8, label, "Quit anyway")) return .{
        .title = "Quit without saving",
        .body = try std.fmt.allocPrint(arena, "Quits and discards the unsaved edits in {d} buffer{s} — the files on disk stay as they were last saved. The session still records which files were open, so they reopen, but the edits are gone for good; there is no recovery file. Cancel is the safe answer if you are not sure which buffers are dirty.", .{ dirty, if (dirty == 1) "" else "s" }),
        .keys = &.{.{ .chord = "q", .label = "Quit anyway" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.next_dirty", .label = "Show me the dirty buffers" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save all instead" } } },
    };
    if (std.mem.eql(u8, label, "Quit")) return .{
        .title = "Quit",
        .body = "Nothing is unsaved, so this is the quit itself — the box is here because `ui.confirm_quit` asks once even then, with Cancel focused so an Enter on reflex does nothing. The session is written on the way out and restored at the next start.",
        .keys = &.{ .{ .chord = "q", .label = "Quit" }, .{ .command = .@"app.quit", .label = "Quit" } },
        .links = &.{ .{ .settings = .{ .row = comptime copy.settingsRow("ui.confirm_quit"), .label = "Confirm on quit" } }, .{ .command = .{ .id = .@"session.save", .label = "Save the session now" } } },
    };
    return .{
        .title = "Cancel — stay in mnml",
        .body = if (clean) "Closes the box and nothing else happens. Esc and a click outside the box are the same answer. `ui.confirm_quit` off skips this box when nothing is unsaved." else "Closes the box and nothing else happens — the unsaved buffers stay open and dirty, and the file chip's ● shows which. Esc and a click outside the box are the same answer. Save all is the row that quits without losing anything.",
        .keys = &.{ .{ .chord = "c", .label = "Cancel" }, .{ .chord = "Esc", .label = "Cancel" } },
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.confirm_quit"), .label = "Confirm on quit" } } },
    };
}

fn restartChoice(app: *App, arena: Allocator, label: []const u8) Allocator.Error!Entry {
    var dirty: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.dirty()) {
        dirty += 1;
    };
    if (std.mem.eql(u8, label, "Save all")) return .{
        .title = "Save all, then restart",
        .body = try std.fmt.allocPrint(arena, "Writes every dirty buffer to disk — {d} of them — and then relaunches; the relaunch reads each file back from disk, so this is the answer that keeps the edits. A buffer that has never been saved asks for a path first, and Cancel on that prompt stops the restart.", .{dirty}),
        .keys = &.{.{ .chord = "s", .label = "Save all" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save_all", .label = "Save all and stay" } }, .{ .command = .{ .id = .@"buffer.next_dirty", .label = "Go to the next dirty buffer" } } },
    };
    if (std.mem.eql(u8, label, "Restart anyway")) return .{
        .title = "Restart without saving",
        .body = try std.fmt.allocPrint(arena, "Relaunches and discards the unsaved edits in {d} buffer{s}. The session reopens the same files, but from what is on disk — the edits are gone for good.", .{ dirty, if (dirty == 1) "" else "s" }),
        .keys = &.{.{ .chord = "r", .label = "Restart anyway" }},
        .links = &.{ .{ .command = .{ .id = .@"buffer.next_dirty", .label = "Show me the dirty buffers" } }, .{ .command = .{ .id = .@"file.save_all", .label = "Save all instead" } } },
    };
    return .{
        .title = "Cancel — no restart",
        .body = "Closes the box and nothing else happens — the unsaved buffers stay open and dirty, and the file chip's ● shows which. Esc and a click outside the box are the same answer.",
        .keys = &.{ .{ .chord = "c", .label = "Cancel" }, .{ .chord = "Esc", .label = "Cancel" } },
        .links = &.{.{ .command = .{ .id = .@"file.save_all", .label = "Save all" } }},
    };
}

fn closeChoice(label: []const u8) Entry {
    if (std.mem.eql(u8, label, "Save")) return .{
        .title = "Save, then close",
        .body = "Writes this buffer to disk and closes the pane; a buffer that has never been saved asks for a path first. Other panes showing the same document keep it open — the text lives on there — so only this window goes.",
        .keys = &.{ .{ .chord = "s", .label = "Save and close" }, .{ .command = .@"file.save", .label = "Save without closing" } },
        .links = &.{.{ .command = .{ .id = .@"file.save", .label = "Save and stay" } }},
    };
    if (std.mem.eql(u8, label, "Discard")) return .{
        .title = "Discard the edits and close",
        .body = "Closes the pane and throws away its unsaved edits — the file on disk stays as it was last saved, and there is no recovery file. If another pane shows the same document, the edits live on there and nothing is lost. Cancel keeps the pane if you want to look first.",
        .keys = &.{.{ .chord = "d", .label = "Discard" }},
        .links = &.{ .{ .command = .{ .id = .@"file.save", .label = "Save instead" } }, .{ .command = .{ .id = .@"git.diff_file", .label = "See what changed" } } },
    };
    return .{
        .title = "Cancel — keep the pane",
        .body = "Closes the box and keeps the pane open with its edits; Esc and a click outside the box are the same answer. The file chip's ● keeps saying the buffer is dirty until it is saved or discarded.",
        .keys = &.{ .{ .chord = "c", .label = "Cancel" }, .{ .chord = "Esc", .label = "Cancel" } },
        .links = &.{.{ .command = .{ .id = .@"file.save", .label = "Save it" } }},
    };
}

fn picker(app: *App, arena: Allocator, kind: app_mod.PickerKind, idx: u32) Allocator.Error!?Entry {
    const p = &app.overlay.picker;
    const label: []const u8 = if (idx < p.filtered.items.len and p.filtered.items[idx] < p.labels.len) p.labels[p.filtered.items[idx]] else "";
    const what: []const u8 = switch (kind) {
        .files => "a file of the workspace, matched fuzzily against what you typed — Enter opens it in the active pane, Ctrl+Enter in a split; the tree excludes `.git/` and this picker does too",
        .commands => "a palette command — Enter runs it; the chord on the right is the active profile's binding, empty when the command has none. `>` in the file picker gets here too",
        .buffers => "an open buffer, shown or hidden in the strip — Enter shows it; the hidden ones are the `+N` chip's",
        .recent => "a recently opened file, newest first — Enter opens it; `file.clear_recent` empties the list",
        .themes => "a theme — the list previews it as the cursor moves and Enter keeps it (`ui.theme`); Esc puts the one you came in with back",
        .tabs => "a tab page — Enter switches to it; Alt+1..9 do the same by number",
        .grep => "a search hit — Enter jumps to the line",
        .git => "a branch, a commit or a stash, depending on the git verb that opened the picker — Enter acts on it",
        .lsp_symbols, .lsp_locations, .lsp_code_actions => "a symbol, a location or a code action the language server offered — Enter goes there or applies it",
        .ai_session => "an AI session — Enter opens its pane",
        .ai_suggest_backend => "a ghost-text backend — Enter picks it (`ai.suggest_backend`) and the setup checks it can be reached",
        .snippets => "a snippet — Enter expands it at the cursor",
        .tools => "a tool that runs in a terminal pane — Enter starts it; a tool not on PATH toasts instead",
        .tasks, .go_run_cmd => "a task or a run target — Enter runs it in a terminal pane",
        .lua => "a script — Enter runs the row's action",
        else => "a candidate — Enter picks it, Esc closes the picker",
    };
    return .{
        .title = if (label.len > 0) try std.fmt.allocPrint(arena, "{s}", .{label}) else try std.fmt.allocPrint(arena, "{s} picker row", .{@tagName(kind)}),
        .body = try std.fmt.allocPrint(arena, "A row of the {s} picker: {s}. Type to narrow the rows; ↑↓ walk them and the cursor row is the one Enter takes. Click a row to pick it. `ui.picker_position` is whether the box sits at the top or the centre.", .{ @tagName(kind), what }),
        .keys = &.{ .{ .chord = "Enter", .label = "Pick" }, .{ .chord = "Esc", .label = "Close" }, .{ .chord = "↑ / ↓", .label = "Walk the rows" } },
        .links = &.{.{ .settings = .{ .row = comptime copy.settingsRow("ui.picker_position"), .label = "Picker position" } }},
    };
}

/// For the AI: a Settings row's key and value; a confirm's question.
pub fn askContext(app: *App, arena: Allocator, id: u32) Allocator.Error!?[]const u8 {
    return switch (app.overlay) {
        .settings => try settings_copy.askContext(app, arena, id),
        .confirm => |*c| try std.fmt.allocPrint(arena, "- a confirm box titled \"{s}\": {s}\n", .{ c.state.title, c.state.message }),
        else => null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "the quit box's buttons, the close box's, a picker row and the other overlays have entries" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    const msg = try app.gpa.dupe(u8, "Unsaved changes.");
    app.overlay = .{ .confirm = .{ .state = .{ .title = "Quit", .message = msg, .choices = &App.quit_choices }, .purpose = .quit, .message = msg } };
    try t.expectEqualStrings("Save all, then quit", (try entry(&app, a, 0)).?.title);
    try t.expectEqualStrings("Quit without saving", (try entry(&app, a, 1)).?.title);
    try t.expectEqualStrings("Cancel — stay in mnml", (try entry(&app, a, 2)).?.title);
    try t.expect((try entry(&app, a, 3)) == null);
    app.overlay.confirm.purpose = .quit_clean;
    app.overlay.confirm.state.choices = &App.quit_clean_choices;
    try t.expectEqualStrings("Quit", (try entry(&app, a, 0)).?.title);
    app.overlay.confirm.purpose = .restart;
    app.overlay.confirm.state.choices = &App.restart_choices;
    try t.expectEqualStrings("Save all, then restart", (try entry(&app, a, 0)).?.title);
    try t.expectEqualStrings("Restart without saving", (try entry(&app, a, 1)).?.title);
    try t.expectEqualStrings("Cancel — no restart", (try entry(&app, a, 2)).?.title);
    app.overlay.confirm.purpose = .{ .close_pane = 0 };
    app.overlay.confirm.state.choices = &App.close_choices;
    try t.expectEqualStrings("Discard the edits and close", (try entry(&app, a, 1)).?.title);
    app.overlay.deinit(app.gpa);
    app.overlay = .discovery;
    try t.expectEqualStrings("Click-discovery panel", (try entry(&app, a, 0)).?.title);
    app.overlay = .{ .info = .about };
    try t.expectEqualStrings("About mnml", (try entry(&app, a, 0)).?.title);
    app.overlay = .none;
    try t.expect((try entry(&app, a, 0)) == null);
}
