//! `:messages` — the toast history. Every toast the app raises is
//! recorded here (`App.toastLevel` calls `record`), capped at `max`
//! entries, oldest dropped first. `messages.show` opens a picker over
//! the log newest first; `:messages!` (`dump`) writes the whole log into
//! a scratch buffer; the statusline bell (`app/statusline.zig`) counts the
//! warnings and errors nobody has looked at yet.
//!
//! The log rides along in `session.zon`, so a warning raised just
//! before a restart is still there after it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");

pub const Level = app_mod.ToastLevel;

pub const Message = struct {
    /// Owned.
    text: []u8,
    level: Level,
    /// `App.now_ms` when it was raised (the awake clock).
    at_ms: i64,
};

pub const max: usize = 200;

pub const State = struct {
    items: std.ArrayListUnmanaged(Message) = .empty,
    /// Entries before this index have been seen in the picker.
    read_upto: usize = 0,

    pub fn deinit(self: *State, gpa: Allocator) void {
        for (self.items.items) |m| gpa.free(m.text);
        self.items.deinit(gpa);
    }

    /// Append one entry; the oldest goes when the log is full.
    pub fn record(self: *State, gpa: Allocator, text: []const u8, level: Level, now_ms: i64) Allocator.Error!void {
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        if (self.items.items.len >= max) {
            gpa.free(self.items.orderedRemove(0).text);
            self.read_upto -|= 1;
        }
        try self.items.append(gpa, .{ .text = copy, .level = level, .at_ms = now_ms });
    }

    pub fn clear(self: *State, gpa: Allocator) void {
        for (self.items.items) |m| gpa.free(m.text);
        self.items.clearRetainingCapacity();
        self.read_upto = 0;
    }

    pub fn markRead(self: *State) void {
        self.read_upto = self.items.items.len;
    }

    pub const Unread = struct { warn: u32 = 0, err: u32 = 0 };

    pub fn unread(self: *const State) Unread {
        var u: Unread = .{};
        for (self.items.items[@min(self.read_upto, self.items.items.len)..]) |m| switch (m.level) {
            .warn => u.warn += 1,
            .err => u.err += 1,
            .info => {},
        };
        return u;
    }
};

pub const table = .{
    .@"messages.show" = &show,
    .@"messages.clear" = &clearCmd,
};

fn tag(level: Level) []const u8 {
    return switch (level) {
        .info => "info",
        .warn => "warn",
        .err => "error",
    };
}

/// `messages.show`: the log newest first, `<level>  <text>` with the
/// age as the detail. Opening it marks everything read.
fn show(app: *App) CommandError!void {
    const gpa = app.gpa;
    const st = &app.messages;
    if (st.items.items.len == 0) return app.diag.fail(app.frame.allocator(), "no messages yet", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    var i = st.items.items.len;
    while (i > 0) {
        i -= 1;
        const m = st.items.items[i];
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  {s}", .{ tag(m.level), m.text }));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{d}s ago", .{@divTrunc(@max(app.now_ms - m.at_ms, 0), 1000)}));
    }
    st.markRead();
    try cmd_picker.openPickerWith(app, "Messages", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &accept;
}

/// Enter on a row raises it again as a toast, so a message that
/// expired can be read at leisure.
fn accept(app: *App, idx: usize, label: []const u8) Allocator.Error!void {
    _ = idx;
    const sep = std.mem.indexOf(u8, label, "  ") orelse return;
    app.toast("{s}", .{label[sep + 2 ..]});
}

fn clearCmd(app: *App) CommandError!void {
    const n = app.messages.items.items.len;
    app.messages.clear(app.gpa);
    app.toast("messages: cleared {d}", .{n});
}

/// `:messages!` — the whole log into a scratch buffer, oldest first.
pub fn dump(app: *App) CommandError!void {
    const st = &app.messages;
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    for (st.items.items) |m| out.writer.print("{s: <5} {s}\n", .{ tag(m.level), m.text }) catch return error.OutOfMemory;
    if (st.items.items.len == 0) out.writer.writeAll("(no messages)\n") catch return error.OutOfMemory;
    const id = app.openScratch() catch return error.OutOfMemory;
    const e = app.panes.editor(id) orelse return;
    try e.buf.editor.setText(out.written());
    e.buf.editor.setCursor(0);
    st.markRead();
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// The screen after a frame, on the frame arena — the bell chip is on
/// the statusline (`app/statusline.zig`), the count beside the glyph.
fn bellRow(app: *App) ![]const u8 {
    try app.render();
    return @import("../ipc/screen.zig").toTestText(app.frame.allocator(), &app.screen);
}

test "messages: every toast is recorded, capped, and the bell counts unread warn/err only" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 80, .rows = 20 });
    defer app.deinit();
    app.toast("plain", .{});
    try t.expectEqual(@as(usize, 1), app.messages.items.items.len);
    try t.expectEqual(@as(usize, 0), app.messages.unread().warn + app.messages.unread().err);
    try t.expect(std.mem.indexOf(u8, try bellRow(&app), " \u{f0f3}  ") != null); // the quiet bell, no count
    try app.toastLevel(.warn, "careful", .{});
    try t.expectEqual(@as(usize, 1), app.messages.unread().warn);
    try t.expect(std.mem.indexOf(u8, try bellRow(&app), " \u{f0f3} 1 ") != null);
    try app.toastLevel(.err, "broken", .{});
    try t.expectEqual(@as(usize, 1), app.messages.unread().err);
    try t.expect(std.mem.indexOf(u8, try bellRow(&app), " \u{f0f3} 2 ") != null);
    // The picker marks everything read and lists newest first.
    try command.run(&app, .{ .static = .@"messages.show" });
    try t.expect(app.overlay == .picker);
    try t.expectEqualStrings("error  broken", app.overlay.picker.labels[0]);
    try t.expectEqual(@as(usize, 0), app.messages.unread().warn + app.messages.unread().err);
    app.overlay.deinit(app.gpa);
    // The cap drops the oldest.
    var i: usize = 0;
    while (i < max + 5) : (i += 1) app.toast("n{d}", .{i});
    try t.expectEqual(max, app.messages.items.items.len);
    try t.expectEqualStrings("n5", app.messages.items.items[0].text);
    // `:messages!` dumps into a scratch buffer.
    try dump(&app);
    try t.expect(std.mem.indexOf(u8, app.activeEditor().?.buf.editor.bytes(), "info  n5\n") != null);
    try command.run(&app, .{ .static = .@"messages.clear" });
    try t.expectEqual(@as(usize, 1), app.messages.items.items.len); // the "cleared" toast itself
}
