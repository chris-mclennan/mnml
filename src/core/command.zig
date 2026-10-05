//! The command registry (D5, D10.1). `CommandId` is an enum derived at
//! comptime from `commands/specs.zig`, so a menu item, a keybinding or a
//! `.test` step cannot name a command that does not exist. Runners are
//! merged at comptime from each subsystem's `pub const table`; with
//! `-Dpartial=false` a spec without a runner is a compile error.
//!
//! Errors (D2): a command returns `CommandError!void`. A user-facing
//! reason goes in `app.diag` right before `error.Failed`; `run` toasts
//! `diag.msg` (or `<title>: <@errorName>`) and returns the error so the
//! `.test` runner and IPC see the failure too.

const std = @import("std");
const compat = @import("mnml_sdk").zig_compat;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const specs = @import("../commands/specs.zig");
const keymap = @import("keymap.zig");
const key_mod = @import("key.zig");
const panel = @import("panel.zig");
const App = @import("../app.zig").App;

pub const Spec = specs.Spec;
pub const Keys = specs.Keys;

pub const CommandError = error{
    NoActivePane,
    NotAnEditor,
    NoWorkspace,
    NoRepo,
    NoSelection,
    Unsupported,
    Canceled,
    Failed,
} || Allocator.Error || std.Io.Cancelable;

pub const CommandFn = *const fn (*App) CommandError!void;

/// The one place a command explains itself. `msg` is frame-arena memory,
/// valid until the next loop iteration.
pub const Diag = struct {
    msg: ?[]const u8 = null,

    pub fn clear(d: *Diag) void {
        d.msg = null;
    }

    /// Record a reason and return `error.Failed` in one expression:
    /// `return app.diag.fail(arena, "no TODO at row {d}", .{row});`
    pub fn fail(d: *Diag, arena: Allocator, comptime fmt: []const u8, args: anytype) error{Failed} {
        d.msg = std.fmt.allocPrint(arena, fmt, args) catch null;
        return error.Failed;
    }
};

// ─── the static registry ────────────────────────────────────────────────

pub const CommandId = blk: {
    @setEvalBranchQuota(200_000);
    var names: [specs.specs.len][]const u8 = undefined;
    for (specs.specs, 0..) |s, i| names[i] = s.id;
    break :blk @Enum(u16, .exhaustive, &names, &std.simd.iota(u16, specs.specs.len));
};

pub const count = specs.specs.len;

pub const by_name: std.StaticStringMap(CommandId) = blk: {
    @setEvalBranchQuota(400_000);
    const KV = struct { []const u8, CommandId };
    var kvs: [count]KV = undefined;
    for (specs.specs, 0..) |s, i| kvs[i] = .{ s.id, @enumFromInt(i) };
    break :blk .initComptime(kvs);
};

pub fn spec(id: CommandId) *const Spec {
    return &specs.specs[@intFromEnum(id)];
}

pub fn title(id: CommandId) []const u8 {
    return spec(id).title;
}

pub const Effect = specs.Effect;

/// What running `ref` can change (`specs.Effect`). A command registered
/// at runtime — Lua, a manifest, the file channel — is `exec`: it runs a
/// program's code, whatever it says it does.
pub fn effect(ref: CommandRef) Effect {
    return switch (ref) {
        .static => |id| specs.effects[@intFromEnum(id)],
        .dyn => .exec,
    };
}

/// The command's short name — its row in a which-key popup — or its
/// title when the spec gives none.
pub fn shortTitle(id: CommandId) []const u8 {
    const s = spec(id);
    return if (s.short.len > 0) s.short else s.title;
}

pub fn group(id: CommandId) []const u8 {
    return spec(id).group;
}

/// The external, string form of an id — identical to the spec's `id`.
pub fn name(id: CommandId) [:0]const u8 {
    return @tagName(id);
}

/// Every subsystem that exposes runners. Adding a subsystem = adding a
/// line here; its `pub const table = .{ .@"ns.verb" = &fn, … }` is merged.
const runner_tables = .{
    @import("../todos.zig"),
    @import("../notes.zig"),
    @import("../findings.zig"),
    @import("../sessions.zig"),
    @import("../app/dock.zig"),
    @import("../app/bottom.zig"),
    @import("../app/cmd_file.zig"),
    @import("../app/cmd_buffer.zig"),
    @import("../app/cmd_editor.zig"),
    @import("../app/cmd_find.zig"),
    @import("../app/cmd_view.zig"),
    @import("../app/cmd_picker.zig"),
    @import("../app/icon_picker.zig"),
    @import("../app/cmd_app.zig"),
    @import("../app/recent_items.zig"),
    @import("../app/quickfix.zig"),
    @import("../app/cmd_tab.zig"),
    @import("../app/tree.zig"),
    @import("../app/outline.zig"),
    @import("../app/md_preview.zig"),
    @import("../app/zon_pane.zig"),
    @import("../app/snippets.zig"),
    @import("../app/context_menus.zig"),
    @import("../app/workspace_trust.zig"),
    @import("../app/settings.zig"),
    @import("../app/cheatsheet.zig"),
    @import("../app/cmd_term.zig"),
    @import("../app/pty_search.zig"),
    @import("../app/now_playing.zig"),
    @import("../app/statusline.zig"),
    @import("../app/runners.zig"),
    @import("../app/tasks.zig"),
    @import("../app/cmd_git.zig"),
    @import("../app/ai.zig"),
    @import("../app/ide.zig"),
    @import("../app/copilot.zig"),
    @import("../app/sessions_table.zig"),
    @import("../app/cloud_agents.zig"),
    @import("../app/spend.zig"),
    @import("../app/tests_pane.zig"),
    @import("../app/flaky.zig"),
    @import("../app/requests.zig"),
    @import("../app/grep.zig"),
    @import("../app/grep_picker.zig"),
    @import("../app/session_search.zig"),
    @import("../app/image_pane.zig"),
    @import("../app/jumplist.zig"),
    @import("../app/cmd_dap.zig"),
    @import("../app/debug_panel.zig"),
    @import("../app/cmd_lsp.zig"),
    @import("../app/http.zig"),
    @import("../app/cmd_http.zig"),
    @import("../app/http_panel.zig"),
    @import("../app/http_ops.zig"),
    @import("../app/ws_pane.zig"),
    @import("../app/cmd_browser.zig"),
    @import("../app/cmd_script.zig"),
    @import("../app/scripts_panel.zig"),
    @import("../app/scripts.zig"),
    @import("../app/script_doctor.zig"),
    @import("../app/messages.zig"),
    @import("../app/zen.zig"),
    @import("../app/named_layouts.zig"),
    @import("../app/cmd_harpoon.zig"),
    @import("../app/stress.zig"),
    @import("../app/clock.zig"),
    @import("../app/coverage.zig"),
    @import("../app/menu_bar.zig"),
    @import("../app/activity_bar.zig"),
    @import("../app/side.zig"),
    @import("../app/glyph_audit.zig"),
    @import("../app/update.zig"),
    @import("../app/cmd_session.zig"),
    @import("../app/startup_picker.zig"),
    @import("../app/mount_pane.zig"),
    @import("../app/integrations.zig"),
    @import("../app/integrations_tools.zig"),
    @import("../app/setup.zig"),
    @import("../app/markdown_links.zig"),
    @import("../app/bookmarks.zig"),
    @import("../app/marketplace.zig"),
    @import("../app/launchers.zig"),
    @import("../app/files_pane.zig"),
    @import("../app/file_clipboard.zig"),
    @import("../app/trash.zig"),
    @import("../app/transfers.zig"),
    @import("../app/search_section.zig"),
    @import("../app/syntax.zig"),
    @import("../app/terminal_glyph.zig"),
    @import("../app/claude_mark.zig"),
    @import("../app/sidebar_auto.zig"),
    @import("../app/launcher_dock.zig"),
    @import("../app/jobs.zig"),
    @import("../app/session_changes.zig"),
    @import("../app/session_cycle.zig"),
    @import("../app/session_numbers.zig"),
    @import("../app/sessions_mode.zig"),
    @import("../app/info_view.zig"),
};

pub const runners: std.enums.EnumArray(CommandId, ?CommandFn) = blk: {
    @setEvalBranchQuota(200_000);
    var r = std.enums.EnumArray(CommandId, ?CommandFn).initFill(null);
    for (runner_tables) |mod| {
        const T = @TypeOf(mod.table);
        for (compat.structFields(T)) |f| {
            const id = by_name.get(f.name) orelse @compileError("runner table names unknown command id `" ++ f.name ++ "`");
            if (r.get(id) != null) @compileError("two runners for `" ++ f.name ++ "`");
            r.set(id, @field(mod.table, f.name));
        }
    }
    if (!build_options.partial) {
        for (specs.specs, 0..) |s, i| {
            if (r.get(@enumFromInt(i)) == null) @compileError("command `" ++ s.id ++ "` has no runner (build with -Dpartial to allow)");
        }
    }
    break :blk r;
};

/// How many specs have a runner in this build — the parity meter.
pub const implemented: usize = blk: {
    @setEvalBranchQuota(20_000);
    var n: usize = 0;
    for (0..count) |i| {
        if (runners.get(@enumFromInt(i)) != null) n += 1;
    }
    break :blk n;
};

// ─── comptime checks ────────────────────────────────────────────────────

comptime {
    @setEvalBranchQuota(1_000_000);
    // Ids are `<namespace>.<verb>`; duplicates are rejected by the enum
    // construction itself ("duplicate enum field").
    // changed: DESIGN D5 said `group == namespace prefix` for every id.
    // In practice 140 Rust commands file under a finer palette group
    // (`picker.files` → "go", `tree.refresh` → "view"); the Rust test
    // only enforces the rule for the panel namespaces, so that is the
    // rule kept here.
    const strict_namespaces = [_][]const u8{ "todos", "notes", "findings", "sessions", "http" };
    for (specs.specs) |s| {
        const dot = std.mem.indexOfScalar(u8, s.id, '.');
        if (dot == null and !std.mem.eql(u8, s.id, "palette") and !std.mem.eql(u8, s.id, "noop"))
            @compileError("command id `" ++ s.id ++ "` is not `<namespace>.<verb>`");
        if (dot) |d| {
            for (strict_namespaces) |ns| {
                if (std.mem.eql(u8, s.id[0..d], ns) and !std.mem.eql(u8, s.group, ns))
                    @compileError("`" ++ s.id ++ "` is grouped `" ++ s.group ++ "` — it will not appear under " ++ ns);
            }
        }
        // Every default chord parses.
        for (.{ s.keys.vim, s.keys.standard, s.keys.both, s.keys.vim_handler }) |list| {
            for (list) |k| {
                if (keymap.parseKeySeqComptime(k) == null)
                    @compileError("command `" ++ s.id ++ "` declares key `" ++ k ++ "` that does not parse");
            }
        }
    }
    // Chord collisions, per profile. An exact duplicate sequence between
    // two commands means the later one silently wins — a compile error
    // instead. A binding that is also a prefix of a longer one is fine
    // (that is `pending_with_fallback`).
    for (.{ keymap.Profile.vim, keymap.Profile.standard }) |profile| {
        const Owned = struct { seq: []const key_mod.Chord, id: []const u8, spec: []const u8 };
        var owned: []const Owned = &.{};
        for (specs.specs) |s| {
            const lists = .{ s.keys.both, switch (profile) {
                .vim => s.keys.vim,
                .standard => s.keys.standard,
            } };
            for (lists) |list| {
                for (list) |k| {
                    const seq = keymap.parseKeySeqComptime(k).?;
                    for (owned) |o| {
                        if (o.seq.len != seq.len) continue;
                        var same = true;
                        for (o.seq, seq) |a, b| {
                            if (!a.eql(b)) {
                                same = false;
                                break;
                            }
                        }
                        if (same and !std.mem.eql(u8, o.id, s.id))
                            @compileError(@tagName(profile) ++ " profile: chord `" ++ k ++ "` is bound by both `" ++ o.id ++ "` and `" ++ s.id ++ "`");
                    }
                    owned = owned ++ &[_]Owned{.{ .seq = seq, .id = s.id, .spec = k }};
                }
            }
        }
    }
}

// ─── dynamic commands (IPC / manifest / Lua) ────────────────────────────

/// A value a script holds in its own state's registry. The `state` is
/// which Lua state that is — 0 is the `init.lua` state every App has,
/// 1.. an installed script's own (`app/scripts.zig`), so a ref never
/// reaches the wrong registry.
pub const LuaRef = struct {
    state: u16 = 0,
    ref: u32,
};

pub const Owner = union(enum) {
    /// Registered by an installed integration; the id is gpa-owned.
    integration: []u8,
    /// Registered from a script; the Lua state that registered it, so
    /// a reload of ONE installed script drops only its commands.
    script: u16,
    /// Registered over the file-IPC channel.
    ipc,

    fn deinit(o: Owner, gpa: Allocator) void {
        switch (o) {
            .integration => |s| gpa.free(s),
            .script, .ipc => {},
        }
    }
};

/// What a manifest command opens: the binary as a mount (or a pty).
pub const MountRun = struct {
    binary: []u8,
    args: [][]u8,
    pty: bool,
    /// The tab label.
    label: []u8,

    fn deinit(r: MountRun, gpa: Allocator) void {
        gpa.free(r.binary);
        for (r.args) |a| gpa.free(a);
        gpa.free(r.args);
        gpa.free(r.label);
    }
};

pub const DynRunner = union(enum) {
    /// An ex-command line to run.
    ex: []u8,
    /// Acknowledge over IPC (`plugin-command` event) and nothing else.
    ipc,
    /// A Lua function held in the registry.
    lua: LuaRef,
    /// Open an integration binary as a `Pane.mount` / `Pane.pty`.
    mount: MountRun,

    fn deinit(r: DynRunner, gpa: Allocator) void {
        switch (r) {
            .ex => |s| gpa.free(s),
            .mount => |m| m.deinit(gpa),
            .ipc, .lua => {},
        }
    }
};

pub const DynCommand = struct {
    id: []u8,
    title: []u8,
    group: []u8,
    keys: [][]u8,
    runner: DynRunner,
    owner: Owner,

    fn deinit(c: *DynCommand, gpa: Allocator) void {
        gpa.free(c.id);
        gpa.free(c.title);
        gpa.free(c.group);
        for (c.keys) |k| gpa.free(k);
        gpa.free(c.keys);
        c.runner.deinit(gpa);
        c.owner.deinit(gpa);
    }
};

/// What a caller passes to `register` — borrowed; the registry dupes.
pub const DynInit = struct {
    id: []const u8,
    title: []const u8 = "",
    group: []const u8 = "plugin",
    keys: []const []const u8 = &.{},
    runner: Runner = .ipc,
    owner: union(enum) { integration: []const u8, script: u16, ipc } = .ipc,

    pub const Runner = union(enum) {
        ex: []const u8,
        ipc,
        lua: LuaRef,
        mount: struct { binary: []const u8, args: []const []const u8, pty: bool = false, label: []const u8 },
    };
};

pub const DynRegistry = struct {
    gpa: Allocator,
    list: std.ArrayList(DynCommand) = .empty,
    /// Slots freed by `unregister` are `null` so indices stay stable.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    live: std.ArrayList(bool) = .empty,

    pub fn init(gpa: Allocator) DynRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DynRegistry) void {
        for (self.list.items, self.live.items) |*c, alive| if (alive) c.deinit(self.gpa);
        self.list.deinit(self.gpa);
        self.live.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
    }

    /// Register or replace. Static ids cannot be shadowed. Returns the slot.
    pub fn register(self: *DynRegistry, init_: DynInit) (Allocator.Error || error{ShadowsBuiltin})!u32 {
        if (by_name.has(init_.id)) return error.ShadowsBuiltin;
        const gpa = self.gpa;
        var c: DynCommand = .{
            .id = try gpa.dupe(u8, init_.id),
            .title = undefined,
            .group = undefined,
            .keys = &.{},
            .runner = .ipc,
            .owner = .ipc,
        };
        errdefer gpa.free(c.id);
        c.title = try gpa.dupe(u8, if (init_.title.len == 0) init_.id else init_.title);
        errdefer gpa.free(c.title);
        c.group = try gpa.dupe(u8, init_.group);
        errdefer gpa.free(c.group);
        const keys = try gpa.alloc([]u8, init_.keys.len);
        var filled: usize = 0;
        errdefer {
            for (keys[0..filled]) |k| gpa.free(k);
            gpa.free(keys);
        }
        for (init_.keys) |k| {
            keys[filled] = try gpa.dupe(u8, k);
            filled += 1;
        }
        c.keys = keys;
        c.runner = switch (init_.runner) {
            .ex => |line| .{ .ex = try gpa.dupe(u8, line) },
            .ipc => .ipc,
            .lua => |r| .{ .lua = r },
            .mount => |m| blk: {
                const binary = try gpa.dupe(u8, m.binary);
                errdefer gpa.free(binary);
                const label = try gpa.dupe(u8, if (m.label.len == 0) std.fs.path.basename(m.binary) else m.label);
                errdefer gpa.free(label);
                const args = try gpa.alloc([]u8, m.args.len);
                var n: usize = 0;
                errdefer {
                    for (args[0..n]) |a| gpa.free(a);
                    gpa.free(args);
                }
                for (m.args) |a| {
                    args[n] = try gpa.dupe(u8, a);
                    n += 1;
                }
                break :blk .{ .mount = .{ .binary = binary, .args = args, .pty = m.pty, .label = label } };
            },
        };
        errdefer c.runner.deinit(gpa);
        c.owner = switch (init_.owner) {
            .integration => |id| .{ .integration = try gpa.dupe(u8, id) },
            .script => |id| .{ .script = id },
            .ipc => .ipc,
        };
        errdefer c.owner.deinit(gpa);

        if (self.by_name.get(c.id)) |slot| {
            // The map key is the OLD id slice; swap it for the new one before
            // the old command (and its id) is freed.
            _ = self.by_name.remove(c.id);
            try self.by_name.put(gpa, c.id, slot);
            self.list.items[slot].deinit(gpa);
            self.list.items[slot] = c;
            self.live.items[slot] = true;
            return slot;
        }
        const slot: u32 = @intCast(self.list.items.len);
        try self.list.append(gpa, c);
        errdefer _ = self.list.pop();
        try self.live.append(gpa, true);
        errdefer _ = self.live.pop();
        try self.by_name.put(gpa, self.list.items[slot].id, slot);
        return slot;
    }

    pub fn get(self: *const DynRegistry, id: []const u8) ?u32 {
        return self.by_name.get(id);
    }

    pub fn at(self: *const DynRegistry, slot: u32) ?*const DynCommand {
        if (slot >= self.list.items.len or !self.live.items[slot]) return null;
        return &self.list.items[slot];
    }

    pub fn unregister(self: *DynRegistry, id: []const u8) bool {
        const slot = self.by_name.get(id) orelse return false;
        _ = self.by_name.remove(id);
        self.list.items[slot].deinit(self.gpa);
        self.live.items[slot] = false;
        return true;
    }

    /// Drop every command with the given owner kind (script reload,
    /// integration uninstall). Returns how many went.
    pub fn unregisterOwner(self: *DynRegistry, owner: std.meta.Tag(Owner)) usize {
        var n: usize = 0;
        for (self.list.items, self.live.items, 0..) |*c, alive, i| {
            if (!alive or std.meta.activeTag(c.owner) != owner) continue;
            _ = self.by_name.remove(c.id);
            c.deinit(self.gpa);
            self.live.items[i] = false;
            n += 1;
        }
        return n;
    }

    /// Drop every command one Lua state registered — one installed
    /// script reloading, or `init.lua`. Returns how many went.
    pub fn unregisterScript(self: *DynRegistry, state: u16) usize {
        var n: usize = 0;
        for (self.list.items, self.live.items, 0..) |*c, alive, i| {
            if (!alive or c.owner != .script or c.owner.script != state) continue;
            _ = self.by_name.remove(c.id);
            c.deinit(self.gpa);
            self.live.items[i] = false;
            n += 1;
        }
        return n;
    }
};

// ─── dispatch ───────────────────────────────────────────────────────────

pub const CommandRef = union(enum) {
    static: CommandId,
    dyn: u32,
};

/// Resolve a command by its string id: built-ins first, then dynamic.
pub fn resolve(app: *const App, id: []const u8) ?CommandRef {
    if (by_name.get(id)) |c| return .{ .static = c };
    if (app.dyn_commands.get(id)) |slot| return .{ .dyn = slot };
    return null;
}

/// Run a command. Clears `app.diag`, calls the runner, toasts a failure
/// (Canceled is silent) and returns the error so callers can see it.
pub fn run(app: *App, ref: CommandRef) CommandError!void {
    app.diag.clear();
    const outer = app.running_cmd;
    const outer_serial = app.running_serial;
    app.cmd_runs +%= 1;
    app.running_cmd = ref;
    app.running_serial = app.cmd_runs;
    defer {
        app.running_cmd = outer;
        app.running_serial = outer_serial;
    }
    defer app.checkLayoutInvariant(switch (ref) {
        .static => |id| name(id),
        .dyn => "a registered command",
    });
    // The sessions mode keeps its shape after whatever ran: a session
    // started joins a column, a closed column is refilled.
    defer if (outer == null) @import("../app/sessions_mode.zig").reconcile(app) catch {};
    const result: CommandError!void = switch (ref) {
        .static => |id| if (runners.get(id)) |f| f(app) else app.diag.fail(app.frame.allocator(), "{s}: not implemented yet", .{name(id)}),
        .dyn => |slot| runDyn(app, slot),
    };
    result catch |err| {
        if (err != error.Canceled) {
            if (app.diag.msg) |m| {
                app.toast("{s}", .{m});
            } else {
                const t = switch (ref) {
                    .static => |id| title(id),
                    .dyn => |slot| if (app.dyn_commands.at(slot)) |c| c.title else "command",
                };
                app.toast("{s}: {s}", .{ t, reason(err) });
            }
        }
        return err;
    };
    // A success is a recent command (Rust's `note_recent_command`) —
    // except the recents picker itself, which would head its own list,
    // and the self-referential replays.
    const id: []const u8 = switch (ref) {
        .static => |s| if (s == .@"picker.recent_commands" or s == .@"vim.dot_repeat" or s == .@"vim.macro_replay" or s == .palette) return else name(s),
        .dyn => |slot| if (app.dyn_commands.at(slot)) |c| c.id else return,
    };
    try app.noteRecentCommand(id);
}

/// What a toast says for an error a command returned without a
/// `diag` message: a sentence for the shared tags a user can act on,
/// the tag's name for the rest (a `Failed` with no message is a bug
/// worth seeing by name).
pub fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAnEditor => "needs an editor pane",
        error.NoActivePane => "nothing is open",
        error.NoWorkspace => "no workspace is open",
        error.NoRepo => "not in a git repository",
        error.NoSelection => "nothing is selected",
        error.Unsupported => "not supported here",
        else => @errorName(err),
    };
}

/// Run by string id. Unknown ids toast and return `error.Failed`.
pub fn runNamed(app: *App, id: []const u8) CommandError!void {
    const ref = resolve(app, id) orelse {
        app.diag.clear();
        const err = app.diag.fail(app.frame.allocator(), "no such command: {s}", .{id});
        app.toast("{s}", .{app.diag.msg orelse "no such command"});
        return err;
    };
    return run(app, ref);
}

fn runDyn(app: *App, slot: u32) CommandError!void {
    const c = app.dyn_commands.at(slot) orelse return app.diag.fail(app.frame.allocator(), "command slot {d} was unregistered", .{slot});
    switch (c.runner) {
        // A manifest line: `{{tokens}}` expanded, a missing program toasted.
        .ex => |line| return @import("../app/launchers.zig").fire(app, line),
        .ipc => return app.ackPluginCommand(c.id),
        .lua => |r| {
            const l = app.luaState(r.state) orelse return app.diag.fail(app.frame.allocator(), "{s}: its script is not loaded", .{c.id});
            return l.callCommand(r);
        },
        .mount => |r| return @import("../app/integrations.zig").runMount(app, .{
            .id = switch (c.owner) {
                .integration => |i| i,
                else => "",
            },
            .binary = r.binary,
            .args = @ptrCast(r.args),
            .pty = r.pty,
            .label = r.label,
        }),
    }
}

// ─── menus ──────────────────────────────────────────────────────────────

/// What a context-menu row does. A static command is an enum — a menu
/// cannot name an id that does not exist.
/// A row of the AI chip's profile menu (`app/launch_profiles.zig`):
/// `index` 0 is the built-in profile, else the product's `index - 1`th.
/// `worktree`: the *New session in a worktree…* row — the session of
/// that profile starts in a git worktree of its own after a name prompt
/// (`app/session_worktree.zig`).
pub const AiProfileAction = struct { product: @import("../config/Config.zig").AiProduct, index: u16, set_default: bool, worktree: bool = false };

pub const MenuAction = union(enum) {
    command: CommandId,
    dyn: u32,
    set_panel_sort: struct { panel: panel.PanelId, sort: panel.ListSort },
    ai_profile: AiProfileAction,
    /// A dock kebab row: one setting on one widget.
    dock_set: struct { id: u32, setting: @import("dock.zig").Setting },
    /// The `⟳` chip menu's toggle row (`app/auto_refresh.zig`).
    toggle_auto_refresh: panel.PanelId,
    /// The coverage chip's mode menu (`app/coverage.zig`).
    set_coverage_mode: @import("../config/Config.zig").CoverageChipMode,
    /// The launcher dock's *Show* rows: icons, labels, or both
    /// (`app/launcher_dock.zig`, `ui.dock.labels`).
    set_dock_labels: @import("../config/Config.zig").DockLabels,
    /// // changed (dock-placement): its *Place* rows — a bottom strip
    /// above the statusline or under the `:` line (`ui.dock.placement`).
    set_dock_placement: @import("../config/Config.zig").DockPlacement,
    /// Its *Align* rows: where the run sits along the strip
    /// (`ui.dock.align`).
    set_dock_align: @import("../config/Config.zig").DockAlign,
    /// Its *Show the + button* row (`ui.dock.plus`).
    set_dock_plus: bool,
    /// // changed (dock-polish): its `+ at the …` rows — which end
    /// the `+` sits at (`ui.dock.plus_at`).
    set_dock_plus_at: @import("../config/Config.zig").DockPlusAt,
    /// Its `Running mark:` rows — brightness, a small dot, or none
    /// (`ui.dock.running_mark`).
    set_dock_running_mark: @import("../config/Config.zig").DockRunningMark,
    /// The Claude chip's `Icon ▸` rows — the figure or the Anthropic
    /// spark (`app/claude_mark.zig`, `ui.claude_mark`). Two drawings to
    /// choose between, so the rows are set-rows rather than commands;
    /// `.custom` is not a row here, exactly as below — baking an SVG is
    /// its own prompt (`view.claude_mark_custom`).
    set_claude_mark: @import("../config/Config.zig").ClaudeMark,
    /// An `Open ×N ▸` child row: `n` Claude sessions arranged so, and
    /// the arrangement remembered for the parent row's plain click
    /// (`ai.batch_arrange`).
    open_batch: struct { n: u8, arrange: @import("../config/Config.zig").BatchArrange },
    /// The terminal chip's `Icon ▸` rows — the ghost or the codicon
    /// (`app/terminal_glyph.zig`, `ui.terminal_glyph`). `.custom` is
    /// not a row here: baking an SVG is its own prompt.
    set_terminal_mark: @import("../config/Config.zig").TerminalGlyph,
    /// // changed (menu-bar): a row of the ` » ` overflow menu — opens
    /// menu-bar menu `index` (`app/menu_bar.zig`).
    menu_bar: u8,
    /// A git palette row menu's action (`app/git_palette.zig`).
    git_palette: GitPaletteAct,
    /// The rail menu's "Move to <side> side": the section the menu was
    /// opened on, not the focused one (`app/side.zig`).
    move_section: struct { section: @import("../ui/activity_bar.zig").Section, side: @import("../config/Config.zig").Side },
    /// // changed (railmove): the rail menu's *Hide from activity bar*
    /// — the section the menu was opened on (`ui.rail.hidden`).
    rail_hide: @import("../ui/activity_bar.zig").Section,
    /// The gear menu's *Show hidden sections ▸* rows: one back.
    rail_show: @import("../ui/activity_bar.zig").Section,
    /// The statusline's *Segments ▸* rows: show or hide one segment
    /// by its `statusline.hidden` name (`app/statusline.zig`). The menu
    /// or a static owns the bytes.
    toggle_statusline_segment: []const u8,
    /// A chip's *Move left* / *Move right*: one segment a place along
    /// its side of the row, written to `ui.statusline_segment_order`.
    /// The menu's `mem` arena or a static owns `key`.
    move_statusline_segment: struct { key: []const u8, left: bool },
    /// The statusline menu's *Reset order*: `ui.statusline_segment_order`
    /// back to empty, the built-in order.
    reset_statusline_order,
    /// The rail menu's *Show on dock instead*: hidden here, its
    /// command pinned on the launcher dock.
    rail_to_dock: @import("../ui/activity_bar.zig").Section,
    /// The dock item's *Move back to activity bar*: unpinned there,
    /// shown here.
    rail_from_dock: @import("../ui/activity_bar.zig").Section,
    /// // right-click: the row's own text to the clipboard — a URL, a
    /// position, a language name (Rust `CopyPath` / `CopyText`). The
    /// menu's `mem` arena or a static owns the bytes.
    copy_text: []const u8,
    /// // right-click: a link under the pointer to the clipboard — a
    /// terminal pane's *Copy link* (toast "link copied").
    copy_link: []const u8,
    /// // right-click: a web URL for the external browser (Rust `OpenUrl`).
    open_url: []const u8,
    /// // right-click: a path to open — a file in a buffer, a directory
    /// in a Files pane (Rust `OpenPath` / `OpenFilesPane`).
    open_path: []const u8,
    /// // right-click: a theme by name — the theme pill's per-theme rows
    /// (Rust `SetTheme`).
    set_theme: []const u8,
    /// // changed (lua-track): a DIAGNOSTICS row menu's Open — the row's
    /// index (`app/lsp.zig`).
    diag_row_open: u32,
    /// // changed (lua-track): the severity chip's menu — one filter.
    set_severity_filter: @import("../app/lsp.zig").SeverityFilter,
    /// // changed (lua-track): a SCRIPTS row menu's "Open <file:line>" —
    /// the row's index (`app/scripts_panel.zig`).
    script_row_open: u32,
    /// // changed (lua-install): the SCRIPTS sort chip's menu — a
    /// `scripts_panel.Sort` as an integer.
    script_sort: u8,
    /// // changed (lua-track): *Bind in init.lua…* — the command id; the
    /// menu's `mem` arena owns the bytes.
    lua_bind: []const u8,
    /// // changed (lsp-defaults): the LSP chip menu's *Install <binary>…*
    /// — the binary's name; the menu's `mem` arena owns the bytes
    /// (`app/runners.zig`'s `installBin`).
    lsp_install: []const u8,
    /// A Claude account row on the usage pane's menus (and the account
    /// choosers the palette opens when several are configured): link a
    /// token to it, rename it, or remove it. `name` is the account's;
    /// the menu's `mem` arena owns the bytes (`app/usage_pane.zig`).
    claude_account: ClaudeAccountAct,
    /// // changed (colors): a `Color: …` row on a session's menus — the
    /// SESSIONS card / table row, a pty tab, a pty pane body. `name` is
    /// one of `ui/accent_color.zig`'s literals or its `none` sentinel
    /// (Rust `SessionSetColor`; `src/sessions.zig` `setColorAction`).
    session_color: SessionColorAct,
    /// // changed (colors): a `Color: …` row on the repo pill's menu —
    /// the repo's index in discovery order (`app/git_palette.zig`
    /// `setRepoColor`).
    repo_color: struct { idx: u32, name: []const u8 },
    /// // changed (lua-plumbing): a script list's row menu
    /// (`app/script_list.zig`) — fold the header at `row`, run the
    /// script's menu entry `item`, or refresh the list.
    script_list_fold: struct { list: u32, row: u32 },
    script_list_menu: struct { list: u32, item: u32 },
    script_list_refresh: u32,
    /// The rail menu's *Show …* row for a script's section.
    script_section_show: u16,
    /// An integration statusline chip's *Requests…* row: open the
    /// REQUESTS view filtered to that chip's service. The menu's `mem`
    /// arena owns the bytes (`app/requests.zig`).
    requests_for: []const u8,
    /// A workspace header menu's *Switch to this workspace*: that root
    /// (0 the primary, i + 1 the i-th extra) becomes the active one.
    switch_workspace: u8,
    /// The bell menu's *Needs input: …* rows: go to a session waiting
    /// on you — `pane` when a pane here runs it, else the listing's
    /// `id` (the menu's `mem` arena owns the bytes;
    /// `app/session_attention.zig`).
    session_focus: struct { pane: ?u32 = null, id: []const u8 = "" },
    /// A row another integration contributed through its manifest's
    /// `context_menu[]` (`app/menu_contrib.zig`): its command, run with
    /// the clicked row's values in `{id}` `{key}` `{repo}` `{n}` `{url}`.
    /// The menu's `mem` arena owns the bytes.
    contribution: MenuContribution,
    none,
};

pub const MenuContribution = struct {
    command: []const u8,
    id: []const u8 = "",
    key: []const u8 = "",
    repo: []const u8 = "",
    n: []const u8 = "",
    url: []const u8 = "",
    /// The info view's copy for the row.
    hover: []const u8 = "",
};

/// Which session a `Color: …` row recolours: the SESSIONS row under the
/// cursor (its transcript id keeps the colour, and its open pane if
/// any), or one pty pane (its session id too, when its command names
/// one).
pub const SessionColorAct = struct {
    target: union(enum) { row, pane: u32 },
    name: []const u8,
};

/// What a git palette menu row does, with the index of the row it
/// names (a rail branch, a remote, a worktree, a stash, a tag, a repo,
/// a closed repo). `repo` is the row's repo under All repos (its index
/// in discovery order): the action makes it the active one first, so
/// opening the menu switches nothing (`app/git_palette.zig`).
pub const GitPaletteAct = struct {
    what: GitPaletteWhat,
    idx: u32,
    repo: ?u32 = null,
};

pub const GitPaletteWhat = enum {
    checkout,
    merge,
    rebase,
    new_branch,
    delete_branch,
    copy_name,
    remote_fetch,
    remote_copy_url,
    worktree_open,
    worktree_shell,
    worktree_copy_path,
    worktree_remove,
    /// // changed (sessions-worktree): a session-owned worktree's
    /// merge into the main tree / remove with its branch
    /// (`app/session_worktree.zig`, behind a named confirm).
    session_merge,
    session_remove,
    stash_apply,
    stash_pop,
    stash_drop,
    /// // changed (git-more2): a STASHES row's files pane, a branch
    /// from it, its rename.
    stash_show,
    stash_branch,
    stash_rename,
    tag_checkout,
    tag_delete,
    tag_copy,
    /// A branch row against the checked-out one: `current..branch`.
    diff_current,
    // The branch verbs (git-more2); `new_branch_from` / `worktree_from`
    // name a tag row.
    rename,
    fast_forward,
    set_upstream,
    checkout_force,
    delete_remote,
    push_force,
    new_branch_from,
    worktree_from,
    switch_repo,
    reopen_repo,
    all_repos,
    /// The row menus' `.command` rows made acts, so that under All
    /// repos the row's repo goes active before the command runs.
    pull,
    push,
    worktree_new,
    /// A section header's fold; a repo sub-header's "show only".
    fold,
    refresh,
    /// `reset --soft / --mixed / --hard` to the ROW's branch (the
    /// commands read the cursor's).
    reset_soft,
    reset_mixed,
    reset_hard,
    /// The reference client's branch verbs (git-panel): the row's tip
    /// commit onto HEAD / reverted, its sha and its web links copied, a
    /// worktree from it, a tag on it, a branch that is not checked out
    /// pushed to its remote.
    cherry_pick,
    revert,
    copy_sha,
    copy_branch_link,
    copy_commit_link,
    branch_worktree,
    tag_here,
    tag_annotated_here,
    push_branch,
    /// // changed (git-menus): the GitKraken rows the branches panel
    /// was missing — the plan modal over `row..HEAD`, an AI summary of
    /// the commits the row has that its base does not, and a push that
    /// opens the forge's new-PR page.
    rebase_interactive,
    explain_branch,
    push_start_pr,
    /// // changed (git-menus): a WORKTREES row — the tree on a new tab
    /// page, removed with its branch, locked / unlocked.
    worktree_open_tab,
    worktree_remove_branch,
    worktree_lock,
    worktree_unlock,
};

/// What a `.claude_account` menu row does to the account it names.
pub const ClaudeAccountAct = struct {
    act: Verb,
    name: []const u8,

    pub const Verb = enum { reauth, link, rename, remove };
};

pub const MenuItem = struct {
    label: []const u8,
    action: MenuAction,
    checked: bool = false,
    /// A row that can wear a tick though it has none now: its menu
    /// keeps the tick column (`app/render.zig`'s `hasTickColumn`).
    checkable: bool = false,
    separator_before: bool = false,
    /// // changed (ui-polish): a glyph override for the row; null draws
    /// the command group's glyph (`ui/menu_glyph.zig`).
    icon: ?[]const u8 = null,
    /// The one-character twin `icon` paints under `ui.ascii_icons`.
    icon_ascii: ?[]const u8 = null,
    /// // changed (ui-polish): rows this one opens to the right (`▸`);
    /// a literal slice — the open menu copies what it shows onto the gpa.
    submenu: []const MenuItem = &.{},

    /// A row that only says something — no action, nothing it opens:
    /// drawn muted, and the keyboard cursor steps over it.
    pub fn isInfo(it: MenuItem) bool {
        return it.action == .none and it.submenu.len == 0;
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

test "ids round-trip through by_name and @tagName" {
    try std.testing.expectEqual(CommandId.@"app.quit", by_name.get("app.quit").?);
    try std.testing.expectEqualStrings("git.commit", name(.@"git.commit"));
    try std.testing.expect(by_name.get("nope.nope") == null);
    try std.testing.expectEqual(@as(usize, 1187), count);
    // + `sessions.focus_1` … `focus_9` (session-numbers)
    // + `picker.recent_items` (cache-phase2)
    try std.testing.expectEqual(@as(usize, 1187), count);
    // + `sessions.focus_1` … `focus_9` (session-numbers)
    // - `sessions.show_1` … `show_9`, folded into `focus_N` (sessions-ctrl-n)
    try std.testing.expectEqual(@as(usize, 1187), count);
    try std.testing.expectEqualStrings("Quit mnml", title(.@"app.quit"));
}

test "dyn registry: register / lookup / replace / unregister / owner sweep" {
    const gpa = std.testing.allocator;
    var reg = DynRegistry.init(gpa);
    defer reg.deinit();
    try std.testing.expectError(error.ShadowsBuiltin, reg.register(.{ .id = "app.quit" }));
    const a = try reg.register(.{ .id = "jira.open", .title = "Open Jira", .keys = &.{"ctrl+k j"}, .owner = .{ .integration = "jira" } });
    const b = try reg.register(.{ .id = "user.hello", .runner = .{ .ex = "echo hi" }, .owner = .{ .script = 0 } });
    try std.testing.expectEqual(a, reg.get("jira.open").?);
    try std.testing.expectEqualStrings("Open Jira", reg.at(a).?.title);
    // Re-register replaces in place, same slot.
    const a2 = try reg.register(.{ .id = "jira.open", .title = "Open Jira issue", .owner = .{ .integration = "jira" } });
    try std.testing.expectEqual(a, a2);
    try std.testing.expectEqualStrings("Open Jira issue", reg.at(a).?.title);
    try std.testing.expectEqual(@as(usize, 1), reg.unregisterOwner(.script));
    try std.testing.expect(reg.at(b) == null);
    try std.testing.expect(reg.get("user.hello") == null);
    try std.testing.expect(reg.unregister("jira.open"));
    try std.testing.expect(!reg.unregister("jira.open"));
}
