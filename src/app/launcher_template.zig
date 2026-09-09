//! Variable substitution for launcher lines. A manifest command's `run`
//! (or `ex`) line can name mnml's runtime context with `{{token}}`:
//!
//!   {{workspace}}         absolute path of the workspace root
//!   {{workspace_name}}    its basename
//!   {{current_file}}      the active file, workspace-relative (absolute
//!                         when it lives outside the workspace)
//!   {{current_file_abs}}  the active file, absolute
//!   {{current_file_dir}}  the active file's directory, absolute
//!   {{cursor_line}}       1-based cursor line
//!   {{cursor_col}}        1-based cursor column
//!   {{selection}}         the selected text, its first line
//!
//! An editor-side token is empty when no editor pane is active; an
//! unknown token — `{{workspce}}`, `{{prompt:name}}`, an OS templating
//! form — stays as written, so a misspelt line still runs and the
//! literal shows what went wrong. `expand` is a pure function of a
//! `Context` snapshot; `contextOf` takes the snapshot off the app so the
//! engine never sees `*App` itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;

pub const Context = struct {
    workspace: []const u8 = "",
    /// Absolute, when an editor pane is active and its buffer has a file.
    current_file: ?[]const u8 = null,
    /// 1-based, when an editor pane is active.
    cursor_line: ?usize = null,
    cursor_col: ?usize = null,
    /// The selected text, when there is a selection.
    selection: ?[]const u8 = null,
};

pub const Token = enum {
    workspace,
    workspace_name,
    current_file,
    current_file_abs,
    current_file_dir,
    cursor_line,
    cursor_col,
    selection,
};

/// `template` with every known `{{token}}` replaced. Returns `template`
/// itself when there is nothing to replace; otherwise a new string on
/// `arena`.
pub fn expand(arena: Allocator, template: []const u8, ctx: Context) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, template, "{{") == null) return template;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, "{{")) |open| {
        try out.appendSlice(arena, rest[0..open]);
        const after = rest[open + 2 ..];
        const close = std.mem.indexOf(u8, after, "}}") orelse {
            // An unmatched `{{`: literal, and the rest with it.
            try out.appendSlice(arena, "{{");
            rest = after;
            break;
        };
        const token = after[0..close];
        if (try substitute(arena, token, ctx)) |value| {
            try out.appendSlice(arena, value);
        } else {
            try out.appendSlice(arena, "{{");
            try out.appendSlice(arena, token);
            try out.appendSlice(arena, "}}");
        }
        rest = after[close + 2 ..];
    }
    try out.appendSlice(arena, rest);
    return out.toOwnedSlice(arena);
}

/// The value of one token; null when the token is not one of ours
/// (the caller keeps the literal). A known token whose value is
/// missing is the empty string, not the literal.
fn substitute(arena: Allocator, token: []const u8, ctx: Context) Allocator.Error!?[]const u8 {
    const tok = std.meta.stringToEnum(Token, token) orelse return null;
    return switch (tok) {
        .workspace => ctx.workspace,
        .workspace_name => std.fs.path.basename(ctx.workspace),
        .current_file => if (ctx.current_file) |p| relativeOrAbs(p, ctx.workspace) else "",
        .current_file_abs => ctx.current_file orelse "",
        .current_file_dir => if (ctx.current_file) |p| (std.fs.path.dirname(p) orelse "") else "",
        .cursor_line => if (ctx.cursor_line) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else "",
        .cursor_col => if (ctx.cursor_col) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else "",
        .selection => ctx.selection orelse "",
    };
}

/// `p` under `workspace` as the part after it; otherwise `p` as given.
/// A prefix match on the path components, no canonicalisation.
fn relativeOrAbs(p: []const u8, workspace: []const u8) []const u8 {
    const ws = std.mem.trimEnd(u8, workspace, "/\\");
    if (ws.len == 0 or !std.mem.startsWith(u8, p, ws)) return p;
    if (p.len == ws.len) return "";
    const c = p[ws.len];
    if (c != '/' and c != '\\') return p;
    return p[ws.len + 1 ..];
}

/// The snapshot: the workspace, and the active editor pane's file,
/// cursor and selection when there is one. Strings borrow the app or
/// `arena`.
pub fn contextOf(app: *App, arena: Allocator) Allocator.Error!Context {
    var ctx: Context = .{ .workspace = app.workspace };
    const e = app.activeEditor() orelse return ctx;
    const ed = e.buf.editor;
    const pos = ed.rowCol();
    ctx.cursor_line = pos.row + 1;
    ctx.cursor_col = pos.col + 1;
    if (e.buf.doc.path) |p| {
        ctx.current_file = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(arena, &.{ app.workspace, p });
    }
    if (ed.hasSelection()) {
        const sel = ed.selectedText();
        const nl = std.mem.indexOfAny(u8, sel, "\r\n") orelse sel.len;
        ctx.selection = sel[0..nl];
    }
    return ctx;
}

/// `expand` on the app's own context.
pub fn expandFor(app: *App, arena: Allocator, template: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, template, "{{") == null) return template;
    return expand(arena, template, try contextOf(app, arena));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const full: Context = .{
    .workspace = "/proj/foo",
    .current_file = "/proj/foo/src/main.zig",
    .cursor_line = 42,
    .cursor_col = 7,
    .selection = "hello",
};

fn expect(expected: []const u8, template: []const u8, ctx: Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    try t.expectEqualStrings(expected, try expand(arena_state.allocator(), template, ctx));
}

test "{{workspace}} and {{workspace_name}}" {
    try expect("cd /proj/foo", "cd {{workspace}}", full);
    try expect("foo", "{{workspace_name}}", full);
    try expect("", "{{workspace_name}}", .{ .workspace = "/" });
}

test "{{current_file}} is workspace-relative inside the workspace and absolute outside; empty without an editor" {
    try expect("src/main.zig", "{{current_file}}", full);
    try expect("/elsewhere/x.zig", "{{current_file}}", .{ .workspace = "/proj/foo", .current_file = "/elsewhere/x.zig" });
    // `/proj/foobar` is not under `/proj/foo`.
    try expect("/proj/foobar/x.zig", "{{current_file}}", .{ .workspace = "/proj/foo", .current_file = "/proj/foobar/x.zig" });
    try expect("src/main.zig", "{{current_file}}", .{ .workspace = "/proj/foo/", .current_file = "/proj/foo/src/main.zig" });
    try expect("code ", "code {{current_file}}", .{ .workspace = "/proj/foo" });
}

test "{{current_file_abs}} and {{current_file_dir}}" {
    try expect("/proj/foo/src/main.zig", "{{current_file_abs}}", full);
    try expect("/proj/foo/src", "{{current_file_dir}}", full);
    try expect("::", ":{{current_file_abs}}:{{current_file_dir}}", .{ .workspace = "/w" });
}

test "{{cursor_line}} and {{cursor_col}} are 1-based numbers, empty without an editor" {
    try expect("--goto /proj/foo/src/main.zig:42:7", "--goto {{current_file_abs}}:{{cursor_line}}:{{cursor_col}}", full);
    try expect("::", ":{{cursor_line}}:{{cursor_col}}", .{ .workspace = "/w" });
}

test "{{selection}} is the selected text, empty without one" {
    try expect("grep hello", "grep {{selection}}", full);
    try expect("grep ", "grep {{selection}}", .{ .workspace = "/w" });
}

test "unknown tokens stay literal: a misspelling, {{prompt:name}}, an unmatched {{, a bare }}" {
    try expect("{{workspce}} /proj/foo", "{{workspce}} {{workspace}}", full);
    try expect("ask {{prompt:name}}", "ask {{prompt:name}}", full);
    try expect("a {{ b", "a {{ b", full);
    try expect("a }} b /proj/foo", "a }} b {{workspace}}", full);
    try expect("{{}}", "{{}}", full);
    try expect("x{{ workspace }}", "x{{ workspace }}", full);
}

test "a template without a token comes back as itself" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const line = ":term htop";
    try t.expectEqual(line.ptr, (try expand(arena_state.allocator(), line, full)).ptr);
}

test "contextOf: no editor gives the workspace alone; an open file gives its path, the cursor and the selection's first line" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one two\nthree\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    const arena = app.frame.allocator();
    const bare = try contextOf(&app, arena);
    try t.expectEqualStrings(root, bare.workspace);
    try t.expect(bare.current_file == null and bare.cursor_line == null and bare.selection == null);
    const path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(path);
    _ = try app.openPath(path);
    const e = app.activeEditor().?;
    e.buf.editor.placeCursor(1, 2);
    var ctx = try contextOf(&app, arena);
    try t.expectEqualStrings(path, ctx.current_file.?);
    try t.expectEqual(@as(?usize, 2), ctx.cursor_line);
    try t.expectEqual(@as(?usize, 3), ctx.cursor_col);
    try t.expect(ctx.selection == null);
    // Select from the top through the newline: the first line only.
    e.buf.editor.anchor = 0;
    e.buf.editor.cursor = 10;
    ctx = try contextOf(&app, arena);
    try t.expectEqualStrings("one two", ctx.selection.?);
    const line = try expandFor(&app, arena, "code --goto {{current_file}}:{{cursor_line}} {{selection}}");
    try t.expectEqualStrings("code --goto a.txt:2 one two", line);
}
