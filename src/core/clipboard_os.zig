//! The OS clipboard sink — where `"+` / `"*` go, and where they read from.
//! Independent of `App`: a `Sink` is a terminal writer (OSC 52), a pair
//! of command lines (pbcopy / wl-copy / xclip / xsel / clip.exe), or
//! nothing. `select` is the pure chain that turns `editor.clipboard` +
//! what the session has into one of those; `probe` finds the tool.
//!
//! OSC 52 is write-only: no terminal answers a `?` query without a user
//! prompt, so a read through that sink returns null and the register
//! layer falls back to its own copy. A tool sink reads by spawning the
//! paste half of the pair.
//!
//! Nothing here runs on its own. A headless session, a `.test` run and
//! every unit test hold `Sink.none` unless they install something —
//! `probe` only ever touches `$PATH`, never the clipboard.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `Config.Editor.clipboard`'s type — the enum lives with the config so
/// `:set clipboard=` and the settings row see it like any other field.
pub const Mode = @import("../config/Config.zig").Clipboard;

/// A copy/paste command pair. The slices are static for the shipped
/// tools; a test may point them at scripts of its own.
pub const Tool = struct {
    name: []const u8,
    copy: []const []const u8,
    /// Empty when the tool cannot read back.
    paste: []const []const u8,

    pub const pbcopy: Tool = .{ .name = "pbcopy", .copy = &.{"pbcopy"}, .paste = &.{"pbpaste"} };
    pub const wayland: Tool = .{ .name = "wl-copy", .copy = &.{"wl-copy"}, .paste = &.{ "wl-paste", "--no-newline" } };
    pub const xclip: Tool = .{ .name = "xclip", .copy = &.{ "xclip", "-selection", "clipboard" }, .paste = &.{ "xclip", "-selection", "clipboard", "-o" } };
    pub const xsel: Tool = .{ .name = "xsel", .copy = &.{ "xsel", "--clipboard", "--input" }, .paste = &.{ "xsel", "--clipboard", "--output" } };
    pub const windows: Tool = .{ .name = "clip.exe", .copy = &.{"clip.exe"}, .paste = &.{ "powershell", "-NoProfile", "-Command", "Get-Clipboard" } };
};

pub const Sink = union(enum) {
    none,
    /// The terminal session's buffered stdout — the writer the renderer
    /// uses, so the sequence never lands inside a frame.
    osc52: *Io.Writer,
    tool: Tool,

    pub fn canRead(s: Sink) bool {
        return switch (s) {
            .tool => |t| t.paste.len > 0,
            else => false,
        };
    }
};

/// The chain. `live` is the terminal writer when there is a real
/// session; `tool` is what `probe` found (or what a test hands in).
pub fn select(mode: Mode, live: ?*Io.Writer, tool: ?Tool) Sink {
    return switch (mode) {
        .internal => .none,
        .auto => if (live) |w| .{ .osc52 = w } else if (tool) |t| .{ .tool = t } else .none,
        .os => if (tool) |t| .{ .tool = t } else if (live) |w| .{ .osc52 = w } else .none,
    };
}

/// The first tool of this platform's list that resolves through `$PATH`.
/// Wayland's pair is only offered under a Wayland session; X11's two are
/// tried in order after it.
pub fn probe(io: Io, env: *const std.process.Environ.Map) ?Tool {
    switch (builtin.os.tag) {
        .macos => return if (onPath(io, env, "pbcopy")) Tool.pbcopy else null,
        .windows => return if (onPath(io, env, "clip.exe") or onPath(io, env, "clip")) Tool.windows else null,
        else => {
            if (env.get("WAYLAND_DISPLAY") != null and onPath(io, env, "wl-copy")) return Tool.wayland;
            if (onPath(io, env, "xclip")) return Tool.xclip;
            if (onPath(io, env, "xsel")) return Tool.xsel;
            return null;
        },
    }
}

fn onPath(io: Io, env: *const std.process.Environ.Map, bin: []const u8) bool {
    const path = env.get("PATH") orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, bin }) catch continue;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

pub const WriteError = Io.Writer.Error || std.process.SpawnError || error{ToolFailed};

/// Push `text` to the OS. `.none` is a no-op. Best-effort by design:
/// the register layer keeps its own copy whatever happens here.
pub fn write(sink: Sink, io: Io, text: []const u8) WriteError!void {
    switch (sink) {
        .none => {},
        .osc52 => |w| {
            try writeOsc52(w, text);
            try w.flush();
        },
        .tool => |t| try toolWrite(io, t, text),
    }
}

/// `ESC ] 52 ; c ; <base64> BEL`, streamed three bytes at a time so no
/// buffer is sized to the text.
pub fn writeOsc52(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    const enc = std.base64.standard.Encoder;
    try w.writeAll("\x1b]52;c;");
    var i: usize = 0;
    var quad: [4]u8 = undefined;
    while (i < text.len) : (i += 3) {
        const chunk = text[i..@min(i + 3, text.len)];
        try w.writeAll(enc.encode(&quad, chunk));
    }
    try w.writeAll("\x07");
}

/// What the OS holds, gpa-owned, or null when this sink cannot read
/// (`.none`, OSC 52) or the tool failed.
pub fn read(sink: Sink, io: Io, gpa: Allocator) ?[]u8 {
    return switch (sink) {
        .tool => |t| if (t.paste.len > 0) toolRead(io, gpa, t) else null,
        else => null,
    };
}

fn toolWrite(io: Io, tool: Tool, text: []const u8) WriteError!void {
    var child = try std.process.spawn(io, .{ .argv = tool.copy, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
    if (child.stdin) |stdin| {
        var wbuf: [4096]u8 = undefined;
        var w: Io.File.Writer = .init(stdin, io, &wbuf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        stdin.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return error.ToolFailed;
    if (term != .exited or term.exited != 0) return error.ToolFailed;
}

fn toolRead(io: Io, gpa: Allocator, tool: Tool) ?[]u8 {
    var child = std.process.spawn(io, .{ .argv = tool.paste, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    if (child.stdout) |stdout| {
        var rbuf: [4096]u8 = undefined;
        var r: Io.File.Reader = .init(stdout, io, &rbuf);
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            out.appendSlice(gpa, chunk[0..n]) catch {
                out.deinit(gpa);
                _ = child.wait(io) catch {};
                return null;
            };
        }
    }
    const term = child.wait(io) catch {
        out.deinit(gpa);
        return null;
    };
    if (term != .exited or term.exited != 0) {
        out.deinit(gpa);
        return null;
    }
    // Get-Clipboard prints the text as a line: one CRLF it did not hold.
    if (builtin.os.tag == .windows and std.mem.endsWith(u8, out.items, "\r\n")) out.items.len -= 2;
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "osc52: the writer receives exactly ESC ] 52 ; c ; base64 BEL" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(.{ .osc52 = &aw.writer }, testing.io, "hello, world");
    try testing.expectEqualStrings("\x1b]52;c;aGVsbG8sIHdvcmxk\x07", aw.written());
}

test "osc52: base64 of the empty string and of multi-line text, padded" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeOsc52(&aw.writer, "");
    try testing.expectEqualStrings("\x1b]52;c;\x07", aw.written());
    aw.clearRetainingCapacity();
    try writeOsc52(&aw.writer, "one\ntwo\n");
    try testing.expectEqualStrings("\x1b]52;c;b25lCnR3bwo=\x07", aw.written());
    aw.clearRetainingCapacity();
    // A length that is not a multiple of three lands on the two-pad case.
    try writeOsc52(&aw.writer, "a");
    try testing.expectEqualStrings("\x1b]52;c;YQ==\x07", aw.written());
}

test "select: every mode against live / not live and tool / no tool" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const live: ?*Io.Writer = &aw.writer;
    const tool: ?Tool = Tool.pbcopy;
    const Want = enum { none, osc52, tool };
    const cases = [_]struct { mode: Mode, live: ?*Io.Writer, tool: ?Tool, want: Want }{
        .{ .mode = .auto, .live = live, .tool = tool, .want = .osc52 },
        .{ .mode = .auto, .live = live, .tool = null, .want = .osc52 },
        .{ .mode = .auto, .live = null, .tool = tool, .want = .tool },
        .{ .mode = .auto, .live = null, .tool = null, .want = .none },
        .{ .mode = .os, .live = live, .tool = tool, .want = .tool },
        .{ .mode = .os, .live = live, .tool = null, .want = .osc52 },
        .{ .mode = .os, .live = null, .tool = tool, .want = .tool },
        .{ .mode = .os, .live = null, .tool = null, .want = .none },
        .{ .mode = .internal, .live = live, .tool = tool, .want = .none },
        .{ .mode = .internal, .live = live, .tool = null, .want = .none },
        .{ .mode = .internal, .live = null, .tool = tool, .want = .none },
        .{ .mode = .internal, .live = null, .tool = null, .want = .none },
    };
    for (cases) |c| {
        const got: Want = switch (select(c.mode, c.live, c.tool)) {
            .none => .none,
            .osc52 => .osc52,
            .tool => .tool,
        };
        try testing.expectEqual(c.want, got);
    }
    // `.none` and OSC 52 cannot read; a tool with a paste half can.
    try testing.expect(!Sink.canRead(.none));
    try testing.expect(!Sink.canRead(.{ .osc52 = live.? }));
    try testing.expect(Sink.canRead(.{ .tool = Tool.pbcopy }));
    try testing.expect(!Sink.canRead(.{ .tool = .{ .name = "w", .copy = &.{"true"}, .paste = &.{} } }));
    try testing.expect(read(.none, testing.io, testing.allocator) == null);
    try testing.expect(read(.{ .osc52 = live.? }, testing.io, testing.allocator) == null);
}

test "probe: finds a tool only through $PATH, and nothing on an empty one" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "");
    try testing.expect(probe(testing.io, &env) == null);
    if (builtin.os.tag == .windows) return;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const bin = switch (builtin.os.tag) {
        .macos => "pbcopy",
        else => "xclip",
    };
    try tmp.dir.writeFile(testing.io, .{ .sub_path = bin, .data = "#!/bin/sh\n" });
    try env.put("PATH", root);
    try testing.expectEqualStrings(bin, probe(testing.io, &env).?.name);
}

test "tool: a copy/paste pair round-trips through the spawned commands" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const copy_sh = try std.fs.path.join(testing.allocator, &.{ root, "copy.sh" });
    defer testing.allocator.free(copy_sh);
    const paste_sh = try std.fs.path.join(testing.allocator, &.{ root, "paste.sh" });
    defer testing.allocator.free(paste_sh);
    const store = try std.fs.path.join(testing.allocator, &.{ root, "store" });
    defer testing.allocator.free(store);
    const copy_src = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\ncat > '{s}'\n", .{store});
    defer testing.allocator.free(copy_src);
    const paste_src = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\ncat '{s}'\n", .{store});
    defer testing.allocator.free(paste_src);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "copy.sh", .data = copy_src });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "paste.sh", .data = paste_src });
    const tool: Tool = .{ .name = "fake", .copy = &.{ "/bin/sh", copy_sh }, .paste = &.{ "/bin/sh", paste_sh } };
    const sink: Sink = .{ .tool = tool };
    try write(sink, testing.io, "round\ntrip\n");
    const got = read(sink, testing.io, testing.allocator).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("round\ntrip\n", got);
    // A failing copy half is an error, not a silent drop.
    const bad: Sink = .{ .tool = .{ .name = "bad", .copy = &.{ "/bin/sh", "-c", "exit 3" }, .paste = &.{ "/bin/sh", "-c", "exit 3" } } };
    try testing.expectError(error.ToolFailed, write(bad, testing.io, "x"));
    try testing.expect(read(bad, testing.io, testing.allocator) == null);
}
