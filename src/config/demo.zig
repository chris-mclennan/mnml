//! `--demo`: a populated mnml you can try without touching anything of
//! yours and without the network.
//!
//! `mnml --demo` is `--sandbox` (`sandbox.zig`: a throwaway home,
//! removed on exit) with a workspace in it. The re-exec that makes the
//! sandbox also sets, on top of the sandbox's own variables:
//!
//!   MNML_DEMO             <root>/tour — the workspace; the chip reads it
//!   PATH                  <root>/demo/bin first: the stand-in `claude`
//!                         and `codex` (no model runs)
//!   JIRA_BASE_URL         @<root>/demo/jira.url  — the offline Jira
//!   BITBUCKET_BASE_URL    @<root>/demo/bb.url    — the offline Bitbucket
//!   JIRA_API_TOKEN, BITBUCKET_API_TOKEN          — the fakes' own tokens
//!   BITBUCKET_ACCESS_TOKEN  the Bitbucket fake's token again, for the
//!                         Jira pane's linked pull requests
//!   MNML_NO_UPDATE_CHECK  1     (no release probe)
//!   MNML_OPEN_URL         none  (a link opens nothing)
//!   MNML_AGENTS_PGID      a group nobody is in, so the agents scan sees
//!                         the demo's own sessions and not the machine's
//!
//! and removes the variables that would reach something real — the
//! model API keys, the other Bitbucket tokens, a config override. Then,
//! in the re-executed process (the one that owns the sandbox), `setup`:
//!
//!   * writes the workspace `<root>/tour` — the fixture the real-screen
//!     tour and the site recordings build (`data/demo/tour/`, embedded;
//!     `tools/tour/workspace.py` reads the same files) — and its history
//!     with `git`: five commits and a merge on `main`, then the demo's
//!     own commit of request files by a second author and an unmerged
//!     `feature/cli-args`; then the dirty working tree;
//!   * writes the throwaway home: its `config.zon` (the first-launch
//!     setup skipped), its `init.lua` (the first screen: `util.zig`, a
//!     Claude Code session on the right, a shell under it), a zsh prompt,
//!     three earlier agent transcripts, and the Jira / Bitbucket configs;
//!   * finds `mnml-jira` and `mnml-bitbucket` (`locate`: beside this
//!     binary, else where the Marketplace installed them in the data
//!     root of the mnml that ran `--demo` — `MNML_DEMO_HOST_DATA_ROOT`),
//!     links them into the sandbox's data root and runs each one's
//!     `--install`;
//!   * starts `mnml-fake-jira` and `mnml-fake-bitbucket` beside this
//!     binary — a release archive and the Linux packages carry them
//!     there — each in a process group of its own and told to exit with
//!     this process (`--parent-pid`), and writes their URLs into the
//!     workspace's `.mnml/env/dev.env` for the request files.
//!
//! A piece that is not there — no `git`, no integration, no fake — is
//! skipped and named in the first frame's toast, with the places that
//! were looked in; the rest of the demo still opens. On exit the fakes are stopped, then the
//! sandbox (workspace included) is removed.
//!
//! The fixture is embedded rather than read from the source tree, so an
//! installed binary carries its own demo and `zig build` needs nothing
//! but this repository. Its history is made by `git` at first run: a
//! checked-in repository cannot live inside another one's tree, and a
//! tarball would be the one opaque file in the build.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const Child = std.process.Child;
const data = @import("data").demo;
const data_root_mod = @import("data_root.zig");
const child_os = @import("../core/child.zig");

pub const flag = "--demo";
/// The demo's workspace; set by the re-exec. With the sandbox's own
/// variable, what paints the ` demo ` chip.
pub const env_var = "MNML_DEMO";
pub const workspace_name = "tour";
/// `<root>/demo/`: the shims (`bin/`), the fakes' URL files, their
/// rate-limit buckets.
pub const state_dir = "demo";

pub const supported = @import("sandbox.zig").supported;

/// The fakes' own credentials (`mnml-fake-jira`: `fake@acme.com` /
/// `fake-token`; `mnml-fake-bitbucket` takes any token for a read).
pub const jira_token = "fake-token";
pub const bitbucket_token = "corpus-read-token";
/// `fake@acme.com:fake-token`, base64 — the request files' `{{jira_basic}}`.
pub const jira_basic = "ZmFrZUBhY21lLmNvbTpmYWtlLXRva2Vu";
/// `me@example.com:corpus-read-token`, base64 — `{{bitbucket_basic}}`
/// (the fake takes an account credential as Basic).
pub const bitbucket_basic = "bWVAZXhhbXBsZS5jb206Y29ycHVzLXJlYWQtdG9rZW4=";
/// No process is in this group: the agents scan sees only what this
/// mnml spawned (`app/agents.zig`, `MNML_AGENTS_PGID`).
pub const agents_pgid = "2147483000";
/// The data root of the mnml that ran `--demo`, before the sandbox
/// replaced it — where the Marketplace installed the integrations.
/// Set by the re-exec when there is one.
pub const host_data_root_env = "MNML_DEMO_HOST_DATA_ROOT";

/// Variables the re-exec drops: each would reach a real account.
pub const unset = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "BITBUCKET_ACCESS_TOKEN",
    "BITBUCKET_APP_PASSWORD",
    "BITBUCKET_PERSONAL_TOKEN",
    "MNML_JIRA_CONFIG",
    "MNML_BITBUCKET_CONFIG",
    "MNML_MARKETPLACE_LOCAL",
    "MNML_ENV",
};

pub fn wanted(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

/// The workspace this process is to seed: `MNML_DEMO`, when set.
pub fn workspaceOf(env: *const Map) ?[]const u8 {
    const v = env.get(env_var) orelse return null;
    return if (v.len == 0) null else v;
}

/// What the re-exec sets on top of the sandbox's variables, for the
/// sandbox at `root`. `path` is the current `PATH` (null: none);
/// `host_data_root` the data root the sandbox is about to replace
/// (null: none known). Allocated in `arena`.
pub fn extraSet(arena: Allocator, root: []const u8, path: ?[]const u8, host_data_root: ?[]const u8) Allocator.Error![]const [2][]const u8 {
    const dir = try std.fs.path.join(arena, &.{ root, state_dir });
    const bin = try std.fs.path.join(arena, &.{ dir, "bin" });
    const new_path = if (path) |p| (if (p.len > 0) try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ bin, std.fs.path.delimiter, p }) else bin) else bin;
    const out = try arena.alloc([2][]const u8, if (host_data_root != null) 14 else 13);
    out[0] = .{ env_var, try std.fs.path.join(arena, &.{ root, workspace_name }) };
    out[1] = .{ "PATH", new_path };
    out[2] = .{ "JIRA_BASE_URL", try std.fmt.allocPrint(arena, "@{s}", .{try std.fs.path.join(arena, &.{ dir, "jira.url" })}) };
    out[3] = .{ "BITBUCKET_BASE_URL", try std.fmt.allocPrint(arena, "@{s}", .{try std.fs.path.join(arena, &.{ dir, "bb.url" })}) };
    out[4] = .{ "JIRA_API_TOKEN", jira_token };
    out[5] = .{ "BITBUCKET_API_TOKEN", bitbucket_token };
    out[6] = .{ "JIRA_RATELIMIT_STATE", try std.fs.path.join(arena, &.{ dir, "jira-bucket.json" }) };
    out[7] = .{ "BITBUCKET_RATELIMIT_STATE", try std.fs.path.join(arena, &.{ dir, "bb-bucket.json" }) };
    out[8] = .{ "MNML_NO_UPDATE_CHECK", "1" };
    out[9] = .{ "MNML_OPEN_URL", "none" };
    out[10] = .{ "MNML_AGENTS_PGID", agents_pgid };
    out[11] = .{ "GIT_CEILING_DIRECTORIES", root };
    // The Jira pane's linked pull requests ask the forge with the token
    // its `bitbucket_token_env` names, `BITBUCKET_ACCESS_TOKEN` by
    // default: the fake's token under that name too, in place of the
    // real one `unset` drops (the forge is the fake, `BITBUCKET_BASE_URL`).
    out[12] = .{ "BITBUCKET_ACCESS_TOKEN", bitbucket_token };
    if (host_data_root) |d| out[13] = .{ host_data_root_env, d };
    return out;
}

// ─── the seed ────────────────────────────────────────────────────────────

/// What `setup` could not do; each becomes a clause of the first toast.
pub const Missing = struct {
    git: bool = false,
    integrations: bool = false,
    fakes: bool = false,
    /// Where the integrations and the fakes were looked for.
    places: Places = .{},

    pub fn any(m: Missing) bool {
        return m.git or m.integrations or m.fakes;
    }

    /// The toast for the first frame. Owned.
    pub fn note(m: Missing, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "demo — a sample workspace, offline Jira and Bitbucket and a stand-in Claude, in a throwaway home removed on exit");
        if (m.git) try out.appendSlice(gpa, "; no `git`, so the workspace has no history");
        const beside_text = m.places.exe_dir orelse "(this binary's directory is unknown)";
        if (m.integrations) {
            try out.print(gpa, "; mnml-jira / mnml-bitbucket are not in {s}", .{beside_text});
            if (m.places.host_data_root) |d| try out.print(gpa, " nor installed from the Marketplace in {s}", .{d});
            try out.appendSlice(gpa, ", so their panes are not installed");
        }
        if (m.fakes) try out.print(gpa, "; mnml-fake-jira / mnml-fake-bitbucket are not in {s}, so nothing answers those panes", .{beside_text});
        return out.toOwnedSlice(gpa);
    }
};

const Author = struct { name: []const u8, email: []const u8 };
const tour_author: Author = .{ .name = "Tour Author", .email = "tour@example.com" };
const second_author: Author = .{ .name = "Sam Rivera", .email = "sam@example.com" };

fn write(io: Io, dir: []const u8, rel: []const u8, text: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, rel });
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn writeExe(io: Io, dir: []const u8, rel: []const u8, text: []const u8) !void {
    try write(io, dir, rel, text);
    // No mode bits on Windows, where `--demo` is refused anyway.
    if (comptime builtin.os.tag == .windows) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, rel });
    try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{});
}

/// One `git` in the workspace, with a fixed author and, for a commit, a
/// fixed date — so a demo's hashes are the same every run. False when
/// git is missing or refused.
fn git(arena: Allocator, io: Io, base: *const Map, ws: []const u8, args: []const []const u8, date: ?[]const u8, who: Author) bool {
    var env = base.clone(arena) catch return false;
    env.put("GIT_AUTHOR_NAME", who.name) catch return false;
    env.put("GIT_AUTHOR_EMAIL", who.email) catch return false;
    env.put("GIT_COMMITTER_NAME", who.name) catch return false;
    env.put("GIT_COMMITTER_EMAIL", who.email) catch return false;
    env.put("GIT_CONFIG_NOSYSTEM", "1") catch return false;
    if (date) |d| {
        env.put("GIT_AUTHOR_DATE", d) catch return false;
        env.put("GIT_COMMITTER_DATE", d) catch return false;
    }
    const argv = arena.alloc([]const u8, args.len + 1) catch return false;
    argv[0] = "git";
    @memcpy(argv[1..], args);
    const r = std.process.run(arena, io, .{ .argv = argv, .cwd = .{ .path = ws }, .environ_map = &env }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

/// The workspace at `ws`, its history made by `git` with `home` as the
/// HOME git sees. Returns false when git could not make the history (the
/// files are all there either way).
pub fn seedWorkspace(gpa: Allocator, io: Io, env: *const Map, ws: []const u8, home: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base = try env.clone(arena);
    try base.put("HOME", home);
    try base.put("GIT_CEILING_DIRECTORIES", home);
    try Io.Dir.cwd().createDirPath(io, ws);

    // The tour's history (`tools/tour/workspace.py`, step for step).
    var ok = git(arena, io, &base, ws, &.{ "init", "-q", "-b", "main" }, null, tour_author);
    for ([_][2][]const u8{ .{ "user.name", tour_author.name }, .{ "user.email", tour_author.email }, .{ "commit.gpgsign", "false" } }) |kv| {
        if (ok) ok = git(arena, io, &base, ws, &.{ "config", kv[0], kv[1] }, null, tour_author);
    }
    try write(io, ws, "README.md", data.readme);
    try write(io, ws, ".gitignore", data.gitignore);
    try write(io, ws, "src/main.zig", data.main_v1);
    ok = ok and commit(arena, io, &base, ws, "Start the tour project", "2026-09-01T09:00:00+0000", tour_author);
    try write(io, ws, "src/util.zig", data.util);
    ok = ok and commit(arena, io, &base, ws, "Add util.sum with a test", "2026-09-02T10:30:00+0000", tour_author);
    ok = ok and git(arena, io, &base, ws, &.{ "checkout", "-q", "-b", "feature/numbers" }, null, tour_author);
    try write(io, ws, "src/main.zig", data.main_v2);
    ok = ok and commit(arena, io, &base, ws, "Sum five numbers and mark the follow-ups", "2026-09-03T14:15:00+0000", tour_author);
    ok = ok and git(arena, io, &base, ws, &.{ "checkout", "-q", "main" }, null, tour_author);
    ok = ok and git(arena, io, &base, ws, &.{ "merge", "-q", "--no-ff", "feature/numbers", "-m", "Merge feature/numbers" }, "2026-09-04T08:45:00+0000", tour_author);
    try write(io, ws, "docs/notes.md", data.docs_notes);
    ok = ok and commit(arena, io, &base, ws, "Add a docs folder", "2026-09-05T16:00:00+0000", tour_author);

    // The demo's own: request files for the fakes on `main` by a second
    // author, and a branch still open.
    try write(io, ws, "requests/jira.http", data.jira_http);
    try write(io, ws, "requests/bitbucket.http", data.bitbucket_http);
    ok = ok and commit(arena, io, &base, ws, "Add request files for the offline Jira and Bitbucket", "2026-09-06T11:20:00+0000", second_author);
    ok = ok and git(arena, io, &base, ws, &.{ "checkout", "-q", "-b", "feature/cli-args" }, null, second_author);
    if (ok) {
        try write(io, ws, "src/args.zig", data.args_zig);
        ok = commit(arena, io, &base, ws, "Parse the numbers from the command line (WIP)", "2026-09-07T15:40:00+0000", second_author);
        ok = ok and git(arena, io, &base, ws, &.{ "checkout", "-q", "main" }, null, tour_author);
    }

    // The working tree: one modified file, one untracked.
    try write(io, ws, "src/util.zig", data.util_dirty);
    try write(io, ws, "CHANGELOG.md", data.changelog);
    // mnml's own workspace state.
    try write(io, ws, ".mnml/config.zon", data.workspace_config);
    try write(io, ws, ".mnml/notes/release.md", data.note_release);
    try write(io, ws, ".mnml/findings/tour-clock.md", data.finding);
    return ok;
}

fn commit(arena: Allocator, io: Io, base: *const Map, ws: []const u8, msg: []const u8, date: []const u8, who: Author) bool {
    return git(arena, io, base, ws, &.{ "add", "-A" }, null, who) and
        git(arena, io, base, ws, &.{ "commit", "-q", "-m", msg }, date, who);
}

/// The three earlier sessions the sessions views list — transcripts,
/// as the site recordings plant them (`record.py` `plant_sessions`):
/// id, minutes ago, the ask, the reply, input / output / cache-read
/// tokens.
const Planted = struct { id: []const u8, age_min: i64, ask: []const u8, reply: []const u8, in: u32, out: u32, cache: u32 };
pub const planted = [_]Planted{
    .{ .id = "3f9c1a02-5d1e-4c7a-9b20-6e81d4f0a113", .age_min = 25, .ask = "add a max() helper to util.zig", .reply = "Added max() with a test for the empty slice.", .in = 18400, .out = 2150, .cache = 142000 },
    .{ .id = "a71e0b44-2c93-4f5d-8e1a-0b7c3d9e2f48", .age_min = 70, .ask = "write the 0.1.0 changelog entry", .reply = "Drafted CHANGELOG.md from the last five commits.", .in = 9600, .out = 1320, .cache = 61000 },
    .{ .id = "c2d86e19-7a4b-4e02-a5f3-91d0c6b8e275", .age_min = 180, .ask = "why does main print nothing for an empty list", .reply = "util.sum returns 0; main now prints a message.", .in = 31200, .out = 4870, .cache = 288000 },
};

/// Claude Code's project directory name for `ws`: every `/` and `.` a `-`.
pub fn projectDirName(arena: Allocator, ws: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, ws);
    for (out) |*c| if (c.* == '/' or c.* == '.' or c.* == '\\') {
        c.* = '-';
    };
    return out;
}

fn jsonString(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

pub fn plantSessions(gpa: Allocator, io: Io, home: []const u8, ws: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fs.path.join(arena, &.{ home, ".claude", "projects", try projectDirName(arena, ws) });
    try Io.Dir.cwd().createDirPath(io, dir);
    const now = Io.Clock.real.now(io);
    for (planted) |p| {
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"type\":\"user\",\"cwd\":");
        try jsonString(w, ws);
        try w.writeAll(",\"gitBranch\":\"main\",\"message\":{\"role\":\"user\",\"content\":");
        try jsonString(w, p.ask);
        try w.writeAll("}}\n{\"type\":\"assistant\",\"cwd\":");
        try jsonString(w, ws);
        try w.print(",\"gitBranch\":\"main\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"claude-sonnet-5\",\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_input_tokens\":{d}}},\"content\":[{{\"type\":\"text\",\"text\":", .{ p.id[0..8], p.in, p.out, p.cache });
        try jsonString(w, p.reply);
        try w.writeAll("}]}}\n");
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ dir, p.id });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
        // Its age is its mtime: the sessions table's "25m ago".
        const f = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch continue;
        defer f.close(io);
        const at: Io.Timestamp = .fromNanoseconds(now.nanoseconds - @as(i96, p.age_min) * 60 * std.time.ns_per_s);
        f.setTimestamps(io, .{ .access_timestamp = .{ .new = at }, .modify_timestamp = .{ .new = at } }) catch {};
    }
}

/// The throwaway home: `root` is HOME, `data_root` mnml's state in it.
pub fn seedHome(io: Io, root: []const u8, data_root: []const u8) !void {
    try write(io, data_root, "config.zon", data.home_config);
    try write(io, data_root, "init.lua", data.init_lua);
    try write(io, data_root, "integrations/jira/config.zon", data.jira_config);
    try write(io, data_root, "integrations/bitbucket/config.zon", data.bitbucket_config);
    try write(io, root, ".zshrc", data.zshrc);
    // The one-time ghost-text tip is not what a demo is about.
    try write(io, root, ".config/mnml/ghost-text-hint-shown", "");
    try writeExe(io, root, state_dir ++ "/bin/claude", data.claude_shim);
    try writeExe(io, root, state_dir ++ "/bin/codex", data.codex_shim);
}

/// A program `--demo` runs: the Marketplace id it installs under, and
/// its file name (without `.exe`).
pub const Tool = struct { id: []const u8, name: []const u8 };
pub const integrations = [_]Tool{ .{ .id = "jira", .name = "mnml-jira" }, .{ .id = "bitbucket", .name = "mnml-bitbucket" } };
pub const fakes = [_]Tool{ .{ .id = "jira", .name = "mnml-fake-jira" }, .{ .id = "bitbucket", .name = "mnml-fake-bitbucket" } };

/// Where `locate` looks.
pub const Places = struct {
    /// The running binary's directory: a source build's `zig-out/bin`,
    /// an unpacked release archive, a package's `bin`.
    exe_dir: ?[]const u8 = null,
    /// The data root of the mnml that ran `--demo` (`host_data_root_env`).
    host_data_root: ?[]const u8 = null,
};

fn exeName(buf: []u8, name: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) std.fmt.bufPrint(buf, "{s}.exe", .{name}) catch name else name;
}

/// The paths `locate` tries for `tool`, in order: beside this binary;
/// then, with `marketplace`, the link the Marketplace makes
/// (`<host data root>/bin/<name>`) and the file it writes
/// (`<host data root>/integrations/<id>/bin/<name>`,
/// `app/marketplace_release.zig`). The fakes are never a Marketplace
/// install, so they are looked for beside the binary only.
pub fn candidates(arena: Allocator, places: Places, tool: Tool, marketplace: bool) Allocator.Error![]const []const u8 {
    var nb: [64]u8 = undefined;
    const file = try arena.dupe(u8, exeName(&nb, tool.name));
    var out: std.ArrayList([]const u8) = .empty;
    if (places.exe_dir) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, file }));
    if (marketplace) if (places.host_data_root) |r| {
        try out.append(arena, try std.fs.path.join(arena, &.{ r, "bin", file }));
        try out.append(arena, try std.fs.path.join(arena, &.{ r, "integrations", tool.id, "bin", file }));
    };
    return out.items;
}

/// The first of `candidates` that is there, or null.
pub fn locate(arena: Allocator, io: Io, places: Places, tool: Tool, marketplace: bool) ?[]const u8 {
    const list = candidates(arena, places, tool, marketplace) catch return null;
    for (list) |p| {
        Io.Dir.cwd().access(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

/// `<data_root>/bin/<file>` → `target`: where `integrations.resolveBinary`
/// looks first. A copy where a link cannot be made.
fn linkInto(arena: Allocator, io: Io, data_root: []const u8, target: []const u8) !void {
    const bin = try std.fs.path.join(arena, &.{ data_root, "bin" });
    try Io.Dir.cwd().createDirPath(io, bin);
    const link = try std.fs.path.join(arena, &.{ bin, std.fs.path.basename(target) });
    Io.Dir.cwd().deleteFile(io, link) catch {};
    Io.Dir.cwd().symLink(io, target, link, .{}) catch {
        try Io.Dir.cwd().copyFile(target, Io.Dir.cwd(), link, io, .{});
    };
}

/// Find `mnml-jira` and `mnml-bitbucket` (`locate`), link them into the
/// sandbox's data root and run each one's `--install` (its manifests into
/// that data root). False when either is not found or will not install.
pub fn installIntegrations(gpa: Allocator, io: Io, env: *const Map, places: Places, data_root: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bins: [integrations.len][]const u8 = undefined;
    for (integrations, 0..) |tool, i| bins[i] = locate(arena, io, places, tool, true) orelse return false;
    var ienv = try env.clone(arena);
    try ienv.put("MNML_DATA_ROOT", data_root);
    var ok = true;
    for (bins) |b| {
        linkInto(arena, io, data_root, b) catch {
            ok = false;
            continue;
        };
        const r = std.process.run(arena, io, .{ .argv = &.{ b, "--install" }, .environ_map = &ienv }) catch {
            ok = false;
            continue;
        };
        if (!(r.term == .exited and r.term.exited == 0)) ok = false;
    }
    return ok;
}

// ─── the fakes ───────────────────────────────────────────────────────────

pub const Fakes = struct {
    children: [fakes.len]?Child = .{ null, null },

    pub fn running(self: *const Fakes) usize {
        var n: usize = 0;
        for (self.children) |c| if (c != null) {
            n += 1;
        };
        return n;
    }

    /// Stop both, and whatever they started (each leads its own group).
    pub fn stop(self: *Fakes, io: Io) void {
        for (&self.children) |*slot| if (slot.*) |*c| {
            child_os.terminate(io, c, .{ .group = true, .grace = .fromMilliseconds(500) });
            slot.* = null;
        };
    }
};

fn getpid() i64 {
    if (comptime builtin.os.tag == .windows) return 0;
    return @intCast(std.c.getpid());
}

/// Start the two fakes beside this binary, their URLs into
/// `<root>/demo/{jira,bb}.url`; wait (a bounded while) for both, then
/// write the workspace's `.mnml/env/dev.env` for the request files.
pub fn startFakes(gpa: Allocator, io: Io, env: *const Map, root: []const u8, ws: []const u8, places: Places) !Fakes {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fs.path.join(arena, &.{ root, state_dir });
    try Io.Dir.cwd().createDirPath(io, dir);
    const pid = try std.fmt.allocPrint(arena, "{d}", .{getpid()});
    const urls = [_][]const u8{ try std.fs.path.join(arena, &.{ dir, "jira.url" }), try std.fs.path.join(arena, &.{ dir, "bb.url" }) };
    var started: Fakes = .{};
    // A bound on each fake's life if this process is killed hard and
    // `--parent-pid` somehow misses it: half a day.
    const life = "43200";
    for (fakes, 0..) |tool, i| {
        const bin = locate(arena, io, places, tool, false) orelse continue;
        const argv: []const []const u8 = if (i == 0)
            &.{ bin, "--port", "0", "--url-file", urls[i], "--parent-pid", pid, "--life-secs", life, "--quiet" }
        else
            &.{ bin, "--port", "0", "--url-file", urls[i], "--parent-pid", pid, "--lifetime-secs", life };
        started.children[i] = std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = dir },
            .environ_map = env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        }) catch null;
    }
    if (started.running() == 0) return started;
    // Each writes its URL file once it listens.
    var got: [2]?[]const u8 = .{ null, null };
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 20) {
        for (urls, 0..) |u, i| if (got[i] == null and started.children[i] != null) {
            const text = Io.Dir.cwd().readFileAlloc(io, u, arena, .limited(4096)) catch continue;
            const url = std.mem.trim(u8, text, " \t\r\n");
            if (url.len > 0) got[i] = url;
        };
        if ((got[0] != null or started.children[0] == null) and (got[1] != null or started.children[1] == null)) break;
        io.sleep(.fromMilliseconds(20), .awake) catch break;
    }
    try writeEnv(io, ws, got[0], got[1]);
    return started;
}

/// `.mnml/env/dev.env` — the request files' variables.
pub fn writeEnv(io: Io, ws: []const u8, jira: ?[]const u8, bitbucket: ?[]const u8) !void {
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("# mnml --demo: the offline servers it started, rewritten every launch.\n");
    if (jira) |u| try w.print("jira={s}\n", .{u});
    if (bitbucket) |u| try w.print("bitbucket={s}\n", .{u});
    try w.print("# @secret jira_basic\njira_basic={s}\n", .{jira_basic});
    try w.print("# @secret bitbucket_basic\nbitbucket_basic={s}\n", .{bitbucket_basic});
    try write(io, ws, ".mnml/env/dev.env", w.buffered());
}

// ─── the whole of it ─────────────────────────────────────────────────────

pub const Setup = struct {
    /// The first frame's toast. Owned.
    note: []u8,
    fakes: Fakes,
};

/// Everything `--demo` does after the re-exec, in the process that owns
/// the sandbox. Null when this is not that process (no `MNML_DEMO`, or
/// a nested mnml inheriting it — the sandbox's owner check).
pub fn setup(gpa: Allocator, io: Io, env: *const Map, exe_dir: ?[]const u8) !?Setup {
    const ws = workspaceOf(env) orelse return null;
    const root = @import("sandbox.zig").owned(env, getpid()) orelse return null;
    const data_root = try data_root_mod.dataRoot(gpa, io, .{ .vars = env, .exe_dir = exe_dir });
    defer gpa.free(data_root);
    const places: Places = .{
        .exe_dir = exe_dir,
        .host_data_root = if (env.get(host_data_root_env)) |v| (if (v.len > 0) v else null) else null,
    };
    var missing: Missing = .{ .places = places };
    missing.git = !(try seedWorkspace(gpa, io, env, ws, root));
    try seedHome(io, root, data_root);
    try plantSessions(gpa, io, root, ws);
    missing.integrations = !(try installIntegrations(gpa, io, env, places, data_root));
    const started = try startFakes(gpa, io, env, root, ws, places);
    missing.fakes = started.running() < fakes.len;
    if (started.running() == 0) try writeEnv(io, ws, null, null);
    return .{ .note = try missing.note(gpa), .fakes = started };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "demo: the re-exec's variables: the workspace, the shims first on PATH, the fakes' URL files and tokens, no update check, no browser, a private agents group" {
    // `--demo` rides on `--sandbox`, which Windows has not got; the paths
    // this test spells with `/` would not match a Windows re-exec anyway.
    if (comptime !supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "/tmp/mnml-sandbox-abcdefgh";
    const set = try extraSet(arena, root, "/usr/bin:/bin", "/home/u/.config/mnml");
    var env: Map = .init(t.allocator);
    defer env.deinit();
    for (set) |kv| try env.put(kv[0], kv[1]);
    try t.expectEqualStrings(root ++ "/tour", workspaceOf(&env).?);
    try t.expectEqualStrings("/home/u/.config/mnml", env.get(host_data_root_env).?);
    try t.expectEqualStrings(root ++ "/demo/bin:/usr/bin:/bin", env.get("PATH").?);
    try t.expectEqualStrings("@" ++ root ++ "/demo/jira.url", env.get("JIRA_BASE_URL").?);
    try t.expectEqualStrings("@" ++ root ++ "/demo/bb.url", env.get("BITBUCKET_BASE_URL").?);
    try t.expectEqualStrings(jira_token, env.get("JIRA_API_TOKEN").?);
    try t.expectEqualStrings(bitbucket_token, env.get("BITBUCKET_API_TOKEN").?);
    // Jira's linked pull requests read this name: the fake's token, not a gap.
    try t.expectEqualStrings(bitbucket_token, env.get("BITBUCKET_ACCESS_TOKEN").?);
    try t.expectEqualStrings("1", env.get("MNML_NO_UPDATE_CHECK").?);
    try t.expectEqualStrings("none", env.get("MNML_OPEN_URL").?);
    try t.expectEqualStrings(agents_pgid, env.get("MNML_AGENTS_PGID").?);
    // No PATH at all: the shims are the whole of it.
    const bare = try extraSet(arena, root, null, null);
    try t.expectEqualStrings(root ++ "/demo/bin", bare[1][1]);
    for (bare) |kv| try t.expect(!std.mem.eql(u8, kv[0], host_data_root_env));
    try t.expect(wanted(&.{ "mnml-zig", "--demo" }));
    try t.expect(!wanted(&.{ "mnml-zig", "--sandbox" }));
    // The keys that would reach a real account are dropped.
    for ([_][]const u8{ "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "BITBUCKET_ACCESS_TOKEN" }) |k| {
        var found = false;
        for (unset) |u| found = found or std.mem.eql(u8, u, k);
        try t.expect(found);
    }
}

fn gitAvailable() bool {
    const r = std.process.run(t.allocator, t.io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    t.allocator.free(r.stdout);
    t.allocator.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

fn gitOut(arena: Allocator, ws: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try arena.alloc([]const u8, args.len + 3);
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = ws;
    @memcpy(argv[3..], args);
    const r = try std.process.run(arena, t.io, .{ .argv = argv });
    return r.stdout;
}

test "demo: the seed: the fixture's files, the tour's commits then the demo's, an open branch, a dirty tree; the home's config, init.lua, integration configs and shims; three transcripts" {
    if (comptime !supported) return error.SkipZigTest;
    if (!gitAvailable()) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try arena.dupe(u8, buf[0..n]);
    const ws = try std.fs.path.join(arena, &.{ root, workspace_name });
    const dr = try std.fs.path.join(arena, &.{ root, "xdg", "mnml" });
    var env: Map = .init(t.allocator);
    defer env.deinit();
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));

    try t.expect(try seedWorkspace(t.allocator, t.io, &env, ws, root));
    try seedHome(t.io, root, dr);
    try plantSessions(t.allocator, t.io, root, ws);

    // Files.
    for ([_][]const u8{ "README.md", ".gitignore", "src/main.zig", "src/util.zig", "docs/notes.md", "CHANGELOG.md", "requests/jira.http", "requests/bitbucket.http", ".mnml/config.zon", ".mnml/notes/release.md", ".mnml/findings/tour-clock.md" }) |rel| {
        const p = try std.fs.path.join(arena, &.{ ws, rel });
        try Io.Dir.cwd().access(t.io, p, .{});
    }
    const util = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ ws, "src/util.zig" }), arena, .limited(1 << 16));
    try t.expectEqualStrings(data.util_dirty, util);

    // History: the tour's five commits and merge, the demo's commit, in
    // order, with the fixed dates — so the hashes are the tour's.
    const log = try gitOut(arena, ws, &.{ "log", "--format=%s|%an", "main" });
    try t.expectEqualStrings(
        "Add request files for the offline Jira and Bitbucket|Sam Rivera\n" ++
            "Add a docs folder|Tour Author\n" ++
            "Merge feature/numbers|Tour Author\n" ++
            "Sum five numbers and mark the follow-ups|Tour Author\n" ++
            "Add util.sum with a test|Tour Author\n" ++
            "Start the tour project|Tour Author\n",
        log,
    );
    // The tour's own `main` tip, commit for commit (`tools/tour/workspace.py`).
    const tour_tip = try gitOut(arena, ws, &.{ "rev-parse", "main~1" });
    try t.expectEqualStrings("fb444d013001d568eb3204a2d0d77005f25c089c\n", tour_tip);
    const branch = try gitOut(arena, ws, &.{ "log", "--format=%s", "-1", "feature/cli-args" });
    try t.expectEqualStrings("Parse the numbers from the command line (WIP)\n", branch);
    const head = try gitOut(arena, ws, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    try t.expectEqualStrings("main\n", head);
    const status = try gitOut(arena, ws, &.{ "status", "--porcelain" });
    try t.expectEqualStrings(" M src/util.zig\n?? CHANGELOG.md\n", status);

    // The home: the first launch done, the first screen's script, the
    // integrations pointed at the fakes' fixed data, the shims runnable.
    const cfg = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ dr, "config.zon" }), arena, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, cfg, ".first_launch_complete = true") != null);
    const lua = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ dr, "init.lua" }), arena, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, lua, "ai.claude_code_new_right") != null);
    const jira = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ dr, "integrations/jira/config.zon" }), arena, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, jira, "fake@acme.com") != null);
    const bb = try Io.Dir.cwd().readFileAlloc(t.io, try std.fs.path.join(arena, &.{ dr, "integrations/bitbucket/config.zon" }), arena, .limited(1 << 16));
    try t.expect(std.mem.indexOf(u8, bb, ".workspace = \"acme\"") != null);
    for ([_][]const u8{ "claude", "codex" }) |s| {
        const st = try Io.Dir.cwd().statFile(t.io, try std.fs.path.join(arena, &.{ root, state_dir, "bin", s }), .{});
        try t.expect(st.permissions.toMode() & 0o111 != 0);
    }

    // Three transcripts, aged.
    const proj = try std.fs.path.join(arena, &.{ root, ".claude", "projects", try projectDirName(arena, ws) });
    const now_s = Io.Clock.real.now(t.io).toSeconds();
    for (planted) |p| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.jsonl", .{ proj, p.id });
        const text = try Io.Dir.cwd().readFileAlloc(t.io, path, arena, .limited(1 << 16));
        try t.expect(std.mem.indexOf(u8, text, p.ask) != null);
        const st = try Io.Dir.cwd().statFile(t.io, path, .{});
        const age = now_s - st.mtime.toSeconds();
        try t.expect(age >= p.age_min * 60 - 5 and age <= p.age_min * 60 + 60);
    }
}

test "demo: the shim on PATH: the re-exec's PATH finds the stand-in claude, which prints its exchange and writes a transcript" {
    if (comptime !supported) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try arena.dupe(u8, buf[0..n]);
    const dr = try std.fs.path.join(arena, &.{ root, "xdg", "mnml" });
    try seedHome(t.io, root, dr);
    const set = try extraSet(arena, root, "/usr/bin:/bin", null);
    var env: Map = .init(t.allocator);
    defer env.deinit();
    for (set) |kv| try env.put(kv[0], kv[1]);
    try env.put("HOME", root);
    // `command -v` through the demo's PATH: the stand-in, not a real one.
    const which = try std.process.run(arena, t.io, .{ .argv = &.{ "/bin/sh", "-c", "command -v claude; command -v codex" }, .environ_map = &env });
    try t.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/demo/bin/claude\n{s}/demo/bin/codex\n", .{ root, root }), which.stdout);
    // The stand-in's exchange, cut short before it idles as `claude`.
    const out = try std.process.run(arena, t.io, .{
        .argv = &.{ "/bin/sh", "-c", "claude --session-id 5e551001-0000-4000-8000-000000000001 > out 2>&1 & p=$!; i=0; while [ $i -lt 150 ] && ! grep -q 'Both tests pass' out; do sleep 0.1; i=$((i+1)); done; kill $p 2>/dev/null; wait $p 2>/dev/null; cat out" },
        .cwd = .{ .path = root },
        .environ_map = &env,
    });
    try t.expect(std.mem.indexOf(u8, out.stdout, "Both tests pass.") != null);
    try t.expect(std.mem.indexOf(u8, out.stdout, "no model runs") != null);
}

test "demo: the first toast names what was skipped, and only that, and where it looked" {
    const all = try (Missing{}).note(t.allocator);
    defer t.allocator.free(all);
    try t.expect(std.mem.startsWith(u8, all, "demo — "));
    try t.expect(std.mem.indexOf(u8, all, "are not in") == null);
    const some = try (Missing{ .fakes = true, .git = true, .places = .{ .exe_dir = "/opt/mnml" } }).note(t.allocator);
    defer t.allocator.free(some);
    try t.expect(std.mem.indexOf(u8, some, "mnml-fake-jira / mnml-fake-bitbucket are not in /opt/mnml,") != null);
    try t.expect(std.mem.indexOf(u8, some, "no `git`") != null);
    try t.expect(std.mem.indexOf(u8, some, "mnml-jira /") == null);
    const ints = try (Missing{ .integrations = true, .places = .{ .exe_dir = "/opt/mnml", .host_data_root = "/home/u/.config/mnml" } }).note(t.allocator);
    defer t.allocator.free(ints);
    try t.expect(std.mem.indexOf(u8, ints, "mnml-jira / mnml-bitbucket are not in /opt/mnml nor installed from the Marketplace in /home/u/.config/mnml, so their panes are not installed") != null);
}

fn touchExe(dir: []const u8, rel: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, rel });
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(t.io, d);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = "#!/bin/sh\n" });
}

test "demo: locate: beside the binary first, then the Marketplace's link, then the file it installed; the fakes only beside" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top = try arena.dupe(u8, buf[0..n]);
    const exe_dir = try std.fs.path.join(arena, &.{ top, "bin" });
    const host = try std.fs.path.join(arena, &.{ top, "data" });
    const places: Places = .{ .exe_dir = exe_dir, .host_data_root = host };
    var nb: [64]u8 = undefined;
    const jira = integrations[0];
    const file = exeName(&nb, jira.name);
    const beside_path = try std.fs.path.join(arena, &.{ exe_dir, file });
    const link_path = try std.fs.path.join(arena, &.{ host, "bin", file });
    const installed_path = try std.fs.path.join(arena, &.{ host, "integrations", "jira", "bin", file });

    // Nothing anywhere: not found.
    try t.expect(locate(arena, t.io, places, jira, true) == null);
    // Only the Marketplace's own install: found there.
    try touchExe(host, try std.fmt.allocPrint(arena, "integrations/jira/bin/{s}", .{file}));
    try sdk_testing.expectPath(installed_path, locate(arena, t.io, places, jira, true).?);
    // Its link in `<data root>/bin` comes before it.
    try touchExe(host, try std.fmt.allocPrint(arena, "bin/{s}", .{file}));
    try sdk_testing.expectPath(link_path, locate(arena, t.io, places, jira, true).?);
    // And beside the binary before both: a source build drives what it built.
    try touchExe(exe_dir, file);
    try sdk_testing.expectPath(beside_path, locate(arena, t.io, places, jira, true).?);
    // No host data root known: beside the binary is the only place.
    try t.expectEqual(@as(usize, 1), (try candidates(arena, .{ .exe_dir = exe_dir }, jira, true)).len);

    // A fake is never a Marketplace install: one in the data root is not used.
    const fake = fakes[0];
    const fake_file = exeName(&nb, fake.name);
    try touchExe(host, try std.fmt.allocPrint(arena, "bin/{s}", .{fake_file}));
    try t.expect(locate(arena, t.io, places, fake, false) == null);
    try touchExe(exe_dir, fake_file);
    try sdk_testing.expectPath(try std.fs.path.join(arena, &.{ exe_dir, fake_file }), locate(arena, t.io, places, fake, false).?);
}

test "demo: the env file: the fakes' URLs and the masked credential" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try writeEnv(t.io, buf[0..n], "http://127.0.0.1:1234", "http://127.0.0.1:5678/2.0");
    const text = try tmp.dir.readFileAlloc(t.io, ".mnml/env/dev.env", t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "jira=http://127.0.0.1:1234\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "bitbucket=http://127.0.0.1:5678/2.0\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "# @secret jira_basic\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "# @secret bitbucket_basic\n") != null);
}
