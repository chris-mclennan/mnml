//! `app.*` and `whichkey.*` runners: quitting behind the unsaved-changes
//! box, the restart handshake, and the leader menu — and the small
//! commands that have no subsystem of their own: scratch buffers, the
//! recent-file jumps, toast dismissal, the cursor-word inserts, the
//! marks / registers / recent-commands pickers, fold navigation, the
//! quickfix walk, and the external tool launchers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const side = @import("side.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const os_path = @import("../core/os_path.zig");
const CommandError = command.CommandError;
const CommandFn = command.CommandFn;
const cmd_picker = @import("cmd_picker.zig");
const marks_store = @import("marks_store.zig");
const cmd_term = @import("cmd_term.zig");
const dispatch = @import("dispatch.zig");
const ex = @import("ex.zig");
const settings = @import("settings.zig");
const find = @import("find.zig");
const transfers = @import("transfers.zig");
const cmdline_mod = @import("cmdline.zig");

pub const table = .{
    .@"app.quit" = &quit,
    .@"app.restart" = &restart,
    .@"app.command_line" = &commandLine,
    .@"whichkey.leader" = &leader,
    .noop = &noop,
    .@"noop.info" = &noopInfo,
    .@"scratch.new" = &scratchNew,
    .@"scratch.from_clipboard" = &scratchFromClipboard,
    .@"toast.dismiss_all" = &toastDismissAll,
    .@"toast.run_action" = &toastRunAction,
    .@"toast.dismiss_current" = &toastDismissCurrent,
    .@"file.open_recent_0" = recentRunner(0),
    .@"file.open_recent_1" = recentRunner(1),
    .@"file.open_recent_2" = recentRunner(2),
    .@"file.open_recent_3" = recentRunner(3),
    .@"file.open_recent_4" = recentRunner(4),
    .@"file.open_recent_5" = recentRunner(5),
    .@"file.open_recent_6" = recentRunner(6),
    .@"file.open_recent_7" = recentRunner(7),
    .@"file.open_recent_8" = recentRunner(8),
    .@"file.open_recent_9" = recentRunner(9),
    .@"file.clear_recent" = &clearRecent,
    .@"file.open_settings" = &openSettingsFile,
    .@"keys.edit" = &openSettingsFile,
    .@"keys.doctor" = &keysDoctor,
    .@"focus.cycle" = &focusCycle,
    .@"editor.file_stats" = &fileStats,
    .@"editor.char_info" = &charInfo,
    .@"editor.char_utf8" = &charUtf8,
    .@"editor.toggle_auto_pair" = &toggleAutoPair,
    .@"editor.fold_next" = &foldNext,
    .@"editor.fold_prev" = &foldPrev,
    .@"editor.fold_selection" = &foldSelection,
    .@"editor.suspend_hint" = &suspendHint,
    .@"editor.format" = &formatAlias,
    .@"editor.insert_current_filename" = &insertCurrentFilename,
    .@"editor.insert_word_under_cursor" = &insertWordUnderCursor,
    .@"editor.insert_bigword_under_cursor" = &insertBigwordUnderCursor,
    .@"editor.insert_last_cmdline" = &insertLastCmdline,
    .@"editor.open_at_cursor" = &openAtCursor,
    .@"editor.select_all_occurrences" = &selectAllOccurrences,
    .@"vim.replay_last_ex" = &replayLastEx,
    .@"buffer.next_dirty" = &nextDirty,
    .@"buffer.prev_dirty" = &prevDirty,
    .@"qf.first" = &qfFirst,
    .@"qf.last" = &qfLast,
    .@"qf.next" = &qfNext,
    .@"qf.prev" = &qfPrev,
    .@"picker.marks" = &pickMarks,
    .@"picker.clipboard" = &pickRegisters,
    .@"picker.recent_commands" = &pickRecentCommands,
    .@"tools.htop" = toolRunner("htop"),
    .@"tools.iftop" = toolRunner("iftop"),
    .@"tools.btop" = toolRunner("btop"),
    .@"tools.ncdu" = toolRunner("ncdu"),
    .@"tools.lazygit" = toolRunner("lazygit"),
    .@"tools.gh" = toolRunner("gh"),
    .@"tools.dust" = toolRunner("dust"),
    .@"term.htop" = toolRunner("htop"),
    .@"term.iftop" = toolRunner("iftop"),
    .@"term.btop" = toolRunner("btop"),
    // Cut at the cutover — each toasts the reason and where it is recorded
    // (docs/PARITY.md), so the palette entry is honest rather than dead.
    .@"pr.picker" = cutRunner(cut_forge),
    .@"pr.refresh" = cutRunner(cut_forge),
    .@"integrations.glyph_builder" = cutRunner(cut_glyph_svg),
    .@"integrations.patch_nerd_font_svg" = cutRunner(cut_glyph_svg),
    .@"integrations.edit_codex_glyph" = cutRunner(cut_glyph_svg),
    .@"integrations.check_updates_now" = cutRunner(cut_integration_updates),
    .@"integrations.fire_auto_updates_now" = cutRunner(cut_integration_updates),
    .@"audio.airplay_music" = cutRunner(cut_audio),
    .@"audio.restore_output" = cutRunner(cut_audio),
    .@"mixr.play_now" = cutRunner(cut_audio),
    .@"mixr.show" = cutRunner(cut_audio),
    .@"mixr.show_auth_status" = cutRunner(cut_audio),
    .@"mixr.show_browse" = cutRunner(cut_audio),
    .@"mixr.show_history" = cutRunner(cut_audio),
    .@"mixr.show_log" = cutRunner(cut_audio),
    .@"mixr.show_queue" = cutRunner(cut_audio),
    .@"sonos.copy_track" = cutRunner(cut_audio),
    .@"sonos.favorites" = cutRunner(cut_audio),
    .@"sonos.group_all" = cutRunner(cut_audio),
    .@"sonos.hide" = cutRunner(cut_audio),
    .@"sonos.mute" = cutRunner(cut_audio),
    .@"sonos.next" = cutRunner(cut_audio),
    .@"sonos.play_pause" = cutRunner(cut_audio),
    .@"sonos.previous" = cutRunner(cut_audio),
    .@"sonos.refresh" = cutRunner(cut_audio),
    .@"sonos.reload_favorites" = cutRunner(cut_audio),
    .@"sonos.rooms" = cutRunner(cut_audio),
    .@"sonos.status" = cutRunner(cut_audio),
    .@"sonos.stream_mac_audio" = cutRunner(cut_audio),
    .@"sonos.ungroup" = cutRunner(cut_audio),
    .@"sonos.volume_down" = cutRunner(cut_audio),
    .@"sonos.volume_up" = cutRunner(cut_audio),
};

const cut_forge = "the cross-host PR picker returns with the Zig forge integrations (docs/PARITY.md § Git)";
const cut_glyph_svg = "the per-integration glyph builder and its SVG preview are cut — SVG-to-font itself is not: `view.terminal_glyph_custom` bakes one (docs/PARITY.md § Headless, IPC & extensibility)";
const cut_audio = "now-playing, Sonos and mixr control are cut from mnml-zig (docs/PARITY.md § UI & theming)";
const cut_integration_updates = "the cargo / git integration auto-updater is not in mnml-zig — Zig integrations reinstall with `<integration> --install`; `integrations.auto_update_*` keys are accepted and ignored (docs/PARITY.md § Headless, IPC & extensibility)";

/// A command that was cut on purpose: the reason, and where the ledger
/// records it, as one toast. Fails so a keybinding does not look like it
/// silently worked.
fn cutRunner(comptime reason: []const u8) CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            return app.diag.fail(app.frame.allocator(), "not in mnml-zig: " ++ reason, .{});
        }
    }.run;
}

/// Quit — always through the box (`quit_prompt.test` and
/// `quit_confirm_clean.test` are its spec; `ConfirmPurpose.quit` /
/// `.quit_clean` route the choice).
fn quit(app: *App) CommandError!void {
    // A copy in flight is refused before the dirty check: the box's
    // Discard must not be a way past it (`transfers.quitGuard`).
    try transfers.quitGuard(app, false);
    const dirty = try app.dirtyBufferNames(app.frame.allocator());
    // // changed (quit-confirm): the CLEAN case confirms too. Ctrl+Q
    // sits one key from Ctrl+W and Ctrl+A, and a mis-hit used to end
    // the session with no way back — the terminals, the layout and the
    // AI panes all gone. `ui.confirm_quit = false` puts the old
    // straight-through quit back for anyone who wants it.
    if (dirty.len == 0) return confirmQuitOrQuit(app);
    // // changed (bottom-row): the box NAMES the buffers. A count alone
    // does not say whether the work about to go is a scratch note or
    // the file you have been on all morning. Its buttons are the quit's
    // own — Save all / Quit anyway / Cancel — and Cancel takes the
    // focus, so Enter on a box you did not mean to raise is always
    // safe (the same safety-first default the delete box uses).
    const msg = try std.fmt.allocPrint(app.gpa, "Unsaved: {s}", .{dirty});
    return openQuitBox(app, msg, &App.quit_choices, .quit);
}

/// Raise the quit box over `msg` (owned, the overlay takes it) with
/// Cancel — the last choice — holding the focus.
fn openQuitBox(app: *App, msg: []u8, choices: []const app_mod.Confirm.Choice, purpose: app_mod.ConfirmPurpose) CommandError!void {
    return openBox(app, "Quit mnml?", msg, choices, purpose);
}

fn openBox(app: *App, title: []const u8, msg: []u8, choices: []const app_mod.Confirm.Choice, purpose: app_mod.ConfirmPurpose) CommandError!void {
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = title, .message = msg, .choices = choices, .selected = choices.len - 1 },
        .purpose = purpose,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// // changed (quit-confirm): `:q` on the last pane and `:qa` end the
/// session, so without a bang they stop at the same box `app.quit`
/// raises. `ConfirmPurpose` is `.quit_clean` either way — both ex
/// verbs refuse a dirty buffer before they get here.
pub fn confirmQuitOrQuit(app: *App) CommandError!void {
    if (!app.cfg.ui.confirm_quit) {
        app.quit = true;
        return;
    }
    const running = try app.runningTerminalNames(app.frame.allocator());
    const msg = if (running.len == 0)
        try app.gpa.dupe(u8, "Nothing is unsaved. This closes mnml.")
    else
        try std.fmt.allocPrint(app.gpa, "Nothing is unsaved. Still running: {s}", .{running});
    return openQuitBox(app, msg, &App.quit_clean_choices, .quit_clean);
}

/// `Ctrl+Shift+A` — take up the newest message's offer, the keyboard's
/// way to the ` Install ` button a toast paints. The newest is the one
/// on screen nearest the statusline, which is the one the chord is for.
fn toastRunAction(app: *App) CommandError!void {
    var i = app.toasts.items.len;
    while (i > 0) {
        i -= 1;
        const action = app.toasts.items[i].action orelse continue;
        app.toasts.items[i].action = null;
        defer action.deinit(app.gpa);
        app.dismissToastAt(i);
        return app.runToastAction(action);
    }
    return app.diag.fail(app.frame.allocator(), "no message on screen is offering anything", .{});
}

/// `Ctrl+;` — the app's own `:` line (`app/cmdline.zig`), from any
/// focus and in either keymap profile. Already open, it stays as it is.
fn commandLine(app: *App) CommandError!void {
    cmdline_mod.open(app);
}

/// Exit 75: the `run.sh` loop rebuilds and relaunches. The relaunch
/// reads every file back from disk, so unsaved work stops at the quit
/// box's own answers first — Save all / Restart anyway / Cancel. The
/// harness's restart (`run.sh restart`, the IPC command) is not this
/// runner and still goes straight out.
fn restart(app: *App) CommandError!void {
    try transfers.quitGuard(app, false);
    const dirty = try app.dirtyBufferNames(app.frame.allocator());
    if (dirty.len == 0) {
        app.restart = true;
        app.quit = true;
        return;
    }
    const msg = try std.fmt.allocPrint(app.gpa, "Unsaved: {s}", .{dirty});
    return openBox(app, "Restart mnml?", msg, &App.restart_choices, .restart);
}

fn leader(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .which_key = .{} };
    app.focus = .overlay;
    app.needs_render = true;
}

test "app.quit asks first, clean or dirty" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    // // changed (quit-confirm): nothing unsaved still raises the box —
    // Quit / Cancel, Cancel focused, so Enter is safe.
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(!app.quit);
    try t.expect(app.overlay == .confirm);
    try t.expect(app.overlay.confirm.purpose == .quit_clean);
    try t.expectEqualStrings("Quit mnml?", app.overlay.confirm.state.title);
    try t.expectEqualStrings("Nothing is unsaved. This closes mnml.", app.overlay.confirm.state.message);
    try t.expectEqual(@as(usize, 2), app.overlay.confirm.state.choices.len);
    try t.expectEqualStrings("Quit", app.overlay.confirm.state.choices[0].label);
    try t.expectEqualStrings("Cancel", app.overlay.confirm.state.choices[1].label);
    try t.expectEqual(@as(usize, 1), app.overlay.confirm.state.selected);

    // Enter lands on Cancel: the box goes and the session stays.
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expect(!app.quit);
    // Esc cancels the same way.
    try command.run(&app, .{ .static = .@"app.quit" });
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(!app.quit);
    // A SECOND Ctrl+Q on the clean box quits anyway, as it does on the
    // dirty one — the chord that raised it, pressed again.
    try command.run(&app, .{ .static = .@"app.quit" });
    try app.handle(.{ .key = app_mod.Key.ctrl('q') });
    try t.expect(app.quit);
    try t.expect(app.overlay == .none);
    // `q` is the quit.
    app.quit = false;
    try command.run(&app, .{ .static = .@"app.quit" });
    try app.handle(.{ .key = app_mod.Key.char('q') });
    try t.expect(app.quit);
    try t.expect(app.overlay == .none);

    app.quit = false;
    const e = app.activeEditor().?;
    try e.buf.editor.setText("x");
    e.buf.doc.dirty = true;
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(!app.quit);
    try t.expect(app.overlay == .confirm);
    // // changed (bottom-row): the box names what is unsaved, its
    // buttons are the quit's own, and Cancel has the focus so Enter is
    // safe on a box you did not mean to raise.
    try t.expectEqualStrings("Quit mnml?", app.overlay.confirm.state.title);
    try t.expectEqualStrings("Unsaved: [scratch]", app.overlay.confirm.state.message);
    try t.expectEqualStrings("Cancel", app.overlay.confirm.state.choices[app.overlay.confirm.state.selected].label);
    try t.expect(app.overlay.confirm.purpose == .quit);

    // Esc cancels; nothing is lost.
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expect(!app.quit);
    try t.expect(app.activeEditor().?.buf.doc.dirty);

    // A SECOND Ctrl+Q on the box quits anyway — the chord that raised it
    // pressed again plainly means yes.
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = app_mod.Key.ctrl('q') });
    try t.expect(app.quit);
    try t.expect(app.overlay == .none);

    // `q` on its own does too.
    app.quit = false;
    try command.run(&app, .{ .static = .@"app.quit" });
    try app.handle(.{ .key = app_mod.Key.char('q') });
    try t.expect(app.quit);
}

test "ui.confirm_quit = false keeps the old quit: the box only when something is unsaved" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    app.cfg.ui.confirm_quit = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(app.quit);
    try t.expect(app.overlay == .none);
    // Unsaved work still stops, whatever the key says.
    app.quit = false;
    const e = app.activeEditor().?;
    try e.buf.editor.setText("x");
    e.buf.doc.dirty = true;
    try command.run(&app, .{ .static = .@"app.quit" });
    try t.expect(!app.quit);
    try t.expect(app.overlay == .confirm);
    try t.expect(app.overlay.confirm.purpose == .quit);
}

test "the harness's exits are not gated by the box: the IPC quit and restart go straight out" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    // `run.sh stop` — the IPC `quit` command, the path `app.zig` takes
    // for it. A box here would leave the harness hanging on a key
    // nobody is there to press.
    app.quit = false;
    try app.handle(.{ .ipc = try event.IpcCommand.create(t.allocator, "{\"cmd\":\"quit\"}") });
    try t.expect(app.quit);
    try t.expect(app.overlay == .none);
    // `run.sh restart` / `app.restart` — exit 75, same story.
    app.quit = false;
    app.restart = false;
    try command.run(&app, .{ .static = .@"app.restart" });
    try t.expect(app.quit);
    try t.expect(app.restart);
    try t.expect(app.overlay == .none);
}

test "app.restart over unsaved work asks first — Save all / Restart anyway / Cancel — and a clean one restarts at once" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("x");
    e.buf.doc.dirty = true;
    try command.run(&app, .{ .static = .@"app.restart" });
    try t.expect(!app.quit);
    try t.expect(!app.restart);
    try t.expect(app.overlay == .confirm);
    try t.expect(app.overlay.confirm.purpose == .restart);
    try t.expectEqualStrings("Restart mnml?", app.overlay.confirm.state.title);
    try t.expectEqualStrings("Unsaved: [scratch]", app.overlay.confirm.state.message);
    try t.expectEqualStrings("Cancel", app.overlay.confirm.state.choices[app.overlay.confirm.state.selected].label);
    // Enter lands on Cancel; Esc cancels too. The edit stays.
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expect(!app.quit and !app.restart);
    try command.run(&app, .{ .static = .@"app.restart" });
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try t.expect(!app.quit and !app.restart);
    try t.expect(app.activeEditor().?.buf.doc.dirty);
    // `r` is Restart anyway.
    try command.run(&app, .{ .static = .@"app.restart" });
    try app.handle(.{ .key = app_mod.Key.char('r') });
    try t.expect(app.quit and app.restart);
    // Nothing unsaved: straight out, no box.
    app.quit = false;
    app.restart = false;
    e.buf.doc.dirty = false;
    try command.run(&app, .{ .static = .@"app.restart" });
    try t.expect(app.quit and app.restart);
    try t.expect(app.overlay == .none);
}

test "the quit box's Save all writes every dirty buffer and then quits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.txt", .data = "one\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.txt", .data = "two\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    for ([_][]const u8{ "one.txt", "two.txt" }) |name| {
        const p = try std.fs.path.join(app.frame.allocator(), &.{ root, name });
        _ = try app.openEditor(p);
        const e = app.activeEditor().?;
        try e.buf.editor.setText("CHANGED\n");
        e.buf.doc.dirty = true;
    }
    try command.run(&app, .{ .static = .@"app.quit" });
    // Both names are on the box, in pane order.
    try t.expectEqualStrings("Unsaved: one.txt, two.txt", app.overlay.confirm.state.message);
    try app.handle(.{ .key = app_mod.Key.char('s') });
    try t.expect(app.quit);
    var got: [64]u8 = undefined;
    for ([_][]const u8{ "one.txt", "two.txt" }) |name| {
        try t.expectEqualStrings("CHANGED\n", try tmp.dir.readFile(t.io, name, &got));
    }
}

// ─── the small ones ──────────────────────────────────────────────────────

fn noop(_: *App) CommandError!void {}

fn noopInfo(app: *App) CommandError!void {
    app.toast("noop — bound on purpose, does nothing", .{});
}

fn scratchNew(app: *App) CommandError!void {
    _ = app.openScratch() catch return error.OutOfMemory;
}

/// A scratch buffer holding the unnamed register.
fn scratchFromClipboard(app: *App) CommandError!void {
    const text = try app.frame.allocator().dupe(u8, app.clipboard.text());
    const id = app.openScratch() catch return error.OutOfMemory;
    const e = app.panes.editor(id) orelse return error.NotAnEditor;
    try e.buf.editor.setText(text);
    e.buf.editor.setCursor(0);
    app.needs_render = true;
}

/// Every transient toast expires now; the next tick sweeps them. A
/// sticky toast (a progress line with an id) stays until its owner
/// clears it.
fn toastDismissAll(app: *App) CommandError!void {
    for (app.toasts.items) |*toast| if (toast.id == null) {
        toast.expires_ms = app.now_ms - 1;
    };
    app.needs_render = true;
}

/// The newest transient toast expires now.
fn toastDismissCurrent(app: *App) CommandError!void {
    var i = app.toasts.items.len;
    while (i > 0) {
        i -= 1;
        if (app.toasts.items[i].id == null) {
            app.toasts.items[i].expires_ms = app.now_ms - 1;
            break;
        }
    }
    app.needs_render = true;
}

/// `file.open_recent_N`: the Nth most recent file (0 = newest).
fn recentRunner(comptime n: usize) CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            const items = app.recent.items;
            if (n >= items.len) return app.diag.fail(app.frame.allocator(), "recent: only {d} file(s)", .{items.len});
            const path = try app.frame.allocator().dupe(u8, items[items.len - 1 - n]);
            _ = app.openPath(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
            };
        }
    }.run;
}

fn clearRecent(app: *App) CommandError!void {
    const n = app.recent.items.len;
    for (app.recent.items) |p| app.gpa.free(p);
    app.recent.clearRetainingCapacity();
    app.toast("recent files: cleared {d}", .{n});
}

/// `file.open_settings` / `keys.edit`: the home config file (keys live
/// in it), created empty when it does not exist yet.
fn openSettingsFile(app: *App) CommandError!void {
    const path = (try settings.configPath(app, .home)) orelse return app.diag.fail(app.frame.allocator(), "no home config (no $HOME, no data root)", .{});
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ path, @errorName(err) }),
    };
}

/// `keys.doctor`: the first-launch wizard, opened on its Keyboard
/// section — the probe rows there tick as each modifier chord arrives,
/// which is the whole diagnosis.
fn keysDoctor(app: *App) CommandError!void {
    try @import("first_launch.zig").show(app);
    app.overlay.wizard.ui.section = .keyboard;
}

/// left column → pane → right column → left column, skipping what is
/// not on screen.
fn focusCycle(app: *App) CommandError!void {
    const left: ?app_mod.FocusId = if (!app.zen) (if (side.shown(app, .left)) |s| side.focusOf(s) else null) else null;
    const right: ?app_mod.FocusId = if (!app.zen) (if (side.shown(app, .right)) |s| side.focusOf(s) else null) else null;
    const pane: ?app_mod.FocusId = if (app.active) |a| .{ .pane = a } else null;
    const in_left = left != null and std.meta.eql(app.focus, left.?);
    const in_right = right != null and std.meta.eql(app.focus, right.?);
    app.focus = if (in_left)
        pane orelse right orelse app.focus
    else if (in_right)
        left orelse pane orelse app.focus
    else
        right orelse left orelse pane orelse app.focus;
    app.needs_render = true;
}

// ─── editor odds and ends ────────────────────────────────────────────────

fn fileStats(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const text = e.buf.editor.bytes();
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |_| words += 1;
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    app.toast("{s}: {d} lines, {d} words, {d} chars, {d} bytes", .{ if (e.buf.doc.path) |p| app.relPath(p) else "[scratch]", e.buf.editor.lineCount(), words, chars, text.len });
}

/// The codepoint under the cursor, `ga` style.
fn charInfo(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const text = ed.bytes();
    if (ed.cursor >= text.len) return app.diag.fail(app.frame.allocator(), "char info: end of buffer", .{});
    const n = std.unicode.utf8ByteSequenceLength(text[ed.cursor]) catch 1;
    const end = @min(ed.cursor + n, text.len);
    const cp = std.unicode.utf8Decode(text[ed.cursor..end]) catch text[ed.cursor];
    app.toast("<{s}> U+{X:0>4} dec {d} oct {o} utf-8 {s}", .{ if (cp == '\n') "NL" else text[ed.cursor..end], cp, cp, cp, try hexBytes(app.frame.allocator(), text[ed.cursor..end]) });
}

fn charUtf8(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const text = ed.bytes();
    if (ed.cursor >= text.len) return app.diag.fail(app.frame.allocator(), "char info: end of buffer", .{});
    const n = std.unicode.utf8ByteSequenceLength(text[ed.cursor]) catch 1;
    const end = @min(ed.cursor + n, text.len);
    app.toast("utf-8: {s}", .{try hexBytes(app.frame.allocator(), text[ed.cursor..end])});
}

fn hexBytes(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (bytes, 0..) |b, i| out.writer.print("{s}{x:0>2}", .{ if (i == 0) "" else " ", b }) catch return error.OutOfMemory;
    return out.written();
}

/// Flips `editor.auto_pair` and every open buffer with it.
fn toggleAutoPair(app: *App) CommandError!void {
    app.cfg.editor.auto_pair = !app.cfg.editor.auto_pair;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .editor => |*e| e.buf.doc.auto_pair = app.cfg.editor.auto_pair,
        else => {},
    };
    app.toast("auto-pair {s}", .{if (app.cfg.editor.auto_pair) "on" else "off"});
}

/// The next closed fold below the cursor (`zj`).
fn foldNext(app: *App) CommandError!void {
    return foldStep(app, true);
}

/// The previous closed fold above the cursor (`zk`).
fn foldPrev(app: *App) CommandError!void {
    return foldStep(app, false);
}

/// `zj` / `zk` (`:help zj`): to the start of the next fold, or the end
/// of the previous one — open bracket blocks and closed folds alike. A
/// closed fold is one line: the step leaves from its edges and never
/// lands on a line a closed fold hides.
fn foldStep(app: *App, forward: bool) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const row = ed.rowCol().row;
    const here = e.buf.foldAt(row);
    const from_start = if (here) |f| f[0] else row;
    const from_end = if (here) |f| f[1] else row;
    var best: ?usize = null;
    const folds = @import("cmd_editor.zig");
    const ranges = try folds.allFoldRanges(ed, folds.foldRulesParsed(e), app.frame.allocator());
    for (ranges) |r| consider(e, r, forward, from_start, from_end, &best);
    for (e.buf.editor.folds.keys(), e.buf.editor.folds.values()) |st, en| consider(e, .{ st, en }, forward, from_start, from_end, &best);
    var target = best orelse return app.diag.fail(app.frame.allocator(), "no fold {s}", .{if (forward) "below" else "above"});
    // A fold end inside a closed fold shows as that fold's header.
    if (e.buf.foldAt(target)) |f| target = f[0];
    ed.setCursor(ed.firstNonWs(target));
    ed.goal_col = null;
    app.needs_render = true;
}

fn consider(e: *const EditorPane, r: [2]usize, forward: bool, from_start: usize, from_end: usize, best: *?usize) void {
    // A fold whose start a closed fold hides is not on screen to reach.
    if (e.buf.foldAt(r[0])) |f| if (f[0] != r[0]) return;
    if (forward) {
        if (r[0] > from_end and (best.* == null or r[0] < best.*.?)) best.* = r[0];
    } else {
        if (r[1] < from_start and (best.* == null or r[1] > best.*.?)) best.* = r[1];
    }
}

/// `zf` over the selection: the rows it spans become one closed fold.
fn foldSelection(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const ed = e.buf.editor;
    const sel = ed.selection() orelse return app.diag.fail(app.frame.allocator(), "fold: nothing selected", .{});
    const start = ed.lineOfByte(sel[0]);
    // A range that ends at a line's start names the line before it,
    // unless that line is empty and the cursor simply sits on it.
    var end_row = ed.lineOfByte(sel[1]);
    if (sel[1] > sel[0] and end_row > start and sel[1] == ed.lineStart(end_row) and !(sel[1] < ed.len() and ed.bytes()[sel[1]] == '\n')) end_row -= 1;
    if (end_row <= start) return app.diag.fail(app.frame.allocator(), "fold: the selection is one line", .{});
    try e.buf.editor.folds.put(app.gpa, start, end_row);
    ed.setCursor(ed.firstNonWs(start));
    ed.anchor = null;
    app.needs_render = true;
    app.toast("folded {d}–{d}", .{ start + 1, end_row + 1 });
}

fn suspendHint(app: *App) CommandError!void {
    app.toast("mnml does not suspend — open a shell with :term (ctrl+`), or quit with ctrl+q", .{});
}

/// `editor.format` is the language server's formatter here.
fn formatAlias(app: *App) CommandError!void {
    return command.run(app, .{ .static = .@"lsp.format" });
}

/// The `ctrl+r`-family inserts: into the `:` line while it is open,
/// otherwise into the buffer at the cursor.
fn insertText(app: *App, e: *EditorPane, text: []const u8) CommandError!void {
    if (e.buf.input.isCmdlineOpen()) return dispatch.cmdlineInsert(app, e, text);
    try app.splice(e, e.buf.editor.cursor, e.buf.editor.cursor, text);
}

fn insertCurrentFilename(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "the buffer has no file name", .{});
    return insertText(app, e, try app.frame.allocator().dupe(u8, app.relPath(path)));
}

fn insertWordUnderCursor(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const r = find.wordAt(e.buf.editor.bytes(), e.buf.editor.cursor) orelse return app.diag.fail(app.frame.allocator(), "no word under the cursor", .{});
    return insertText(app, e, try app.frame.allocator().dupe(u8, e.buf.editor.bytes()[r.start..r.end]));
}

/// The run of non-blank bytes around `byte`.
fn bigWordAt(text: []const u8, byte: usize) ?[2]usize {
    if (byte >= text.len or std.ascii.isWhitespace(text[byte])) return null;
    var s = byte;
    while (s > 0 and !std.ascii.isWhitespace(text[s - 1])) s -= 1;
    var e = byte;
    while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
    return .{ s, e };
}

fn insertBigwordUnderCursor(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const r = bigWordAt(e.buf.editor.bytes(), e.buf.editor.cursor) orelse return app.diag.fail(app.frame.allocator(), "no word under the cursor", .{});
    return insertText(app, e, try app.frame.allocator().dupe(u8, e.buf.editor.bytes()[r[0]..r[1]]));
}

fn insertLastCmdline(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const last = app.cmd_history.getLastOrNull() orelse return app.diag.fail(app.frame.allocator(), "no previous : line", .{});
    return insertText(app, e, try app.frame.allocator().dupe(u8, last));
}

/// `gf`: the path under the cursor, with an optional `:line[:col]`.
pub fn pathUnderCursor(app: *App, e: *EditorPane) CommandError!struct { abs: []const u8, line: ?u32, col: ?u32 } {
    const arena = app.frame.allocator();
    const text = e.buf.editor.bytes();
    const r = bigWordAt(text, e.buf.editor.cursor) orelse return app.diag.fail(arena, "no path under the cursor", .{});
    var word = std.mem.trim(u8, text[r[0]..r[1]], "\"'`<>()[]{},;");
    var line: ?u32 = null;
    var col: ?u32 = null;
    // `path:12:3` — the trailing numbers are a position, not the name.
    var k: usize = 2;
    while (k > 0) : (k -= 1) {
        const colon = std.mem.lastIndexOfScalar(u8, word, ':') orelse break;
        const n = std.fmt.parseInt(u32, word[colon + 1 ..], 10) catch break;
        if (line == null) line = n else {
            col = line;
            line = n;
        }
        word = word[0..colon];
    }
    if (word.len == 0) return app.diag.fail(arena, "no path under the cursor", .{});
    const abs = try app.absPath(word);
    std.Io.Dir.cwd().access(app.io, abs, .{}) catch return app.diag.fail(arena, "{s}: no such file", .{word});
    return .{ .abs = abs, .line = line, .col = col };
}

fn openAtCursor(app: *App) CommandError!void {
    const e = try app.requireEditor();
    const target = try pathUnderCursor(app, e);
    const id = app.openPath(target.abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ app.relPath(target.abs), @errorName(err) }),
    };
    if (target.line) |l| if (app.panes.editor(id)) |ed| ed.buf.editor.placeCursor(l -| 1, (target.col orelse 1) -| 1);
}

/// `ctrl+shift+l`: a cursor on every occurrence of the word.
fn selectAllOccurrences(app: *App) CommandError!void {
    const e = try app.requireEditor();
    var rounds: usize = 0;
    while (rounds < 4096) : (rounds += 1) {
        const before = e.buf.editor.extra_cursors.items.len;
        _ = try app.applyOps(e, &.{.add_cursor_at_next_word});
        if (e.buf.editor.extra_cursors.items.len == before) break;
    }
    app.toast("{d} cursor(s)", .{e.buf.editor.extra_cursors.items.len + 1});
}

/// `@:` — the last `:` line again.
fn replayLastEx(app: *App) CommandError!void {
    const last = app.cmd_history.getLastOrNull() orelse return app.diag.fail(app.frame.allocator(), "no previous : line", .{});
    const line = try app.frame.allocator().dupe(u8, last);
    return ex.run(app, line);
}

// ─── buffers ─────────────────────────────────────────────────────────────

fn nextDirty(app: *App) CommandError!void {
    return dirtyStep(app, true);
}

fn prevDirty(app: *App) CommandError!void {
    return dirtyStep(app, false);
}

/// The next / previous editor with unsaved changes, in pane order.
fn dirtyStep(app: *App, forward: bool) CommandError!void {
    const n = app.panes.slots.items.len;
    if (n == 0) return app.diag.fail(app.frame.allocator(), "no dirty buffers", .{});
    const start: usize = app.active orelse 0;
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const i = if (forward) (start + k) % n else (start + n - (k % n)) % n;
        const slot = app.panes.slots.items[i] orelse continue;
        switch (slot) {
            .editor => |e| if (e.buf.doc.dirty) {
                app.showPane(@intCast(i));
                return;
            },
            else => {},
        }
    }
    return app.diag.fail(app.frame.allocator(), "no dirty buffers", .{});
}

// ─── quickfix ────────────────────────────────────────────────────────────

fn quickfixPane(app: *App) ?struct { id: PaneId, list: *app_mod.ListPane } {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .list => |*l| if (l.kind == .quickfix) return .{ .id = @intCast(i), .list = l },
        else => {},
    };
    return null;
}

fn qfFirst(app: *App) CommandError!void {
    return qfGo(app, .first);
}
fn qfLast(app: *App) CommandError!void {
    return qfGo(app, .last);
}
fn qfNext(app: *App) CommandError!void {
    return qfGo(app, .next);
}
fn qfPrev(app: *App) CommandError!void {
    return qfGo(app, .prev);
}

/// `:cfirst` / `:clast` / `:cnext` / `:cprev` over the quickfix pane
/// (`:cexpr` fills it); the entry opens the way Enter on its row does.
fn qfGo(app: *App, where: enum { first, last, next, prev }) CommandError!void {
    const arena = app.frame.allocator();
    const qf = quickfixPane(app) orelse return app.diag.fail(arena, "no quickfix list (:cexpr fills one)", .{});
    const n = qf.list.entries.items.len;
    if (n == 0) return app.diag.fail(arena, "quickfix list is empty", .{});
    qf.list.cursor = switch (where) {
        .first => 0,
        .last => n - 1,
        .next => if (qf.list.cursor + 1 < n) qf.list.cursor + 1 else return app.diag.fail(arena, "quickfix: at the last entry", .{}),
        .prev => if (qf.list.cursor > 0) qf.list.cursor - 1 else return app.diag.fail(arena, "quickfix: at the first entry", .{}),
    };
    try dispatch.listPaneEnter(app, qf.id, qf.list);
    app.toast("({d} of {d}) {s}", .{ qf.list.cursor + 1, n, qf.list.entries.items[qf.list.cursor].text });
}

// ─── pickers over what the app already holds ─────────────────────────────

/// The buffer's marks, then the global (uppercase) ones with their file.
fn pickMarks(app: *App) CommandError!void {
    const gpa = app.gpa;
    const e = try app.requireEditor();
    const globals = try marks_store.letters(app, app.frame.allocator());
    if (e.buf.doc.marks.count() == 0 and globals.len == 0) return app.diag.fail(app.frame.allocator(), "no marks in this buffer (m<a-z> sets one)", .{});
    var letters: std.ArrayListUnmanaged(u8) = .empty;
    defer letters.deinit(gpa);
    var it = e.buf.doc.marks.keyIterator();
    while (it.next()) |k| try letters.append(gpa, k.*);
    std.mem.sort(u8, letters.items, {}, std.sort.asc(u8));
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (letters.items) |c| {
        const pos = e.buf.doc.markPos(c).?;
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{c}  Ln {d}, Col {d}", .{ c, pos.row + 1, pos.col + 1 }));
        const row = @min(pos.row, e.buf.editor.lineCount() -| 1);
        const ls = e.buf.editor.lineStart(row);
        const le = e.buf.editor.lineEnd(row);
        try details.append(gpa, try gpa.dupe(u8, std.mem.trim(u8, e.buf.editor.bytes()[ls..le], " \t")));
    }
    for (globals) |c| {
        const m = app.global_marks.get(c).?;
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{c}  Ln {d}, Col {d}", .{ c, m.row + 1, m.col + 1 }));
        try details.append(gpa, try gpa.dupe(u8, app.relPath(m.path)));
    }
    try cmd_picker.openPickerWith(app, "Marks", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptMark;
}

fn acceptMark(app: *App, _: usize, label: []const u8) Allocator.Error!void {
    if (marks_store.isGlobal(label[0])) return marks_store.jump(app, label[0], true);
    const e = app.activeEditor() orelse return;
    const pos = e.buf.doc.markPos(label[0]) orelse return;
    e.buf.editor.placeCursor(pos.row, pos.col);
    app.needs_render = true;
}

/// The registers: `"` then `a`–`z`, `0`–`9`; Enter inserts one.
fn pickRegisters(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    if (app.clipboard.unnamed) |u| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "\"  {s}", .{try preview(app.frame.allocator(), u.text)}));
        try details.append(gpa, try gpa.dupe(u8, if (u.linewise) "linewise" else if (u.block) "blockwise" else ""));
    }
    var regs: std.ArrayListUnmanaged(u8) = .empty;
    defer regs.deinit(gpa);
    var it = app.clipboard.named.keyIterator();
    while (it.next()) |k| try regs.append(gpa, k.*);
    std.mem.sort(u8, regs.items, {}, std.sort.asc(u8));
    for (regs.items) |r| {
        const entry = app.clipboard.named.get(r).?;
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{c}  {s}", .{ r, try preview(app.frame.allocator(), entry.text) }));
        try details.append(gpa, try gpa.dupe(u8, if (entry.linewise) "linewise" else if (entry.block) "blockwise" else ""));
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no registers hold anything yet", .{});
    try cmd_picker.openPickerWith(app, "Registers", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptRegister;
}

fn preview(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (out.items.len >= 60) {
            try out.appendSlice(arena, "…");
            break;
        }
        try out.append(arena, if (c == '\n' or c == '\t') ' ' else c);
    }
    return out.items;
}

fn acceptRegister(app: *App, _: usize, label: []const u8) Allocator.Error!void {
    const e = app.activeEditor() orelse return;
    const text: []const u8 = if (label[0] == '"') (if (app.clipboard.unnamed) |u| u.text else return) else (app.clipboard.named.get(label[0]) orelse return).text;
    const copy = try app.frame.allocator().dupe(u8, text);
    if (e.buf.input.isCmdlineOpen()) return dispatch.cmdlineInsert(app, e, copy);
    try app.splice(e, e.buf.editor.cursor, e.buf.editor.cursor, copy);
}

/// `picker.recent_commands`: the commands that ran, newest first
/// (`App.recent_commands` — palette, keymap, menu and `:` runs alike),
/// each row `group  ·  title  ·  id` as the palette's, the chord as
/// the detail; Enter runs it again. Rust's `open_recent_commands_picker`.
/// (The `:` line's own history is `view.cmdline_history`.) An id no
/// longer registered — an integration gone — is left out.
fn pickRecentCommands(app: *App) CommandError!void {
    const gpa = app.gpa;
    if (app.recent_commands.items.len == 0) return app.diag.fail(app.frame.allocator(), "no recent commands yet", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (app.recent_commands.items) |id| {
        const ref = command.resolve(app, id) orelse continue;
        switch (ref) {
            .static => |sid| {
                try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  ·  {s}  ·  {s}", .{ command.group(sid), command.title(sid), id }));
                try details.append(gpa, try cmd_picker.chordHint(app, gpa, command.spec(sid).keys));
            },
            .dyn => |slot| {
                const c = app.dyn_commands.at(slot) orelse continue;
                try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  ·  {s}  ·  {s}", .{ c.group, c.title, id }));
                try details.append(gpa, try std.mem.join(gpa, " / ", c.keys));
            },
        }
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no recent commands resolvable", .{});
    try cmd_picker.openPickerWith(app, "Recent commands", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptRecentCommand;
}

/// The id is the row's last `  ·  ` segment.
fn acceptRecentCommand(app: *App, _: usize, label: []const u8) Allocator.Error!void {
    const sep = "  \u{b7}  ";
    const at = std.mem.lastIndexOf(u8, label, sep) orelse return;
    const id = try app.frame.allocator().dupe(u8, label[at + sep.len ..]);
    command.runNamed(app, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {}, // toasted by `command.run`
    };
}

// ─── external tools ──────────────────────────────────────────────────────

/// `tools.<bin>` / `term.<bin>`: the tool in a pty pane when it is on
/// PATH, otherwise the install hint for this platform.
fn toolRunner(comptime bin: []const u8) CommandFn {
    return &struct {
        fn run(app: *App) CommandError!void {
            if (onPath(app, bin)) return cmd_term.termEx(app, bin);
            // // changed (bottom-row): the hint is a button, not just
            // prose. It was a diag — the message named the command and
            // then went away, leaving the user to retype it.
            const action: app_mod.ToastAction = .{ .run_in_terminal = .{
                .label = try app.gpa.dupe(u8, "Install"),
                .cmd = try std.fmt.allocPrint(app.gpa, "{s}{s}", .{ installHintPrefix(), bin }),
            } };
            errdefer action.deinit(app.gpa);
            try app.toastWithAction(.warn, action, "{s} is not on PATH — {s}{s}", .{ bin, installHintPrefix(), bin });
        }
    }.run;
}

/// The package manager's install verb for this platform — the hint a
/// missing tool's toast ends with (`brew install <bin>`). Launchers
/// (`app/launchers.zig`) give the same one.
pub fn installHintPrefix() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "brew install ",
        .windows => "winget install ",
        else => "sudo apt install ",
    };
}

/// Whether `bin` resolves through `$PATH`.
pub fn onPath(app: *App, bin: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return os_path.which(app.io, &app.env, &buf, bin) != null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const event = @import("../core/event.zig");

test "an offer runs in a VISIBLE pane, the chord takes the newest one, and an unclaimed offer is freed" {
    // A real pty and a login shell: POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();

    // Nothing offering anything: the chord says so rather than acting.
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"toast.run_action" }));

    try app.toastWithAction(.warn, .{ .run_in_terminal = .{
        .label = try app.gpa.dupe(u8, "Install"),
        .cmd = try app.gpa.dupe(u8, "printf hi"),
    } }, "missing: nothing-at-all (printf hi)", .{});
    try t.expectEqualStrings("Install", app.toasts.items[app.toasts.items.len - 1].action.?.label());
    // The view the box paints carries the label.
    const shown = try app.visibleToasts(app.frame.allocator());
    try t.expectEqualStrings("Install", shown[0].action.?);

    // The chord takes it: a VISIBLE pane, titled with the command, not
    // a silent background install. The box goes with it.
    try command.run(&app, .{ .static = .@"toast.run_action" });
    try t.expectEqualStrings("printf hi", app.panes.get(app.active.?).?.title());
    for (app.toasts.items) |item| try t.expect(item.action == null);

    // An offer attached to a message that never landed is freed, not
    // leaked — the testing allocator is the check.
    app.in_global = true;
    try app.toastWithAction(.warn, .{ .marketplace = .{
        .label = try app.gpa.dupe(u8, "Marketplace"),
        .id = try app.gpa.dupe(u8, "jira"),
    } }, "swallowed inside :g", .{});
    app.in_global = false;
    // So is one replaced by a second offer on the same message.
    try app.toastWithAction(.info, .{ .marketplace = .{
        .label = try app.gpa.dupe(u8, "Marketplace"),
        .id = try app.gpa.dupe(u8, "jira"),
    } }, "same text twice", .{});
    try app.toastWithAction(.info, .{ .marketplace = .{
        .label = try app.gpa.dupe(u8, "Marketplace"),
        .id = try app.gpa.dupe(u8, "bitbucket"),
    } }, "same text twice", .{});
}

test "keys.doctor opens the wizard on its Keyboard section" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"keys.doctor" });
    try t.expect(app.overlay == .wizard);
    try t.expect(app.overlay.wizard.ui.section == .keyboard);
    try t.expect(app.focus == .overlay);
}

test "the Codex glyph editor and the integration auto-updater are cut: each fails with the ledger toast" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    const ids = [_]command.CommandId{
        .@"integrations.edit_codex_glyph",
        .@"integrations.check_updates_now",
        .@"integrations.fire_auto_updates_now",
    };
    for (ids) |id| {
        try t.expectError(error.Failed, command.run(&app, .{ .static = id }));
        try t.expect(std.mem.startsWith(u8, app.lastToast().?, "not in mnml-zig: "));
        try t.expect(std.mem.indexOf(u8, app.lastToast().?, "docs/PARITY.md") != null);
    }
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "auto_update_*") != null);
}

test "small commands: recent jumps, scratch from the register, fold navigation, gf, char info, the registers picker, tools on PATH" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\n  two\nthree\nfour\nfive\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "see a.txt:2:3 here\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b);
    _ = try app.openPath(a);
    _ = try app.openPath(b);
    // recent_1 is the older of the two.
    try command.run(&app, .{ .static = .@"file.open_recent_1" });
    try t.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"file.open_recent_9" }));
    // Folds: two closed folds, zj / zk walk them.
    const e = app.activeEditor().?;
    try e.buf.editor.folds.put(t.allocator, 1, 2);
    try e.buf.editor.folds.put(t.allocator, 3, 4);
    e.buf.editor.setCursor(0);
    try command.run(&app, .{ .static = .@"editor.fold_next" });
    try t.expectEqual(@as(usize, 1), e.buf.editor.rowCol().row);
    try t.expectEqual(@as(usize, 2), e.buf.editor.rowCol().col); // first non-blank
    try command.run(&app, .{ .static = .@"editor.fold_next" });
    try t.expectEqual(@as(usize, 3), e.buf.editor.rowCol().row);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.fold_next" }));
    try command.run(&app, .{ .static = .@"editor.fold_prev" });
    try t.expectEqual(@as(usize, 1), e.buf.editor.rowCol().row);
    // char info on 't' of "two".
    try command.run(&app, .{ .static = .@"editor.char_info" });
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "<t> U+0074 dec 116"));
    try command.run(&app, .{ .static = .@"editor.file_stats" });
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "5 lines, 5 words") != null);
    // gf on `a.txt:2:3` inside b.txt lands on row 2, col 3.
    _ = try app.openPath(b);
    app.activeEditor().?.buf.editor.setCursor(5);
    try command.run(&app, .{ .static = .@"editor.open_at_cursor" });
    try t.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());
    try t.expectEqual(@as(usize, 1), app.activeEditor().?.buf.editor.rowCol().row);
    try t.expectEqual(@as(usize, 2), app.activeEditor().?.buf.editor.rowCol().col);
    // The registers picker inserts what it holds.
    try app.clipboard.set("pasted", false);
    try command.run(&app, .{ .static = .@"scratch.from_clipboard" });
    try t.expectEqualStrings("pasted", app.activeEditor().?.buf.editor.bytes()[0..6]);
    try command.run(&app, .{ .static = .@"picker.clipboard" });
    try t.expect(app.overlay == .picker);
    try t.expectEqualStrings("\"  pasted", app.overlay.picker.labels[0]);
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expectEqualStrings("pastedpasted", app.activeEditor().?.buf.editor.bytes()[0..12]);
    // Toasts: dismiss expires them; the tick sweeps.
    try t.expect(app.toasts.items.len > 0);
    try command.run(&app, .{ .static = .@"toast.dismiss_all" });
    try app.tick(app.now_ms + 1);
    try t.expectEqual(@as(usize, 0), app.toasts.items.len);
    // Tools: a fake PATH with only `htop` in it.
    try tmp.dir.createDirPath(t.io, "bin");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bin/htop", .data = "#!/bin/sh\n" });
    const bin = try std.fs.path.join(t.allocator, &.{ root, "bin" });
    defer t.allocator.free(bin);
    try app.env.put("PATH", bin);
    try t.expect(onPath(&app, "htop"));
    try t.expect(!onPath(&app, "btop"));
    // // changed (bottom-row): the miss is a toast carrying an
    // ` Install ` button, not a bare diag — the hint used to name the
    // command and then fade, leaving the user to retype it.
    try command.run(&app, .{ .static = .@"tools.btop" });
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "btop is not on PATH") != null);
    const offer = app.toasts.items[app.toasts.items.len - 1].action.?;
    try t.expectEqualStrings("Install", offer.label());
    try t.expect(std.mem.endsWith(u8, offer.run_in_terminal.cmd, "btop"));
    app.dismissToasts();
    // Recent commands picker re-runs the newest command; the picker
    // itself is not in its own list.
    try command.run(&app, .{ .static = .@"view.toggle_line_numbers" });
    const before = app.cfg.ui.line_numbers;
    try command.run(&app, .{ .static = .@"picker.recent_commands" });
    try t.expectEqualStrings("Recent commands", app.overlay.picker.state.title);
    try t.expect(std.mem.endsWith(u8, app.overlay.picker.labels[0], "  ·  view.toggle_line_numbers"));
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.cfg.ui.line_numbers != before);
    try t.expectEqualStrings("view.toggle_line_numbers", app.recent_commands.items[0]);
    for (app.recent_commands.items) |id| try t.expect(!std.mem.eql(u8, id, "picker.recent_commands"));
    // A cut id says so, and names the ledger.
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"sonos.play_pause" }));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "docs/PARITY.md") != null);
    // focus.cycle walks tree → pane → tree with no right panel.
    app.tree.visible = true;
    app.focus = .tree;
    try command.run(&app, .{ .static = .@"focus.cycle" });
    try t.expect(app.focus == .pane);
    try command.run(&app, .{ .static = .@"focus.cycle" });
    try t.expect(app.focus == .tree);
}
