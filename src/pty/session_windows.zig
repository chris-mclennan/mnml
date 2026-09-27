//! One ConPTY session: a child process behind `CreatePseudoConsole`, a
//! reader thread that moves its output into a `Ring`, a watcher thread
//! that notices its exit, and a ghostty-vt `Terminal` the UI thread feeds
//! from that ring. The public surface is `session_posix.zig`'s.
//!
//! The plumbing
//! ------------
//! Two anonymous pipes. The child's input is the read end of one; we keep
//! its write end, and a writer thread `WriteFile`s the session's outbox
//! there — the UI thread only queues (`outbox.zig`), so a child that stops
//! reading its console input can never block it. The child's output is
//! the write end of the other; the reader thread blocks in `ReadFile` on
//! its read end. `CreatePseudoConsole` duplicates the two ends it is
//! given into conhost, so our copies are closed right after — exactly as
//! Microsoft's sample does. The child gets the pseudoconsole through
//! `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` on an extended startup info; it
//! is not told about our pipes at all.
//!
//! Threads and ownership
//! ---------------------
//! All three threads (reader, watcher, writer) are *detached*, like the
//! POSIX reader, and as there, `Session.deinit` does not join them but
//! does wait for all of them to let go of the shared block before it frees
//! it — so the block never outlives
//! the session and a leak-checked caller can tear down the allocator
//! right after. `deinit` terminates the child, closes the pseudoconsole,
//! marks the block `closing`, sets the stop event, and then waits for the
//! releases. None takes long: the watcher's and the writer's waits return
//! on the stop event (a writer inside `WriteFile` is released by the
//! pseudoconsole's close, which breaks the pipe under it); the reader keeps draining (into scratch once closing —
//! `ClosePseudoConsole` is known to block until every pending byte has
//! been read; a reader that stopped reading would wedge the UI thread on
//! close) until conhost lets go of its end of the pipe after the close,
//! which breaks its `ReadFile`. Everything either thread touches lives in
//! `Shared`; neither dereferences `Session`, and neither touches the
//! block after its release.
//!
//! Exit
//! ----
//! A ConPTY child exiting does not end the output pipe — conhost stays
//! up. So the watcher waits on the process handle (and a stop event
//! `deinit` sets), records the exit code, and then closes the
//! pseudoconsole itself; the reader reaches EOF once the last of the
//! output has drained. That gives `eof()` the POSIX meaning: the child
//! is gone *and* nothing more is coming. The close is the watcher's and
//! never the UI thread's on purpose: `ClosePseudoConsole` waits for the
//! output pipe to drain, and the ring the reader drains into is emptied
//! only by the UI thread — a UI thread inside `ClosePseudoConsole` with a
//! full ring would wait on itself. `deinit` closes too, but by then the
//! reader discards, so nothing waits on the UI.
//!
//! Query replies (DSR, DA, …) work as on POSIX: stashed by the
//! `write_pty` effect mid-parse, written after the drain; the
//! `@fieldParentPtr` walk is why a `Session` is heap-allocated and never
//! moved.
//!
//! Untested: there is no Windows machine in the loop. This file is held
//! to "compiles clean for x86_64-windows-gnu"; `win_cmdline.zig` holds
//! the pieces that run on every host and are tested there.

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vt = @import("ghostty-vt");
const Ring = @import("ring.zig").Ring;
const common = @import("common.zig");
const Outbox = @import("outbox.zig").Outbox;
const win = @import("win_cmdline.zig");

const log = std.log.scoped(.pty);

pub const Notify = common.Notify;
pub const Exit = common.Exit;

pub const Options = struct {
    cols: u16,
    rows: u16,
    /// The parent's environment; the child gets a copy with TERM et al.
    /// overlaid. Not modified.
    env: *const std.process.Environ.Map,
    /// Program to run. `null` → `%COMSPEC%` (see `win_cmdline.defaultShell`).
    argv: ?[]const []const u8 = null,
    /// Accepted for symmetry with the POSIX options: the shell
    /// integrations are POSIX-only, so nothing sets them here.
    shell_args: []const []const u8 = &.{},
    shell_login: bool = true,
    cwd: ?[]const u8 = null,
    notify: Notify = .none,
    /// Ring size; must be a power of two.
    ring_capacity: usize = Ring.default_capacity,
    /// Scrollback kept above the screen, in lines.
    scrollback_lines: usize = common.default_scrollback_lines,
    /// Take the child's clipboard writes (OSC 52 and the kitty protocol)
    /// for `takeClipboard`. Off: they are dropped, as before.
    clipboard_write: bool = false,
    /// Accepted for symmetry with the POSIX options; the Windows reader
    /// blocks in `ReadFile` and needs no poll interval.
    poll_interval_ms: i32 = 250,
};

pub const SpawnError = error{
    PipeFailed,
    PseudoConsoleFailed,
    AttributeListFailed,
    CreateProcessFailed,
    EventFailed,
    NoShell,
    ArgvEmpty,
    InvalidArg0,
    InvalidWtf8,
} || Allocator.Error || std.Thread.SpawnError || Io.Cancelable;

// ── kernel32 ────────────────────────────────────────────────────────
// Zig 0.16's std reaches the kernel through ntdll and declares almost
// none of the console / process Win32 surface, so these are our own
// externs. Signatures follow the SDK headers; `windows.BOOL` compares
// with `.FALSE` / `.TRUE`.

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
/// `HPCON` — an opaque pseudoconsole handle, not a kernel handle.
const HPCON = *anyopaque;
const HRESULT = c_long;

const INFINITE: DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: DWORD = 0;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

const kernel32 = struct {
    extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePseudoConsole(size: windows.COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HPCON) callconv(.winapi) HRESULT;
    extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) HRESULT;
    extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, Attribute: usize, lpValue: ?*anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: BOOL, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: windows.UINT) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateEventW(lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES, bManualReset: BOOL, bInitialState: BOOL, lpName: ?windows.LPCWSTR) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
};

const SpinLock = common.SpinLock;

/// State the two threads and the session all reach. Refcounted; see the
/// module doc for why it is not simply owned by the session.
const Shared = struct {
    ring: Ring,
    /// Our end of the child's output pipe. The reader closes it.
    out_read: HANDLE,
    /// The child. Closed with the block.
    process: HANDLE,
    /// Manual-reset event `deinit` sets so the watcher and the writer
    /// stop waiting.
    stop: HANDLE,
    /// What the session wants written to the child; the writer drains it.
    outbox: Outbox = .{},
    /// Auto-reset: set by a push onto an empty outbox.
    write_ready: HANDLE,
    /// Our end of the child's input pipe. The writer owns it and closes
    /// it on its way out.
    in_write: HANDLE,
    /// The pseudoconsole. Closed exactly once (`closePty`) by whoever
    /// gets there first — the watcher after the child exits, or
    /// `Session.deinit`. `pcon_lock` covers the flag and every resize,
    /// so a resize never touches a handle that is being closed.
    hpc: HPCON,
    pcon_lock: SpinLock = .{},
    pcon_closed: bool = false,
    notify: Notify,
    /// Guards `notify`: the threads call it under the lock, `Session.deinit`
    /// clears it under the lock. After `deinit` returns the callback is
    /// never entered again.
    notify_lock: SpinLock = .{},
    /// Set by `Session.deinit`. The reader discards from here on.
    closing: std.atomic.Value(bool) = .init(false),
    /// Set by the reader when the output pipe broke.
    eof: std.atomic.Value(bool) = .init(false),
    /// Set by the watcher once `exit_code` is valid.
    exited: std.atomic.Value(bool) = .init(false),
    exit_code: std.atomic.Value(u32) = .init(0),
    /// The session + the reader + the watcher + the writer. `deinit`
    /// waits for the three threads' releases before its own, so the block
    /// is always freed by `deinit`, before it returns — each thread's last
    /// touch is its `fetchSub`.
    refs: std.atomic.Value(u32) = .init(4),

    fn release(self: *Shared, gpa: Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.ring.deinit();
        self.outbox.deinit(gpa);
        windows.CloseHandle(self.process);
        windows.CloseHandle(self.stop);
        windows.CloseHandle(self.write_ready);
        gpa.destroy(self);
    }

    /// Session side: block until every thread has dropped its
    /// reference. Bounded by their wake-up latency once `deinit` has
    /// set the stop event and closed the pseudoconsole — a short spin,
    /// then 1 ms naps.
    fn awaitThreads(self: *Shared) void {
        var spins: u32 = 0;
        while (self.refs.load(.acquire) > 1) : (spins += 1) {
            if (spins < 256) std.atomic.spinLoopHint() else kernel32.Sleep(1);
        }
    }

    fn callNotify(self: *Shared) void {
        self.notify_lock.lock();
        defer self.notify_lock.unlock();
        self.notify.call();
    }

    fn disarmNotify(self: *Shared) void {
        self.notify_lock.lock();
        defer self.notify_lock.unlock();
        self.notify = .none;
    }

    /// Close the pseudoconsole unless someone already has. May block
    /// until the reader has drained what conhost still holds (see the
    /// module doc), so the caller must not be the thread that empties
    /// the ring. The lock is dropped before the blocking call: a resize
    /// racing the close sees the flag and skips.
    fn closePty(self: *Shared) void {
        self.pcon_lock.lock();
        if (self.pcon_closed) {
            self.pcon_lock.unlock();
            return;
        }
        self.pcon_closed = true;
        self.pcon_lock.unlock();
        kernel32.ClosePseudoConsole(self.hpc);
    }

    fn resizePty(self: *Shared, size: windows.COORD) void {
        self.pcon_lock.lock();
        defer self.pcon_lock.unlock();
        if (self.pcon_closed) return;
        const hr = kernel32.ResizePseudoConsole(self.hpc, size);
        if (hr != 0) log.warn("ResizePseudoConsole failed: 0x{x}", .{@as(u32, @bitCast(hr))});
    }
};

pub const Session = struct {
    gpa: Allocator,
    term: vt.Terminal,
    /// By value: the write_pty callback recovers `Session` from
    /// `&stream.handler` via `@fieldParentPtr`. Never move a Session.
    stream: vt.TerminalStream,
    shared: *Shared,
    /// The child's last clipboard write, until `takeClipboard`.
    clipboard: ?[]u8 = null,
    exit: ?Exit = null,
    cols: u16,
    rows: u16,

    pub fn spawn(gpa: Allocator, io: Io, opts: Options) SpawnError!*Session {
        // ── strings the kernel wants ──
        var env = try opts.env.clone(gpa);
        defer env.deinit();
        try applyTerm(&env);
        const env_block = try env.createWindowsBlock(gpa, .{});
        defer env_block.deinit(gpa);

        var shell_argv: [1][]const u8 = undefined;
        const argv: []const []const u8 = if (opts.argv) |a| blk: {
            if (a.len == 0) return error.ArgvEmpty;
            break :blk a;
        } else blk: {
            shell_argv[0] = win.defaultShell(opts.env);
            if (shell_argv[0].len == 0) return error.NoShell;
            break :blk &shell_argv;
        };
        const cmd_line = try win.commandLine(gpa, argv);
        defer gpa.free(cmd_line);
        const cwd_w: ?[:0]u16 = if (opts.cwd) |d| try std.unicode.wtf8ToWtf16LeAllocZ(gpa, d) else null;
        defer if (cwd_w) |d| gpa.free(d);

        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        const shared = try gpa.create(Shared);
        errdefer gpa.destroy(shared);
        var ring = try Ring.init(opts.ring_capacity);
        errdefer ring.deinit();

        var term: vt.Terminal = try .init(io, gpa, common.terminalOptions(opts.cols, opts.rows, opts.scrollback_lines));
        errdefer term.deinit(gpa);

        // ── pipes + pseudoconsole ──
        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        if (kernel32.CreatePipe(&in_read, &in_write, null, 0) == .FALSE) return error.PipeFailed;
        // Owned by the writer thread once it is running.
        var in_write_owned = false;
        errdefer if (!in_write_owned) windows.CloseHandle(in_write);
        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        if (kernel32.CreatePipe(&out_read, &out_write, null, 0) == .FALSE) {
            windows.CloseHandle(in_read);
            return error.PipeFailed;
        }

        var hpc: HPCON = undefined;
        const hr = kernel32.CreatePseudoConsole(coord(opts.cols, opts.rows), in_read, out_write, 0, &hpc);
        // conhost holds its own duplicates now; ours would only keep the
        // pipes alive past the child.
        windows.CloseHandle(in_read);
        windows.CloseHandle(out_write);
        if (hr != 0) {
            windows.CloseHandle(out_read);
            log.warn("CreatePseudoConsole failed: 0x{x}", .{@as(u32, @bitCast(hr))});
            return error.PseudoConsoleFailed;
        }
        errdefer {
            // Order matters: with nobody reading the output pipe,
            // `ClosePseudoConsole` waits for a drain that never comes.
            // Break the pipe first so conhost's writes fail instead.
            windows.CloseHandle(out_read);
            kernel32.ClosePseudoConsole(hpc);
        }

        // ── the child ──
        var attr_size: usize = 0;
        _ = kernel32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_list = try gpa.alloc(usize, (attr_size + @sizeOf(usize) - 1) / @sizeOf(usize));
        defer gpa.free(attr_list);
        if (kernel32.InitializeProcThreadAttributeList(attr_list.ptr, 1, 0, &attr_size) == .FALSE) return error.AttributeListFailed;
        defer kernel32.DeleteProcThreadAttributeList(attr_list.ptr);
        if (kernel32.UpdateProcThreadAttribute(attr_list.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == .FALSE)
            return error.AttributeListFailed;

        var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attr_list.ptr;
        var pi: windows.PROCESS.INFORMATION = undefined;
        // No application name: `CreateProcessW` resolves the first token
        // on PATH itself (and appends `.exe`). Handles are not inherited —
        // the pseudoconsole attribute is the child's whole console.
        if (windows.kernel32.CreateProcessW(
            null,
            cmd_line.ptr,
            null,
            null,
            .FALSE,
            .{ .extended_startupinfo_present = true, .create_unicode_environment = true },
            env_block.slice.ptr,
            if (cwd_w) |d| d.ptr else null,
            @ptrCast(&si),
            &pi,
        ) == .FALSE) {
            log.warn("CreateProcessW failed: {t}", .{windows.GetLastError()});
            return error.CreateProcessFailed;
        }
        windows.CloseHandle(pi.hThread);
        errdefer {
            _ = kernel32.TerminateProcess(pi.hProcess, 1);
            windows.CloseHandle(pi.hProcess);
        }

        const stop = kernel32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventFailed;
        errdefer windows.CloseHandle(stop);
        const write_ready = kernel32.CreateEventW(null, .FALSE, .FALSE, null) orelse return error.EventFailed;
        errdefer windows.CloseHandle(write_ready);

        // ── wire the session ──
        shared.* = .{
            .ring = ring,
            .out_read = out_read,
            .process = pi.hProcess,
            .stop = stop,
            .write_ready = write_ready,
            .in_write = in_write,
            .hpc = hpc,
            .notify = opts.notify,
        };
        self.* = .{
            .gpa = gpa,
            .term = term,
            .stream = undefined,
            .shared = shared,
            .cols = opts.cols,
            .rows = opts.rows,
        };
        var handler = self.term.vtHandler();
        handler.effects = .readonly;
        handler.effects.write_pty = onWritePty;
        handler.effects.device_attributes = common.deviceAttributes;
        if (opts.clipboard_write) handler.effects.clipboard_write = onClipboardWrite;
        self.stream = .init(.{ .handler = handler, .allocator = gpa });

        // Watcher and writer first: they only wait, so if a later thread
        // fails to start they can be stopped and joined, and the errdefers
        // above are once more the only owners of the block.
        const watcher = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watcherMain, .{ shared, gpa });
        const writer = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, writerMain, .{ shared, gpa }) catch |err| {
            _ = kernel32.SetEvent(stop);
            watcher.join();
            return err;
        };
        // The writer closes the pipe on its way out, even a joined one.
        in_write_owned = true;
        const reader = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerMain, .{ shared, gpa }) catch |err| {
            _ = kernel32.SetEvent(stop);
            watcher.join();
            writer.join();
            return err;
        };
        watcher.detach();
        writer.detach();
        reader.detach();
        return self;
    }

    /// Terminate the child, close the pseudoconsole and let go. Waits
    /// only for the two threads to drop the shared block, never for the
    /// child (see module doc). When this returns nothing of the session
    /// is left allocated.
    pub fn deinit(self: *Session) void {
        const gpa = self.gpa;
        const shared = self.shared;
        shared.disarmNotify();
        shared.closing.store(true, .release);
        // The POSIX side hangs up on the whole process group; Win32 has no
        // group to signal, so the direct child is terminated. Grandchildren
        // it started are on their own (a job object would be the fix).
        if (!shared.exited.load(.acquire)) _ = kernel32.TerminateProcess(shared.process, 1);
        // The reader discards from here on, so the drain this may wait
        // for needs nothing from us.
        shared.closePty();
        _ = kernel32.SetEvent(shared.stop);
        self.stream.deinit();
        self.term.deinit(gpa);
        if (self.clipboard) |text| gpa.free(text);
        shared.awaitThreads();
        shared.release(gpa);
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Feed what the reader has ringed into the terminal (its query
    /// replies go onto the outbox as they are parsed): the bytes there
    /// when the pump starts, at most `common.pump_budget` of them — never
    /// what the child writes while it runs (see `pump_budget`). Call from
    /// the UI thread on every `.pty_readable` and once per frame; while
    /// `backlog` is true the loop calls again without sleeping. Returns
    /// true when the terminal state changed (something to render).
    pub fn pump(self: *Session) bool {
        const ring = &self.shared.ring;
        ring.beginDrain();
        var left = @min(ring.len(), common.pump_budget);
        var fed = false;
        while (left > 0) {
            const chunk = ring.readableSlice();
            if (chunk.len == 0) break;
            const n = @min(chunk.len, left);
            self.stream.nextSlice(chunk[0..n]);
            ring.consume(n);
            left -= n;
            fed = true;
        }
        self.reap();
        return fed;
    }

    /// Bytes are ringed that no pump has fed yet.
    pub fn backlog(self: *const Session) bool {
        return self.shared.ring.len() > 0;
    }

    /// Bytes from the user (keystrokes, paste) to the child. Queued for
    /// the writer; returns at once whether or not the child is reading.
    pub fn write(self: *Session, bytes: []const u8) void {
        self.queue(bytes);
    }

    /// Ctrl+C: what is still queued goes (a tty flushes its input on an
    /// interrupt), then the byte — conhost turns it into CTRL_C_EVENT.
    pub fn interrupt(self: *Session) void {
        self.shared.outbox.discard();
        self.queue("\x03");
    }

    /// Bytes still waiting for the child to read them.
    pub fn pendingInput(self: *Session) usize {
        return self.shared.outbox.pending();
    }

    fn queue(self: *Session, bytes: []const u8) void {
        if (self.shared.exited.load(.acquire)) return;
        const edge = self.shared.outbox.push(self.gpa, bytes) catch |err| {
            log.warn("dropping {d} bytes of input: {t}", .{ bytes.len, err });
            return;
        };
        if (edge) _ = kernel32.SetEvent(self.shared.write_ready);
    }

    /// Resize both the pseudoconsole (the child sees a window-size event)
    /// and the terminal grid. No-op when unchanged, so callers may spam it.
    pub fn resize(self: *Session, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return error.InvalidValue;
        if (cols == self.cols and rows == self.rows) return;
        // After the child exited the pseudoconsole is closed or closing;
        // only the grid is left to size.
        self.shared.resizePty(coord(cols, rows));
        try common.resizeGrid(&self.stream.handler, cols, rows);
        self.cols = cols;
        self.rows = rows;
    }

    /// The child's exit, once known. `null` while it is still running.
    pub fn exited(self: *Session) ?Exit {
        if (self.exit == null) self.reap();
        return self.exit;
    }

    /// True once the output pipe broke: the pseudoconsole was closed and
    /// everything the child wrote has been ringed.
    pub fn eof(self: *const Session) bool {
        return self.shared.eof.load(.acquire);
    }

    /// The Session's stream is the only writer of `term`; readers of the
    /// grid (`grid.zig`) go through here.
    pub fn terminal(self: *Session) *vt.Terminal {
        return &self.term;
    }

    fn fromHandler(handler: *vt.TerminalStream.Handler) *Session {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// The text the child last copied, gpa-owned — the caller frees it.
    /// Null when it copied nothing since the last call.
    pub fn takeClipboard(self: *Session) ?[]u8 {
        const text = self.clipboard orelse return null;
        self.clipboard = null;
        return text;
    }

    fn onClipboardWrite(handler: *vt.TerminalStream.Handler, w: vt.clipboard.Write) void {
        const self = fromHandler(handler);
        const text = common.clipboardText(w) orelse return w.reply(.unsupported);
        const copy = self.gpa.dupe(u8, text) catch return w.reply(.io_error);
        if (self.clipboard) |old| self.gpa.free(old);
        self.clipboard = copy;
        w.reply(.{ .success = .{} });
    }

    fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
        // Mid-parse is fine: a push only copies.
        fromHandler(handler).queue(data);
    }

    /// Take the watcher's verdict. The watcher has closed (or is
    /// closing) the pseudoconsole, so the reader reaches EOF after the
    /// last output — the POSIX shape, where a dead child closes the pty.
    fn reap(self: *Session) void {
        if (self.exit != null) return;
        if (!self.shared.exited.load(.acquire)) return;
        self.exit = win.exitFromCode(self.shared.exit_code.load(.acquire));
    }
};

// ── threads ─────────────────────────────────────────────────────────

fn readerMain(shared: *Shared, gpa: Allocator) void {
    defer shared.release(gpa);
    var scratch: [4096]u8 = undefined;
    while (true) {
        // Once the session let go nobody will drain the ring; keep
        // reading anyway (into scratch) so `ClosePseudoConsole` can finish.
        var discard = shared.closing.load(.acquire);
        var dst: []u8 = &scratch;
        if (!discard) {
            dst = shared.ring.writable();
            // Back-pressure: a full ring means the UI is more than 256 KiB
            // behind; give it a moment rather than spinning.
            while (dst.len == 0) {
                if (shared.closing.load(.acquire)) {
                    discard = true;
                    dst = &scratch;
                    break;
                }
                kernel32.Sleep(1);
                dst = shared.ring.writable();
            }
        }
        var got: DWORD = 0;
        // FALSE with ERROR_BROKEN_PIPE once conhost closed its end; a
        // zero-length read means the same.
        if (kernel32.ReadFile(shared.out_read, dst.ptr, @intCast(@min(dst.len, std.math.maxInt(DWORD))), &got, null) == .FALSE) break;
        if (got == 0) break;
        if (!discard and shared.ring.commit(got)) shared.callNotify();
    }
    shared.eof.store(true, .release);
    windows.CloseHandle(shared.out_read);
    shared.callNotify();
}

fn watcherMain(shared: *Shared, gpa: Allocator) void {
    defer shared.release(gpa);
    const handles = [_]HANDLE{ shared.process, shared.stop };
    // Index 0 is the process; anything else is the stop event (or a
    // failed wait, after which there is nothing sensible to report).
    if (kernel32.WaitForMultipleObjects(handles.len, &handles, .FALSE, INFINITE) != WAIT_OBJECT_0) return;
    var code: DWORD = 0;
    if (kernel32.GetExitCodeProcess(shared.process, &code) == .FALSE) code = 255;
    shared.exit_code.store(code, .release);
    shared.exited.store(true, .release);
    shared.callNotify();
    // Last: this may block until the UI thread has drained the ring, and
    // the UI thread is free to — it is not us.
    shared.closePty();
}

/// Drain the outbox into the child's input pipe. The only thread that
/// writes it, and the one that closes it. `WriteFile` may block on a child
/// that is not reading — which is why it is this thread and not the UI's.
/// `deinit`'s pseudoconsole close breaks the pipe under a blocked write.
fn writerMain(shared: *Shared, gpa: Allocator) void {
    defer shared.release(gpa);
    defer windows.CloseHandle(shared.in_write);
    var chunk: [16 * 1024]u8 = undefined;
    const handles = [_]HANDLE{ shared.write_ready, shared.stop };
    while (!shared.closing.load(.acquire)) {
        const taken = shared.outbox.peek(&chunk);
        if (taken.n == 0) {
            if (kernel32.WaitForMultipleObjects(handles.len, &handles, .FALSE, INFINITE) != WAIT_OBJECT_0) break;
            continue;
        }
        var written: DWORD = 0;
        if (kernel32.WriteFile(shared.in_write, &chunk, @intCast(taken.n), &written, null) == .FALSE or written == 0) {
            shared.outbox.close();
            break;
        }
        shared.outbox.consume(written, taken.gen);
    }
    shared.outbox.close();
}

// ── helpers ─────────────────────────────────────────────────────────

fn coord(cols: u16, rows: u16) windows.COORD {
    return .{ .X = @intCast(@min(cols, std.math.maxInt(i16))), .Y = @intCast(@min(rows, std.math.maxInt(i16))) };
}

/// Overlay the terminal identity on the child's environment. No terminfo
/// on Windows: `xterm-256color` is what Windows Terminal itself claims,
/// and what every Windows-aware TUI library keys on.
fn applyTerm(env: *std.process.Environ.Map) Allocator.Error!void {
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "mnml-zig");
    _ = env.swapRemove("TERM_PROGRAM_VERSION");
}
