//! The now-playing cluster in the statusline's right lane — the Rust
//! row's `󱼀 󰐎` beside the coverage chip. At rest it is the brand mark of
//! the preferred player (`ui.preferred_music_app`: mnml's baked Beatport
//! B for mixr, nf-fa-apple for Music, nf-fa-spotify for Spotify) and
//! nf-md-play_box_outline, on the player's colour. With a track loaded
//! it is the transport: play / pause, skip, and the title (`Artist -
//! Title` for a macOS player, the track as mixr wrote it), cut at 28
//! cells with an ellipsis — or scrolled, `ui.now_playing_marquee`.
//!
//! What plays comes from a poller the terminal loop runs every three
//! seconds (`ui.now_playing_source`): mixr's `~/.mixr/quick.txt` when
//! fresh, `osascript` asking Music then Spotify on macOS, both under
//! `auto` (the playing one wins). A mixr track sticks for ten seconds
//! across the empty reads mixr writes between songs. Headless runs and
//! tests start no poller: the chip paints its idle form, as the Rust
//! dumps show it — unless `MNML_NOW_PLAYING` says otherwise:
//!
//!     MNML_NOW_PLAYING="<track>|playing|<source>|<detail>"
//!
//! `<track>` and the state (`playing` / `paused`) are required; the
//! source (`mixr` / `music` / `spotify`, default mixr) and the detail
//! (the artist) are optional; an empty value is the idle form. A
//! `.test` sets it with a `# env: MNML_NOW_PLAYING=…` header line.
//!
//! Clicks are the Rust arm's: the transport chips drive the player
//! (`osascript` for Music / Spotify; mixr's IPC is cut — a toast says
//! so), the title or the brand opens it (`mixr.show`, or `activate`),
//! the idle play chip starts it (`mixr.play_now` / `playpause`), and
//! the right button is the player menu with the preferred-app radio
//! rows — `mixr.set_preferred_*` live here and write the config.
//!
//! // changed: the poller is an `Io.Group` task handing a fixed-size
//! `Track` through a mutex (no allocation off the main task); the
//! override and the `--ascii` twins are Zig's; the transport IPC to mixr
//! is cut with the rest of the mixr runners (docs/PARITY.md).

const std = @import("std");
const builtin = @import("builtin");
const repeat = @import("mnml_sdk").zig_compat.repeat;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const os_path = @import("../core/os_path.zig");
const CommandError = command.CommandError;
const Config = @import("../config/Config.zig");
const settings = @import("settings.zig");
const event = @import("../core/event.zig");

pub const Source = enum {
    mixr,
    music,
    spotify,
    /// A macOS player that named itself something else.
    other,

    pub fn parse(s: []const u8) Source {
        if (std.ascii.eqlIgnoreCase(s, "mixr")) return .mixr;
        if (std.ascii.eqlIgnoreCase(s, "music")) return .music;
        if (std.ascii.eqlIgnoreCase(s, "spotify")) return .spotify;
        return .other;
    }

    /// The name `osascript` addresses.
    pub fn appName(s: Source) []const u8 {
        return switch (s) {
            .mixr => "mixr",
            .music => "Music",
            .spotify => "Spotify",
            .other => "",
        };
    }

    pub fn ofPreferred(p: Config.MusicApp) Source {
        return switch (p) {
            .mixr => .mixr,
            .music => .music,
            .spotify => .spotify,
        };
    }
};

/// The longest title or detail kept; longer ones are cut at a
/// codepoint boundary.
pub const max_text = 192;

/// What a player reports. Fixed buffers so the poller hands it over
/// without allocating.
pub const Track = struct {
    source: Source = .mixr,
    playing: bool = false,
    track_buf: [max_text]u8 = undefined,
    track_len: usize = 0,
    detail_buf: [max_text]u8 = undefined,
    detail_len: usize = 0,

    pub fn init(source: Source, playing: bool, title: []const u8, extra: []const u8) Track {
        var out: Track = .{ .source = source, .playing = playing };
        out.track_len = copyClipped(&out.track_buf, title);
        out.detail_len = copyClipped(&out.detail_buf, extra);
        return out;
    }

    pub fn track(self: *const Track) []const u8 {
        return self.track_buf[0..self.track_len];
    }

    pub fn detail(self: *const Track) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    pub fn hasTrack(self: *const Track) bool {
        return self.track_len > 0;
    }
};

fn copyClipped(buf: *[max_text]u8, s: []const u8) usize {
    var n = @min(s.len, max_text);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

/// `poll` runs this often.
pub const poll_ms: i64 = 3000;
/// mixr's `quick.txt` older than this is not a reading.
pub const mixr_stale_secs: i64 = 10;
/// A mixr track outlives an empty read for this long.
pub const mixr_sticky_ms: i64 = 10_000;
/// The marquee advances a cell this often (~3.3 cells/s, as Rust).
pub const marquee_step_ms: i64 = 300;
/// The label's width before it is cut or scrolled.
pub const label_max: usize = 28;

pub const State = struct {
    /// What the row shows; null is the idle form.
    current: ?Track = null,
    /// The env override, read on the first tick.
    started: bool = false,
    /// `MNML_NOW_PLAYING` was set: no poller, the override stands.
    overridden: bool = false,
    group: Io.Group = .init,
    mutex: Io.Mutex = .init,
    /// The poller's latest reading until `tick` takes it.
    latest: ?Reading = null,
    /// When the last non-empty mixr read landed, for the sticky rule.
    last_mixr_track_ms: ?i64 = null,
    marquee_offset: usize = 0,
    marquee_next_ms: i64 = 0,

    pub fn deinit(self: *State, io: Io) void {
        self.group.cancel(io);
    }

    fn put(self: *State, io: Io, r: Reading) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.latest = r;
    }

    fn take(self: *State, io: Io) ?Reading {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const r = self.latest;
        self.latest = null;
        return r;
    }
};

/// One poll's answer: a track, or none from the source.
pub const Reading = struct { track: ?Track };

// ─── the override ────────────────────────────────────────────────────────

/// `MNML_NOW_PLAYING`'s value as a track; null for an empty or
/// unparsable one (the idle form).
pub fn parseOverride(value: []const u8) ?Track {
    var it = std.mem.splitScalar(u8, value, '|');
    const title = std.mem.trim(u8, it.next() orelse return null, " \t");
    if (title.len == 0) return null;
    const state = std.mem.trim(u8, it.next() orelse "", " \t");
    const playing = std.ascii.eqlIgnoreCase(state, "playing");
    if (!playing and !std.ascii.eqlIgnoreCase(state, "paused")) return null;
    const source = if (it.next()) |s| (if (std.mem.trim(u8, s, " \t").len == 0) Source.mixr else Source.parse(std.mem.trim(u8, s, " \t"))) else Source.mixr;
    const detail = std.mem.trim(u8, it.next() orelse "", " \t");
    return Track.init(source, playing, title, detail);
}

// ─── the tick ────────────────────────────────────────────────────────────

/// Once: the override, else the poller in a real terminal. Every tick:
/// take the poller's reading, advance the marquee.
pub fn tick(app: *App, now: i64) void {
    const st = &app.now_playing;
    if (!st.started) {
        st.started = true;
        if (app.env.get("MNML_NOW_PLAYING")) |v| {
            st.overridden = true;
            st.current = parseOverride(v);
            app.needs_render = true;
        } else if (app.native_notify) {
            start(app);
        }
    }
    if (st.take(app.io)) |r| {
        const merged = merge(st, r.track, now);
        const changed = !sameTrack(st.current, merged);
        st.current = merged;
        if (changed) {
            st.marquee_offset = 0;
            app.needs_render = true;
        }
    }
    if (app.cfg.ui.now_playing_marquee) if (st.current) |*t| if (t.hasTrack()) {
        if (now >= st.marquee_next_ms) {
            st.marquee_next_ms = now + marquee_step_ms;
            st.marquee_offset +%= 1;
            app.needs_render = true;
        }
    };
}

/// The marquee wants a frame at its next step while a label scrolls.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.now_playing;
    if (!app.cfg.ui.now_playing_marquee) return null;
    const t = st.current orelse return null;
    if (!t.hasTrack()) return null;
    return st.marquee_next_ms;
}

fn sameTrack(a: ?Track, b: ?Track) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.source == y.source and x.playing == y.playing and std.mem.eql(u8, x.track(), y.track()) and std.mem.eql(u8, x.detail(), y.detail());
}

/// Rust's stickiness: an empty mixr read within ten seconds of a real
/// one keeps the previous track on the row.
fn merge(st: *State, new: ?Track, now: i64) ?Track {
    const is_mixr = if (new) |t| t.source == .mixr else false;
    const empty = if (new) |t| !t.hasTrack() else true;
    if (is_mixr and !empty) {
        st.last_mixr_track_ms = now;
        return new;
    }
    if (is_mixr) if (st.last_mixr_track_ms) |at| if (now - at <= mixr_sticky_ms) {
        if (st.current) |cur| if (cur.source == .mixr and cur.hasTrack()) return cur;
    };
    return new;
}

// ─── the poller ──────────────────────────────────────────────────────────

fn start(app: *App) void {
    const st = &app.now_playing;
    st.group.cancel(app.io);
    // `HOME`, else `USERPROFILE`: mixr's `~/.mixr/quick.txt` on Windows too.
    const home = os_path.home(&app.env) orelse "";
    st.group.concurrent(app.io, worker, .{ st, app.events, app.io, app.cfg.ui.now_playing_source, home }) catch {};
}

fn worker(st: *State, events: *event.EventQueue, io: Io, source: Config.NowPlayingSource, home: []const u8) Io.Cancelable!void {
    while (true) {
        const t = poll(io, source, home) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        st.put(io, .{ .track = t });
        events.post(io, .timer);
        try io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
}

/// One reading from the configured source.
pub fn poll(io: Io, source: Config.NowPlayingSource, home: []const u8) Io.Cancelable!?Track {
    return switch (source) {
        .mixr => try pollMixr(io, home),
        .macos => try pollMacos(io, home),
        .auto => blk: {
            const m = try pollMixr(io, home);
            if (m) |t| if (t.playing) break :blk m;
            const mac = try pollMacos(io, home);
            if (mac) |t| if (t.playing) break :blk mac;
            break :blk m orelse mac;
        },
    };
}

fn pollMixr(io: Io, home: []const u8) Io.Cancelable!?Track {
    if (home.len == 0) return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.mixr/quick.txt", .{home}) catch return null;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    const now = Io.Timestamp.now(io, .real).toSeconds();
    if (now - st.mtime.toSeconds() > mixr_stale_secs) return null;
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, path, &buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    return projectMixr(text);
}

/// mixr's `quick.txt`: `playing=`, `playing_bpm=`, `playing_active=`
/// lines; `—` is none.
pub fn projectMixr(text: []const u8) Track {
    var track: []const u8 = "";
    var bpm: []const u8 = "";
    var active: ?bool = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, val, "—")) val = "";
        if (std.mem.eql(u8, key, "playing")) {
            track = val;
        } else if (std.mem.eql(u8, key, "playing_bpm")) {
            bpm = val;
        } else if (std.mem.eql(u8, key, "playing_active")) {
            active = std.ascii.eqlIgnoreCase(val, "true");
        }
    }
    return Track.init(.mixr, active orelse (track.len > 0), track, bpm);
}

const music_script =
    \\set np to ""
    \\try
    \\    if application "Music" is running then
    \\        tell application "Music"
    \\            if player state is playing then
    \\                set np to "Music" & tab & (name of current track) & tab & (artist of current track)
    \\            end if
    \\        end tell
    \\    end if
    \\end try
    \\return np
;

const spotify_script =
    \\set np to ""
    \\try
    \\    if application "Spotify" is running then
    \\        tell application "Spotify"
    \\            if player state is playing then
    \\                set np to "Spotify" & tab & (name of current track) & tab & (artist of current track)
    \\            end if
    \\        end tell
    \\    end if
    \\end try
    \\return np
;

fn appInstalled(io: Io, name: []const u8, home: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const roots = [_][]const u8{ "/Applications", "/System/Applications", home };
    for (roots, 0..) |root, i| {
        if (i == 2 and home.len == 0) continue;
        const p = (if (i == 2) std.fmt.bufPrint(&buf, "{s}/Applications/{s}.app", .{ root, name }) else std.fmt.bufPrint(&buf, "{s}/{s}.app", .{ root, name })) catch continue;
        Io.Dir.cwd().access(io, p, .{}) catch continue;
        return true;
    }
    return false;
}

fn pollMacos(io: Io, home: []const u8) Io.Cancelable!?Track {
    if (builtin.os.tag != .macos) return null;
    var out: [1024]u8 = undefined;
    if (appInstalled(io, "Music", home)) {
        if (parseMacos(try runScript(io, music_script, &out))) |t| return t;
    }
    if (appInstalled(io, "Spotify", home)) {
        if (parseMacos(try runScript(io, spotify_script, &out))) |t| return t;
    }
    return null;
}

/// `osascript -e <script>`'s stdout, trimmed; empty on any failure.
fn runScript(io: Io, script: []const u8, out: *[1024]u8) Io.Cancelable![]const u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "osascript", "-e", script },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return "",
    };
    defer child.kill(io);
    var rbuf: [1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &rbuf);
    var w: Io.Writer = .fixed(out);
    _ = reader.interface.streamRemaining(&w) catch {};
    _ = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
    return std.mem.trim(u8, w.buffered(), " \t\r\n");
}

/// `App<TAB>Track<TAB>Artist` → a playing track; null for an empty line.
pub fn parseMacos(line: []const u8) ?Track {
    const l = std.mem.trim(u8, line, " \t\r\n");
    if (l.len == 0) return null;
    var it = std.mem.splitScalar(u8, l, '\t');
    const app_name = std.mem.trim(u8, it.next() orelse "", " \t");
    const track = std.mem.trim(u8, it.next() orelse "", " \t");
    const artist = std.mem.trim(u8, it.next() orelse "", " \t");
    if (track.len == 0) return null;
    return Track.init(Source.parse(app_name), true, track, artist);
}

// ─── the label ───────────────────────────────────────────────────────────

/// The transport's title: the track alone for mixr or without a detail,
/// else `detail - track`, runs of whitespace folded to one space.
pub fn rawLabel(arena: Allocator, t: *const Track) Allocator.Error![]const u8 {
    const joined = if (t.source == .mixr or t.detail_len == 0) try arena.dupe(u8, t.track()) else try std.fmt.allocPrint(arena, "{s} - {s}", .{ t.detail(), t.track() });
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, joined, " \t\r\n");
    while (it.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.items;
}

/// The label as the row shows it: whole when it fits `label_max`
/// codepoints, else the first 28 and `…` — or, with the marquee on, a
/// 28-codepoint window from `offset` over the label and three cells of
/// gap.
pub fn shownLabel(arena: Allocator, raw: []const u8, marquee: bool, offset: usize) Allocator.Error![]const u8 {
    const n = std.unicode.utf8CountCodepoints(raw) catch raw.len;
    if (n <= label_max) return raw;
    var cps: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(raw).iterator();
    while (it.nextCodepointSlice()) |cp| try cps.append(arena, cp);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (marquee) {
        try cps.appendSlice(arena, &.{ " ", " ", " " });
        const loop_len = cps.items.len;
        const off = offset % loop_len;
        var i: usize = 0;
        while (i < label_max) : (i += 1) try out.appendSlice(arena, cps.items[(off + i) % loop_len]);
    } else {
        for (cps.items[0..label_max]) |cp| try out.appendSlice(arena, cp);
        try out.appendSlice(arena, "…");
    }
    return out.items;
}

// ─── clicks ──────────────────────────────────────────────────────────────

/// The track's player, else the preferred one.
fn playerOf(app: *const App) Source {
    if (app.now_playing.current) |t| if (t.hasTrack()) return t.source;
    return Source.ofPreferred(app.cfg.ui.preferred_music_app);
}

const mixr_cut = "mixr transport is cut from mnml 0.3 (docs/PARITY.md § UI & theming)";

/// The play / pause chip: `playpause` for a macOS player; mixr's IPC
/// is cut. Idle: the preferred player starts (`mixr.play_now` for mixr).
pub fn clickPlay(app: *App) CommandError!void {
    const has = if (app.now_playing.current) |t| t.hasTrack() else false;
    const player = playerOf(app);
    switch (player) {
        .music, .spotify => try tellPlayer(app, player, "playpause"),
        .mixr => if (has) app.toast("{s}", .{mixr_cut}) else try command.run(app, .{ .static = .@"mixr.play_now" }),
        .other => {},
    }
}

/// The skip chip: `next track` for a macOS player; mixr's teleport is cut.
pub fn clickNext(app: *App) CommandError!void {
    const player = playerOf(app);
    switch (player) {
        .music, .spotify => try tellPlayer(app, player, "next track"),
        .mixr => app.toast("{s}", .{mixr_cut}),
        .other => {},
    }
}

/// The title or the brand: the player comes forward — `mixr.show`, or
/// `activate` for a macOS player.
pub fn clickLabel(app: *App) CommandError!void {
    const player = playerOf(app);
    switch (player) {
        .music, .spotify => try tellPlayer(app, player, "activate"),
        .mixr => try command.run(app, .{ .static = .@"mixr.show" }),
        .other => {},
    }
}

/// `osascript -e 'tell application "<app>" to <verb>'`, fire and forget;
/// a toast elsewhere than macOS.
fn tellPlayer(app: *App, player: Source, verb: []const u8) CommandError!void {
    if (builtin.os.tag != .macos) {
        app.toast("{s}: only a macOS player answers `{s}`", .{ player.appName(), verb });
        return;
    }
    const arena = app.frame.allocator();
    const script = try std.fmt.allocPrint(arena, "tell application \"{s}\" to {s}", .{ player.appName(), verb });
    var child = std.process.spawn(app.io, .{
        .argv = &.{ "osascript", "-e", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        app.toast("{s}: cannot run osascript: {s}", .{ player.appName(), @errorName(err) });
        return;
    };
    _ = child.wait(app.io) catch {};
}

pub const Chip = enum { label, play, next };

/// A left click on one of the cluster's chips, for `dispatch.mouse`:
/// a command's own failures are its toasts, as `runCmd` treats them.
pub fn click(app: *App, chip: Chip) Allocator.Error!void {
    (switch (chip) {
        .label => clickLabel(app),
        .play => clickPlay(app),
        .next => clickNext(app),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// The cluster's right-click: the player menu — auth status, the
/// preferred-app radio rows, the mixr views, and the title to copy
/// when a track is loaded.
pub fn openMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const cur = app.cfg.ui.preferred_music_app;
    var rows: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "○ Beatport: not signed in", .action = .{ .command = .@"mixr.show_auth_status" } },
        .{ .label = "mixr (Beatport)", .action = .{ .command = .@"mixr.set_preferred_mixr" }, .checked = cur == .mixr },
        .{ .label = "Music", .action = .{ .command = .@"mixr.set_preferred_music" }, .checked = cur == .music },
        .{ .label = "Spotify", .action = .{ .command = .@"mixr.set_preferred_spotify" }, .checked = cur == .spotify },
        .{ .label = "Play random chart", .action = .{ .command = .@"mixr.play_now" }, .separator_before = true },
        .{ .label = "Open mixr", .action = .{ .command = .@"mixr.show" } },
        .{ .label = "Show: Queue", .action = .{ .command = .@"mixr.show_queue" } },
        .{ .label = "Show: History", .action = .{ .command = .@"mixr.show_history" } },
        .{ .label = "Show: Browse", .action = .{ .command = .@"mixr.show_browse" } },
        .{ .label = "Show: Log", .action = .{ .command = .@"mixr.show_log" } },
    });
    if (app.now_playing.current) |t| if (t.hasTrack()) {
        try rows.append(app.gpa, .{ .label = "Copy track title", .action = .{ .command = .@"mixr.copy_track" } });
    };
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu("mixr", owned, x, y);
}

// ─── commands ────────────────────────────────────────────────────────────

pub const table = .{
    .@"mixr.set_preferred_mixr" = &preferMixr,
    .@"mixr.set_preferred_music" = &preferMusic,
    .@"mixr.set_preferred_spotify" = &preferSpotify,
    .@"mixr.copy_track" = &copyTrack,
};

fn preferMixr(app: *App) CommandError!void {
    try setPreferred(app, .mixr);
}

fn preferMusic(app: *App) CommandError!void {
    try setPreferred(app, .music);
}

fn preferSpotify(app: *App) CommandError!void {
    try setPreferred(app, .spotify);
}

/// The idle chip's player, persisted to the home config.
pub fn setPreferred(app: *App, pick: Config.MusicApp) CommandError!void {
    app.cfg.ui.preferred_music_app = pick;
    _ = try settings.persist(app, .home, &.{ "ui", "preferred_music_app" }, pick);
    app.toast("music: prefer {s}", .{@tagName(pick)});
    app.needs_render = true;
}

fn copyTrack(app: *App) CommandError!void {
    const t = app.now_playing.current orelse return app.toast("nothing playing", .{});
    if (!t.hasTrack()) return app.toast("nothing playing", .{});
    const label = try rawLabel(app.frame.allocator(), &t);
    try app.clipboard.copy(label);
    app.toast("copied: {s}", .{label});
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "the override: track and state, an optional source and detail; empty or malformed is idle" {
    const a = parseOverride("Blue Monday|playing").?;
    try testing.expectEqual(Source.mixr, a.source);
    try testing.expect(a.playing);
    try testing.expectEqualStrings("Blue Monday", a.track());
    try testing.expectEqualStrings("", a.detail());
    const b = parseOverride("Blue Monday|paused|spotify|New Order").?;
    try testing.expectEqual(Source.spotify, b.source);
    try testing.expect(!b.playing);
    try testing.expectEqualStrings("New Order", b.detail());
    try testing.expect(parseOverride("") == null);
    try testing.expect(parseOverride("|playing") == null);
    try testing.expect(parseOverride("Song|dancing") == null);
    try testing.expectEqual(Source.other, parseOverride("x|playing|Winamp").?.source);
}

test "mixr's quick.txt: the sentinel is none, playing_active decides, a missing flag follows the track" {
    const idle = projectMixr("playing=—\nplaying_bpm=—\nplaying_active=false\n");
    try testing.expect(!idle.hasTrack());
    try testing.expect(!idle.playing);
    const live = projectMixr("playing = Artist - Title \nplaying_bpm=128\nplaying_active=true\n");
    try testing.expectEqualStrings("Artist - Title", live.track());
    try testing.expectEqualStrings("128", live.detail());
    try testing.expect(live.playing);
    const dip = projectMixr("playing=Artist - Title\nplaying_active=false\n");
    try testing.expect(dip.hasTrack() and !dip.playing);
    try testing.expect(projectMixr("playing=Song\n").playing);
}

test "the macOS line: app, track, artist by tabs; nothing without a track" {
    const m = parseMacos("Music\tKarma Police\tRadiohead\n").?;
    try testing.expectEqual(Source.music, m.source);
    try testing.expectEqualStrings("Karma Police", m.track());
    try testing.expectEqualStrings("Radiohead", m.detail());
    try testing.expect(m.playing);
    try testing.expect(parseMacos("") == null);
    try testing.expect(parseMacos("Spotify\t\tX") == null);
    try testing.expectEqual(Source.other, parseMacos("Winamp\tSong\t").?.source);
}

test "the label: mixr's track as written, `artist - title` for a macOS player, whitespace folded, 28 cells then …, or a marquee window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mixr = Track.init(.mixr, true, "Artist  -  Title", "128");
    try testing.expectEqualStrings("Artist - Title", try rawLabel(a, &mixr));
    const mac = Track.init(.music, true, "Karma Police", "Radiohead");
    try testing.expectEqualStrings("Radiohead - Karma Police", try rawLabel(a, &mac));
    const long = "abcdefghijklmnopqrstuvwxyz0123456789";
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz01…", try shownLabel(a, long, false, 0));
    try testing.expectEqualStrings(long[0..28], try shownLabel(a, long, true, 0));
    // Offset 36 (the label's length) starts in the three-cell gap.
    try testing.expectEqualStrings("   abcdefghijklmnopqrstuvwxy", try shownLabel(a, long, true, 36));
    try testing.expectEqualStrings("short", try shownLabel(a, "short", true, 7));
    // Cut at a codepoint boundary, never inside one.
    const cut = Track.init(.mixr, true, repeat("é", 200), "");
    try testing.expect(std.unicode.utf8ValidateSlice(cut.track()));
}

test "the mixr sticky rule: an empty mixr read inside ten seconds keeps the track; a macOS read replaces it" {
    var st: State = .{};
    const live = Track.init(.mixr, true, "Song", "");
    try testing.expect(merge(&st, live, 1000).?.hasTrack());
    st.current = live;
    const dip = Track.init(.mixr, false, "", "");
    try testing.expectEqualStrings("Song", merge(&st, dip, 5000).?.track());
    try testing.expect(!merge(&st, dip, 12_000).?.hasTrack());
    const mac = Track.init(.music, true, "Other", "X");
    try testing.expectEqualStrings("Other", merge(&st, mac, 2000).?.track());
    try testing.expect(merge(&st, null, 2000) == null);
}
