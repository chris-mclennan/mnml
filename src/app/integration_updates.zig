//! Installed integrations that are behind the Marketplace.
//!
//! The Marketplace tab already reads `update available` off a row whose
//! index (or catalogue) version is newer than what is installed
//! (`integrations.catalogueState`). This module turns the same
//! comparison around for the Installed tab:
//!
//!   - a row's hint (`hintFor`): the newest Marketplace version of the
//!     installed manifest's BINARY, when it is newer — the row paints
//!     `0.2.3 → 0.2.4 available`, its menu gains *Update to 0.2.4*
//!     (`integrations.update_from_marketplace`, which queues the same
//!     install the Marketplace row's Install runs), and its hover says
//!     it in words. A version that is not newer — the same one, or an
//!     older index — is never offered: an update is never a downgrade;
//!   - the tab label's count (`behind`): one per Marketplace row with an
//!     installed manifest behind it, so Jira's three chips count once;
//!   - the quiet check (`startupCheck` / `tick`): the terminal loop's
//!     mnml fetches the listing once at start and again every
//!     `check_interval_ms`, unless `ui.dashboard_refresh` is `manual`,
//!     `ui.check_updates` is off or `MNML_NO_UPDATE_CHECK=1`. The fetch
//!     is the Marketplace's own worker; nothing here runs on the paint
//!     path but arithmetic over the listing in memory;
//!   - the startup note (`afterListing`): when a fetch finds versions
//!     newer than the last ones it noted, ONE toast names them all, and
//!     `<data root>/marketplace/update-notice` remembers them so the
//!     same versions are not announced twice. Only the quiet check
//!     toasts; a listing somebody opened records what it saw.
//!
//! When the Marketplace could not be read there is no listing to
//! compare against, and the rows say nothing — a hint from a cache, not
//! an `unknown` on every row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const integrations = @import("integrations.zig");
const marketplace = @import("marketplace.zig");
const catalogue = @import("marketplace_catalogue.zig");

/// How often the quiet check fetches again after the first one. Only
/// a tick asks (an idle mnml parks with no deadline and is not woken
/// for this).
pub const check_interval_ms: i64 = 6 * std.time.ms_per_hour;

/// Under the data root: the versions the startup note last named, one
/// `<id> <version>` per line.
pub const notice_file = "marketplace" ++ std.fs.path.sep_str ++ "update-notice";

pub const table = .{
    .@"integrations.update_from_marketplace" = &updateFromMarketplace,
    .@"integrations.check_updates_now" = &checkNowCmd,
};

/// A newer version of an installed integration, and the Marketplace row
/// (`app.marketplace.entries[entry]`) that installs it. `version`
/// borrows the listing's arena.
pub const Hint = struct { version: []const u8, entry: usize };

/// The newest Marketplace version of `inst`'s binary when it is newer
/// than `inst`'s, else null. Matched as `catalogueState` matches: on
/// the binary's program name, `$VAR` expanded.
pub fn hintFor(app: *App, arena: Allocator, inst: *const integrations.Installed) Allocator.Error!?Hint {
    if (inst.manifest.version.len == 0 or inst.manifest.binary.len == 0) return null;
    const have = integrations.programName(try integrations.expandEnv(app, arena, inst.manifest.binary));
    var best: ?Hint = null;
    for (app.marketplace.entries, 0..) |e, i| {
        if (e.kind != .builtin and e.kind != .release) continue;
        if (e.binary.len == 0) continue;
        const want = integrations.programName(try integrations.expandEnv(app, arena, e.binary));
        if (!std.mem.eql(u8, have, want)) continue;
        if (!catalogue.olderThan(inst.manifest.version, e.version)) continue;
        if (best) |b| if (!catalogue.olderThan(b.version, e.version)) continue;
        best = .{ .version = e.version, .entry = i };
    }
    return best;
}

/// The hint for the Installed tab's row at VISIBLE index `idx`; null on
/// another tab, a first-party row, or a current one.
pub fn rowHint(app: *App, arena: Allocator, idx: usize) Allocator.Error!?Hint {
    const st = &app.integrations;
    if (st.tab != .installed) return null;
    const v = (try integrations.entryAt(app, idx)) orelse return null;
    return switch (integrations.installedRow(v)) {
        .first_party => null,
        .manifest => |i| if (i < st.list.len) try hintFor(app, arena, &st.list[i]) else null,
    };
}

/// One Marketplace row an installed integration is behind.
pub const Behind = struct { id: []const u8, label: []const u8, version: []const u8 };

/// Every Marketplace row with an installed manifest older than it —
/// what the tab label counts and the startup note names.
pub fn behind(app: *App, arena: Allocator) Allocator.Error![]Behind {
    var out: std.ArrayListUnmanaged(Behind) = .empty;
    for (app.marketplace.entries) |e| {
        if (e.kind != .builtin and e.kind != .release) continue;
        if (try integrations.catalogueState(app, arena, e.binary, e.version) != .update) continue;
        try out.append(arena, .{ .id = e.id, .label = if (e.label.len > 0) e.label else e.id, .version = e.version });
    }
    return out.toOwnedSlice(arena);
}

// ─── the quiet check ────────────────────────────────────────────────────

/// The terminal loop, once, after the `startup` hook: this mnml may
/// reach the network on its own (`marketplace.State.live`), and the
/// first check starts now.
pub fn startupCheck(app: *App) void {
    app.marketplace.live = true;
    check(app, App.nowMs(app.io));
}

/// Again every `check_interval_ms`, from `App.tick`.
pub fn tick(app: *App, now: i64) void {
    const at = app.marketplace.checked_at_ms orelse return;
    if (now - at < check_interval_ms) return;
    check(app, now);
}

/// Whether the quiet check may run at all.
pub fn allowed(app: *const App) bool {
    if (!app.marketplace.live) return false;
    if (!app.cfg.marketplace.enabled or !app.cfg.ui.check_updates) return false;
    if (app.cfg.ui.dashboard_refresh == .manual) return false;
    if (app.env.get("MNML_NO_UPDATE_CHECK")) |v| if (std.mem.eql(u8, v, "1")) return false;
    if (app.offline() != .online) return false;
    return true;
}

fn check(app: *App, now: i64) void {
    // Stamped first, so a check that cannot start is not retried every
    // tick.
    app.marketplace.checked_at_ms = now;
    if (!allowed(app)) return;
    // A fetch somebody started is already the check.
    if (app.marketplace.fetching) return;
    if (marketplace.sourceCount(app) == 0) return;
    marketplace.refresh(app) catch return;
    if (app.marketplace.fetching) app.marketplace.quiet = true;
}

// ─── checking now ───────────────────────────────────────────────────────

/// `integrations.check_updates_now`: the quiet check's fetch, now, by
/// hand — and when the listing lands, one toast that says what it found
/// (`reportText`). The 6-hour clock starts again from here.
fn checkNowCmd(app: *App) CommandError!void {
    const off = app.offline();
    if (off != .online) {
        app.toast("integrations: {s} \u{2014} the update check does not reach the network", .{off.label()});
        return;
    }
    if (!app.cfg.marketplace.enabled)
        return app.diag.fail(app.frame.allocator(), "integrations: the Marketplace is off (marketplace.enabled), so there is nothing to check against", .{});
    if (marketplace.sourceCount(app) == 0)
        return app.diag.fail(app.frame.allocator(), "integrations: no Marketplace sources to check against (marketplace.sources)", .{});
    try marketplace.refresh(app);
    app.marketplace.report_check = true;
    app.marketplace.checked_at_ms = App.nowMs(app.io);
    app.toast("integrations: checking the Marketplace for updates\u{2026}", .{});
}

/// After a check somebody asked for: `3 integrations checked · 1 update:
/// Jira 0.2.3 → 0.2.4` — counted by binary, so Jira's three chips are
/// one integration — or `· all up to date`.
pub fn reportText(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    var updates: std.ArrayListUnmanaged(u8) = .empty;
    var n_updates: usize = 0;
    const arrow = if (app.cfg.ui.ascii_icons) "->" else "\u{2192}";
    for (app.integrations.list) |*inst| {
        if (inst.manifest.isLauncher() or inst.manifest.binary.len == 0) continue;
        const name = integrations.programName(try integrations.expandEnv(app, arena, inst.manifest.binary));
        const dup = for (seen.items) |o| {
            if (std.mem.eql(u8, o, name)) break true;
        } else false;
        if (dup) continue;
        try seen.append(arena, name);
        const h = (try hintFor(app, arena, inst)) orelse continue;
        const e = app.marketplace.entries[h.entry];
        try updates.appendSlice(arena, if (n_updates == 0) ": " else ", ");
        try updates.print(arena, "{s} {s} {s} {s}", .{ if (e.label.len > 0) e.label else e.id, inst.manifest.version, arrow, h.version });
        n_updates += 1;
    }
    const n = seen.items.len;
    const head = try std.fmt.allocPrint(arena, "{d} integration{s} checked \u{00b7} ", .{ n, if (n == 1) "" else "s" });
    if (n_updates == 0) return std.fmt.allocPrint(arena, "{s}all up to date", .{head});
    return std.fmt.allocPrint(arena, "{s}{d} update{s}{s}", .{ head, n_updates, if (n_updates == 1) "" else "s", updates.items });
}

/// The listing a check somebody asked for has landed: say what it found.
pub fn reportCheck(app: *App) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    app.toast("{s}", .{try reportText(app, arena_state.allocator())});
}

// ─── the startup note ───────────────────────────────────────────────────

/// After a listing lands: the versions newer than installed that the
/// note has not named yet. A quiet check toasts them, once, in one
/// toast; any listing records them.
pub fn afterListing(app: *App, quiet: bool) Allocator.Error!void {
    if (app.data_root.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const now = try behind(app, arena);
    if (now.len == 0) return;
    const path = try std.fs.path.join(arena, &.{ app.data_root, notice_file });
    const seen = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(64 * 1024)) catch "";
    var fresh: std.ArrayListUnmanaged(Behind) = .empty;
    for (now) |b| if (!noted(seen, b.id, b.version)) try fresh.append(arena, b);
    if (fresh.items.len == 0) return;
    if (quiet) app.toast("{s}", .{try noteText(arena, fresh.items, app.cfg.ui.ascii_icons)});
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (now) |b| try text.print(arena, "{s} {s}\n", .{ b.id, b.version });
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(app.io, d) catch return;
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = text.items }) catch {};
}

const Io = std.Io;

/// Whether `seen` (the notice file) has the line `<id> <version>`.
pub fn noted(seen: []const u8, id: []const u8, version: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, seen, "\r\n");
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const a = parts.next() orelse continue;
        const b = parts.next() orelse continue;
        if (std.mem.eql(u8, a, id) and std.mem.eql(u8, b, version)) return true;
    }
    return false;
}

/// `Jira 0.2.4 and Bitbucket 0.2.4 are available — Integrations ▸ Installed`.
pub fn noteText(arena: Allocator, list: []const Behind, ascii: bool) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (list, 0..) |b, i| {
        if (i > 0) try out.appendSlice(arena, if (i + 1 == list.len) " and " else ", ");
        try out.print(arena, "{s} {s}", .{ b.label, b.version });
    }
    try out.print(arena, " {s} available \u{2014} Integrations {s} Installed", .{ if (list.len == 1) "is" else "are", if (ascii) ">" else "\u{25b8}" });
    return out.items;
}

// ─── the command ────────────────────────────────────────────────────────

/// The Installed row's *Update to <version>*: queue the Marketplace
/// row's install — the same one its Install runs.
fn updateFromMarketplace(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const i = (try integrations.focusedRow(app)) orelse
        return app.diag.fail(arena, "integrations: pick an installed integration first", .{});
    return updateAt(app, i);
}

/// *Update to* for installed row `i` (an index into the list).
pub fn updateAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    const arena = app.frame.allocator();
    if (i >= st.list.len) return;
    const inst = &st.list[i];
    const hint = (try hintFor(app, arena, inst)) orelse
        return app.diag.fail(arena, "integrations: {s} is not behind the Marketplace", .{inst.id()});
    const id = try arena.dupe(u8, app.marketplace.entries[hint.entry].id);
    try marketplace.enqueue(app, id);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "the startup note: one name, two names, three — and the ASCII arrow" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const jira: Behind = .{ .id = "jira", .label = "Jira", .version = "0.2.4" };
    const bb: Behind = .{ .id = "bitbucket", .label = "Bitbucket", .version = "0.2.4" };
    const s: Behind = .{ .id = "sample", .label = "Sample", .version = "0.2.0" };
    try testing.expectEqualStrings("Jira 0.2.4 is available \u{2014} Integrations \u{25b8} Installed", try noteText(ar, &.{jira}, false));
    try testing.expectEqualStrings("Jira 0.2.4 and Bitbucket 0.2.4 are available \u{2014} Integrations \u{25b8} Installed", try noteText(ar, &.{ jira, bb }, false));
    try testing.expectEqualStrings("Jira 0.2.4, Bitbucket 0.2.4 and Sample 0.2.0 are available \u{2014} Integrations > Installed", try noteText(ar, &.{ jira, bb, s }, true));
    try testing.expect(noted("jira 0.2.4\nbitbucket 0.2.4\n", "bitbucket", "0.2.4"));
    try testing.expect(!noted("jira 0.2.4\n", "jira", "0.2.5"));
    try testing.expect(!noted("", "jira", "0.2.4"));
}

const screen_mod = @import("../ipc/screen.zig");

/// Four installed manifests on three binaries: Jira's two chips at
/// 0.2.3, Bitbucket at 0.2.4, Sample at 0.2.0 — each binary a file
/// under the data root, named by `$<NAME>_BIN`.
const Rig = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    root: []const u8,
    root_buf: [std.fs.max_path_bytes]u8,

    fn init(self: *Rig) !void {
        const io = testing.io;
        self.tmp = testing.tmpDir(.{});
        self.env = std.process.Environ.Map.init(testing.allocator);
        self.root = self.root_buf[0..try self.tmp.dir.realPath(io, &self.root_buf)];
        try self.tmp.dir.createDirPath(io, "integrations");
        try self.tmp.dir.createDirPath(io, "tools");
        const bins = [_]struct { v: []const u8, name: []const u8 }{
            .{ .v = "JIRA_BIN", .name = "mnml-jira" },
            .{ .v = "BB_BIN", .name = "mnml-bitbucket" },
            .{ .v = "SAMPLE_BIN", .name = "mnml-sample" },
        };
        for (bins) |b| {
            const rel = try std.fs.path.join(testing.allocator, &.{ "tools", b.name });
            defer testing.allocator.free(rel);
            try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = "#!/bin/sh\n" });
            const abs = try std.fs.path.join(testing.allocator, &.{ self.root, rel });
            defer testing.allocator.free(abs);
            try self.env.put(b.v, abs);
        }
        const manifests = [_]struct { file: []const u8, text: []const u8 }{
            .{ .file = "jira_work.zon", .text = ".{ .id = \"jira_work\", .label = \"Jira Work\", .version = \"0.2.3\", .binary = \"$JIRA_BIN\" }" },
            .{ .file = "jira_boards.zon", .text = ".{ .id = \"jira_boards\", .label = \"Jira Boards\", .version = \"0.2.3\", .binary = \"$JIRA_BIN\" }" },
            .{ .file = "bitbucket_prs.zon", .text = ".{ .id = \"bitbucket_prs\", .label = \"Bitbucket PRs\", .version = \"0.2.4\", .binary = \"$BB_BIN\" }" },
            .{ .file = "sample.zon", .text = ".{ .id = \"sample\", .label = \"Sample\", .version = \"0.2.0\", .binary = \"$SAMPLE_BIN\" }" },
        };
        for (manifests) |m| {
            const rel = try std.fs.path.join(testing.allocator, &.{ "integrations", m.file });
            defer testing.allocator.free(rel);
            try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = m.text });
        }
    }

    fn deinit(self: *Rig) void {
        self.env.deinit();
        self.tmp.cleanup();
    }

    fn app(self: *Rig) !App {
        var a = try App.initWith(testing.allocator, testing.io, .{ .workspace = self.root, .data_root = self.root, .cols = 110, .rows = 40, .env = &self.env });
        errdefer a.deinit();
        try integrations.refresh(&a);
        a.tree.visible = false;
        a.tree.width = 80;
        return a;
    }
};

/// The listing a fetch of the index would leave: Jira one patch ahead,
/// Bitbucket the same, Sample BEHIND what is installed.
var index_rows = [_]marketplace.Entry{
    .{ .source = "index", .kind = .release, .id = "jira", .label = "Jira", .description = "", .version = "0.2.4", .url = "", .binary = "mnml-jira" },
    .{ .source = "index", .kind = .release, .id = "bitbucket", .label = "Bitbucket", .description = "", .version = "0.2.4", .url = "", .binary = "mnml-bitbucket" },
    .{ .source = "index", .kind = .release, .id = "sample", .label = "Sample", .description = "", .version = "0.1.0", .url = "", .binary = "mnml-sample" },
};

/// The Installed tab's visible index of the row labelled `label`.
fn rowOf(app: *App, label: []const u8) !u32 {
    var v: usize = 0;
    while (try integrations.entryAt(app, v)) |e| : (v += 1) switch (integrations.installedRow(e)) {
        .first_party => {},
        .manifest => |i| if (std.mem.eql(u8, app.integrations.list[i].manifest.label, label)) return @intCast(v),
    };
    return error.TestRowNotFound;
}

fn closeMenu(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
}

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(testing.allocator, &app.screen);
}

test "an Installed row behind the index reads `0.2.3 → 0.2.4 available`, its menu leads with Update to 0.2.4 and its hover says so; a current row, an older index and an unreadable one say nothing; the label counts the Marketplace rows behind" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var app = try rig.app();
    defer app.deinit();
    app.marketplace.entries = &index_rows;
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    const a = app.frame.allocator();

    // The hints themselves.
    const list = app.integrations.list;
    for (list) |*inst| {
        const h = try hintFor(&app, a, inst);
        if (std.mem.startsWith(u8, inst.id(), "jira_")) {
            try testing.expectEqualStrings("0.2.4", h.?.version);
            try testing.expectEqualStrings("jira", app.marketplace.entries[h.?.entry].id);
        } else {
            // bitbucket: the same version; sample: the index is OLDER
            // than what is installed, and a downgrade is never offered.
            try testing.expect(h == null);
        }
    }
    // Jira's two chips are one Marketplace row behind: one update.
    try testing.expectEqual(@as(usize, 1), (try behind(&app, a)).len);

    {
        const text = try screenText(&app);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "Installed (8) \u{b7} 1 update") != null);
        try testing.expect(std.mem.indexOf(u8, text, "Jira Work  0.2.3 \u{2192} 0.2.4 available") != null);
        try testing.expect(std.mem.indexOf(u8, text, "Jira Boards  0.2.3 \u{2192} 0.2.4 available") != null);
        try testing.expect(std.mem.indexOf(u8, text, "Bitbucket PRs  0.2.4") != null);
        try testing.expect(std.mem.indexOf(u8, text, "0.2.4 \u{2192}") == null);
        try testing.expect(std.mem.indexOf(u8, text, "Sample  0.2.0") != null);
        try testing.expect(std.mem.indexOf(u8, text, "\u{2192} 0.1.0") == null);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "available"));
    }

    // The menu: Update to 0.2.4 first, firing the update command; a
    // current row has no such row.
    const jira = try rowOf(&app, "Jira Work");
    try integrations.rowMouse(&app, jira, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    try testing.expectEqualStrings("Update to 0.2.4", app.overlay.menu.items[0].label);
    try testing.expect(app.overlay.menu.items[0].action.command == .@"integrations.update_from_marketplace");
    closeMenu(&app);
    const bb = try rowOf(&app, "Bitbucket PRs");
    try integrations.rowMouse(&app, bb, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    for (app.overlay.menu.items) |it| try testing.expect(!std.mem.startsWith(u8, it.label, "Update to"));
    closeMenu(&app);

    // The hover, in words.
    const panels = @import("info_view_copy/panels.zig");
    const tip = (try panels.row(&app, a, .{ .panel = .integrations, .idx = jira })).?;
    try testing.expect(std.mem.endsWith(u8, tip.title, "\u{b7} 0.2.4 available"));
    try testing.expect(std.mem.startsWith(u8, tip.body, "0.2.4 is in the Marketplace index; Update to install it."));
    const plain = (try panels.row(&app, a, .{ .panel = .integrations, .idx = bb })).?;
    try testing.expect(std.mem.indexOf(u8, plain.title, "available") == null);

    // The menu's Update queues the Marketplace row's install — the same
    // one its Install runs (held behind a running one here, so nothing
    // downloads).
    app.marketplace.installing = try testing.allocator.dupe(u8, "busy");
    try integrations.rowMouse(&app, jira, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    closeMenu(&app);
    try command.run(&app, .{ .static = .@"integrations.update_from_marketplace" });
    try testing.expectEqual(@as(usize, 1), app.marketplace.queue.items.len);
    try testing.expectEqualStrings("jira", app.marketplace.queue.items[0]);
    // On a current row it says so rather than reinstalling.
    try integrations.rowMouse(&app, bb, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    closeMenu(&app);
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"integrations.update_from_marketplace" }));

    // The index could not be read: no listing, no hints, no count.
    app.marketplace.entries = &.{};
    {
        const text = try screenText(&app);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "Installed (8)") != null);
        try testing.expect(std.mem.indexOf(u8, text, "update") == null);
        try testing.expect(std.mem.indexOf(u8, text, "available") == null);
        try testing.expect(std.mem.indexOf(u8, text, "\u{2192}") == null);
    }
}

test "the startup note: one toast for every integration behind, once per version — the quiet check toasts, a listing somebody opened only records" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var app = try rig.app();
    defer app.deinit();
    var rows = index_rows;
    rows[1].version = "0.2.5"; // Bitbucket behind too
    app.marketplace.entries = &rows;
    const before = app.toasts.items.len;
    try afterListing(&app, true);
    try testing.expectEqual(before + 1, app.toasts.items.len);
    try testing.expectEqualStrings("Jira 0.2.4 and Bitbucket 0.2.5 are available \u{2014} Integrations \u{25b8} Installed", app.lastToast().?);
    const path = try std.fs.path.join(testing.allocator, &.{ rig.root, notice_file });
    defer testing.allocator.free(path);
    const seen = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(seen);
    try testing.expectEqualStrings("jira 0.2.4\nbitbucket 0.2.5\n", seen);
    // The same versions again: nothing.
    try afterListing(&app, true);
    try testing.expectEqual(before + 1, app.toasts.items.len);
    // A newer one: one toast, naming only what is new.
    rows[0].version = "0.2.6";
    try afterListing(&app, true);
    try testing.expectEqual(before + 2, app.toasts.items.len);
    try testing.expectEqualStrings("Jira 0.2.6 is available \u{2014} Integrations \u{25b8} Installed", app.lastToast().?);
    // Somebody opened the Marketplace and saw 0.2.7: recorded, not toasted,
    // and the quiet check after it has nothing new to say.
    rows[0].version = "0.2.7";
    try afterListing(&app, false);
    try testing.expectEqual(before + 2, app.toasts.items.len);
    try afterListing(&app, true);
    try testing.expectEqual(before + 2, app.toasts.items.len);
}

test "the quiet check runs only where it may: the terminal loop's mnml, not under ui.dashboard_refresh = manual, ui.check_updates = false or MNML_NO_UPDATE_CHECK=1" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var app = try rig.app();
    defer app.deinit();
    try testing.expect(!allowed(&app));
    app.marketplace.live = true;
    try testing.expect(allowed(&app));
    app.cfg.ui.dashboard_refresh = .manual;
    try testing.expect(!allowed(&app));
    app.cfg.ui.dashboard_refresh = .auto;
    app.cfg.ui.check_updates = false;
    try testing.expect(!allowed(&app));
    app.cfg.ui.check_updates = true;
    try app.env.put("MNML_NO_UPDATE_CHECK", "1");
    try testing.expect(!allowed(&app));
    // Not allowed: the check stamps its time and starts nothing, and the
    // tick does not try again before the interval.
    check(&app, 1000);
    try testing.expect(!app.marketplace.fetching);
    try testing.expectEqual(@as(?i64, 1000), app.marketplace.checked_at_ms);
    tick(&app, 1000 + check_interval_ms - 1);
    try testing.expectEqual(@as(?i64, 1000), app.marketplace.checked_at_ms);
    tick(&app, 1000 + check_interval_ms);
    try testing.expectEqual(@as(?i64, 1000 + check_interval_ms), app.marketplace.checked_at_ms);
}

test "integrations.check_updates_now runs the check and, when the listing lands, says what it found: counted by binary, one update named with both versions — or all up to date" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var app = try rig.app();
    defer app.deinit();
    app.marketplace.entries = &index_rows;
    const a = app.frame.allocator();
    // Jira's two chips are one binary: three integrations, Jira behind.
    try testing.expectEqualStrings("3 integrations checked \u{00b7} 1 update: Jira 0.2.3 \u{2192} 0.2.4", try reportText(&app, a));
    var rows = index_rows;
    rows[0].version = "0.2.3";
    app.marketplace.entries = &rows;
    try testing.expectEqualStrings("3 integrations checked \u{00b7} all up to date", try reportText(&app, a));
    rows[0].version = "0.2.4";
    rows[1].version = "0.2.5";
    app.cfg.ui.ascii_icons = true;
    try testing.expectEqualStrings("3 integrations checked \u{00b7} 2 updates: Bitbucket 0.2.4 -> 0.2.5, Jira 0.2.3 -> 0.2.4", try reportText(&app, a));
}

test "integrations.check_updates_now under the offline switch says so and fetches nothing" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var app = try rig.app();
    defer app.deinit();
    try app.env.put("MNML_OFFLINE", "1");
    app.marketplace.live = true;
    try testing.expect(!allowed(&app));
    try command.run(&app, .{ .static = .@"integrations.check_updates_now" });
    try testing.expect(!app.marketplace.fetching);
    try testing.expect(!app.marketplace.report_check);
    try testing.expectEqualStrings("integrations: offline (MNML_OFFLINE=1) \u{2014} the update check does not reach the network", app.lastToast().?);
}

test "the Details pane of an integration behind the Marketplace says both versions and offers Update to; Relink is called Relink; `i` on the row updates; the Marketplace row's menu reads the binary, not the slug" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var app = try rig.app();
    defer app.deinit();
    try app.resize(200, 30);
    app.marketplace.entries = &index_rows;
    // An install is running, so an update queues rather than downloads.
    app.marketplace.installing = try testing.allocator.dupe(u8, "busy");
    try integrations.openDetail(&app, .{ .installed = "jira_work" });
    {
        const text = try screenText(&app);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "installed 0.2.3 \u{00b7} 0.2.4 available") != null);
        try testing.expect(std.mem.indexOf(u8, text, "[ Update to 0.2.4 ]") != null);
        try testing.expect(std.mem.indexOf(u8, text, "[ Relink the binary ]") != null);
        try testing.expect(std.mem.indexOf(u8, text, "[ Update ]") == null);
    }
    // The tab wears the name, not the id.
    try testing.expectEqualStrings("Jira Work", app.panes.get(app.panes.findKind(.integrations).?).?.title());
    // Current with the Marketplace: Relink only.
    try integrations.openDetail(&app, .{ .installed = "bitbucket_prs" });
    {
        const text = try screenText(&app);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "available") == null);
        try testing.expect(std.mem.indexOf(u8, text, "Update to") == null);
        try testing.expect(std.mem.indexOf(u8, text, "[ Relink the binary ]") != null);
    }
    // `i` on the behind row is its Update to: the Marketplace row queues.
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    const jira = try rowOf(&app, "Jira Work");
    try integrations.rowMouse(&app, jira, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    closeMenu(&app);
    try testing.expect(try integrations.handleKey(&app, .{ .code = .{ .char = 'i' } }));
    try testing.expectEqual(@as(usize, 1), app.marketplace.queue.items.len);
    try testing.expectEqualStrings("jira", app.marketplace.queue.items[0]);
    // The Marketplace's Jira row is installed by its binary (jira_work,
    // jira_boards), not by the slug `jira`: its menu offers the update.
    try command.run(&app, .{ .static = .@"integrations.show_marketplace" });
    app.marketplace.entries = &index_rows;
    try integrations.rowMouse(&app, try mktRow(&app, "jira"), .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Update to 0.2.4", app.overlay.menu.items[0].label);
    closeMenu(&app);
    // Bitbucket's row: installed and current — Reinstall, not Install.
    try integrations.rowMouse(&app, try mktRow(&app, "bitbucket"), .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    try testing.expectEqualStrings("Reinstall", app.overlay.menu.items[0].label);
    closeMenu(&app);
}

/// The Marketplace tab's visible index of the row for entry `id`.
fn mktRow(app: *App, id: []const u8) !u32 {
    var v: usize = 0;
    while (try integrations.entryAt(app, v)) |e| : (v += 1) {
        if (e < app.marketplace.entries.len and std.mem.eql(u8, app.marketplace.entries[e].id, id)) return @intCast(v);
    }
    return error.TestUnexpectedResult;
}
