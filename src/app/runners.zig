//! Project runners: `cargo.*`, `npm.*`, `pytest.*`, `go.*`, the
//! project-agnostic `test.*`, and the tools picker. Each runs its command
//! in a pty pane below the active one.
//!
//! Detection walks UP from the active editor's directory — so a file in
//! `packages/app/` finds `packages/app/package.json` before the root's —
//! and stops at the workspace root: it never looks above the folder the
//! user opened (`runners_dont_walk_up.test`). A missing manifest is a
//! toast named after the command id (`go.test: no go.mod …`), never the
//! subcommand string, and a missing binary offers its install command.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const pty_pane = @import("pty_pane.zig");
const cmd_picker = @import("cmd_picker.zig");
const Prompt = app_mod.Prompt;

pub const table = .{
    .@"cargo.test" = &cargoTest,
    .@"cargo.check" = &cargoCheck,
    .@"cargo.clippy" = &cargoClippy,
    .@"cargo.build" = &cargoBuild,
    .@"cargo.fmt" = &cargoFmt,
    .@"npm.test" = &npmTest,
    .@"npm.run" = &npmRun,
    .@"npm.run_script" = &npmRunScript,
    .@"npm.build" = &npmBuild,
    .@"npm.start" = &npmStart,
    .@"npm.install" = &npmInstall,
    .@"npm.lint" = &npmLint,
    .@"pytest.run" = &pytestRun,
    .@"pytest.failed" = &pytestFailed,
    .@"go.test" = &goTest,
    .@"go.build" = &goBuild,
    .@"go.vet" = &goVet,
    .@"go.run" = &goRun,
    .@"go.run_path" = &goRunPath,
    .@"test.run_all" = &testRunAll,
    .@"test.run_file" = &testRunFile,
    .@"test.run_at_cursor" = &testRunAtCursor,
    .@"test.rerun_failed" = &testRerunFailed,
    .@"tools.installer" = &toolsInstaller,
};

/// The last runner command, for `test.rerun_failed` in a project whose
/// tool has no "last failed" mode. Owned by the app's runner state.
pub const State = struct {
    last_cmdline: ?[]u8 = null,
    last_cwd: ?[]u8 = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.last_cmdline) |c| gpa.free(c);
        if (self.last_cwd) |c| gpa.free(c);
    }

    fn remember(self: *State, gpa: Allocator, cmdline: []const u8, cwd: []const u8) Allocator.Error!void {
        const c = try gpa.dupe(u8, cmdline);
        errdefer gpa.free(c);
        const d = try gpa.dupe(u8, cwd);
        if (self.last_cmdline) |old| gpa.free(old);
        if (self.last_cwd) |old| gpa.free(old);
        self.last_cmdline = c;
        self.last_cwd = d;
    }
};

// ─── detection ──────────────────────────────────────────────────────────

fn exists(io: Io, dir: []const u8, name: []const u8, buf: []u8) bool {
    const p = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return false;
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

/// The nearest directory at or above `start` holding one of `manifests`,
/// never above `workspace`. `start` must be inside the workspace (or be
/// it); anything else is treated as the workspace itself.
pub fn findManifestDir(io: Io, start: []const u8, manifests: []const []const u8, workspace: []const u8) ?[]const u8 {
    var cur: []const u8 = if (std.mem.startsWith(u8, start, workspace)) start else workspace;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        for (manifests) |m| if (exists(io, cur, m, &buf)) return cur;
        if (std.mem.eql(u8, cur, workspace)) return null;
        cur = std.fs.path.dirname(cur) orelse return null;
        if (cur.len < workspace.len) return null;
    }
}

/// Where a detection walk starts: the directory of the last editor the
/// user was in (a runner pane taking focus must not lose the monorepo
/// context), else the workspace.
pub fn startDir(app: *App) []const u8 {
    const id = app.last_editor orelse return app.workspace;
    const e = app.panes.editor(id) orelse return app.workspace;
    const path = e.buf.path orelse return app.workspace;
    return std.fs.path.dirname(path) orelse app.workspace;
}

/// Is `bin` on the child's PATH?
pub fn onPath(app: *App, bin: []const u8) bool {
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        _ = Io.Dir.cwd().statFile(app.io, bin, .{}) catch return false;
        return true;
    }
    const path = app.env.get("PATH") orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (exists(app.io, dir, bin, &buf)) return true;
    }
    return false;
}

// ─── running ────────────────────────────────────────────────────────────

/// Run `cmdline` through the shell in a pane below, at `cwd`.
pub fn spawn(app: *App, label: []const u8, cmdline: []const u8, cwd: []const u8, kind: pty_pane.Kind) CommandError!PaneId {
    const id = try pty_pane.open(app, .{
        .argv = &.{ "/bin/sh", "-c", cmdline },
        .cwd = cwd,
        .label = label,
        .placement = .below,
        .kind = kind,
    });
    try app.runners.remember(app.gpa, cmdline, cwd);
    return id;
}

/// `<bin> <subcmd>` at the nearest `manifest`. `slug` is the command's
/// identity in the toast (`build` for `npm.build`, which runs `npm run
/// build`); it cannot be read off `subcmd`.
fn runManifestCommand(app: *App, manifest: []const u8, bin: []const u8, slug: []const u8, subcmd: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const root = findManifestDir(app.io, startDir(app), &.{manifest}, app.workspace) orelse
        return app.diag.fail(arena, "{s}.{s}: no {s} found in {s} or any parent", .{ bin, slug, manifest, app.workspace });
    if (!onPath(app, bin)) return offerInstall(app, bin);
    const cmdline = try std.fmt.allocPrint(arena, "{s} {s}", .{ bin, subcmd });
    _ = try spawn(app, cmdline, cmdline, root, .runner);
}

// ─── cargo ──────────────────────────────────────────────────────────────

fn runCargo(app: *App, subcmd: []const u8) CommandError!void {
    const slug = firstWord(subcmd);
    return runManifestCommand(app, "Cargo.toml", "cargo", slug, subcmd);
}

fn firstWord(s: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    return it.next() orelse s;
}

fn cargoTest(app: *App) CommandError!void {
    return runCargo(app, "test");
}
fn cargoCheck(app: *App) CommandError!void {
    return runCargo(app, "check");
}
fn cargoClippy(app: *App) CommandError!void {
    return runCargo(app, "clippy --all-targets");
}
fn cargoBuild(app: *App) CommandError!void {
    return runCargo(app, "build");
}
fn cargoFmt(app: *App) CommandError!void {
    return runCargo(app, "fmt");
}

// ─── npm ────────────────────────────────────────────────────────────────

/// `npm <subcmd>`. A `run <script>` is checked against the nearest
/// package.json's `scripts` first, so a missing script is a toast and not
/// an npm error buried in the pane.
fn runNpm(app: *App, slug: []const u8, subcmd: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (std.mem.startsWith(u8, subcmd, "run ")) {
        const script = std.mem.trim(u8, subcmd["run ".len..], " ");
        if (findManifestDir(app.io, startDir(app), &.{"package.json"}, app.workspace)) |dir| {
            if (try packageScripts(app, dir)) |scripts| {
                if (!scripts.has(script)) {
                    return app.diag.fail(arena, "npm.{s}: no `{s}` script in package.json — available: {s}", .{ slug, script, scripts.preview });
                }
            }
        }
    }
    return runManifestCommand(app, "package.json", "npm", slug, subcmd);
}

const Scripts = struct {
    names: []const []const u8,
    /// `test / build`, or `(none defined)`.
    preview: []const u8,

    fn has(self: Scripts, name: []const u8) bool {
        for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

/// The `scripts` names of `<dir>/package.json`, on the frame arena. Null
/// when the file does not parse or has no `scripts` object.
fn packageScripts(app: *App, dir: []const u8) Allocator.Error!?Scripts {
    const arena = app.frame.allocator();
    const path = try std.fs.path.join(arena, &.{ dir, "package.json" });
    const src = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(4 << 20)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch return null;
    if (parsed != .object) return null;
    const scripts = parsed.object.get("scripts") orelse return null;
    if (scripts != .object) return null;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = scripts.object.iterator();
    while (it.next()) |kv| try names.append(arena, kv.key_ptr.*);
    const preview = if (names.items.len == 0) "(none defined)" else try std.mem.join(arena, " / ", names.items);
    return .{ .names = names.items, .preview = preview };
}

fn npmTest(app: *App) CommandError!void {
    return runNpm(app, "test", "test");
}
fn npmRun(app: *App) CommandError!void {
    return runNpm(app, "run", "run dev");
}
fn npmBuild(app: *App) CommandError!void {
    return runNpm(app, "build", "run build");
}
fn npmStart(app: *App) CommandError!void {
    return runNpm(app, "start", "start");
}
fn npmInstall(app: *App) CommandError!void {
    return runNpm(app, "install", "install");
}
fn npmLint(app: *App) CommandError!void {
    return runNpm(app, "lint", "run lint");
}

/// `npm.run_script`: a prompt for the script name.
fn npmRunScript(app: *App) CommandError!void {
    if (findManifestDir(app.io, startDir(app), &.{"package.json"}, app.workspace) == null)
        return app.diag.fail(app.frame.allocator(), "npm.run_script: no package.json found", .{});
    openPrompt(app, "npm run: script name", .npm_run_script, null);
}

pub fn npmRunScriptAccept(app: *App, text: []const u8) CommandError!void {
    const script = std.mem.trim(u8, text, " \t");
    if (script.len == 0) return app.diag.fail(app.frame.allocator(), "npm.run_script: empty script name", .{});
    const subcmd = try std.fmt.allocPrint(app.frame.allocator(), "run {s}", .{script});
    return runNpm(app, script, subcmd);
}

fn openPrompt(app: *App, title: []const u8, purpose: app_mod.PromptPurpose, seed: ?[]const u8) void {
    app.overlay.deinit(app.gpa);
    var state = Prompt.init(app.gpa, title);
    if (seed) |s| state.setText(app.gpa, s) catch {};
    app.overlay = .{ .prompt = .{ .state = state, .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

// ─── pytest ─────────────────────────────────────────────────────────────

const py_manifests = [_][]const u8{ "pyproject.toml", "setup.py", "requirements.txt" };

fn isPytestFile(name: []const u8) bool {
    return (std.mem.startsWith(u8, name, "test_") and std.mem.endsWith(u8, name, ".py")) or std.mem.endsWith(u8, name, "_test.py");
}

/// `<dir>/tests` or `<dir>/test` holds a `test_*.py` / `*_test.py`, one
/// level deep — a bare `tests/` (every Rust repo has one) is not a
/// Python project.
fn hasPytestFiles(io: Io, root: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "tests", "test" }) |sub| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, sub }) catch continue;
        var dir = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (isPytestFile(entry.name)) return true;
            if (entry.kind != .directory) continue;
            var subdir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer subdir.close(io);
            var sit = subdir.iterate();
            while (sit.next(io) catch null) |e2| if (isPytestFile(e2.name)) return true;
        }
    }
    return false;
}

/// `pytest <args>`: needs a manifest or real test files at the root. The
/// project's own venv pytest wins over the one on PATH.
fn runPytest(app: *App, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const root = findManifestDir(app.io, startDir(app), &py_manifests, app.workspace) orelse app.workspace;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var has_manifest = false;
    for (py_manifests) |m| if (exists(app.io, root, m, &buf)) {
        has_manifest = true;
    };
    if (!has_manifest and !hasPytestFiles(app.io, root))
        return app.diag.fail(arena, "pytest: no pyproject.toml / setup.py / requirements.txt / test files at {s}", .{app.workspace});
    const venvs = [_][]const u8{ ".venv/bin/pytest", ".venv/Scripts/pytest.exe", "venv/bin/pytest", "venv/Scripts/pytest.exe" };
    var bin: []const u8 = "pytest";
    for (venvs) |v| if (exists(app.io, root, v, &buf)) {
        bin = try std.fmt.allocPrint(arena, "'{s}/{s}'", .{ root, v });
        break;
    };
    if (std.mem.eql(u8, bin, "pytest") and !onPath(app, "pytest")) return offerInstall(app, "pytest");
    const cmdline = if (args.len == 0) bin else try std.fmt.allocPrint(arena, "{s} {s}", .{ bin, args });
    _ = try spawn(app, cmdline, cmdline, root, .runner);
}

fn pytestRun(app: *App) CommandError!void {
    return runPytest(app, "");
}
fn pytestFailed(app: *App) CommandError!void {
    return runPytest(app, "--lf");
}

// ─── go ─────────────────────────────────────────────────────────────────

/// `go <subcmd>`. `go run .` looks for `cmd/<app>/` at the module root:
/// one → run it; several → a picker; none → the literal `go run .`.
fn runGo(app: *App, subcmd: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (std.mem.eql(u8, subcmd, "run .")) {
        if (findManifestDir(app.io, startDir(app), &.{"go.mod"}, app.workspace)) |root| {
            const apps = try goCmdDirs(app, root);
            switch (apps.len) {
                0 => {},
                1 => return runManifestCommand(app, "go.mod", "go", "run", try std.fmt.allocPrint(arena, "run ./cmd/{s}", .{apps[0]})),
                else => return openGoRunPicker(app, apps),
            }
        }
    }
    return runManifestCommand(app, "go.mod", "go", firstWord(subcmd), subcmd);
}

/// The names under `<root>/cmd/`, sorted, on the frame arena.
fn goCmdDirs(app: *App, root: []const u8) Allocator.Error![]const []const u8 {
    const arena = app.frame.allocator();
    const p = try std.fs.path.join(arena, &.{ root, "cmd" });
    var dir = Io.Dir.cwd().openDir(app.io, p, .{ .iterate = true }) catch return &.{};
    defer dir.close(app.io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn openGoRunPicker(app: *App, apps: []const []const u8) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (apps) |a| try labels.append(gpa, try std.fmt.allocPrint(gpa, "cmd/{s}", .{a}));
    try cmd_picker.openPicker(app, "go run: pick a cmd/<app>", .go_run_cmd, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// The picker's choice: `cmd/<app>` → `go run ./cmd/<app>`.
pub fn goRunAccept(app: *App, label: []const u8) CommandError!void {
    const subcmd = try std.fmt.allocPrint(app.frame.allocator(), "run ./{s}", .{label});
    return runManifestCommand(app, "go.mod", "go", "run", subcmd);
}

fn goTest(app: *App) CommandError!void {
    return runGo(app, "test ./...");
}
fn goBuild(app: *App) CommandError!void {
    return runGo(app, "build ./...");
}
fn goVet(app: *App) CommandError!void {
    return runGo(app, "vet ./...");
}
fn goRun(app: *App) CommandError!void {
    return runGo(app, "run .");
}

fn goRunPath(app: *App) CommandError!void {
    if (findManifestDir(app.io, startDir(app), &.{"go.mod"}, app.workspace) == null)
        return app.diag.fail(app.frame.allocator(), "go.run_path: no go.mod found", .{});
    openPrompt(app, "go run: package path", .go_run_path, "./");
}

pub fn goRunPathAccept(app: *App, text: []const u8) CommandError!void {
    const path = std.mem.trim(u8, text, " \t");
    if (path.len == 0) return app.diag.fail(app.frame.allocator(), "go.run_path: empty path", .{});
    const subcmd = try std.fmt.allocPrint(app.frame.allocator(), "run {s}", .{path});
    return runManifestCommand(app, "go.mod", "go", "run", subcmd);
}

// ─── test.* — whichever project this is ─────────────────────────────────

pub const Project = enum { cargo, npm, go, pytest };

/// The project kind at or above the active file: the nearest manifest
/// decides, a Python layout without one counts when it has test files.
pub fn detectProject(app: *App) ?Project {
    const start = startDir(app);
    if (findManifestDir(app.io, start, &.{"Cargo.toml"}, app.workspace) != null) return .cargo;
    if (findManifestDir(app.io, start, &.{"package.json"}, app.workspace) != null) return .npm;
    if (findManifestDir(app.io, start, &.{"go.mod"}, app.workspace) != null) return .go;
    if (findManifestDir(app.io, start, &py_manifests, app.workspace) != null) return .pytest;
    if (hasPytestFiles(app.io, app.workspace)) return .pytest;
    return null;
}

fn requireProject(app: *App) CommandError!Project {
    return detectProject(app) orelse app.diag.fail(app.frame.allocator(), "test: no Cargo.toml / package.json / go.mod / Python project at {s}", .{app.workspace});
}

fn testRunAll(app: *App) CommandError!void {
    switch (try requireProject(app)) {
        .cargo => return runCargo(app, "test"),
        .npm => return runNpm(app, "test", "test"),
        .go => return runGo(app, "test ./..."),
        .pytest => return runPytest(app, ""),
    }
}

/// The active file, workspace-relative.
fn activeRel(app: *App) CommandError![]const u8 {
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "open a test file first", .{});
    const path = e.buf.path orelse return app.diag.fail(app.frame.allocator(), "open a saved test file first", .{});
    return app.relPath(path);
}

fn testRunFile(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const rel = try activeRel(app);
    switch (try requireProject(app)) {
        .cargo => return runCargo(app, try std.fmt.allocPrint(arena, "test {s}", .{std.fs.path.stem(rel)})),
        .npm => return runNpm(app, "test", try std.fmt.allocPrint(arena, "test -- {s}", .{rel})),
        .go => return runGo(app, try std.fmt.allocPrint(arena, "test ./{s}", .{std.fs.path.dirname(rel) orelse "."})),
        .pytest => return runPytest(app, rel),
    }
}

/// The nearest test name above the cursor: a Rust `fn` under a
/// `#[test]`-style attribute, `def test_x`, `func TestX`, `it("x"` /
/// `test("x"`.
pub fn testNameAt(text: []const u8, cursor: usize) ?[]const u8 {
    const at = @min(cursor, text.len);
    // The cursor's own line, whole.
    var end = if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |i| i else text.len;
    while (true) {
        const line_end = end;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..line_end], '\n')) |i| i + 1 else 0;
        const line = std.mem.trimStart(u8, text[line_start..line_end], " \t");
        const above: []const u8 = if (line_start == 0) "" else blk: {
            const prev_end = line_start - 1;
            const prev_start = if (std.mem.lastIndexOfScalar(u8, text[0..prev_end], '\n')) |i| i + 1 else 0;
            break :blk std.mem.trimStart(u8, text[prev_start..prev_end], " \t");
        };
        if (testNameIn(line, above)) |n| return n;
        if (line_start == 0) return null;
        end = line_start - 1;
    }
}

fn identAt(s: []const u8) ?[]const u8 {
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_')) n += 1;
    return if (n > 0) s[0..n] else null;
}

fn testNameIn(line: []const u8, above: []const u8) ?[]const u8 {
    // Rust: the attribute names the test, the fn carries the name.
    if (std.mem.startsWith(u8, above, "#[") and std.mem.indexOf(u8, above, "test") != null) {
        for ([_][]const u8{ "pub async fn ", "pub fn ", "async fn ", "fn " }) |p| if (std.mem.startsWith(u8, line, p)) return identAt(line[p.len..]);
    }
    const prefixes = [_][]const u8{ "fn test_", "async fn test_", "def test_", "async def test_", "func Test" };
    for (prefixes) |p| if (std.mem.startsWith(u8, line, p)) {
        const from = p.len - (if (std.mem.endsWith(u8, p, "test_")) @as(usize, 5) else 4);
        return identAt(line[from..]);
    };
    for ([_][]const u8{ "it(", "test(", "it.only(", "test.only(" }) |p| if (std.mem.startsWith(u8, line, p)) {
        const rest = line[p.len..];
        if (rest.len < 2) return null;
        const q = rest[0];
        if (q != '"' and q != '\'' and q != '`') return null;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, q) orelse return null;
        return rest[1..close];
    };
    return null;
}

fn testRunAtCursor(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const rel = try activeRel(app);
    const e = app.activeEditor().?;
    const name = testNameAt(e.buf.editor.bytes(), e.buf.editor.cursor) orelse
        return app.diag.fail(arena, "no test above the cursor", .{});
    switch (try requireProject(app)) {
        .cargo => return runCargo(app, try std.fmt.allocPrint(arena, "test {s}", .{name})),
        .npm => return runNpm(app, "test", try std.fmt.allocPrint(arena, "test -- -t '{s}'", .{name})),
        .go => return runGo(app, try std.fmt.allocPrint(arena, "test ./{s} -run '^{s}$'", .{ std.fs.path.dirname(rel) orelse ".", name })),
        .pytest => return runPytest(app, try std.fmt.allocPrint(arena, "{s} -k '{s}'", .{ rel, name })),
    }
}

/// pytest re-runs its last failures; the others re-run the last command.
fn testRerunFailed(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (detectProject(app) == .pytest) return runPytest(app, "--lf");
    const cmdline = app.runners.last_cmdline orelse return app.diag.fail(arena, "nothing has run yet", .{});
    const cwd = app.runners.last_cwd orelse app.workspace;
    const c = try arena.dupe(u8, cmdline);
    const d = try arena.dupe(u8, cwd);
    _ = try spawn(app, c, c, d, .runner);
}

// ─── tools ──────────────────────────────────────────────────────────────

pub const ToolKind = enum {
    lsp,
    formatter,
    linter,
    runner,

    pub fn label(k: ToolKind) []const u8 {
        return switch (k) {
            .lsp => "lsp",
            .formatter => "fmt",
            .linter => "lint",
            .runner => "run",
        };
    }
};

pub const Tool = struct {
    name: []const u8,
    kind: ToolKind,
    /// The binary looked for on PATH.
    bin: []const u8,
    description: []const u8,
    /// Shell line that installs it, per platform.
    brew: []const u8,
    apt: []const u8,

    pub fn install(self: Tool) []const u8 {
        return switch (builtin.os.tag) {
            .macos => self.brew,
            .linux => self.apt,
            else => self.brew,
        };
    }
};

pub const known_tools = [_]Tool{
    .{ .name = "rust-analyzer", .kind = .lsp, .bin = "rust-analyzer", .description = "Rust language server", .brew = "rustup component add rust-analyzer", .apt = "rustup component add rust-analyzer" },
    .{ .name = "typescript-language-server", .kind = .lsp, .bin = "typescript-language-server", .description = "TypeScript / JavaScript language server", .brew = "npm i -g typescript typescript-language-server", .apt = "npm i -g typescript typescript-language-server" },
    .{ .name = "pyright", .kind = .lsp, .bin = "pyright-langserver", .description = "Python language server", .brew = "npm i -g pyright", .apt = "npm i -g pyright" },
    .{ .name = "gopls", .kind = .lsp, .bin = "gopls", .description = "Go language server", .brew = "go install golang.org/x/tools/gopls@latest", .apt = "go install golang.org/x/tools/gopls@latest" },
    .{ .name = "clangd", .kind = .lsp, .bin = "clangd", .description = "C / C++ language server", .brew = "brew install llvm", .apt = "sudo apt install -y clangd" },
    .{ .name = "zls", .kind = .lsp, .bin = "zls", .description = "Zig language server", .brew = "brew install zls", .apt = "sudo apt install -y zls" },
    .{ .name = "lua-language-server", .kind = .lsp, .bin = "lua-language-server", .description = "Lua language server", .brew = "brew install lua-language-server", .apt = "sudo apt install -y lua-language-server" },
    .{ .name = "prettier", .kind = .formatter, .bin = "prettier", .description = "JS / TS / CSS / Markdown formatter", .brew = "npm i -g prettier", .apt = "npm i -g prettier" },
    .{ .name = "black", .kind = .formatter, .bin = "black", .description = "Python formatter", .brew = "pip install black", .apt = "pip install black" },
    .{ .name = "rustfmt", .kind = .formatter, .bin = "rustfmt", .description = "Rust formatter", .brew = "rustup component add rustfmt", .apt = "rustup component add rustfmt" },
    .{ .name = "eslint", .kind = .linter, .bin = "eslint", .description = "JS / TS linter", .brew = "npm i -g eslint", .apt = "npm i -g eslint" },
    .{ .name = "ruff", .kind = .linter, .bin = "ruff", .description = "Python linter + formatter", .brew = "brew install ruff", .apt = "pip install ruff" },
    .{ .name = "golangci-lint", .kind = .linter, .bin = "golangci-lint", .description = "Go linter aggregator", .brew = "brew install golangci-lint", .apt = "go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest" },
    .{ .name = "shellcheck", .kind = .linter, .bin = "shellcheck", .description = "Shell script linter", .brew = "brew install shellcheck", .apt = "sudo apt install -y shellcheck" },
    .{ .name = "cargo", .kind = .runner, .bin = "cargo", .description = "Rust build tool", .brew = "brew install rustup && rustup-init -y", .apt = "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" },
    .{ .name = "npm", .kind = .runner, .bin = "npm", .description = "Node package manager", .brew = "brew install node", .apt = "sudo apt install -y nodejs npm" },
    .{ .name = "go", .kind = .runner, .bin = "go", .description = "Go toolchain", .brew = "brew install go", .apt = "sudo apt install -y golang-go" },
    .{ .name = "pytest", .kind = .runner, .bin = "pytest", .description = "Python test runner", .brew = "pip install pytest", .apt = "pip install pytest" },
};

pub fn toolByBin(bin: []const u8) ?u16 {
    for (known_tools, 0..) |tool, i| if (std.mem.eql(u8, tool.bin, bin)) return @intCast(i);
    return null;
}

fn toolByName(name: []const u8) ?u16 {
    for (known_tools, 0..) |tool, i| if (std.mem.eql(u8, tool.name, name)) return @intCast(i);
    return null;
}

/// A runner's binary is missing: say so, and offer to run its install
/// command in a pane. An unknown binary only gets the toast.
fn offerInstall(app: *App, bin: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const idx = toolByBin(bin) orelse return app.diag.fail(arena, "{s} is not on PATH", .{bin});
    try openInstallConfirm(app, idx);
}

pub const install_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'i', .label = "Install" }, .{ .key = 'c', .label = "Copy command" }, .{ .key = 'n', .label = "Not now" } };

fn openInstallConfirm(app: *App, idx: u16) CommandError!void {
    const tool = known_tools[idx];
    const msg = try std.fmt.allocPrint(app.gpa, "  {s} is not installed.\n  {s}", .{ tool.bin, tool.install() });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Missing tool", .message = msg, .choices = &install_choices },
        .purpose = .{ .install_tool = idx },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The install box's answer.
pub fn installAccept(app: *App, idx: u16, choice: usize) CommandError!void {
    const tool = known_tools[idx];
    switch (choice) {
        0 => {
            const label = try std.fmt.allocPrint(app.frame.allocator(), "install {s}", .{tool.name});
            _ = try spawn(app, label, tool.install(), app.workspace, .command);
        },
        1 => {
            try app.clipboard.setYank(tool.install(), false);
            app.toast("copied: {s}", .{tool.install()});
        },
        else => {},
    }
}

/// `tools.installer`: every known tool with its install state; missing
/// ones first. Enter opens the install box (or says it is installed).
fn toolsInstaller(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for ([_]bool{ false, true }) |want_installed| {
        for (known_tools) |tool| {
            const installed = onPath(app, tool.bin);
            if (installed != want_installed) continue;
            const mark: []const u8 = if (installed) (if (app.cfg.ui.ascii_icons) "+" else "✓") else (if (app.cfg.ui.ascii_icons) "x" else "✗");
            try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} [{s}] {s} — {s}", .{ mark, tool.kind.label(), tool.name, tool.description }));
        }
    }
    try cmd_picker.openPicker(app, "External tools (Enter = install)", .tools, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// The tools picker's choice. The label carries the name after the kind chip.
pub fn toolAccept(app: *App, label: []const u8) CommandError!void {
    const after = std.mem.indexOf(u8, label, "] ") orelse return;
    const rest = label[after + 2 ..];
    const name = rest[0 .. std.mem.indexOf(u8, rest, " —") orelse rest.len];
    const idx = toolByName(name) orelse return;
    if (onPath(app, known_tools[idx].bin)) {
        app.toast("{s} is installed", .{name});
        return;
    }
    try openInstallConfirm(app, idx);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    app: App,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        errdefer t.allocator.free(root);
        // A workspace that is itself inside a Cargo project: the walk
        // must never see the parent's manifest.
        const app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn file(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(t.io, d);
        try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    fn open(f: *Fixture, rel: []const u8) !void {
        const abs = try std.fs.path.join(t.allocator, &.{ f.root, rel });
        defer t.allocator.free(abs);
        _ = try f.app.openPath(abs);
    }

    fn run(f: *Fixture, id: command.CommandId) void {
        command.run(&f.app, .{ .static = id }) catch {};
    }

    fn toast(f: *Fixture) []const u8 {
        return f.app.lastToast() orelse "";
    }

    fn activeIsPty(f: *Fixture) bool {
        const id = f.app.active orelse return false;
        return f.app.panes.pty(id) != null;
    }
};

test "detection walks up from the file to the workspace root and no further" {
    var f = try Fixture.init();
    defer f.deinit();
    // The tmp root's parents have no go.mod, but plant one ABOVE by
    // pretending the workspace is a subdirectory.
    try f.file("go.mod", "module x\n");
    try f.file("sub/pkg/a.go", "package pkg\n");
    const sub = try std.fs.path.join(t.allocator, &.{ f.root, "sub" });
    defer t.allocator.free(sub);
    const pkg = try std.fs.path.join(t.allocator, &.{ f.root, "sub", "pkg" });
    defer t.allocator.free(pkg);
    // Workspace = root: found at the root.
    try t.expectEqualStrings(f.root, findManifestDir(t.io, pkg, &.{"go.mod"}, f.root).?);
    // Workspace = sub: the root's go.mod is above the workspace — not found.
    try t.expect(findManifestDir(t.io, pkg, &.{"go.mod"}, sub) == null);
    // A start outside the workspace is treated as the workspace.
    try t.expect(findManifestDir(t.io, "/", &.{"go.mod"}, sub) == null);
}

test "go/npm/pytest/cargo toast their id, not the subcommand, when the manifest is missing" {
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"go.test");
    try t.expect(std.mem.startsWith(u8, f.toast(), "go.test: no go.mod found in "));
    f.run(.@"npm.build");
    try t.expect(std.mem.startsWith(u8, f.toast(), "npm.build: no package.json found in "));
    f.run(.@"cargo.clippy");
    try t.expect(std.mem.startsWith(u8, f.toast(), "cargo.clippy: no Cargo.toml found in "));
    f.run(.@"pytest.run");
    try t.expect(std.mem.startsWith(u8, f.toast(), "pytest: no pyproject.toml / setup.py / requirements.txt / test files at "));
    try t.expect(!f.activeIsPty());
}

test "npm run validates the script against the nearest package.json, walking up from the open file" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("packages/app/package.json", "{\"name\":\"app\",\"scripts\":{\"test\":\"jest\",\"build\":\"tsc\"}}");
    try f.file("packages/app/src/index.ts", "export const x = 1;");
    try f.open("packages/app/src/index.ts");
    f.run(.@"npm.run");
    try t.expectEqualStrings("npm.run: no `dev` script in package.json — available: test / build", f.toast());
    try t.expect(!f.activeIsPty());
    f.run(.@"npm.lint");
    try t.expectEqualStrings("npm.lint: no `lint` script in package.json — available: test / build", f.toast());
    if (!pty_pane.supported or !onPath(&f.app, "npm")) return;
    f.run(.@"npm.build");
    try t.expect(f.activeIsPty());
    try t.expectEqualStrings("npm run build", f.app.panes.get(f.app.active.?).?.title());
    // The pane's cwd is the sub-package, and the context survives the
    // pty taking focus: a second runner still finds packages/app.
    const p = f.app.panes.pty(f.app.active.?).?;
    try t.expect(std.mem.endsWith(u8, p.cwd.?, "packages/app"));
    try t.expectEqualStrings("npm run build", f.app.runners.last_cmdline.?);
    f.run(.@"npm.run");
    try t.expectEqualStrings("npm.run: no `dev` script in package.json — available: test / build", f.toast());
}

test "pytest detection: a bare tests/ dir is not a project; test_*.py one level deep is; requirements.txt is" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("tests/integration.rs", "// rust");
    f.run(.@"pytest.run");
    try t.expect(std.mem.startsWith(u8, f.toast(), "pytest: no pyproject.toml"));
    try f.file("tests/unit/test_basic.py", "def test_basic(): pass");
    try t.expect(hasPytestFiles(t.io, f.root));
    try t.expectEqual(Project.pytest, detectProject(&f.app).?);
    var g = try Fixture.init();
    defer g.deinit();
    try g.file("requirements.txt", "pytest\n");
    try t.expectEqual(Project.pytest, detectProject(&g.app).?);
    try t.expect(!hasPytestFiles(t.io, g.root));
}

test "go run: one cmd/ dir is picked, two open the picker, none means the literal target" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("go.mod", "module x\n");
    try f.file("cmd/server/main.go", "package main");
    const one = try goCmdDirs(&f.app, f.root);
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expectEqualStrings("server", one[0]);
    try f.file("cmd/worker/main.go", "package main");
    f.run(.@"go.run");
    try t.expect(f.app.overlay == .picker);
    try t.expectEqualStrings("go run: pick a cmd/<app>", f.app.overlay.picker.state.title);
    try t.expectEqualStrings("cmd/server", f.app.overlay.picker.labels[0]);
    try t.expectEqualStrings("cmd/worker", f.app.overlay.picker.labels[1]);
    try f.app.handle(.{ .key = Key.named(.esc) });
    try t.expect(f.app.overlay == .none);
}

test "test.* picks the project; the test name above the cursor is found for four languages" {
    try t.expectEqualStrings("adds", testNameAt("fn other() {}\n#[test]\nfn adds() {\n  x\n}", 30).?);
    try t.expectEqualStrings("test_it", testNameAt("def test_it():\n    assert True\n", 20).?);
    try t.expectEqualStrings("TestSum", testNameAt("func TestSum(t *testing.T) {\n}", 10).?);
    try t.expectEqualStrings("adds up", testNameAt("describe('x', () => {\n  it('adds up', () => {\n  });\n});", 40).?);
    try t.expect(testNameAt("nothing here", 5) == null);
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"test.run_all");
    try t.expect(std.mem.startsWith(u8, f.toast(), "test: no Cargo.toml / package.json / go.mod / Python project at "));
    try f.file("Cargo.toml", "[package]\nname = \"x\"\n");
    try t.expectEqual(Project.cargo, detectProject(&f.app).?);
    f.run(.@"test.rerun_failed");
    try t.expectEqualStrings("nothing has run yet", f.toast());
}

test "tools: the picker lists every known tool with a kind chip; a missing tool opens the install box" {
    var f = try Fixture.init();
    defer f.deinit();
    f.run(.@"tools.installer");
    try t.expect(f.app.overlay == .picker);
    try t.expectEqualStrings("External tools (Enter = install)", f.app.overlay.picker.state.title);
    try t.expectEqual(known_tools.len, f.app.overlay.picker.labels.len);
    var has_lsp = false;
    for (f.app.overlay.picker.labels) |l| if (std.mem.indexOf(u8, l, "[lsp]") != null) {
        has_lsp = true;
    };
    try t.expect(has_lsp);
    try f.app.handle(.{ .key = Key.named(.esc) });
    // A binary that cannot be on PATH.
    try t.expect(!onPath(&f.app, "definitely-not-a-binary-xyz"));
    try t.expect(toolByBin("go") != null);
    try installAccept(&f.app, toolByBin("go").?, 1);
    try t.expect(std.mem.startsWith(u8, f.toast(), "copied: "));
    try t.expectEqualStrings(known_tools[toolByBin("go").?].install(), f.app.clipboard.text());
}
