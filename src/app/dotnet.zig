//! What the .NET runners, the results pane and the debugger share: where
//! the nearest `*.csproj` and `*.sln` are, what a csproj says about its
//! output, and which test the cursor is in. No `App` in here — every
//! function takes what it reads, so the tests feed it text.
//!
//! Detection walks up from the active file's directory to the workspace
//! root (`runners.findManifestDir`'s rule), keeping the first `.csproj`
//! and the first `.sln` it meets. The solution wins for `build` /
//! `test` / `restore` (it covers every project), the project for `run`
//! / `watch` (`dotnet run` wants exactly one).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const structure = @import("highlight").structure;
const outline = @import("outline.zig");

/// The nearest project and solution at or above a file. Absolute paths
/// on the arena the walk was given.
pub const Project = struct {
    csproj: ?[]const u8,
    sln: ?[]const u8,

    /// `dotnet build` / `test` / `restore`: the solution's directory
    /// when there is one, else the project's.
    pub fn buildRoot(p: Project) []const u8 {
        return std.fs.path.dirname(p.sln orelse p.csproj.?) orelse ".";
    }

    /// `dotnet run` / `watch`: the project's directory, else the
    /// solution's (dotnet then picks the one project it finds there).
    pub fn runRoot(p: Project) []const u8 {
        return std.fs.path.dirname(p.csproj orelse p.sln.?) orelse ".";
    }
};

/// The nearest `*.csproj` and `*.sln` at or above `start`, never above
/// `workspace`. Null when neither exists. A `start` outside the
/// workspace is treated as the workspace itself.
pub fn find(io: Io, arena: Allocator, start: []const u8, workspace: []const u8) Allocator.Error!?Project {
    var cur: []const u8 = if (std.mem.startsWith(u8, start, workspace)) start else workspace;
    var p: Project = .{ .csproj = null, .sln = null };
    while (true) {
        if (p.csproj == null) p.csproj = try firstWithExt(io, arena, cur, ".csproj");
        if (p.sln == null) p.sln = try firstWithExt(io, arena, cur, ".sln");
        if (p.csproj != null and p.sln != null) break;
        if (std.mem.eql(u8, cur, workspace)) break;
        cur = std.fs.path.dirname(cur) orelse break;
        if (cur.len < workspace.len) break;
    }
    if (p.csproj == null and p.sln == null) return null;
    return p;
}

/// `<dir>/<name><ext>` for the alphabetically first `name` in `dir`, so
/// two projects in one directory pick the same one every time.
fn firstWithExt(io: Io, arena: Allocator, dir: []const u8, ext: []const u8) Allocator.Error!?[]const u8 {
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var best: ?[]const u8 = null;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ext)) continue;
        if (best == null or std.mem.lessThan(u8, entry.name, best.?)) best = try arena.dupe(u8, entry.name);
    }
    const name = best orelse return null;
    return try std.fs.path.join(arena, &.{ dir, name });
}

// ─── the csproj ─────────────────────────────────────────────────────────

/// The target framework a csproj without one is assumed to build for.
pub const default_tfm = "net8.0";

pub const Csproj = struct {
    /// `<AssemblyName>`, else the file's stem.
    assembly_name: []const u8,
    /// `<TargetFramework>`, else the first of `<TargetFrameworks>`.
    target_framework: ?[]const u8,
};

/// What the debugger needs from `path`'s text. Slices of `text` / `path`.
pub fn parseCsproj(path: []const u8, text: []const u8) Csproj {
    const tfm: ?[]const u8 = tagText(text, "TargetFramework") orelse blk: {
        const many = tagText(text, "TargetFrameworks") orelse break :blk null;
        const first = many[0 .. std.mem.indexOfScalar(u8, many, ';') orelse many.len];
        break :blk if (first.len > 0) first else null;
    };
    return .{
        .assembly_name = tagText(text, "AssemblyName") orelse std.fs.path.stem(path),
        .target_framework = tfm,
    };
}

/// The trimmed text of the first `<tag …>…</tag>`; null when absent or
/// empty. Attributes on the opener are skipped; a self-closing tag is
/// not a match.
fn tagText(text: []const u8, tag: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "<")) |lt| {
        from = lt + 1;
        const after = text[lt + 1 ..];
        if (!std.mem.startsWith(u8, after, tag)) continue;
        const rest = after[tag.len..];
        if (rest.len == 0 or !(rest[0] == '>' or std.ascii.isWhitespace(rest[0]))) continue;
        const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        if (gt > 0 and rest[gt - 1] == '/') continue;
        const body = rest[gt + 1 ..];
        var close_buf: [64]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
        const end = std.mem.indexOf(u8, body, close) orelse return null;
        const inner = std.mem.trim(u8, body[0..end], " \t\r\n");
        return if (inner.len > 0) inner else null;
    }
    return null;
}

/// The `launch` body for a project's debug build: the assembly under
/// `bin/Debug/<tfm>/`, run from the project's directory. JSON on `arena`.
pub fn launchBody(arena: Allocator, csproj_path: []const u8, text: []const u8) Allocator.Error![]u8 {
    const c = parseCsproj(csproj_path, text);
    const dir = std.fs.path.dirname(csproj_path) orelse ".";
    const program = try std.fs.path.join(arena, &.{ dir, "bin", "Debug", c.target_framework orelse default_tfm, try std.fmt.allocPrint(arena, "{s}.dll", .{c.assembly_name}) });
    return std.json.Stringify.valueAlloc(arena, .{ .program = program, .cwd = dir, .stopAtEntry = false }, .{});
}

// ─── the test at the cursor ─────────────────────────────────────────────

pub const TestId = struct {
    /// Empty when the method is not inside a class.
    class: []const u8,
    method: []const u8,
};

/// The innermost method around `cursor` and the class it sits in, from
/// the grammar's outline (document order; a nested definition follows
/// its container).
pub fn testAt(syms: []const structure.Symbol, cursor: usize) ?TestId {
    var best: ?usize = null;
    for (syms, 0..) |s, i| {
        if (!s.kind.isFunction()) continue;
        if (s.start > cursor or cursor >= s.end) continue;
        if (best == null or s.start >= syms[best.?].start) best = i;
    }
    const m = best orelse return null;
    var i = m;
    var class: []const u8 = "";
    while (i > 0) {
        i -= 1;
        const s = syms[i];
        if (!(s.kind == .class or s.kind == .@"struct")) continue;
        if (s.start <= syms[m].start and syms[m].end <= s.end) {
            class = s.name;
            break;
        }
    }
    return .{ .class = class, .method = syms[m].name };
}

/// Without a tree: the nearest method signature above the cursor's
/// line and the nearest `class` / `struct` above that, read off the
/// lines (`outline.fallback`).
pub fn testAtText(arena: Allocator, text: []const u8, cursor: usize) Allocator.Error!?TestId {
    const at = @min(cursor, text.len);
    const line: u32 = @intCast(std.mem.count(u8, text[0..at], "\n"));
    const found = try outline.fallback(arena, text, "cs");
    var method: ?usize = null;
    for (found, 0..) |f, i| if (f.kind.isFunction() and f.line <= line) {
        method = i;
    };
    const m = method orelse return null;
    var class: []const u8 = "";
    var i = m;
    while (i > 0) {
        i -= 1;
        if (found[i].kind == .class or found[i].kind == .@"struct") {
            class = found[i].name;
            break;
        }
    }
    return .{ .class = class, .method = found[m].name };
}

/// `Class.Method`, or the bare method.
pub fn qualified(arena: Allocator, id: TestId) Allocator.Error![]const u8 {
    if (id.class.len == 0) return id.method;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ id.class, id.method });
}

/// `dotnet test`'s selector for one test: a substring match on the
/// fully-qualified name.
pub fn filterArg(arena: Allocator, id: TestId) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "FullyQualifiedName~{s}", .{try qualified(arena, id)});
}

/// The classes of a file, as `FullyQualifiedName~A|FullyQualifiedName~B`
/// — `dotnet test`'s "this file". Null when the file declares none.
pub fn fileFilterArg(arena: Allocator, syms: []const structure.Symbol) Allocator.Error!?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (syms) |s| {
        if (!(s.kind == .class or s.kind == .@"struct")) continue;
        if (out.items.len > 0) try out.append(arena, '|');
        try out.appendSlice(arena, "FullyQualifiedName~");
        try out.appendSlice(arena, s.name);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(arena);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "find: the nearest csproj and the sln above it; the sln builds, the csproj runs; nothing above the workspace" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(t.io, "src/App/Sub");
    try tmp.dir.createDirPath(t.io, "src/Tests");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "All.sln", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/App/App.csproj", .data = "<Project/>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/App/Zed.csproj", .data = "<Project/>" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/Tests/Tests.csproj", .data = "<Project/>" });
    const sub = try std.fs.path.join(a, &.{ root, "src", "App", "Sub" });
    const p = (try find(t.io, a, sub, root)).?;
    try t.expect(sdk_testing.pathEndsWith(p.csproj.?, "src/App/App.csproj"));
    try t.expect(std.mem.endsWith(u8, p.sln.?, "All.sln"));
    try t.expectEqualStrings(root, p.buildRoot());
    try t.expect(std.mem.endsWith(u8, p.runRoot(), "src/App"));
    // A sibling project: its own csproj, the same sln.
    const tests_dir = try std.fs.path.join(a, &.{ root, "src", "Tests" });
    const q = (try find(t.io, a, tests_dir, root)).?;
    try t.expect(std.mem.endsWith(u8, q.csproj.?, "Tests.csproj"));
    // The workspace is src/App: the sln above it is never seen; both roots are the project.
    const app_dir = try std.fs.path.join(a, &.{ root, "src", "App" });
    const r = (try find(t.io, a, sub, app_dir)).?;
    try t.expect(r.sln == null);
    try t.expectEqualStrings(app_dir, r.buildRoot());
    try t.expectEqualStrings(app_dir, r.runRoot());
    // A start outside the workspace is the workspace; a workspace with neither is null.
    try t.expect((try find(t.io, a, "/", app_dir)).?.csproj != null);
    const bare = try std.fs.path.join(a, &.{ root, "src", "App", "Sub" });
    try t.expect((try find(t.io, a, bare, bare)) == null);
}

test "parseCsproj: AssemblyName / TargetFramework(s) with defaults; launchBody names the debug dll" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plain = "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n    <TargetFramework>net9.0</TargetFramework>\n  </PropertyGroup>\n</Project>\n";
    const c = parseCsproj("/ws/src/App/App.csproj", plain);
    try t.expectEqualStrings("App", c.assembly_name);
    try t.expectEqualStrings("net9.0", c.target_framework.?);
    const named = "<Project>\n<PropertyGroup Label=\"x\">\n<AssemblyName> Acme.Tool </AssemblyName>\n<TargetFrameworks>net8.0;net48</TargetFrameworks>\n</PropertyGroup>\n</Project>";
    const n = parseCsproj("/ws/Tool.csproj", named);
    try t.expectEqualStrings("Acme.Tool", n.assembly_name);
    try t.expectEqualStrings("net8.0", n.target_framework.?);
    // An attribute on the opener, a self-closing tag, an empty tag.
    try t.expectEqualStrings("net7.0", tagText("<TargetFramework Condition=\"'$(X)'==''\">net7.0</TargetFramework>", "TargetFramework").?);
    try t.expect(tagText("<TargetFramework/>", "TargetFramework") == null);
    try t.expect(tagText("<TargetFramework></TargetFramework>", "TargetFramework") == null);
    try t.expect(tagText("<TargetFrameworkX>net7.0</TargetFrameworkX>", "TargetFramework") == null);
    const none = parseCsproj("/ws/Lib.csproj", "<Project/>");
    try t.expectEqualStrings("Lib", none.assembly_name);
    try t.expect(none.target_framework == null);
    const body = try launchBody(a, "/ws/src/App/App.csproj", plain);
    try t.expectEqualStrings("{\"program\":\"/ws/src/App/bin/Debug/net9.0/App.dll\",\"cwd\":\"/ws/src/App\",\"stopAtEntry\":false}", body);
    const defaulted = try launchBody(a, "/ws/Lib.csproj", "<Project/>");
    try t.expect(std.mem.indexOf(u8, defaulted, "/ws/bin/Debug/" ++ default_tfm ++ "/Lib.dll") != null);
}

test "testAt: the innermost method and its class; a local function keeps the outer class; outside every method is null" {
    const S = structure.Symbol;
    // class Calc { void Adds() { void Inner() {} } }  struct P { void Q() {} }  void Free() {}
    const syms = [_]S{
        .{ .name = "Calc", .kind = .class, .line = 0, .col = 0, .depth = 0, .start = 0, .end = 100 },
        .{ .name = "Adds", .kind = .method, .line = 1, .col = 4, .depth = 1, .start = 10, .end = 60 },
        .{ .name = "Inner", .kind = .function, .line = 2, .col = 8, .depth = 2, .start = 30, .end = 50 },
        .{ .name = "Divides", .kind = .method, .line = 5, .col = 4, .depth = 1, .start = 70, .end = 90 },
        .{ .name = "P", .kind = .@"struct", .line = 8, .col = 0, .depth = 0, .start = 110, .end = 150 },
        .{ .name = "Q", .kind = .method, .line = 9, .col = 4, .depth = 1, .start = 120, .end = 140 },
        .{ .name = "Free", .kind = .function, .line = 12, .col = 0, .depth = 0, .start = 160, .end = 180 },
    };
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("Calc.Adds", try qualified(a, testAt(&syms, 15).?));
    try t.expectEqualStrings("Calc.Inner", try qualified(a, testAt(&syms, 35).?));
    try t.expectEqualStrings("Calc.Divides", try qualified(a, testAt(&syms, 75).?));
    try t.expectEqualStrings("P.Q", try qualified(a, testAt(&syms, 130).?));
    try t.expectEqualStrings("Free", try qualified(a, testAt(&syms, 170).?));
    try t.expect(testAt(&syms, 5) == null);
    try t.expect(testAt(&syms, 200) == null);
    try t.expectEqualStrings("FullyQualifiedName~Calc.Adds", try filterArg(a, testAt(&syms, 15).?));
    try t.expectEqualStrings("FullyQualifiedName~Calc|FullyQualifiedName~P", (try fileFilterArg(a, &syms)).?);
    try t.expect((try fileFilterArg(a, syms[1..3])) == null);
}

test "testAtText: the signature above the cursor and its class, without a tree" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\namespace Acme.Tests;
        \\
        \\public class CalcTests
        \\{
        \\    [Fact]
        \\    public void Adds()
        \\    {
        \\        Assert.Equal(2, 1 + 1);
        \\    }
        \\
        \\    [Fact]
        \\    public async Task DividesAsync()
        \\    {
        \\        await Task.Yield();
        \\    }
        \\}
        \\
    ;
    const in_adds = std.mem.indexOf(u8, text, "Assert").?;
    try t.expectEqualStrings("CalcTests.Adds", try qualified(a, (try testAtText(a, text, in_adds)).?));
    const in_div = std.mem.indexOf(u8, text, "await").?;
    try t.expectEqualStrings("CalcTests.DividesAsync", try qualified(a, (try testAtText(a, text, in_div)).?));
    try t.expect((try testAtText(a, text, 0)) == null);
}
