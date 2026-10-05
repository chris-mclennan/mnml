//! Menu rows other integrations contribute (docs/SDK.md, *Menu
//! contributions*). A manifest's `context_menu[]` names a target — a
//! kind of row or link anywhere (`ticket`, `pr`, `pipeline`, `link`) or
//! one integration's pane rows (`pane:<id>:<kind>`) — and a command of
//! its own. When mnml builds a menu for such a row or link, every
//! installed integration's matching rows follow the menu's own, grouped
//! under a muted header with the contributor's label, ordered by that
//! label and then by manifest order; a click runs the command with the
//! row's values filled into `{id}` `{key}` `{repo}` `{n}` `{url}`. The
//! owner of the menu never learns who added what.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const MenuContribution = command.MenuContribution;
const sdk_manifest = @import("../bridge/manifest.zig").manifest;
const Entry = sdk_manifest.ContextMenuEntry;
const host = @import("../bridge/host.zig");

/// What was clicked: a pane row or a link, and the values it carries.
pub const Row = struct {
    /// `ticket`, `pr`, `pipeline`, or a pane's own row kind; empty for
    /// a link that is only an address.
    kind: []const u8 = "",
    id: []const u8 = "",
    key: []const u8 = "",
    repo: []const u8 = "",
    /// A PR's or a pipeline's number, as text.
    n: []const u8 = "",
    state: []const u8 = "",
    url: []const u8 = "",
    /// The integration whose pane the row is in; empty elsewhere.
    pane: []const u8 = "",
    /// A link: rows targeting `link` match it too.
    link: bool = false,

    fn field(r: Row, name: []const u8) []const u8 {
        inline for (.{ "kind", "id", "key", "repo", "n", "state" }) |f| {
            if (std.mem.eql(u8, name, f)) return @field(r, f);
        }
        return "";
    }
};

/// One integration's rows, under its label.
pub const Source = struct { label: []const u8, rows: []const Entry };

/// Whether a row aimed at `t` belongs on `row`'s menu.
pub fn matches(target: sdk_manifest.Target, row: Row) bool {
    return switch (target.parse() orelse return false) {
        .any => |k| if (std.mem.eql(u8, k, "link")) row.link else row.kind.len > 0 and std.mem.eql(u8, k, row.kind),
        .pane => |p| row.pane.len > 0 and std.mem.eql(u8, p.integration, row.pane) and std.mem.eql(u8, p.row, row.kind),
        .legacy => false,
    };
}

/// Whether `when` (`state=OPEN`, `state!=MERGED`) holds for `row`; a
/// row without a `when` always shows.
pub fn whenHolds(when: ?[]const u8, row: Row) bool {
    const w = sdk_manifest.When.parse(when orelse return true) orelse return false;
    const eq = std.ascii.eqlIgnoreCase(row.field(w.field), w.value);
    return eq != w.negate;
}

/// How a filled value must be written. The values come from what was
/// clicked — a link is whatever a terminal printed — so they are
/// untrusted: never re-read as syntax by whoever runs the result.
pub const Quote = enum {
    /// One argv element, spawned without a shell (a `.mount` command's
    /// args): the value goes in as it is.
    argv,
    /// A `run` line. It can reach `sh -c` (`term …`, `!…`), so each
    /// value is quoted for the POSIX shell in the quoting context the
    /// placeholder sits in — bare, inside '…', inside "…".
    posix,
    /// A `run` line on Windows, where `term …` runs `cmd /d /c`. cmd has
    /// no quoting that makes every byte literal, so a value is filled
    /// only from a safe set (and double-quoted when it holds a space);
    /// anything else is refused.
    windows,

    pub fn forRunLine() Quote {
        return if (@import("builtin").os.tag == .windows) .windows else .posix;
    }
};

pub const FillError = error{
    /// A value with a NUL, a newline or (on Windows) a character cmd
    /// would act on.
    UnsafeValue,
} || Allocator.Error;

/// `template` with `{id}` `{key}` `{repo}` `{n}` `{url}` replaced by
/// `c`'s values, each written for `quote`, on `arena`; any other `{…}`
/// stays as written.
pub fn fill(arena: Allocator, template: []const u8, c: MenuContribution, quote: Quote) FillError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var state: enum { bare, single, double } = .bare;
    var i: usize = 0;
    outer: while (i < template.len) {
        const ch = template[i];
        if (ch == '{') {
            inline for (sdk_manifest.menu_placeholders) |name| {
                const tok = "{" ++ name ++ "}";
                if (std.mem.startsWith(u8, template[i..], tok)) {
                    const v = @field(c, name);
                    if (std.mem.indexOfAny(u8, v, "\x00\n\r") != null) return error.UnsafeValue;
                    switch (quote) {
                        .argv => try out.appendSlice(arena, v),
                        .posix => try posixQuote(arena, &out, v, switch (state) {
                            .bare => .bare,
                            .single => .single,
                            .double => .double,
                        }),
                        .windows => try windowsQuote(arena, &out, v, state == .double),
                    }
                    i += tok.len;
                    continue :outer;
                }
            }
        }
        // The template's own quoting, tracked the way the shell reads it.
        if (quote != .argv) switch (state) {
            .bare => if (ch == '\\' and quote == .posix and i + 1 < template.len) {
                try out.appendSlice(arena, template[i .. i + 2]);
                i += 2;
                continue;
            } else if (ch == '\'' and quote == .posix) {
                state = .single;
            } else if (ch == '"') {
                state = .double;
            },
            .single => if (ch == '\'') {
                state = .bare;
            },
            .double => if (ch == '\\' and quote == .posix and i + 1 < template.len) {
                try out.appendSlice(arena, template[i .. i + 2]);
                i += 2;
                continue;
            } else if (ch == '"') {
                state = .bare;
            },
        };
        try out.append(arena, ch);
        i += 1;
    }
    return out.items;
}

/// `v` as one literal word for `sh`, in the quoting context it lands in.
fn posixQuote(arena: Allocator, out: *std.ArrayList(u8), v: []const u8, ctx: enum { bare, single, double }) Allocator.Error!void {
    switch (ctx) {
        .bare => {
            const plain = v.len > 0 and for (v) |b| {
                if (!(std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "/._-+:@,#=%", b) != null)) break false;
            } else true;
            if (plain) return out.appendSlice(arena, v);
            try out.append(arena, '\'');
            for (v) |b| if (b == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, b);
            try out.append(arena, '\'');
        },
        // Inside '…' nothing is special but the closing quote.
        .single => for (v) |b| if (b == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, b),
        // Inside "…" these four still act; a backslash makes each literal.
        .double => for (v) |b| {
            if (std.mem.indexOfScalar(u8, "\\\"$`", b) != null) try out.append(arena, '\\');
            try out.append(arena, b);
        },
    }
}

/// `v` for `cmd /d /c`: only from a set cmd never acts on, double-quoted
/// when it holds a space and is not already inside "…".
fn windowsQuote(arena: Allocator, out: *std.ArrayList(u8), v: []const u8, in_double: bool) FillError!void {
    var space = false;
    for (v) |b| {
        if (b == ' ') {
            space = true;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "/\\._-+:@,#=~", b) != null)) return error.UnsafeValue;
    }
    const wrap = (space or v.len == 0) and !in_double;
    if (wrap) try out.append(arena, '"');
    try out.appendSlice(arena, v);
    if (wrap) try out.append(arena, '"');
}

/// Append every source's rows that match `row`, each source's under a
/// separator and a muted header with its label — sources by label
/// (ignoring case), rows in manifest order.
pub fn append(arena: Allocator, all: *std.ArrayList(MenuItem), sources: []const Source, row: Row) Allocator.Error!void {
    const order = try arena.dupe(Source, sources);
    std.mem.sort(Source, order, {}, struct {
        fn lt(_: void, a: Source, b: Source) bool {
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.lt);
    for (order) |src| {
        var header = false;
        for (src.rows) |e| {
            if (!matches(e.target, row) or !whenHolds(e.when, row)) continue;
            if (!header) {
                try all.append(arena, .{ .label = src.label, .action = .none, .separator_before = all.items.len > 0 });
                header = true;
            }
            try all.append(arena, .{ .label = e.text(), .action = .{ .contribution = .{
                .command = e.command,
                .id = row.id,
                .key = row.key,
                .repo = row.repo,
                .n = row.n,
                .url = row.url,
                .hover = e.hover orelse e.text(),
            } } });
        }
    }
}

/// `append` over the enabled installed integrations.
pub fn appendInstalled(app: *App, arena: Allocator, all: *std.ArrayList(MenuItem), row: Row) Allocator.Error!void {
    var sources: std.ArrayList(Source) = .empty;
    for (app.integrations.list) |*inst| {
        if (!inst.enabled() or inst.manifest.context_menu.len == 0) continue;
        try sources.append(arena, .{ .label = inst.manifest.label, .rows = inst.manifest.context_menu });
    }
    try append(arena, all, sources.items, row);
}

/// A right-click on a mounted pane's row (`mount_pane.click`): the
/// contributed rows for it, as the host's menu titled with the row's
/// key. False — nothing opened — when no installed integration adds a
/// row for it, so the click goes to the pane as before.
pub fn openRowMenu(app: *App, pane_integration: []const u8, r: host.UnpackedRow, x: u16, y: u16) Allocator.Error!bool {
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const arena = mem.allocator();
    const row: Row = .{
        .kind = try arena.dupe(u8, r.kind),
        .id = try arena.dupe(u8, r.id),
        .key = try arena.dupe(u8, r.key),
        .repo = try arena.dupe(u8, r.repo),
        .n = try arena.dupe(u8, r.n),
        .state = try arena.dupe(u8, r.state),
        .pane = try arena.dupe(u8, pane_integration),
    };
    var all: std.ArrayList(MenuItem) = .empty;
    try appendInstalled(app, arena, &all, row);
    if (all.items.len == 0) {
        mem.deinit();
        return false;
    }
    const title = if (row.key.len > 0) row.key else if (row.id.len > 0) row.id else row.kind;
    const owned = try app.gpa.dupe(MenuItem, all.items);
    errdefer app.gpa.free(owned);
    try @import("context_menus.zig").openOwned(app, title, owned, x, y, mem);
    return true;
}

/// `c`'s strings copied onto `arena` — the menu's own arena goes with
/// its close.
pub fn dupe(arena: Allocator, c: MenuContribution) Allocator.Error!MenuContribution {
    var out: MenuContribution = undefined;
    inline for (@typeInfo(MenuContribution).@"struct".fields) |f| @field(out, f.name) = try arena.dupe(u8, @field(c, f.name));
    return out;
}

/// `fill`, a refused value reported rather than run.
fn filled(app: *App, template: []const u8, c: MenuContribution, quote: Quote) CommandError![]const u8 {
    return fill(app.frame.allocator(), template, c, quote) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsafeValue => return app.diag.fail(app.frame.allocator(), "{s}: not run — what was clicked holds a character it cannot be given safely", .{c.command}),
    };
}

/// A contributed row was picked: its command, the row's values filled
/// into its `run` line or its args. Any other command runs by id.
pub fn run(app: *App, c: MenuContribution) CommandError!void {
    const arena = app.frame.allocator();
    const slot = app.dyn_commands.get(c.command) orelse return command.runNamed(app, c.command);
    const dc = app.dyn_commands.at(slot) orelse return command.runNamed(app, c.command);
    switch (dc.runner) {
        .ex => |line| return @import("launchers.zig").fire(app, try filled(app, line, c, Quote.forRunLine())),
        .mount => |r| {
            const args = try arena.alloc([]const u8, r.args.len);
            for (r.args, args) |a, *o| o.* = try filled(app, a, c, .argv);
            return @import("integrations.zig").runMount(app, .{
                .id = switch (dc.owner) {
                    .integration => |i| i,
                    else => "",
                },
                .binary = r.binary,
                .args = args,
                .pty = r.pty,
                .label = r.label,
            });
        },
        else => return command.run(app, .{ .dyn = slot }),
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "matches: a kind anywhere, link on links, pane:<id>:<kind> only in that pane; older targets never" {
    const ticket: Row = .{ .kind = "ticket", .key = "ACME-123", .pane = "jira" };
    try t.expect(matches(.{ .kind = "ticket" }, ticket));
    try t.expect(!matches(.{ .kind = "pr" }, ticket));
    try t.expect(!matches(.{ .kind = "link" }, ticket));
    try t.expect(matches(.{ .kind = "pane:jira:ticket" }, ticket));
    try t.expect(!matches(.{ .kind = "pane:bitbucket:ticket" }, ticket));
    try t.expect(!matches(.{ .kind = "pane:jira:ticket" }, .{ .kind = "ticket", .link = true }));
    try t.expect(matches(.{ .kind = "link" }, .{ .url = "https://example.com", .link = true }));
    try t.expect(!matches(.{ .kind = "ticket" }, .{ .url = "https://example.com", .link = true }));
    try t.expect(!matches(.{ .kind = "tree.file" }, ticket));
}

test "whenHolds: field=value ignoring case, != negates, no when always, a malformed one never" {
    const pr: Row = .{ .kind = "pr", .state = "OPEN" };
    try t.expect(whenHolds(null, pr));
    try t.expect(whenHolds("state=open", pr));
    try t.expect(!whenHolds("state=MERGED", pr));
    try t.expect(whenHolds("state!=MERGED", pr));
    try t.expect(!whenHolds("colour=red", pr));
}

test "fill: the five placeholders, anything else in braces left alone" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const got = try fill(arena_state.allocator(), "triage {key} {repo}#{n} id={id} {url} {{workspace}} {nope}", .{ .command = "x", .id = "7", .key = "ACME-123", .repo = "acme/widget", .n = "42", .url = "https://e.x/7" }, .posix);
    try t.expectEqualStrings("triage ACME-123 acme/widget#42 id=7 https://e.x/7 {{workspace}} {nope}", got);
}

test "append: grouped under each contributor's header, by label then manifest order, filtered by target and when" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zeta: Source = .{ .label = "zeta", .rows = &.{
        .{ .target = .{ .kind = "pr" }, .label = "Z one", .command = "z.one" },
        .{ .target = .{ .kind = "pr" }, .label = "Z merged only", .command = "z.m", .when = "state=MERGED" },
        .{ .target = .{ .kind = "pr" }, .label = "Z two", .command = "z.two", .hover = "Does two" },
    } };
    const alpha: Source = .{ .label = "Alpha", .rows = &.{
        .{ .target = .{ .kind = "ticket" }, .label = "A ticket", .command = "a.t" },
        .{ .target = .{ .kind = "pane:bitbucket:pr" }, .label = "A pr", .command = "a.p" },
    } };
    var all: std.ArrayList(MenuItem) = .empty;
    try all.append(arena, .{ .label = "Own row", .action = .none });
    try append(arena, &all, &.{ zeta, alpha }, .{ .kind = "pr", .n = "42", .repo = "acme/widget", .state = "OPEN", .pane = "bitbucket" });
    const want = [_][]const u8{ "Own row", "Alpha", "A pr", "zeta", "Z one", "Z two" };
    try t.expectEqual(want.len, all.items.len);
    for (want, all.items) |w, it| try t.expectEqualStrings(w, it.label);
    try t.expect(all.items[1].isInfo() and all.items[1].separator_before);
    try t.expect(all.items[3].isInfo() and all.items[3].separator_before);
    try t.expectEqualStrings("a.p", all.items[2].action.contribution.command);
    try t.expectEqualStrings("acme/widget", all.items[2].action.contribution.repo);
    try t.expectEqualStrings("Z one", all.items[4].action.contribution.hover);
    try t.expectEqualStrings("Does two", all.items[5].action.contribution.hover);
    // Nothing matches: nothing added, not even a header.
    var none: std.ArrayList(MenuItem) = .empty;
    try append(arena, &none, &.{ zeta, alpha }, .{ .kind = "pipeline" });
    try t.expectEqual(@as(usize, 0), none.items.len);
}

const hostile = [_][]const u8{ "$(touch PWNED)", "`touch PWNED`", "; touch PWNED", "a'b", "a\"b", "x && touch PWNED", "a b", "'", "\\", "$HOME", "" };

test "fill: hostile values are one literal word for sh, bare, inside '…' and inside \"…\"; exact quoted text" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("echo '$(touch PWNED)'", try fill(a, "echo {key}", .{ .command = "x", .key = "$(touch PWNED)" }, .posix));
    try t.expectEqualStrings("echo 'a'\\''b'", try fill(a, "echo {key}", .{ .command = "x", .key = "a'b" }, .posix));
    try t.expectEqualStrings("echo 'a'\\''b'", try fill(a, "echo '{key}'", .{ .command = "x", .key = "a'b" }, .posix));
    try t.expectEqualStrings("echo \"\\$(x) \\` \\\" \\\\\"", try fill(a, "echo \"{key}\"", .{ .command = "x", .key = "$(x) ` \" \\" }, .posix));
    // Plain values are written as they are.
    try t.expectEqualStrings("echo ACME-123 acme/widget#42", try fill(a, "echo {key} {repo}#{n}", .{ .command = "x", .key = "ACME-123", .repo = "acme/widget", .n = "42" }, .posix));
    // An argv element takes the text as it is.
    try t.expectEqualStrings("--key=$(touch PWNED)", try fill(a, "--key={key}", .{ .command = "x", .key = "$(touch PWNED)" }, .argv));
    // A NUL or a line break is refused in every mode.
    for ([_]Quote{ .argv, .posix, .windows }) |q| for ([_][]const u8{ "a\nb", "a\rb", "a\x00b" }) |v| {
        try t.expectError(error.UnsafeValue, fill(a, "echo {key}", .{ .command = "x", .key = v }, q));
    };
    // cmd: a safe set, double-quoted around a space; anything else refused.
    try t.expectEqualStrings("echo \"a b\"", try fill(a, "echo {key}", .{ .command = "x", .key = "a b" }, .windows));
    for ([_][]const u8{ "a&b", "a|b", "a\"b", "%PATH%", "a^b", "a<b", "!x!" }) |v|
        try t.expectError(error.UnsafeValue, fill(a, "echo {key}", .{ .command = "x", .key = v }, .windows));
}

test "fill: run through /bin/sh, each hostile value arrives as one literal argument and nothing else runs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "printf '[%s]' {key}", "printf '[%s]' '{key}'", "printf '[%s]' \"{key}\"" }) |template| for (hostile) |v| {
        const line = try fill(a, template, .{ .command = "x", .key = v }, .posix);
        const res = try std.process.run(a, t.io, .{ .argv = &.{ "/bin/sh", "-c", line }, .cwd = .{ .path = dir } });
        try t.expect(res.term == .exited and res.term.exited == 0);
        // `[v]` exactly once: one argument, the literal text.
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "[{s}]", .{v}), res.stdout);
        try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "PWNED", .{}));
    };
}
