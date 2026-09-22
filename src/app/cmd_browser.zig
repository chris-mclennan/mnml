//! The `browser.*` runners: open Chrome, navigate, eval, capture
//! (screenshot / PDF / snapshots), the inspector panels, device and
//! network emulation, URL history, the profile. Every one of them
//! says "no browser pane open" when there is none.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Prompt = app_mod.Prompt;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_picker = @import("cmd_picker.zig");
const browser = @import("browser_pane.zig");
const BrowserPane = browser.BrowserPane;
const cdp = @import("../cdp/client.zig");
const history = @import("../http/history.zig");

pub const table = .{
    .@"browser.open" = &openBlankCmd,
    .@"browser.open_url" = &openCmd,
    .@"browser.navigate" = &navigateCmd,
    .@"browser.reload" = &reloadCmd,
    .@"browser.back" = &backCmd,
    .@"browser.forward" = &forwardCmd,
    .@"browser.copy_url" = &copyUrlCmd,
    .@"browser.devtools" = &devtoolsCmd,
    .@"browser.dock_toggle" = &dockCmd,
    .@"browser.install_cft" = &installCftCmd,
    .@"browser.screenshot" = &screenshotCmd,
    .@"browser.screenshot_node" = &screenshotNodeCmd,
    .@"browser.print_pdf" = &printPdfCmd,
    .@"browser.snapshot" = &snapshotCmd,
    .@"browser.diff_snapshot" = &diffSnapshotCmd,
    .@"browser.clear_snapshots" = &clearSnapshotsCmd,
    .@"browser.device_picker" = &devicePickerCmd,
    .@"browser.network_throttle" = &throttlePickerCmd,
    .@"browser.scroll_node_into_view" = &scrollNodeCmd,
    .@"browser.url_history" = &urlHistoryCmd,
    .@"browser.cookies" = &cookiesCmd,
    .@"browser.delete_cookie" = &deleteCookieCmd,
    .@"browser.edit_cookie" = &editCookieCmd,
    .@"browser.add_cookie" = &addCookieCmd,
    .@"browser.storage" = &storageCmd,
    .@"browser.edit_storage" = &editStorageCmd,
    .@"browser.add_storage" = &addStorageCmd,
    .@"browser.delete_storage" = &deleteStorageCmd,
    .@"browser.perf" = &perfCmd,
    .@"browser.dom" = &domCmd,
    .@"browser.wipe_profile" = &wipeProfileCmd,
    .@"browser.toggle_headless" = &toggleHeadlessCmd,
    .@"browser.autocapture_toggle" = &autocaptureToggleCmd,
    .@"http.capture_now" = &captureNowCmd,
    .@"http.capture_start" = &captureStartCmd,
};

pub fn activeBrowser(app: *App) ?*BrowserPane {
    if (app.active) |id| if (app.panes.get(id)) |p| if (p.asBrowser()) |b| return b;
    // Any open browser pane when the active one is something else.
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asBrowser()) |b| return b;
    return null;
}

fn requireBrowser(app: *App) CommandError!*BrowserPane {
    return activeBrowser(app) orelse app.diag.fail(app.frame.allocator(), "no browser pane open", .{});
}

fn openPrompt(app: *App, title: []const u8, purpose: app_mod.PromptPurpose, seed: ?[]const u8) Allocator.Error!void {
    var state = Prompt.init(app.gpa, title);
    if (seed) |s| try state.setText(app.gpa, s);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `browser.open_url`: prompt for a URL, then launch Chrome on it.
fn openCmd(app: *App) CommandError!void {
    try openPrompt(app, "Open URL in Chrome", .browser_url, null);
}

/// `browser.open` — the palette bar's globe: no prompt, straight to
/// `about:blank` (Rust: the rail chip's default skips the prompt). A
/// missing Chrome fails with the pane's own diag, which the chip's
/// press toasts.
fn openBlankCmd(app: *App) CommandError!void {
    _ = try browser.open(app, "about:blank");
}

fn navigateCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    try openPrompt(app, "Navigate to", .browser_navigate, b.url);
}

fn reloadCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    try browser.send(app, b, "Page.reload", "{}", .quiet);
    try b.push(.system, "reload");
}

fn backCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    try browser.eval(app, b, "window.history.back()", .quiet);
}

fn forwardCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    try browser.eval(app, b, "window.history.forward()", .quiet);
}

fn copyUrlCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.url.len == 0) return app.diag.fail(app.frame.allocator(), "browser.copy_url: pane has no URL yet", .{});
    try app.clipboard.set(b.url, false);
    app.toast("browser: {s} → clipboard", .{history.shortUrl(b.url)});
}

fn devtoolsCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    const port = b.port orelse return app.diag.fail(app.frame.allocator(), "browser.devtools: no debugger port — open via :browser.open", .{});
    const hint = try std.fmt.allocPrint(app.frame.allocator(), "http://127.0.0.1:{d}", .{port});
    try app.clipboard.set(hint, false);
    app.toast("browser.devtools: open chrome://inspect and add {s} (copied)", .{hint});
}

fn dockCmd(app: *App) CommandError!void {
    _ = try requireBrowser(app);
    return app.diag.fail(app.frame.allocator(), "browser.dock: window docking is not in this build", .{});
}

fn installCftCmd(app: *App) CommandError!void {
    const result = std.process.run(app.gpa, app.io, .{ .argv = &.{ "npx", "--yes", "@puppeteer/browsers", "install", "chrome@stable" }, .environ_map = &app.env }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "browser.install_cft: npx: {s} (needs Node)", .{@errorName(err)});
    };
    defer app.gpa.free(result.stdout);
    defer app.gpa.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        app.toast("installed Chrome for Testing — try `:browser.open`", .{});
    } else return app.diag.fail(app.frame.allocator(), "browser.install_cft failed: {s}", .{std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.stdout, " \n")});
}

fn screenshotCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    try browser.send(app, b, "Page.captureScreenshot", "{\"format\":\"png\",\"captureBeyondViewport\":false}", .screenshot);
    app.toast("screenshot: capturing…", .{});
}

fn screenshotNodeCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel != .dom) return app.diag.fail(app.frame.allocator(), "node screenshot needs the DOM panel open (D)", .{});
    if (b.dom_sel >= b.dom.items.len) return app.diag.fail(app.frame.allocator(), "no node selected", .{});
    const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"nodeId\":{s}}}", .{b.dom.items[b.dom_sel].key});
    try browser.send(app, b, "DOM.getBoxModel", params, .box_model);
}

fn printPdfCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    try browser.send(app, b, "Page.printToPDF", "{\"printBackground\":true}", .pdf);
    app.toast("pdf: printing…", .{});
}

fn snapshotCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    const n = try browser.captureSnapshot(app, b);
    app.toast("snapshot #{d} captured at {s}", .{ n, history.shortUrl(b.url) });
}

fn diffSnapshotCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    const text = (try browser.diffSnapshot(app, b)) orelse return app.diag.fail(app.frame.allocator(), "no snapshot to diff against — capture one with browser.snapshot", .{});
    const id = try app.openScratch();
    const e = app.panes.editor(id).?;
    e.buf.editor.setText(text) catch return error.OutOfMemory;
    e.buf.markSaved() catch return error.OutOfMemory;
}

fn clearSnapshotsCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    const n = b.snapshots.items.len;
    for (b.snapshots.items) |*s| s.deinit(app.gpa);
    b.snapshots.clearRetainingCapacity();
    app.toast("cleared {d} snapshot(s)", .{n});
}

fn devicePickerCmd(app: *App) CommandError!void {
    _ = try requireBrowser(app);
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (browser.device_presets) |d| try labels.append(gpa, try gpa.dupe(u8, d.name));
    try cmd_picker.openPicker(app, "Device emulation", .browser_device, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn throttlePickerCmd(app: *App) CommandError!void {
    _ = try requireBrowser(app);
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (browser.throttles) |t| try labels.append(gpa, try gpa.dupe(u8, t.name));
    try cmd_picker.openPicker(app, "Network throttle", .browser_throttle, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn scrollNodeCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel != .dom) return app.diag.fail(app.frame.allocator(), "scroll-into-view needs the DOM panel open (D)", .{});
    if (b.dom_sel >= b.dom.items.len) return app.diag.fail(app.frame.allocator(), "no node selected", .{});
    const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"nodeId\":{s}}}", .{b.dom.items[b.dom_sel].key});
    try browser.send(app, b, "DOM.scrollIntoViewIfNeeded", params, .quiet);
    app.toast("scrolled node into view", .{});
}

fn urlHistoryCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.visited.items.len == 0) return app.diag.fail(app.frame.allocator(), "no browser history yet", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    var i = b.visited.items.len;
    while (i > 0) {
        i -= 1;
        try labels.append(gpa, try gpa.dupe(u8, b.visited.items[i]));
    }
    try cmd_picker.openPicker(app, "Browser history", .browser_url_history, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

fn cookiesCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel == .cookies) {
        b.panel = .log;
        return;
    }
    try browser.send(app, b, "Network.getCookies", "{}", .cookies);
}

fn deleteCookieCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel != .cookies or b.cookies_sel >= b.cookies.items.len) return app.diag.fail(app.frame.allocator(), "open the cookies panel (K) and pick a cookie", .{});
    var parts = std.mem.splitScalar(u8, b.cookies.items[b.cookies_sel].key, '\t');
    const name = parts.next() orelse return;
    const domain = parts.next() orelse "";
    const path = parts.next() orelse "/";
    const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"name\":{f},\"domain\":{f},\"path\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(domain, .{}), std.json.fmt(path, .{}) });
    try browser.send(app, b, "Network.deleteCookies", params, .quiet);
    try browser.send(app, b, "Network.getCookies", "{}", .cookies);
    app.toast("cookie {s} deleted", .{name});
}

fn editCookieCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel != .cookies or b.cookies_sel >= b.cookies.items.len) return app.diag.fail(app.frame.allocator(), "open the cookies panel (K) and pick a cookie", .{});
    const name = std.mem.sliceTo(b.cookies.items[b.cookies_sel].key, '\t');
    const seed = try std.fmt.allocPrint(app.frame.allocator(), "{s}=", .{name});
    try openPrompt(app, "Cookie (name=value)", .browser_add_cookie, seed);
}

fn addCookieCmd(app: *App) CommandError!void {
    _ = try requireBrowser(app);
    try openPrompt(app, "Cookie (name=value)", .browser_add_cookie, null);
}

const storage_dump = "(function(){var o=[];for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o.push({scope:'local',key:k,value:localStorage.getItem(k)})}for(var j=0;j<sessionStorage.length;j++){var s=sessionStorage.key(j);o.push({scope:'session',key:s,value:sessionStorage.getItem(s)})}return JSON.stringify(o)})()";

fn storageCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel == .storage) {
        b.panel = .log;
        return;
    }
    try browser.eval(app, b, storage_dump, .storage);
}

fn editStorageCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel != .storage or b.storage_sel >= b.storage.items.len) return app.diag.fail(app.frame.allocator(), "open the storage panel (L) and pick an entry", .{});
    var parts = std.mem.splitScalar(u8, b.storage.items[b.storage_sel].key, '\t');
    _ = parts.next();
    const key = parts.next() orelse return;
    const seed = try std.fmt.allocPrint(app.frame.allocator(), "{s}=", .{key});
    try openPrompt(app, "localStorage entry (key=value)", .browser_add_storage, seed);
}

fn addStorageCmd(app: *App) CommandError!void {
    _ = try requireBrowser(app);
    try openPrompt(app, "localStorage entry (key=value)", .browser_add_storage, null);
}

fn deleteStorageCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel != .storage or b.storage_sel >= b.storage.items.len) return app.diag.fail(app.frame.allocator(), "open the storage panel (L) and pick an entry", .{});
    var parts = std.mem.splitScalar(u8, b.storage.items[b.storage_sel].key, '\t');
    const scope = parts.next() orelse "local";
    const key = parts.next() orelse return;
    const expr = try std.fmt.allocPrint(app.frame.allocator(), "{s}Storage.removeItem({f})", .{ scope, std.json.fmt(key, .{}) });
    try browser.eval(app, b, expr, .quiet);
    try browser.eval(app, b, storage_dump, .storage);
    app.toast("storage: {s} removed", .{key});
}

const perf_dump = "(function(){var t=performance.timing;var n=performance.getEntriesByType('navigation')[0];var p=performance.getEntriesByType('paint');var out=[];function ms(v){return Math.round(v)+' ms'}if(n){out.push('ttfb        '+ms(n.responseStart-n.requestStart));out.push('dom ready   '+ms(n.domContentLoadedEventEnd-n.startTime));out.push('load        '+ms(n.loadEventEnd-n.startTime));out.push('transfer    '+n.transferSize+' B')}p.forEach(function(e){out.push((e.name+'                ').slice(0,12)+ms(e.startTime))});try{var lcp=performance.getEntriesByType('largest-contentful-paint');if(lcp.length)out.push('lcp         '+ms(lcp[lcp.length-1].startTime))}catch(e){}return out.join('\\n')})()";

fn perfCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel == .perf) {
        b.panel = .log;
        return;
    }
    try browser.eval(app, b, perf_dump, .perf);
}

fn domCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    if (b.panel == .dom) {
        b.panel = .log;
        return;
    }
    try browser.send(app, b, "DOM.getDocument", "{\"depth\":-1}", .dom);
}

/// Deletes the profile — the base directory and every `-N` sibling a
/// second pane opened — or, in ephemeral mode, every ephemeral profile
/// a crash left behind (a pane that closes removes its own).
fn wipeProfileCmd(app: *App) CommandError!void {
    if (activeBrowser(app) != null) return app.diag.fail(app.frame.allocator(), "close the browser pane first — Chrome has the profile locked", .{});
    const arena = app.frame.allocator();
    const ephemeral = app.cfg.browser.profile_mode == .ephemeral;
    const base = if (ephemeral) try std.fmt.allocPrint(arena, "{s}/.mnml/{s}", .{ app.workspace, browser.ephemeral_prefix }) else try browser.profileBase(app, arena);
    const parent = std.fs.path.dirname(base) orelse return app.diag.fail(arena, "no profile to wipe", .{});
    const stem = std.fs.path.basename(base);
    var dir = Io.Dir.cwd().openDir(app.io, parent, .{ .iterate = true }) catch return app.diag.fail(arena, "no profile to wipe", .{});
    defer dir.close(app.io);
    var victims: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(app.io) catch null) |e| {
        if (e.kind != .directory or !std.mem.startsWith(u8, e.name, stem)) continue;
        const rest = e.name[stem.len..];
        const ours = if (ephemeral) rest.len > 0 else rest.len == 0 or (rest[0] == '-' and rest.len > 1 and for (rest[1..]) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true);
        if (ours) try victims.append(arena, try arena.dupe(u8, e.name));
    }
    if (victims.items.len == 0) return app.diag.fail(arena, "no profile to wipe", .{});
    for (victims.items) |name| dir.deleteTree(app.io, name) catch |err| return app.diag.fail(arena, "wipe failed: {s}", .{@errorName(err)});
    if (victims.items.len == 1) {
        app.toast("wiped {s}", .{app.relPath(try std.fs.path.join(arena, &.{ parent, victims.items[0] }))});
    } else app.toast("wiped {d} profiles under {s}", .{ victims.items.len, app.relPath(parent) });
}

fn toggleHeadlessCmd(app: *App) CommandError!void {
    app.cfg.browser.headless = !app.cfg.browser.headless;
    app.toast("browser: {s} (takes effect on the next browser.open)", .{if (app.cfg.browser.headless) "headless" else "headed"});
}

fn autocaptureToggleCmd(app: *App) CommandError!void {
    app.cfg.browser.autocapture_to_log = !app.cfg.browser.autocapture_to_log;
    app.toast("browser: autocapture to .rqst/captured/log.jsonl {s}", .{if (app.cfg.browser.autocapture_to_log) "on" else "off"});
}

fn captureNowCmd(app: *App) CommandError!void {
    const b = try requireBrowser(app);
    for (b.net.items) |*n| try browser.appendCaptured(app, n);
    app.toast("captured {d} request(s) → .rqst/captured/log.jsonl", .{b.net.items.len});
}

fn captureStartCmd(app: *App) CommandError!void {
    if (activeBrowser(app) != null) return captureNowCmd(app);
    try openPrompt(app, "Open URL in Chrome (capturing)", .browser_url, null);
}

/// Pickers opened here.
pub fn acceptPicker(app: *App, kind: app_mod.PickerKind, i: usize, label: []const u8) Allocator.Error!void {
    const b = activeBrowser(app) orelse return;
    switch (kind) {
        .browser_device => try browser.applyDevice(app, b, i),
        .browser_throttle => try browser.applyThrottle(app, b, i),
        .browser_url_history => try browser.navigate(app, b, label),
        else => {},
    }
}

/// Prompts opened here.
pub fn acceptPrompt(app: *App, purpose: app_mod.PromptPurpose, text: []const u8) Allocator.Error!void {
    switch (purpose) {
        .browser_url => {
            const url = std.mem.trim(u8, text, " \t");
            _ = browser.open(app, if (url.len == 0) "about:blank" else url) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
            };
        },
        .browser_navigate => {
            const b = activeBrowser(app) orelse return;
            const url = std.mem.trim(u8, text, " \t");
            if (url.len == 0) return;
            try browser.navigate(app, b, url);
        },
        .browser_eval => {
            const b = activeBrowser(app) orelse return;
            if (std.mem.trim(u8, text, " \t").len == 0) return;
            try browser.eval(app, b, text, .eval);
        },
        .browser_add_cookie => {
            const b = activeBrowser(app) orelse return;
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse {
                app.toast("cookie: input must be name=value", .{});
                return;
            };
            const name = std.mem.trim(u8, text[0..eq], " \t");
            const value = text[eq + 1 ..];
            const params = try std.fmt.allocPrint(app.frame.allocator(), "{{\"name\":{f},\"value\":{f},\"url\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(value, .{}), std.json.fmt(b.url, .{}) });
            try browser.send(app, b, "Network.setCookie", params, .quiet);
            try browser.send(app, b, "Network.getCookies", "{}", .cookies);
            app.toast("cookie {s} set", .{name});
        },
        .browser_add_storage => {
            const b = activeBrowser(app) orelse return;
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse {
                app.toast("storage: input must be key=value", .{});
                return;
            };
            const key = std.mem.trim(u8, text[0..eq], " \t");
            const expr = try std.fmt.allocPrint(app.frame.allocator(), "localStorage.setItem({f},{f})", .{ std.json.fmt(key, .{}), std.json.fmt(text[eq + 1 ..], .{}) });
            try browser.eval(app, b, expr, .quiet);
            try browser.eval(app, b, storage_dump, .storage);
            app.toast("storage: {s} set", .{key});
        },
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "browser.open goes straight to a pane (no prompt) and says so when Chrome is missing; browser.open_url asks for the URL" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    browser.test_no_chrome = true;
    defer browser.test_no_chrome = false;
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"browser.open" }));
    try testing.expect(app.overlay == .none);
    try testing.expect(std.mem.startsWith(u8, app.diag.msg.?, "no Chrome found"));
    try testing.expectEqual(@as(usize, 0), app.panes.count());
    app.diag.clear();
    try command.run(&app, .{ .static = .@"browser.open_url" });
    try testing.expect(app.overlay == .prompt);
    try testing.expectEqualStrings("Open URL in Chrome", app.overlay.prompt.state.title);
}
