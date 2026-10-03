//! Hover help for the Settings overlay: one entry per row, the section
//! names on its strip, the filter pill, the Reset action, an installed
//! integration's rows.
//!
//! A row's entry is hand-written where the setting is one a user
//! trips on (the hover help itself, the input style, the slide-in
//! modes, the docks); every other row's is generated from its label,
//! docs/CONFIG.md's comment for the key (`zon_schema.configDocs`), its
//! choices and its current one, and where it is written — so a new
//! row has real words the day it lands, and the audit counts it
//! curated. The `keys` are the overlay's own, literal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const Key = copy.Key;
const settings = @import("../settings.zig");
const ui_settings = @import("../../ui/settings.zig");
const zon_schema = @import("../../config/zon_schema.zig");

const ask = copy.ask_link;

const row_keys = [_]Key{ .{ .chord = "←→", .label = "Change the value" }, .{ .chord = "Ctrl+R", .label = "Reset this row" }, .{ .chord = "Enter", .label = "Save and close" } };

/// The entry for the Settings hit `h` (a row, an option chip, a section
/// name, the filter pill, the box itself, the Reset row) — the overlay
/// must be the one open, since the ids are its own.
pub fn entry(app: *App, arena: Allocator, h: u32) Allocator.Error!?Entry {
    return switch (ui_settings.decodeHit(h)) {
        .surface => .{
            .title = "Settings",
            .body = "The everyday settings as rows, sectioned UI / Editor / AI / Integrations: `←→` change the focused row, `↑↓` walk, Tab steps sections, Ctrl+R resets a row, `/` filters by label (vim adds `h l j k`, `r` for a row and `R` for all of them), Enter saves and closes, Esc closes and puts back exactly the config you opened with. A `*` marks a row that differs from the shipped default. Each row says where it is written — the home config or this workspace's.",
            .keys = &.{ .{ .chord = "/", .label = "Filter the rows" }, .{ .chord = "Enter", .label = "Save and close" }, .{ .chord = "Esc", .label = "Cancel" } },
            .links = &.{ .{ .command = .{ .id = .@"view.settings_search", .label = "Search the settings" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon instead" } }, comptime copy.docsSection("The settings overlay") },
        },
        .filter => .{
            .title = "Settings filter",
            .body = "Type to narrow the rows to the ones whose label matches; the section names stay so a match keeps its context. Esc clears the query and closes the pill at once, and a second Esc closes Settings; Enter hands the keys back to the list with the query kept. Under the standard profile any printable key opens the pill by itself, the way VS Code's settings screen types-to-filter.",
            .keys = &.{ .{ .chord = "Esc", .label = "Clear and close the pill" }, .{ .chord = "Enter", .label = "Back to the list" }, .{ .chord = "↑ / ↓", .label = "Walk the matches" } },
            .links = &.{.{ .command = .{ .id = .@"view.settings_search", .label = "Open with the filter" } }},
        },
        .section => |n| try sectionName(arena, n),
        .row => |id| try rowEntry(app, arena, id, false),
        .option => |o| try rowEntry(app, arena, o.id, true),
    };
}

fn sectionName(arena: Allocator, n: usize) Allocator.Error!?Entry {
    const names = [_][]const u8{ "UI", "Editor", "AI", "Integrations", "Reset" };
    if (n >= names.len) return null;
    return .{
        .title = try std.fmt.allocPrint(arena, "Settings — {s}", .{names[n]}),
        .body = switch (n) {
            0 => "The strip's UI name: click scrolls the list to the UI section — what is on screen, the columns and bars and their slide-in modes, the docks, the tabs, the hover help, the theme. Tab and Shift+Tab step sections from the keyboard (`[` and `]` too, under vim). A UI row that is per-workspace says so in its aside.",
            1 => "The strip's Editor name: click scrolls to the Editor section — the input style (vim or standard), auto-pair and indent, format on save, the tab width, the clipboard, the size limits for highlighting and the LSP. Some Editor rows — the tab width, format on save — are written to this workspace, so a project keeps its own; each row's aside says where it goes.",
            2 => "The strip's AI name: click scrolls to the AI section — inline suggestions and their backend, the idle and timeout delays, which backend each product routes to (the CLI, the API, or off), the meter chip's mode. `off` on a route is how the Ask links in this box come to say so.",
            3 => "The strip's Integrations name: click scrolls to the Integrations section — the built-in rows (Sonos, the browser, the marketplace, session restore) and then one row per setting an installed integration's manifest declares, labelled with the integration's name. Installing an integration adds its rows here.",
            else => "The Reset section: its one row puts every setting back to the shipped default after a confirm. Under vim `R` on the list does the same; `r` (vim) or Ctrl+R (either profile) resets only the focused row.",
        },
        .keys = &.{ .{ .chord = "Enter", .label = "Save and close" }, .{ .chord = "Esc", .label = "Cancel" } },
    };
}

fn rowEntry(app: *App, arena: Allocator, id: u32, option_chip: bool) Allocator.Error!?Entry {
    if (id == settings.reset_id) return .{
        .title = "Reset all to defaults",
        .body = "Puts every setting on every row back to the shipped default, after a confirm box in which Cancel is the focused answer. The reset is written like any other change — Enter saves it, Esc on the overlay still puts the opened-with config back. It does not touch what the overlay does not list: workspaces, key rebinds, LSP servers, launchers stay as they are in config.zon.",
        .keys = &.{ .{ .chord = "Ctrl+R", .label = "Reset the focused row" }, .{ .chord = "R", .label = "Reset all (vim, with a confirm)" } },
        .links = &.{ .{ .command = .{ .id = .@"app.reset_to_defaults", .label = "Reset mnml itself (backup + relaunch)" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } } },
    };
    if (id >= settings.integ_base) return try integrationRow(app, arena, id - settings.integ_base);
    if (id >= settings.rows.len) return null;
    var e = if (try handWritten(app, arena, id)) |h| h else try generated(app, arena, id);
    if (option_chip) e.aside = if (e.aside) |a| try std.fmt.allocPrint(arena, "This chip is one of the row's choices — click picks it. {s}", .{a}) else "This chip is one of the row's choices — click picks it.";
    return e;
}

/// The current choice of the row `id` as the overlay shows it, and the
/// choices around it.
const Current = struct { value: []const u8, options: []const []const u8, modified: bool, number: bool };

fn current(app: *App, arena: Allocator, id: u32) Allocator.Error!?Current {
    const list = try settings.items(app, arena);
    for (list) |it| switch (it) {
        .row => |r| if (r.id == id) {
            if (r.number != null) return .{ .value = try std.fmt.allocPrint(arena, "{d}", .{r.current}), .options = &.{}, .modified = r.modified, .number = true };
            return .{ .value = if (r.current < r.options.len) r.options[r.current] else "?", .options = r.options, .modified = r.modified, .number = false };
        },
        else => {},
    };
    return null;
}

fn scopeLine(id: u32) []const u8 {
    return switch (settings.rows[id].scope) {
        .home => "Written to the home config — it holds in every workspace.",
        .workspace => "Written to this workspace's .mnml/config.zon — a project keeps its own.",
    };
}

/// A row from its label, docs/CONFIG.md's comment for the key, its
/// choices and where it is written.
fn generated(app: *App, arena: Allocator, id: u32) Allocator.Error!Entry {
    const spec = settings.rows[id];
    const docs = try zon_schema.configDocs(arena);
    var body: std.ArrayListUnmanaged(u8) = .empty;
    if (docs.get(spec.path)) |line| {
        try body.print(arena, "`{s}` — {s}", .{ spec.path, line });
        if (line.len > 0 and line[line.len - 1] != '.') try body.append(arena, '.');
        try body.append(arena, ' ');
    } else try body.print(arena, "`{s}` in config.zon. ", .{spec.path});
    if (try current(app, arena, id)) |c| {
        if (c.number) {
            try body.print(arena, "A number row: `←→` step it; it is {s} now", .{c.value});
        } else {
            try body.print(arena, "The choices are ", .{});
            for (c.options, 0..) |o, i| {
                if (i > 0) try body.appendSlice(arena, if (i + 1 == c.options.len) " and " else ", ");
                try body.print(arena, "`{s}`", .{o});
            }
            try body.print(arena, "; it is `{s}` now", .{c.value});
        }
        try body.appendSlice(arena, if (c.modified) " (changed from the default — `r` puts it back). " else " (the default). ");
    }
    try body.appendSlice(arena, "Enter saves; Esc puts back what you opened with.");
    return .{
        .title = spec.label,
        .body = body.items,
        .aside = scopeLine(id),
        .keys = &row_keys,
        .links = &.{.{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }},
    };
}

/// The rows whose entry is worth more than the generated one.
fn handWritten(app: *App, arena: Allocator, id: u32) Allocator.Error!?Entry {
    const path = settings.rows[id].path;
    const c = try current(app, arena, id);
    const now: []const u8 = if (c) |cc| cc.value else "?";
    inline for (hand_written) |hw| if (std.mem.eql(u8, hw.path, path)) {
        return .{
            .title = settings.rows[id].label,
            .body = try std.fmt.allocPrint(arena, "{s} It is `{s}` now{s}.", .{ hw.body, now, if (c != null and c.?.modified) ", changed from the default" else "" }),
            .aside = scopeLine(id),
            .keys = &row_keys,
            .links = hw.links,
        };
    };
    return null;
}

const Hand = struct { path: []const u8, body: []const u8, links: []const copy.Link = &.{.{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }} };

const hand_written = [_]Hand{
    .{ .path = "ui.hover_help", .body = "This box — the help panel at the bottom of the left column that describes whatever the pointer rests on, or the keyboard's focus when the pointer is elsewhere. `off` removes it and gives the rows to the section above; the tooltip near the pointer (`ui.hover_tooltip`) is separate. Under SESSIONS it steps aside by itself while the cards would otherwise scroll, and comes back when they fit; its pin keeps it. The panel's kebab has the same switch.", .links = &.{ .{ .command = .{ .id = .@"view.toggle_hover_help", .label = "Toggle the panel" } }, .{ .command = .{ .id = .@"view.discovery", .label = "The click-discovery panel" } } } },
    .{ .path = "ui.hover_help_height", .body = "How many rows the help panel takes at the bottom of the left column, 4 to 60. The section above always keeps six rows, so on a short column the panel shrinks to fit, and a column under ten rows paints no panel at all. Long entries scroll with the wheel.", .links = &.{.{ .command = .{ .id = .@"view.toggle_hover_help", .label = "Toggle the panel" } }} },
    .{ .path = "ui.hover_tooltip", .body = "The small box that follows the pointer with a one-line description of the thing under it — the same words this panel uses as its fallback. Off by default because the panel says more without covering anything; on, both show. The statusline's figures list what they count in the tooltip either way.", .links = &.{.{ .command = .{ .id = .@"view.toggle_hover_tooltip", .label = "Toggle the tooltip" } }} },
    .{ .path = "ui.focus_follows_mouse", .body = "Whether the pointer moves the keyboard focus. `off` (the default) is click-to-focus. `panes`: moving onto another split's body — an editor, a terminal, a session — focuses it; the tree and the side sections still want a click. `all`: the side columns and the dock take the focus on hover too. Nothing moves while a menu, a picker, a prompt, a confirm box or the which-key popup is up, while a button is held (a drag across a divider stays a drag), or mid-chord, and a hover never scrolls the pane or moves its cursor.", .links = &.{.{ .settings = .{ .row = copy.settingsRow("ui.focus_follows_mouse_delay_ms"), .label = "The hover delay" } }} },
    .{ .path = "ui.focus_follows_mouse_delay_ms", .body = "How long the pointer has to rest on a new pane or section before focus follows it, in milliseconds, 0 to 2000. 0 is at once; a few hundred keeps a pointer that is only crossing a split on its way somewhere else from pulling the focus along. Read only while `Focus follows mouse` is on.", .links = &.{.{ .settings = .{ .row = copy.settingsRow("ui.focus_follows_mouse"), .label = "Focus follows mouse" } }} },
    .{ .path = "editor.input_style", .body = "Which keymap profile the keys use: `vim` (modal — NORMAL / INSERT / VISUAL, the NvChad chords with Space as the leader) or `standard` (VS Code's chords, modeless). The two are whole profiles, not one map with patches, so a chord you learned in one may not exist in the other; the cheatsheet lists the active one. The statusline's mode chip swaps them with a click.", .links = &.{ .{ .command = .{ .id = .@"editor.toggle_keymap", .label = "Swap now" } }, .{ .command = .{ .id = .@"view.cheatsheet", .label = "The cheatsheet" } } } },
    .{ .path = "ui.theme", .body = "The colour theme, from the shipped set and any `.zon` theme in the data root's themes folder. `theme.auto_system` follows the terminal's light/dark instead; the theme pill in the top-right cluster toggles between the configured pair. A theme only recolours — glyphs and layout are the same under every one.", .links = &.{ .{ .command = .{ .id = .@"theme.pick", .label = "Pick a theme" } }, .{ .command = .{ .id = .@"theme.auto_system", .label = "Follow the system" } } } },
    .{ .path = "ui.menu_bar", .body = "The menu bar's mode: `always` keeps the words on the top row; `auto` hides them and slides them in when the pointer rests on the top row (the `⋯` grip marks the spot), the pin chip past the words keeping them for the session; `hidden` never shows them — Alt+F and the other accelerators still open the menus.", .links = &.{ .{ .command = .{ .id = .@"view.menu_bar_cycle", .label = "Cycle the mode" } }, .{ .command = .{ .id = .@"view.menu_bar_pin", .label = "Pin the bar" } } } },
    .{ .path = "ui.activity_bar", .body = "The rail of section icons down the left edge: `always` on; `auto` hidden until the pointer rests in the first column, staying while it is on the rail; `hidden` off — the `view.activity_*` commands and the rail menu's sections still work from the palette. The rail is inside the left column, so a hidden column hides it too.", .links = &.{.{ .command = .{ .id = .@"view.activity_bar_cycle", .label = "Cycle the mode" } }} },
    .{ .path = "ui.sidebar", .body = "How the two side columns come and go: `always` carved out of the frame; `auto` hidden until the pointer rests at the screen's edge, then painted OVER the editor so no pane moves, sliding back when the pointer leaves unless the keyboard is in it or the pin chip docked it; `hidden` off until toggled. The `⋮` grip at the edge marks the band. Below `ui.sidebar_auto_below` columns an `always` column behaves as `auto`.", .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Pin the column" } }, .{ .command = .{ .id = .@"view.toggle_tree", .label = "Toggle the left column" } } } },
    .{ .path = "ui.sidebar_auto_below", .body = "A narrow terminal's side columns: on a terminal fewer columns wide than this, an `always` column behaves as `auto` — hidden, brought in over the editor by the screen edge's `⋮` grip or by any section's command — and it docks again the moment the terminal is this wide. An explicit `auto` or `hidden` is left alone, and the keys never stay in a column that went away. 0 turns the rule off. The one narrow-terminal rule: `ui.auto_hide_narrow_width`, its old name, is read as this key.", .links = &.{ .{ .command = .{ .id = .@"view.sidebar_pin", .label = "Pin the column" } }, .{ .command = .{ .id = .@"view.toggle_tree", .label = "Toggle the left column" } } } },
    .{ .path = "ui.dock.mode", .body = "The LAUNCHER dock — the strip of integrations, terminals, launchers and pinned commands along one edge of the editor area (not the bottom panel, not the dock widgets). `always` carves it out of the frame; `auto_hide` paints it over the editor when the pointer rests at its edge, the pin chip keeping it for the session; `hidden` never on hover, `view.dock_toggle` still reveals it once.", .links = &.{ .{ .command = .{ .id = .@"view.dock_cycle_mode", .label = "Cycle the mode" } }, .{ .command = .{ .id = .@"view.dock_pin", .label = "Pin the dock" } } } },
    .{ .path = "ui.dock.edge", .body = "Which edge the launcher dock lives on: `bottom`, `left` or `right`. There is no top — that row is the menu bar's. On a side edge the dock takes the outermost column and the side column's own reveal band moves one cell in, so the outer cell summons the dock and the next one the column; both stay reachable.", .links = &.{.{ .command = .{ .id = .@"view.dock_move", .label = "Move it to another edge" } }} },
    .{ .path = "ui.dock.placement", .body = "For a bottom dock, which row it takes: `inner` is the editor area's last row, above the statusline, so the two rows the frame keeps for itself never move; `outer` is the screen's last row, under the `:` line, and both of those move up one; `shared` puts the strip ON the `:` line's row, right of whatever is typed there — no row of its own, no grip, always up (an `auto_hide` mode reads as `always` there), and out of the way for as long as a typed command would reach its first item. `:dock above` / `:dock below` / `:dock shared` say the same from the command line.", .links = &.{.{ .command = .{ .id = .@"view.dock_pin", .label = "Pin the dock" } }} },
    .{ .path = "ui.edge_grips", .body = "The three dots painted at the middle of a hidden slide-in's edge — the menu bar's top centre, a side column's edge, the dock's — so the band that summons it is visible. Dwelling on a grip reveals the surface because the grip is inside the band; click reveals AND pins. `off` puts the invisible bands back for people who know them by heart.", .links = &.{.{ .command = .{ .id = .@"view.dock_pin", .label = "Pin the dock" } }} },
    .{ .path = "ui.maximize_click", .body = "What a left click on the maximize chip at the tab strip's right end runs: `zoom_pane` gives the active pane its leaf's whole area and hides the other splits; `fullscreen` hides the chrome — rail, columns, bars — as well. The chip's right-click lists both and runs the one you pick once without re-pointing the click; this row re-points it.", .links = &.{ .{ .command = .{ .id = .@"view.toggle_zoom", .label = "Zoom the active pane" } }, .{ .command = .{ .id = .@"view.fullscreen", .label = "Full screen" } } } },
    .{ .path = "ui.confirm_quit", .body = "Whether quitting with nothing unsaved still asks. With unsaved buffers the quit box always asks — Save all, Quit anyway, Cancel; this row is only about the clean case, where the box offers Quit and Cancel with Cancel focused so an Enter on reflex does nothing. The session is saved on the way out either way.", .links = &.{.{ .command = .{ .id = .@"app.quit", .label = "Quit" } }} },
    .{ .path = "ui.ascii_icons", .body = "`on` replaces every Nerd Font glyph — the rail's icons, the file-type icons, the chips' marks — with a one-character ASCII twin, for a terminal without a patched font or a font that draws them as boxes. `--ascii` on the command line is the same switch for one run. The glyph audit (`zig build glyph-audit`) is what keeps every glyph paired with a twin.", .links = &.{.{ .command = .{ .id = .@"integrations.audit_glyphs", .label = "Audit the glyphs" } }} },
    .{ .path = "ui.clock", .body = "The statusline's clock, on or off: on shows local time, off hides it. The chip's click flips local and UTC (a trailing Z says so) for this session only, and its right-click picks local, UTC or hide; only this row is written to the config.", .links = &.{ .{ .command = .{ .id = .@"clock.utc", .label = "Show UTC" } }, .{ .command = .{ .id = .@"clock.hide", .label = "Hide the clock" } } } },
    .{ .path = "ui.terminal_glyph", .body = "The mark the terminal chip and every terminal tab wear: `ghostty` (the ghost), `terminal` (the plain codicon) or `custom` (an SVG of your own baked into the MnmlSymbols font behind the ghost's codepoint — `view.terminal_glyph_custom` asks for the file). The terminal chip's *Icon* submenu is the same choice.", .links = &.{ .{ .command = .{ .id = .@"view.terminal_glyph_custom", .label = "Bake a custom SVG" } }, .{ .command = .{ .id = .@"view.terminal_glyph_ghostty", .label = "The ghost" } } } },
    .{ .path = "ui.claude_mark", .body = "The mark Claude wears everywhere the chrome draws one — the tab bar's chip, a session's tab, its SESSIONS card, the dock: `figure` (the Claude Code figure) or `spark` (the Anthropic spark). The Claude chip's *Icon* submenu is the same choice. Both glyphs come from the MnmlSymbols font; `integrations.bake_ai_glyphs` rebuilds it.", .links = &.{.{ .command = .{ .id = .@"integrations.bake_ai_glyphs", .label = "Bake the AI glyphs" } }} },
    .{ .path = "ui.wrap", .body = "Soft wrap: long lines fold at the pane's right edge instead of scrolling sideways, with the horizontal scroll pinned to 0. Visual only — the file's line breaks are untouched. The statusline's WRAP chip and `:set wrap` / `:set nowrap` are the same switch.", .links = &.{.{ .command = .{ .id = .@"view.toggle_wrap", .label = "Toggle wrap" } }} },
    .{ .path = "ui.line_numbers", .body = "The line-number gutter on every editor. Off, the gutter keeps its sign column for diagnostics and breakpoints, so the rail and the marks still have a home. `ui.relative_line_numbers` counts from the cursor line instead when this is on — vim's `relativenumber`.", .links = &.{ .{ .command = .{ .id = .@"view.toggle_line_numbers", .label = "Toggle line numbers" } }, .{ .command = .{ .id = .@"view.toggle_relative_numbers", .label = "Toggle relative numbers" } } } },
    .{ .path = "ui.relative_line_numbers", .body = "vim's `relativenumber`: the gutter counts lines away from the cursor line — the cursor's own line shows its absolute number — so `5j` and `3k` can be read off the gutter. Needs `ui.line_numbers` on to show at all.", .links = &.{.{ .command = .{ .id = .@"view.toggle_relative_numbers", .label = "Toggle relative numbers" } }} },
    .{ .path = "ui.preview_tabs", .body = "VS Code's preview tabs: a single click in the tree opens a file in an italic tab that the next single-click open replaces, so browsing does not pile up tabs. Editing, double-clicking or pinning makes it a real tab. Off, every open is a real tab.", .links = &.{.{ .command = .{ .id = .@"buffer.pin_toggle", .label = "Pin the active tab" } }} },
    .{ .path = "ui.auto_equalize_splits", .body = "On, every split and every close re-shares the sizes in the tab page equally, so closing one of three terminals leaves two halves rather than an uneven pair. Off, a new split takes half of the pane it came from and a close hands its space to the neighbour. The Window menu's Auto-equalize splits row is the same switch and carries a tick when it is on.", .links = &.{ .{ .command = .{ .id = .@"view.equalize_splits", .label = "Equalize now" } }, .{ .command = .{ .id = .@"view.toggle_auto_equalize_splits", .label = "Toggle it" } } } },
    .{ .path = "ui.tree_width", .body = "The left column's width, per workspace. `auto` (the default) is a fifth of the window, clamped to 30..48 cells — 30 at 80 and 120 columns, 40 at 200 — and follows a resize; a number pins it. A divider drag or the divider menu's *Set width…* overrides either for the session, and `view.reset_tree_width` goes back to this. The info panel below the tree and the section headers' chips are laid out to the width — at 30 a chip cluster may drop to its icon-only form.", .links = &.{ .{ .command = .{ .id = .@"view.reset_tree_width", .label = "Reset the width" } }, .{ .command = .{ .id = .@"view.set_tree_width", .label = "Set a width for the session" } } } },
    .{ .path = "ui.welcome", .body = "What the editor area shows while no pane is open. `full` is the start surface: recent workspaces, recent files, this workspace's sessions to resume with a row that starts a new one, and the shortcuts for your profile — j / k walk a list, Tab moves between them, Enter acts. `minimal` is the word mark and the shortcut list alone; `off` leaves the area blank.", .links = &.{ .{ .command = .{ .id = .@"view.cheatsheet", .label = "Every chord" } }, .{ .command = .{ .id = .@"picker.recent", .label = "Recent files" } } } },
    .{ .path = "ui.pane_rail", .body = "The one-cell colour stripe down a pane's left edge that says which pane you are looking at — a Claude session's matches its SESSIONS card, two shells side by side stop being identical grey. The editor keeps its gutter width and paints the rail into the sign column instead; a sign still wins the cell it needs.", .links = &.{.{ .command = .{ .id = .@"sessions.new_menu", .label = "A session's colour" } }} },
    .{ .path = "ui.jobs_chip", .body = "The statusline chip for background jobs — a language server starting, a git fetch, a test run, a send, a linter. `auto` shows it while one runs and for ten seconds after one fails; `always` keeps an idle face too; `hidden` never paints it. The JOBS list is still `jobs.show` either way.", .links = &.{.{ .command = .{ .id = .@"jobs.show", .label = "Open the jobs list" } }} },
    .{ .path = "ui.focus_cue", .body = "How the screen says which pane or section has the keys. `dim` paints everything that does NOT have them — each other pane's tab name, the tree's workspace path — in the dim colour; `rail` leaves the words alone and keeps only the focused pane's rail at full colour, the rest stepped back, and lights the focused section's header; `both` (the default) does the two at once.", .links = &.{ .{ .command = .{ .id = .@"view.focus_tree", .label = "Focus the tree" } }, .{ .command = .{ .id = .@"view.focus_pane", .label = "Focus the active pane" } } } },
    .{ .path = "ui.stress_meter", .body = "The four-block frame-time meter in the statusline that fills as the 95th-percentile render time climbs. Its click toasts the numbers and its right-click copies or resets them; `off` here hides it (`perf.hide_stress` too). Leave it on while chasing typing lag — a full bar names the frame, not the keyboard.", .links = &.{ .{ .command = .{ .id = .@"perf.toast_stress", .label = "Show the numbers" } }, .{ .command = .{ .id = .@"perf.toggle_stress", .label = "Toggle the meter" } } } },
    .{ .path = "ui.copy_on_select", .body = "A terminal or session pane copies a mouse selection the moment the button comes up, as ghostty does, and Ctrl+C over a selection then only lets it go. Off, a drag only selects and Ctrl+C over the selection is what copies it. Either way Ctrl+C over a selection never reaches the program in the pane; with nothing selected it is the program's own Ctrl+C. Editor panes do not copy on select.", .links = &.{.{ .command = .{ .id = .@"term.copy", .label = "Copy the selection" } }} },
    .{ .path = "ui.click_echo", .body = "Echo every click's target on the statusline (`click @12,3 → statusline_seg:2`) — the click inspector, for finding out what a cell is when the hover help is not enough or when writing an e2e script by label. Off in daily use; `debug.toggle_click_inspector` is the same switch.", .links = &.{ .{ .command = .{ .id = .@"debug.toggle_click_inspector", .label = "Toggle the inspector" } }, .{ .command = .{ .id = .@"view.discovery", .label = "The click-discovery panel" } } } },
    .{ .path = "ai.routing.claude.backend", .body = "Which backend a Claude job (ask, explain, fix, the commit message) goes to: `sub` the `claude` CLI on your subscription, `api` the Anthropic API with the key from the environment, `auto` the API only when a key is set and the CLI is not on PATH, `off` none — the Ask links in this box then say so. Codex has its own row and no API route.", .links = &.{ .{ .command = .{ .id = .@"ai.toggle_backend", .label = "Toggle the backend" } }, .{ .command = .{ .id = .@"ai.show_config", .label = "Show the AI config" } } } },
    .{ .path = "ai.inline_suggestions", .body = "Ghost-text completions in the editor: after `ai.suggest_idle_ms` of no typing a request goes to `ai.suggest_backend` and the answer paints dim after the cursor — Tab accepts, any other key dismisses. The statusline's ghost chip shows the request's phase and says when one failed. Off, nothing is sent while you type.", .links = &.{ .{ .command = .{ .id = .@"ai.setup_suggestions", .label = "Suggestion setup" } }, .{ .command = .{ .id = .@"ai.toggle_inline_suggestions", .label = "Toggle suggestions" } } } },
    .{ .path = "ai.suggest_backend", .body = "Where ghost-text requests go — a local model, the Claude CLI, the API — each named by a token this row lists; the setup picker (`ai.setup_suggestions`) explains each and checks it can be reached. A backend that answers slowly is better paired with a longer `ai.suggest_idle_ms` so it is not asked on every pause.", .links = &.{ .{ .command = .{ .id = .@"ai.setup_suggestions", .label = "Suggestion setup" } }, .{ .command = .{ .id = .@"ai.suggestion_stats", .label = "Request statistics" } } } },
    .{ .path = "editor.format_on_save", .body = "Run the formatter on every save — the language server's, or the external one `format` in config.zon names for the file's language. An autosave is not formatted (the text would move under the cursor mid-thought); `editor.format` runs it once by hand.", .links = &.{ .{
        .command = .{ .id = .@"editor.format", .label = "Format now" },
    }, .{ .command = .{ .id = .@"lsp.format", .label = "Format with the LSP" } } } },
    .{ .path = "editor.tab_width", .body = "How many cells a tab character draws as, and the indent size a Tab key inserts (as spaces unless `:set noexpandtab`), per workspace. An `.editorconfig` in the workspace overrides it for the files it covers; `editor.set_tab_width` asks for a number once.", .links = &.{.{ .command = .{ .id = .@"editor.set_tab_width", .label = "Set the tab width" } }} },
    .{ .path = "session.restore", .body = "Whether the last session — tab pages, splits, every open file and its cursor — comes back at the next start of this workspace. Off, mnml starts on the welcome pane; `session.restore` from the palette brings the saved one back by hand. Terminals are a separate row: a restored shell is a new shell.", .links = &.{ .{ .command = .{ .id = .@"session.save", .label = "Save the session now" } }, .{ .command = .{ .id = .@"session.restore", .label = "Restore it" } } } },
};

fn integrationRow(app: *App, arena: Allocator, k: u32) Allocator.Error!?Entry {
    const integrations = @import("../integrations.zig");
    const refs = try integrations.settingRefs(app, arena);
    if (k >= refs.len) return null;
    const inst = &app.integrations.list[refs[k].installed];
    const s = inst.manifest.settings[refs[k].setting];
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try body.print(arena, "A setting the `{s}` integration's manifest declares — its own, written to its section of the config rather than to mnml's. The choices are ", .{inst.manifest.label});
    for (s.options, 0..) |o, i| {
        if (i > 0) try body.appendSlice(arena, if (i + 1 == s.options.len) " and " else ", ");
        try body.print(arena, "`{s}`", .{o});
    }
    const cur = integrations.settingIndex(app, refs[k]);
    try body.print(arena, "; it is `{s}` now. The integration reads it on its next poll or launch, so a running pane may need reopening to see the change.", .{if (cur < s.options.len) s.options[cur] else "?"});
    return .{
        .title = try std.fmt.allocPrint(arena, "{s}: {s}", .{ inst.manifest.label, s.label }),
        .body = body.items,
        .aside = "Written to the home config, under the integration's own key.",
        .keys = &row_keys,
        .links = &.{ .{ .command = .{ .id = .@"integrations.configure_picker", .label = "Configure the integration" } }, .{ .command = .{ .id = .@"integrations.show_manifest", .label = "Show its manifest" } } },
    };
}

/// For the AI: the row's key, its current value, the choices and the
/// doc line — enough to ask "what should this be".
pub fn askContext(app: *App, arena: Allocator, h: u32) Allocator.Error!?[]const u8 {
    const id: u32 = switch (ui_settings.decodeHit(h)) {
        .row => |id| id,
        .option => |o| o.id,
        else => return null,
    };
    if (id >= settings.rows.len) return null;
    const spec = settings.rows[id];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "- Settings row: {s} (config key `{s}`, {s})\n", .{ spec.label, spec.path, switch (spec.scope) {
        .home => "home config",
        .workspace => "this workspace's config",
    } });
    if (try current(app, arena, id)) |c| {
        try out.print(arena, "- current value: {s}{s}\n", .{ c.value, if (c.modified) " (changed from the default)" else " (the default)" });
        if (c.options.len > 0) {
            try out.appendSlice(arena, "- choices: ");
            for (c.options, 0..) |o, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, o);
            }
            try out.append(arena, '\n');
        }
    }
    const docs = try zon_schema.configDocs(arena);
    if (docs.get(spec.path)) |line| try out.print(arena, "- docs/CONFIG.md says: {s}\n", .{line});
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every Settings row has an entry — hand-written or generated — that names its key, its value and where it is written" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    try settings.open(&app);
    const a = app.frame.allocator();
    for (settings.rows, 0..) |spec, i| {
        const e = (try entry(&app, a, @intCast(i))) orelse {
            std.debug.print("no entry for settings row {s}\n", .{spec.path});
            return error.MissingEntry;
        };
        try t.expectEqualStrings(spec.label, e.title);
        try t.expect(e.body.len >= 40);
        try t.expect(e.aside != null);
    }
    // The hover-help row is hand-written and says what the box is.
    const hh = (try entry(&app, a, comptime copy.settingsRow("ui.hover_help"))).?;
    try t.expect(std.mem.indexOf(u8, hh.body, "This box") != null);
    try t.expect(std.mem.indexOf(u8, hh.body, "It is `on` now") != null);
    // A generated row reads the CONFIG.md comment and the current choice.
    const gen = (try entry(&app, a, comptime copy.settingsRow("ui.picker_position"))).?;
    try t.expect(std.mem.indexOf(u8, gen.body, "`ui.picker_position`") != null);
    try t.expect(std.mem.indexOf(u8, gen.body, "now") != null);
    // The option chip says it is one; the section names, the filter,
    // the surface and the Reset row answer too.
    try t.expect(std.mem.indexOf(u8, (try entry(&app, a, ui_settings.optionHit(0, 1))).?.aside.?, "one of the row's choices") != null);
    try t.expectEqualStrings("Settings — UI", (try entry(&app, a, ui_settings.sectionHit(0))).?.title);
    try t.expectEqualStrings("Settings filter", (try entry(&app, a, ui_settings.filter_id)).?.title);
    try t.expectEqualStrings("Settings", (try entry(&app, a, ui_settings.surface_id)).?.title);
    try t.expectEqualStrings("Reset all to defaults", (try entry(&app, a, settings.reset_id)).?.title);
    // Every hand-written path is a real row.
    inline for (hand_written) |hw| _ = comptime copy.settingsRow(hw.path);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
}
