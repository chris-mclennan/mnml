//! `mnml-drive` — drive a REAL mnml, in a real ghostty window, from a
//! shell. Dev-only, macOS-only, ghostty-only, never shipped: it is not in
//! `run.sh install` or `scripts/package.sh`, and the build only compiles it
//! under `-Ddrive` on a macOS host. See `docs/DRIVE.md`.
//!
//! The headless harness proves what mnml COMPUTED. This proves what a
//! person SEES: the CoreText-rendered glyph, the Nerd Font icon that fell
//! back to a box, the theme colour after ghostty's own blending, the
//! cursor the terminal actually drew. `screen.txt` cannot show any of it.
//!
//! ── the safety rule ───────────────────────────────────────────────────
//!
//! The developer has their own ghostty windows open with their own work in
//! them. So:
//!
//!   * `launch` starts its OWN ghostty and records the child pid.
//!   * every other verb re-reads the window list and refuses unless the
//!     recorded window id is still on screen AND still owned by that pid.
//!     Not "a ghostty window", not "the frontmost window" — that one.
//!   * events go to the pid (`CGEventPostToPid`), never to the screen, so
//!     the harness window is driven without being focused and the
//!     developer keeps typing into whatever they were typing into.
//!   * nothing is ever raised or activated.
//!   * `quit` signals the recorded pid and nothing else.
//!
//! A verb that cannot satisfy all of that exits 3 and does nothing.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mac = @import("mac.zig");
const keys = @import("keys.zig");
const harness = @import("harness.zig");
const drive_build = @import("drive_build");

const usage_text =
    \\mnml-drive — drive a real mnml in a real ghostty window (dev-only, macOS + ghostty)
    \\
    \\  launch --workspace DIR --data-root DIR [--size small|corpus|full]
    \\         [--cols N] [--rows N] [--font-size PT] [--exe PATH] [--ghostty PATH]
    \\         [--timeout MS] [--take-focus] [--allow-input] [--no-mouse]
    \\  key <spec>              one chord or a chain: ctrl+p, "space f f", enter
    \\  type <text>             literal text, any codepoint
    \\  click|rightclick|doubleclick|hover X Y      cell coordinates
    \\  drag FX FY TX TY
    \\  scroll X Y up|down [--notches N]
    \\  shot PATH.png           the harness window only
    \\  pixel X Y [--expect #RRGGBB] [--tolerance N] [--fx F] [--fy F]
    \\  screen | status | rects                     the live IPC dumps
    \\  wait-frame [--timeout MS]                   block until screen.txt moves
    \\  info                    the recorded window, re-verified
    \\  doctor                  permissions, and what to do about them
    \\  version                 `source <hash>`: the sources this binary was built from
    \\  focus                   take the keyboard (explicit: keys need it)
    \\  quit
    \\
    \\Every verb but `launch`, `doctor`, `version` and the usage text reads
    \\--data-root DIR (or $MNML_DRIVE_DATA_ROOT) to find drive.json.
    \\
    \\Exit: 0 ok · 2 usage · 3 refused (not our window / no permission) · 4 timeout
    \\
;

const exit_usage: u8 = 2;
const exit_refused: u8 = 3;
const exit_timeout: u8 = 4;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const w = &out_file.interface;
    defer w.flush() catch {};
    var err_buf: [4096]u8 = undefined;
    var err_file: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const e = &err_file.interface;
    defer e.flush() catch {};

    if (args.len < 2) {
        try w.writeAll(usage_text);
        return exit_usage;
    }
    const verb = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "help")) {
        try w.writeAll(usage_text);
        return 0;
    }
    if (std.mem.eql(u8, verb, "doctor")) return doctor(w);
    // The stamp `tools/tour/stamp.py` compares against the checkout
    // (build.zig `driveSourceHash`): a driver built before its sources
    // changed is refused or rebuilt rather than trusted.
    if (std.mem.eql(u8, verb, "version")) {
        try w.print("source {s}\n", .{drive_build.source_hash});
        return 0;
    }
    if (std.mem.eql(u8, verb, "launch")) return launch(arena, io, init.environ_map, rest, w, e);

    // Everything else acts on an already-launched window, and every one
    // of them pays the same toll first.
    const data_root = flagValue(rest, "--data-root") orelse init.environ_map.get("MNML_DRIVE_DATA_ROOT") orelse {
        try e.writeAll("mnml-drive: --data-root DIR (or $MNML_DRIVE_DATA_ROOT) says which harness to drive\n");
        return exit_usage;
    };
    var session = openSession(arena, io, data_root, e) catch |err| switch (err) {
        error.Refused => return exit_refused,
        else => return err,
    };

    if (std.mem.eql(u8, verb, "info")) {
        try w.print(
            "pid {d} · window {d} · \"{s}\" · {d}x{d} cells at {d:.0},{d:.0} {d:.0}x{d:.0} pt · cell {d:.2}x{d:.2} pt\n",
            .{ session.rec.pid, session.rec.window_id, session.rec.title, session.rec.cols, session.rec.rows, session.win.x, session.win.y, session.win.w, session.win.h, session.rec.cellW(), session.rec.cellH() },
        );
        return 0;
    }
    if (std.mem.eql(u8, verb, "quit")) return quit(io, &session, w);
    if (std.mem.eql(u8, verb, "focus")) {
        if (!mac.activate(session.rec.pid)) {
            try e.writeAll("mnml-drive focus: the window server refused to activate the harness\n");
            return exit_refused;
        }
        sleepMs(io, 250);
        return 0;
    }
    if (std.mem.eql(u8, verb, "screen")) return catDump(arena, io, session.rec.ipc_dir, "screen.txt", w, e);
    if (std.mem.eql(u8, verb, "status")) return catDump(arena, io, session.rec.ipc_dir, "status.json", w, e);
    if (std.mem.eql(u8, verb, "rects")) return catDump(arena, io, session.rec.ipc_dir, "rects.json", w, e);
    if (std.mem.eql(u8, verb, "wait-frame")) {
        const ms = flagInt(u64, rest, "--timeout") orelse 3000;
        return if (waitFrame(arena, io, session.rec.ipc_dir, ms)) 0 else exit_timeout;
    }
    if (std.mem.eql(u8, verb, "shot")) {
        if (rest.len == 0 or rest[0][0] == '-') {
            try e.writeAll("mnml-drive shot: needs an output path\n");
            return exit_usage;
        }
        return shot(arena, io, &session, rest[0], e);
    }
    if (std.mem.eql(u8, verb, "key")) {
        if (rest.len == 0) {
            try e.writeAll("mnml-drive key: needs a spec\n");
            return exit_usage;
        }
        return sendKeys(io, &session, rest[0], e);
    }
    if (std.mem.eql(u8, verb, "type")) {
        if (rest.len == 0) {
            try e.writeAll("mnml-drive type: needs text\n");
            return exit_usage;
        }
        return sendText(arena, io, &session, rest[0], e);
    }
    if (std.mem.eql(u8, verb, "click") or std.mem.eql(u8, verb, "rightclick") or
        std.mem.eql(u8, verb, "doubleclick") or std.mem.eql(u8, verb, "hover"))
    {
        const xy = cellArgs(rest) orelse {
            try e.print("mnml-drive {s}: needs X Y in cells\n", .{verb});
            return exit_usage;
        };
        return mouse(io, &session, verb, xy[0], xy[1], e);
    }
    if (std.mem.eql(u8, verb, "drag")) {
        if (rest.len < 4) {
            try e.writeAll("mnml-drive drag: needs FX FY TX TY in cells\n");
            return exit_usage;
        }
        const a = cellArgs(rest) orelse return exit_usage;
        const b = cellArgs(rest[2..]) orelse return exit_usage;
        return drag(io, &session, a[0], a[1], b[0], b[1], e);
    }
    if (std.mem.eql(u8, verb, "scroll")) {
        if (rest.len < 3) {
            try e.writeAll("mnml-drive scroll: needs X Y up|down\n");
            return exit_usage;
        }
        const xy = cellArgs(rest) orelse return exit_usage;
        const up = std.mem.eql(u8, rest[2], "up");
        if (!up and !std.mem.eql(u8, rest[2], "down")) {
            try e.writeAll("mnml-drive scroll: the direction is `up` or `down`\n");
            return exit_usage;
        }
        const notches = flagInt(i32, rest, "--notches") orelse 1;
        return scroll(io, &session, xy[0], xy[1], up, notches, e);
    }
    if (std.mem.eql(u8, verb, "pixel")) {
        const xy = cellArgs(rest) orelse {
            try e.writeAll("mnml-drive pixel: needs X Y in cells\n");
            return exit_usage;
        };
        return pixel(&session, rest, xy[0], xy[1], w, e);
    }

    try e.print("mnml-drive: unknown verb `{s}`\n", .{verb});
    try w.writeAll(usage_text);
    return exit_usage;
}

// ─── the toll every verb pays ───────────────────────────────────────────

const Session = struct {
    rec: harness.Record,
    /// The window as it is RIGHT NOW, not as `launch` recorded it: a
    /// window the user dragged is still ours, and its cells have moved.
    win: mac.Window,
};

/// Read `drive.json`, then prove the window it names is still ours.
fn openSession(gpa: Allocator, io: Io, data_root: []const u8, e: *Io.Writer) !Session {
    const perms = mac.permissions();
    if (!perms.ok()) {
        try permissionHelp(e, perms);
        return error.Refused;
    }
    const path = try std.fs.path.join(gpa, &.{ data_root, "drive.json" });
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch {
        try e.print("mnml-drive: no harness at {s} — run `mnml-drive launch` first\n", .{path});
        return error.Refused;
    };
    const rec = harness.readRecord(gpa, text) catch {
        try e.print("mnml-drive: {s} is unreadable; delete it and launch again\n", .{path});
        return error.Refused;
    };
    // Three separate questions, because each of them has been the answer
    // at least once while this tool was being written: is the process
    // still there, is that window still on screen, and is it still THAT
    // process's window (ids are recycled).
    if (!mac.processAlive(rec.pid)) {
        try e.print("mnml-drive: refusing — the harness process {d} is gone (stale drive.json)\n", .{rec.pid});
        return error.Refused;
    }
    const win = mac.windowOwnedBy(rec.pid, rec.window_id) orelse {
        try e.print(
            "mnml-drive: refusing — window {d} is not on screen as a window of process {d}.\n" ++
                "  It may be minimised, on another Space, closed, or the id may have been reused.\n" ++
                "  Nothing was posted; no other window is ever a fallback.\n",
            .{ rec.window_id, rec.pid },
        );
        return error.Refused;
    };
    if (win.w <= 0 or win.h <= 0) {
        try e.writeAll("mnml-drive: refusing — the harness window has no on-screen area\n");
        return error.Refused;
    }
    var live = rec;
    live.x = win.x;
    live.y = win.y;
    live.w = win.w;
    live.h = win.h;
    return .{ .rec = live, .win = win };
}

fn permissionHelp(e: *Io.Writer, p: mac.Permissions) !void {
    try e.writeAll("mnml-drive: refusing — a macOS permission is missing.\n");
    if (!p.accessibility) {
        try e.writeAll(
            \\
            \\  Accessibility (to post keys and clicks)
            \\    System Settings → Privacy & Security → Accessibility
            \\    → + → add the program that RUNS mnml-drive (your terminal
            \\      app, e.g. /Applications/Ghostty.app), then toggle it on.
            \\    A terminal already in the list still has to be toggled on,
            \\    and it has to be restarted afterwards to pick the grant up.
            \\
        );
    }
    if (!p.screen_recording) {
        try e.writeAll(
            \\
            \\  Screen Recording (to read pixels back: shot, pixel, and
            \\  window titles)
            \\    System Settings → Privacy & Security → Screen & System
            \\    Audio Recording → + → add the same program, toggle on,
            \\    and restart it.
            \\
        );
    }
    try e.writeAll("\nNothing was posted. See docs/DRIVE.md.\n");
}

fn doctor(w: *Io.Writer) !u8 {
    const p = mac.permissions();
    try w.print("Accessibility     : {s}\n", .{if (p.accessibility) "granted" else "MISSING"});
    try w.print("Screen Recording  : {s}\n", .{if (p.screen_recording) "granted" else "MISSING"});
    if (p.ok()) {
        try w.writeAll("\nBoth granted — mnml-drive can launch and drive a window.\n");
        return 0;
    }
    try w.writeAll(
        \\
        \\Grant them to the program that RUNS mnml-drive — your terminal
        \\app, not mnml-drive itself (a command-line binary inherits its
        \\parent's grants and cannot hold its own):
        \\
        \\  System Settings → Privacy & Security → Accessibility
        \\  System Settings → Privacy & Security → Screen & System Audio Recording
        \\
        \\Add the terminal app with +, toggle it ON, and restart it —
        \\a grant does not reach a process that was already running.
        \\
    );
    return exit_refused;
}

// ─── launch ─────────────────────────────────────────────────────────────

fn launch(gpa: Allocator, io: Io, init_env: *std.process.Environ.Map, args: []const [:0]const u8, w: *Io.Writer, e: *Io.Writer) !u8 {
    const perms = mac.permissions();
    if (!perms.ok()) {
        try permissionHelp(e, perms);
        return exit_refused;
    }
    const workspace = flagValue(args, "--workspace") orelse {
        try e.writeAll("mnml-drive launch: --workspace DIR is required\n");
        return exit_usage;
    };
    const data_root = flagValue(args, "--data-root") orelse {
        try e.writeAll("mnml-drive launch: --data-root DIR is required\n");
        return exit_usage;
    };
    // How big. Three ways to say it, in precedence order:
    //
    //   --cols/--rows   exact. What a script's own `# width:` /
    //                   `# height:` header turns into, so a file that
    //                   declares a size gets that size and no other.
    //   --size NAME     `small` (80x24), `corpus` (120x40), or `full`.
    //   (nothing)       `full`: the size the user actually works at.
    //
    // The default is `full` because the default was 120x40 and the first
    // thing the user said about it was that the menu bar collapses to
    // `»` at that width — which is a real screen, but not the screen
    // they look at all day, and a hunter sweeping the wrong one finds
    // the wrong bugs.
    const explicit_cols = flagInt(u16, args, "--cols");
    const explicit_rows = flagInt(u16, args, "--rows");
    const named: harness.Named = if (flagValue(args, "--size")) |n|
        std.meta.stringToEnum(harness.Named, n) orelse {
            try e.print("mnml-drive launch: --size takes small | corpus | full (got `{s}`)\n", .{n});
            return exit_usage;
        }
    else
        .full;
    // A `full` launch has no number until a window has been measured, so
    // it starts at the corpus size and re-launches once it knows.
    var want: ?harness.Cells = if (explicit_cols != null or explicit_rows != null) .{
        .cols = @max(explicit_cols orelse harness.min_cols, harness.min_cols),
        .rows = @max(explicit_rows orelse harness.min_rows, harness.min_rows),
    } else named.cells();
    var cols: u16 = if (want) |v| v.cols else harness.Named.corpus.cells().?.cols;
    var rows: u16 = if (want) |v| v.rows else harness.Named.corpus.cells().?.rows;
    // The user's own font size, unless they set none: `--font-size`
    // exists for the retry path and for a machine with no ghostty config.
    var font_pt = flagInt(u16, args, "--font-size") orelse 13;
    const timeout_ms = flagInt(u64, args, "--timeout") orelse 20_000;
    const ghostty = flagValue(args, "--ghostty") orelse "/Applications/Ghostty.app/Contents/MacOS/ghostty";
    const exe = flagValue(args, "--exe") orelse "zig-out/bin/mnml-zig";

    // Whoever has the keyboard now. A ghostty started from a shell
    // activates itself as it opens, which took the keyboard from the
    // person at the machine mid-sentence on every launch; once the
    // window is up it is handed back (unless `--take-focus`).
    const front_before = mac.frontWindowPid();
    const take_focus = hasFlag(args, "--take-focus");

    try Io.Dir.cwd().createDirPath(io, data_root);
    // mnml's own config, in the isolated data root (harness.mnml_config
    // says why each key is there).
    //
    // In BOTH roots, because the harness launches `--profile dev` and the
    // dev profile is the stable answer with `-dev` on the end — an
    // explicit $MNML_DATA_ROOT included (`config/data_root.zig`). Writing
    // only the un-suffixed one is exactly the bug that put the
    // first-launch wizard on the user's screen: the file was there, and
    // the app was reading the directory next door.
    // Plus the developer's own layout keys, so a hunter is looking at
    // the layout the developer looks at rather than the defaults
    // (`harness.copied_keys` — two appearance keys, and nothing that
    // names a token, a path or an integration).
    const own_cfg = readUserMnmlConfig(gpa, io, init_env) orelse "";
    const mnml_cfg = try harness.mnmlConfigWith(gpa, own_cfg, .{ .allow_input = hasFlag(args, "--allow-input") });
    for ([_][]const u8{ data_root, try std.fmt.allocPrint(gpa, "{s}-dev", .{data_root}) }) |root| {
        try Io.Dir.cwd().createDirPath(io, root);
        const cfg_path = try std.fs.path.join(gpa, &.{ root, "config.zon" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = mnml_cfg });
    }

    const user_cfg = readUserGhosttyConfig(gpa, io, init_env) orelse "";
    const conf_path = try std.fs.path.join(gpa, &.{ data_root, "ghostty.conf" });
    const abs_exe = if (std.fs.path.isAbsolute(exe)) exe else try Io.Dir.cwd().realPathFileAlloc(io, exe, gpa);
    const abs_ws = if (std.fs.path.isAbsolute(workspace)) workspace else try Io.Dir.cwd().realPathFileAlloc(io, workspace, gpa);
    const ipc_dir = try std.fs.path.join(gpa, &.{ abs_ws, ".mnml", "ipc-zig" });
    const screen = mac.mainDisplayBounds();
    // The menu bar owns the top of the main display; a window placed at
    // y = 0 has its first row under it.
    const menu_bar_pt: f64 = 38;

    // Measure, then adjust. Nothing here can predict how many points a
    // cell takes at a given font size — that is CoreText's answer, for
    // the user's own font — so the harness asks for a size, measures the
    // window it got, and if ghostty had to clamp it to the display it
    // works out the size that WOULD fit and tries again. The grid never
    // shrinks; only the type does.
    var attempt: u8 = 0;
    while (attempt < 6) : (attempt += 1) {
        const conf = try harness.renderConfig(gpa, user_cfg, .{
            .cols = cols,
            .rows = rows,
            .title = harness.window_title,
            .font_size = font_pt,
            // A user font-size that does not fit is not a preference the
            // harness can honour; from the second attempt on, ours wins.
            .force_font_size = attempt > 0,
            .mouse_reporting = !hasFlag(args, "--no-mouse"),
        });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = conf_path, .data = conf });
        // A previous attempt's dumps would answer for this one.
        Io.Dir.cwd().deleteTree(io, ipc_dir) catch {};

        var child_env = try envWith(gpa, io, init_env, &.{
            .{ "MNML_DATA_ROOT", data_root },
            .{ "MNML_PROFILE", "dev" },
        });
        defer child_env.deinit();
        const cfg_flag = try std.fmt.allocPrint(gpa, "--config-file={s}", .{conf_path});
        const child = std.process.spawn(io, .{
            .argv = &.{
                ghostty,
                // Nothing of the user's leaks in but the font lines
                // copied into the harness config above.
                "--config-default-files=false",
                cfg_flag,
                "-e",
                abs_exe,
                // The dev profile keeps the IPC mailbox and the running-
                // instance marker separate from an installed mnml's, so
                // the harness never collides with the developer's own.
                "--profile",
                "dev",
                abs_ws,
            },
            .environ_map = &child_env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            try e.print("mnml-drive launch: cannot start {s}: {s}\n", .{ ghostty, @errorName(err) });
            return exit_refused;
        };
        const pid: i32 = @intCast(child.id.?);

        const found = waitForWindow(io, pid, harness.window_title, timeout_ms) orelse {
            try e.print(
                "mnml-drive launch: no window titled \"{s}\" appeared for pid {d} within {d} ms.\n" ++
                    "  If a window opened in YOUR ghostty instead, this build handed the launch to\n" ++
                    "  the running app; close that window by hand and report it — the harness will\n" ++
                    "  not drive a window it does not own.\n",
                .{ harness.window_title, pid, timeout_ms },
            );
            _ = std.c.kill(pid, .TERM);
            return exit_refused;
        };
        // The app is not up until it has drawn a frame AND the frame
        // knows how big it is: the very first status.json is written
        // before the winsize event lands and says 0x0, which read as
        // "the window came up the wrong size" the first time this ran.
        const got = waitForGrid(gpa, io, ipc_dir, timeout_ms) orelse {
            try e.print(
                "mnml-drive launch: the window is up but {s}/status.json never reported a size.\n" ++
                    "  mnml writes it only with `ipc.write_screen = true`, which the harness puts in\n" ++
                    "  {s}/config.zon — so a missing dump means the app did not read that root.\n",
                .{ ipc_dir, data_root },
            );
            _ = std.c.kill(pid, .TERM);
            return exit_refused;
        };
        // Re-read the bounds now that the app has drawn: the window is
        // listed the moment it exists, which is BEFORE ghostty has moved
        // it to `window-position-x/y` and sized it to the grid. Judging
        // "does it fit" on that first sighting refused a window that had
        // since landed neatly at the top-left corner.
        const placed = mac.windowOwnedBy(pid, found.id) orelse found;
        const fits = placed.x >= screen.origin.x - 1 and placed.y >= screen.origin.y - 1 and
            placed.x + placed.w <= screen.origin.x + screen.size.width + 1 and
            placed.y + placed.h <= screen.origin.y + screen.size.height + 1;
        const cell_w0 = if (got.cols > 0) placed.w / @as(f64, @floatFromInt(got.cols)) else 0;
        const cell_h0 = if (got.rows > 0) placed.h / @as(f64, @floatFromInt(got.rows)) else 0;
        // Ghostty 1.3 takes `window-position-x/y` and then cascades the
        // window beside the last one anyway, which on a two-display desk
        // puts the harness across the bezel. Ask the window server to
        // move OUR window to the main display's top-left, under the menu
        // bar, and re-read the bounds rather than believing the ask.
        var settled = placed;
        if (!fits or placed.x != screen.origin.x or placed.y < menu_bar_pt) {
            if (mac.moveWindow(pid, found.id, .{ .x = screen.origin.x, .y = screen.origin.y + menu_bar_pt })) {
                sleepMs(io, 250);
                settled = mac.windowOwnedBy(pid, found.id) orelse placed;
            }
        }
        // Fully on ONE display is what the shot and pixel math need: a
        // window that straddles a bezel photographs in two halves. The
        // main display is where the move above aims, but ghostty opens
        // on the display that has the keyboard, and the move is refused
        // outright on some setups (its one AX element answers
        // `kAXErrorAttributeUnsupported` for AXPosition, measured on a
        // two-display desk) — a window wholly on the other display is
        // still a window the harness can shoot and read.
        const settled_fits = mac.displayContaining(.{
            .origin = .{ .x = settled.x, .y = settled.y },
            .size = .{ .width = settled.w, .height = settled.h },
        }) != null;

        // `full` has no number until now: measure a cell on THIS machine,
        // at the user's own font, and work out how many of them the
        // target area holds. The target is the user's own largest ghostty
        // window when they have one open — "the size I usually work at" —
        // and otherwise the display itself, less the menu bar.
        if (want == null) {
            const area = fullTargetArea(pid, screen, menu_bar_pt);
            const cells = harness.cellsFor(area.width, area.height, cell_w0, cell_h0);
            want = .{ .cols = cells.cols, .rows = cells.rows };
            if (cells.cols != got.cols or cells.rows != got.rows) {
                try e.print("mnml-drive launch: full size on this machine is {d}x{d} cells ({d:.0}x{d:.0} pt at {d:.2}x{d:.2} pt a cell)\n", .{ cells.cols, cells.rows, area.width, area.height, cell_w0, cell_h0 });
                cols = cells.cols;
                rows = cells.rows;
                _ = std.c.kill(pid, .TERM);
                sleepMs(io, 300);
                continue;
            }
            cols = cells.cols;
            rows = cells.rows;
        }

        if (got.cols == cols and got.rows == rows and settled_fits) {
            const rec: harness.Record = .{
                .pid = pid,
                .window_id = found.id,
                .title = harness.window_title,
                .x = settled.x,
                .y = settled.y,
                .w = settled.w,
                .h = settled.h,
                .cols = cols,
                .rows = rows,
                .workspace = abs_ws,
                .data_root = data_root,
                .ipc_dir = ipc_dir,
            };
            const rec_path = try std.fs.path.join(gpa, &.{ data_root, "drive.json" });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = rec_path, .data = try harness.writeRecord(gpa, rec) });
            if (!take_focus) giveFocusBack(io, pid, front_before);
            try w.print("{s}\n", .{rec_path});
            return 0;
        }
        // It did not fit. Measure what a cell actually costs at this
        // size and scale the type down by the shortfall, with a little
        // slack so a rounding error does not need a fourth attempt.
        const next = nextFontSize(font_pt, cell_w0, cell_h0, cols, rows, screen);
        _ = std.c.kill(pid, .TERM);
        if (got.cols == cols and got.rows == rows and next == null) {
            // The grid is right and the type is not the problem: the
            // window simply landed somewhere off this display.
            try e.print(
                "mnml-drive launch: the window came up {d}x{d} as asked, but at {d:.0},{d:.0} {d:.0}x{d:.0} pt\n" ++
                    "  it is not wholly on any one display (main: {d:.0},{d:.0} {d:.0}x{d:.0} pt). Refusing: a window\n" ++
                    "  partly off screen photographs as a window partly off screen.\n",
                .{ got.cols, got.rows, settled.x, settled.y, settled.w, settled.h, screen.origin.x, screen.origin.y, screen.size.width, screen.size.height },
            );
            return exit_refused;
        }
        if (next == null or next.? >= font_pt) {
            try e.print(
                "mnml-drive launch: {d}x{d} cells will not fit this display ({d:.0}x{d:.0} pt)\n" ++
                    "  even at the smallest font the harness will use. Asked at {d} pt; the window\n" ++
                    "  came up {d}x{d}. Refusing: every cell→pixel sum after this would be wrong.\n",
                .{ cols, rows, screen.size.width, screen.size.height, font_pt, got.cols, got.rows },
            );
            return exit_refused;
        }
        try e.print("mnml-drive launch: {d}x{d} did not fit at {d} pt (got {d}x{d}); retrying at {d} pt\n", .{ cols, rows, font_pt, got.cols, got.rows, next.? });
        font_pt = next.?;
        sleepMs(io, 300);
    }
    try e.writeAll("mnml-drive launch: gave up after four attempts to fit the grid on screen\n");
    return exit_refused;
}

/// Hand the keyboard back to the application that had it before the
/// launch, if the harness took it. Ghostty activates as it opens, and a
/// script that launches a window per file (the corpus sweep) would
/// otherwise take the keyboard from the person at the machine once a
/// file. The app it hands back to is the one that was frontmost a
/// moment ago — nothing is raised that was not already in front.
fn giveFocusBack(io: Io, pid: i32, before: ?i32) void {
    const prev = before orelse return;
    if (prev == pid) return;
    var waited: u64 = 0;
    // The activation can land after the window is listed; watch for it
    // briefly rather than checking once too early.
    while (waited < 1500) : (waited += 50) {
        if (mac.frontWindowPid()) |front| {
            if (front == pid) {
                _ = mac.activate(prev);
                return;
            }
        }
        sleepMs(io, 50);
    }
}

/// The font size that WOULD fit, from the one measurement that exists:
/// how many points a cell took at the size just tried. Null when even the
/// floor is too big — the harness would rather refuse than photograph a
/// grid that is not the one the script asked for.
fn nextFontSize(current: u16, cell_w: f64, cell_h: f64, cols: u16, rows: u16, screen: mac.CGRect) ?u16 {
    if (cell_w <= 0 or cell_h <= 0 or current <= 6) return null;
    const want_w = cell_w * @as(f64, @floatFromInt(cols));
    const want_h = cell_h * @as(f64, @floatFromInt(rows));
    const scale = @min(screen.size.width / want_w, screen.size.height / want_h);
    if (scale >= 1) return null; // it fits; the mismatch was not size
    // A hair under the exact ratio, because a font size is an integer
    // and rounding up lands back where it started.
    const scaled = @floor(@as(f64, @floatFromInt(current)) * scale * 0.97);
    const next: u16 = @intFromFloat(@max(scaled, 6));
    return if (next < current) next else current - 1;
}

/// Poll `status.json` until it reports a non-zero grid, and return it.
/// The size is the App's own screen, so this is also the check that the
/// window came up the size the config asked for.
fn waitForGrid(gpa: Allocator, io: Io, ipc_dir: []const u8, timeout_ms: u64) ?struct { cols: u16, rows: u16 } {
    const p = std.fs.path.join(gpa, &.{ ipc_dir, "status.json" }) catch return null;
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 120) {
        if (Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20))) |text| {
            defer gpa.free(text);
            const c = jsonInt(text, "cols") orelse 0;
            const r = jsonInt(text, "rows") orelse 0;
            if (c > 0 and r > 0) return .{ .cols = c, .rows = r };
        } else |_| {}
        sleepMs(io, 120);
    }
    return null;
}

/// The developer's own `config.zon`, read-only, for the two layout keys
/// the harness copies. The stable root, not the dev one: the dev profile
/// is a scratch copy, and the settings a person actually lives in are in
/// the one they opened first.
fn readUserMnmlConfig(gpa: Allocator, io: Io, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    const p = std.fs.path.join(gpa, &.{ home, ".config", "mnml", "config.zon" }) catch return null;
    return Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch null;
}

fn readUserGhosttyConfig(gpa: Allocator, io: Io, env: *std.process.Environ.Map) ?[]u8 {
    const home = env.get("HOME") orelse return null;
    const p = std.fs.path.join(gpa, &.{ home, ".config", "ghostty", "config" }) catch return null;
    return Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 * 1024)) catch null;
}

fn envWith(gpa: Allocator, io: Io, base: *std.process.Environ.Map, pairs: []const struct { []const u8, []const u8 }) !std.process.Environ.Map {
    _ = io;
    var m = try base.clone(gpa);
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

fn waitForWindow(io: Io, pid: i32, title: []const u8, timeout_ms: u64) ?mac.Window {
    var waited: u64 = 0;
    var buf: [32]mac.Window = undefined;
    while (waited < timeout_ms) : (waited += 120) {
        for (mac.windowsOf(pid, &buf)) |win| {
            if (std.mem.eql(u8, win.title(), title)) return win;
        }
        // A ghostty that died (a bad config, a missing binary) will never
        // produce a window; say so at once rather than at the timeout.
        if (!mac.processAlive(pid)) return null;
        sleepMs(io, 120);
    }
    return null;
}

fn waitForStatus(gpa: Allocator, io: Io, ipc_dir: []const u8, timeout_ms: u64) bool {
    const p = std.fs.path.join(gpa, &.{ ipc_dir, "status.json" }) catch return false;
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 120) {
        if (Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20))) |text| {
            gpa.free(text);
            return true;
        } else |_| {}
        sleepMs(io, 120);
    }
    return false;
}

fn readGrid(gpa: Allocator, io: Io, ipc_dir: []const u8) struct { cols: u16, rows: u16 } {
    const p = std.fs.path.join(gpa, &.{ ipc_dir, "status.json" }) catch return .{ .cols = 0, .rows = 0 };
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch return .{ .cols = 0, .rows = 0 };
    defer gpa.free(text);
    return .{ .cols = jsonInt(text, "cols") orelse 0, .rows = jsonInt(text, "rows") orelse 0 };
}

fn jsonInt(text: []const u8, key: []const u8) ?u16 {
    var buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const rest = text[at + needle.len ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u16, rest[0..n], 10) catch null;
}

// ─── the acting verbs ───────────────────────────────────────────────────

/// macOS routes synthetic KEY events to the ACTIVE application only: a
/// harness window that is not frontmost is handed the keystroke and
/// drops it, silently, which looked exactly like mnml ignoring the key.
/// So the keyboard verbs check first and refuse — they never take focus
/// on their own, because taking the keyboard is the one thing this tool
/// does that the person at the machine will notice.
fn requireFront(s: *Session, e: *Io.Writer) bool {
    const front = mac.frontWindowPid() orelse return true;
    if (front == s.rec.pid) return true;
    e.print(
        "mnml-drive: refusing — the harness is not the active application (pid {d} is), and macOS\n" ++
            "  delivers synthetic keys only to the active one. Nothing was posted.\n" ++
            "  Run `mnml-drive focus --data-root <root>` first; it takes the keyboard from you\n" ++
            "  until you click back, which is why it is a separate verb and never automatic.\n",
        .{front},
    ) catch {};
    return false;
}

fn sendKeys(io: Io, s: *Session, spec: []const u8, e: *Io.Writer) !u8 {
    if (!requireFront(s, e)) return exit_refused;
    var buf: [keys.max_seq]keys.Key = undefined;
    const chain = keys.parseSpec(spec, &buf) catch |err| {
        try e.print("mnml-drive key: {s} in `{s}`\n", .{ @errorName(err), spec });
        return exit_usage;
    };
    for (chain) |k| {
        const st = keys.stroke(k) catch {
            try e.print("mnml-drive key: `{s}` has no key on a US layout — use `type` for text\n", .{spec});
            return exit_usage;
        };
        mac.postKey(s.rec.pid, st.keycode, st.flags);
        // A chord CHAIN is several presses, and mnml's chord timeout is
        // real time: back to back they arrive as one burst and the
        // sequence resolves, but a terminal that coalesces would lose
        // the middle. 12 ms is under the timeout and over the coalesce.
        if (chain.len > 1) sleepMs(io, 12);
    }
    return 0;
}

fn sendText(gpa: Allocator, io: Io, s: *Session, text: []const u8, e: *Io.Writer) !u8 {
    if (!requireFront(s, e)) return exit_refused;
    var it = std.unicode.Utf8View.init(text) catch {
        try e.writeAll("mnml-drive type: the text is not valid UTF-8\n");
        return exit_usage;
    };
    var cps = it.iterator();
    while (cps.nextCodepoint()) |cp| {
        var u16buf: [2]u16 = undefined;
        const n = std.unicode.utf16CodepointSequenceLength(cp) catch 1;
        _ = std.unicode.utf8ToUtf16Le(u16buf[0..n], utf8Of(gpa, cp)) catch continue;
        mac.postText(s.rec.pid, u16buf[0..n]);
        sleepMs(io, 4);
    }
    return 0;
}

fn utf8Of(gpa: Allocator, cp: u21) []const u8 {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return "?";
    return gpa.dupe(u8, buf[0..n]) catch "?";
}

/// A mouse event has to go through the global tap to be routed at all
/// (`mac.postMouseMove`'s comment says why), so before one is posted the
/// harness proves that the spot it is about to click belongs to it: the
/// window the SERVER would deliver to at that exact point is ours, and
/// the harness is the active app. Anything over our window — a
/// notification, a Spotlight panel, the developer's own terminal — and
/// nothing is posted.
fn pointIsOurs(s: *Session, p: mac.CGPoint, e: *Io.Writer) bool {
    if (!requireFront(s, e)) return false;
    const top = mac.topWindowAt(p) orelse {
        e.print("mnml-drive: refusing — no window at {d:.0},{d:.0}; nothing was posted\n", .{ p.x, p.y }) catch {};
        return false;
    };
    if (top.pid == s.rec.pid and top.id == s.rec.window_id) return true;
    e.print(
        "mnml-drive: refusing — the window at {d:.0},{d:.0} is {d} (window {d}), not the harness\n" ++
            "  (pid {d}, window {d}). Something is on top of it. Nothing was posted.\n",
        .{ p.x, p.y, top.pid, top.id, s.rec.pid, s.rec.window_id },
    ) catch {};
    return false;
}

fn mouse(io: Io, s: *Session, verb: []const u8, cx: u16, cy: u16, e: *Io.Writer) !u8 {
    if (offGrid(s, cx, cy, e)) return exit_usage;
    const c = s.rec.cellCentre(cx, cy);
    const p: mac.CGPoint = .{ .x = c.x, .y = c.y };
    if (!pointIsOurs(s, p, e)) return exit_refused;
    const before = mac.cursorPosition();
    // The pointer is moved for real because a terminal decides hover
    // state from where the cursor IS, not from the event's coordinate;
    // it goes back so the developer's pointer does not end up parked in
    // the harness window.
    mac.warpCursor(p);
    defer mac.warpCursor(before);
    mac.postMouseMove(s.rec.window_id, p);
    if (std.mem.eql(u8, verb, "hover")) {
        sleepMs(io, 30);
        return 0;
    }
    if (std.mem.eql(u8, verb, "doubleclick")) {
        mac.postClick(s.rec.window_id, p, .left, 1);
        mac.postClick(s.rec.window_id, p, .left, 2);
    } else {
        mac.postClick(s.rec.window_id, p, if (std.mem.eql(u8, verb, "rightclick")) .right else .left, 1);
    }
    sleepMs(io, 30);
    return 0;
}

fn drag(io: Io, s: *Session, fx: u16, fy: u16, tx: u16, ty: u16, e: *Io.Writer) !u8 {
    if (offGrid(s, fx, fy, e) or offGrid(s, tx, ty, e)) return exit_usage;
    const from = s.rec.cellCentre(fx, fy);
    if (!pointIsOurs(s, .{ .x = from.x, .y = from.y }, e)) return exit_refused;
    const before = mac.cursorPosition();
    defer mac.warpCursor(before);
    const a = s.rec.cellCentre(fx, fy);
    mac.warpCursor(.{ .x = a.x, .y = a.y });
    mac.postDragStep(s.rec.window_id, .{ .x = a.x, .y = a.y }, .down);
    // One event per cell along the way, as the headless driver's `drag`
    // does: a selection that reads every intermediate position gets the
    // same path under both drivers.
    const steps: u16 = @max(absDiff(fx, tx), absDiff(fy, ty));
    var i: u16 = 1;
    while (i <= steps) : (i += 1) {
        const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(steps, 1)));
        const cx = lerp(fx, tx, f);
        const cy = lerp(fy, ty, f);
        const p = s.rec.cellCentre(cx, cy);
        mac.warpCursor(.{ .x = p.x, .y = p.y });
        mac.postDragStep(s.rec.window_id, .{ .x = p.x, .y = p.y }, .move);
        sleepMs(io, 6);
    }
    const b = s.rec.cellCentre(tx, ty);
    mac.postDragStep(s.rec.window_id, .{ .x = b.x, .y = b.y }, .up);
    sleepMs(io, 30);
    return 0;
}

fn scroll(io: Io, s: *Session, cx: u16, cy: u16, up: bool, notches: i32, e: *Io.Writer) !u8 {
    if (offGrid(s, cx, cy, e)) return exit_usage;
    const at = s.rec.cellCentre(cx, cy);
    if (!pointIsOurs(s, .{ .x = at.x, .y = at.y }, e)) return exit_refused;
    const before = mac.cursorPosition();
    defer mac.warpCursor(before);
    const c = s.rec.cellCentre(cx, cy);
    const p: mac.CGPoint = .{ .x = c.x, .y = c.y };
    mac.warpCursor(p);
    var i: i32 = 0;
    while (i < notches) : (i += 1) {
        mac.postScroll(s.rec.window_id, p, if (up) 1 else -1);
        sleepMs(io, 20);
    }
    sleepMs(io, 30);
    return 0;
}

fn offGrid(s: *Session, cx: u16, cy: u16, e: *Io.Writer) bool {
    if (cx < s.rec.cols and cy < s.rec.rows) return false;
    e.print("mnml-drive: cell {d},{d} is off a {d}x{d} grid\n", .{ cx, cy, s.rec.cols, s.rec.rows }) catch {};
    return true;
}

fn absDiff(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

fn lerp(a: u16, b: u16, f: f64) u16 {
    const av: f64 = @floatFromInt(a);
    const bv: f64 = @floatFromInt(b);
    return @intFromFloat(@round(av + (bv - av) * f));
}

// ─── reading back ───────────────────────────────────────────────────────

fn shot(gpa: Allocator, io: Io, s: *Session, path: []const u8, e: *Io.Writer) !u8 {
    // `screencapture -l <id>` photographs ONE window by id — never a
    // region of the screen, so nothing of the developer's can be in the
    // frame even if their window is on top of the harness's.
    const id = try std.fmt.allocPrint(gpa, "{d}", .{s.rec.window_id});
    var child = std.process.spawn(io, .{
        .argv = &.{ "screencapture", "-x", "-o", "-l", id, path },
        .stdin = .ignore,
        .stdout = .ignore,
    }) catch |err| {
        try e.print("mnml-drive shot: screencapture: {s}\n", .{@errorName(err)});
        return exit_refused;
    };
    const term = child.wait(io) catch |err| {
        try e.print("mnml-drive shot: screencapture: {s}\n", .{@errorName(err)});
        return exit_refused;
    };
    if (term != .exited or term.exited != 0) {
        try e.writeAll("mnml-drive shot: screencapture refused (Screen Recording granted to this terminal?)\n");
        return exit_refused;
    }
    return 0;
}

fn pixel(s: *Session, args: []const [:0]const u8, cx: u16, cy: u16, w: *Io.Writer, e: *Io.Writer) !u8 {
    if (offGrid(s, cx, cy, e)) return exit_usage;
    var img = mac.captureWindow(s.rec.window_id) orelse {
        try e.writeAll("mnml-drive pixel: could not capture the window (Screen Recording?)\n");
        return exit_refused;
    };
    defer img.deinit();
    // The capture is in the display's backing pixels; the record's
    // geometry is in points. One scale factor converts, and deriving it
    // from the capture rather than assuming 2 keeps a non-Retina display
    // honest.
    const scale: f64 = if (s.rec.w > 0) @as(f64, @floatFromInt(img.width)) / s.rec.w else 1;
    // Where in the cell: the centre unless `--fx` / `--fy` (0..1 across
    // the cell) say otherwise. A half-block glyph — the pane rail's `▌`
    // — fills only the left half, and its centre sample is background.
    const fx = std.math.clamp(flagFloat(args, "--fx") orelse 0.5, 0.0, 0.999);
    const fy = std.math.clamp(flagFloat(args, "--fy") orelse 0.5, 0.0, 0.999);
    const cx_pt = s.rec.x + (@as(f64, @floatFromInt(cx)) + fx) * s.rec.cellW();
    const cy_pt = s.rec.y + (@as(f64, @floatFromInt(cy)) + fy) * s.rec.cellH();
    const px: usize = @intFromFloat(@max((cx_pt - s.rec.x) * scale, 0));
    const py: usize = @intFromFloat(@max((cy_pt - s.rec.y) * scale, 0));
    const got = img.rgb(px, py) orelse {
        try e.print("mnml-drive pixel: {d},{d} is outside the {d}x{d} capture\n", .{ px, py, img.width, img.height });
        return exit_refused;
    };
    try w.print("#{x:0>2}{x:0>2}{x:0>2}\n", .{ got[0], got[1], got[2] });
    if (flagValue(args, "--expect")) |want_text| {
        const want = parseHex(want_text) orelse {
            try e.writeAll("mnml-drive pixel: --expect takes #RRGGBB\n");
            return exit_usage;
        };
        const tol = flagInt(u16, args, "--tolerance") orelse 8;
        for (0..3) |i| {
            const d = if (got[i] > want[i]) got[i] - want[i] else want[i] - got[i];
            if (d > tol) {
                try e.print("mnml-drive pixel: cell {d},{d} is #{x:0>2}{x:0>2}{x:0>2}, expected #{x:0>2}{x:0>2}{x:0>2} ±{d}\n", .{ cx, cy, got[0], got[1], got[2], want[0], want[1], want[2], tol });
                return 1;
            }
        }
    }
    return 0;
}

fn parseHex(s: []const u8) ?[3]u8 {
    if (s.len != 7 or s[0] != '#') return null;
    const v = std.fmt.parseInt(u24, s[1..], 16) catch return null;
    return .{ @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

fn catDump(gpa: Allocator, io: Io, ipc_dir: []const u8, name: []const u8, w: *Io.Writer, e: *Io.Writer) !u8 {
    const p = try std.fs.path.join(gpa, &.{ ipc_dir, name });
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(8 << 20)) catch {
        try e.print("mnml-drive: no {s} yet at {s}\n", .{ name, p });
        return exit_refused;
    };
    try w.writeAll(text);
    return 0;
}

/// Block until `screen.txt` is written again. The mtime is the signal
/// mnml already produces — the loop rewrites the file every frame it
/// draws — so nothing new has to be added to the app for a host to know
/// a frame landed.
fn waitFrame(gpa: Allocator, io: Io, ipc_dir: []const u8, timeout_ms: u64) bool {
    const p = std.fs.path.join(gpa, &.{ ipc_dir, "screen.txt" }) catch return false;
    const before: i96 = statMtime(io, p) orelse 0;
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 15) {
        if (statMtime(io, p)) |now| {
            if (now != before) return true;
        }
        sleepMs(io, 15);
    }
    return false;
}

fn statMtime(io: Io, path: []const u8) ?i96 {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    return st.mtime.nanoseconds;
}

fn quit(io: Io, s: *Session, w: *Io.Writer) !u8 {
    // Ctrl+Q is mnml's own quit, so the app saves and exits the way it
    // would for a person. Only if that does not take does the harness
    // signal — and only its OWN pid, never a search for "a ghostty".
    const st = keys.stroke(keys.parseChord("ctrl+q").?) catch unreachable;
    mac.postKey(s.rec.pid, st.keycode, st.flags);
    var waited: u64 = 0;
    while (waited < 4000) : (waited += 100) {
        if (!mac.processAlive(s.rec.pid)) {
            try w.writeAll("quit\n");
            return 0;
        }
        sleepMs(io, 100);
    }
    _ = std.c.kill(s.rec.pid, .TERM);
    waited = 0;
    while (waited < 2000) : (waited += 100) {
        if (!mac.processAlive(s.rec.pid)) break;
        sleepMs(io, 100);
    }
    try w.writeAll("quit (SIGTERM)\n");
    return 0;
}

// ─── argument plumbing ──────────────────────────────────────────────────

fn flagValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) {
            if (i + 1 < args.len) return args[i + 1];
            return null;
        }
        if (args[i].len > name.len + 1 and std.mem.startsWith(u8, args[i], name) and args[i][name.len] == '=') {
            return args[i][name.len + 1 ..];
        }
    }
    return null;
}

fn flagFloat(args: []const [:0]const u8, name: []const u8) ?f64 {
    const v = flagValue(args, name) orelse return null;
    return std.fmt.parseFloat(f64, v) catch null;
}

fn hasFlag(args: []const [:0]const u8, name: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn flagInt(comptime T: type, args: []const [:0]const u8, name: []const u8) ?T {
    const v = flagValue(args, name) orelse return null;
    return std.fmt.parseInt(T, v, 10) catch null;
}

/// The first two positional arguments, as cell coordinates.
fn cellArgs(args: []const [:0]const u8) ?[2]u16 {
    var found: [2]u16 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len and n < 2) : (i += 1) {
        if (args[i].len > 0 and args[i][0] == '-') break;
        found[n] = std.fmt.parseInt(u16, args[i], 10) catch return null;
        n += 1;
    }
    return if (n == 2) found else null;
}

fn sleepMs(io: Io, ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

test {
    _ = keys;
    _ = harness;
}

test "the usage text names every flag launch reads, and --size by the words it takes" {
    // It said `[--size PT]`: `--size` takes a name and the point size is
    // `--font-size`, so the one line meant to save a trip to DRIVE.md
    // sent the reader to the wrong flag.
    for ([_][]const u8{ "--workspace", "--data-root", "--cols", "--rows", "--exe", "--ghostty", "--timeout", "--font-size PT", "--size small|corpus|full" }) |flag| {
        try std.testing.expect(std.mem.indexOf(u8, usage_text, flag) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--size PT") == null);
}

/// What a `full` launch should fill: the user's own largest ghostty
/// window when one is open — "the size I usually work at" — and
/// otherwise the main display, less the menu bar.
///
/// Their window is only ever MEASURED. It is never raised, moved,
/// focused or driven; the harness reads its bounds out of the window
/// list and forgets it.
fn fullTargetArea(own_pid: i32, screen: mac.CGRect, menu_bar_pt: f64) mac.CGSize {
    const fallback: mac.CGSize = .{ .width = screen.size.width, .height = screen.size.height - menu_bar_pt };
    var best: ?mac.CGSize = null;
    var buf: [32]mac.Window = undefined;
    for (mac.ghosttyPids(own_pid)) |pid| {
        for (mac.windowsOf(pid, &buf)) |win| {
            const area = win.w * win.h;
            if (best == null or area > best.?.width * best.?.height) best = .{ .width = win.w, .height = win.h };
        }
    }
    const target = best orelse fallback;
    // Never larger than the display the harness has to fit on.
    return .{
        .width = @min(target.width, fallback.width),
        .height = @min(target.height, fallback.height),
    };
}
