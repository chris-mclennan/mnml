//! Cross-links out of a pull request — the `[jira]`, `[github]` and
//! `[mnml]` sections of `config.zon` made to do something.
//!
//! A PR title and description carry issue keys (`ENG-4210`), and the
//! useful thing to do with one depends on what else the user has
//! installed. So the rule is one sentence: **run the sibling
//! integration's command when its manifest is in the data root, and
//! open a browser when it is not.** `target` decides that without
//! doing either, which is what makes it testable; the pane carries out
//! whichever answer comes back.
//!
//! Key scanning is deliberately narrow. `[A-Z][A-Z0-9]+-[0-9]+` also
//! matches `UTF-8`, `HTTP-2` and `SEV-1`, so a configured
//! `jira.project_keys` list is the honest default for a real workspace;
//! an empty list keeps the loose behaviour for someone who has not
//! filled it in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cfg = @import("config.zig");

pub const Key = struct {
    /// A slice of the text scanned.
    text: []const u8,
    /// The project half — `TE` of `ENG-4210`.
    project: []const u8,
};

/// Every issue key in `text`, in order, without duplicates. When
/// `project_keys` is non-empty only those projects count. Allocated on
/// `arena`; the keys borrow `text`.
pub fn scanKeys(arena: Allocator, text: []const u8, project_keys: []const []const u8) Allocator.Error![]const Key {
    var out: std.ArrayList(Key) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!isUpper(text[i]) or (i > 0 and isKeyByte(text[i - 1]))) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < text.len and (isUpper(text[j]) or isDigit(text[j]))) j += 1;
        if (j >= text.len or text[j] != '-' or j - i < 2) {
            i = j + 1;
            continue;
        }
        const project = text[i..j];
        var k = j + 1;
        while (k < text.len and isDigit(text[k])) k += 1;
        if (k == j + 1 or (k < text.len and isKeyByte(text[k]))) {
            i = k + 1;
            continue;
        }
        if (projectWanted(project, project_keys)) {
            const key: Key = .{ .text = text[i..k], .project = project };
            var seen = false;
            for (out.items) |o| if (std.mem.eql(u8, o.text, key.text)) {
                seen = true;
            };
            if (!seen) try out.append(arena, key);
        }
        i = k;
    }
    return out.toOwnedSlice(arena);
}

fn projectWanted(project: []const u8, list: []const []const u8) bool {
    if (list.len == 0) return true;
    for (list) |p| if (std.ascii.eqlIgnoreCase(p, project)) return true;
    return false;
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isKeyByte(c: u8) bool {
    return isUpper(c) or isDigit(c) or c == '-' or (c >= 'a' and c <= 'z');
}

// ─── where a link goes ───────────────────────────────────────────────────

pub const Target = union(enum) {
    /// Ask mnml to run this command id — the sibling integration is
    /// installed and owns the surface.
    command: []const u8,
    /// Open this URL in a browser.
    url: []const u8,
    /// Neither is possible; the reason is for the toast.
    unavailable: []const u8,
};

/// Is `<data root>/integrations/<id>.zon` there? That file is exactly
/// what `--install` writes, so its presence is the same question as
/// "is that integration installed".
pub fn installed(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, id: []const u8) bool {
    const root = (cfg.dataRoot(gpa, env) catch return false) orelse return false;
    defer gpa.free(root);
    const name = std.fmt.allocPrint(gpa, "{s}.zon", .{id}) catch return false;
    defer gpa.free(name);
    const p = std.fs.path.join(gpa, &.{ root, "integrations", name }) catch return false;
    defer gpa.free(p);
    if (Io.Dir.cwd().access(io, p, .{})) |_| return true else |_| return false;
}

/// Where a Jira key should go. `arena` owns the URL when there is one.
pub fn jiraTarget(arena: Allocator, c: cfg.Jira, key: []const u8, jira_installed: bool) Allocator.Error!Target {
    if (!c.enabled) return .{ .unavailable = "jira cross-links are off in config.zon" };
    if (jira_installed and c.command.len > 0) return .{ .command = c.command };
    if (c.base_url.len > 0) {
        const base = std.mem.trimEnd(u8, c.base_url, "/");
        return .{ .url = try std.fmt.allocPrint(arena, "{s}/browse/{s}", .{ base, key }) };
    }
    return .{ .unavailable = "no jira integration installed and no `jira.base_url` set" };
}

/// The same rule for the github section — a mirror of the same source.
pub fn githubTarget(arena: Allocator, c: cfg.Github, repo: []const u8, branch: []const u8, github_installed: bool) Allocator.Error!Target {
    if (!c.enabled) return .{ .unavailable = "github cross-links are off in config.zon" };
    if (github_installed and c.command.len > 0) return .{ .command = c.command };
    if (c.base_url.len > 0) {
        const base = std.mem.trimEnd(u8, c.base_url, "/");
        return .{ .url = try std.fmt.allocPrint(arena, "{s}/{s}/tree/{s}", .{ base, repo, branch }) };
    }
    return .{ .unavailable = "no github integration installed and no `github.base_url` set" };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "issue keys are found in a title and a body, in order and without repeats" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const text = "Fixes ENG-4210 and ENG-4211. See also ENG-4210 again, and PROJ-7.";
    const keys = try scanKeys(arena.allocator(), text, &.{});
    try t.expectEqual(@as(usize, 3), keys.len);
    try t.expectEqualStrings("ENG-4210", keys[0].text);
    try t.expectEqualStrings("TE", keys[0].project);
    try t.expectEqualStrings("ENG-4211", keys[1].text);
    try t.expectEqualStrings("PROJ-7", keys[2].text);
}

test "a configured project list is what stops UTF-8 and SEV-1 reading as issue keys" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const text = "A UTF-8 bug, a SEV-1 incident, and TE-99.";
    const loose = try scanKeys(arena.allocator(), text, &.{});
    try t.expectEqual(@as(usize, 3), loose.len); // the over-match, honestly
    const narrow = try scanKeys(arena.allocator(), text, &.{ "TE", "PROJ" });
    try t.expectEqual(@as(usize, 1), narrow.len);
    try t.expectEqualStrings("TE-99", narrow[0].text);
    // The list is matched case-insensitively, since config is hand-typed.
    const lower = try scanKeys(arena.allocator(), text, &.{"te"});
    try t.expectEqual(@as(usize, 1), lower.len);
}

test "things that look like keys but are not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A single leading letter, a key with no number, a key glued to a
    // word, and a lower-case project.
    try t.expectEqual(@as(usize, 0), (try scanKeys(a, "T-1", &.{})).len);
    try t.expectEqual(@as(usize, 0), (try scanKeys(a, "TE-", &.{})).len);
    try t.expectEqual(@as(usize, 0), (try scanKeys(a, "XY-4210x", &.{})).len);
    try t.expectEqual(@as(usize, 0), (try scanKeys(a, "eng-4210", &.{})).len);
    try t.expectEqual(@as(usize, 0), (try scanKeys(a, "xTE-4210", &.{})).len);
    try t.expectEqual(@as(usize, 0), (try scanKeys(a, "", &.{})).len);
    // But one at the very start and one at the very end both count.
    const edges = try scanKeys(a, "TE-1 middle TE-2", &.{});
    try t.expectEqual(@as(usize, 2), edges.len);
}

test "a key runs the jira command when jira is installed, and opens a browser when it is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: cfg.Jira = .{ .enabled = true, .command = "jira.open", .base_url = "https://acme.atlassian.net/" };
    try t.expectEqualStrings("jira.open", (try jiraTarget(a, c, "TE-1", true)).command);
    try t.expectEqualStrings("https://acme.atlassian.net/browse/TE-1", (try jiraTarget(a, c, "TE-1", false)).url);
    // No sibling and no base URL: say so rather than opening nothing.
    const bare: cfg.Jira = .{ .enabled = true, .command = "jira.open" };
    try t.expect(std.mem.indexOf(u8, (try jiraTarget(a, bare, "TE-1", false)).unavailable, "jira.base_url") != null);
    const off: cfg.Jira = .{ .enabled = false };
    try t.expect(std.mem.indexOf(u8, (try jiraTarget(a, off, "TE-1", true)).unavailable, "off") != null);
}

test "the github section follows the same rule" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: cfg.Github = .{ .enabled = true, .command = "github.open", .base_url = "https://github.com/acme" };
    try t.expectEqualStrings("github.open", (try githubTarget(a, c, "api", "main", true)).command);
    try t.expectEqualStrings("https://github.com/acme/api/tree/main", (try githubTarget(a, c, "api", "main", false)).url);
    try t.expect(std.mem.indexOf(u8, (try githubTarget(a, .{}, "api", "main", false)).unavailable, "off") != null);
}

test "installed asks the filesystem the same question --install answers" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    try t.expect(!installed(t.allocator, t.io, &env, "jira"));
    try tmp.dir.createDirPath(t.io, "integrations");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/jira.zon", .data = ".{ .id = \"jira\", .label = \"Jira\" }" });
    try t.expect(installed(t.allocator, t.io, &env, "jira"));
    try t.expect(!installed(t.allocator, t.io, &env, "github"));
    // No data root at all is "not installed", not a crash.
    var empty = std.process.Environ.Map.init(t.allocator);
    defer empty.deinit();
    try t.expect(!installed(t.allocator, t.io, &empty, "jira"));
}
