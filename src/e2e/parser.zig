//! The `.test` script grammar. One statement per line; `#` comments and
//! blank lines are skipped. Steps drive the editor, expectations assert on
//! the rendered screen or app state:
//!
//! ```text
//! write <relpath> <content>      # seed a fixture in the temp workspace ("\n" → newline)
//! open  <relpath>                # open it in an editor pane (focuses the pane)
//! key   <keyspec>                # send one chord — "ctrl+s", "enter", "down", "esc", "a", …
//! type  <text>                   # type literal text, char by char ("\n" → Enter)
//! command <id>                   # run a registered command by id
//! command! <id>                  # run it, and it must FAIL — a script's
//!                                #   command whose `run` errors (a plain
//!                                #   `command` step fails on that)
//! ex <cmdline>                   # run an ex command — `ex bd!` runs `:bd!`
//! wait  <ms>                     # sleep while ticking (for async/pty steps)
//! snippet <scope> <trig> <expansion>  # seed a [snippets.<scope>] entry
//! shell <cmd>                    # `$SHELL -c` in the workspace with the file's env
//!                                #   (`# env:`, `$MNML_E2E_WORKSPACE`); non-zero exit fails.
//!                                #   Every shell step runs in the file's own process
//!                                #   group (`$MNML_AGENTS_PGID`, which the App's session
//!                                #   scan is limited to); the file's end kills the group
//! serve <port> <status> [delay=<ms>] <text>  # an HTTP server on 127.0.0.1:<port> for this file:
//!                                #   <text> is "Name: value\n…\n\n<body>" (headers, a blank
//!                                #   line, the body) or just the body; delay= waits before
//!                                #   the body goes out (a server that never finishes);
//!                                #   the text `@echo` answers with the request as it
//!                                #   arrived (request line, headers, body) as text/plain.
//!                                #   Port 0 is the one to use: the runner binds a free
//!                                #   port for each `serve 0` when the file starts, and
//!                                #   `${SERVE_PORT}` (the first) / `${SERVE_PORT_<n>}`
//!                                #   name them anywhere in the file, `# env:` lines
//!                                #   included — a fixed port collides with another run
//! ghost <text>                   # inject an AI ghost-text suggestion on the active editor
//! click <x> <y>                  # left-click at screen cell (x,y) — 0-based
//! rightclick <x> <y>             # right-click (context menus)
//! hover <x> <y>                  # move the pointer to a cell, no button (menu rows, hover-switch)
//! doubleclick <x> <y>            # double-click (row activation)
//! scroll <x> <y> <up|down>       # mouse wheel at (x,y)
//! drag <fx> <fy> <tx> <ty>       # left-button drag, one event per cell
//! expect screen contains <text>  # the rendered screen contains the substring
//! expect screen lacks <text>     # …does not
//! expect status contains <text>  # `status.json` contains the substring —
//!                                #   focus, the editor cursor's line/col, the
//!                                #   mode, `cursorShape` (block | bar |
//!                                #   underline | hidden), which is the only
//!                                #   way a headless script sees which surface
//!                                #   owns the terminal cursor, `cmdline`,
//!                                #   whether the app's own `:` line is open,
//!                                #   and `ghost` (idle | armed | inflight |
//!                                #   shown | empty | error), what AI inline
//!                                #   suggestion is doing — the only way to
//!                                #   wait for a request that answers on a
//!                                #   worker seconds later, and `settings`
//!                                #   ({top, visible, atTop, atEnd} | null),
//!                                #   the Settings overlay's list window —
//!                                #   the footer's `22/98` without the total
//!                                #   that moves every time a row lands
//! expect status lacks <text>     # …does not
//! expect dirty <true|false>      # the active editor's dirty flag
//! expect quit <true|false>       # has the app asked to quit? After a
//!                                #   `true` the runner stops stepping the
//!                                #   app, and only `expect quit`,
//!                                #   `expect status` and `expect file`
//!                                #   still mean anything
//! expect pane <text>             # the active pane's title contains the substring
//! expect highlights at_least <n> # ≥ n syntax spans on the active editor
//! expect file <relpath> contains <text>  # the workspace file contains it
//! expect file <relpath> lacks <text>     # …does not
//! expect color <x> <y> <fg|bg> [not] #RRGGBB
//!                                # the cell's resolved colour — the only
//!                                #   way a script can see one, since the
//!                                #   screen dump carries no style
//! expect color <x> <y> <fg|bg> [not] index <N>
//!                                # …or its palette index (0..255), for a
//!                                #   colour the terminal owns — the
//!                                #   terminal chip's bright white is
//!                                #   `index 15`, never an rgb
//! expect within <ms> <expectation>  # any expectation above, polled for up
//!                                #   to <ms> instead of the runner's 3 s
//!                                #   budget: it answers the moment it
//!                                #   holds, so a startup that is slow
//!                                #   under load costs a loaded machine
//!                                #   the time and an idle one nothing —
//!                                #   where a `wait <ms>` before a plain
//!                                #   expect costs both the full <ms> and
//!                                #   still fails past it
//! ```
//!
//! `<text>` may be wrapped in `"…"` (one layer stripped); inside it `\n`
//! `\t` `\\` `\"` are unescaped. Anything else is an error that names the
//! line.
//!
//! The leading comment block may carry runner directives:
//! `# ascii` (the App starts in `--ascii` mode),
//! `# requires: network` (skipped unless opted in), `# width: 120` (runs
//! at that width only), `# height: 14` (that height only — a menu taller
//! than the screen needs a short one), `# sizes: all` (this file's
//! assertions are size-independent, so a sweep evaluates them at every
//! rung instead of only at 120×40), `# env: NAME=value` (set in the App's environment
//! for this file — `MNML_NOW_PLAYING` for the statusline's cluster; at
//! most `Header.max_env` of them, and one more is a parse error rather
//! than a line that disappears), and
//! `# shared-data-root` (this file wants the run's one data root instead
//! of the private one every file gets), and `# requires: optimized`
//! (this file's deadlines are pinned outside the runner — an offline
//! server started with `--lifetime-secs 180` — so an unoptimized build
//! announces it as skipped instead of failing it on the clock).

const std = @import("std");
const Allocator = std.mem.Allocator;
const key = @import("../core/key.zig");
const keymap = @import("../core/keymap.zig");

pub const MouseAction = enum { click, right_click, double_click, hover, scroll_up, scroll_down };

pub const Step = union(enum) {
    write: struct { rel: []const u8, content: []const u8 },
    open: []const u8,
    key: key.Key,
    type: []const u8,
    command: []const u8,
    /// `command! <id>`: the command runs and must fail.
    command_fails: []const u8,
    ex: []const u8,
    wait: u64,
    snippet: struct { scope: []const u8, trigger: []const u8, expansion: []const u8 },
    shell: []const u8,
    serve: struct { port: u16, status: u16, delay_ms: u32, text: []const u8 },
    ghost: []const u8,
    mouse: struct { x: u16, y: u16, action: MouseAction },
    drag: struct { from_x: u16, from_y: u16, to_x: u16, to_y: u16 },
    /// `shot <name>`: leave a picture of the screen for whoever reads
    /// the run afterwards. Every driver understands it and none of them
    /// fails on it — headless has no pixels and does nothing, the real
    /// ghostty window writes `<name>.png` under the run's shot
    /// directory. A hunter's script can ask for one at the moment it
    /// cares about without knowing which driver it is running under.
    shot: []const u8,
};

/// What `expect color` compares against: an rgb triple, or a palette
/// index.
pub const ColorWant = union(enum) {
    rgb: [3]u8,
    index: u8,
};

pub const Check = union(enum) {
    screen_contains: []const u8,
    screen_lacks: []const u8,
    dirty: bool,
    pane_title: []const u8,
    file_contains: struct { rel: []const u8, text: []const u8 },
    file_lacks: struct { rel: []const u8, text: []const u8 },
    highlights_at_least: usize,
    /// A substring of `status.json`. That file is the host's view of the
    /// app — focus, the editor cursor's line and column, the mode,
    /// `cursorShape`, which is the only way a headless script can see
    /// which surface owns the terminal cursor (nothing draws one), and
    /// `cmdline`, whether the app's own `:` line is open.
    status_contains: []const u8,
    status_lacks: []const u8,
    /// Has the app asked to quit? `status.json` carries the same flag,
    /// but a script that leaned on its TEXT (`expect status contains
    /// "\"quit\":true"`) was asserting on a spelling; and the screen is
    /// no oracle at all here, because the runner used to keep drawing a
    /// quit app, so its last frame looked alive.
    quit: bool,
    /// A cell's foreground or background, as a theme resolves it: the
    /// only way a `.test` can see a colour (the screen dump carries
    /// none). `expect color X Y fg #61afef`, `… bg not #1e222a`,
    /// `… fg index 15` for a palette-indexed colour.
    color: struct { x: u16, y: u16, bg: bool, want: ColorWant, negated: bool },
};

pub const Stmt = union(enum) {
    step: Step,
    check: Check,
};

pub const Line = struct {
    /// 1-based.
    ln: usize,
    stmt: Stmt,
    /// `expect within <ms> …`: this check's own polling budget, never
    /// shorter than the runner's. Null for every other line.
    budget_ms: ?u64 = null,
};

/// Directives from the leading comment block.
pub const Header = struct {
    requires_network: bool = false,
    /// `# requires: macos` (also `linux`, `windows`): the file only runs
    /// on that OS, and is announced as skipped anywhere else. For a
    /// screen only one platform can paint — the first-launch wizard's
    /// Option-as-Alt fix writes ghostty's `macos-option-as-alt`, which
    /// exists nowhere else, so elsewhere the row says there is no fix.
    requires_os: ?std.Target.Os.Tag = null,
    /// `# requires: optimized`: the file's timings only hold against a
    /// shipped build, so an unoptimized one announces it as skipped
    /// rather than failing it. Not a get-out — it is for a file whose
    /// deadlines are pinned OUTSIDE the runner and so cannot be scaled
    /// with the build: the `wait <ms>` a script spells out, and the
    /// `--life-secs` it gives the offline server it starts itself. One
    /// family carries it — the files that mount a real integration child
    /// against a server they start themselves — because which member of
    /// it falls over in a Debug build depends on what else the machine
    /// is doing. Nothing outside that family has needed the mark.
    requires_optimized: bool = false,
    /// `# shared-data-root`: this file wants the run's one data root
    /// rather than the private one every file otherwise gets. Nothing in
    /// the corpus asks for it; it exists so a file that genuinely needs
    /// to see another's installs can say so out loud.
    shared_data_root: bool = false,
    width: ?u16 = null,
    height: ?u16 = null,
    /// `# sizes: all`: this file's content assertions hold at EVERY size
    /// the sweep runs it at, not only at 120×40. Without it a sweep rung
    /// other than the corpus size evaluates nothing (the runner reports
    /// it as `ok*  … (structure only)`), because a file written for
    /// 120×40 says things about 120×40. Use it for a file whose every
    /// assertion is size-INDEPENDENT — a status flag, a file on disk, a
    /// pane title, a short string that cannot reflow — so the sweep
    /// checks behaviour at each rung instead of only proving nothing
    /// panicked. A file that names its own `# width:` / `# height:` is
    /// already asserting at its one size, and that wins.
    sizes_all: bool = false,
    /// `# ascii`: the App starts with `ui.ascii_icons` on, as
    /// `mnml-zig --ascii` does. A terminal with no Nerd Font is a
    /// shipped mode, and the only way a script can prove a glyph's
    /// twin is really painted is to run the whole App in it.
    ascii: bool = false,
    /// `# env: NAME=value` lines, in order; slices of the text parsed.
    env: [max_env]EnvPair = undefined,
    env_len: usize = 0,
    /// More `# env:` lines than `max_env`. They used to be dropped where
    /// they stood, and a file whose last line went missing failed a long
    /// way from the cause — the pane reached the real API instead of the
    /// test double, with nothing on screen to say why. `parse` turns
    /// this into a syntax error.
    env_overflow: bool = false,

    pub const max_env = 16;
    pub const EnvPair = struct { key: []const u8, value: []const u8 };

    pub fn envPairs(h: *const Header) []const EnvPair {
        return h.env[0..h.env_len];
    }
};

/// A parsed script. Every slice lives in `arena`.
pub const Script = struct {
    arena: std.heap.ArenaAllocator,
    header: Header,
    lines: []const Line,

    pub fn deinit(self: *Script) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Why parsing stopped: `line N: …`, ready to print.
pub const Diagnostic = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) error{Syntax} {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
        self.len = s.len;
        return error.Syntax;
    }
};

pub const Error = error{ Syntax, OutOfMemory };

pub fn parse(gpa: Allocator, text: []const u8, diag: *Diagnostic) Error!Script {
    const header = parseHeader(text);
    if (header.env_overflow) return diag.set("more than {d} `# env:` lines; the rest would be dropped", .{Header.max_env});
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayList(Line) = .empty;

    var it = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    while (it.next()) |raw| {
        ln += 1;
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const head, const rest = split1(line);
        var budget: ?u64 = null;
        const stmt: Stmt = if (std.meta.stringToEnum(Keyword, head)) |kw| switch (kw) {
            .write => blk: {
                const rel, const content = split1(rest);
                if (rel.len == 0) return diag.set("line {d}: `write` needs a path", .{ln});
                break :blk .{ .step = .{ .write = .{ .rel = rel, .content = try unescape(a, content) } } };
            },
            .open => blk: {
                if (rest.len == 0) return diag.set("line {d}: `open` needs a path", .{ln});
                break :blk .{ .step = .{ .open = trim(rest) } };
            },
            .key => blk: {
                const spec = trim(rest);
                const k = keymap.parseKeySpec(spec) orelse return diag.set("line {d}: unrecognised key spec `{s}`", .{ ln, spec });
                break :blk .{ .step = .{ .key = k } };
            },
            .type => .{ .step = .{ .type = try unescape(a, rest) } },
            .command => blk: {
                if (rest.len == 0) return diag.set("line {d}: `command` needs an id", .{ln});
                break :blk .{ .step = .{ .command = trim(rest) } };
            },
            .@"command!" => blk: {
                if (rest.len == 0) return diag.set("line {d}: `command!` needs an id", .{ln});
                break :blk .{ .step = .{ .command_fails = trim(rest) } };
            },
            .ex => blk: {
                if (rest.len == 0) return diag.set("line {d}: `ex` needs an ex command", .{ln});
                break :blk .{ .step = .{ .ex = trim(rest) } };
            },
            .wait => blk: {
                const ms = std.fmt.parseInt(u64, trim(rest), 10) catch return diag.set("line {d}: `wait` needs a millisecond count", .{ln});
                break :blk .{ .step = .{ .wait = ms } };
            },
            .snippet => blk: {
                const scope, const rest1 = split1(rest);
                const trigger, const expansion = split1(rest1);
                if (scope.len == 0 or trigger.len == 0) return diag.set("line {d}: `snippet` needs <scope> <trigger> <expansion>", .{ln});
                break :blk .{ .step = .{ .snippet = .{ .scope = scope, .trigger = trigger, .expansion = try unescape(a, expansion) } } };
            },
            .shell => blk: {
                const cmd = trim(rest);
                if (cmd.len == 0) return diag.set("line {d}: `shell` needs a command", .{ln});
                break :blk .{ .step = .{ .shell = cmd } };
            },
            .serve => blk: {
                const port_s, const rest1 = split1(rest);
                const status_s, var rest2 = split1(rest1);
                const port = std.fmt.parseInt(u16, port_s, 10) catch return diag.set("line {d}: `serve` needs <port> <status> [delay=<ms>] <text>", .{ln});
                const status = std.fmt.parseInt(u16, status_s, 10) catch return diag.set("line {d}: `serve` needs <port> <status> [delay=<ms>] <text>", .{ln});
                var delay: u32 = 0;
                if (std.mem.startsWith(u8, rest2, "delay=")) {
                    const d, const rest3 = split1(rest2);
                    delay = std.fmt.parseInt(u32, d["delay=".len..], 10) catch return diag.set("line {d}: `serve` delay=<ms>", .{ln});
                    rest2 = rest3;
                }
                break :blk .{ .step = .{ .serve = .{ .port = port, .status = status, .delay_ms = delay, .text = try unescape(a, rest2) } } };
            },
            .ghost => blk: {
                const s = try unescape(a, rest);
                if (s.len == 0) return diag.set("line {d}: `ghost` needs suggestion text", .{ln});
                break :blk .{ .step = .{ .ghost = s } };
            },
            .click, .rightclick, .doubleclick, .hover, .scroll => blk: {
                const xy = try parseXy(diag, ln, head, rest);
                const action: MouseAction = switch (kw) {
                    .click => .click,
                    .rightclick => .right_click,
                    .doubleclick => .double_click,
                    .hover => .hover,
                    else => if (std.mem.eql(u8, trim(xy.rest), "up"))
                        .scroll_up
                    else if (std.mem.eql(u8, trim(xy.rest), "down"))
                        .scroll_down
                    else
                        return diag.set("line {d}: `scroll X Y <up|down>`", .{ln}),
                };
                break :blk .{ .step = .{ .mouse = .{ .x = xy.x, .y = xy.y, .action = action } } };
            },
            .drag => blk: {
                const from = try parseXy(diag, ln, "drag", rest);
                const to = try parseXy(diag, ln, "drag", from.rest);
                break :blk .{ .step = .{ .drag = .{ .from_x = from.x, .from_y = from.y, .to_x = to.x, .to_y = to.y } } };
            },
            .shot => blk: {
                // A bare name, not a path: the driver owns where shots
                // land, and a script that could name `../` would write
                // outside the run directory.
                const name = trim(rest);
                if (name.len == 0) return diag.set("line {d}: `shot` needs a name", .{ln});
                if (std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.eql(u8, name, "..")) {
                    return diag.set("line {d}: `shot` takes a bare name, not a path (`{s}`)", .{ ln, name });
                }
                break :blk .{ .step = .{ .shot = try a.dupe(u8, name) } };
            },
            .expect => blk: {
                const first, const after = split1(rest);
                if (!std.mem.eql(u8, first, "within")) break :blk try parseExpect(a, diag, ln, rest);
                const ms_text, const check_text = split1(after);
                const ms = std.fmt.parseInt(u64, ms_text, 10) catch return diag.set("line {d}: expect within <ms> <expectation> — `{s}` is not a millisecond count", .{ ln, ms_text });
                budget = ms;
                break :blk try parseExpect(a, diag, ln, check_text);
            },
        } else return diag.set("line {d}: unknown statement `{s}`", .{ ln, head });
        try lines.append(a, .{ .ln = ln, .stmt = stmt, .budget_ms = budget });
    }

    return .{ .arena = arena, .header = header, .lines = try lines.toOwnedSlice(a) };
}

const Keyword = enum { write, open, key, type, command, @"command!", ex, wait, snippet, shell, serve, ghost, click, rightclick, doubleclick, hover, scroll, drag, shot, expect };

fn parseExpect(a: Allocator, diag: *Diagnostic, ln: usize, rest: []const u8) Error!Stmt {
    const what, const arg = split1(rest);
    const What = enum { screen, status, dirty, pane, highlights, file, color, quit };
    const kind = std.meta.stringToEnum(What, what) orelse return diag.set("line {d}: unknown expectation `{s}`", .{ ln, what });
    const check: Check = switch (kind) {
        .screen => blk: {
            const op, const text = split1(arg);
            if (std.mem.eql(u8, op, "contains")) break :blk .{ .screen_contains = try unescape(a, text) };
            if (std.mem.eql(u8, op, "lacks")) break :blk .{ .screen_lacks = try unescape(a, text) };
            return diag.set("line {d}: expect screen <contains|lacks> …", .{ln});
        },
        .status => blk: {
            const op, const text = split1(arg);
            if (std.mem.eql(u8, op, "contains")) break :blk .{ .status_contains = try unescape(a, text) };
            if (std.mem.eql(u8, op, "lacks")) break :blk .{ .status_lacks = try unescape(a, text) };
            return diag.set("line {d}: expect status <contains|lacks> …", .{ln});
        },
        .dirty => blk: {
            const v = trim(arg);
            if (std.mem.eql(u8, v, "true")) break :blk .{ .dirty = true };
            if (std.mem.eql(u8, v, "false")) break :blk .{ .dirty = false };
            return diag.set("line {d}: expect dirty <true|false>", .{ln});
        },
        .quit => blk: {
            const v = trim(arg);
            if (std.mem.eql(u8, v, "true")) break :blk .{ .quit = true };
            if (std.mem.eql(u8, v, "false")) break :blk .{ .quit = false };
            return diag.set("line {d}: expect quit <true|false>", .{ln});
        },
        .pane => .{ .pane_title = try unescape(a, arg) },
        .highlights => blk: {
            const op, const num = split1(arg);
            if (!std.mem.eql(u8, op, "at_least")) return diag.set("line {d}: expect highlights at_least <N>", .{ln});
            const min = std.fmt.parseInt(usize, trim(num), 10) catch return diag.set("line {d}: expect highlights at_least <usize>", .{ln});
            break :blk .{ .highlights_at_least = min };
        },
        .color => blk: {
            const xs, const r1 = split1(arg);
            const ys, const r2 = split1(r1);
            const which, const r3 = split1(r2);
            var hex, var after = split1(r3);
            var negated = false;
            if (std.mem.eql(u8, hex, "not")) {
                negated = true;
                hex, after = split1(r3["not".len..]);
            }
            const x = std.fmt.parseInt(u16, xs, 10) catch return diag.set("line {d}: expect color <X> <Y> <fg|bg> [not] #RRGGBB | index <N>", .{ln});
            const y = std.fmt.parseInt(u16, ys, 10) catch return diag.set("line {d}: expect color <X> <Y> <fg|bg> [not] #RRGGBB | index <N>", .{ln});
            const is_bg = if (std.mem.eql(u8, which, "bg")) true else if (std.mem.eql(u8, which, "fg")) false else return diag.set("line {d}: expect color … <fg|bg> …", .{ln});
            const spelt = trim(hex);
            // // changed (dock-polish): `index <N>` — a colour the
            // terminal's palette owns, which no `#RRGGBB` can name.
            if (std.mem.eql(u8, spelt, "index")) {
                const ns, _ = split1(after);
                const n = std.fmt.parseInt(u8, trim(ns), 10) catch return diag.set("line {d}: expect color … index <N> (0..255)", .{ln});
                break :blk .{ .color = .{ .x = x, .y = y, .bg = is_bg, .want = .{ .index = n }, .negated = negated } };
            }
            if (spelt.len != 7 or spelt[0] != '#') return diag.set("line {d}: expect color … #RRGGBB (a `#` and six hex digits) or index <N>", .{ln});
            const body = spelt[1..];
            const v = std.fmt.parseInt(u24, body, 16) catch return diag.set("line {d}: expect color … #RRGGBB (six hex digits)", .{ln});
            break :blk .{ .color = .{ .x = x, .y = y, .bg = is_bg, .want = .{ .rgb = .{ @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) } }, .negated = negated } };
        },
        .file => blk: {
            const rel, const rest1 = split1(arg);
            if (rel.len == 0) return diag.set("line {d}: expect file needs a path", .{ln});
            const op, const text = split1(rest1);
            if (std.mem.eql(u8, op, "contains")) break :blk .{ .file_contains = .{ .rel = rel, .text = try unescape(a, text) } };
            if (std.mem.eql(u8, op, "lacks")) break :blk .{ .file_lacks = .{ .rel = rel, .text = try unescape(a, text) } };
            return diag.set("line {d}: expect file <path> <contains|lacks> …", .{ln});
        },
    };
    return .{ .check = check };
}

const Xy = struct { x: u16, y: u16, rest: []const u8 };

fn parseXy(diag: *Diagnostic, ln: usize, kw: []const u8, rest: []const u8) Error!Xy {
    const xs, const r1 = split1(rest);
    const ys, const r2 = split1(r1);
    const x = std.fmt.parseInt(u16, xs, 10) catch return diag.set("line {d}: `{s}` needs `X Y` cell coordinates", .{ ln, kw });
    const y = std.fmt.parseInt(u16, ys, 10) catch return diag.set("line {d}: `{s}` needs `X Y` cell coordinates", .{ ln, kw });
    return .{ .x = x, .y = y, .rest = r2 };
}

const whitespace = " \t\r\n\x0b\x0c";

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, whitespace);
}

/// The first whitespace-delimited token and the rest with leading
/// whitespace removed.
pub fn split1(s_in: []const u8) struct { []const u8, []const u8 } {
    const s = std.mem.trimStart(u8, s_in, whitespace);
    const i = std.mem.indexOfAny(u8, s, whitespace) orelse return .{ s, "" };
    return .{ s[0..i], std.mem.trimStart(u8, s[i..], whitespace) };
}

/// Strip one optional layer of `"…"` and unescape `\n \t \\ \"`. An
/// unknown escape keeps its backslash; a trailing lone backslash stays.
pub fn unescape(a: Allocator, s_in: []const u8) Allocator.Error![]const u8 {
    const s = trim(s_in);
    const inner = if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s;
    var out = try std.ArrayList(u8).initCapacity(a, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c != '\\') {
            out.appendAssumeCapacity(c);
            continue;
        }
        i += 1;
        if (i >= inner.len) {
            out.appendAssumeCapacity('\\');
            break;
        }
        switch (inner[i]) {
            'n' => out.appendAssumeCapacity('\n'),
            't' => out.appendAssumeCapacity('\t'),
            '\\' => out.appendAssumeCapacity('\\'),
            '"' => out.appendAssumeCapacity('"'),
            else => |other| {
                out.appendAssumeCapacity('\\');
                out.appendAssumeCapacity(other);
            },
        }
    }
    return out.toOwnedSlice(a);
}

/// Runner directives from the leading comment block only — the block ends
/// at the first non-comment, non-blank line.
pub fn parseHeader(text: []const u8) Header {
    var h: Header = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0) continue;
        if (line[0] != '#') break;
        const after_hash = trim(std.mem.trimStart(u8, line, "#"));
        if (std.ascii.startsWithIgnoreCase(after_hash, "requires:")) {
            const what = trim(after_hash["requires:".len..]);
            if (std.ascii.eqlIgnoreCase(what, "network")) h.requires_network = true;
            if (std.ascii.eqlIgnoreCase(what, "macos")) h.requires_os = .macos;
            if (std.ascii.eqlIgnoreCase(what, "linux")) h.requires_os = .linux;
            if (std.ascii.eqlIgnoreCase(what, "windows")) h.requires_os = .windows;
            if (std.ascii.eqlIgnoreCase(what, "optimized")) h.requires_optimized = true;
        }
        if (std.ascii.eqlIgnoreCase(after_hash, "shared-data-root")) h.shared_data_root = true;
        if (std.ascii.eqlIgnoreCase(after_hash, "ascii")) h.ascii = true;
        if (std.ascii.startsWithIgnoreCase(after_hash, "height:")) {
            h.height = std.fmt.parseInt(u16, trim(after_hash["height:".len..]), 10) catch null;
        }
        if (std.ascii.startsWithIgnoreCase(after_hash, "sizes:")) {
            if (std.ascii.eqlIgnoreCase(trim(after_hash["sizes:".len..]), "all")) h.sizes_all = true;
        }
        if (std.ascii.startsWithIgnoreCase(after_hash, "width:")) {
            h.width = std.fmt.parseInt(u16, trim(after_hash["width:".len..]), 10) catch null;
        }
        if (std.ascii.startsWithIgnoreCase(after_hash, "env:")) {
            const spec = trim(after_hash["env:".len..]);
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse continue;
            const name = trim(spec[0..eq]);
            if (name.len == 0) continue;
            if (h.env_len == Header.max_env) {
                h.env_overflow = true;
                continue;
            }
            h.env[h.env_len] = .{ .key = name, .value = spec[eq + 1 ..] };
            h.env_len += 1;
        }
    }
    return h;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn parseOk(src: []const u8) !Script {
    var diag: Diagnostic = .{};
    return parse(t.allocator, src, &diag) catch |e| {
        std.debug.print("unexpected parse failure: {s}\n", .{diag.message()});
        return e;
    };
}

fn parseErr(src: []const u8) ![]const u8 {
    var diag: Diagnostic = .{};
    var script = parse(t.allocator, src, &diag) catch |e| switch (e) {
        error.Syntax => return t.allocator.dupe(u8, diag.message()),
        else => return e,
    };
    script.deinit();
    return error.TestExpectedError;
}

fn expectErr(src: []const u8, want: []const u8) !void {
    const msg = try parseErr(src);
    defer t.allocator.free(msg);
    try t.expectEqualStrings(want, msg);
}

test "a basic script parses with 1-based line numbers" {
    var s = try parseOk(
        \\# a comment
        \\write foo.txt hello
        \\open foo.txt
        \\type " world"
        \\key ctrl+s
        \\expect screen contains "hello world"
        \\expect dirty false
    );
    defer s.deinit();
    try t.expectEqual(@as(usize, 6), s.lines.len);
    try t.expectEqual(@as(usize, 2), s.lines[0].ln);
    try t.expectEqualStrings("foo.txt", s.lines[0].stmt.step.write.rel);
    try t.expectEqualStrings("hello", s.lines[0].stmt.step.write.content);
    try t.expectEqualStrings("foo.txt", s.lines[1].stmt.step.open);
    try t.expectEqualStrings(" world", s.lines[2].stmt.step.type);
    try t.expect(s.lines[3].stmt.step.key.mods.ctrl);
    try t.expectEqual(@as(u21, 's'), s.lines[3].stmt.step.key.code.char);
    try t.expectEqualStrings("hello world", s.lines[4].stmt.check.screen_contains);
    try t.expectEqual(false, s.lines[5].stmt.check.dirty);
    try t.expectEqual(@as(usize, 7), s.lines[5].ln);
}

test "every step directive" {
    var s = try parseOk(
        \\command editor.use_vim
        \\ex bd!
        \\wait 250
        \\snippet rust fn "fn $1() {\n}"
        \\shell git init -q .
        \\ghost "a + b"
        \\click 12 5
        \\rightclick 3 1
        \\doubleclick 8 8
        \\scroll 40 20 down
        \\scroll 40 20 up
        \\drag 1 2 30 2
        \\write dir/x.txt "l1\nl2\ttab \"q\" \\ \z"
    );
    defer s.deinit();
    const L = s.lines;
    try t.expectEqualStrings("editor.use_vim", L[0].stmt.step.command);
    try t.expectEqualStrings("bd!", L[1].stmt.step.ex);
    try t.expectEqual(@as(u64, 250), L[2].stmt.step.wait);
    try t.expectEqualStrings("rust", L[3].stmt.step.snippet.scope);
    try t.expectEqualStrings("fn", L[3].stmt.step.snippet.trigger);
    try t.expectEqualStrings("fn $1() {\n}", L[3].stmt.step.snippet.expansion);
    try t.expectEqualStrings("git init -q .", L[4].stmt.step.shell);
    try t.expectEqualStrings("a + b", L[5].stmt.step.ghost);
    try t.expectEqual(MouseAction.click, L[6].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 12), L[6].stmt.step.mouse.x);
    try t.expectEqual(@as(u16, 5), L[6].stmt.step.mouse.y);
    try t.expectEqual(MouseAction.right_click, L[7].stmt.step.mouse.action);
    try t.expectEqual(MouseAction.double_click, L[8].stmt.step.mouse.action);
    try t.expectEqual(MouseAction.scroll_down, L[9].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 40), L[9].stmt.step.mouse.x);
    try t.expectEqual(MouseAction.scroll_up, L[10].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 30), L[11].stmt.step.drag.to_x);
    try t.expectEqual(@as(u16, 2), L[11].stmt.step.drag.from_y);
    try t.expectEqualStrings("dir/x.txt", L[12].stmt.step.write.rel);
    try t.expectEqualStrings("l1\nl2\ttab \"q\" \\ \\z", L[12].stmt.step.write.content);
}

test "expect quit parses both booleans and is a check, not a step" {
    var s = try parseOk("expect quit false\nexpect quit true\n");
    defer s.deinit();
    try t.expectEqual(false, s.lines[0].stmt.check.quit);
    try t.expectEqual(true, s.lines[1].stmt.check.quit);
}

test "hover is a mouse step with no button" {
    var s = try parseOk("hover 4 9\n");
    defer s.deinit();
    try t.expectEqual(MouseAction.hover, s.lines[0].stmt.step.mouse.action);
    try t.expectEqual(@as(u16, 4), s.lines[0].stmt.step.mouse.x);
    try t.expectEqual(@as(u16, 9), s.lines[0].stmt.step.mouse.y);
    try expectErr("hover 4\n", "line 1: `hover` needs `X Y` cell coordinates");
}

test "every expectation" {
    var s = try parseOk(
        \\expect screen contains "x"
        \\expect screen lacks y z
        \\expect dirty true
        \\expect pane "notes.txt"
        \\expect highlights at_least 12
        \\expect file out.txt contains "a\nb"
        \\expect file out.txt lacks gone
    );
    defer s.deinit();
    const L = s.lines;
    try t.expectEqualStrings("x", L[0].stmt.check.screen_contains);
    try t.expectEqualStrings("y z", L[1].stmt.check.screen_lacks);
    try t.expectEqual(true, L[2].stmt.check.dirty);
    try t.expectEqualStrings("notes.txt", L[3].stmt.check.pane_title);
    try t.expectEqual(@as(usize, 12), L[4].stmt.check.highlights_at_least);
    try t.expectEqualStrings("out.txt", L[5].stmt.check.file_contains.rel);
    try t.expectEqualStrings("a\nb", L[5].stmt.check.file_contains.text);
    try t.expectEqualStrings("gone", L[6].stmt.check.file_lacks.text);
}

test "errors name the line and the directive" {
    try expectErr("open x\nfrobnicate 1\n", "line 2: unknown statement `frobnicate`");
    try expectErr("write\n", "line 1: `write` needs a path");
    try expectErr("open   \n", "line 1: `open` needs a path");
    try expectErr("key ctrl+nope+x\n", "line 1: unrecognised key spec `ctrl+nope+x`");
    try expectErr("command\n", "line 1: `command` needs an id");
    try expectErr("command!\n", "line 1: `command!` needs an id");
    try expectErr("ex\n", "line 1: `ex` needs an ex command");
    try expectErr("wait soon\n", "line 1: `wait` needs a millisecond count");
    try expectErr("snippet rust\n", "line 1: `snippet` needs <scope> <trigger> <expansion>");
    try expectErr("shell   \n", "line 1: `shell` needs a command");
    try expectErr("ghost   \n", "line 1: `ghost` needs suggestion text");
    try expectErr("serve x 200 hi\n", "line 1: `serve` needs <port> <status> [delay=<ms>] <text>");
    try expectErr("serve 19877 200 delay=soon hi\n", "line 1: `serve` delay=<ms>");
    try expectErr("click x y\n", "line 1: `click` needs `X Y` cell coordinates");
    try expectErr("scroll 1 2 sideways\n", "line 1: `scroll X Y <up|down>`");
    try expectErr("drag 1 2 3\n", "line 1: `drag` needs `X Y` cell coordinates");
    try expectErr("expect nothing\n", "line 1: unknown expectation `nothing`");
    try expectErr("expect screen equals x\n", "line 1: expect screen <contains|lacks> …");
    try expectErr("expect dirty maybe\n", "line 1: expect dirty <true|false>");
    try expectErr("expect quit soon\n", "line 1: expect quit <true|false>");
    try expectErr("expect highlights at_most 3\n", "line 1: expect highlights at_least <N>");
    try expectErr("expect highlights at_least many\n", "line 1: expect highlights at_least <usize>");
    try expectErr("expect file\n", "line 1: expect file needs a path");
    try expectErr("expect file a.txt has x\n", "line 1: expect file <path> <contains|lacks> …");
}

test "serve parses its port, status, delay and text" {
    var s = try parseOk("serve 19877 302 \"location: /x\\n\\n\"\nserve 19878 200 delay=1500 late\n");
    defer s.deinit();
    const a = s.lines[0].stmt.step.serve;
    try t.expectEqual(@as(u16, 19877), a.port);
    try t.expectEqual(@as(u16, 302), a.status);
    try t.expectEqual(@as(u32, 0), a.delay_ms);
    try t.expectEqualStrings("location: /x\n\n", a.text);
    const b = s.lines[1].stmt.step.serve;
    try t.expectEqual(@as(u32, 1500), b.delay_ms);
    try t.expectEqualStrings("late", b.text);
}

test "unescape strips one quote layer and the four escapes" {
    const cases = [_][2][]const u8{
        .{ "\"a\\nb\"", "a\nb" },
        .{ "plain", "plain" },
        .{ "\"tab\\there\"", "tab\there" },
        .{ "  \"padded\"  ", "padded" },
        .{ "\"\"", "" },
        .{ "\"", "\"" },
        .{ "\"\"inner\"\"", "\"inner\"" },
        .{ "a\\\\b", "a\\b" },
        .{ "say \\\"hi\\\"", "say \"hi\"" },
        .{ "keep \\q", "keep \\q" },
        .{ "trailing\\", "trailing\\" },
    };
    for (cases) |c| {
        const got = try unescape(t.allocator, c[0]);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c[1], got);
    }
}

test "split1 splits on the first whitespace run" {
    const a, const b = split1("  write  a b ");
    try t.expectEqualStrings("write", a);
    try t.expectEqualStrings("a b ", b);
    const c, const d = split1("solo");
    try t.expectEqualStrings("solo", c);
    try t.expectEqualStrings("", d);
}

test "header directives come only from the leading comment block" {
    try t.expect(parseHeader("# requires: network\nopen x\n").requires_network);
    try t.expect(parseHeader("#   Requires: Network  \n\n# more\nopen x\n").requires_network);
    try t.expect(!parseHeader("open x\n# requires: network\n").requires_network);
    try t.expectEqual(@as(?std.Target.Os.Tag, .macos), parseHeader("# requires: macos\nopen x\n").requires_os);
    try t.expectEqual(@as(?std.Target.Os.Tag, .linux), parseHeader("#  Requires: Linux \nopen x\n").requires_os);
    try t.expectEqual(@as(?std.Target.Os.Tag, null), parseHeader("# requires: network\nopen x\n").requires_os);
    try t.expectEqual(@as(?std.Target.Os.Tag, null), parseHeader("open x\n# requires: macos\n").requires_os);
    try t.expect(parseHeader("# requires: optimized\nopen x\n").requires_optimized);
    try t.expect(parseHeader("# ascii\nopen x\n").ascii);
    try t.expect(parseHeader("#  Ascii \nopen x\n").ascii);
    try t.expect(!parseHeader("open x\n# ascii\n").ascii);
    try t.expect(!parseHeader("# width: 80\nopen x\n").ascii);
    try t.expect(parseHeader("#  Requires: Optimized \nopen x\n").requires_optimized);
    try t.expect(!parseHeader("# requires: network\nopen x\n").requires_optimized);
    try t.expect(!parseHeader("open x\n# requires: optimized\n").requires_optimized);
    try t.expect(parseHeader("# shared-data-root\nopen x\n").shared_data_root);
    try t.expect(parseHeader("#  Shared-Data-Root  \nopen x\n").shared_data_root);
    try t.expect(!parseHeader("# width: 120\nopen x\n").shared_data_root);
    try t.expect(!parseHeader("open x\n# shared-data-root\n").shared_data_root);
    // `# sizes: all`: content assertions count at every rung of a sweep.
    // Only `all` is a value; anything else leaves the flag alone rather
    // than half-enabling a directive nobody wrote.
    try t.expect(parseHeader("# sizes: all\nopen x\n").sizes_all);
    try t.expect(parseHeader("#  Sizes:  All \nopen x\n").sizes_all);
    try t.expect(!parseHeader("# sizes: 80x24\nopen x\n").sizes_all);
    try t.expect(!parseHeader("# width: 80\nopen x\n").sizes_all);
    try t.expect(!parseHeader("open x\n# sizes: all\n").sizes_all);
    try t.expectEqual(@as(?u16, 120), parseHeader("# width: 120\n").width);
    try t.expectEqual(@as(?u16, null), parseHeader("# width: wide\n").width);
    try t.expectEqual(@as(?u16, 14), parseHeader("# height: 14\n").height);
    try t.expectEqual(@as(?u16, null), parseHeader("# height: tall\n").height);
    try t.expectEqual(@as(?u16, null), parseHeader("# height: 14\n").width);
    const env = parseHeader("# env: MNML_NOW_PLAYING=Song|playing|spotify\n# env: EMPTY=\n# env: nokey\n# env: =x\nopen x\n");
    try t.expectEqual(@as(usize, 2), env.envPairs().len);
    try t.expectEqualStrings("MNML_NOW_PLAYING", env.envPairs()[0].key);
    try t.expectEqualStrings("Song|playing|spotify", env.envPairs()[0].value);
    try t.expectEqualStrings("", env.envPairs()[1].value);
    try t.expectEqual(@as(usize, 0), parseHeader("open x\n# env: A=b\n").envPairs().len);
}

test "one `# env:` line past the cap is a parse error, not a line that quietly vanishes" {
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(t.allocator);
    for (0..Header.max_env) |i| try src.print(t.allocator, "# env: K{d}=v\n", .{i});
    try src.appendSlice(t.allocator, "open x\n");
    var full = try parseOk(src.items);
    full.deinit();
    try t.expectEqual(@as(usize, Header.max_env), parseHeader(src.items).envPairs().len);

    try src.insertSlice(t.allocator, 0, "# env: ONE_TOO_MANY=v\n");
    try expectErr(src.items, "more than 16 `# env:` lines; the rest would be dropped");
}

test "CRLF and blank lines are tolerated" {
    var s = try parseOk("open a.txt\r\n\r\n  # indented comment\r\nexpect dirty false\r\n");
    defer s.deinit();
    try t.expectEqual(@as(usize, 2), s.lines.len);
    try t.expectEqualStrings("a.txt", s.lines[0].stmt.step.open);
    try t.expectEqual(@as(usize, 4), s.lines[1].ln);
}

test "expect color takes a cell, fg or bg, and an optional `not`" {
    var s = try parseOk("expect color 10 39 bg #1e222a\nexpect color 0 0 fg not #ffffff\n");
    defer s.deinit();
    const a = s.lines[0].stmt.check.color;
    try t.expectEqual(@as(u16, 10), a.x);
    try t.expectEqual(@as(u16, 39), a.y);
    try t.expect(a.bg);
    try t.expect(!a.negated);
    try t.expectEqualSlices(u8, &.{ 0x1e, 0x22, 0x2a }, &a.want.rgb);
    const b = s.lines[1].stmt.check.color;
    try t.expect(!b.bg);
    try t.expect(b.negated);
    try t.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff }, &b.want.rgb);
    // // changed (dock-polish): `index <N>` names a palette colour.
    var ix = try parseOk("expect color 5 6 fg index 15\nexpect color 5 6 fg not index 2\n");
    defer ix.deinit();
    const c = ix.lines[0].stmt.check.color;
    try t.expectEqual(@as(u8, 15), c.want.index);
    try t.expect(!c.negated);
    const d = ix.lines[1].stmt.check.color;
    try t.expectEqual(@as(u8, 2), d.want.index);
    try t.expect(d.negated);
    // A malformed one is a parse error, not a silently-passing check.
    for ([_][]const u8{
        "expect color 10 39 bg 1e222a\n",
        "expect color 10 39 middle #1e222a\n",
        "expect color x 39 bg #1e222a\n",
        "expect color 5 6 fg index\n",
        "expect color 5 6 fg index 300\n",
    }) |bad| t.allocator.free(try parseErr(bad));
}

test "`shot` takes a bare name; a path or nothing is a parse error" {
    var d: Diagnostic = .{};
    var s = try parse(t.allocator, "shot tree_open\n", &d);
    defer s.deinit();
    try t.expectEqualStrings("tree_open", s.lines[0].stmt.step.shot);

    // A name, never a path: the driver owns the directory, and `../`
    // would write outside the run's own.
    var d2: Diagnostic = .{};
    try t.expectError(error.Syntax, parse(t.allocator, "shot ../escape\n", &d2));
    try t.expect(std.mem.indexOf(u8, d2.message(), "bare name") != null);
    var d3: Diagnostic = .{};
    try t.expectError(error.Syntax, parse(t.allocator, "shot\n", &d3));
    try t.expect(std.mem.indexOf(u8, d3.message(), "needs a name") != null);
}

test "expect within <ms>: the check parses as it would bare and carries its own budget; a bad count names the line" {
    var diag: Diagnostic = .{};
    var s = try parse(t.allocator, "expect within 30000 screen contains \"JIRA WORK (4)\"\nexpect within 500 status lacks x\nexpect screen contains y\n", &diag);
    defer s.deinit();
    try t.expectEqualStrings("JIRA WORK (4)", s.lines[0].stmt.check.screen_contains);
    try t.expectEqual(@as(?u64, 30000), s.lines[0].budget_ms);
    try t.expectEqualStrings("x", s.lines[1].stmt.check.status_lacks);
    try t.expectEqual(@as(?u64, 500), s.lines[1].budget_ms);
    try t.expectEqual(@as(?u64, null), s.lines[2].budget_ms);
    const msg = try parseErr("expect within soon screen contains y\n");
    defer t.allocator.free(msg);
    try t.expectEqualStrings("line 1: expect within <ms> <expectation> — `soon` is not a millisecond count", msg);
}
