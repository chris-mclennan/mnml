//! Tier 2 — the file-IPC channel every mnml-spawned process can write
//! to, mount or not: one JSON line per command appended to
//! `$MNML_IPC_DIR/command`. Fire-and-forget; mnml acks in
//! `events.jsonl`. The shapes are mnml's `ipc/command.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const dir_env = "MNML_IPC_DIR";

pub const ToastLevel = enum { info, warn, @"error" };
pub const ProgressStatus = enum { success, failed, cancelled };
pub const Side = enum { left, right };

pub const Segment = struct {
    id: []const u8,
    side: Side = .right,
    text: []const u8,
    color: ?[]const u8 = null,
    click_command: ?[]const u8 = null,
    priority: u8 = 100,
    min_width: u16 = 4,
    max_width: u16 = 30,
    /// The hover text: what this number counts, and its breakdown. A
    /// chip that says `󰂨 4(2)` and nothing else makes the reader guess.
    tooltip: ?[]const u8 = null,
    /// The things behind the figure — the hover lists them under the
    /// tooltip line, and a click on a row runs its `command`. The
    /// design-language rule: a statusline figure's hover lists what it
    /// counts. Leave it empty and the chip keeps the one-line hover.
    items: []const Item = &.{},
};

/// One thing behind a figure: a pull request, a ticket, a pipeline.
/// `text` is what it is; `sub` is where it lives or how old it is,
/// painted muted and right-aligned; `command` is the command id a
/// click on the row runs, with `args` appended to its argv when that
/// command mounts a binary.
pub const Item = struct {
    text: []const u8,
    sub: []const u8 = "",
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

/// One row of a link range table (`Ipc.linkRanges`): the numbers a
/// repo is currently using for one kind of thing. `repo` is what goes
/// into a `.range` link's `{repo}` (`acme/widget`); `kind` is what a
/// link's `ranges` names (`pr`, `pipeline`); `low`..`high` is every
/// number the integration has seen there. mnml adds its own slack above
/// `high`, so a number created since the last poll still resolves.
pub const LinkRange = struct {
    repo: []const u8,
    kind: []const u8,
    low: u64,
    high: u64,
};

pub const Error = error{ NoChannel, WriteFailed } || Allocator.Error;

/// How a pane names the session it wants focused.
pub const SessionSelector = struct {
    /// The host's own id, when the pane was told one.
    id: []const u8 = "",
    /// Failing that: the directory the session runs in…
    cwd: []const u8 = "",
    /// …and the first line of the prompt it was started with, which is
    /// what a dispatched `term` line puts on screen.
    prompt_line: []const u8 = "",
};

pub const Ipc = struct {
    gpa: Allocator,
    io: Io,
    /// `<dir>/command`, owned.
    path: []u8,

    /// From `MNML_IPC_DIR`; null when not launched by mnml.
    pub fn fromEnv(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!?Ipc {
        const dir = env.get(dir_env) orelse return null;
        if (dir.len == 0) return null;
        return try init(gpa, io, dir);
    }

    pub fn init(gpa: Allocator, io: Io, dir: []const u8) Allocator.Error!Ipc {
        return .{ .gpa = gpa, .io = io, .path = try std.fs.path.join(gpa, &.{ dir, "command" }) };
    }

    pub fn deinit(self: *Ipc) void {
        self.gpa.free(self.path);
    }

    /// Append one command line. `payload` is any struct with a `cmd`.
    pub fn line(self: *const Ipc, payload: anytype) Error!void {
        const json = try std.json.Stringify.valueAlloc(self.gpa, payload, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(json);
        const text = try std.mem.concat(self.gpa, u8, &.{ json, "\n" });
        defer self.gpa.free(text);
        const file = Io.Dir.cwd().createFile(self.io, self.path, .{ .read = true, .truncate = false }) catch return error.WriteFailed;
        defer file.close(self.io);
        const end = file.length(self.io) catch return error.WriteFailed;
        file.writePositionalAll(self.io, text, end) catch return error.WriteFailed;
    }

    pub fn registerCommand(self: *const Ipc, id: []const u8, title: []const u8, group: []const u8, keys: []const []const u8) Error!void {
        return self.line(.{ .cmd = "register-command", .id = id, .title = title, .group = group, .keys = keys });
    }

    pub fn toast(self: *const Ipc, level: ToastLevel, text: []const u8) Error!void {
        return self.line(.{ .cmd = "toast", .text = text, .level = level });
    }

    pub fn toastPersistent(self: *const Ipc, id: []const u8, level: ToastLevel, text: []const u8) Error!void {
        return self.line(.{ .cmd = "toast-persistent", .id = id, .text = text, .level = level });
    }

    pub fn toastDismiss(self: *const Ipc, id: []const u8) Error!void {
        return self.line(.{ .cmd = "toast-dismiss", .id = id });
    }

    pub fn progressStart(self: *const Ipc, id: []const u8, label: []const u8) Error!void {
        return self.line(.{ .cmd = "progress-start", .id = id, .text = label });
    }

    pub fn progressUpdate(self: *const Ipc, id: []const u8, label: ?[]const u8, percent: ?u8) Error!void {
        return self.line(.{ .cmd = "progress-update", .id = id, .text = label, .count = percent });
    }

    pub fn progressEnd(self: *const Ipc, id: []const u8, status: ProgressStatus) Error!void {
        return self.line(.{ .cmd = "progress-end", .id = id, .text = status });
    }

    pub fn statuslineSetSegment(self: *const Ipc, seg: Segment) Error!void {
        // A chip with nothing behind it sends no `items` key at all:
        // the line an older SDK wrote stays byte for byte what it was.
        if (seg.items.len == 0) return self.line(.{
            .cmd = "statusline-set-segment",
            .id = seg.id,
            .side = seg.side,
            .text = seg.text,
            .color = seg.color,
            .click_command = seg.click_command,
            .priority = seg.priority,
            .min_width = seg.min_width,
            .max_width = seg.max_width,
            .tooltip = seg.tooltip,
        });
        return self.line(.{
            .cmd = "statusline-set-segment",
            .id = seg.id,
            .side = seg.side,
            .text = seg.text,
            .color = seg.color,
            .click_command = seg.click_command,
            .priority = seg.priority,
            .min_width = seg.min_width,
            .max_width = seg.max_width,
            .tooltip = seg.tooltip,
            .items = seg.items,
        });
    }

    /// Replace this integration's link range table — every row, each
    /// poll; `id` is the manifest id whose `.range` links read it. An
    /// empty table clears it.
    pub fn linkRanges(self: *const Ipc, id: []const u8, rows: []const LinkRange) Error!void {
        return self.line(.{ .cmd = "link-ranges", .id = id, .ranges = rows });
    }

    pub fn statuslineClearSegment(self: *const Ipc, id: []const u8) Error!void {
        return self.line(.{ .cmd = "statusline-clear-segment", .id = id });
    }

    /// `section`: explorer, search, git, debug, integrations, sessions, agents, cloud_agents.
    pub fn setActivityBadge(self: *const Ipc, section: []const u8, count: u32) Error!void {
        return self.line(.{ .cmd = "set-activity-badge", .section = section, .count = count });
    }

    /// Bring a session mnml is running to the front — what a `[ view ]`
    /// button asks for after its dispatch started one. The host matches
    /// the session by the id it gave, else by the working directory and
    /// the prompt's first line, which is what a dispatched `term` line
    /// can actually name.
    pub fn focusSession(self: *const Ipc, sel: SessionSelector) Error!void {
        try self.line(.{
            .cmd = "focus-session",
            .id = if (sel.id.len > 0) sel.id else null,
            .cwd = if (sel.cwd.len > 0) sel.cwd else null,
            .prompt_line = if (sel.prompt_line.len > 0) sel.prompt_line else null,
        });
    }

    pub fn notify(self: *const Ipc, title: []const u8, body: []const u8, level: ToastLevel, sound: bool) Error!void {
        return self.line(.{ .cmd = "notify", .title = title, .text = body, .level = level, .sound = sound });
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "lines append to <dir>/command in mnml's shape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var ipc = try Ipc.init(testing.allocator, testing.io, dir);
    defer ipc.deinit();
    try ipc.toast(.warn, "hi");
    try ipc.registerCommand("hello.pick", "Hello: pick", "integrations", &.{"ctrl+k h"});
    try ipc.progressUpdate("p", null, 40);
    try ipc.statuslineSetSegment(.{ .id = "s", .text = "T" });
    try ipc.setActivityBadge("integrations", 3);
    try ipc.linkRanges("forge", &.{.{ .repo = "acme/widget", .kind = "pr", .low = 5490, .high = 5512 }});
    const got = try tmp.dir.readFileAlloc(testing.io, "command", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "{\"cmd\":\"toast\",\"text\":\"hi\",\"level\":\"warn\"}\n" ++
            "{\"cmd\":\"register-command\",\"id\":\"hello.pick\",\"title\":\"Hello: pick\",\"group\":\"integrations\",\"keys\":[\"ctrl+k h\"]}\n" ++
            "{\"cmd\":\"progress-update\",\"id\":\"p\",\"count\":40}\n" ++
            "{\"cmd\":\"statusline-set-segment\",\"id\":\"s\",\"side\":\"right\",\"text\":\"T\",\"priority\":100,\"min_width\":4,\"max_width\":30}\n" ++
            "{\"cmd\":\"set-activity-badge\",\"section\":\"integrations\",\"count\":3}\n" ++
            "{\"cmd\":\"link-ranges\",\"id\":\"forge\",\"ranges\":[{\"repo\":\"acme/widget\",\"kind\":\"pr\",\"low\":5490,\"high\":5512}]}\n",
        got,
    );
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect((try Ipc.fromEnv(testing.allocator, testing.io, &env)) == null);
}
