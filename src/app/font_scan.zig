//! Installed Nerd Fonts, for the Marketplace tab's FONTS section.
//!
//! A stale Nerd Font silently changes what mnml looks like — 3.4.0's
//! codicon U+EB40 is a book, 3.5.1's an arrow into a circle — and
//! nothing on the system says which vintage is installed. The font
//! files do: name-table ID 5 carries `…;Nerd Fonts X.Y.Z`. This module
//! reads it with a seek-based sfnt reader (the table directory and the
//! `name` table only, never the multi-MB glyph tables), groups the
//! per-weight files into families, and compares each with the latest
//! release, which a worker fetches from the GitHub API once a day and
//! caches at `<data root>/cache/nerdfonts-latest.json`.
//!
//! The scan runs on the `startup` hook (`onStartup`); the fetch lands
//! as one `.fonts` event (D3). `MNML_FONT_DIRS` (`:`-separated, `;` on
//! Windows) replaces the platform font directories — the UI spec dump
//! and the tests seed a fixture folder through it; `MNML_NERDFONTS_LATEST`
//! names the latest release and skips the lookup.
//!
//! `updateCommand` is the one-click update the section's `↑ Update`
//! chip offers: on macOS the family's Homebrew cask; elsewhere null —
//! Linux distributions package Nerd Fonts under too many names to
//! guess one, and Windows installs are per-user drag-and-drop.
//! `cmapCodepoints` reads a font's format-12 cmap — the ground truth
//! the startup tofu check (`glyph_audit.zig`) needs for the fonts mnml
//! owns.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Mouse = @import("../core/key.zig").Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const hooks = @import("../core/hooks.zig");
const alloc = @import("../core/alloc.zig");
const marketplace = @import("marketplace.zig");
const runners = @import("runners.zig");
const fonts_section = @import("../ui/fonts_section.zig");

/// The mnml-owned symbols face: no Nerd Fonts lineage, never updated
/// through a cask.
pub const mnml_symbols = "MnmlSymbols";
pub const latest_url_path = "/repos/ryanoasis/nerd-fonts/releases/latest";
pub const cache_rel = "cache/nerdfonts-latest.json";
pub const cache_ttl_secs: i64 = 24 * 3600;

/// One installed family, the per-weight and variant files collapsed.
pub const Family = struct {
    /// `JetBrainsMono Nerd Font`, `Symbols Nerd Font`, `MnmlSymbols`.
    name: []const u8,
    /// `3.5.1` from name ID 5; null for MnmlSymbols.
    version: ?[]const u8,
    /// One representative file, the first seen.
    path: []const u8,
};

pub const CpSet = std.AutoHashMapUnmanaged(u21, void);

// ─── the state ──────────────────────────────────────────────────────────

pub const Result = struct {
    kind: union(enum) {
        latest: []u8,
        failed: []u8,
    },

    pub fn destroy(self: *Result, gpa: Allocator) void {
        switch (self.kind) {
            .latest, .failed => |s| gpa.free(s),
        }
        gpa.destroy(self);
    }
};

pub const State = struct {
    group: Io.Group = .init,
    snapshot: alloc.SnapshotArena,
    families: []Family = &.{},
    scanned: bool = false,
    /// The latest release, gpa-owned; null until the cache or the worker says.
    latest: ?[]u8 = null,
    fetching: bool = false,
    /// The installed MnmlSymbols' cmap, read once per scan and
    /// gpa-owned; null when no face is installed. A painter choosing
    /// between a baked glyph and a Unicode fallback asks `baked` every
    /// frame, and that must not touch the disk.
    mnml_glyphs: ?CpSet = null,

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = .init(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.group.cancel(io);
        if (self.latest) |l| gpa.free(l);
        if (self.mnml_glyphs) |*s| s.deinit(gpa);
        self.snapshot.deinit();
    }

    /// Does the installed MnmlSymbols carry `cp`? False when no face is
    /// installed, and false when the installed one predates the glyph —
    /// an older bake is exactly the case a fallback exists for.
    pub fn baked(self: *const State, cp: u21) bool {
        const set = self.mnml_glyphs orelse return false;
        return set.contains(cp);
    }
};

// ─── the sfnt reader ────────────────────────────────────────────────────

/// Where the bytes come from: a file, read at offsets, or a slice (the
/// tests' hand-built fonts).
const Source = union(enum) {
    file: struct { f: Io.File, io: Io },
    bytes: []const u8,

    fn readExact(s: Source, buf: []u8, off: u64) ?void {
        switch (s) {
            .bytes => |b| {
                if (off + buf.len > b.len) return null;
                @memcpy(buf, b[@intCast(off)..][0..buf.len]);
            },
            .file => |f| {
                const n = f.f.readPositionalAll(f.io, buf, off) catch return null;
                if (n != buf.len) return null;
            },
        }
    }

    fn u16At(s: Source, off: u64) ?u16 {
        var b: [2]u8 = undefined;
        s.readExact(&b, off) orelse return null;
        return std.mem.readInt(u16, &b, .big);
    }

    fn u32At(s: Source, off: u64) ?u32 {
        var b: [4]u8 = undefined;
        s.readExact(&b, off) orelse return null;
        return std.mem.readInt(u32, &b, .big);
    }
};

const tag_ttcf = std.mem.readInt(u32, "ttcf", .big);
const tag_otto = std.mem.readInt(u32, "OTTO", .big);
const tag_true = std.mem.readInt(u32, "true", .big);
const tag_name = std.mem.readInt(u32, "name", .big);
const tag_cmap = std.mem.readInt(u32, "cmap", .big);

/// The table directory: the first font of a collection (`ttcf`), else
/// the file itself — TrueType (`0x00010000` / `true`) and CFF (`OTTO`)
/// lay the directory out the same way. Null when the magic is none of
/// those, so a stray file in a font folder costs four bytes.
fn sfntBase(s: Source) ?u64 {
    const magic = s.u32At(0) orelse return null;
    if (magic == tag_ttcf) return s.u32At(12) orelse return null;
    if (magic == 0x00010000 or magic == tag_otto or magic == tag_true) return 0;
    return null;
}

/// The offset of table `tag`, when the font has it. A directory of
/// more than 64 tables is a corrupt header, not a font.
fn tableOffset(s: Source, base: u64, tag: u32) ?u64 {
    const num_tables = s.u16At(base + 4) orelse return null;
    if (num_tables > 64) return null;
    var i: u64 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = base + 12 + i * 16;
        if ((s.u32At(rec) orelse return null) == tag) return s.u32At(rec + 8) orelse return null;
    }
    return null;
}

/// What the name table says about one file. Both owned by the caller.
pub const Names = struct {
    family: []u8,
    version: ?[]u8,

    pub fn deinit(n: Names, gpa: Allocator) void {
        gpa.free(n.family);
        if (n.version) |v| gpa.free(v);
    }
};

fn readNames(gpa: Allocator, s: Source) Allocator.Error!?Names {
    const base = sfntBase(s) orelse return null;
    const name_off = tableOffset(s, base, tag_name) orelse return null;
    const count = s.u16At(name_off + 2) orelse return null;
    if (count > 512) return null;
    const string_off = name_off + (s.u16At(name_off + 4) orelse return null);
    // Per slot: the value and whether it came from the Windows platform.
    // Windows (platform 3, UTF-16BE) beats Mac (platform 1), and the
    // FIRST record of the winning platform sticks: Nerd Font files carry
    // two platform-3 ID-16 records, the full "X Nerd Font" then the
    // abbreviated "X NF", and last-wins would take the abbreviation.
    const Slot = struct {
        text: ?[]u8 = null,
        win: bool = false,

        fn offer(slot: *@This(), gpa_: Allocator, text: []u8, is_win: bool) void {
            if (slot.text) |cur| {
                if (slot.win or !is_win) {
                    gpa_.free(text);
                    return;
                }
                gpa_.free(cur);
            }
            slot.text = text;
            slot.win = is_win;
        }
    };
    var family_16: Slot = .{};
    var family_1: Slot = .{};
    var version: Slot = .{};
    errdefer {
        if (family_16.text) |fam| gpa.free(fam);
        if (family_1.text) |fam| gpa.free(fam);
        if (version.text) |ver| gpa.free(ver);
    }
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const rec = name_off + 6 + i * 12;
        const platform = s.u16At(rec) orelse return null;
        const name_id = s.u16At(rec + 6) orelse return null;
        if (name_id != 1 and name_id != 5 and name_id != 16) continue;
        const len = s.u16At(rec + 8) orelse return null;
        const off = s.u16At(rec + 10) orelse return null;
        if (len == 0 or len > 4096) continue;
        const raw = try gpa.alloc(u8, len);
        defer gpa.free(raw);
        s.readExact(raw, string_off + off) orelse continue;
        const text = if (platform == 3) try utf16BeToUtf8(gpa, raw) else try gpa.dupe(u8, raw);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) {
            gpa.free(text);
            continue;
        }
        const owned = if (trimmed.len == text.len) text else blk: {
            defer gpa.free(text);
            break :blk try gpa.dupe(u8, trimmed);
        };
        switch (name_id) {
            16 => family_16.offer(gpa, owned, platform == 3),
            1 => family_1.offer(gpa, owned, platform == 3),
            5 => version.offer(gpa, owned, platform == 3),
            else => unreachable,
        }
    }
    // ID 16 over ID 1; the loser is freed.
    const pick: struct { family: []u8, other: ?[]u8 } = if (family_16.text) |typographic|
        .{ .family = typographic, .other = family_1.text }
    else
        .{ .family = family_1.text orelse return null, .other = null };
    if (pick.other) |o| gpa.free(o);
    return .{ .family = pick.family, .version = version.text };
}

/// UTF-16BE to UTF-8; a lone surrogate is dropped (font names are ASCII).
fn utf16BeToUtf8(gpa: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, raw[i..][0..2], .big);
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 3 < raw.len) {
            const lo: u21 = std.mem.readInt(u16, raw[i + 2 ..][0..2], .big);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else continue;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// The family and version string of one font file; null when the file
/// is not a font or has no family name.
pub fn readFileNames(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?Names {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    return readNames(gpa, .{ .file = .{ .f = f, .io = io } });
}

/// `readFileNames` over bytes already in memory (the tests' fixtures).
pub fn readBytesNames(gpa: Allocator, bytes: []const u8) Allocator.Error!?Names {
    return readNames(gpa, .{ .bytes = bytes });
}

/// Every codepoint the font's format-12 cmap subtables map. Format 12
/// only: mnml's own block (U+F1B00+) is in plane 15, which the BMP-only
/// format 4 cannot hold, so any font carrying mnml glyphs has one.
/// Null when the file is no font or has no such subtable.
pub fn cmapCodepoints(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?CpSet {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    return cmapOf(gpa, .{ .file = .{ .f = f, .io = io } });
}

pub fn cmapOfBytes(gpa: Allocator, bytes: []const u8) Allocator.Error!?CpSet {
    return cmapOf(gpa, .{ .bytes = bytes });
}

fn cmapOf(gpa: Allocator, s: Source) Allocator.Error!?CpSet {
    const base = sfntBase(s) orelse return null;
    const cmap_off = tableOffset(s, base, tag_cmap) orelse return null;
    const n_sub = s.u16At(cmap_off + 2) orelse return null;
    if (n_sub > 32) return null;
    var out: CpSet = .empty;
    errdefer out.deinit(gpa);
    var found = false;
    var i: u64 = 0;
    while (i < n_sub) : (i += 1) {
        const rec = cmap_off + 4 + i * 8;
        const sub_off = cmap_off + (s.u32At(rec + 4) orelse return null);
        if ((s.u16At(sub_off) orelse return null) != 12) continue;
        found = true;
        const n_groups = s.u32At(sub_off + 12) orelse return null;
        if (n_groups > 10_000) continue;
        var g: u64 = 0;
        while (g < n_groups) : (g += 1) {
            const grp = sub_off + 16 + g * 12;
            const start = s.u32At(grp) orelse return null;
            const end = s.u32At(grp + 4) orelse return null;
            if (end < start or end - start > 0x10000 or end > 0x10FFFF) continue;
            var cp = start;
            while (cp <= end) : (cp += 1) try out.put(gpa, @intCast(cp), {});
        }
    }
    if (!found) {
        out.deinit(gpa);
        return null;
    }
    return out;
}

// ─── families ───────────────────────────────────────────────────────────

/// `X.Y.Z` after the `Nerd Fonts` marker of a name-ID-5 string —
/// `Version 3.5.1;Nerd Fonts 3.5.1`, `Version 2.030;ryanoasis Nerd
/// Fonts 3.4.0` — anchored on the marker, never the leading `Version`.
pub fn nfVersionFromId5(s: []const u8) ?[]const u8 {
    const marker = "Nerd Fonts";
    const at = std.mem.indexOf(u8, s, marker) orelse return null;
    var rest = s[at + marker.len ..];
    rest = std.mem.trimStart(u8, rest, " \t");
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.')) : (end += 1) {}
    const ver = std.mem.trim(u8, rest[0..end], ".");
    return if (ver.len == 0) null else ver;
}

/// A Nerd Font (or mnml's own face): the full `X Nerd Font [Mono|Propo]`
/// form and the abbreviated `X NF` / `NFM` / `NFP` some files carry as
/// their only family name.
pub fn isNerdFontFamily(family: []const u8) bool {
    if (std.mem.eql(u8, family, mnml_symbols)) return true;
    if (std.mem.indexOf(u8, family, "Nerd Font") != null) return true;
    for ([_][]const u8{ " NF", " NFM", " NFP" }) |suf| if (std.mem.endsWith(u8, family, suf)) return true;
    return false;
}

/// The base name a family is keyed on: everything before ` Nerd Font`
/// or the abbreviated suffix, minus the `NL` (no-ligature) marker.
fn baseName(family: []const u8) []const u8 {
    var base = family;
    if (std.mem.indexOf(u8, base, " Nerd Font")) |at| base = base[0..at];
    for ([_][]const u8{ " NFM", " NFP", " NF" }) |suf| if (std.mem.endsWith(u8, base, suf)) {
        base = base[0 .. base.len - suf.len];
        break;
    };
    if (std.mem.endsWith(u8, base, "NL")) base = base[0 .. base.len - 2];
    return std.mem.trimEnd(u8, base, " ");
}

/// The one row a family's variants share: ` Nerd Font Mono`, ` Nerd
/// Font Propo`, ` NF` / ` NFM` / ` NFP` and the NL marker all fold into
/// `<Base> Nerd Font` — one cask ships nine faces at one version.
pub fn displayGroup(arena: Allocator, family: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, family, mnml_symbols)) return try arena.dupe(u8, family);
    return std.fmt.allocPrint(arena, "{s} Nerd Font", .{baseName(family)});
}

/// The directories to scan: `MNML_FONT_DIRS` when set (empty = none),
/// else the platform's. Missing directories are skipped by the scan.
pub fn fontDirs(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (env.get("MNML_FONT_DIRS")) |list| {
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        var it = std.mem.splitScalar(u8, list, sep);
        while (it.next()) |d| if (d.len > 0) try out.append(arena, d);
        return out.toOwnedSlice(arena);
    }
    const home = env.get("HOME") orelse env.get("USERPROFILE");
    switch (builtin.os.tag) {
        .macos => {
            if (home) |h| try out.append(arena, try std.fs.path.join(arena, &.{ h, "Library", "Fonts" }));
            try out.append(arena, "/Library/Fonts");
        },
        .windows => {
            if (env.get("LOCALAPPDATA")) |lad| try out.append(arena, try std.fs.path.join(arena, &.{ lad, "Microsoft", "Windows", "Fonts" }));
            try out.append(arena, "C:\\Windows\\Fonts");
        },
        else => {
            if (home) |h| {
                try out.append(arena, try std.fs.path.join(arena, &.{ h, ".local", "share", "fonts" }));
                try out.append(arena, try std.fs.path.join(arena, &.{ h, ".fonts" }));
            }
            try out.append(arena, "/usr/share/fonts");
            try out.append(arena, "/usr/local/share/fonts");
        },
    }
    return out.toOwnedSlice(arena);
}

fn isFontFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".ttf", ".otf", ".ttc" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// The Nerd Font families under `dirs` (one level of subfolders too —
/// Linux nests per family), sorted by name. Everything on `arena`.
pub fn scanDirs(arena: Allocator, gpa: Allocator, io: Io, dirs: []const []const u8) Allocator.Error![]Family {
    var out: std.ArrayListUnmanaged(Family) = .empty;
    for (dirs) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind == .directory) {
                const sub_path = try std.fs.path.join(arena, &.{ dir_path, e.name });
                var sub = Io.Dir.cwd().openDir(io, sub_path, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                var sit = sub.iterate();
                while (sit.next(io) catch null) |e2| {
                    if (e2.kind == .directory) continue;
                    try visitFile(arena, gpa, io, &out, try std.fs.path.join(arena, &.{ sub_path, e2.name }));
                }
            } else {
                try visitFile(arena, gpa, io, &out, try std.fs.path.join(arena, &.{ dir_path, e.name }));
            }
        }
    }
    std.mem.sort(Family, out.items, {}, struct {
        fn lt(_: void, a: Family, b: Family) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

fn visitFile(arena: Allocator, gpa: Allocator, io: Io, out: *std.ArrayListUnmanaged(Family), path: []const u8) Allocator.Error!void {
    if (!isFontFile(path)) return;
    const names = (try readFileNames(gpa, io, path)) orelse return;
    defer names.deinit(gpa);
    if (!isNerdFontFamily(names.family)) return;
    const group = try displayGroup(arena, names.family);
    const version: ?[]const u8 = if (names.version) |v| (if (nfVersionFromId5(v)) |nv| try arena.dupe(u8, nv) else null) else null;
    for (out.items) |*fam| if (std.mem.eql(u8, fam.name, group)) {
        // Several weight files of one family: the highest version seen
        // wins, so a half-updated family reads as the newer install.
        if (version) |v| {
            if (fam.version == null or std.mem.lessThan(u8, fam.version.?, v)) fam.version = v;
        }
        return;
    };
    try out.append(arena, .{ .name = group, .version = version, .path = path });
}

/// The platform's (or `MNML_FONT_DIRS`'s) Nerd Font families.
pub fn scanNerdFonts(arena: Allocator, gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error![]Family {
    return scanDirs(arena, gpa, io, try fontDirs(arena, env));
}

// ─── the update command ─────────────────────────────────────────────────

/// Cask tokens that are not a plain CamelCase → kebab split.
const cask_overrides = [_]struct { base: []const u8, cask: []const u8 }{
    .{ .base = "JetBrainsMono", .cask = "jetbrains-mono" },
    .{ .base = "MesloLGS", .cask = "meslo-lg" },
    .{ .base = "MesloLGM", .cask = "meslo-lg" },
    .{ .base = "MesloLGL", .cask = "meslo-lg" },
    .{ .base = "SauceCodePro", .cask = "sauce-code-pro" },
    .{ .base = "CaskaydiaCove", .cask = "caskaydia-cove" },
    .{ .base = "CaskaydiaMono", .cask = "caskaydia-mono" },
    .{ .base = "BlexMono", .cask = "blex-mono" },
    .{ .base = "iMWriting", .cask = "im-writing" },
};

/// `FiraCode` → `fira-code`; consecutive capitals stay one word.
fn camelToKebab(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i > 0) try out.append(arena, '-');
        try out.append(arena, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(arena);
}

/// The shell line that updates one family, or null when mnml cannot
/// drive it: MnmlSymbols is mnml's own, and only macOS has one package
/// manager every Nerd Font ships through (`brew install --cask
/// font-<name>-nerd-font`) — on Linux the fonts come as `fonts-*`,
/// `nerd-fonts-*`, `ttf-*` or a tarball depending on the distribution,
/// and on Windows they are installed by hand, so both return null and
/// the row shows the version without a chip. `upgrade || install`
/// covers a family brew does not know it installed.
pub fn updateCommand(arena: Allocator, family: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, family, mnml_symbols)) return null;
    if (builtin.os.tag != .macos) return null;
    return updateCommandMacos(arena, family);
}

/// `updateCommand`'s macOS rule, on every platform so the tests pin it.
pub fn updateCommandMacos(arena: Allocator, family: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, family, mnml_symbols)) return null;
    if (std.mem.startsWith(u8, family, "Symbols Nerd Font")) return "brew upgrade --cask font-symbols-only-nerd-font || brew install --cask font-symbols-only-nerd-font";
    const base_spaced = baseName(family);
    var base: std.ArrayListUnmanaged(u8) = .empty;
    for (base_spaced) |c| if (c != ' ') try base.append(arena, c);
    if (base.items.len == 0) return null;
    var kebab: ?[]const u8 = null;
    for (cask_overrides) |o| if (std.mem.eql(u8, o.base, base.items)) {
        kebab = o.cask;
    };
    const token = kebab orelse try camelToKebab(arena, base.items);
    const line: []const u8 = try std.fmt.allocPrint(arena, "brew upgrade --cask font-{s}-nerd-font || brew install --cask font-{s}-nerd-font", .{ token, token });
    return line;
}

// ─── the latest release ─────────────────────────────────────────────────

const Cache = struct { version: []const u8, checked_epoch: i64 };

pub fn cachePath(arena: Allocator, data_root: []const u8) Allocator.Error!?[]const u8 {
    if (data_root.len == 0) return null;
    return try std.fs.path.join(arena, &.{ data_root, cache_rel });
}

/// The cached latest version when the cache is younger than a day.
pub fn latestCached(arena: Allocator, io: Io, path: []const u8, now_epoch: i64) ?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    const c = std.json.parseFromSliceLeaky(Cache, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    if (c.version.len == 0) return null;
    if (now_epoch - c.checked_epoch >= cache_ttl_secs or now_epoch < c.checked_epoch) return null;
    return c.version;
}

pub fn writeCache(gpa: Allocator, io: Io, path: []const u8, version: []const u8, now_epoch: i64) Allocator.Error!void {
    const text = try std.json.Stringify.valueAlloc(gpa, Cache{ .version = version, .checked_epoch = now_epoch }, .{});
    defer gpa.free(text);
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch {};
    cwd.writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

/// `tag_name` of a release, its `v` stripped.
pub fn parseLatest(arena: Allocator, body: []const u8) ?[]const u8 {
    const Release = struct { tag_name: []const u8 };
    const r = std.json.parseFromSliceLeaky(Release, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    const v = std.mem.trimStart(u8, r.tag_name, "v");
    return if (v.len == 0) null else v;
}

pub fn nowEpoch(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

fn apiBase(app: *App) []const u8 {
    if (app.env.get("MNML_MARKETPLACE_API")) |v| if (v.len > 0) return v;
    return marketplace.default_api;
}

fn post(events: *event.EventQueue, io: Io, gpa: Allocator, r: Result) void {
    const box = gpa.create(Result) catch return;
    box.* = r;
    events.post(io, .{ .fonts = box });
}

fn fetchWorker(events: *event.EventQueue, io: Io, gpa: Allocator, url: []u8, cache: ?[]u8) void {
    defer {
        gpa.free(url);
        if (cache) |c| gpa.free(c);
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    io.checkCancel() catch return;
    const fetched = marketplace.fetch(gpa, io, arena, url) catch return;
    const body = switch (fetched) {
        .body => |b| b,
        .err => |e| {
            const msg = std.fmt.allocPrint(gpa, "nerd fonts: {s}", .{e}) catch return;
            return post(events, io, gpa, .{ .kind = .{ .failed = msg } });
        },
    };
    const version = parseLatest(arena, body) orelse {
        const msg = gpa.dupe(u8, "nerd fonts: no tag_name in the release") catch return;
        return post(events, io, gpa, .{ .kind = .{ .failed = msg } });
    };
    if (cache) |c| writeCache(gpa, io, c, version, nowEpoch(io)) catch {};
    const owned = gpa.dupe(u8, version) catch return;
    post(events, io, gpa, .{ .kind = .{ .latest = owned } });
}

/// Start the lookup unless the answer is already known.
pub fn fetchLatest(app: *App) Allocator.Error!void {
    const st = &app.fonts;
    if (st.latest != null or st.fetching) return;
    const gpa = app.gpa;
    const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ apiBase(app), latest_url_path });
    errdefer gpa.free(url);
    const cache: ?[]u8 = if (try cachePath(app.frame.allocator(), app.data_root)) |p| try gpa.dupe(u8, p) else null;
    errdefer if (cache) |c| gpa.free(c);
    st.group.concurrent(app.io, fetchWorker, .{ app.events, app.io, gpa, url, cache }) catch return;
    st.fetching = true;
}

pub fn handle(app: *App, r: *Result) Allocator.Error!void {
    defer app.gpa.destroy(r);
    const st = &app.fonts;
    st.fetching = false;
    switch (r.kind) {
        .latest => |v| {
            if (st.latest) |old| app.gpa.free(old);
            st.latest = v;
        },
        // A failed lookup is not news: the header just omits the version.
        .failed => |msg| app.gpa.free(msg),
    }
    app.needs_render = true;
}

// ─── the startup ────────────────────────────────────────────────────────

/// The scan, then the latest release from `MNML_NERDFONTS_LATEST`, the
/// cache, or the worker — only when something is installed to compare.
pub fn scan(app: *App) Allocator.Error!void {
    const st = &app.fonts;
    st.snapshot.reset();
    const arena = st.snapshot.allocator();
    st.families = try scanDirs(arena, app.gpa, app.io, try fontDirs(arena, &app.env));
    st.scanned = true;
    // The installed face's cmap, read here so the painters never do.
    if (st.mnml_glyphs) |*s| s.deinit(app.gpa);
    st.mnml_glyphs = if (mnmlSymbolsPath(app)) |p| try cmapCodepoints(app.gpa, app.io, p) else null;
    if (st.latest == null) {
        if (app.env.get("MNML_NERDFONTS_LATEST")) |v| {
            if (v.len > 0) st.latest = try app.gpa.dupe(u8, v);
        } else if (try cachePath(app.frame.allocator(), app.data_root)) |p| {
            if (latestCached(app.frame.allocator(), app.io, p, nowEpoch(app.io))) |v| st.latest = try app.gpa.dupe(u8, v);
        }
    }
    if (st.latest == null and st.families.len > 0) try fetchLatest(app);
}

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    scan(app) catch {};
}

/// The MnmlSymbols family's file, when installed.
pub fn mnmlSymbolsPath(app: *const App) ?[]const u8 {
    for (app.fonts.families) |f| if (std.mem.eql(u8, f.name, mnml_symbols)) return f.path;
    return null;
}

/// The installed family a ghostty `font-codepoint-map` target names —
/// loosely: `Symbols Nerd Font` matches `Symbols Nerd Font Mono`.
pub fn familyNamed(app: *const App, target: []const u8) ?Family {
    const want = std.mem.trim(u8, target, " ");
    if (want.len == 0) return null;
    for (app.fonts.families) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, want)) return f;
        if (std.ascii.startsWithIgnoreCase(want, f.name) or std.ascii.startsWithIgnoreCase(f.name, want)) return f;
    }
    return null;
}

// ─── the section ────────────────────────────────────────────────────────

/// The FONTS rows for the painter; null when nothing is installed.
pub fn sectionProps(app: *App, arena: Allocator) Allocator.Error!?fonts_section.Props {
    const st = &app.fonts;
    if (st.families.len == 0) return null;
    const rows = try arena.alloc(fonts_section.Row, st.families.len);
    for (st.families, 0..) |f, i| {
        const behind = if (f.version) |cur| (if (st.latest) |lat| !std.mem.eql(u8, cur, lat) else false) else false;
        rows[i] = .{
            .family = f.name,
            .version = f.version,
            .updatable = behind and (try updateCommand(arena, f.name)) != null,
        };
    }
    return .{ .latest = st.latest, .rows = rows };
}

pub const update_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'u', .label = "Update" }, .{ .key = 'c', .label = "Copy command" }, .{ .key = 'n', .label = "Not now" } };

/// A press on a row's `↑ Update` chip: the install box with the
/// family's command — Update runs it in a pty pane below, as the tools
/// installer does; Copy puts it on the clipboard.
pub fn updateChipMouse(app: *App, idx: u16, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or m.button != .left) return;
    openUpdateConfirm(app, idx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |msg| app.toast("{s}", .{msg}),
    };
}

pub fn openUpdateConfirm(app: *App, idx: u16) CommandError!void {
    const st = &app.fonts;
    if (idx >= st.families.len) return;
    const f = st.families[idx];
    const cmd = (try updateCommand(app.frame.allocator(), f.name)) orelse return app.diag.fail(app.frame.allocator(), "{s}: no update command on this platform", .{f.name});
    const msg = try std.fmt.allocPrint(app.gpa, "{s} is at v{s}; the latest Nerd Fonts release is {s}.\n{s}", .{ f.name, f.version orelse "?", st.latest orelse "?", cmd });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Update font", .message = msg, .choices = &update_choices },
        .purpose = .{ .font_update = idx },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The box's answer.
pub fn updateAccept(app: *App, idx: u16, choice: usize) CommandError!void {
    const st = &app.fonts;
    if (idx >= st.families.len) return;
    const f = st.families[idx];
    const cmd = (try updateCommand(app.frame.allocator(), f.name)) orelse return;
    switch (choice) {
        0 => {
            const label = try std.fmt.allocPrint(app.frame.allocator(), "update {s}", .{f.name});
            _ = try runners.spawn(app, label, cmd, app.workspace, .command);
        },
        1 => {
            try app.clipboard.setYank(cmd, false);
            app.toast("copied: {s}", .{cmd});
        },
        else => {},
    }
}

// ─── fixtures ───────────────────────────────────────────────────────────

/// A minimal sfnt with a `name` table (IDs 1 / 5 / 16 on the Windows
/// platform, UTF-16BE) and, when `cmap` is given, a format-12 cmap of
/// those inclusive ranges. The tests build these; `tools/fixture-font.py`
/// writes the same shape for the UI spec's seed folder.
pub const FixtureOpts = struct {
    family: []const u8,
    /// Name ID 16; ID 1 when null.
    typographic: ?[]const u8 = null,
    version: ?[]const u8 = null,
    cmap: ?[]const [2]u21 = null,
    /// Wrap the font in a one-font `ttcf` collection.
    collection: bool = false,
    /// The `OTTO` (CFF) magic instead of TrueType's.
    otto: bool = false,
};

pub fn buildFixture(gpa: Allocator, o: FixtureOpts) Allocator.Error![]u8 {
    const Buf = struct {
        list: std.ArrayListUnmanaged(u8) = .empty,
        gpa: Allocator,

        fn be16(b: *@This(), v: u16) Allocator.Error!void {
            var raw: [2]u8 = undefined;
            std.mem.writeInt(u16, &raw, v, .big);
            try b.list.appendSlice(b.gpa, &raw);
        }
        fn be32(b: *@This(), v: u32) Allocator.Error!void {
            var raw: [4]u8 = undefined;
            std.mem.writeInt(u32, &raw, v, .big);
            try b.list.appendSlice(b.gpa, &raw);
        }
        fn bytes(b: *@This(), s: []const u8) Allocator.Error!void {
            try b.list.appendSlice(b.gpa, s);
        }
    };
    // The name table.
    var name_tbl: Buf = .{ .gpa = gpa };
    defer name_tbl.list.deinit(gpa);
    var strings: Buf = .{ .gpa = gpa };
    defer strings.list.deinit(gpa);
    const Rec = struct { id: u16, text: []const u8 };
    var recs: [3]Rec = undefined;
    var n: usize = 0;
    recs[n] = .{ .id = 1, .text = o.family };
    n += 1;
    if (o.typographic) |tf| {
        recs[n] = .{ .id = 16, .text = tf };
        n += 1;
    }
    if (o.version) |v| {
        recs[n] = .{ .id = 5, .text = v };
        n += 1;
    }
    try name_tbl.be16(0);
    try name_tbl.be16(@intCast(n));
    try name_tbl.be16(@intCast(6 + 12 * n));
    for (recs[0..n]) |r| {
        const off: u16 = @intCast(strings.list.items.len);
        for (r.text) |c| try strings.be16(c);
        try name_tbl.be16(3); // Windows
        try name_tbl.be16(1); // Unicode BMP
        try name_tbl.be16(0x409);
        try name_tbl.be16(r.id);
        try name_tbl.be16(@intCast(r.text.len * 2));
        try name_tbl.be16(off);
    }
    try name_tbl.bytes(strings.list.items);
    // The cmap table.
    var cmap_tbl: Buf = .{ .gpa = gpa };
    defer cmap_tbl.list.deinit(gpa);
    if (o.cmap) |ranges| {
        try cmap_tbl.be16(0);
        try cmap_tbl.be16(1);
        try cmap_tbl.be16(3);
        try cmap_tbl.be16(10);
        try cmap_tbl.be32(12);
        try cmap_tbl.be16(12);
        try cmap_tbl.be16(0);
        try cmap_tbl.be32(@intCast(16 + 12 * ranges.len));
        try cmap_tbl.be32(0);
        try cmap_tbl.be32(@intCast(ranges.len));
        for (ranges) |r| {
            try cmap_tbl.be32(r[0]);
            try cmap_tbl.be32(r[1]);
            try cmap_tbl.be32(1);
        }
    }
    const tables: usize = if (o.cmap != null) 2 else 1;
    const base: usize = if (o.collection) 16 else 0;
    const dir_len = 12 + 16 * tables;
    var out: Buf = .{ .gpa = gpa };
    errdefer out.list.deinit(gpa);
    if (o.collection) {
        try out.bytes("ttcf");
        try out.be32(0x00010000);
        try out.be32(1);
        try out.be32(@intCast(base));
    }
    if (o.otto) try out.bytes("OTTO") else try out.be32(0x00010000);
    try out.be16(@intCast(tables));
    try out.be16(16);
    try out.be16(0);
    try out.be16(0);
    var off: usize = base + dir_len;
    // Records sorted by tag, as the spec asks: cmap before name.
    if (o.cmap != null) {
        try out.bytes("cmap");
        try out.be32(0);
        try out.be32(@intCast(off));
        try out.be32(@intCast(cmap_tbl.list.items.len));
        off += cmap_tbl.list.items.len;
    }
    try out.bytes("name");
    try out.be32(0);
    try out.be32(@intCast(off));
    try out.be32(@intCast(name_tbl.list.items.len));
    if (o.cmap != null) try out.bytes(cmap_tbl.list.items);
    try out.bytes(name_tbl.list.items);
    return out.list.toOwnedSlice(gpa);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "the name table: family from ID 16 over ID 1, the version from ID 5; a TTC wrapper and the OTTO magic read the same" {
    const gpa = t.allocator;
    const plain = try buildFixture(gpa, .{ .family = "JetBrainsMono NFM ExtraBold", .typographic = "JetBrainsMono Nerd Font Mono", .version = "Version 2.304;Nerd Fonts 3.5.1" });
    defer gpa.free(plain);
    const names = (try readBytesNames(gpa, plain)) orelse return error.TestUnexpectedResult;
    defer names.deinit(gpa);
    try t.expectEqualStrings("JetBrainsMono Nerd Font Mono", names.family);
    try t.expectEqualStrings("Version 2.304;Nerd Fonts 3.5.1", names.version.?);
    try t.expectEqualStrings("3.5.1", nfVersionFromId5(names.version.?).?);

    const ttc = try buildFixture(gpa, .{ .family = "Symbols Nerd Font Mono", .version = "Version 2.030;ryanoasis Nerd Fonts 3.4.0", .collection = true });
    defer gpa.free(ttc);
    const ttc_names = (try readBytesNames(gpa, ttc)) orelse return error.TestUnexpectedResult;
    defer ttc_names.deinit(gpa);
    try t.expectEqualStrings("Symbols Nerd Font Mono", ttc_names.family);
    try t.expectEqualStrings("3.4.0", nfVersionFromId5(ttc_names.version.?).?);

    const otto = try buildFixture(gpa, .{ .family = "MnmlSymbols", .otto = true });
    defer gpa.free(otto);
    const otto_names = (try readBytesNames(gpa, otto)) orelse return error.TestUnexpectedResult;
    defer otto_names.deinit(gpa);
    try t.expectEqualStrings("MnmlSymbols", otto_names.family);
    try t.expect(otto_names.version == null);

    // Not a font: four bytes of magic and out.
    try t.expect((try readBytesNames(gpa, "%PDF-1.4 not a font at all")) == null);
    try t.expect((try readBytesNames(gpa, "")) == null);
}

test "nfVersionFromId5 anchors on the marker; family grouping and the Nerd Font filter" {
    try t.expectEqualStrings("3.5.1", nfVersionFromId5("Version 3.5.1;Nerd Fonts 3.5.1").?);
    try t.expectEqualStrings("3.4.0", nfVersionFromId5("Version 2.030;ryanoasis Nerd Fonts 3.4.0").?);
    try t.expect(nfVersionFromId5("Version 1.0") == null);
    try t.expect(nfVersionFromId5("Nerd Fonts ") == null);
    try t.expect(isNerdFontFamily("JetBrainsMono Nerd Font Mono"));
    try t.expect(isNerdFontFamily("Hack NFM"));
    try t.expect(isNerdFontFamily("MnmlSymbols"));
    try t.expect(!isNerdFontFamily("Helvetica Neue"));
    try t.expect(!isNerdFontFamily("Nerdy Fonts"));
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("JetBrainsMono Nerd Font", try displayGroup(arena, "JetBrainsMono Nerd Font Mono"));
    try t.expectEqualStrings("JetBrainsMono Nerd Font", try displayGroup(arena, "JetBrainsMono Nerd Font Propo"));
    try t.expectEqualStrings("JetBrainsMono Nerd Font", try displayGroup(arena, "JetBrainsMonoNL NFM"));
    try t.expectEqualStrings("Symbols Nerd Font", try displayGroup(arena, "Symbols Nerd Font Mono"));
    try t.expectEqualStrings("MnmlSymbols", try displayGroup(arena, "MnmlSymbols"));
}

test "the font directories per platform, and MNML_FONT_DIRS in their place" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/u");
    try env.put("USERPROFILE", "C:\\Users\\u");
    try env.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
    const dirs = try fontDirs(arena, &env);
    switch (builtin.os.tag) {
        .macos => {
            try t.expectEqual(@as(usize, 2), dirs.len);
            try t.expectEqualStrings("/home/u/Library/Fonts", dirs[0]);
            try t.expectEqualStrings("/Library/Fonts", dirs[1]);
        },
        .windows => {
            try t.expectEqual(@as(usize, 2), dirs.len);
            try t.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\Microsoft\\Windows\\Fonts", dirs[0]);
            try t.expectEqualStrings("C:\\Windows\\Fonts", dirs[1]);
        },
        else => {
            try t.expectEqual(@as(usize, 4), dirs.len);
            try t.expectEqualStrings("/home/u/.local/share/fonts", dirs[0]);
            try t.expectEqualStrings("/home/u/.fonts", dirs[1]);
            try t.expectEqualStrings("/usr/share/fonts", dirs[2]);
            try t.expectEqualStrings("/usr/local/share/fonts", dirs[3]);
        },
    }
    // The override: the list as given, empty entries dropped, "" = none.
    try env.put("MNML_FONT_DIRS", if (builtin.os.tag == .windows) "D:\\fonts;;E:\\more" else "/tmp/fonts::/opt/more");
    const over = try fontDirs(arena, &env);
    try t.expectEqual(@as(usize, 2), over.len);
    try t.expect(std.mem.endsWith(u8, over[1], "more"));
    try env.put("MNML_FONT_DIRS", "");
    try t.expectEqual(@as(usize, 0), (try fontDirs(arena, &env)).len);
}

test "the cask rule: the symbols face, an override, the CamelCase split, the mnml face" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("brew upgrade --cask font-symbols-only-nerd-font || brew install --cask font-symbols-only-nerd-font", (try updateCommandMacos(arena, "Symbols Nerd Font")).?);
    try t.expectEqualStrings("brew upgrade --cask font-jetbrains-mono-nerd-font || brew install --cask font-jetbrains-mono-nerd-font", (try updateCommandMacos(arena, "JetBrainsMono Nerd Font")).?);
    try t.expectEqualStrings("brew upgrade --cask font-fira-code-nerd-font || brew install --cask font-fira-code-nerd-font", (try updateCommandMacos(arena, "FiraCode Nerd Font")).?);
    try t.expectEqualStrings("brew upgrade --cask font-hack-nerd-font || brew install --cask font-hack-nerd-font", (try updateCommandMacos(arena, "Hack NFM")).?);
    try t.expect((try updateCommandMacos(arena, "MnmlSymbols")) == null);
    try t.expect((try updateCommandMacos(arena, " Nerd Font")) == null);
    if (builtin.os.tag != .macos) try t.expect((try updateCommand(arena, "Hack Nerd Font")) == null);
}

test "a scan groups the weight files of a folder into families and keeps the highest version; the cmap reads back" {
    const gpa = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const files = [_]struct { name: []const u8, o: FixtureOpts }{
        .{ .name = "JetBrainsMonoNerdFont-Regular.ttf", .o = .{ .family = "JetBrainsMono NF", .typographic = "JetBrainsMono Nerd Font", .version = "Version 2.304;Nerd Fonts 3.4.0" } },
        .{ .name = "JetBrainsMonoNerdFontMono-Bold.ttf", .o = .{ .family = "JetBrainsMono NFM Bold", .typographic = "JetBrainsMono Nerd Font Mono", .version = "Version 2.304;Nerd Fonts 3.5.1" } },
        .{ .name = "nested/SymbolsNerdFont-Regular.ttc", .o = .{ .family = "Symbols Nerd Font", .version = "Version 2.030;Nerd Fonts 3.5.1", .collection = true } },
        .{ .name = "MnmlSymbols.ttf", .o = .{ .family = "MnmlSymbols", .cmap = &.{ .{ 0xF1B00, 0xF1B0F }, .{ 0xF1F04, 0xF1F05 } } } },
        .{ .name = "Helvetica.otf", .o = .{ .family = "Helvetica", .otto = true, .version = "Version 1.0" } },
    };
    try tmp.dir.createDirPath(io, "nested");
    for (files) |f| {
        const bytes = try buildFixture(gpa, f.o);
        defer gpa.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = bytes });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not a font" });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const missing = try std.fs.path.join(arena, &.{ root, "no-such-dir" });
    const fams = try scanDirs(arena, gpa, io, &.{ root, missing });
    try t.expectEqual(@as(usize, 3), fams.len);
    try t.expectEqualStrings("JetBrainsMono Nerd Font", fams[0].name);
    try t.expectEqualStrings("3.5.1", fams[0].version.?);
    try t.expectEqualStrings("MnmlSymbols", fams[1].name);
    try t.expect(fams[1].version == null);
    try t.expectEqualStrings("Symbols Nerd Font", fams[2].name);
    try t.expectEqualStrings("3.5.1", fams[2].version.?);
    try t.expect(std.mem.endsWith(u8, fams[2].path, "SymbolsNerdFont-Regular.ttc"));
    var cmap = (try cmapCodepoints(gpa, io, fams[1].path)).?;
    defer cmap.deinit(gpa);
    try t.expectEqual(@as(usize, 18), cmap.count());
    try t.expect(cmap.contains(0xF1B0A));
    try t.expect(cmap.contains(0xF1F05));
    try t.expect(!cmap.contains(0xF1E00));
    // A font without a format-12 subtable has no cmap to speak of.
    try t.expect((try cmapCodepoints(gpa, io, fams[0].path)) == null);
}

test "the cache: fresh within a day, stale after; the release JSON's tag_name loses its v" {
    const gpa = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = (try cachePath(arena, root)).?;
    try t.expect(std.mem.endsWith(u8, path, cache_rel));
    try t.expect((try cachePath(arena, "")) == null);
    try t.expect(latestCached(arena, io, path, 1_000_000) == null);
    try writeCache(gpa, io, path, "3.5.1", 1_000_000);
    try t.expectEqualStrings("3.5.1", latestCached(arena, io, path, 1_000_000 + cache_ttl_secs - 1).?);
    try t.expect(latestCached(arena, io, path, 1_000_000 + cache_ttl_secs) == null);
    try t.expect(latestCached(arena, io, path, 999_999) == null);
    try t.expectEqualStrings("3.5.1", parseLatest(arena, "{\"tag_name\":\"v3.5.1\",\"name\":\"v3.5.1\"}").?);
    try t.expect(parseLatest(arena, "{\"message\":\"rate limited\"}") == null);
}

test "startup: the fixture folder through MNML_FONT_DIRS, the version from the env, the section's rows and chip" {
    const gpa = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    try tmp.dir.createDirPath(io, "fonts");
    const files = [_]struct { name: []const u8, o: FixtureOpts }{
        .{ .name = "fonts/JetBrainsMonoNerdFont-Regular.ttf", .o = .{ .family = "JetBrainsMono Nerd Font", .version = "Version 2.304;Nerd Fonts 3.5.1" } },
        .{ .name = "fonts/SymbolsNerdFont-Regular.ttf", .o = .{ .family = "Symbols Nerd Font", .version = "Version 2.030;Nerd Fonts 3.4.0" } },
        .{ .name = "fonts/MnmlSymbols.ttf", .o = .{ .family = "MnmlSymbols" } },
    };
    for (files) |f| {
        const bytes = try buildFixture(gpa, f.o);
        defer gpa.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = bytes });
    }
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    try env.put("MNML_FONT_DIRS", fonts_dir);
    try env.put("MNML_NERDFONTS_LATEST", "3.5.1");
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 20, .env = &env });
    defer app.deinit();
    // A column wide enough for the header and the rows (the shipped
    // 30 clips them, as Rust's does).
    app.tree.width = 50;
    onStartup(&app, .startup);
    try t.expectEqual(@as(usize, 3), app.fonts.families.len);
    try t.expectEqualStrings("3.5.1", app.fonts.latest.?);
    try t.expect(!app.fonts.fetching);
    const props = (try sectionProps(&app, app.frame.allocator())).?;
    try t.expectEqual(@as(usize, 3), props.rows.len);
    try t.expect(!props.rows[0].updatable);
    try t.expectEqual(builtin.os.tag == .macos, props.rows[2].updatable);
    // The Marketplace tab paints the section under the filter row.
    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    try app.render();
    const text = try @import("../ipc/screen.zig").toTestText(gpa, &app.screen);
    defer gpa.free(text);
    try t.expect(std.mem.indexOf(u8, text, "FONTS · latest Nerd Fonts 3.5.1") != null);
    try t.expect(std.mem.indexOf(u8, text, "JetBrainsMono Nerd Font  v3.5.1 \u{2713}") != null);
    try t.expect(std.mem.indexOf(u8, text, "MnmlSymbols  auto-baked by mnml") != null);
    try t.expect(std.mem.indexOf(u8, text, "Symbols Nerd Font  v3.4.0") != null);
    if (builtin.os.tag == .macos) {
        try t.expect(std.mem.indexOf(u8, text, "\u{2191} Update") != null);
        // The chip is the one `.font_update` hit on the screen.
        var chip_at: ?struct { x: u16, y: u16 } = null;
        var y: u16 = 0;
        while (y < 20) : (y += 1) {
            var x: u16 = 0;
            while (x < 100) : (x += 1) {
                if (app.hits.at(x, y)) |h| if (h == .font_update and chip_at == null) {
                    chip_at = .{ .x = x, .y = y };
                };
            }
        }
        try t.expectEqual(@as(u16, 2), app.hits.at(chip_at.?.x, chip_at.?.y).?.font_update);
        // The chip opens the box; Copy puts the command on the clipboard.
        try app.handle(.{ .mouse = .{ .x = chip_at.?.x, .y = chip_at.?.y, .kind = .press, .button = .left } });
        try t.expect(app.overlay == .confirm);
        try t.expectEqual(@as(u16, 2), app.overlay.confirm.purpose.font_update);
        try updateAccept(&app, 2, 1);
        try t.expect(std.mem.startsWith(u8, app.lastToast().?, "copied: brew upgrade --cask font-symbols-only-nerd-font"));
    }
    // A filter or a scroll hides the section, as Rust's does.
    app.integrations.panel.scroll = 1;
    try app.render();
    const scrolled = try @import("../ipc/screen.zig").toTestText(gpa, &app.screen);
    defer gpa.free(scrolled);
    try t.expect(std.mem.indexOf(u8, scrolled, "FONTS") == null);
}

test "the latest release comes from a local server and lands as one event, cached for the next launch" {
    const gpa = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    try tmp.dir.createDirPath(io, "fonts");
    const bytes = try buildFixture(gpa, .{ .family = "Hack Nerd Font", .version = "Version 3.003;Nerd Fonts 3.4.0" });
    defer gpa.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts/HackNerdFont-Regular.ttf", .data = bytes });
    const routes = [_]marketplace.FakeGitHub.Route{.{ .path = latest_url_path, .body = "{\"tag_name\":\"v3.5.1\"}" }};
    const fake = try marketplace.FakeGitHub.start(gpa, io, &routes);
    defer fake.stop();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    try env.put("MNML_FONT_DIRS", fonts_dir);
    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{fake.port});
    defer gpa.free(base);
    try env.put("MNML_MARKETPLACE_API", base);
    var app = try App.initWith(gpa, io, .{ .workspace = root, .data_root = root, .cols = 60, .rows = 16, .env = &env });
    defer app.deinit();
    onStartup(&app, .startup);
    try t.expect(app.fonts.fetching);
    var waited: u32 = 0;
    while (app.fonts.fetching and waited < 10_000) : (waited += 10) {
        try app.tick(App.nowMs(io));
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(!app.fonts.fetching);
    try t.expectEqualStrings("3.5.1", app.fonts.latest.?);
    // The cache is what the next launch reads.
    const cached = try tmp.dir.readFileAlloc(io, cache_rel, gpa, .limited(4096));
    defer gpa.free(cached);
    try t.expect(std.mem.indexOf(u8, cached, "\"version\":\"3.5.1\"") != null);
    try t.expectEqualStrings("3.5.1", latestCached(app.frame.allocator(), io, (try cachePath(app.frame.allocator(), root)).?, nowEpoch(io)).?);
}
