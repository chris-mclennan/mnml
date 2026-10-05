//! The host end of a mount (E5). One `Mount` = one Unix socket mnml
//! listens on, one child process told where it is (`MNML_MOUNT_SOCKET`),
//! and one reader task in an `Io.Group` that turns what the sibling
//! sends into `AppEvent.mount` posts.
//!
//! Frames never queue. The reader paints every `frame` / `frame_dirty`
//! into the `Shared.grid` under a lock and posts one `.frame` event only
//! when the grid goes clean → dirty (the pty ring's rule); the UI copies
//! the grid out in its handler and the next frame paints it. A sibling
//! that streams faster than the UI paints therefore coalesces in the
//! grid instead of filling the queue, and a dirty row is never lost
//! under a dropped full frame — there is nothing to drop.
//!
//! Everything else the sibling says (title, cursor, command, toast,
//! bye) is a real event with a gpa-owned payload; `Event.destroy` frees
//! it whether or not the handler adopted it.
//!
//! Sends go the other way from the UI thread only (`Mount.send`); the
//! socket is full-duplex so the reader never contends with them. The
//! stream and the child handle live in `Shared` under its lock because
//! `close` (UI) and the reader's teardown both reach them.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const event = @import("../core/event.zig");
const ids = @import("../core/ids.zig");
const child_os = @import("../core/child.zig");

pub const PaneId = ids.PaneId;
pub const supported = Io.net.has_unix_sockets;

/// Bytes a cell keeps inline for its grapheme; a longer symbol is cut.
pub const max_symbol = 24;

/// One painted cell of a sibling's frame.
pub const Cell = struct {
    sym: [max_symbol]u8 = [_]u8{' '} ++ [_]u8{0} ** (max_symbol - 1),
    len: u8 = 1,
    fg: ?wire.Color = null,
    bg: ?wire.Color = null,
    mods: wire.Mods = .{},

    pub fn set(c: *Cell, w: wire.Cell) void {
        const n: u8 = @intCast(@min(w.symbol.len, max_symbol));
        @memcpy(c.sym[0..n], w.symbol[0..n]);
        c.len = n;
        c.fg = w.fg;
        c.bg = w.bg;
        c.mods = w.mods;
    }

    pub fn symbol(c: *const Cell) []const u8 {
        return c.sym[0..c.len];
    }
};

/// The sibling's screen as the host holds it. Sized by what the sibling
/// sends, not by the pane: a frame wider than the pane is clipped at
/// paint time, a narrower one leaves the theme's ground.
pub const Grid = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},

    pub fn deinit(g: *Grid, gpa: Allocator) void {
        gpa.free(g.cells);
        g.* = .{};
    }

    pub fn at(g: *Grid, x: u16, y: u16) *Cell {
        return &g.cells[@as(usize, y) * g.cols + x];
    }

    pub fn cell(g: *const Grid, x: u16, y: u16) *const Cell {
        return &g.cells[@as(usize, y) * g.cols + x];
    }

    /// Reallocate to `cols × rows`, blank. Cheap when unchanged in size.
    pub fn resize(g: *Grid, gpa: Allocator, cols: u16, rows: u16) Allocator.Error!void {
        const n = @as(usize, cols) * rows;
        if (n != g.cells.len) {
            const fresh = try gpa.alloc(Cell, n);
            gpa.free(g.cells);
            g.cells = fresh;
        }
        @memset(g.cells, .{});
        g.cols = cols;
        g.rows = rows;
    }

    /// A whole screen: the grid takes the frame's shape.
    pub fn applyFull(g: *Grid, gpa: Allocator, rows: []const []const wire.Cell) Allocator.Error!void {
        var cols: usize = 0;
        for (rows) |r| cols = @max(cols, r.len);
        try g.resize(gpa, @intCast(@min(cols, std.math.maxInt(u16))), @intCast(@min(rows.len, std.math.maxInt(u16))));
        for (rows[0..g.rows], 0..) |r, y| {
            for (r[0..@min(r.len, g.cols)], 0..) |c, x| g.at(@intCast(x), @intCast(y)).set(c);
        }
    }

    /// Rows that changed; a row outside the grid is ignored, a short
    /// row leaves the rest of its line as it was.
    pub fn applyDirty(g: *Grid, rows: []const wire.Row) void {
        for (rows) |r| {
            if (r.y >= g.rows) continue;
            for (r.cells[0..@min(r.cells.len, g.cols)], 0..) |c, x| g.at(@intCast(x), r.y).set(c);
        }
    }

    /// Become a copy of `other`.
    pub fn copyFrom(g: *Grid, gpa: Allocator, other: *const Grid) Allocator.Error!void {
        if (g.cells.len != other.cells.len) {
            const fresh = try gpa.alloc(Cell, other.cells.len);
            gpa.free(g.cells);
            g.cells = fresh;
        }
        @memcpy(g.cells, other.cells);
        g.cols = other.cols;
        g.rows = other.rows;
    }
};

/// `MNML_CHILD_STDERR`: where a mounted child's stderr goes instead of
/// `/dev/null`. Unset — which is every normal run — and nothing changes.
///
/// A child's stderr is discarded because a sibling that writes to the
/// terminal would scribble over the very screen mnml is painting. That
/// also means a child which panics, or refuses, says so into the void:
/// all the host sees is the EOF, and all it can report is "connection
/// closed". This is the way to hear it. Set it to a path PREFIX; each
/// mount gets its own `<prefix>.<n>` so two children never interleave
/// and the order is the order they were spawned.
///
/// ```sh
/// MNML_CHILD_STDERR=/tmp/child zig build e2e -- tests/e2e/some.test
/// cat /tmp/child.*
/// ```
const child_stderr_var = "MNML_CHILD_STDERR";

/// Bumped per spawn so the files are unique and ordered within a run.
var child_stderr_seq: std.atomic.Value(u32) = .init(0);

/// The file `MNML_CHILD_STDERR` asks for, or `.ignore` — which is the
/// default, and the only thing a run without the variable set ever
/// gets. Never fails the spawn: a debug aid that broke a mount would be
/// worse than no debug aid.
fn childStderr(io: Io, env: *const std.process.Environ.Map) std.process.SpawnOptions.StdIo {
    const prefix = env.get(child_stderr_var) orelse return .ignore;
    if (prefix.len == 0) return .ignore;
    const n = child_stderr_seq.fetchAdd(1, .monotonic);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}.{d}", .{ prefix, n }) catch return .ignore;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    const file = Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return .ignore;
    return .{ .file = file };
}

/// What the reader posts. `pane` routes it; `generation` lets a pane
/// that was re-mounted drop a dead reader's last words.
pub const Event = struct {
    pane: PaneId,
    generation: u32,
    kind: union(enum) {
        /// The sibling connected; the host answers with `hello`.
        connected,
        /// `Shared.grid` changed since the UI last copied it.
        frame,
        title: []u8,
        cursor: ?wire.Cursor,
        command: []u8,
        /// `action` is the offer the pane attached, when it sent one
        /// the host can act on: a label and either a command id or a
        /// page. Owned like the text, and freed with it.
        toast: struct { level: wire.ToastLevel, text: []u8, action: ?ToastAction = null },
        /// The sibling started a session and wants to be told what it
        /// does next. One `key` per button; a second watch under a key
        /// replaces the first.
        watch_session: struct { key: []u8, id: []u8, cwd: []u8, prompt_line: []u8 },
        /// The element under the pointer, named by the pane for the
        /// info view. Owned.
        hover: struct { title: []u8, body: []u8, command: []u8 = &.{} },
        /// The sibling said goodbye.
        bye,
        /// The stream ended without one; the reason is for the banner.
        closed: []u8,
    },

    /// A toast's offer, owned by the event. `wire.ToastAction` with
    /// its strings copied out of the frame arena.
    pub const ToastAction = struct {
        label: []u8,
        command: []u8,
        url: []u8,

        pub fn isCommand(a: ToastAction) bool {
            return a.command.len > 0;
        }
    };

    pub fn destroy(self: *Event, gpa: Allocator) void {
        switch (self.kind) {
            .title, .command, .closed => |s| gpa.free(s),
            .toast => |t| {
                gpa.free(t.text);
                if (t.action) |a| {
                    gpa.free(a.label);
                    gpa.free(a.command);
                    gpa.free(a.url);
                }
            },
            .watch_session => |w| {
                gpa.free(w.key);
                gpa.free(w.id);
                gpa.free(w.cwd);
                gpa.free(w.prompt_line);
            },
            .hover => |h| {
                gpa.free(h.title);
                gpa.free(h.body);
                if (h.command.len > 0) gpa.free(h.command);
            },
            .connected, .frame, .cursor, .bye => {},
        }
        gpa.destroy(self);
    }
};

/// Between the UI thread and the reader task.
pub const Shared = struct {
    io: Io,
    lock: Io.Mutex = .init,
    grid: Grid = .{},
    /// A `.frame` event is in flight; the next paint clears it.
    grid_posted: bool = false,
    stream: ?Io.net.Stream = null,
    child: ?std.process.Child = null,
    /// `close` began; the reader stops at its next step.
    closing: bool = false,
    /// The reader returned.
    done: std.atomic.Value(bool) = .init(false),
};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: []const u8,
    /// The child's whole environment; the caller has already put
    /// `MNML_MOUNT_SOCKET` and friends in it (`envFor`).
    env: *const std.process.Environ.Map,
    /// Where the socket goes (`socketPath`).
    socket_path: []const u8,
    pane: PaneId,
    generation: u32,
};

pub const SpawnError = error{ Unsupported, BindFailed, SpawnFailed, ListenFailed } || Allocator.Error;

pub const SendError = error{ NotConnected, WriteFailed } || Allocator.Error;

pub const Mount = struct {
    gpa: Allocator,
    io: Io,
    shared: *Shared,
    server: ?Io.net.Server,
    socket_path: []u8,
    group: Io.Group = .init,
    generation: u32,
    /// The UI thread's writer over the accepted stream.
    wbuf: []u8,
    writer: ?Io.net.Stream.Writer = null,
    /// `.connected` landed.
    connected: bool = false,
    /// `hello` went out.
    greeted: bool = false,

    pub const write_buffer = 64 * 1024;
    /// How long `close` gives a sibling to leave after `goodbye`.
    pub const grace_ms: u32 = 200;

    /// Bind the socket, spawn the child, start the reader.
    pub fn spawn(gpa: Allocator, io: Io, events: *event.EventQueue, opts: SpawnOptions) SpawnError!*Mount {
        if (!supported) return error.Unsupported;
        const path = try gpa.dupe(u8, opts.socket_path);
        errdefer gpa.free(path);
        if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        // A stale file from a crashed host would block the bind.
        Io.Dir.cwd().deleteFile(io, path) catch {};
        const addr = Io.net.UnixAddress.init(path) catch return error.BindFailed;
        var server = addr.listen(io, .{}) catch return error.BindFailed;
        errdefer server.deinit(io);
        errdefer Io.Dir.cwd().deleteFile(io, path) catch {};

        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        shared.* = .{ .io = io };
        const wbuf = try gpa.alloc(u8, write_buffer);
        errdefer gpa.free(wbuf);

        // `.ignore` unless `MNML_CHILD_STDERR` names somewhere to put it.
        const stderr = childStderr(io, opts.env);
        defer if (stderr == .file) stderr.file.close(io);
        shared.child = std.process.spawn(io, .{
            .argv = opts.argv,
            .cwd = .{ .path = opts.cwd },
            .environ_map = opts.env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = stderr,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };
        errdefer if (shared.child) |*c| c.kill(io);

        const m = try gpa.create(Mount);
        errdefer gpa.destroy(m);
        m.* = .{
            .gpa = gpa,
            .io = io,
            .shared = shared,
            .server = server,
            .socket_path = path,
            .generation = opts.generation,
            .wbuf = wbuf,
        };
        m.group.concurrent(io, reader, .{ events, io, gpa, shared, &m.server.?, opts.pane, opts.generation }) catch return error.ListenFailed;
        return m;
    }

    /// The UI's answer to `.connected`: arm the writer.
    pub fn onConnected(m: *Mount) void {
        m.shared.lock.lockUncancelable(m.io);
        defer m.shared.lock.unlock(m.io);
        const stream = m.shared.stream orelse return;
        m.writer = .init(stream, m.io, m.wbuf);
        m.connected = true;
    }

    /// One message to the sibling. UI thread only.
    pub fn send(m: *Mount, msg: wire.HostMessage) SendError!void {
        const w = if (m.writer) |*w| w else return error.NotConnected;
        const body = try wire.encode(m.gpa, msg);
        defer m.gpa.free(body);
        wire.writeMessage(&w.interface, body) catch return error.WriteFailed;
    }

    /// Copy the reader's grid into `dst` and clear the posted flag, so
    /// the next change posts again.
    pub fn takeGrid(m: *Mount, gpa: Allocator, dst: *Grid) Allocator.Error!void {
        m.shared.lock.lockUncancelable(m.io);
        defer m.shared.lock.unlock(m.io);
        try dst.copyFrom(gpa, &m.shared.grid);
        m.shared.grid_posted = false;
    }

    /// Tell the sibling to go, give it `grace_ms`, then take everything
    /// down: the reader, the child, the socket file.
    pub fn close(m: *Mount) void {
        const io = m.io;
        const s = m.shared;
        {
            s.lock.lockUncancelable(io);
            defer s.lock.unlock(io);
            s.closing = true;
            if (s.stream) |stream| {
                if (m.writer != null) m.send(.goodbye) catch {};
                stream.shutdown(io, .both) catch {};
            }
        }
        if (!m.connected) {
            // The reader is parked in `accept`; a connection of our own
            // wakes it and it sees `closing`.
            if (Io.net.UnixAddress.init(m.socket_path)) |addr| {
                if (addr.connect(io)) |c| c.close(io) else |_| {}
            } else |_| {}
        }
        var waited: u32 = 0;
        while (!s.done.load(.acquire) and waited < grace_ms) : (waited += 10) {
            io.sleep(.fromMilliseconds(10), .awake) catch break;
        }
        m.group.cancel(io);
        s.lock.lockUncancelable(io);
        if (s.child) |*c| c.kill(io);
        s.child = null;
        if (s.stream) |stream| stream.close(io);
        s.stream = null;
        s.lock.unlock(io);
        if (m.server) |*srv| srv.deinit(io);
        m.server = null;
        Io.Dir.cwd().deleteFile(io, m.socket_path) catch {};
    }

    /// `close` first.
    pub fn destroy(m: *Mount) void {
        const gpa = m.gpa;
        m.shared.grid.deinit(gpa);
        gpa.destroy(m.shared);
        gpa.free(m.wbuf);
        gpa.free(m.socket_path);
        gpa.destroy(m);
    }
};

fn post(events: *event.EventQueue, io: Io, gpa: Allocator, ev: Event) void {
    const box = gpa.create(Event) catch return;
    box.* = ev;
    events.post(io, .{ .mount = box });
}

fn postOwned(events: *event.EventQueue, io: Io, gpa: Allocator, pane: PaneId, generation: u32, comptime tag: []const u8, text: []const u8) void {
    const copy = gpa.dupe(u8, text) catch return;
    post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = @unionInit(@FieldType(Event, "kind"), tag, copy) });
}

/// The reader task: accept once, then one message at a time until the
/// stream ends, then reap the child.
fn reader(events: *event.EventQueue, io: Io, gpa: Allocator, shared: *Shared, server: *Io.net.Server, pane: PaneId, generation: u32) void {
    defer shared.done.store(true, .release);
    readLoop(events, io, gpa, shared, server, pane, generation);
    // Reap: the child exits on `goodbye` or its own `bye`; a cancel
    // while we wait (the pane closed) kills it instead. // changed: the
    // kill goes by pid, taken first — a cancelled `Child.wait` clears
    // `child.id` without killing anything, so the `c.kill` that used
    // to sit here saw a null id and did nothing, and a bridge child
    // that ignored `goodbye` outlived its pane.
    shared.lock.lockUncancelable(io);
    var child = shared.child;
    shared.child = null;
    shared.lock.unlock(io);
    if (child) |*c| {
        const pid = c.id;
        _ = c.wait(io) catch child_os.reapAbandoned(pid);
    }
}

fn readLoop(events: *event.EventQueue, io: Io, gpa: Allocator, shared: *Shared, server: *Io.net.Server, pane: PaneId, generation: u32) void {
    const stream = server.accept(io) catch |err| {
        postOwned(events, io, gpa, pane, generation, "closed", @errorName(err));
        return;
    };
    {
        shared.lock.lockUncancelable(io);
        defer shared.lock.unlock(io);
        if (shared.closing) {
            stream.close(io);
            return;
        }
        shared.stream = stream;
    }
    post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .connected });

    const rbuf = gpa.alloc(u8, 64 * 1024) catch return;
    defer gpa.free(rbuf);
    var r: Io.net.Stream.Reader = .init(stream, io, rbuf);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const msg = wire.receive(wire.SiblingMessage, gpa, arena, &r.interface) catch |err| {
            postOwned(events, io, gpa, pane, generation, "closed", switch (err) {
                error.TooLarge => "frame over 16 MiB",
                error.Truncated => "stream cut mid-frame",
                error.BadMessage => "unreadable message",
                error.ReadFailed => "read failed",
                error.OutOfMemory => "out of memory",
            });
            return;
        } orelse {
            postOwned(events, io, gpa, pane, generation, "closed", "connection closed");
            return;
        };
        switch (msg) {
            .frame => |f| {
                shared.lock.lockUncancelable(io);
                defer shared.lock.unlock(io);
                shared.grid.applyFull(gpa, f.cells) catch continue;
                if (!shared.grid_posted) {
                    shared.grid_posted = true;
                    post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .frame });
                }
            },
            .frame_dirty => |d| {
                shared.lock.lockUncancelable(io);
                defer shared.lock.unlock(io);
                shared.grid.applyDirty(d.rows);
                if (!shared.grid_posted) {
                    shared.grid_posted = true;
                    post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .frame });
                }
            },
            .title => |t| postOwned(events, io, gpa, pane, generation, "title", t),
            .cursor => |c| post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .{ .cursor = c } }),
            .command => |c| postOwned(events, io, gpa, pane, generation, "command", c.id),
            .toast => |t| {
                const copy = gpa.dupe(u8, t.text) catch continue;
                // The offer, if the pane sent one that is an offer.
                // Three owned strings or none: a half-allocated action
                // would be freed wrong.
                var action: ?Event.ToastAction = null;
                if (t.action) |a| if (a.isValid()) {
                    const label = gpa.dupe(u8, a.label) catch {
                        gpa.free(copy);
                        continue;
                    };
                    const cmd = gpa.dupe(u8, a.command) catch {
                        gpa.free(copy);
                        gpa.free(label);
                        continue;
                    };
                    const url = gpa.dupe(u8, a.url) catch {
                        gpa.free(copy);
                        gpa.free(label);
                        gpa.free(cmd);
                        continue;
                    };
                    action = .{ .label = label, .command = cmd, .url = url };
                };
                post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .{ .toast = .{ .level = t.level, .text = copy, .action = action } } });
            },
            .watch_session => |req| {
                // Four owned strings or none: a half-allocated watch
                // would be freed wrong.
                const key = gpa.dupe(u8, req.key) catch continue;
                const id = gpa.dupe(u8, req.selector.id) catch {
                    gpa.free(key);
                    continue;
                };
                const cwd = gpa.dupe(u8, req.selector.cwd) catch {
                    gpa.free(key);
                    gpa.free(id);
                    continue;
                };
                const line = gpa.dupe(u8, req.selector.prompt_line) catch {
                    gpa.free(key);
                    gpa.free(id);
                    gpa.free(cwd);
                    continue;
                };
                post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .{ .watch_session = .{ .key = key, .id = id, .cwd = cwd, .prompt_line = line } } });
            },
            .hover => |h| {
                // A pane names what is under the pointer; bounded, so a
                // chatty sibling cannot fill the info view with a book.
                const title = gpa.dupe(u8, h.title[0..@min(h.title.len, 120)]) catch continue;
                const body = gpa.dupe(u8, h.body[0..@min(h.body.len, 600)]) catch {
                    gpa.free(title);
                    continue;
                };
                // The command the element's click runs, by id; the
                // host spells its chord. An id is short — a longer one
                // is not an id, and is dropped rather than cut.
                const cmd_in = h.command orelse "";
                const cmd: []u8 = if (cmd_in.len == 0 or cmd_in.len > 120) &.{} else gpa.dupe(u8, cmd_in) catch {
                    gpa.free(title);
                    gpa.free(body);
                    continue;
                };
                post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .{ .hover = .{ .title = title, .body = body, .command = cmd } } });
            },
            .bye => {
                post(events, io, gpa, .{ .pane = pane, .generation = generation, .kind = .bye });
                return;
            },
        }
    }
}

// ─── paths + environment ─────────────────────────────────────────────────

/// `<ipc_dir>/mounts/<pid>-<id>.sock`, or a short `/tmp` name when the
/// workspace path would not fit a `sockaddr_un` (104 bytes on macOS).
/// Windows keeps the long path: Zig reaches AF_UNIX there through AFD,
/// whose socket path may be as long as any path (`UnixAddress.max_len`).
pub fn socketPath(gpa: Allocator, ipc_dir: []const u8, id: u32) Allocator.Error![]u8 {
    // The real process id on Windows too: two mnml instances sharing a
    // workspace must not name the same socket.
    const pid: u32 = if (builtin.os.tag == .windows) std.os.windows.GetCurrentProcessId() else @intCast(@as(i64, std.c.getpid()));
    const name = try std.fmt.allocPrint(gpa, "{d}-{d}.sock", .{ pid, id });
    defer gpa.free(name);
    const long = try std.fs.path.join(gpa, &.{ ipc_dir, "mounts", name });
    if (long.len < Io.net.UnixAddress.max_len - 4) return long;
    gpa.free(long);
    return std.fmt.allocPrint(gpa, "/tmp/mnml-mount-{s}", .{name});
}

pub const EnvVars = struct {
    socket_path: []const u8,
    workspace: []const u8,
    theme: []const u8,
    ipc_dir: []const u8,
    /// The host's data root. An integration reads its config, its token
    /// and its caches under the same root its host uses — a host on a
    /// private root (a dev profile, the corpus) must never have its
    /// panes reading the user's real `~/.config/mnml`.
    data_root: []const u8 = "",
    /// `integrations.request_log`, passed down so the SDK's
    /// `request_log.Log` knows whether to write and how big to let a
    /// file get. A null block leaves both unset, which the SDK reads
    /// as "on, at the default ceiling".
    request_log: ?RequestLogVars = null,
};

pub const RequestLogVars = struct {
    enabled: bool = true,
    max_mb: u32 = 4,
};

/// The child's environment: the host's, plus the mount contract.
///
/// Not everything the child is told comes from here. Where the API
/// brokers are (`<SERVICE>_BROKER_SOCKET`, `MNML_BROKER`) is the App's
/// answer rather than the bridge's, so `app/broker.zig`'s `putEnv`
/// adds it on top — see `app/mount_pane.zig`.
pub fn envFor(gpa: Allocator, base: *const std.process.Environ.Map, vars: EnvVars) Allocator.Error!std.process.Environ.Map {
    var env = try base.clone(gpa);
    errdefer env.deinit();
    try env.put("MNML_MOUNT_SOCKET", vars.socket_path);
    try env.put("MNML_WORKSPACE", vars.workspace);
    try env.put("MNML_THEME", vars.theme);
    try env.put("MNML_IPC_DIR", vars.ipc_dir);
    if (vars.data_root.len > 0) try env.put("MNML_DATA_ROOT", vars.data_root);
    if (vars.request_log) |rl| {
        try env.put("MNML_REQUEST_LOG", if (rl.enabled) "1" else "0");
        var mbuf: [12]u8 = undefined;
        try env.put("MNML_REQUEST_LOG_MAX_MB", std.fmt.bufPrint(&mbuf, "{d}", .{rl.max_mb}) catch "4");
    }
    var pbuf: [4]u8 = undefined;
    try env.put("MNML_PROTOCOL", std.fmt.bufPrint(&pbuf, "{d}", .{wire.protocol}) catch "3");
    return env;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "grid: a full frame sets the shape; dirty rows patch in place; short and long rows are clipped" {
    const gpa = testing.allocator;
    var g: Grid = .{};
    defer g.deinit(gpa);
    const a = [_]wire.Cell{ .{ .symbol = "a" }, .{ .symbol = "b", .fg = .{ .index = 3 } }, .{ .symbol = "漢" } };
    const b = [_]wire.Cell{.{ .symbol = "z" }};
    try g.applyFull(gpa, &.{ &a, &b });
    try testing.expectEqual(@as(u16, 3), g.cols);
    try testing.expectEqual(@as(u16, 2), g.rows);
    try testing.expectEqualStrings("b", g.cell(1, 0).symbol());
    try testing.expectEqual(wire.Color{ .index = 3 }, g.cell(1, 0).fg.?);
    try testing.expectEqualStrings("漢", g.cell(2, 0).symbol());
    try testing.expectEqualStrings("z", g.cell(0, 1).symbol());
    try testing.expectEqualStrings(" ", g.cell(1, 1).symbol());
    const patch = [_]wire.Cell{ .{ .symbol = "Q" }, .{ .symbol = "R" }, .{ .symbol = "S" }, .{ .symbol = "T" } };
    g.applyDirty(&.{ .{ .y = 1, .cells = &patch }, .{ .y = 9, .cells = &patch } });
    try testing.expectEqualStrings("Q", g.cell(0, 1).symbol());
    try testing.expectEqualStrings("S", g.cell(2, 1).symbol());
    try testing.expectEqualStrings("a", g.cell(0, 0).symbol());
    var copy: Grid = .{};
    defer copy.deinit(gpa);
    try copy.copyFrom(gpa, &g);
    try testing.expectEqualStrings("R", copy.cell(1, 1).symbol());
    try testing.expectEqual(@as(u16, 3), copy.cols);
    // A symbol longer than the inline slot is cut, never overrun.
    const long = [_]wire.Cell{.{ .symbol = "0123456789012345678901234567890123456789" }};
    try g.applyFull(gpa, &.{&long});
    try testing.expectEqual(@as(usize, max_symbol), g.cell(0, 0).symbol().len);
}

test "envFor carries the mount contract; socketPath stays short enough for sockaddr_un" {
    const gpa = testing.allocator;
    var base = std.process.Environ.Map.init(gpa);
    defer base.deinit();
    try base.put("HOME", "/h");
    var env = try envFor(gpa, &base, .{ .socket_path = "/s.sock", .workspace = "/ws", .theme = "onedark", .ipc_dir = "/ws/.mnml/ipc-zig" });
    defer env.deinit();
    try sdk_testing.expectPath("/s.sock", env.get("MNML_MOUNT_SOCKET").?);
    try testing.expect(env.get("MNML_DATA_ROOT") == null);
    var rooted = try envFor(gpa, &base, .{ .socket_path = "/s.sock", .workspace = "/ws", .theme = "onedark", .ipc_dir = "/ws/.mnml/ipc-zig", .data_root = "/private/root" });
    defer rooted.deinit();
    try sdk_testing.expectPath("/private/root", rooted.get("MNML_DATA_ROOT").?);
    // `integrations.request_log` reaches every integration as two
    // variables — the other half of the name the SDK reads.
    try testing.expect(env.get("MNML_REQUEST_LOG") == null);
    var logged = try envFor(gpa, &base, .{ .socket_path = "/s.sock", .workspace = "/ws", .theme = "onedark", .ipc_dir = "/i", .request_log = .{ .enabled = true, .max_mb = 8 } });
    defer logged.deinit();
    try testing.expectEqualStrings("1", logged.get("MNML_REQUEST_LOG").?);
    try testing.expectEqualStrings("8", logged.get("MNML_REQUEST_LOG_MAX_MB").?);
    var off = try envFor(gpa, &base, .{ .socket_path = "/s.sock", .workspace = "/ws", .theme = "onedark", .ipc_dir = "/i", .request_log = .{ .enabled = false } });
    defer off.deinit();
    try testing.expectEqualStrings("0", off.get("MNML_REQUEST_LOG").?);
    try sdk_testing.expectPath("/ws", env.get("MNML_WORKSPACE").?);
    try testing.expectEqualStrings("onedark", env.get("MNML_THEME").?);
    try sdk_testing.expectPath("/ws/.mnml/ipc-zig", env.get("MNML_IPC_DIR").?);
    try testing.expectEqualStrings("3", env.get("MNML_PROTOCOL").?);
    try sdk_testing.expectPath("/h", env.get("HOME").?);
    const short = try socketPath(gpa, "/ws/.mnml/ipc-zig", 3);
    defer gpa.free(short);
    try testing.expect(std.mem.endsWith(u8, short, "-3.sock"));
    try testing.expect(sdk_testing.pathStartsWith(short, "/ws/.mnml/ipc-zig/mounts/"));
    const deep = "/" ++ "d" ** 120;
    const fallback = try socketPath(gpa, deep, 4);
    defer gpa.free(fallback);
    try testing.expect(fallback.len < Io.net.UnixAddress.max_len);
    // Windows' AF_UNIX takes a path of any length: the long one stays.
    try testing.expect(sdk_testing.pathStartsWith(fallback, if (builtin.os.tag == .windows) deep ++ "/mounts/" else "/tmp/mnml-mount-"));
}

test "close: a sibling that never connected and outlives goodbye is killed, not orphaned — the reader's cancelled wait reaps it by pid" {
    if (!supported or builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var events = try event.EventQueue.init(gpa, 64);
    defer events.deinit(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Relative to the build root, where `.zig-cache` is: short enough
    // for `sockaddr_un` on every platform, and inside the tree.
    var pbuf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&pbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var sbuf: [160]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sbuf, "{s}/m.sock", .{dir});
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    // A "sibling" that never connects to the socket and ignores every
    // goodbye — a hung integration binary.
    const m = try Mount.spawn(gpa, io, &events, .{ .argv = &.{ "/bin/sleep", "30" }, .cwd = dir, .env = &env, .socket_path = sock, .pane = 1, .generation = 0 });
    const pid = blk: {
        m.shared.lock.lockUncancelable(io);
        defer m.shared.lock.unlock(io);
        break :blk m.shared.child.?.id.?;
    };
    try testing.expect(!child_os.gone(pid));

    // `close` wakes the reader out of `accept`; the reader takes the
    // child and blocks in `wait`; `grace_ms` later the group is
    // cancelled and that wait comes back `Canceled` with `id` cleared
    // and the child untouched. The pid taken before the wait is what
    // takes it down.
    m.close();
    m.destroy();
    // `reapAbandoned` returns reaped, so `gone` holds the instant `close`
    // does; the deadline is what a wrong answer costs. The one this test
    // gave under load — one run in twenty, "still there" a full ten
    // seconds after the kill — was a zombie: the cancel's SIGIO had
    // landed in the reap's `waitpid` (`core/child.zig`, `reap`).
    try testing.expect(child_os.goneWithin(io, pid, .fromSeconds(10)));
}
