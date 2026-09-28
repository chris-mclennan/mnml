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
const trusted = @import("trusted.zig");
const data_root = @import("data_root.zig");
const os_path = @import("../core/os_path.zig");

pub const Patch = patch_mod.Patch;
pub const apply = patch_mod.apply;
pub const Diagnostics = diag_mod.Diagnostics;
pub const Diagnostic = diag_mod.Diagnostic;

/// How the workspace layer is treated. `.ask` consults the trust store
/// under `Options.data_root`: a remembered fingerprint applies the layer
/// in full, anything else strips it and sets `Loaded.trust_prompt` so
/// the app can put the question.
pub const Trust = enum { trusted, untrusted, ask };

/// What the trust dialog shows: the workspace's exec-bearing claims and
/// the digest that, once remembered, keeps it from asking again.
pub const TrustPrompt = struct {
    claims: []const trust_mod.Claim,
    fingerprint: u64,
};

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
    /// Set when the workspace layer was stripped under `.ask` and the
    /// user has not answered yet.
    trust_prompt: ?TrustPrompt = null,
    /// Whether the workspace layer applied in full.
    workspace_trusted: bool,
    /// A 0.2 `config.toml` where the workspace's / the home `config.zon`
    /// would be, with no `.zon` beside it — never read; the app shows
    /// the pointer at the converter once per data root and the
    /// statusline's RESTRICTED chip for the workspace one.
    workspace_toml: ?[]const u8 = null,
    home_toml: ?[]const u8 = null,
    /// The options this was loaded with, strings re-homed on the arena,
    /// so `reload` can run the same load with a different trust.
    opts: Options,

    /// The same three layers again, with `trust` — what Trust in the
    /// dialog does. A fresh `Loaded`; the caller retires this one.
    pub fn reload(self: *const Loaded, gpa: Allocator, io: Io, trust: Trust) Allocator.Error!Loaded {
        var o = self.opts;
        o.trust = trust;
        return load(gpa, io, o);
    }

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
    /// Where `trusted_workspaces.zon` lives; required for `.ask`.
    data_root: ?[]const u8 = null,
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
        // A workspace with no layer, no `init.lua` and no manifests has
        // nothing to distrust: under `.ask` it is trusted, as
        // `decideTrust` says of a layer with no claims. (It used to stay
        // false, and a DAP adapter or LSP server written into the
        // config AFTER launch was then never re-read until a restart.)
        // A layer below decides otherwise when it exists.
        .workspace_trusted = opts.trust != .untrusted,
        .opts = .{
            .explicit = if (opts.explicit) |p| try arena.dupe(u8, p) else null,
            .workspace = try arena.dupe(u8, opts.workspace),
            .trust = opts.trust,
            .data_root = if (opts.data_root) |d| try arena.dupe(u8, d) else null,
            .env = .{ .vars = opts.env.vars, .exe_dir = if (opts.env.exe_dir) |d| try arena.dupe(u8, d) else null },
        },
    };
    if (loaded.home_path) |p| {
        if (try readLayer(arena, io, &loaded.diagnostics, p)) |patch| try apply(arena, &loaded.config, patch);
        loaded.home_toml = try tomlBeside(arena, io, p);
    }
    loaded.workspace_toml = try tomlBeside(arena, io, loaded.workspace_path);
    // `.mnml/init.lua` beside the config is an exec-bearing claim of its
    // own (D10): a workspace with the script and no config still needs
    // the trust decision.
    const init_lua_path = try std.fs.path.join(arena, &.{ opts.workspace, ".mnml", "init.lua" });
    const facts: trust_mod.Facts = .{
        .init_lua = if (Io.Dir.cwd().access(io, init_lua_path, .{})) true else |_| false,
        // The manifests beside the config are claims too (the
        // `workspace_manifests` sink).
        .manifests = try trust_mod.manifestNames(arena, io, opts.workspace),
    };
    const ws_layer = try readLayer(arena, io, &loaded.diagnostics, loaded.workspace_path);
    if (ws_layer != null or facts.init_lua or facts.manifests.len > 0) {
        var p: Patch(Config) = ws_layer orelse .{};
        const trust: Trust = switch (opts.trust) {
            .trusted, .untrusted => opts.trust,
            .ask => try decideTrust(gpa, io, &loaded, p, facts),
        };
        loaded.workspace_trusted = trust == .trusted;
        if (trust == .untrusted) {
            const n = try trust_mod.strip(arena, &p);
            if (n != 0) try loaded.diagnostics.addFmt(loaded.workspace_path, 0, 0, "untrusted workspace: {d} exec-bearing setting(s) ignored", .{n});
        }
        try apply(arena, &loaded.config, p);
    }
    if (loaded.explicit_path) |p| {
        if (try readLayer(arena, io, &loaded.diagnostics, p)) |patch| try apply(arena, &loaded.config, patch);
    }

    try normalize(arena, &loaded.config, &loaded.diagnostics, os_path.home(opts.env.vars));
    return loaded;
}

/// The 0.2.x `config.toml` beside an absent `config.zon` at
/// `zon_path`, or null. mnml-zig never reads it (E2); this is the one
/// thing it will ever say about TOML, and the app says it once.
pub fn tomlBeside(arena: Allocator, io: Io, zon_path: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.endsWith(u8, zon_path, ".zon")) return null;
    if (Io.Dir.cwd().access(io, zon_path, .{})) |_| return null else |_| {}
    const toml = try std.mem.concat(arena, u8, &.{ zon_path[0 .. zon_path.len - ".zon".len], ".toml" });
    Io.Dir.cwd().access(io, toml, .{}) catch return null;
    return toml;
}

/// One layer file as a patch; null when the file is absent (fine) or
/// unreadable (a diagnostic). A 0.2.x `config.toml` beside an absent
/// `.zon` is `tomlBeside`'s to report, not a diagnostic: a diagnostic
/// toasts on every launch.
fn readLayer(arena: Allocator, io: Io, diags: *Diagnostics, path: []const u8) Allocator.Error!?Patch(Config) {
    const src = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.addFmt(path, 0, 0, "cannot read: {s}", .{@errorName(e)});
            return null;
        },
    };
    return try parseLayer(arena, src, path, diags);
}

/// `.ask`: a layer with no exec-bearing claim needs no answer; one whose
/// claims match the store is trusted; anything else is stripped and the
/// prompt is set for the app.
fn decideTrust(gpa: Allocator, io: Io, loaded: *Loaded, p: Patch(Config), facts: trust_mod.Facts) Allocator.Error!Trust {
    const arena = loaded.arena.allocator();
    const claims = try trust_mod.claimsWith(arena, p, facts);
    if (claims.len == 0) return .trusted;
    const fp = trust_mod.fingerprint(claims);
    if (loaded.opts.data_root) |root| {
        const store = try trusted.storePath(arena, root);
        if (try trusted.lookup(gpa, io, store, loaded.opts.workspace)) |remembered| {
            if (remembered == fp) return .trusted;
        }
    }
    loaded.trust_prompt = .{ .claims = claims, .fingerprint = fp };
    return .untrusted;
}

// ─── after the merge ─────────────────────────────────────────────────────

/// Clamp what the Rust config clamped, expand `~`, and drop startup
/// layout entries that cannot open. Runs once, after every layer.
pub fn normalize(arena: Allocator, cfg: *Config, diags: *Diagnostics, home: ?[]const u8) Allocator.Error!void {
    cfg.editor.chord_timeout_ms = std.math.clamp(cfg.editor.chord_timeout_ms, Config.chord_timeout_ms_min, Config.chord_timeout_ms_max);
    cfg.ai.suggest_idle_ms = std.math.clamp(cfg.ai.suggest_idle_ms, Config.suggest_idle_ms_min, Config.suggest_idle_ms_max);
    cfg.ai.suggest_timeout_ms = std.math.clamp(cfg.ai.suggest_timeout_ms, Config.suggest_timeout_ms_min, Config.suggest_timeout_ms_max);
    cfg.ai.cli_timeout_ms = std.math.clamp(cfg.ai.cli_timeout_ms, Config.cli_timeout_ms_min, Config.cli_timeout_ms_max);
    cfg.ui.tree_width = std.math.clamp(cfg.ui.tree_width, Config.tree_width_min, Config.tree_width_max);
    cfg.ui.focus_follows_mouse_delay_ms = @min(cfg.ui.focus_follows_mouse_delay_ms, Config.focus_follows_mouse_delay_ms_max);
    cfg.ui.hover_help_grace_ms = @min(cfg.ui.hover_help_grace_ms, Config.hover_help_grace_ms_max);
    cfg.ui.hover_help_height = std.math.clamp(cfg.ui.hover_help_height, Config.hover_help_height_min, Config.hover_help_height_max);
    cfg.ui.bottom_panel_height = std.math.clamp(cfg.ui.bottom_panel_height, Config.bottom_panel_height_min, Config.bottom_panel_height_max);
    // // changed (sidebar-autohide): the two dwells, and the width
    // rule — Rust clamps a non-zero `auto_hide_narrow_width` to
    // 40..300 (`config.rs`), which keeps a typo like `4` from hiding
    // the columns on every screen.
    cfg.ui.sidebar_reveal_ms = @min(cfg.ui.sidebar_reveal_ms, Config.sidebar_dwell_ms_max);
    cfg.ui.sidebar_hide_ms = @min(cfg.ui.sidebar_hide_ms, Config.sidebar_dwell_ms_max);
    // // changed (launcher-dock): the dock's dwells borrow the same ceiling.
    cfg.ui.dock.reveal_ms = @min(cfg.ui.dock.reveal_ms, Config.sidebar_dwell_ms_max);
    cfg.ui.dock.hide_ms = @min(cfg.ui.dock.hide_ms, Config.sidebar_dwell_ms_max);
    // `ui.auto_hide_narrow_width` is the old name of `sidebar_auto_below`:
    // one rule for a narrow terminal's columns, not two that disagree.
    // A non-zero value is read as the new key, and the startup note says
    // to rename it.
    if (cfg.ui.auto_hide_narrow_width != 0) {
        cfg.ui.sidebar_auto_below = cfg.ui.auto_hide_narrow_width;
        try diags.addFmt("config", 0, 0, "ui.auto_hide_narrow_width is now ui.sidebar_auto_below — {d} is read as that; rename the key", .{cfg.ui.auto_hide_narrow_width});
        cfg.ui.auto_hide_narrow_width = 0;
    }
    // The same range for the rule that makes a docked column auto-hide
    // on a narrow terminal, for the same reason: a stray `4` must not
    // mean "never", nor `4000` "always".
    if (cfg.ui.sidebar_auto_below != 0) cfg.ui.sidebar_auto_below = std.math.clamp(cfg.ui.sidebar_auto_below, 40, 300);
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

/// `~`, `~/…` (and `~\…` on Windows) against `home`; the result never
/// borrows `home` — the environment map does not outlive the config.
fn expandTilde(arena: Allocator, path: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    const out = try os_path.expandTilde(arena, path, home, .native);
    return if (home != null and out.ptr == home.?.ptr) arena.dupe(u8, out) else out;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

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
    try t.expectEqualStrings("work", p.ai.?.claude_accounts.?[0].name);
    try sdk_testing.expectPath("/usr/bin/cargo", p.tools.?.get("cargo").?.get("path").?.string);
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

test "config: a `.jira` section (domain / ticket_prefix: never read, removed) is an unknown section, reported and skipped" {
    const f = try Fixture.init();
    defer f.deinit();
    const p = try parseLayer(f.arena(), ".{ .jira = .{ .domain = \"acme\", .ticket_prefix = \"TE-\" }, .session = .{ .restore = false } }", "c.zon", &f.diags);
    try t.expectEqual(@as(?bool, false), p.session.?.restore);
    try t.expectEqual(@as(usize, 1), f.diags.count());
    try t.expect(std.mem.indexOf(u8, f.diags.items.items[0].msg, "unknown section 'jira'") != null);
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
    cfg.ai.suggest_idle_ms = 1;
    cfg.ai.suggest_timeout_ms = 1;
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
    try t.expectEqual(@as(u16, 4), cfg.ui.hover_help_height);
    try t.expectEqual(@as(u16, 100), cfg.editor.chord_timeout_ms);
    // Ghost text's clocks: a typo of `1` would spin a request per
    // keystroke and give it no time to answer.
    try t.expectEqual(@as(u16, Config.suggest_idle_ms_min), cfg.ai.suggest_idle_ms);
    try t.expectEqual(@as(u32, Config.suggest_timeout_ms_min), cfg.ai.suggest_timeout_ms);
    try sdk_testing.expectPath("/home/u/code", cfg.ui.projects_dir);
    try sdk_testing.expectPath("/home/u", cfg.startup.default_workspace.?);
    try t.expectEqual(@as(usize, 2), cfg.startup.layout.len);
    try t.expectEqual(@as(?u8, 99), cfg.startup.layout[1].ratio);
    try t.expectEqual(@as(usize, 2), f.diags.count());
}

test "ui.auto_hide_narrow_width is the old name of ui.sidebar_auto_below: its value moves over, clamped, with a note to rename it" {
    const f = try Fixture.init();
    defer f.deinit();
    var cfg: Config = .{};
    cfg.ui.auto_hide_narrow_width = 120;
    try normalize(f.arena(), &cfg, &f.diags, "/home/u");
    try t.expectEqual(@as(u16, 120), cfg.ui.sidebar_auto_below);
    try t.expectEqual(@as(u16, 0), cfg.ui.auto_hide_narrow_width);
    try t.expectEqual(@as(usize, 1), f.diags.count());
    try t.expect(std.mem.indexOf(u8, f.diags.items.items[0].msg, "rename the key") != null);
    // A stray `4` is clamped like the new key's.
    var c2: Config = .{};
    c2.ui.auto_hide_narrow_width = 4;
    try normalize(f.arena(), &c2, &f.diags, "/home/u");
    try t.expectEqual(@as(u16, 40), c2.ui.sidebar_auto_below);
    // Unset, the new key keeps its own value.
    var c3: Config = .{};
    try normalize(f.arena(), &c3, &f.diags, "/home/u");
    try t.expectEqual(@as(u16, 100), c3.ui.sidebar_auto_below);
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
        try t.expect(sdk_testing.pathEndsWith(loaded.home_path.?, "home/config.zon"));
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
    // a 0.2.x config.toml where the .zon would be: not read, not a
    // diagnostic (that toasted on every launch) — named for the app's
    // once-per-data-root notice and the RESTRICTED chip
    {
        try tmp.dir.createDirPath(t.io, "old/.mnml");
        try tmp.dir.writeFile(t.io, .{ .sub_path = "old/.mnml/config.toml", .data = "[ui]\ntheme = \"gruvbox\"\n" });
        const old = try std.fs.path.join(t.allocator, &.{ root, "old" });
        defer t.allocator.free(old);
        var loaded = try load(t.allocator, t.io, .{ .workspace = old, .env = .{ .vars = &vars } });
        defer loaded.deinit();
        try t.expectEqualStrings("onedark", loaded.config.ui.theme); // not read
        try t.expectEqual(@as(usize, 0), loaded.diagnostics.count());
        try t.expect(sdk_testing.pathEndsWith(loaded.workspace_toml.?, "old/.mnml/config.toml"));
        try t.expect(loaded.home_toml == null); // the home .zon exists
        // A .zon beside the .toml: the .toml is nothing.
        try tmp.dir.writeFile(t.io, .{ .sub_path = "old/.mnml/config.zon", .data = ".{}" });
        var again = try load(t.allocator, t.io, .{ .workspace = old, .env = .{ .vars = &vars } });
        defer again.deinit();
        try t.expect(again.workspace_toml == null);
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
    try t.expectEqual(@as(usize, 2), cfg.ai.claude_accounts.len);
    try t.expectEqualStrings("work", cfg.ai.claude_accounts[1].name);
    try t.expect(cfg.ai.claude_accounts[1].active);
}

test "load: a workspace with nothing to distrust is trusted under .ask; explicit distrust stays untrusted" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    // No `.mnml/` at all.
    var bare = try load(t.allocator, t.io, .{ .workspace = root, .trust = .ask, .env = .{ .vars = &vars } });
    defer bare.deinit();
    try t.expect(bare.workspace_trusted);
    try t.expect(bare.trust_prompt == null);
    // A `.mnml/config.zon` with no exec-bearing claim: the same answer.
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .editor = .{ .tab_width = 2 } }" });
    var plain = try load(t.allocator, t.io, .{ .workspace = root, .trust = .ask, .env = .{ .vars = &vars } });
    defer plain.deinit();
    try t.expect(plain.workspace_trusted);
    // Told untrusted, a bare workspace is untrusted.
    var no = try load(t.allocator, t.io, .{ .workspace = root, .trust = .untrusted, .env = .{ .vars = &vars } });
    defer no.deinit();
    try t.expect(!no.workspace_trusted);
}

test "load: a workspace with only .mnml/init.lua still asks for trust" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/init.lua", .data = "mnml.toast('hi')" });
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var loaded = try load(t.allocator, t.io, .{ .workspace = root, .trust = .ask, .env = .{ .vars = &vars } });
    defer loaded.deinit();
    try t.expect(!loaded.workspace_trusted);
    const prompt = loaded.trust_prompt.?;
    try t.expectEqual(@as(usize, 1), prompt.claims.len);
    try t.expectEqual(trust_mod.Sink.init_lua, prompt.claims[0].sink);
    // Explicit trust runs it; explicit distrust does not prompt.
    var trusted_load = try load(t.allocator, t.io, .{ .workspace = root, .trust = .trusted, .env = .{ .vars = &vars } });
    defer trusted_load.deinit();
    try t.expect(trusted_load.workspace_trusted);
    try t.expect(trusted_load.trust_prompt == null);
}
