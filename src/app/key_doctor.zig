//! The keyboard doctor — the terminal-side facts behind the wizard's
//! Keyboard section and `keys.doctor`: which terminal this is, what to
//! tell the user about a chord that never arrived, and the one fix
//! mnml applies itself (Rust `key_doctor.rs`).
//!
//! Only ghostty gets an auto-fix: mnml knows its config path and its
//! line grammar, so `macos-option-as-alt = true` can be written without
//! guessing. Every other terminal gets instructions (`remedy`). The
//! config is line-oriented `key = value`, not ZON or TOML, so the fix is
//! a targeted text edit (`rewriteOptionAsAlt`, pure and tested) that
//! keeps every other line and comment; a timestamped backup lands
//! beside the file first. What the edit did is reported as a
//! `FixOutcome` so the UI can say something true — "already set" must
//! not read as "fixed".
//!
//! API (for the wizard, and for a `keys.doctor` runner):
//! - `detectTerminal(env)` / `detectTerminalFrom(...)`, `underMultiplexer(env)`
//! - `remedy(probe, terminal, is_macos)` — the advice, and its `AutoFix` when one exists
//! - `ghosttyConfigPath(arena, env)` — where the fix goes
//! - `applyGhosttyOptionAsAlt(gpa, io, path)` — the fix, with its `FixOutcome`
//! - `fixNote(buf, ...)` — the one-line result the wizard shows under the row

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const persist = @import("../config/persist.zig");
const ghostty_config = @import("ghostty_config.zig");

/// Terminals with specific advice.
pub const Terminal = enum {
    ghostty,
    iterm2,
    apple_terminal,
    kitty,
    wezterm,
    alacritty,
    windows_terminal,
    unknown,

    pub fn label(term: Terminal) []const u8 {
        return switch (term) {
            .ghostty => "ghostty",
            .iterm2 => "iTerm2",
            .apple_terminal => "Terminal.app",
            .kitty => "kitty",
            .wezterm => "WezTerm",
            .alacritty => "Alacritty",
            .windows_terminal => "Windows Terminal",
            .unknown => "this terminal",
        };
    }
};

/// The host terminal from what it advertises. This is the outermost
/// thing visible: under tmux or ssh the variables describe whatever is
/// nearest, which is why `underMultiplexer` is reported apart.
pub fn detectTerminalFrom(term_program: ?[]const u8, term: ?[]const u8, kitty_window: bool, wt_session: bool) Terminal {
    const tp = term_program orelse "";
    if (std.ascii.eqlIgnoreCase(tp, "ghostty")) return .ghostty;
    if (std.ascii.eqlIgnoreCase(tp, "iterm.app")) return .iterm2;
    if (std.ascii.eqlIgnoreCase(tp, "apple_terminal")) return .apple_terminal;
    if (std.ascii.eqlIgnoreCase(tp, "wezterm")) return .wezterm;
    if (kitty_window) return .kitty;
    if (wt_session) return .windows_terminal;
    const tn = term orelse "";
    if (std.ascii.indexOfIgnoreCase(tn, "kitty") != null) return .kitty;
    if (std.ascii.indexOfIgnoreCase(tn, "alacritty") != null) return .alacritty;
    return .unknown;
}

pub fn detectTerminal(env: *const std.process.Environ.Map) Terminal {
    return detectTerminalFrom(env.get("TERM_PROGRAM"), env.get("TERM"), env.get("KITTY_WINDOW_ID") != null, env.get("WT_SESSION") != null);
}

pub fn underMultiplexer(env: *const std.process.Environ.Map) bool {
    return env.get("TMUX") != null or env.get("STY") != null;
}

/// A chord family the doctor has advice for.
pub const Probe = enum { ctrl_right, alt_right, cmd_right, end };

/// A fix mnml can apply itself. Deliberately tiny: only where the
/// config format AND its path are unambiguous.
pub const AutoFix = enum {
    /// `macos-option-as-alt = true` in ghostty's config: Option+←/→ (and
    /// every other Alt chord) in one line.
    ghostty_option_as_alt,
};

pub const Remedy = struct { text: []const u8, fix: ?AutoFix = null };

/// Advice for a chord that never arrived.
pub fn remedy(probe: Probe, term: Terminal, macos: bool) Remedy {
    return switch (probe) {
        .ctrl_right => if (macos) .{ .text = "macOS binds Ctrl+←/→ to Mission Control's \"move left/right a space\" whenever you have more than one Space, so it never reaches the terminal. Free it in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. Option+←/→ is the macOS-native word-motion chord and needs no system change — prefer it if it ticks above." } else .{ .text = "Ctrl+←/→ is normally forwarded on this platform. Check your terminal or window manager for a conflicting global shortcut." },
        .alt_right => switch (term) {
            .ghostty => if (macos) .{ .text = "Ghostty defaults to using Option for special characters (Option+e → é) rather than sending Alt. Adding `macos-option-as-alt = true` to ~/.config/ghostty/config forwards it — this unlocks Option+←/→ and every other Alt chord. Restart ghostty afterwards.", .fix = .ghostty_option_as_alt } else .{ .text = "Alt+←/→ isn't arriving. Check your terminal's key-encoding settings, or use Ctrl+←/→ instead." },
            .iterm2 => .{ .text = "iTerm2 defaults Left Option to \"Normal\". Set Settings → Profiles → Keys → Left Option key = \"Esc+\" to send Alt." },
            .apple_terminal => .{ .text = "Terminal.app: Settings → Profiles → Keyboard → tick \"Use Option as Meta key\"." },
            else => if (macos) .{ .text = "On macOS most terminals use Option to compose special characters rather than sending Alt. Look for an \"Option as Meta/Alt\" setting in your terminal's preferences." } else .{ .text = "Alt+←/→ isn't arriving. Check your terminal's key-encoding settings, or use Ctrl+←/→ instead." },
        },
        .cmd_right => if (macos) .{ .text = "Most terminals reserve Cmd for their own shortcuts and never forward it. This one is optional — Home/End cover line motion, and on a MacBook that's Fn+←/→." } else .{ .text = "Cmd only exists on macOS — nothing to fix here." },
        .end => .{ .text = "This chord didn't arrive. If even End is missing, keys aren't reaching mnml at all." },
    };
}

/// What `applyGhosttyOptionAsAlt` did.
pub const FixOutcome = enum {
    /// Already `true` — nothing written. The chord fails for another
    /// reason (or ghostty needs restarting).
    already_set,
    /// An explicit `= false` (or another value) flipped to `true`.
    flipped,
    /// The key was absent; appended with a breadcrumb comment.
    appended,
};

pub const option_as_alt_key = "macos-option-as-alt";

const breadcrumb =
    \\
    \\# Added by mnml (keys.doctor): send Option as Alt so
    \\# Option+←/→ reaches the app as a word-motion chord.
    \\# Without this, Option composes special characters instead.
    \\
;

pub const Rewrite = struct { outcome: FixOutcome, text: []const u8 };

/// The new text of a ghostty config with `macos-option-as-alt = true`
/// in it, everything else kept: an uncommented assignment of the key is
/// flipped in place; a missing one is appended after a breadcrumb.
pub fn rewriteOptionAsAlt(arena: Allocator, existing: []const u8) Allocator.Error!Rewrite {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var hit = false;
    var it = std.mem.splitScalar(u8, existing, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const tl = std.mem.trim(u8, line, " \t\r");
        if (!hit and !std.mem.startsWith(u8, tl, "#")) if (std.mem.indexOfScalar(u8, tl, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, tl[0..eq], " \t"), option_as_alt_key)) {
                hit = true;
                const val = std.mem.trim(u8, tl[eq + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(val, "true")) return .{ .outcome = .already_set, .text = existing };
                try out.appendSlice(arena, option_as_alt_key ++ " = true");
                continue;
            }
        };
        try out.appendSlice(arena, line);
    }
    if (hit) {
        if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
        return .{ .outcome = .flipped, .text = out.items };
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
    try out.appendSlice(arena, breadcrumb);
    try out.appendSlice(arena, option_as_alt_key ++ " = true\n");
    return .{ .outcome = .appended, .text = out.items };
}

/// Where the fix goes: the first ghostty config that exists, else the
/// first place ghostty would read one (`$XDG_CONFIG_HOME/ghostty/config`,
/// then `~/.config/ghostty/config`). Null without a home.
pub fn ghosttyConfigPath(arena: Allocator, io: Io, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    const cands = try ghostty_config.candidates(arena, env);
    if (cands.len == 0) return null;
    for (cands) |p| {
        Io.Dir.cwd().access(io, p, .{}) catch continue;
        return p;
    }
    return cands[0];
}

pub const ApplyError = error{ OutOfMemory, WriteFailed };

/// What `applyGhosttyOptionAsAlt` was asked to do and what came of it.
pub const Applied = struct { path: []const u8, outcome: ApplyError!FixOutcome };

/// Set `macos-option-as-alt = true` in the ghostty config at `path`,
/// preserving everything else; a `<path>.pre-mnml-<stamp>` backup is
/// written first when the file exists. Nothing is written when the key
/// is already `true`.
pub fn applyGhosttyOptionAsAlt(gpa: Allocator, io: Io, path: []const u8) ApplyError!FixOutcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const existing: ?[]const u8 = cwd.readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch null;
    const rw = try rewriteOptionAsAlt(arena, existing orelse "");
    if (rw.outcome == .already_set) return rw.outcome;
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch return error.WriteFailed;
    if (existing) |prev| {
        var stamp: [17]u8 = undefined;
        persist.formatStamp(&stamp, Io.Timestamp.now(io, .real).toSeconds());
        const backup = try std.fmt.allocPrint(arena, "{s}.pre-mnml-{s}", .{ path, stamp });
        cwd.writeFile(io, .{ .sub_path = backup, .data = prev }) catch {}; // best effort
    }
    cwd.writeFile(io, .{ .sub_path = path, .data = rw.text }) catch return error.WriteFailed;
    return rw.outcome;
}

/// What happened, in one line for the wizard's Keyboard row. `alt_seen`
/// is whether an Option/Alt chord already ticked — then there is
/// nothing to fix. Truncated to `buf` with an ellipsis.
pub fn fixNote(buf: []u8, alt_seen: bool, term: Terminal, macos: bool, result: ?Applied) []const u8 {
    if (alt_seen) return fit(buf, "Option+→ already arrives — nothing to fix.", .{});
    if (remedy(.alt_right, term, macos).fix != .ghostty_option_as_alt) return fit(buf, "No auto-fix for {s} — see the note above.", .{term.label()});
    const r = result orelse return fit(buf, "Couldn't locate ~/.config/ghostty/config.", .{});
    const outcome = r.outcome catch |err| return fit(buf, "Couldn't write {s}: {s}", .{ r.path, @errorName(err) });
    return switch (outcome) {
        .already_set => fit(buf, "{s} already has macos-option-as-alt = true — restart ghostty for it to take effect.", .{r.path}),
        .flipped => fit(buf, "Flipped macos-option-as-alt to true in {s}. Restart ghostty.", .{r.path}),
        .appended => fit(buf, "Added macos-option-as-alt = true to {s} (original backed up). Restart ghostty.", .{r.path}),
    };
}

fn fit(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch truncated(buf, fmt, args);
}

fn truncated(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    // Render into a scratch and cut at a UTF-8 boundary with room for `…`.
    var scratch: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&scratch, fmt, args) catch scratch[0..];
    const ell = "\u{2026}";
    if (buf.len < ell.len) return buf[0..0];
    var cut = @min(full.len, buf.len - ell.len);
    while (cut > 0 and (full[cut] & 0xC0) == 0x80) cut -= 1;
    @memcpy(buf[0..cut], full[0..cut]);
    @memcpy(buf[cut .. cut + ell.len], ell);
    return buf[0 .. cut + ell.len];
}

pub const host_is_macos = builtin.os.tag == .macos;

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "terminal detection: TERM_PROGRAM first, then the kitty and Windows Terminal markers, then TERM; case-insensitive" {
    try t.expectEqual(Terminal.ghostty, detectTerminalFrom("ghostty", "xterm-ghostty", false, false));
    try t.expectEqual(Terminal.ghostty, detectTerminalFrom("Ghostty", null, false, false));
    try t.expectEqual(Terminal.iterm2, detectTerminalFrom("iTerm.app", null, false, false));
    try t.expectEqual(Terminal.apple_terminal, detectTerminalFrom("Apple_Terminal", null, false, false));
    try t.expectEqual(Terminal.wezterm, detectTerminalFrom("WezTerm", null, false, false));
    try t.expectEqual(Terminal.kitty, detectTerminalFrom(null, "xterm-256color", true, false));
    try t.expectEqual(Terminal.windows_terminal, detectTerminalFrom(null, null, false, true));
    try t.expectEqual(Terminal.kitty, detectTerminalFrom(null, "xterm-kitty", false, false));
    try t.expectEqual(Terminal.alacritty, detectTerminalFrom(null, "alacritty", false, false));
    try t.expectEqual(Terminal.unknown, detectTerminalFrom(null, "xterm-256color", false, false));
    // From an environment map.
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try t.expectEqual(Terminal.unknown, detectTerminal(&env));
    try env.put("TERM_PROGRAM", "ghostty");
    try t.expectEqual(Terminal.ghostty, detectTerminal(&env));
    try t.expect(!underMultiplexer(&env));
    try env.put("TMUX", "/tmp/tmux-501/default,1,0");
    try t.expect(underMultiplexer(&env));
}

test "remedy: only ghostty on macOS carries the auto-fix; every other terminal gets words" {
    try t.expectEqual(AutoFix.ghostty_option_as_alt, remedy(.alt_right, .ghostty, true).fix.?);
    try t.expect(remedy(.alt_right, .ghostty, false).fix == null);
    try t.expect(remedy(.alt_right, .iterm2, true).fix == null);
    try t.expect(std.mem.indexOf(u8, remedy(.alt_right, .iterm2, true).text, "Esc+") != null);
    try t.expect(std.mem.indexOf(u8, remedy(.alt_right, .apple_terminal, true).text, "Meta") != null);
    try t.expect(remedy(.alt_right, .unknown, true).fix == null);
    try t.expect(std.mem.indexOf(u8, remedy(.ctrl_right, .ghostty, true).text, "Mission Control") != null);
    try t.expect(remedy(.cmd_right, .ghostty, false).fix == null);
}

test "rewriteOptionAsAlt: already true is untouched; false flips in place keeping the rest; a missing key is appended after a breadcrumb; a commented key does not count" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const set = "font-family = X\nmacos-option-as-alt = True\n";
    const a = try rewriteOptionAsAlt(arena, set);
    try t.expectEqual(FixOutcome.already_set, a.outcome);
    try t.expectEqualStrings(set, a.text);

    const off = "# theirs\nfont-family = X\n  macos-option-as-alt=false  \ntheme = dark";
    const b = try rewriteOptionAsAlt(arena, off);
    try t.expectEqual(FixOutcome.flipped, b.outcome);
    try t.expectEqualStrings("# theirs\nfont-family = X\nmacos-option-as-alt = true\ntheme = dark\n", b.text);

    const missing = "font-family = X\n# macos-option-as-alt = true\n";
    const c = try rewriteOptionAsAlt(arena, missing);
    try t.expectEqual(FixOutcome.appended, c.outcome);
    try t.expect(std.mem.startsWith(u8, c.text, missing));
    try t.expect(std.mem.indexOf(u8, c.text, "# Added by mnml (keys.doctor)") != null);
    try t.expect(std.mem.endsWith(u8, c.text, "macos-option-as-alt = true\n"));

    // An empty file: just the breadcrumb and the line.
    const d = try rewriteOptionAsAlt(arena, "");
    try t.expectEqual(FixOutcome.appended, d.outcome);
    try t.expect(std.mem.startsWith(u8, d.text, "\n# Added by mnml"));
    // A file without a trailing newline gets one before the breadcrumb.
    const e = try rewriteOptionAsAlt(arena, "font-family = X");
    try t.expect(std.mem.startsWith(u8, e.text, "font-family = X\n\n# Added"));
}

test "applyGhosttyOptionAsAlt: writes the file (creating the directory), backs the original up beside it, and says which outcome; the path resolves from the environment" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", root);

    // No config anywhere: the first candidate, its directory made.
    const path = (try ghosttyConfigPath(arena, io, &env)).?;
    try t.expect(sdk_testing.pathEndsWith(path, ".config/ghostty/config"));
    try t.expectEqual(FixOutcome.appended, try applyGhosttyOptionAsAlt(t.allocator, io, path));
    const written = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(65536));
    try t.expect(std.mem.endsWith(u8, written, "macos-option-as-alt = true\n"));
    // Again: already set, nothing rewritten.
    try t.expectEqual(FixOutcome.already_set, try applyGhosttyOptionAsAlt(t.allocator, io, path));

    // An explicit false flips, and the original is backed up beside it.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "theme = dark\nmacos-option-as-alt = false\n" });
    try t.expectEqual(FixOutcome.flipped, try applyGhosttyOptionAsAlt(t.allocator, io, path));
    const flipped = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(65536));
    try t.expectEqualStrings("theme = dark\nmacos-option-as-alt = true\n", flipped);
    var dir = try tmp.dir.openDir(io, ".config/ghostty", .{ .iterate = true });
    defer dir.close(io);
    var backups: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| if (std.mem.startsWith(u8, e.name, "config.pre-mnml-")) {
        backups += 1;
    };
    try t.expect(backups >= 1);

    // XDG first, and an existing file wins over the default place.
    try tmp.dir.createDirPath(io, "xdg/ghostty");
    try tmp.dir.writeFile(io, .{ .sub_path = "xdg/ghostty/config", .data = "" });
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(arena, &.{ root, "xdg" }));
    try t.expect(sdk_testing.pathEndsWith((try ghosttyConfigPath(arena, io, &env)).?, "xdg/ghostty/config"));
}

test "fixNote: the sentence names what happened; a long path is cut with an ellipsis" {
    var buf: [200]u8 = undefined;
    try t.expectEqualStrings("Option+→ already arrives — nothing to fix.", fixNote(&buf, true, .ghostty, true, null));
    try t.expectEqualStrings("No auto-fix for iTerm2 — see the note above.", fixNote(&buf, false, .iterm2, true, null));
    try t.expectEqualStrings("Couldn't locate ~/.config/ghostty/config.", fixNote(&buf, false, .ghostty, true, null));
    try t.expectEqualStrings("Flipped macos-option-as-alt to true in /h/.config/ghostty/config. Restart ghostty.", fixNote(&buf, false, .ghostty, true, .{ .path = "/h/.config/ghostty/config", .outcome = .flipped }));
    try t.expect(std.mem.startsWith(u8, fixNote(&buf, false, .ghostty, true, .{ .path = "/h/.config/ghostty/config", .outcome = .appended }), "Added macos-option-as-alt = true to /h/"));
    try t.expectEqualStrings("Couldn't write /h/config: WriteFailed", fixNote(&buf, false, .ghostty, true, .{ .path = "/h/config", .outcome = error.WriteFailed }));
    var small: [24]u8 = undefined;
    const cut = fixNote(&small, false, .ghostty, true, .{ .path = "/a/very/long/path/to/ghostty/config", .outcome = .flipped });
    try t.expect(std.mem.endsWith(u8, cut, "\u{2026}"));
    try t.expect(cut.len <= small.len);
}
