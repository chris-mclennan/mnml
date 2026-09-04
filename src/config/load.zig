//! The loader: one ZON file → `Patch(Config)` (`parseLayer`), and the
//! three layers → one `Config` (`load`).
//!
//! Layers, in order: the home file (`data_root.homeConfigPath`), the
//! workspace's `.mnml/config.zon` (with its trust), then `--config`.
//! Each is parsed on its own; a file that does not parse, a section that
//! does not type-check, or a map entry that is wrong contributes nothing
//! and one `file:line:col` diagnostic — never a failed startup.
//!
//! Everything a `Loaded` holds lives on its arena (D1: config is a
//! replace-wholesale dataset). `Loaded.deinit` frees it all.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const Config = @import("Config.zig");
const patch_mod = @import("patch.zig");
const decode_mod = @import("decode.zig");
const diag_mod = @import("diag.zig");
const trust_mod = @import("trust.zig");
const data_root = @import("data_root.zig");

pub const Patch = patch_mod.Patch;
pub const apply = patch_mod.apply;
pub const Diagnostics = diag_mod.Diagnostics;
pub const Diagnostic = diag_mod.Diagnostic;

pub const Trust = enum { trusted, untrusted };

/// Largest config file the loader will read.
pub const max_file_bytes = 16 * 1024 * 1024;

pub const Loaded = struct {
    /// Heap-allocated so every `Allocator` handed out from it (the
    /// diagnostics list holds one) stays valid when `Loaded` is moved.
    arena: *std.heap.ArenaAllocator,
    config: Config,
    diagnostics: Diagnostics,
    /// The three layer paths as resolved (absent files included), for a
    /// settings screen or `:config` to show.
    home_path: ?[]const u8,
    workspace_path: []const u8,
    explicit_path: ?[]const u8,

    pub fn allocator(self: *const Loaded) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Loaded) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }
};

// ─── one file ────────────────────────────────────────────────────────────

/// Parse one layer. Every value in the returned patch lives on `arena`;
/// `src` is not referenced afterwards. Problems go to `diags`, never up.
pub fn parseLayer(arena: Allocator, src: [:0]const u8, file: []const u8, diags: *Diagnostics) Allocator.Error!Patch(Config) {
    var out: Patch(Config) = .{};

    var ast = try Ast.parse(arena, src, .zon);
    defer ast.deinit(arena);
    if (ast.errors.len != 0) {
        for (ast.errors) |e| {
            var buf: std.Io.Writer.Allocating = .init(arena);
            ast.renderError(e, &buf.writer) catch return error.OutOfMemory;
            try diags.addAt(file, ast, e.token, "{s}", .{buf.written()});
        }
        return out;
    }

    var zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    defer zoir.deinit(arena);
    if (zoir.hasCompileErrors()) {
        for (zoir.compile_errors) |e| {
            const tok: Ast.TokenIndex = if (e.token.unwrap()) |tk| tk else ast.nodeMainToken(@enumFromInt(e.node_or_offset));
            try diags.addAt(file, ast, tok, "{s}", .{e.msg.get(zoir)});
        }
        return out;
    }

    var ctx: decode_mod.Context = .{ .arena = arena, .ast = ast, .zoir = zoir, .diags = diags, .file = file };
    const root: Zoir.Node.Index = .root;
    const lit = switch (root.get(zoir)) {
        .empty_literal => return out,
        .struct_literal => |l| l,
        else => {
            try ctx.fail(root, "expected `.{{ … }}` at the top level", .{});
            return out;
        },
    };

    // Section by section, so a typo in `.ui` drops `.ui` for this layer
    // and `.editor` still applies.
    for (lit.names, 0..) |name, i| {
        const key = name.get(zoir);
        const val = lit.vals.at(@intCast(i));
        var matched = false;
        inline for (@typeInfo(Patch(Config)).@"struct".fields) |f| {
            if (!matched and std.mem.eql(u8, f.name, key)) {
                matched = true;
                if (decode_mod.decode(f.type, &ctx, val)) |v| {
                    @field(out, f.name) = v;
                } else |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Bad => {}, // reported; the section is dropped
                }
            }
        }
        if (!matched) try ctx.failName(val, "unknown section '{s}' (ignored)", .{key});
    }
    return out;
}

// ─── three layers ────────────────────────────────────────────────────────

pub const Options = struct {
    /// `--config PATH`; applied last, always trusted.
    explicit: ?[]const u8 = null,
    /// Absolute workspace root; its `.mnml/config.zon` is the middle layer.
    workspace: []const u8,
    trust: Trust = .trusted,
    env: data_root.Env,
};

pub fn load(gpa: Allocator, io: Io, opts: Options) Allocator.Error!Loaded {
    const arena_state = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_state);
    arena_state.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var loaded: Loaded = .{
        .arena = arena_state,
        .config = .{},
        .diagnostics = Diagnostics.init(arena),
        .home_path = try data_root.homeConfigPath(arena, io, opts.env),
        .workspace_path = try std.fs.path.join(arena, &.{ opts.workspace, ".mnml", data_root.config_file }),
        .explicit_path = if (opts.explicit) |p| try arena.dupe(u8, p) else null,
    };
    if (loaded.home_path) |p| try applyFile(arena, io, &loaded.config, &loaded.diagnostics, p, .trusted);
    try applyFile(arena, io, &loaded.config, &loaded.diagnostics, loaded.workspace_path, opts.trust);
    if (loaded.explicit_path) |p| try applyFile(arena, io, &loaded.config, &loaded.diagnostics, p, .trusted);

    try normalize(arena, &loaded.config, &loaded.diagnostics, opts.env.vars.get("HOME"));
    return loaded;
}

fn applyFile(arena: Allocator, io: Io, cfg: *Config, diags: *Diagnostics, path: []const u8, trust: Trust) Allocator.Error!void {
    const src = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => return, // absent — fine
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.addFmt(path, 0, 0, "cannot read: {s}", .{@errorName(e)});
            return;
        },
    };
    var p = try parseLayer(arena, src, path, diags);
    if (trust == .untrusted) {
        const n = try trust_mod.strip(arena, &p);
        if (n != 0) try diags.addFmt(path, 0, 0, "untrusted workspace: {d} exec-bearing setting(s) ignored", .{n});
    }
    try apply(arena, cfg, p);
}

// ─── after the merge ─────────────────────────────────────────────────────

/// Clamp what the Rust config clamped, expand `~`, and drop startup
/// layout entries that cannot open. Runs once, after every layer.
pub fn normalize(arena: Allocator, cfg: *Config, diags: *Diagnostics, home: ?[]const u8) Allocator.Error!void {
    cfg.editor.chord_timeout_ms = std.math.clamp(cfg.editor.chord_timeout_ms, Config.chord_timeout_ms_min, Config.chord_timeout_ms_max);
    cfg.ui.tree_width = std.math.clamp(cfg.ui.tree_width, Config.tree_width_min, Config.tree_width_max);
    cfg.ui.hover_help_height = std.math.clamp(cfg.ui.hover_help_height, Config.hover_help_height_min, Config.hover_help_height_max);
    cfg.ui.projects_dir = try expandTilde(arena, cfg.ui.projects_dir, home);
    if (cfg.startup.default_workspace) |ws| cfg.startup.default_workspace = try expandTilde(arena, ws, home);

    var kept: std.ArrayList(Config.LayoutEntry) = .empty;
    for (cfg.startup.layout, 0..) |entry, i| {
        var e = entry;
        const ok = switch (e.kind) {
            .editor => e.path != null and std.mem.trim(u8, e.path.?, " \t").len != 0,
            .pty => e.cmd != null and std.mem.trim(u8, e.cmd.?, " \t").len != 0,
        };
        if (!ok) {
            try diags.addFmt("startup.layout", 0, 0, "entry #{d} kind={s} is missing its {s}; dropped", .{ i, @tagName(e.kind), if (e.kind == .editor) "path" else "cmd" });
            continue;
        }
        if (i != 0 and e.split == null) {
            try diags.addFmt("startup.layout", 0, 0, "entry #{d} needs `.split` (required after the first entry); dropped", .{i});
            continue;
        }
        if (e.ratio) |r| e.ratio = std.math.clamp(r, 1, 99);
        try kept.append(arena, e);
    }
    if (kept.items.len != cfg.startup.layout.len) cfg.startup.layout = try kept.toOwnedSlice(arena);
}

fn expandTilde(arena: Allocator, path: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    const h = home orelse return path;
    if (std.mem.eql(u8, path, "~")) return arena.dupe(u8, h);
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(arena, &.{ h, path[2..] });
    return path;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    diags: Diagnostics,

    /// Heap-allocated: `diags` keeps an `Allocator` that points at
    /// `arena_state`, so the fixture must not move.
    fn init() !*Fixture {
        const f = try t.allocator.create(Fixture);
        f.arena_state = std.heap.ArenaAllocator.init(t.allocator);
        f.diags = Diagnostics.init(f.arena_state.allocator());
        return f;
    }
    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        t.allocator.destroy(f);
    }
    fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }
    fn rendered(f: *Fixture) ![]u8 {
        return f.diags.render(t.allocator);
    }
};

test "a full layer parses into a patch" {
    const f = try Fixture.init();
    defer f.deinit();
    var p = try parseLayer(f.arena(),
        \\.{
        \\    .editor = .{ .input_style = .vim, .tab_width = 2 },
        \\    .ui = .{ .theme = "gruvbox", .todos_sort = .name_desc, .md_preview_engine = .glow },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" }, .vim = .{ .@"space f f" = "picker.files" } },
        \\    .lsp = .{ .rust = .{ .cmd = "rust-analyzer", .settings = .{ .cargo = .{ .allFeatures = true } } } },
        \\    .snippets = .{ .rust = .{ .@"fn" = "fn $1() {}" } },
        \\    .abbr = .{ .teh = "the" },
        \\    .ai = .{ .backend = .sub, .claude_accounts = .{ .{ .name = "work" } } },
        \\    .tools = .{ .cargo = .{ .path = "/usr/bin/cargo" } },
        \\    .startup = .{ .tasks = .{ "build" }, .default_workspace = "~/code" },
        \\    .tasks = .{ .build = .{ .cmd = "zig build" } },
        \\    .workspaces = .{ .{ .name = "mnml", .path = "~/mnml", .group = "personal" } },
        \\    .marketplace = .{ .sources = .{ .{ .crates_keyword = .{ .id = "x", .keyword = "y" } } } },
        \\}
    , "full.zon", &f.diags);
    if (f.diags.count() != 0) {
        const text = try f.rendered();
        defer t.allocator.free(text);
        std.debug.print("unexpected diagnostics:\n{s}", .{text});
        return error.TestUnexpectedResult;
    }
    try t.expectEqual(@as(?Config.InputStyle, .vim), p.editor.?.input_style);
    try t.expectEqualStrings("gruvbox", p.ui.?.theme.?);
    try t.expectEqual(@as(?Config.ListSort, .name_desc), p.ui.?.todos_sort);
    try t.expectEqual(Config.MdEngine.glow, p.ui.?.md_preview_engine.?);
    try t.expectEqualStrings("picker.files", p.keys.?.global.get("ctrl+p").?);
    try t.expectEqualStrings("picker.files", p.keys.?.vim.get("space f f").?);
    try t.expect(p.lsp.get("rust").?.settings.get("cargo").?.get("allFeatures").?.bool);
    try t.expectEqualStrings("fn $1() {}", p.snippets.get("rust").?.get("fn").?);
    try t.expectEqualStrings("the", p.abbr.get("teh").?);
    try t.expectEqual(@as(?Config.AiBackend, .sub), p.ai.?.backend);
    try t.expectEqualStrings("work", p.ai.?.extra.?.get("claude_accounts").?.array[0].get("name").?.string);
    try t.expectEqualStrings("/usr/bin/cargo", p.tools.?.get("cargo").?.get("path").?.string);
    try t.expectEqualStrings("build", p.startup.?.tasks.?[0]);
    try t.expectEqualStrings("zig build", p.tasks.get("build").?.cmd);
    try t.expectEqualStrings("personal", p.workspaces.?[0].group.?);
    try t.expectEqualStrings("y", p.marketplace.?.sources.?[0].crates_keyword.keyword);
    // and the patch applies onto the default without touching the rest
    var cfg: Config = .{};
    try apply(f.arena(), &cfg, p);
    try t.expectEqual(@as(u8, 2), cfg.editor.tab_width);
    try t.expect(cfg.editor.breadcrumb);
    p.editor = null;
    try t.expect(!patch_mod.isEmpty(Config, p));
}

test "a typo in .ui drops .ui for the layer; .editor still applies" {
    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(),
        \\.{
        \\    .editor = .{ .tab_width = 2 },
        \\    .ui = .{ .theme = "x", .tree_widht = 40 },
        \\}
    , "c.zon", &f.diags);
    try t.expect(p.ui == null);
    try t.expectEqual(@as(?u8, 2), p.editor.?.tab_width);
    const text = try f.rendered();
    defer t.allocator.free(text);
    try t.expect(std.mem.startsWith(u8, text, "c.zon:3:"));
    try t.expect(std.mem.indexOf(u8, text, "tree_widht") != null);
}

test "a wrong value type is located too" {
    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(), ".{ .editor = .{ .tab_width = \"four\" } }", "c.zon", &f.diags);
    try t.expect(p.editor == null);
    try t.expectEqual(@as(u32, 1), f.diags.items.items[0].line);
    try t.expectEqual(@as(u32, 30), f.diags.items.items[0].col);
}

test "an unknown section is reported and skipped, not fatal" {
    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(), ".{ .edtior = .{}, .session = .{ .restore = false } }", "c.zon", &f.diags);
    try t.expectEqual(@as(?bool, false), p.session.?.restore);
    try t.expectEqual(@as(usize, 1), f.diags.count());
    try t.expectEqual(@as(u32, 5), f.diags.items.items[0].col);
}

test "a syntax error yields a located diagnostic and an empty patch" {
    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(), ".{ .editor = .{ .tab_width = 2 ", "c.zon", &f.diags);
    try t.expect(patch_mod.isEmpty(Config, p));
    try t.expect(f.diags.count() >= 1);
    try t.expect(f.diags.items.items[0].line >= 1);
}

test "a duplicate key is rejected by ZonGen with a location" {
    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(), ".{ .editor = .{ .tab_width = 2, .tab_width = 4 } }", "c.zon", &f.diags);
    try t.expect(patch_mod.isEmpty(Config, p));
    const text = try f.rendered();
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "duplicate") != null);
    try t.expect(std.mem.startsWith(u8, text, "c.zon:1:"));
}

test "a non-struct top level is a diagnostic" {
    const f = try Fixture.init();
    defer f.deinit();
    _ = try parseLayer(f.arena(), "42", "c.zon", &f.diags);
    try t.expectEqual(@as(usize, 1), f.diags.count());
}

test "normalize clamps, expands ~, and drops broken layout entries" {
    const f = try Fixture.init();
    defer f.deinit();
    var cfg: Config = .{};
    cfg.ui.tree_width = 500;
    cfg.ui.hover_help_height = 1;
    cfg.editor.chord_timeout_ms = 1;
    cfg.ui.projects_dir = "~/code";
    cfg.startup.default_workspace = "~";
    cfg.startup.layout = &.{
        .{ .kind = .editor, .path = "a.txt" },
        .{ .kind = .pty }, // no cmd
        .{ .kind = .editor, .path = "b.txt" }, // no split
        .{ .kind = .pty, .cmd = "htop", .split = .down, .ratio = 250 },
    };
    try normalize(f.arena(), &cfg, &f.diags, "/home/u");
    try t.expectEqual(@as(u16, 80), cfg.ui.tree_width);
    try t.expectEqual(@as(u16, 3), cfg.ui.hover_help_height);
    try t.expectEqual(@as(u16, 100), cfg.editor.chord_timeout_ms);
    try t.expectEqualStrings("/home/u/code", cfg.ui.projects_dir);
    try t.expectEqualStrings("/home/u", cfg.startup.default_workspace.?);
    try t.expectEqual(@as(usize, 2), cfg.startup.layout.len);
    try t.expectEqual(@as(?u8, 99), cfg.startup.layout[1].ratio);
    try t.expectEqual(@as(usize, 2), f.diags.count());
}

test "load: three layers in order, untrusted workspace stripped, bad file non-fatal" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];

    try tmp.dir.createDirPath(t.io, "home");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "home/config.zon", .data =
        \\.{
        \\    .editor = .{ .tab_width = 2, .input_style = .vim },
        \\    .lsp = .{ .rust = .{ .cmd = "rust-analyzer" } },
        \\    .keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } },
        \\}
    });
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data =
        \\.{
        \\    .editor = .{ .tab_width = 8 },
        \\    .lsp = .{ .zig = .{ .cmd = "zls", .extensions = .{ "zig" } } },
        \\    .keys = .{ .global = .{ .@"ctrl+b" = "tree.toggle" } },
        \\    .ui = .{ .md_preview_engine = .{ .custom = "evil" }, .tree_width = 40 },
        \\}
    });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "explicit.zon", .data = ".{ .ipc = .{ .write_screen = true }, .bogus = 1 }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "broken.zon", .data = ".{ oops" });

    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    const home_root = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home_root);
    try vars.put("MNML_DATA_ROOT", home_root);
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const explicit = try std.fs.path.join(t.allocator, &.{ root, "explicit.zon" });
    defer t.allocator.free(explicit);

    // untrusted workspace
    {
        var loaded = try load(t.allocator, t.io, .{ .workspace = ws, .explicit = explicit, .trust = .untrusted, .env = .{ .vars = &vars } });
        defer loaded.deinit();
        const c = loaded.config;
        try t.expectEqual(@as(u8, 8), c.editor.tab_width); // workspace over home
        try t.expectEqual(Config.InputStyle.vim, c.editor.input_style); // home survives
        try t.expect(c.ipc.write_screen); // explicit
        try t.expectEqual(@as(usize, 2), c.keys.global.count()); // extended
        try t.expectEqualStrings("rust-analyzer", c.lsp.get("rust").?.cmd.?); // home lsp kept
        try t.expect(c.lsp.get("zig").?.cmd == null); // untrusted cmd stripped …
        try t.expectEqual(@as(usize, 1), c.lsp.get("zig").?.extensions.len); // … extensions kept
        try t.expectEqual(Config.MdEngine.builtin, c.ui.md_preview_engine); // custom engine stripped
        try t.expectEqual(@as(u16, 40), c.ui.tree_width); // ordinary key applied
        // diagnostics: the strip note + the unknown section in explicit
        try t.expectEqual(@as(usize, 2), loaded.diagnostics.count());
        try t.expectEqualStrings(explicit, loaded.explicit_path.?);
        try t.expect(std.mem.endsWith(u8, loaded.home_path.?, "home/config.zon"));
    }
    // trusted workspace
    {
        var loaded = try load(t.allocator, t.io, .{ .workspace = ws, .trust = .trusted, .env = .{ .vars = &vars } });
        defer loaded.deinit();
        try t.expectEqualStrings("zls", loaded.config.lsp.get("zig").?.cmd.?);
        try t.expectEqualStrings("evil", loaded.config.ui.md_preview_engine.custom);
        try t.expect(!loaded.config.ipc.write_screen);
        try t.expectEqual(@as(usize, 0), loaded.diagnostics.count());
    }
    // a broken explicit file: diagnostics, everything else intact
    {
        const broken = try std.fs.path.join(t.allocator, &.{ root, "broken.zon" });
        defer t.allocator.free(broken);
        var loaded = try load(t.allocator, t.io, .{ .workspace = ws, .explicit = broken, .env = .{ .vars = &vars } });
        defer loaded.deinit();
        try t.expectEqual(@as(u8, 8), loaded.config.editor.tab_width);
        try t.expect(loaded.diagnostics.count() >= 1);
        try t.expectEqualStrings(broken, loaded.diagnostics.items.items[0].file);
    }
    // no files at all: pure defaults, no diagnostics
    {
        const nowhere = try std.fs.path.join(t.allocator, &.{ root, "nowhere" });
        defer t.allocator.free(nowhere);
        var loaded = try load(t.allocator, t.io, .{ .workspace = nowhere, .env = .{ .vars = &vars } });
        defer loaded.deinit();
        try t.expectEqual(@as(u8, 2), loaded.config.editor.tab_width); // home still applies
        try t.expectEqual(@as(usize, 0), loaded.diagnostics.count());
    }
}

test "docs config example parses clean" {
    // The reference file IS the schema, or it is wrong: `docs/CONFIG.md`'s
    // ```zon block must decode with zero diagnostics.
    const md = try Io.Dir.cwd().readFileAlloc(t.io, "docs/CONFIG.md", t.allocator, .limited(1 << 20));
    defer t.allocator.free(md);
    const open = std.mem.indexOf(u8, md, "```zon\n") orelse return error.TestUnexpectedResult;
    const body_start = open + "```zon\n".len;
    const close = std.mem.indexOfPos(u8, md, body_start, "\n```") orelse return error.TestUnexpectedResult;
    const src = try t.allocator.dupeZ(u8, md[body_start..close]);
    defer t.allocator.free(src);

    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(), src, "docs/CONFIG.md", &f.diags);
    if (f.diags.count() != 0) {
        const text = try f.rendered();
        defer t.allocator.free(text);
        std.debug.print("docs/CONFIG.md example has diagnostics:\n{s}", .{text});
        return error.TestUnexpectedResult;
    }
    // every section is present in the example
    inline for (@typeInfo(Patch(Config)).@"struct".fields) |fld| {
        const v = @field(p, fld.name);
        if (comptime patch_mod.isMap(fld.type)) {
            if (v.count() == 0) {
                std.debug.print("docs/CONFIG.md example is missing map section .{s}\n", .{fld.name});
                return error.TestUnexpectedResult;
            }
        } else if (v == null) {
            std.debug.print("docs/CONFIG.md example is missing section .{s}\n", .{fld.name});
            return error.TestUnexpectedResult;
        }
    }
    // and it applies onto the default
    var cfg: Config = .{};
    try apply(f.arena(), &cfg, p);
    try normalize(f.arena(), &cfg, &f.diags, "/home/u");
    try t.expectEqual(@as(usize, 0), f.diags.count());
    try t.expectEqualStrings("rust-analyzer", cfg.lsp.get("rust").?.cmd.?);
    try t.expectEqual(@as(usize, 2), cfg.startup.layout.len);
    try t.expectEqual(Config.LintParser.shellcheck, cfg.linters.get("sh").?.parser);
    try t.expectEqualStrings("work", cfg.ai.extra.get("claude_accounts").?.array[0].get("name").?.string);
}
