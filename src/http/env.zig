//! `{{VAR}}` resolution. An env is a named `KEY=VALUE` file:
//! `<ws>/.mnml/env/<name>.env` (mnml's own) over `<ws>/.rqst/env/<name>.env`
//! (the rqst-era location) — the `.mnml` value wins on a shared key, so
//! a workspace migrating over can override one key at a time. A name
//! that resolves to no file is an empty set, not an error.
//!
//! Which env is active: the explicit choice (`--env`, a session
//! override) → `$MNML_ENV` → `[http] default_env` in the config →
//! `.rqst/config`'s `default_env=`. Unresolved `{{FOO}}` stays verbatim
//! so it shows up in the failure; `{{$uuid}}` and friends are fresh per
//! expansion. Process env vars are the last fallback for a plain name.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const subdirs = [_][]const u8{ ".rqst", ".mnml" };
pub const fallback_name = "dev";

pub const EnvSet = struct {
    gpa: Allocator,
    /// Owned; null for the empty set.
    name: ?[]u8 = null,
    /// Owned keys and values.
    vars: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// The process environment, consulted after the file. Borrowed.
    process: ?*const std.process.Environ.Map = null,
    /// Names a `# @secret NAME …` line marked; a hover masks them.
    secrets: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn empty(gpa: Allocator) EnvSet {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EnvSet) void {
        if (self.name) |n| self.gpa.free(n);
        var it = self.vars.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.vars.deinit(self.gpa);
        for (self.secrets.keys()) |k| self.gpa.free(k);
        self.secrets.deinit(self.gpa);
    }

    /// Marked `# @secret`, or named like one (token / secret / password /
    /// key / auth) — the value is shown masked either way.
    pub fn isSecret(self: *const EnvSet, name: []const u8) bool {
        if (self.secrets.contains(name)) return true;
        return looksSecret(name);
    }

    /// Read `.rqst/env/<name>.env` then `.mnml/env/<name>.env`; the
    /// later file's value wins. Missing files are fine.
    pub fn load(gpa: Allocator, io: Io, workspace: []const u8, name: []const u8) Allocator.Error!EnvSet {
        var set: EnvSet = .{ .gpa = gpa, .name = try gpa.dupe(u8, name) };
        errdefer set.deinit();
        for (subdirs) |sub| {
            const path = try envPath(gpa, workspace, sub, name);
            defer gpa.free(path);
            const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(text);
            try set.mergeText(text);
        }
        return set;
    }

    /// Every `KEY=VALUE` line of `text`, later lines winning; a
    /// `# @secret A B` line marks names.
    pub fn mergeText(self: *EnvSet, text: []const u8) Allocator.Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, t, "#")) {
                const rest = std.mem.trimStart(u8, t[1..], " \t");
                if (std.mem.startsWith(u8, rest, "@secret")) {
                    var names = std.mem.tokenizeAny(u8, rest["@secret".len..], " \t,");
                    while (names.next()) |n| if (isValidName(n) and !self.secrets.contains(n)) {
                        const k = try self.gpa.dupe(u8, n);
                        errdefer self.gpa.free(k);
                        try self.secrets.put(self.gpa, k, {});
                    };
                }
                continue;
            }
            const kv = parseLine(line) orelse continue;
            try self.put(kv.key, kv.value);
        }
    }

    pub fn put(self: *EnvSet, key: []const u8, value: []const u8) Allocator.Error!void {
        const v = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(v);
        if (self.vars.getPtr(key)) |slot| {
            self.gpa.free(slot.*);
            slot.* = v;
            return;
        }
        const k = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(k);
        try self.vars.put(self.gpa, k, v);
    }

    pub fn get(self: *const EnvSet, key: []const u8) ?[]const u8 {
        if (self.vars.get(key)) |v| return v;
        if (self.process) |p| if (p.get(key)) |v| return v;
        return null;
    }
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };

/// A name that reads like a credential.
pub fn looksSecret(name: []const u8) bool {
    const marks = [_][]const u8{ "token", "secret", "password", "passwd", "api_key", "apikey", "auth", "private" };
    for (marks) |m| if (std.ascii.findIgnoreCase(name, m) != null) return true;
    return false;
}

/// `value` as a hover shows it: bullets for a secret.
pub fn masked(name: []const u8, value: []const u8, set: *const EnvSet) []const u8 {
    return if (set.isSecret(name)) "••••••••" else value;
}

/// The 0-based line of `KEY=` in an env file's text, if defined.
pub fn lineOfKey(text: []const u8, key: []const u8) ?usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (n += 1) {
        const kv = parseLine(line) orelse continue;
        if (std.mem.eql(u8, kv.key, key)) return n;
    }
    return null;
}

/// `KEY=VALUE`, `export KEY=VALUE`, quotes stripped, `#` lines and
/// blanks skipped. A trailing ` # comment` after an unquoted value is
/// dropped.
pub fn parseLine(raw: []const u8) ?KeyValue {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    if (key.len == 0 or !isValidName(key)) return null;
    var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        value = value[1 .. value.len - 1];
    } else if (quotedThenComment(value)) |inner| {
        // `KEY="v w" # note`: the quotes close before the comment.
        value = inner;
    } else if (std.mem.indexOf(u8, value, " #")) |c| {
        value = std.mem.trimEnd(u8, value[0..c], " \t");
    }
    return .{ .key = key, .value = value };
}

/// The inside of `"…" # comment` / `'…' # comment`: a quoted value whose
/// closing quote is followed only by blanks and a `#` comment.
fn quotedThenComment(value: []const u8) ?[]const u8 {
    if (value.len < 2 or (value[0] != '"' and value[0] != '\'')) return null;
    const close = std.mem.indexOfScalarPos(u8, value, 1, value[0]) orelse return null;
    const rest = std.mem.trimStart(u8, value[close + 1 ..], " \t");
    if (rest.len == 0 or rest[0] != '#') return null;
    if (close + 1 < value.len and value[close + 1] != ' ' and value[close + 1] != '\t') return null;
    return value[1..close];
}

pub fn isValidName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub fn envPath(alloc: Allocator, workspace: []const u8, sub: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/env/{s}.env", .{ workspace, sub, name });
}

// ─── which env ─────────────────────────────────────────────────────────

pub const Selection = struct {
    /// Borrowed from whichever source chose it (or `fallback_name`).
    name: []const u8,
    /// No source named one; `fallback_name` stands in.
    is_fallback: bool,
};

/// explicit → `$MNML_ENV` → the config default → `.rqst/config` →
/// `dev`. The result borrows `arena` when it came off disk.
pub fn select(arena: Allocator, io: Io, workspace: []const u8, explicit: ?[]const u8, env_var: ?[]const u8, config_default: ?[]const u8) Allocator.Error!Selection {
    if (explicit) |e| if (e.len > 0) return .{ .name = e, .is_fallback = false };
    if (env_var) |e| if (e.len > 0) return .{ .name = e, .is_fallback = false };
    if (config_default) |c| if (c.len > 0) return .{ .name = c, .is_fallback = false };
    if (try rqstConfigDefault(arena, io, workspace)) |n| return .{ .name = n, .is_fallback = false };
    return .{ .name = fallback_name, .is_fallback = true };
}

/// Whether `<ws>/.mnml/env/<name>.env` or `<ws>/.rqst/env/<name>.env`
/// is on disk — an env is a file, not a name.
pub fn exists(io: Io, workspace: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (subdirs) |sub| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}/env/{s}.env", .{ workspace, sub, name }) catch continue;
        _ = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        return true;
    }
    return false;
}

/// `select` over the envs that exist: each source in `select`'s order
/// is skipped when its file is gone (a `default_env` naming a deleted
/// env, a session pick whose file was removed), and `dev` stands in
/// only when `dev.env` is there. Null when none is — the workspace has
/// no env, and nothing claims one.
pub fn selectExisting(arena: Allocator, io: Io, workspace: []const u8, explicit: ?[]const u8, env_var: ?[]const u8, config_default: ?[]const u8) Allocator.Error!?Selection {
    const rqst = try rqstConfigDefault(arena, io, workspace);
    for ([_]?[]const u8{ explicit, env_var, config_default, rqst }) |c| {
        const n = c orelse continue;
        if (n.len > 0 and exists(io, workspace, n)) return .{ .name = n, .is_fallback = false };
    }
    if (exists(io, workspace, fallback_name)) return .{ .name = fallback_name, .is_fallback = true };
    return null;
}

/// The one sentence for `{{NAME}}`s no env defines — the request
/// pane's refusal and `mnml run` / `chain run`'s warning say it alike.
/// `env_name` null: no env file exists (or none is selected).
pub fn unresolvedMessage(alloc: Allocator, names: []const []const u8, env_name: ?[]const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "unresolved");
    for (names) |n| try out.print(alloc, " {{{{{s}}}}}", .{n});
    const them = names.len > 1;
    if (env_name) |e| {
        try out.print(alloc, " \u{2014} not defined in env {s}; add {s} to .mnml/env/{s}.env or pick an env", .{ e, if (them) "them" else "it", e });
    } else {
        try out.print(alloc, " \u{2014} no env defines {s}; add {s} to .mnml/env/<env>.env or pick an env", .{ if (them) "them" else "it", if (them) "them" else "it" });
    }
    return out.toOwnedSlice(alloc);
}

/// `default_env=<name>` from `<ws>/.rqst/config` (rqst's KEY=VALUE file).
pub fn rqstConfigDefault(arena: Allocator, io: Io, workspace: []const u8) Allocator.Error!?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ workspace, ".rqst", "config" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, t[0..eq], " \t"), "default_env")) {
            const v = std.mem.trim(u8, t[eq + 1 ..], " \t");
            if (v.len > 0) return v;
        }
    }
    return null;
}

/// Every `<stem>` of a `<stem>.env` under either env dir, `.mnml` first,
/// deduplicated, in directory order.
pub fn listNames(arena: Allocator, io: Io, workspace: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for ([_][]const u8{ ".mnml", ".rqst" }) |sub| {
        const dir_path = try std.fs.path.join(arena, &.{ workspace, sub, "env" });
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".env")) continue;
            const stem = entry.name[0 .. entry.name.len - ".env".len];
            if (stem.len == 0) continue;
            var seen = false;
            for (out.items) |o| if (std.mem.eql(u8, o, stem)) {
                seen = true;
                break;
            };
            if (!seen) try out.append(arena, try arena.dupe(u8, stem));
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

// ─── live reload ────────────────────────────────────────────────────────

/// A stamp of the env files as they sit on disk: the active name's two
/// files and every `.mnml/env/*.env` (name, mtime, size), so a poll on
/// the tick can tell an edit, a new file or a removed one from nothing
/// at all. Missing files stamp as missing.
pub fn digest(io: Io, workspace: []const u8, name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (subdirs) |sub| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}/env/{s}.env", .{ workspace, sub, name }) catch continue;
        h.update(path);
        stampInto(&h, Io.Dir.cwd(), io, path);
    }
    const dir_path = std.fmt.bufPrint(&buf, "{s}/.mnml/env", .{workspace}) catch return h.final();
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return h.final();
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".env")) continue;
        h.update(entry.name);
        stampInto(&h, dir, io, entry.name);
    }
    return h.final();
}

fn stampInto(h: *std.hash.Wyhash, dir: Io.Dir, io: Io, path: []const u8) void {
    const st = dir.statFile(io, path, .{}) catch {
        h.update("missing");
        return;
    };
    const ns: i128 = st.mtime.toNanoseconds();
    const size: u64 = st.size;
    h.update(std.mem.asBytes(&ns));
    h.update(std.mem.asBytes(&size));
}

// ─── writing ────────────────────────────────────────────────────────────

pub const Upsert = struct {
    /// Absolute, owned by the caller's allocator.
    path: []u8,
    replaced: bool,
};

/// Write `KEY=VALUE` into the env file that already holds the key
/// (`.mnml` checked first), else append to `.mnml/env/<name>.env`,
/// creating it. Newlines in the value are refused.
pub fn upsert(gpa: Allocator, io: Io, workspace: []const u8, name: []const u8, key: []const u8, value: []const u8) !Upsert {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidValue;
    if (!isValidName(key)) return error.InvalidKey;
    for ([_][]const u8{ ".mnml", ".rqst" }) |sub| {
        const path = try envPath(gpa, workspace, sub, name);
        errdefer gpa.free(path);
        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            gpa.free(path);
            continue;
        };
        defer gpa.free(text);
        if (try replaceKey(gpa, text, key, value)) |fresh| {
            defer gpa.free(fresh);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = fresh });
            return .{ .path = path, .replaced = true };
        }
        gpa.free(path);
    }
    const path = try envPath(gpa, workspace, ".mnml", name);
    errdefer gpa.free(path);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const existing = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch try gpa.dupe(u8, "");
    defer gpa.free(existing);
    const nl: []const u8 = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
    const fresh = try std.mem.concat(gpa, u8, &.{ existing, nl, key, "=", value, "\n" });
    defer gpa.free(fresh);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = fresh });
    return .{ .path = path, .replaced = false };
}

/// `text` with the line defining `key` rewritten; null when no line does.
fn replaceKey(gpa: Allocator, text: []const u8, key: []const u8, value: []const u8) Allocator.Error!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (parseLine(line)) |kv| if (std.mem.eql(u8, kv.key, key)) {
            found = true;
            try out.appendSlice(gpa, key);
            try out.append(gpa, '=');
            try out.appendSlice(gpa, value);
            continue;
        };
        try out.appendSlice(gpa, line);
    }
    if (!found) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// Drop the line defining `key` from whichever env file holds it.
pub fn deleteKey(gpa: Allocator, io: Io, workspace: []const u8, name: []const u8, key: []const u8) !bool {
    var any = false;
    for ([_][]const u8{ ".mnml", ".rqst" }) |sub| {
        const path = try envPath(gpa, workspace, sub, name);
        defer gpa.free(path);
        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(text);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        var found = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (parseLine(line)) |kv| if (std.mem.eql(u8, kv.key, key)) {
                found = true;
                continue;
            };
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
        if (!found) continue;
        // The split leaves a trailing empty line; keep one newline.
        while (std.mem.endsWith(u8, out.items, "\n\n")) _ = out.pop();
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
        any = true;
    }
    return any;
}

// ─── expansion ──────────────────────────────────────────────────────────

/// How deep a value may name another value (`BASE=http://{{HOST}}`,
/// `HOST={{IP}}:80`, …). Past it — or in a cycle — the inner `{{…}}`
/// stays as written, and `unresolved` names it.
pub const max_depth = 8;

/// Replace every `{{NAME}}` / `{{ NAME }}` / `{{$dynamic}}` in `text`.
/// A value that itself holds `{{…}}` is expanded too, `max_depth`
/// levels down. Unknown names stay as written.
pub fn expand(alloc: Allocator, io: Io, text: []const u8, env: *const EnvSet) Allocator.Error![]u8 {
    return expandDepth(alloc, io, text, env, 0);
}

fn expandDepth(alloc: Allocator, io: Io, text: []const u8, env: *const EnvSet, depth: usize) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "{{")) {
            if (std.mem.indexOf(u8, text[i + 2 ..], "}}")) |close| {
                const raw = text[i + 2 .. i + 2 + close];
                const name = std.mem.trim(u8, raw, " \t");
                if (try resolve(alloc, io, name, env)) |v| {
                    defer if (v.owned) alloc.free(v.text);
                    // A dynamic's text is final; an env value may name
                    // another.
                    if (!v.owned and depth < max_depth and std.mem.indexOf(u8, v.text, "{{") != null) {
                        const inner = try expandDepth(alloc, io, v.text, env, depth + 1);
                        defer alloc.free(inner);
                        try out.appendSlice(alloc, inner);
                    } else try out.appendSlice(alloc, v.text);
                    i += 2 + close + 2;
                    continue;
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Names in `text` that `env` cannot resolve, in order, deduplicated —
/// the ones a resolved value names included (`BASE=http://{{HOST}}`
/// with no `HOST` reports `HOST`), and a name still standing at
/// `max_depth` (a cycle).
pub fn unresolved(arena: Allocator, text: []const u8, env: *const EnvSet) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    try unresolvedInto(arena, text, env, &out, 0);
    return out.items;
}

fn unresolvedInto(arena: Allocator, text: []const u8, env: *const EnvSet, out: *std.ArrayListUnmanaged([]const u8), depth: usize) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "{{")) {
            if (std.mem.indexOf(u8, text[i + 2 ..], "}}")) |close| {
                const name = std.mem.trim(u8, text[i + 2 .. i + 2 + close], " \t");
                i += 2 + close + 2;
                if (name.len > 0 and name[0] == '$') continue;
                if (!isValidName(name)) continue;
                if (env.get(name)) |v| {
                    if (depth < max_depth) {
                        try unresolvedInto(arena, v, env, out, depth + 1);
                        continue;
                    }
                    if (std.mem.indexOf(u8, v, "{{") == null) continue;
                }
                var seen = false;
                for (out.items) |o| if (std.mem.eql(u8, o, name)) {
                    seen = true;
                    break;
                };
                if (!seen) try out.append(arena, name);
                continue;
            }
        }
        i += 1;
    }
}

/// Every `{{…}}` token's byte range in `text`, for highlighting.
pub const Token = struct { start: usize, end: usize, name: []const u8 };

pub fn tokens(arena: Allocator, text: []const u8) Allocator.Error![]Token {
    var out: std.ArrayListUnmanaged(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "{{")) {
            if (std.mem.indexOf(u8, text[i + 2 ..], "}}")) |close| {
                const end = i + 2 + close + 2;
                try out.append(arena, .{ .start = i, .end = end, .name = std.mem.trim(u8, text[i + 2 .. i + 2 + close], " \t") });
                i = end;
                continue;
            }
        }
        i += 1;
    }
    return out.items;
}

const Resolved = struct { text: []const u8, owned: bool };

fn resolve(alloc: Allocator, io: Io, name: []const u8, env: *const EnvSet) Allocator.Error!?Resolved {
    if (name.len > 0 and name[0] == '$') {
        const v = (try dynamicVar(alloc, io, name[1..])) orelse return null;
        return .{ .text = v, .owned = true };
    }
    if (!isValidName(name)) return null;
    const v = env.get(name) orelse return null;
    return .{ .text = v, .owned = false };
}

/// `$uuid` / `$guid`, `$timestamp` (seconds), `$epochMs`, `$isoTimestamp`,
/// `$randomInt`, `$date` (YYYY-MM-DD). Fresh per call.
pub fn dynamicVar(alloc: Allocator, io: Io, name: []const u8) Allocator.Error!?[]u8 {
    const now_ns: i128 = @intCast(Io.Timestamp.now(io, .real).toNanoseconds());
    const now_ms: i64 = @intCast(@divFloor(now_ns, std.time.ns_per_ms));
    const now_s: i64 = @divFloor(now_ms, 1000);
    if (std.mem.eql(u8, name, "uuid") or std.mem.eql(u8, name, "guid")) {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        return try std.fmt.allocPrint(alloc, "{x}-{x}-{x}-{x}-{x}", .{ bytes[0..4], bytes[4..6], bytes[6..8], bytes[8..10], bytes[10..16] });
    }
    if (std.mem.eql(u8, name, "timestamp")) return try std.fmt.allocPrint(alloc, "{d}", .{now_s});
    if (std.mem.eql(u8, name, "epochMs") or std.mem.eql(u8, name, "epoch_ms")) return try std.fmt.allocPrint(alloc, "{d}", .{now_ms});
    if (std.mem.eql(u8, name, "randomInt") or std.mem.eql(u8, name, "random_int")) return try std.fmt.allocPrint(alloc, "{d}", .{randomBelow(io, 1001)});
    if (std.mem.eql(u8, name, "isoTimestamp") or std.mem.eql(u8, name, "iso_timestamp") or std.mem.eql(u8, name, "date")) {
        const civil = civilFromUnix(now_s);
        const year: u32 = @intCast(@max(civil.year, 0));
        if (std.mem.eql(u8, name, "date")) return try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, civil.month, civil.day });
        const ms: u64 = @intCast(@mod(now_ms, 1000));
        return try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ year, civil.month, civil.day, civil.hour, civil.minute, civil.second, ms });
    }
    return null;
}

fn randomBelow(io: Io, n: u32) u32 {
    var b: [4]u8 = undefined;
    io.random(&b);
    return std.mem.readInt(u32, &b, .little) % n;
}

pub const Civil = struct { year: i64, month: u32, day: u32, hour: u32, minute: u32, second: u32 };

/// Proleptic Gregorian, UTC (Howard Hinnant's days-from-civil inverse).
pub fn civilFromUnix(secs: i64) Civil {
    const days = @divFloor(secs, 86_400);
    const rem: u32 = @intCast(@mod(secs, 86_400));
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: i64 = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d, .hour = rem / 3600, .minute = (rem % 3600) / 60, .second = rem % 60 };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseLine: quotes, export, comments, invalid keys" {
    try testing.expectEqualStrings("v w", parseLine("K=\"v w\"").?.value);
    try testing.expectEqualStrings("v", parseLine("export K='v'").?.value);
    try testing.expectEqualStrings("v", parseLine("K=v # note").?.value);
    // Quoted AND commented: the quotes close before the comment.
    try testing.expectEqualStrings("hello world", parseLine("GREETING=\"hello world\" # shown to users").?.value);
    try testing.expectEqualStrings("a # b", parseLine("K='a # b'   # note").?.value);
    // A `#` inside the quotes, no comment after, is the value's own.
    try testing.expectEqualStrings("a # b", parseLine("K=\"a # b\"").?.value);
    try testing.expect(parseLine("# K=v") == null);
    try testing.expect(parseLine("bad key=v") == null);
    try testing.expect(parseLine("") == null);
}

test "expand substitutes known names, leaves unknown, resolves dynamics; unresolved lists" {
    var env = EnvSet.empty(testing.allocator);
    defer env.deinit();
    try env.put("BASE", "https://x");
    try env.put("TOKEN", "t1");
    const out = try expand(testing.allocator, testing.io, "{{BASE}}/a?t={{ TOKEN }}&m={{MISSING}}&u={{$uuid}}", &env);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "https://x/a?t=t1&m={{MISSING}}&u="));
    const uuid = out[std.mem.indexOf(u8, out, "&u=").? + 3 ..];
    try testing.expectEqual(@as(usize, 36), uuid.len);
    try testing.expectEqual(@as(u8, '4'), uuid[14]);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const miss = try unresolved(arena.allocator(), "{{A}} {{B}} {{A}} {{$ts}} {{BASE}}", &env);
    try testing.expectEqual(@as(usize, 2), miss.len);
    try testing.expectEqualStrings("A", miss[0]);
    try testing.expectEqualStrings("B", miss[1]);
    // A value naming another expands too; a missing inner name is reported.
    try env.put("HOST", "127.0.0.1:9");
    try env.put("NESTED", "http://{{HOST}}");
    try env.put("DEEP", "{{NESTED}}/v1");
    try env.put("HALF", "http://{{NOPE}}");
    const nested = try expand(testing.allocator, testing.io, "X-Base: {{DEEP}}", &env);
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("X-Base: http://127.0.0.1:9/v1", nested);
    const half = try unresolved(arena.allocator(), "{{HALF}}", &env);
    try testing.expectEqual(@as(usize, 1), half.len);
    try testing.expectEqualStrings("NOPE", half[0]);
    // A cycle stops at the depth cap and is named, never a hang.
    try env.put("LOOP_A", "a{{LOOP_B}}");
    try env.put("LOOP_B", "b{{LOOP_A}}");
    const loop = try expand(testing.allocator, testing.io, "{{LOOP_A}}", &env);
    defer testing.allocator.free(loop);
    try testing.expect(std.mem.indexOf(u8, loop, "{{LOOP_") != null);
    try testing.expect((try unresolved(arena.allocator(), "{{LOOP_A}}", &env)).len == 1);
    const ts = (try dynamicVar(testing.allocator, testing.io, "isoTimestamp")).?;
    defer testing.allocator.free(ts);
    try testing.expectEqual(@as(usize, 24), ts.len);
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    const toks = try tokens(arena.allocator(), "a{{X}}b{{ Y }}");
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqualStrings("Y", toks[1].name);
}

test "civilFromUnix matches known dates" {
    const c = civilFromUnix(1_700_000_000); // 2023-11-14T22:13:20Z
    try testing.expectEqual(@as(i64, 2023), c.year);
    try testing.expectEqual(@as(u32, 11), c.month);
    try testing.expectEqual(@as(u32, 14), c.day);
    try testing.expectEqual(@as(u32, 22), c.hour);
    try testing.expectEqual(@as(u32, 13), c.minute);
    try testing.expectEqual(@as(u32, 20), c.second);
    const epoch = civilFromUnix(0);
    try testing.expectEqual(@as(i64, 1970), epoch.year);
    try testing.expectEqual(@as(u32, 1), epoch.month);
}

test "load: .mnml overrides .rqst on the same key; select precedence; upsert writes to the owning file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    try tmp.dir.createDirPath(testing.io, ".rqst/env");
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".rqst/config", .data = "default_env=dev\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".rqst/env/dev.env", .data = "BASE_URL=https://rqst.example.com\nONLY_RQST=1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "BASE_URL=https://mnml.example.com\n" });
    var env = try EnvSet.load(testing.allocator, testing.io, ws, "dev");
    defer env.deinit();
    try testing.expectEqualStrings("https://mnml.example.com", env.get("BASE_URL").?);
    try testing.expectEqualStrings("1", env.get("ONLY_RQST").?);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("dev", (try select(a, testing.io, ws, null, null, null)).name);
    try testing.expectEqualStrings("cfg", (try select(a, testing.io, ws, null, null, "cfg")).name);
    try testing.expectEqualStrings("envv", (try select(a, testing.io, ws, null, "envv", "cfg")).name);
    try testing.expectEqualStrings("ex", (try select(a, testing.io, ws, "ex", "envv", "cfg")).name);
    const names = try listNames(a, testing.io, ws);
    try testing.expectEqual(@as(usize, 1), names.len);

    // ONLY_RQST lives in .rqst: the write lands there. A new key goes to .mnml.
    const up1 = try upsert(testing.allocator, testing.io, ws, "dev", "ONLY_RQST", "2");
    defer testing.allocator.free(up1.path);
    try testing.expect(up1.replaced);
    try testing.expect(std.mem.indexOf(u8, up1.path, ".rqst/env/dev.env") != null);
    const up2 = try upsert(testing.allocator, testing.io, ws, "dev", "MY_KEY", "myvalue");
    defer testing.allocator.free(up2.path);
    try testing.expect(!up2.replaced);
    const mnml = try tmp.dir.readFileAlloc(testing.io, ".mnml/env/dev.env", testing.allocator, .limited(4096));
    defer testing.allocator.free(mnml);
    try testing.expectEqualStrings("BASE_URL=https://mnml.example.com\nMY_KEY=myvalue\n", mnml);
    const rqst = try tmp.dir.readFileAlloc(testing.io, ".rqst/env/dev.env", testing.allocator, .limited(4096));
    defer testing.allocator.free(rqst);
    try testing.expectEqualStrings("BASE_URL=https://rqst.example.com\nONLY_RQST=2\n", rqst);
    try testing.expectError(error.InvalidValue, upsert(testing.allocator, testing.io, ws, "dev", "K", "a\nb"));
    try testing.expect(try deleteKey(testing.allocator, testing.io, ws, "dev", "MY_KEY"));
    const after = try tmp.dir.readFileAlloc(testing.io, ".mnml/env/dev.env", testing.allocator, .limited(4096));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("BASE_URL=https://mnml.example.com\n", after);
    // A fresh workspace without an env dir: the new file and its dirs are created.
    const up3 = try upsert(testing.allocator, testing.io, ws, "prod", "A", "1");
    defer testing.allocator.free(up3.path);
    const prod = try tmp.dir.readFileAlloc(testing.io, ".mnml/env/prod.env", testing.allocator, .limited(4096));
    defer testing.allocator.free(prod);
    try testing.expectEqualStrings("A=1\n", prod);
}

test "@secret marks names, credential-shaped names mask on their own, lineOfKey finds the definition" {
    var set = EnvSet.empty(testing.allocator);
    defer set.deinit();
    const text = "HOST=a\n# @secret PIN, CODE\nPIN=1\nCODE=2\nAPI_TOKEN=t\n# X=9\n";
    try set.mergeText(text);
    try testing.expect(set.isSecret("PIN"));
    try testing.expect(set.isSecret("CODE"));
    try testing.expect(set.isSecret("API_TOKEN"));
    try testing.expect(!set.isSecret("HOST"));
    try testing.expect(looksSecret("my_password") and looksSecret("ApiKey") and !looksSecret("HOST"));
    try testing.expectEqualStrings("••••••••", masked("PIN", "1", &set));
    try testing.expectEqualStrings("a", masked("HOST", "a", &set));
    try testing.expectEqual(@as(?usize, 3), lineOfKey(text, "CODE"));
    try testing.expectEqual(@as(?usize, 0), lineOfKey(text, "HOST"));
    try testing.expect(lineOfKey(text, "NOPE") == null);
    // A commented-out key is not a definition.
    try testing.expect(lineOfKey(text, "X") == null);
    // The marker survives a second merge and does not duplicate.
    try set.mergeText("# @secret PIN\n");
    try testing.expectEqual(@as(usize, 2), set.secrets.count());
}

test "digest: an edit, a new file and a removed one each move the stamp; a missing name is a stable stamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    const d0 = digest(testing.io, ws, "dev");
    try testing.expectEqual(d0, digest(testing.io, ws, "dev"));
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "A=1\n" });
    const d1 = digest(testing.io, ws, "dev");
    try testing.expect(d1 != d0);
    try testing.expectEqual(d1, digest(testing.io, ws, "dev"));
    // The edit: the size moves whatever the mtime granularity.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "A=12\n" });
    const d2 = digest(testing.io, ws, "dev");
    try testing.expect(d2 != d1);
    // Another env file appears: the ENVS list changes too.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/prod.env", .data = "A=9\n" });
    const d3 = digest(testing.io, ws, "dev");
    try testing.expect(d3 != d2);
    try tmp.dir.deleteFile(testing.io, ".mnml/env/prod.env");
    try testing.expectEqual(d2, digest(testing.io, ws, "dev"));
}

test "selectExisting: a source whose file is gone is skipped; no env file means no env" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Nothing on disk: `select` still answers `dev`; this does not.
    try testing.expectEqualStrings("dev", (try select(a, testing.io, ws, null, null, null)).name);
    try testing.expect((try selectExisting(a, testing.io, ws, null, null, null)) == null);
    try testing.expect((try selectExisting(a, testing.io, ws, "prod", "ci", "staging")) == null);
    try testing.expect(!exists(testing.io, ws, "dev"));
    // A persisted `default_env=staging` whose file is gone falls to the
    // one that is there.
    try tmp.dir.createDirPath(testing.io, ".rqst");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".rqst/config", .data = "default_env=staging\n" });
    try tmp.dir.createDirPath(testing.io, ".rqst/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".rqst/env/prod.env", .data = "A=1\n" });
    try testing.expect(exists(testing.io, ws, "prod"));
    try testing.expect((try selectExisting(a, testing.io, ws, null, null, null)) == null);
    try testing.expectEqualStrings("prod", (try selectExisting(a, testing.io, ws, "gone", null, "prod")).?.name);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = "A=2\n" });
    const dev = (try selectExisting(a, testing.io, ws, "gone", null, null)).?;
    try testing.expectEqualStrings("dev", dev.name);
    try testing.expect(dev.is_fallback);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/staging.env", .data = "A=3\n" });
    try testing.expectEqualStrings("staging", (try selectExisting(a, testing.io, ws, null, null, null)).?.name);
}

test "unresolvedMessage names every miss and where to define it" {
    const one = try unresolvedMessage(testing.allocator, &.{"jira"}, null);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("unresolved {{jira}} \u{2014} no env defines it; add it to .mnml/env/<env>.env or pick an env", one);
    const two = try unresolvedMessage(testing.allocator, &.{ "A", "B" }, "dev");
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("unresolved {{A}} {{B}} \u{2014} not defined in env dev; add them to .mnml/env/dev.env or pick an env", two);
}
