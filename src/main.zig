const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const e2e = @import("e2e/root.zig");
const headless = @import("headless.zig");
const app_driver = @import("app/driver.zig");
const loop = @import("tui/loop.zig");
const Term = @import("tui/term.zig").Term;
const input = @import("input/mod.zig");
const config = @import("config/root.zig");
const http_cli = @import("http/cli.zig");

/// What `--version` prints: `-Dversion=` at build time, or the derived
/// dev string (see build.zig, the release block).
pub const version = build_options.version;

/// A crash prints its trace on a readable terminal, not inside the alt
/// screen with the mouse still reporting — on Windows, with the console
/// modes put back too.
pub const panic = Term.Panic;

/// The application's driver factory: the same App the terminal runs,
/// behind the `e2e.Driver` vtable for `test` and `--headless`.
pub const app_factory: ?e2e.Factory = app_driver.default_factory.factory();

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    var out_buf: [4096]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out.interface;

    if (args.len >= 2 and std.mem.eql(u8, args[1], "test")) return testSubcommand(gpa, io, env, args[2..], w);
    if (args.len >= 2) if (httpSubcommand(gpa, io, env, args[1], args[2..], w)) |code| return code;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            try w.print("mnml-zig {s}\n", .{version});
            try w.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return usage(w, "mnml-zig [WORKSPACE] [FILE…] [--input vim|standard] [--ascii] [--config PATH] [--headless] [--startup-picker] | test [PATH…] [--gate] [--filter NAME] [--skip NAME] | run FILE | chain run FILE | discover SPEC | sync | sync-check | proxy --url URL");
    }
    if (parseInputFlag(args[1..], w)) |style| {
        app_driver.default_factory.input_style = style;
    } else |_| return 2;
    for (args[1..]) |a| if (std.mem.eql(u8, a, "--headless")) return headlessSubcommand(gpa, io, env, args[1..], w);
    return terminalMain(gpa, io, env, args[1..], w);
}

/// `--input vim|standard` / `--input=vim`, anywhere on the line; null
/// when absent (the config decides).
fn parseInputFlag(argv: []const [:0]const u8, w: *Io.Writer) !?input.Style {
    var style: ?input.Style = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        var value: ?[]const u8 = null;
        if (std.mem.eql(u8, a, "--input")) {
            i += 1;
            if (i >= argv.len) {
                _ = try usage(w, "--input needs vim or standard");
                return error.Usage;
            }
            value = argv[i];
        } else if (std.mem.startsWith(u8, a, "--input=")) value = a["--input=".len..];
        const v = value orelse continue;
        if (std.mem.eql(u8, v, "vim")) {
            style = .vim;
        } else if (std.mem.eql(u8, v, "standard")) {
            style = .standard;
        } else {
            _ = try usage(w, "--input needs vim or standard");
            return error.Usage;
        }
    }
    return style;
}

// ─── mnml-zig [WS] [FILE…] ──────────────────────────────────────────────

/// `--config PATH` / `--config=PATH`, anywhere on the line.
fn parseConfigFlag(argv: []const [:0]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--config")) {
            if (i + 1 < argv.len) return argv[i + 1];
            return null;
        }
        if (std.mem.startsWith(u8, a, "--config=")) return a["--config=".len..];
    }
    return null;
}

/// The three config layers for `workspace`, with the command line's
/// overrides applied, plus where mnml keeps its state. `loaded` is the
/// caller's to hand on (the App frees it).
const Startup = struct { loaded: config.Loaded, data_root: []u8 };

fn loadConfig(gpa: Allocator, io: Io, env: *std.process.Environ.Map, workspace: []const u8, argv: []const [:0]const u8, ascii: bool) !Startup {
    const exe_dir: ?[]u8 = std.process.executableDirPathAlloc(io, gpa) catch null;
    defer if (exe_dir) |d| gpa.free(d);
    const cfg_env: config.data_root.Env = .{ .vars = env, .exe_dir = exe_dir };
    const data_root = try config.data_root.dataRoot(gpa, io, cfg_env);
    errdefer gpa.free(data_root);
    var loaded = try config.load.load(gpa, io, .{
        .explicit = parseConfigFlag(argv),
        .workspace = workspace,
        .trust = .ask,
        .data_root = data_root,
        .env = cfg_env,
    });
    if (ascii) loaded.config.ui.ascii_icons = true;
    if (app_driver.default_factory.input_style) |s| loaded.config.editor.input_style = @import("app.zig").App.configStyleOf(s);
    return .{ .loaded = loaded, .data_root = data_root };
}

/// `--startup-picker` is the flag spelling of `MNML_STARTUP_PICKER=1`:
/// the picker reads the environment (`startup_picker.wanted`), so the
/// flag sets the variable for this process. True when it was on the line.
fn applyStartupPickerFlag(env: *std.process.Environ.Map, argv: []const []const u8) Allocator.Error!bool {
    for (argv) |a| if (std.mem.eql(u8, a, "--startup-picker")) {
        try env.put("MNML_STARTUP_PICKER", "1");
        return true;
    };
    return false;
}

/// The terminal: the first non-flag argument that is a directory is the
/// workspace (default: cwd); every other non-flag argument is opened.
fn terminalMain(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var workspace: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var ascii = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--input") or std.mem.eql(u8, a, "--config")) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--ascii")) {
            ascii = true;
            continue;
        }
        if (a.len > 0 and a[0] == '-') continue;
        const st = Io.Dir.cwd().statFile(io, a, .{}) catch {
            try files.append(arena, a);
            continue;
        };
        if (st.kind == .directory and workspace == null) workspace = a else try files.append(arena, a);
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_len = Io.Dir.cwd().realPathFile(io, workspace orelse ".", &cwd_buf) catch return usage(w, "workspace is not a directory");
    const ws_abs = cwd_buf[0..ws_len];
    {
        const plain = try arena.alloc([]const u8, argv.len);
        for (argv, 0..) |a, k| plain[k] = a;
        _ = try applyStartupPickerFlag(env, plain);
    }
    const startup = try loadConfig(gpa, io, env, ws_abs, argv, ascii);
    defer gpa.free(startup.data_root);
    const cfg: loop.Options = .{
        .loaded = startup.loaded,
        .workspace = ws_abs,
        .data_root = startup.data_root,
        .files = files.items,
    };
    return loop.run(gpa, io, env, cfg) catch |err| switch (err) {
        error.NotATty => return usage(w, "stdout is not a terminal (use --headless)"),
        else => return err,
    };
}

// ─── mnml-zig run / chain / discover / sync / proxy ─────────────────────

/// The HTTP client's subcommands, when `verb` is one of them.
fn httpSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, verb: []const u8, rest: []const [:0]const u8, w: *Io.Writer) ?u8 {
    var err_buf: [4096]u8 = undefined;
    var err_file: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const std_: http_cli.Std = .{ .out = w, .err = &err_file.interface };
    var argv_buf: [64][]const u8 = undefined;
    const n = @min(rest.len, argv_buf.len);
    for (rest[0..n], 0..) |a, i| argv_buf[i] = a;
    const argv = argv_buf[0..n];
    const result: anyerror!u8 = if (std.mem.eql(u8, verb, "run"))
        http_cli.run(gpa, io, env, argv, std_)
    else if (std.mem.eql(u8, verb, "chain"))
        http_cli.chainRun(gpa, io, env, argv, std_)
    else if (std.mem.eql(u8, verb, "discover"))
        http_cli.discoverCmd(gpa, io, argv, std_)
    else if (std.mem.eql(u8, verb, "sync"))
        http_cli.syncCmd(gpa, io, argv, std_, false)
    else if (std.mem.eql(u8, verb, "sync-check"))
        http_cli.syncCmd(gpa, io, argv, std_, true)
    else if (std.mem.eql(u8, verb, "proxy"))
        http_cli.proxyCmd(gpa, io, env, argv, std_)
    else
        return null;
    const code = result catch 1;
    err_file.interface.flush() catch {};
    w.flush() catch {};
    return code;
}

// ─── mnml-zig test ──────────────────────────────────────────────────────

/// `mnml-zig test [PATH…] [--gate] [--sizes 80x24,120x40] [--filter NAME] [--skip NAME] [--parse] [--stub]`
///
/// Runs `.test` scripts (default `tests/e2e` + `tests/e2e-zig`). `--gate` runs the Phase-0
/// gate list from `tools/gate.txt`. `--filter` keeps the files whose
/// name contains it (what `zig build test -Dtest-filter=…` passes);
/// `--skip` (repeatable) leaves a file out and says so. `--parse` only
/// parses. `--stub` drives the recording stub instead of the App —
/// exercises the harness, proves nothing about the editor. Exit 1 on
/// any failure.
fn testSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var sizes: std.ArrayList(e2e.Size) = .empty;
    defer sizes.deinit(gpa);
    var skips: std.ArrayList([]const u8) = .empty;
    defer skips.deinit(gpa);
    var name_filter: ?[]const u8 = null;
    var gate = false;
    var parse_only = false;
    var use_stub = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--gate")) {
            gate = true;
        } else if (std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i >= argv.len) return usage(w, "--filter needs a name");
            name_filter = argv[i];
        } else if (std.mem.startsWith(u8, a, "--filter=")) {
            name_filter = a["--filter=".len..];
        } else if (std.mem.eql(u8, a, "--skip")) {
            i += 1;
            if (i >= argv.len) return usage(w, "--skip needs a name");
            try skips.append(gpa, argv[i]);
        } else if (std.mem.startsWith(u8, a, "--skip=")) {
            try skips.append(gpa, a["--skip=".len..]);
        } else if (std.mem.eql(u8, a, "--parse")) {
            parse_only = true;
        } else if (std.mem.eql(u8, a, "--stub")) {
            use_stub = true;
        } else if (std.mem.eql(u8, a, "--sizes")) {
            i += 1;
            if (i >= argv.len) return usage(w, "--sizes needs a list like 80x24,120x40");
            var it = std.mem.splitScalar(u8, argv[i], ',');
            while (it.next()) |tok| try sizes.append(gpa, parseSize(tok) orelse return usage(w, "bad size (want WxH)"));
        } else if (std.mem.startsWith(u8, a, "--sizes=")) {
            var it = std.mem.splitScalar(u8, a["--sizes=".len..], ',');
            while (it.next()) |tok| try sizes.append(gpa, parseSize(tok) orelse return usage(w, "bad size (want WxH)"));
        } else if (a.len > 0 and a[0] == '-') {
            // Unknown flags are ignored, as the Rust runner ignores them.
        } else try paths.append(gpa, a);
    }

    var gate_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (gate_paths.items) |p| gpa.free(p);
        gate_paths.deinit(gpa);
    }
    if (gate) {
        const list = Io.Dir.cwd().readFileAlloc(io, "tools/gate.txt", gpa, .unlimited) catch return usage(w, "--gate needs tools/gate.txt");
        defer gpa.free(list);
        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r");
            if (name.len == 0 or name[0] == '#') continue;
            const p = try std.fmt.allocPrint(gpa, "tests/e2e/{s}.test", .{name});
            try gate_paths.append(gpa, p);
            try paths.append(gpa, p);
        }
    }
    if (paths.items.len == 0) {
        try paths.append(gpa, "tests/e2e");
        // `tests/e2e` is the shared suite (a symlink to Rust mnml's);
        // Zig-only scripts live beside it, where the Rust runner — which
        // walks recursively and knows no `# zig-only` — cannot see them.
        try paths.append(gpa, "tests/e2e-zig");
    }

    if (parse_only) return parseOnly(gpa, io, paths.items, w);

    // `mnml-zig test` is typed by the user, so `shell` steps are allowed
    // unless the variable says otherwise; the gate exists for discovery
    // paths on a cloned repo, not for explicit invocations.
    const allow_shell = std.mem.eql(u8, env.get("MNML_E2E_ALLOW_SHELL") orelse "1", "1");
    const network = std.mem.eql(u8, env.get("MNML_E2E_NETWORK") orelse "0", "1");
    const timeout: u64 = if (env.get("MNML_E2E_FILE_TIMEOUT_SECS")) |v| std.fmt.parseInt(u64, v, 10) catch 120 else 120;
    // `TMPDIR` is the POSIX spelling, `TEMP` / `TMP` Windows's.
    const tmp_root = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
    const data_root = try e2e.runner.makeTempDir(gpa, io, tmp_root);
    defer {
        Io.Dir.cwd().deleteTree(io, data_root) catch {};
        gpa.free(data_root);
    }
    const opts: e2e.Options = .{
        .allow_shell = allow_shell,
        .network = network,
        .file_timeout_secs = timeout,
        .sizes = if (sizes.items.len > 0) sizes.items else &.{e2e.runner.content_size},
        .shell = env.get("SHELL") orelse "/bin/sh",
        .tmp_root = tmp_root,
        .data_root = data_root,
        .name_filter = name_filter,
        .skip = skips.items,
    };

    var stub_factory: e2e.driver.StubFactory = .{};
    var no_app: u8 = 0;
    const factory: e2e.Factory = if (use_stub)
        stub_factory.factory()
    else
        app_factory orelse blk: {
            try w.writeAll("mnml-zig test: no App driver yet — every file FAILs (use --parse to check scripts, --stub to exercise the harness)\n");
            break :blk .{ .ptr = &no_app, .create = noAppDriver };
        };
    const stats = try e2e.runner.runPaths(gpa, io, factory, paths.items, opts, w);
    return if (stats.failed == 0) 0 else 1;
}

fn noAppDriver(_: *anyopaque, _: Allocator, _: Io, _: e2e.driver.Config) anyerror!e2e.Driver {
    return error.NoAppDriverYet;
}

fn parseSize(tok: []const u8) ?e2e.Size {
    const x = std.mem.indexOfScalar(u8, tok, 'x') orelse return null;
    const cols = std.fmt.parseInt(u16, tok[0..x], 10) catch return null;
    const rows = std.fmt.parseInt(u16, tok[x + 1 ..], 10) catch return null;
    if (cols < 10 or rows < 10) return null;
    return .{ .cols = cols, .rows = rows };
}

fn usage(w: *Io.Writer, msg: []const u8) !u8 {
    try w.print("mnml-zig test: {s}\n", .{msg});
    try w.flush();
    return 2;
}

/// Parse every file and report; the way to validate the corpus before
/// there is an App to run it against.
fn parseOnly(gpa: Allocator, io: Io, roots: []const []const u8, w: *Io.Writer) !u8 {
    var total: usize = 0;
    var failed: usize = 0;
    for (roots) |root| {
        const files = try e2e.runner.collectFiles(gpa, io, root);
        defer {
            for (files) |p| gpa.free(p);
            gpa.free(files);
        }
        for (files) |path| {
            total += 1;
            const name = std.fs.path.basename(path);
            const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
                failed += 1;
                try w.print("  FAIL {s} — can't read: {s}\n", .{ name, @errorName(e) });
                continue;
            };
            defer gpa.free(text);
            var diag: e2e.parser.Diagnostic = .{};
            var script = e2e.parser.parse(gpa, text, &diag) catch |e| switch (e) {
                error.Syntax => {
                    failed += 1;
                    try w.print("  FAIL {s} — {s}\n", .{ name, diag.message() });
                    continue;
                },
                else => return e,
            };
            script.deinit();
            try w.print("  ok   {s}\n", .{name});
        }
    }
    try w.print("\n{d}/{d} passed\n", .{ total - failed, total });
    try w.flush();
    return if (failed == 0) 0 else 1;
}

// ─── mnml-zig [WS] --headless ───────────────────────────────────────────

/// `mnml-zig [WORKSPACE] --headless [--stub]` — the virtual screen driven
/// through `<ws>/.mnml/<subdir>/`. `MNML_COLS` / `MNML_ROWS` size it,
/// `MNML_IPC_DIR` relocates the channel. Exit 75 asks the wrapper to
/// rebuild and relaunch.
fn headlessSubcommand(gpa: Allocator, io: Io, env: *std.process.Environ.Map, argv: []const [:0]const u8, w: *Io.Writer) !u8 {
    var use_stub = false;
    var workspace: ?[]const u8 = null;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--stub")) {
            use_stub = true;
        } else if (a.len > 0 and a[0] != '-') workspace = a;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_rel = workspace orelse ".";
    const ws = Io.Dir.cwd().realPathFile(io, ws_rel, &cwd_buf) catch return usage(w, "workspace is not a directory");
    const ws_abs = cwd_buf[0..ws];

    const size = headless.sizeFromEnv(env.get("MNML_COLS"), env.get("MNML_ROWS"));
    const opts: headless.Options = .{
        .size = size,
        .ipc = .{ .dir_override = env.get("MNML_IPC_DIR"), .subdir = build_options.ipc_subdir },
    };
    var stub_factory: e2e.driver.StubFactory = .{};
    const factory: e2e.Factory = if (use_stub) stub_factory.factory() else app_factory orelse {
        try w.writeAll("mnml-zig --headless: no App driver yet (use --stub to drive the recording stub)\n");
        try w.flush();
        return 2;
    };
    const startup = try loadConfig(gpa, io, env, ws_abs, argv, false);
    defer gpa.free(startup.data_root);
    // `make` owns `loaded` from here, whatever it returns.
    const cfg: e2e.driver.Config = .{ .workspace = ws_abs, .data_root = startup.data_root, .cols = size.cols, .rows = size.rows, .cfg = startup.loaded.config, .loaded = startup.loaded, .startup_hook = true };
    const driver = try factory.make(gpa, io, cfg);
    defer driver.deinit();
    const restart = try headless.run(gpa, io, driver, ws_abs, opts);
    return if (restart) 75 else 0;
}

test {
    _ = @import("config/root.zig");
    _ = @import("core/alloc.zig");
    _ = @import("core/key.zig");
    _ = @import("core/event.zig");
    _ = @import("commands/specs.zig");
    _ = @import("core/keymap.zig");
    _ = @import("core/command.zig");
    _ = @import("core/panel.zig");
    _ = @import("core/hooks.zig");
    _ = @import("core/clipboard_os.zig");
    _ = @import("app.zig");
    _ = @import("regex/regex.zig");
    _ = @import("ipc/root.zig");
    _ = @import("e2e/root.zig");
    _ = @import("headless.zig");
    _ = @import("editor/edit_op.zig");
    _ = @import("editor/clipboard.zig");
    _ = @import("editor/editor.zig");
    _ = @import("editor/editorconfig.zig");
    _ = @import("editor/undo.zig");
    _ = @import("editor/motion.zig");
    _ = @import("editor/insert.zig");
    _ = @import("editor/delete.zig");
    _ = @import("editor/select.zig");
    _ = @import("editor/line.zig");
    _ = @import("editor/register.zig");
    _ = @import("editor/apply.zig");
    _ = @import("editor/buffer.zig");
    _ = @import("input/mod.zig");
    _ = @import("input/standard.zig");
    _ = @import("input/vim.zig");
    _ = @import("app/driver.zig");
    _ = @import("scripting/lua.zig");
    _ = @import("app/smoke_test.zig");
    _ = @import("http/cli.zig");
    _ = @import("http/proxy.zig");
    _ = @import("http/yaml.zig");
    _ = @import("http/discover.zig");
    _ = @import("http/sources.zig");
    _ = @import("tui/loop.zig");
    _ = @import("ui/ui.zig");
}

test "version string is set" {
    try std.testing.expect(version.len > 0);
}

test "size flags parse WxH and reject anything under 10" {
    try std.testing.expectEqual(e2e.Size{ .cols = 80, .rows = 24 }, parseSize("80x24").?);
    try std.testing.expectEqual(@as(?e2e.Size, null), parseSize("80"));
    try std.testing.expectEqual(@as(?e2e.Size, null), parseSize("8x24"));
    try std.testing.expectEqual(@as(?e2e.Size, null), parseSize("axb"));
}

test "--startup-picker is MNML_STARTUP_PICKER=1 for this process" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!try applyStartupPickerFlag(&env, &.{ "ws", "--ascii" }));
    try std.testing.expect(env.get("MNML_STARTUP_PICKER") == null);
    try std.testing.expect(try applyStartupPickerFlag(&env, &.{ "--startup-picker", "ws" }));
    try std.testing.expectEqualStrings("1", env.get("MNML_STARTUP_PICKER").?);
}
