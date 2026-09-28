//! Hover help for the activity bar: every section's row, the settings
//! gear, a pinned integration and a script's own section.
//!
//! A section's entry says what the section HOLDS and what a click
//! does with it — the same `view.activity_*` command the rail runs
//! and the right-click menu's first row names — and the state it is
//! in now: whether it is the marked one, which side its column is on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const rail_ui = @import("../../ui/activity_bar.zig");
const Section = rail_ui.Section;
const Part = rail_ui.Part;
const activity_bar = @import("../activity_bar.zig");
const integrations = @import("../integrations.zig");
const script_section = @import("../script_section.zig");
const command = @import("../../core/command.zig");

const ask = copy.ask_link;

pub fn entry(app: *App, arena: Allocator, part: Part) Allocator.Error!?Entry {
    return switch (part) {
        .section => |s| try section(app, arena, s),
        .gear => .{
            .title = "Settings gear",
            .body = "The overlay of everyday settings, one row per option, sectioned UI / Editor / AI / Integrations: `←→` change a row, `r` resets it, Enter saves and Esc puts back what you opened with. Click opens it; right-click is the app menu — Settings, the command palette, the cheatsheet, themes, About. Anything the overlay does not list (workspaces, key rebinds, LSP servers) is edited in config.zon, which `file.open_settings` opens.",
            .keys = &.{ .{ .command = .@"view.settings", .label = "Settings" }, .{ .command = .palette, .label = "Command palette" } },
            .links = &.{ .{ .command = .{ .id = .@"view.settings", .label = "Open Settings" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }, .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } } },
        },
        .pin => |i| try pinned(app, arena, i),
        .script => |i| try script(app, arena, i),
    };
}

fn marked(app: *App, s: Section) []const u8 {
    return if (activity_bar.active(app) == s) " This is the marked section — its column is the one open now." else "";
}

fn section(app: *App, arena: Allocator, s: Section) Allocator.Error!?Entry {
    return switch (s) {
        .explorer => .{
            .title = "Explorer — the file tree",
            .body = try std.fmt.allocPrint(arena, "The workspace's files as a tree, with the header chips for a new file or folder, pull, fold-all and rescan. Click shows it in its column (and leaves git mode if that is on); right-click offers the section's menu — move it to the other side, hide it. Arrows or j/k walk rows, Enter opens, right-click on a row is the file menu.{s}", .{marked(app, .explorer)}),
            .keys = &.{.{ .command = .@"picker.files", .label = "Fuzzy-open a file" }},
            .links = &.{ .{ .command = .{ .id = .@"view.activity_explorer", .label = "Show the tree" } }, .{ .command = .{ .id = .@"picker.files", .label = "Fuzzy-open a file" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.sidebar_side"), .label = "Default sidebar side" } } },
        },
        .search => .{
            .title = "Search — ripgrep across the workspace",
            .body = try std.fmt.allocPrint(arena, "Workspace-wide text search with the three flags on its header — `Aa` case, `\\b` whole word, `.*` regex. Type the query and Enter runs it; the hits group by file, Enter on one jumps to the line. Click shows the section; right-click is its menu. The search needs `rg` on PATH — without it the section says so instead of searching.{s}", .{marked(app, .search)}),
            .links = &.{ .{ .command = .{ .id = .@"view.activity_search", .label = "Show search" } }, .{ .command = .{ .id = .@"grep.open", .label = "Open the grep pane" } } },
        },
        .git => .{
            .title = "Git",
            .body = try std.fmt.allocPrint(arena, "Enters git mode: the sidebar becomes the git palette — status, commits, branches, worktrees, stashes for the active repo, with the repo pill at the top to switch — and the editor area shows the commit graph. Click enters or leaves it; right-click is the section's menu. Every other section's click leaves git mode, which puts the layout back the way it was.{s}", .{marked(app, .git)}),
            .keys = &.{ .{ .command = .@"view.activity_git", .label = "Git mode" }, .{ .command = .@"git.commit", .label = "Commit" }, .{ .command = .@"git.status_pane", .label = "Status pane" } },
            .links = &.{ .{ .command = .{ .id = .@"view.activity_git", .label = "Enter git mode" } }, .{ .command = .{ .id = .@"git.graph", .label = "The commit graph" } }, ask },
        },
        .debug => .{
            .title = "Debug — DAP",
            .body = try std.fmt.allocPrint(arena, "The debugger's column: variables, watches, the call stack and breakpoints, fed by a Debug Adapter Protocol server named in `dap` in config.zon. Click shows it; right-click is its menu. Breakpoints are set in the editor gutter (click the sign cell) and survive here without a session; the run itself starts from the Run menu or `dap.run`.{s}", .{marked(app, .debug)}),
            .keys = &.{ .{ .command = .@"view.activity_debug", .label = "Debug" }, .{ .command = .@"dap.toggle_breakpoint", .label = "Toggle breakpoint" } },
            .links = &.{ .{ .command = .{ .id = .@"view.activity_debug", .label = "Show the debug column" } }, .{ .command = .{ .id = .@"dap.run", .label = "Start debugging" } }, ask },
        },
        .integrations => .{
            .title = "Integrations",
            .body = try std.fmt.allocPrint(arena, "The installed integrations — Jira, Bitbucket, the browser, the tools — on the Installed tab, with the Marketplace beside it; a row's Enter opens the integration and its right-click offers configure, disable, pin to the rail or the dock, uninstall. Click shows the section; right-click is its menu. An integration's own settings land in Settings → Integrations once it is installed.{s}", .{marked(app, .integrations)}),
            .keys = &.{.{ .command = .@"view.activity_integrations", .label = "Integrations" }},
            .links = &.{ .{ .command = .{ .id = .@"view.activity_integrations", .label = "Show integrations" } }, .{ .command = .{ .id = .@"integrations.show_marketplace", .label = "The marketplace" } }, comptime copy.docsSection("Launchers and integration manifests") },
        },
        .sessions => .{
            .title = "Sessions — Claude Code and Codex",
            .body = try std.fmt.allocPrint(arena, "Every AI session this workspace has — running, waiting for your approval, ended — one card each with its branch, cwd and what the pane is showing, plus the cloud runs. Click shows the section; right-click is its menu; `t` opens the sessions table across workspaces. A card waiting on approval sorts to the top under the State order, so the thing that needs you is the first row.{s}", .{marked(app, .sessions)}),
            .keys = &.{.{ .command = .@"view.activity_sessions", .label = "Sessions" }},
            .links = &.{ .{ .command = .{ .id = .@"view.activity_sessions", .label = "Show sessions" } }, .{ .command = .{ .id = .@"ai.claude_code_new", .label = "Start a Claude session" } }, .{ .command = .{ .id = .@"sessions.table", .label = "The sessions table" } } },
        },
        .http => .{
            .title = "HTTP — requests",
            .body = try std.fmt.allocPrint(arena, "The request client's panel: one row per `.http` / `.curl` / `.rest` file, then the RECENT sends, the CAPTURED browser traffic, the ENVS, chains, mocks, cookies and collections, each section with its own header chips. Click shows it; right-click is its menu. `+ New request` opens a blank Request pane; Enter on a file row opens it as a request rather than as text.{s}", .{marked(app, .http)}),
            .links = &.{ .{ .command = .{ .id = .@"view.activity_http", .label = "Show the HTTP panel" } }, .{ .command = .{ .id = .@"http.new", .label = "New request" } }, .{ .command = .{ .id = .@"http.paste_curl", .label = "Paste a curl command" } } },
        },
        .notes => .{
            .title = "Notes — .mnml/notes",
            .body = try std.fmt.allocPrint(arena, "Persistent scratch: one row per markdown file in the workspace's `.mnml/notes/`, newest first by default, with a filter and a sort chip on the header. Click shows the section; right-click is its menu. `+` makes a note and opens it; Enter on a row opens it in an editor. The folder is the workspace's, so notes travel with the checkout and not with mnml.{s}", .{marked(app, .notes)}),
            .links = &.{ .{ .command = .{ .id = .@"view.activity_notes", .label = "Show notes" } }, .{ .command = .{ .id = .@"notes.new", .label = "New note" } } },
        },
        .todos => .{
            .title = "TODOs — the markers in the code",
            .body = try std.fmt.allocPrint(arena, "Every TODO / FIXME / XXX / HACK / REVIEW marker in the workspace, grouped by file and rescanned as files change (throttled to once every two seconds — the scan walks the tree). Click shows the section; right-click is its menu. Enter jumps to the line; a row's kebab hands the marker to a Claude or Codex session with the file and line filled in.{s}", .{marked(app, .todos)}),
            .links = &.{ .{ .command = .{ .id = .@"view.activity_todos", .label = "Show TODOs" } }, .{ .command = .{ .id = .@"todos.refresh", .label = "Rescan now" } }, .{ .command = .{ .id = .@"todos.fix_with_agent", .label = "Hand one to an agent" } } },
        },
        .findings => .{
            .title = "Findings — .mnml/findings",
            .body = try std.fmt.allocPrint(arena, "The reports a tester or a review round left in the workspace's `.mnml/findings/` — one row per markdown file, with a sort chip and a filter. Click shows the section; right-click is its menu. Enter opens a finding in the editor; the row's kebab resolves or deletes it. `+` starts a new one from a template.{s}", .{marked(app, .findings)}),
            .links = &.{ .{ .command = .{ .id = .@"view.activity_findings", .label = "Show findings" } }, .{ .command = .{ .id = .@"findings.new", .label = "New finding" } } },
        },
        .scripts => .{
            .title = "Scripts — what init.lua registered",
            .body = try std.fmt.allocPrint(arena, "Every command, section and hook the Lua scripts registered, each with the file and line it came from, plus the installed script packages. Click shows the section; right-click is its menu. The ⟳ chip reloads every script; a script that failed to load shows its error here rather than in a toast you may have missed.{s}", .{marked(app, .scripts)}),
            .links = &.{ .{ .command = .{ .id = .@"view.activity_scripts", .label = "Show scripts" } }, .{ .command = .{ .id = .@"script.reload", .label = "Reload" } }, .{ .command = .{ .id = .@"script.doctor", .label = "Script doctor" } } },
        },
        .script => .{
            .title = "A script's section",
            .body = "A section a Lua script registered with `mnml.section{}` — its rows, filter, sort and folds are the script's to fill, and the rail row wears the glyph the script chose. Click shows it; right-click is its menu. When the script reloads the section is rebuilt, so a row you were on may move.",
            .links = &.{.{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } }},
        },
        .diagnostics => .{
            .title = "Diagnostics",
            .body = "The language servers' problems for every open file, worst first, with a jump to the line on Enter and a filter by severity. It is not a rail section of its own — it lives in the right column — which is why this row does not take the mark. Click shows it; the statusline's count chip opens the same list.",
            .keys = &.{ .{ .command = .@"lsp.diagnostics", .label = "Diagnostics" }, .{ .command = .@"lsp.next_diagnostic", .label = "Next problem" } },
            .links = &.{ .{ .command = .{ .id = .@"lsp.diagnostics", .label = "Show diagnostics" } }, ask },
        },
        .outline => .{
            .title = "Outline",
            .body = "The active file's symbols from its language server — functions, types, headings — as a tree; Enter jumps to one and the cursor's own symbol is followed as you move. It lives in the right column rather than on the rail, so this row does not take the mark. Empty until a server has indexed the file.",
            .keys = &.{.{ .command = .@"lsp.symbols", .label = "Symbol picker" }},
            .links = &.{ .{ .command = .{ .id = .@"outline.show", .label = "Show the outline" } }, .{ .command = .{ .id = .@"lsp.symbols", .label = "Pick a symbol" } } },
        },
    };
}

fn pinned(app: *App, arena: Allocator, i: u16) Allocator.Error!?Entry {
    const pins = try integrations.pinnedChips(app, arena);
    if (i >= pins.len) return .{
        .title = "Pinned launcher",
        .body = "An integration pinned to the rail from its chip's menu (*Pin to activity bar*). Click runs the integration's command; right-click offers disable, show on the top bar, remove from the rail, pin to the dock, copy id. The pin is remembered in `ui.activity_bar_pinned_integrations`.",
        .links = &.{.{ .command = .{ .id = .@"view.activity_integrations", .label = "The integrations section" } }},
    };
    const c = pins[i].chip;
    return .{
        .title = try std.fmt.allocPrint(arena, "{s}{s}", .{ c.tooltip, if (c.enabled) "" else " — disabled" }),
        .body = try std.fmt.allocPrint(arena, "The `{s}` integration, pinned to the rail from its chip's menu. Click runs its command — the same one its row in Integrations runs on Enter; right-click offers disable, show on the top bar, remove from the rail, pin to the dock, copy id. {s}The pin lives in `ui.activity_bar_pinned_integrations`, so it survives a restart and a rescan.", .{ c.id, if (c.enabled) "" else "It is disabled at the moment, so the click toasts instead of running; enable it from the menu or the Integrations section. " }),
        .keys = &.{.{ .command = .@"view.activity_integrations", .label = "Integrations" }},
        .links = &.{ .{ .command = .{ .id = .@"integrations.unpin_from_activity_bar", .label = "Remove from the rail" } }, .{ .command = .{ .id = .@"integrations.pin_to_dock", .label = "Pin to the dock" } }, .{ .command = .{ .id = .@"integrations.configure_picker", .label = "Configure it" } } },
    };
}

fn script(app: *App, arena: Allocator, i: u16) Allocator.Error!?Entry {
    const rows = try script_section.railRows(app, arena);
    if (i >= rows.len) return try section(app, arena, .script);
    return .{
        .title = try std.fmt.allocPrint(arena, "{s} — a script's section", .{rows[i].label}),
        .body = try std.fmt.allocPrint(arena, "A section registered by a Lua script with `mnml.section{{}}` — `{s}` — whose rows, filter, sort and folds the script fills. Click shows it in its column; right-click is its menu. A reload of the script rebuilds the section, so a row you were on may move.", .{rows[i].label}),
        .links = &.{ .{ .command = .{ .id = .@"view.activity_scripts", .label = "The scripts section" } }, .{ .command = .{ .id = .@"script.reload", .label = "Reload" } } },
    };
}

/// For the AI: which section, whether it is marked, which side it is
/// on, and what the click runs.
pub fn askContext(app: *App, arena: Allocator, part: Part) Allocator.Error!?[]const u8 {
    return switch (part) {
        .section => |s| try std.fmt.allocPrint(arena, "- rail section: {s}; marked now: {s}; its click runs: {s}\n", .{ s.meta().label, if (activity_bar.active(app) == s) "yes" else "no", if (activity_bar.commandOf(s)) |c| command.name(c) else "(a script section)" }),
        else => null,
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every section, the gear, a pin and a script row have entries" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    inline for (comptime std.enums.values(Section)) |s| {
        const e = (try entry(&app, a, .{ .section = s })) orelse return error.MissingEntry;
        try t.expect(e.body.len >= 40);
    }
    try t.expectEqualStrings("Settings gear", (try entry(&app, a, .gear)).?.title);
    try t.expect((try entry(&app, a, .{ .pin = 0 })) != null);
    try t.expect((try entry(&app, a, .{ .script = 0 })) != null);
    // The explorer is the marked section on a fresh app, and says so.
    try t.expect(std.mem.indexOf(u8, (try entry(&app, a, .{ .section = .explorer })).?.body, "marked section") != null);
    try t.expect(std.mem.indexOf(u8, (try entry(&app, a, .{ .section = .notes })).?.body, "marked section") == null);
}
