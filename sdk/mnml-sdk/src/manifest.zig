//! The integration manifest — what `<integration> --install` writes to
//! `<data root>/integrations/<id>.zon` and what mnml reads at startup
//! and on `integrations.refresh`. Uninstall is deleting the file; the
//! filesystem is the interface.
//!
//! `Manifest` is the ZON schema on both sides: the SDK serialises it
//! with `std.zon.stringify`, mnml parses it with `std.zon.parse`. Only
//! `id` and `label` are required; the rest default. A manifest without
//! a `binary` is a *launcher*: it has no program of its own, and every
//! command carries a `run` line — an ex line, usually `:term <tool>` —
//! that mnml expands (`{{workspace}}`, `{{current_file}}`, …) and runs.
//! `validate` is the one rule both readers apply: a manifest needs a
//! binary or a runnable command, and a launcher's commands all need one.
//!
//! The data root is mnml's: `$MNML_DATA_ROOT`, else
//! `$XDG_CONFIG_HOME/mnml`, else `$HOME/.config/mnml`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How the binary opens when a command has no `ex` line: hosted over
/// the mount socket, or as a plain terminal pane.
pub const Mode = enum { mount, pty };

/// The rail / palette-bar chip. Display strings live on the manifest;
/// the chip is about rendering.
pub const Chip = struct {
    /// A Nerd Font glyph (or any short string). Wins over `glyph_codepoint`.
    glyph: []const u8 = "",
    /// A codepoint in hex (`F1D00`, `U+F1D00`) painted verbatim when
    /// `glyph` is empty — for a glyph baked into mnml's own font block
    /// (U+F1B00–U+F20FF) rather than a Nerd Font one. `glyphText` reads
    /// the two together.
    glyph_codepoint: []const u8 = "",
    /// What paints when the glyph cannot: 1–3 plain characters.
    fallback: []const u8 = "",
    /// A theme colour name: red, orange, yellow, green, blue, cyan,
    /// teal, purple, pink, magenta, comment, fg. Unknown → the accent.
    color: []const u8 = "",
    tooltip: []const u8 = "",
    enabled: bool = true,
    in_palette_bar: bool = true,

    /// The glyph to paint: `glyph`, else `glyph_codepoint` decoded into
    /// `buf` (a `U+` / `0x` prefix is allowed), else empty.
    pub fn glyphText(c: Chip, buf: *[4]u8) []const u8 {
        if (c.glyph.len > 0) return c.glyph;
        const cp = parseCodepoint(c.glyph_codepoint) orelse return "";
        const n = std.unicode.utf8Encode(cp, buf) catch return "";
        return buf[0..n];
    }
};

/// `F1D00` / `U+F1D00` / `0xF1D00` as a codepoint; null when it is not one.
pub fn parseCodepoint(hex_in: []const u8) ?u21 {
    var hex = std.mem.trim(u8, hex_in, " \t");
    if (std.mem.startsWith(u8, hex, "U+") or std.mem.startsWith(u8, hex, "u+")) hex = hex[2..];
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
    if (hex.len == 0 or hex.len > 6) return null;
    const cp = std.fmt.parseInt(u21, hex, 16) catch return null;
    if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return null;
    return cp;
}

pub const Command = struct {
    /// `<integration>.<verb>`; must not shadow a built-in.
    id: []const u8,
    title: []const u8,
    group: []const u8 = "integrations",
    /// Chords in mnml's spec grammar (`ctrl+k j`, `space i j`).
    keys: []const []const u8 = &.{},
    /// An ex line to run instead of opening the binary (`term foo --x`).
    /// `run` is the launcher spelling of the same thing — the two are
    /// one field to mnml (`line`); a leading `:` is fine. mnml expands
    /// `{{workspace}}`, `{{workspace_name}}`, `{{current_file}}`,
    /// `{{current_file_abs}}`, `{{current_file_dir}}`, `{{cursor_line}}`,
    /// `{{cursor_col}}` and `{{selection}}` when the command fires;
    /// an unknown `{{token}}` stays as written.
    ex: ?[]const u8 = null,
    run: ?[]const u8 = null,
    /// Extra argv when the command opens the binary.
    args: []const []const u8 = &.{},

    /// The line the command runs, if it has one: `run`, else `ex`.
    pub fn line(c: Command) ?[]const u8 {
        return c.run orelse c.ex;
    }
};

pub const ContextMenuEntry = struct {
    /// `tree.file` | `tree.dir` | `tab` | `pane`.
    target: []const u8,
    title: []const u8,
    command: []const u8,
};

pub const MenuBarEntry = struct {
    /// `File > Send via Slack`.
    path: []const u8,
    command: []const u8,
};

pub const StatuslineSegment = struct {
    id: []const u8,
    side: enum { left, right } = .right,
    text: []const u8 = "",
    color: ?[]const u8 = null,
    click_command: ?[]const u8 = null,
    priority: u8 = 100,
    /// What the chip means, on hover, before anything has counted. A
    /// run replaces it with the live breakdown by sending `tooltip` on
    /// its `statusline-set-segment` line.
    tooltip: ?[]const u8 = null,
};

/// A discrete-choice row in mnml's settings overlay, under the
/// integration's name. The chosen value reaches the binary as
/// `MNML_SETTING_<KEY>` (upper-cased) and lives in
/// `<data root>/integration-settings.zon`.
pub const Setting = struct {
    key: []const u8,
    label: []const u8,
    options: []const []const u8,
    default: []const u8 = "",
    help: ?[]const u8 = null,
};

pub const AuthField = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { text, secret, url, email, number } = .text,
    env_fallback: ?[]const u8 = null,
    help_url: ?[]const u8 = null,
    help: ?[]const u8 = null,
    required: bool = false,
};

pub const ValuesSource = struct {
    id: []const u8,
    /// What the host runs on the interval — `mnml-bitbucket --values`.
    /// The host appends `--workspace <ws>` when the line does not carry
    /// one; the integration publishes its own statusline segment over
    /// that workspace's channel.
    command: []const u8,
    /// How often, in seconds. The host clamps it to its own floor and
    /// ceiling and to the user's `integrations.poll.min_interval_secs`.
    poll_interval_secs: u32 = 300,
    /// Also warm the pane's cache after a successful values run
    /// (`--prefetch`). Off by default: prefetch is one request per tab
    /// per repo where `--values` is one, which is the wrong shape for
    /// something that runs on a timer against a rate-limited API.
    prefetch: bool = false,
};

pub const Manifest = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    version: []const u8 = "",
    /// On PATH, or absolute. Empty (left out) makes the manifest a
    /// launcher: no program of its own, every command a `run` line.
    binary: []const u8 = "",
    /// msg / forge / tracker / aws / db / …
    category: []const u8 = "",
    mode: Mode = .mount,
    /// Argv the binary always gets.
    args: []const []const u8 = &.{},
    chip: ?Chip = null,
    commands: []const Command = &.{},
    context_menu: []const ContextMenuEntry = &.{},
    menu_bar: []const MenuBarEntry = &.{},
    statusline: []const StatuslineSegment = &.{},
    settings: []const Setting = &.{},
    /// Environment variables that must be set; the chip dims otherwise.
    requires: []const []const u8 = &.{},
    auth: []const AuthField = &.{},
    values_sources: []const ValuesSource = &.{},
    /// The SDK version the binary was built against — `sdk.version`,
    /// stamped by `render` (so by every `--install`) when the author
    /// leaves it out, which is always. mnml compares it with its own
    /// SDK: an Installed row built behind it wears a `rebuild` chip,
    /// and `integrations.rebuild_stale` rebuilds every one that came
    /// from a folder on this machine. A launcher has no binary and is
    /// never stamped. Empty on a manifest written before the field
    /// existed, which counts as behind.
    sdk: []const u8 = "",

    /// No binary: the commands' `run` lines are all there is.
    pub fn isLauncher(m: Manifest) bool {
        return m.binary.len == 0;
    }

    /// Built on an SDK behind `current` (the host's `sdk.version`), or
    /// never stamped. A launcher is never stale: nothing was built.
    pub fn staleAgainst(m: Manifest, current: []const u8) bool {
        if (m.isLauncher()) return false;
        return sdk_root.behind(m.sdk, current);
    }
};

const sdk_root = @import("root.zig");

pub const IdError = error{InvalidId};

pub const ValidateError = error{ InvalidId, NoBinaryNoCommand, LauncherCommandWithoutRun };

/// The rule both readers apply after the id: a manifest with no
/// `binary` needs at least one command, and every command of such a
/// launcher needs a `run` (or `ex`) line — there is nothing else to
/// open. `why` gets the reason a toast can show.
pub fn validate(m: Manifest, why: *[]const u8) ValidateError!void {
    validateId(m.id) catch {
        why.* = "id must be a file name ([A-Za-z0-9_.-])";
        return error.InvalidId;
    };
    if (!m.isLauncher()) return;
    if (m.commands.len == 0) {
        why.* = "no binary and no command: a launcher needs a command with a run line";
        return error.NoBinaryNoCommand;
    }
    for (m.commands) |c| if (c.line() == null) {
        why.* = "a launcher command needs a run line (there is no binary to open)";
        return error.LauncherCommandWithoutRun;
    };
}

/// `[A-Za-z0-9_.-]+` — an id is a file name.
pub fn validateId(id: []const u8) IdError!void {
    if (id.len == 0 or id.len > 64) return error.InvalidId;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return error.InvalidId,
    };
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.InvalidId;
}

pub const subdir = "integrations";

/// mnml's data root under this environment. `%USERPROFILE%` stands in
/// for `$HOME`, the way `src/config/data_root.zig`'s `home()` does:
/// Windows sets no `HOME`, so without that rung `<integration>
/// --install` answers `error.NoHome` there and writes no manifest
/// unless the caller hands it `MNML_DATA_ROOT` — `run.ps1 install`
/// does, a user running the binary by hand does not.
pub fn dataRoot(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return try gpa.dupe(u8, root);
    if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |xdg| return try std.fs.path.join(gpa, &.{ xdg, "mnml" });
    const home = nonEmpty(env.get("HOME")) orelse nonEmpty(env.get("USERPROFILE")) orelse return null;
    return try std.fs.path.join(gpa, &.{ home, ".config", "mnml" });
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

pub const PathError = error{ NoHome, InvalidId } || Allocator.Error;

/// `<data root>/integrations/<id>.zon`, owned.
pub fn path(gpa: Allocator, env: *const std.process.Environ.Map, id: []const u8) PathError![]u8 {
    try validateId(id);
    const root = (try dataRoot(gpa, env)) orelse return error.NoHome;
    defer gpa.free(root);
    return pathUnder(gpa, root, id);
}

pub fn pathUnder(gpa: Allocator, root: []const u8, id: []const u8) PathError![]u8 {
    try validateId(id);
    const name = try std.fmt.allocPrint(gpa, "{s}.zon", .{id});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ root, subdir, name });
}

/// The manifest as ZON text, owned. Fields at their default are left
/// out, so the file reads as what the author chose — except `.sdk`,
/// which a binary's manifest always carries: the SDK this code was
/// compiled against, so the host can tell a stale build from a current
/// one. A launcher (no binary) is written without it.
pub fn render(gpa: Allocator, m_in: Manifest) Allocator.Error![]u8 {
    var m = m_in;
    if (!m.isLauncher() and m.sdk.len == 0) m.sdk = sdk_root.version;
    return renderUnstamped(gpa, m);
}

/// `render` without the stamp: the manifest exactly as given, `.sdk`
/// included. For a host that rewrites an installed manifest (a user's
/// chip choice) — the stamp says which SDK the binary was built on,
/// and only the binary's own `--install` knows that.
pub fn renderUnstamped(gpa: Allocator, m: Manifest) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (m.isLauncher()) {
        out.writer.writeAll("// A launcher manifest (no binary of its own); mnml reads it at startup and on integrations.refresh.\n") catch return error.OutOfMemory;
    } else {
        out.writer.writeAll("// Written by `") catch return error.OutOfMemory;
        out.writer.writeAll(m.binary) catch return error.OutOfMemory;
        out.writer.writeAll(" --install`; mnml reads it at startup and on integrations.refresh.\n") catch return error.OutOfMemory;
    }
    std.zon.stringify.serialize(m, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const WriteError = PathError || error{WriteFailed};

/// Write the manifest; returns the path written (owned).
pub fn write(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, m: Manifest) WriteError![]u8 {
    const root = (try dataRoot(gpa, env)) orelse return error.NoHome;
    defer gpa.free(root);
    return writeUnder(gpa, io, root, m);
}

pub fn writeUnder(gpa: Allocator, io: Io, root: []const u8, m: Manifest) WriteError![]u8 {
    const p = try pathUnder(gpa, root, m.id);
    errdefer gpa.free(p);
    const text = try render(gpa, m);
    defer gpa.free(text);
    Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?) catch return error.WriteFailed;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch return error.WriteFailed;
    return p;
}

/// Delete the manifest. True when a file went; false when there was none.
pub fn remove(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, id: []const u8) (PathError || error{RemoveFailed})!bool {
    const p = try path(gpa, env, id);
    defer gpa.free(p);
    Io.Dir.cwd().deleteFile(io, p) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.RemoveFailed,
    };
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("testing.zig");

test "stale: an older stamp and a missing one are stale against the host's SDK; an equal one is not" {
    const bin: Manifest = .{ .id = "x", .label = "x", .binary = "mnml-x", .sdk = "0.1.0" };
    try testing.expect(bin.staleAgainst("0.2.0"));
    try testing.expect(!bin.staleAgainst("0.1.0"));
    const unstamped: Manifest = .{ .id = "x", .label = "x", .binary = "mnml-x" };
    try testing.expect(unstamped.staleAgainst("0.1.0"));
}

test "ids are file names" {
    try validateId("jira");
    try validateId("mnml-forge-bitbucket.v2");
    try testing.expectError(error.InvalidId, validateId(""));
    try testing.expectError(error.InvalidId, validateId("a/b"));
    try testing.expectError(error.InvalidId, validateId(".."));
    try testing.expectError(error.InvalidId, validateId("sp ace"));
}

test "validate: a binary needs nothing more; a launcher needs commands, each with a run (or ex) line; the line is one field" {
    var why: []const u8 = "";
    try validate(.{ .id = "jira", .label = "Jira", .binary = "mnml-jira" }, &why);
    const htop: Manifest = .{ .id = "htop", .label = "htop", .commands = &.{.{ .id = "htop.open", .title = "htop: open", .run = ":term htop" }} };
    try testing.expect(htop.isLauncher());
    try validate(htop, &why);
    try testing.expectEqualStrings(":term htop", htop.commands[0].line().?);
    const via_ex: Manifest = .{ .id = "x", .label = "x", .commands = &.{.{ .id = "x.o", .title = "o", .ex = "term x" }} };
    try validate(via_ex, &why);
    try testing.expectError(error.NoBinaryNoCommand, validate(.{ .id = "e", .label = "e" }, &why));
    try testing.expect(std.mem.indexOf(u8, why, "no binary and no command") != null);
    try testing.expectError(error.LauncherCommandWithoutRun, validate(.{ .id = "e", .label = "e", .commands = &.{.{ .id = "e.o", .title = "o" }} }, &why));
    try testing.expect(std.mem.indexOf(u8, why, "run line") != null);
    try testing.expectError(error.InvalidId, validate(.{ .id = "a/b", .label = "x", .binary = "y" }, &why));
    // `run` wins over `ex` when a manifest carries both.
    try testing.expectEqualStrings("term a", (Command{ .id = "c", .title = "c", .run = "term a", .ex = "term b" }).line().?);
    try testing.expect((Command{ .id = "c", .title = "c" }).line() == null);
}

test "a chip's glyph: the literal first, else the pinned codepoint decoded, else nothing" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("H", (Chip{ .glyph = "H", .glyph_codepoint = "F1D00" }).glyphText(&buf));
    try testing.expectEqualStrings("\u{F1D00}", (Chip{ .glyph_codepoint = "F1D00" }).glyphText(&buf));
    try testing.expectEqualStrings("\u{F1D00}", (Chip{ .glyph_codepoint = "U+F1D00" }).glyphText(&buf));
    try testing.expectEqualStrings("\u{E8DA}", (Chip{ .glyph_codepoint = "0xe8da" }).glyphText(&buf));
    try testing.expectEqualStrings("", (Chip{}).glyphText(&buf));
    try testing.expectEqualStrings("", (Chip{ .glyph_codepoint = "not hex" }).glyphText(&buf));
    try testing.expectEqualStrings("", (Chip{ .glyph_codepoint = "D800" }).glyphText(&buf));
    try testing.expect(parseCodepoint("1234567") == null);
}

test "the data root follows MNML_DATA_ROOT, XDG, HOME" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect((try dataRoot(testing.allocator, &env)) == null);
    try env.put("HOME", "/h");
    const a = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(a);
    try sdk_testing.expectPath("/h/.config/mnml", a);
    try env.put("XDG_CONFIG_HOME", "/x");
    const b = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(b);
    try sdk_testing.expectPath("/x/mnml", b);
    try env.put("MNML_DATA_ROOT", "/r");
    const c = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("/r", c);
    const p = try path(testing.allocator, &env, "jira");
    defer testing.allocator.free(p);
    try sdk_testing.expectPath("/r/integrations/jira.zon", p);
}

test "USERPROFILE is the home where HOME is not set" {
    // Windows sets USERPROFILE and no HOME. Without this rung a bare
    // `mnml-jira.exe --install` there returns error.NoHome and writes
    // nothing; `src/config/data_root.zig` has had the same fallback
    // since the Windows backends landed, and the two must agree or the
    // manifest lands somewhere mnml never reads.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("USERPROFILE", "C:\\Users\\u");
    const a = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("C:\\Users\\u" ++ std.fs.path.sep_str ++ ".config" ++ std.fs.path.sep_str ++ "mnml", a);
    // HOME still wins where both are set (MSYS and Git Bash set both).
    try env.put("HOME", "/h");
    const b = (try dataRoot(testing.allocator, &env)).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/h" ++ std.fs.path.sep_str ++ ".config" ++ std.fs.path.sep_str ++ "mnml", b);
}

test "write renders ZON that parses back with the same shape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const m: Manifest = .{
        .id = "hello",
        .label = "Hello",
        .description = "The sample integration",
        .version = "0.1.0",
        .binary = "mnml-hello",
        .chip = .{ .glyph = "\u{f0a7}", .fallback = "H", .color = "cyan" },
        .commands = &.{
            .{ .id = "hello.open", .title = "Hello: open", .keys = &.{"ctrl+k h"} },
            .{ .id = "hello.shell", .title = "Hello: shell", .ex = "term mnml-hello --shell" },
        },
        .settings = &.{.{ .key = "greeting", .label = "Greeting", .options = &.{ "hi", "hello" }, .default = "hi" }},
        .requires = &.{"HELLO_TOKEN"},
    };
    const p = try writeUnder(testing.allocator, testing.io, root, m);
    defer testing.allocator.free(p);
    try testing.expect(sdk_testing.pathEndsWith(p, "/integrations/hello.zon"));
    const text = try Io.Dir.cwd().readFileAllocOptions(testing.io, p, testing.allocator, .unlimited, .of(u8), 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "// Written by `mnml-hello --install`"));
    try testing.expect(std.mem.indexOf(u8, text, ".mode") == null); // a default is not written
    // Parsed on an arena: `std.zon.parse.free` would try to free the
    // literal a defaulted field points at.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena_state.allocator());
    const back = try std.zon.parse.fromSliceAlloc(Manifest, arena_state.allocator(), text, &diag, .{ .free_on_error = false });
    try testing.expectEqualStrings("hello", back.id);
    try testing.expectEqual(Mode.mount, back.mode);
    try testing.expectEqualStrings("cyan", back.chip.?.color);
    try testing.expect(back.chip.?.enabled);
    try testing.expectEqual(@as(usize, 2), back.commands.len);
    try testing.expectEqualStrings("ctrl+k h", back.commands[0].keys[0]);
    try testing.expectEqualStrings("term mnml-hello --shell", back.commands[1].ex.?);
    try testing.expectEqualStrings("hello", back.settings[0].options[1]);
    try testing.expectEqualStrings("HELLO_TOKEN", back.requires[0]);
    // `--install` stamps the SDK it was compiled against, which the
    // author never wrote; the host reads it back to call a build stale.
    try testing.expectEqualStrings(sdk_root.version, back.sdk);
    try testing.expect(std.mem.indexOf(u8, text, ".sdk = \"" ++ sdk_root.version ++ "\"") != null);
    try testing.expect(!back.staleAgainst(sdk_root.version));
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", root);
    try testing.expect(try remove(testing.allocator, testing.io, &env, "hello"));
    try testing.expect(!try remove(testing.allocator, testing.io, &env, "hello"));
    // A launcher renders without a `.binary` and says what it is.
    const launcher: Manifest = .{ .id = "htop", .label = "htop", .chip = .{ .glyph_codepoint = "F1D00", .fallback = "H" }, .commands = &.{.{ .id = "htop.open", .title = "htop: open", .run = ":term htop" }} };
    const lp = try writeUnder(testing.allocator, testing.io, root, launcher);
    defer testing.allocator.free(lp);
    const ltext = try Io.Dir.cwd().readFileAllocOptions(testing.io, lp, testing.allocator, .unlimited, .of(u8), 0);
    defer testing.allocator.free(ltext);
    try testing.expect(std.mem.startsWith(u8, ltext, "// A launcher manifest"));
    try testing.expect(std.mem.indexOf(u8, ltext, ".binary") == null);
    // Nothing was compiled, so nothing is stamped — and nothing is stale.
    try testing.expect(std.mem.indexOf(u8, ltext, ".sdk") == null);
    try testing.expect(!launcher.staleAgainst("9.9.9"));
    try testing.expect(std.mem.indexOf(u8, ltext, ".run = \":term htop\"") != null);
    try testing.expect(std.mem.indexOf(u8, ltext, ".glyph_codepoint = \"F1D00\"") != null);
    var ldiag: std.zon.parse.Diagnostics = .{};
    defer ldiag.deinit(arena_state.allocator());
    const lback = try std.zon.parse.fromSliceAlloc(Manifest, arena_state.allocator(), ltext, &ldiag, .{ .free_on_error = false });
    try testing.expect(lback.isLauncher());
    try testing.expectEqualStrings(":term htop", lback.commands[0].line().?);
}
