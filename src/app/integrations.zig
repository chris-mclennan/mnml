//! Integrations: the INTEGRATIONS section (`PanelId.integrations`) and
//! what feeds it.
//!
//!   Installed    the manifests under `<data root>/integrations/*.zon`
//!                and `<workspace>/.mnml/integrations/*.zon`, scanned at
//!                startup and on `integrations.refresh`. Each manifest
//!                command becomes a `DynCommand` owned by the integration
//!                — one that opens the binary as a `Pane.mount` (or a pty
//!                when `mode = .pty`), or runs the manifest's `ex` line —
//!                each `chip` a button on the palette bar, each
//!                `statusline[]` entry a segment on the statusline, each
//!                `settings[]` entry a row of the settings overlay
//!                (stored in `<data root>/integration-settings.zon`,
//!                handed to the binary as `MNML_SETTING_<KEY>`).
//!   Marketplace  what the configured sources list (`marketplace.zig`).
//!   Dev          the folders under `integrations.dev_roots` (and the
//!                repo's own `integrations/` when the workspace holds
//!                `sdk/mnml-sdk`) that have a `build.zig` and a
//!                `manifest.zon` beside it — the manifest-to-be, read
//!                before anything is built. Build runs `zig build` there
//!                as a task pane; Install builds when nothing is built
//!                yet, runs `<binary> --install`, links the binary into
//!                `<data root>/bin/` and rescans; Rebuild + reinstall
//!                always builds first. A folder is a folder: the same
//!                integration sits in Installed and Dev at once.
//!
//! The filesystem is the interface: install is a file appearing,
//! uninstall is deleting it, enable / disable rewrites `chip.enabled`.
//! `Pane.integrations` is the detail pane for one entry of any tab —
//! the title, the description, a row of action buttons, the manifest's
//! sections.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const launch_profiles = @import("launch_profiles.zig");
const context_menus = @import("context_menus.zig");
const CommandError = command.CommandError;
const alloc = @import("../core/alloc.zig");
const panel = @import("../core/panel.zig");
const ListSort = panel.ListSort;
const manifest_mod = @import("../bridge/manifest.zig");
const Manifest = manifest_mod.Manifest;
const mount_pane = @import("mount_pane.zig");
const pty_pane = @import("pty_pane.zig");
const cmd_picker = @import("cmd_picker.zig");
const runners = @import("runners.zig");
const marketplace = @import("marketplace.zig");
const catalogue = @import("marketplace_catalogue.zig");
const font_scan = @import("font_scan.zig");
const claude_mark = @import("claude_mark.zig");
const bufferline = @import("../ui/bufferline.zig");
const fonts_section = @import("../ui/fonts_section.zig");
const side = @import("side.zig");
const usage_pane = @import("usage_pane.zig");
const auto_refresh = @import("auto_refresh.zig");
const settings = @import("settings.zig");
const hit = @import("../ui/hit.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const list_panel = @import("../ui/list_panel.zig");
const view = @import("../ui/integrations_view.zig");
const config = @import("../config/root.zig");
const launchers = @import("launchers.zig");
const integration_poll = @import("integration_poll.zig");

pub const settings_file = "integration-settings.zon";
pub const Tab = view.Tab;
pub const Panel = list_panel.ListPanel(view.Entry);

pub const Source = enum { home, workspace };

// ─── the first-party surfaces ───────────────────────────────────────────

/// The four surfaces mnml ships itself. No manifest describes them, so
/// no scan finds them — the Rust editor lists them as built-in
/// `IntegrationIcon` rows (`config.rs` ~1640) and everything else
/// comes from a manifest. This table is the Zig side of that list: the
/// Installed tab paints these four above whatever is installed, and
/// `Config.default_integration_icons` mirrors it field for field (a
/// unit test holds the two together) so `ui.integration_icons` stays
/// the one place the two user preferences are stored.
pub const FirstParty = struct {
    id: []const u8,
    glyph: []const u8,
    fallback: []const u8,
    /// What Enter on the row — and a click on the chip — runs.
    command: []const u8,
    /// A theme role, or a `#RRGGBB` literal.
    color: []const u8,
    label: []const u8,
    /// The shipped defaults of the two preferences `ui.integration_icons`
    /// persists. Only Browser's chip is on out of the box, as Rust's
    /// is: a first launch stays quiet.
    enabled: bool,
    in_palette_bar: bool,
};

pub const first_party = [_]FirstParty{
    .{ .id = "browser", .glyph = "\u{EB01}", .fallback = "B", .command = "browser.open", .color = "blue", .label = "Browser", .enabled = true, .in_palette_bar = true },
    // Claude's mark is mnml's own baked glyph; the fallback is the idle
    // char a user without the font still sees. Both come from
    // `ui/bufferline.zig`, which is where a mark's codepoint is spelled
    // — this row is the value `allChips` compares against to know the
    // icon is still the shipped figure, so the two cannot be allowed to
    // drift. The colour is Anthropic's brand orange as a literal — no
    // theme role is it — and it comes from `ui/brand.zig`, the one
    // place that spells THAT.
    .{ .id = "claude_code", .glyph = bufferline.claude_glyph, .fallback = bufferline.claude_ascii, .command = "ai.claude_code", .color = @import("../ui/brand.zig").claude_hex, .label = "Claude Code", .enabled = false, .in_palette_bar = false },
    .{ .id = "codex", .glyph = bufferline.codex_glyph, .fallback = "\u{276F}_", .command = "ai.codex", .color = "cyan", .label = "Codex", .enabled = false, .in_palette_bar = false },
    .{ .id = "http", .glyph = "\u{F1D8}", .fallback = "H", .command = "view.activity_http", .color = "teal", .label = "HTTP", .enabled = false, .in_palette_bar = false },
};

/// The manifest chip of an installed integration, by id — what a tab,
/// a rail row or a palette-bar chip paints for it. Null when nothing by
/// that id is installed, or when its manifest declares no chip.
pub fn chipOf(app: *const App, id: []const u8) ?manifest_mod.Chip {
    for (app.integrations.list) |*inst| {
        if (!std.mem.eql(u8, inst.id(), id)) continue;
        return inst.manifest.chip;
    }
    return null;
}

/// The first-party row with `id`, if it is one.
pub fn firstPartyIndex(id: []const u8) ?usize {
    for (first_party, 0..) |fp, i| if (std.mem.eql(u8, fp.id, id)) return i;
    return null;
}

/// The config row for `id` — where a toggle lands. Absent only when a
/// user config replaced `ui.integration_icons` without it.
fn configIcon(app: *const App, id: []const u8) ?config.Config.IntegrationIcon {
    for (app.cfg.ui.integration_icons) |ic| if (std.mem.eql(u8, ic.id, id)) return ic;
    return null;
}

/// A first-party row's live `enabled` / `in_palette_bar`: the config's
/// when it names the id, else the table's default.
pub fn fpEnabled(app: *const App, i: usize) bool {
    return if (configIcon(app, first_party[i].id)) |ic| ic.enabled else first_party[i].enabled;
}

pub fn fpOnBar(app: *const App, i: usize) bool {
    return if (configIcon(app, first_party[i].id)) |ic| ic.in_palette_bar else first_party[i].in_palette_bar;
}

/// An Installed-tab index: the four first-party rows come first, then
/// the scanned manifests. Every consumer of an Installed index decodes
/// through here rather than indexing `State.list` directly.
pub const InstalledRow = union(enum) { first_party: usize, manifest: usize };

pub fn installedRow(v: usize) InstalledRow {
    return if (v < first_party.len) .{ .first_party = v } else .{ .manifest = v - first_party.len };
}

/// The Installed-tab index of manifest `i`.
pub fn manifestVirtual(i: usize) usize {
    return first_party.len + i;
}

/// The Installed tab's row count — what its tab label says.
pub fn installedCount(app: *const App) usize {
    return first_party.len + app.integrations.list.len;
}

/// One manifest as scanned. Everything borrows the snapshot arena.
pub const Installed = struct {
    manifest: Manifest,
    path: []const u8,
    source: Source,
    /// The binary resolves (absolute, `$VAR`, `<data root>/bin/`, or PATH).
    binary_found: bool,
    /// The dyn slots its commands took, in manifest order.
    slots: []u32,

    pub fn enabled(self: *const Installed) bool {
        return if (self.manifest.chip) |c| c.enabled else true;
    }

    pub fn id(self: *const Installed) []const u8 {
        return self.manifest.id;
    }
};

/// One folder of a dev root — or one launcher file lying in a root
/// (`launcher`): a manifest with no binary, so nothing to build and
/// Install is a copy. Borrows `State.dev_snapshot`.
pub const DevEntry = struct {
    /// Absolute: the folder, or the root a launcher file lies in.
    dir: []const u8,
    /// The root it was found under, as the config named it (or `integrations` / `launchers`).
    root: []const u8,
    /// `<dir>/manifest.zon`, or the launcher's own `<root>/<id>.zon`.
    manifest_path: []const u8,
    manifest: Manifest,
    launcher: bool = false,

    pub fn id(self: *const DevEntry) []const u8 {
        return self.manifest.id;
    }

    /// What names the entry to the detail pane and the menus: the
    /// folder, or the launcher's file.
    pub fn key(self: *const DevEntry) []const u8 {
        return if (self.launcher) self.manifest_path else self.dir;
    }
};

/// A palette-bar chip: an installed integration's, or a config icon.
pub const Chip = struct {
    id: []const u8,
    glyph: []const u8,
    fallback: []const u8,
    color: []const u8,
    tooltip: []const u8,
    enabled: bool,
    /// On the palette bar's strip (`chips`), or only pinnable / listed.
    in_palette_bar: bool = true,
    /// What a click runs.
    action: union(enum) { dyn: u32, named: []const u8, none },
    /// The row in `State.list`, for the context menu.
    installed: ?usize,
};

/// A pinned activity-bar icon: the chip an id of
/// `ui.activity_bar_pinned_integrations` names.
pub const Pinned = struct { chip: Chip };

/// The Installed tab's orders. The chip cycles them; the menu lists
/// them through `ListSort` (`name` / `name_desc` / `newest` = enabled
/// first / `oldest` = by category) since a menu row carries a ListSort.
pub const InstalledSort = enum {
    name,
    name_desc,
    enabled_first,
    category,

    pub fn label(s: InstalledSort) []const u8 {
        return switch (s) {
            .name => "A-Z",
            .name_desc => "Z-A",
            .enabled_first => "Enabled",
            .category => "Category",
        };
    }

    pub fn menuLabel(s: InstalledSort) []const u8 {
        return switch (s) {
            .name => "Name (A–Z)",
            .name_desc => "Name (Z–A)",
            .enabled_first => "Enabled first",
            .category => "By category",
        };
    }

    pub fn next(s: InstalledSort) InstalledSort {
        return switch (s) {
            .name => .name_desc,
            .name_desc => .enabled_first,
            .enabled_first => .category,
            .category => .name,
        };
    }

    pub fn toList(s: InstalledSort) ListSort {
        return switch (s) {
            .name => .name,
            .name_desc => .name_desc,
            .enabled_first => .newest,
            .category => .oldest,
        };
    }

    pub fn fromList(l: ListSort) InstalledSort {
        return switch (l) {
            .name => .name,
            .name_desc => .name_desc,
            .newest => .enabled_first,
            .oldest => .category,
        };
    }

    pub const all = [_]InstalledSort{ .name, .name_desc, .enabled_first, .category };

    /// Widest label, in code points — the header chip pads to it.
    pub const widest_label: usize = widestLabel(InstalledSort);
};

/// The Marketplace and Dev tabs' orders (`newest` = by kind, `oldest` = by source).
pub const MarketSort = enum {
    name,
    name_desc,
    kind,
    source,

    pub fn label(s: MarketSort) []const u8 {
        return switch (s) {
            .name => "A-Z",
            .name_desc => "Z-A",
            .kind => "Kind",
            .source => "Source",
        };
    }

    pub fn menuLabel(s: MarketSort) []const u8 {
        return switch (s) {
            .name => "Name (A–Z)",
            .name_desc => "Name (Z–A)",
            .kind => "By kind",
            .source => "By source",
        };
    }

    pub fn next(s: MarketSort) MarketSort {
        return switch (s) {
            .name => .name_desc,
            .name_desc => .kind,
            .kind => .source,
            .source => .name,
        };
    }

    pub fn toList(s: MarketSort) ListSort {
        return switch (s) {
            .name => .name,
            .name_desc => .name_desc,
            .kind => .newest,
            .source => .oldest,
        };
    }

    pub fn fromList(l: ListSort) MarketSort {
        return switch (l) {
            .name => .name,
            .name_desc => .name_desc,
            .newest => .kind,
            .oldest => .source,
        };
    }

    pub const all = [_]MarketSort{ .name, .name_desc, .kind, .source };

    /// Widest label, in code points — the header chip pads to it.
    pub const widest_label: usize = widestLabel(MarketSort);
};

/// The widest `label()` of a sort enum's `all`, in code points. The
/// header's sort chip is right-anchored and pads to it, so a shorter
/// label never slides the chip out from under a repeat-clicking
/// pointer (`ui/chip.zig`).
fn widestLabel(comptime Sort: type) usize {
    comptime {
        var w: usize = 0;
        for (Sort.all) |m| w = @max(w, std.unicode.utf8CountCodepoints(m.label()) catch unreachable);
        return w;
    }
}

/// A Dev install in flight: the task pane running `zig build` and / or
/// `<binary> --install`; `tick` finishes the job when it exits.
pub const DevJob = struct {
    pane: PaneId,
    dir: []u8,
    id: []u8,
    /// The built binary the manifest will name (linked into `<root>/bin/`).
    built: []u8,

    fn deinit(self: *DevJob, gpa: Allocator) void {
        gpa.free(self.dir);
        gpa.free(self.id);
        gpa.free(self.built);
    }
};

pub const State = struct {
    snapshot: alloc.SnapshotArena,
    list: []Installed = &.{},
    /// `<id>.<key>` → value, gpa-owned both sides.
    settings: std.StringHashMapUnmanaged([]u8) = .empty,
    /// The row a context menu was opened on: a tab and an index into
    /// that tab's underlying list.
    menu_row: ?struct { tab: Tab, idx: usize } = null,
    /// The chip a chip / pinned-icon menu was opened on (its id,
    /// gpa-owned): what `integrations.pin_to_activity_bar` and its
    /// twin act on first.
    menu_chip: ?[]u8 = null,
    /// `ui.activity_bar_pinned_integrations` after a pin / unpin: the
    /// config field points here until the next reload.
    pins_owned: ?[][]u8 = null,
    /// // changed (launcher-dock): `ui.dock.pins` after a pin / unpin,
    /// owned the same way `pins_owned` owns the activity bar's.
    dock_pins_owned: ?[][]u8 = null,
    /// `ui.integration_icons` after a first-party row's Enable /
    /// Disable or Show in palette bar: the array AND its strings, so
    /// the config field cannot dangle on the next reload of the file
    /// underneath. The arena is the whole ownership.
    icons_arena: ?std.heap.ArenaAllocator = null,
    scanned: bool = false,
    /// The last scan's problems, one line each (snapshot arena).
    problems: [][]const u8 = &.{},
    /// 0.2 `*.toml` manifests the scan walked past (never read — E2):
    /// the once-per-launch notice and the Installed tab's empty-state
    /// line count them.
    toml_count: usize = 0,
    /// The notice toasted this launch.
    toml_noticed: bool = false,
    generation: u32 = 0,
    /// The statusline segments the manifests set, gpa-owned ids.
    segment_ids: std.ArrayListUnmanaged([]u8) = .empty,

    // The section.
    tab: Tab = .installed,
    /// The filter and the active tab's cursor / scroll; the other tabs'
    /// cursors wait in `tab_cursor`.
    panel: Panel.State = .{},
    tab_cursor: [3]usize = .{ 0, 0, 0 },
    tab_scroll: [3]usize = .{ 0, 0, 0 },
    installed_sort: InstalledSort = .name,
    market_sort: MarketSort = .name,
    /// `integrations.toggle_dev_tab`'s answer for the session; null
    /// defers to the config and the roots.
    show_dev_override: ?bool = null,
    last_click: ?struct { tab: Tab, idx: usize, at_ms: i64 } = null,

    // The Dev tab.
    dev_snapshot: alloc.SnapshotArena,
    dev: []DevEntry = &.{},
    dev_problems: [][]const u8 = &.{},
    dev_scanned: bool = false,
    job: ?DevJob = null,

    pub fn init(gpa: Allocator) State {
        return .{ .snapshot = .init(gpa), .dev_snapshot = .init(gpa) };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        var it = self.settings.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.settings.deinit(gpa);
        for (self.segment_ids.items) |s| gpa.free(s);
        self.segment_ids.deinit(gpa);
        if (self.menu_chip) |c| gpa.free(c);
        if (self.icons_arena) |*a| a.deinit();
        self.freePins(gpa);
        self.panel.deinit(gpa);
        if (self.job) |*j| j.deinit(gpa);
        self.dev_snapshot.deinit();
        self.snapshot.deinit();
    }

    pub fn find(self: *const State, id: []const u8) ?usize {
        for (self.list, 0..) |*i, idx| if (std.mem.eql(u8, i.id(), id)) return idx;
        return null;
    }

    fn freePins(self: *State, gpa: Allocator) void {
        if (self.pins_owned) |owned| {
            for (owned) |p| gpa.free(p);
            gpa.free(owned);
            self.pins_owned = null;
        }
        self.freeDockPins(gpa);
    }

    fn freeDockPins(self: *State, gpa: Allocator) void {
        const owned = self.dock_pins_owned orelse return;
        for (owned) |p| gpa.free(p);
        gpa.free(owned);
        self.dock_pins_owned = null;
    }

    fn setMenuChip(self: *State, gpa: Allocator, id: ?[]const u8) Allocator.Error!void {
        if (self.menu_chip) |c| gpa.free(c);
        self.menu_chip = if (id) |i| try gpa.dupe(u8, i) else null;
    }

    pub fn findDev(self: *const State, key: []const u8) ?usize {
        for (self.dev, 0..) |*d, idx| if (std.mem.eql(u8, d.key(), key)) return idx;
        return null;
    }
};

/// `Pane.integrations`: the detail pane for one entry.
pub const IntegrationsPane = struct {
    target: Target,
    /// The focused action button.
    cursor: usize = 0,

    pub const Target = union(enum) {
        /// A manifest id.
        installed: []u8,
        /// A marketplace entry id.
        marketplace: []u8,
        /// A dev folder (absolute), or a launcher file in a dev root.
        dev: []u8,

        fn key(self: Target) []const u8 {
            return switch (self) {
                inline else => |s| s,
            };
        }
    };

    /// `openDetail`'s argument: the same shape, borrowed.
    pub const TargetRef = union(enum) {
        installed: []const u8,
        marketplace: []const u8,
        dev: []const u8,

        fn key(self: TargetRef) []const u8 {
            return switch (self) {
                inline else => |s| s,
            };
        }
    };

    pub fn deinit(self: *IntegrationsPane, gpa: Allocator) void {
        gpa.free(self.target.key());
    }

    pub fn title(self: *const IntegrationsPane) []const u8 {
        return switch (self.target) {
            .dev => |d| std.fs.path.basename(d),
            inline else => |s| s,
        };
    }
};

pub const table = .{
    .@"integrations.refresh" = &refreshCmd,
    .@"integrations.retry_refresh" = &@import("mount_pane.zig").retryRefresh,
    .@"integrations.poll_now" = &integration_poll.pollNow,
    .@"integrations.refresh_binary_cache" = &refreshCmd,
    .@"integrations.dismiss_toml_notice" = &dismissTomlNotice,
    .@"integrations.show_installed" = &showInstalled,
    .@"view.activity_integrations" = &showInstalled,
    .@"integrations.show_marketplace" = &showMarketplace,
    .@"integrations.update" = &updateCmd,
    .@"integrations.show_in_dev" = &showDevCmd,
    .@"integrations.toggle_dev_tab" = &toggleDevTab,
    .@"integrations.toggle_tab" = &toggleTab,
    .@"integrations.show_details" = &showDetails,
    .@"integrations.show_manifest" = &showManifest,
    .@"integrations.edit" = &editCmd,
    .@"integrations.toggle_enabled" = &toggleEnabled,
    .@"integrations.remove" = &removeCmd,
    .@"integrations.copy_id" = &copyId,
    .@"integrations.cycle_sort" = &cycleSort,
    .@"integrations.dev_build" = &devBuildCmd,
    .@"integrations.dev_install" = &devInstallCmd,
    .@"integrations.dev_rebuild" = &devRebuildCmd,
    .@"integrations.pin_to_activity_bar" = &pinCmd,
    .@"integrations.unpin_from_activity_bar" = &unpinCmd,
    .@"integrations.pin_to_dock" = &pinDockCmd,
    .@"integrations.unpin_from_dock" = &unpinDockCmd,
    .@"integrations.toggle_palette_bar" = &togglePaletteBar,
    .@"integrations.open_as_split" = &openAsSplitCmd,
    .@"integrations.open_as_tab" = &openAsTabCmd,
};

// ─── discovery ──────────────────────────────────────────────────────────

/// The `.startup` hook: the first scan.
pub fn onStartup(app: *App, _: @import("../core/hooks.zig").HookArgs) void {
    refresh(app) catch {};
}

/// Where manifests live, in precedence order (workspace after home so
/// a workspace manifest with the same id wins).
fn dirs(app: *App, arena: Allocator) Allocator.Error![2]?[]const u8 {
    const home: ?[]const u8 = if (app.data_root.len > 0) try std.fs.path.join(arena, &.{ app.data_root, manifest_mod.subdir }) else null;
    const ws = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", manifest_mod.subdir });
    return .{ home, ws };
}

/// Re-scan: drop every integration command, binding and segment, read
/// the manifests again, register what they declare.
pub fn refresh(app: *App) Allocator.Error!void {
    const st = &app.integrations;
    // Old bindings go before the arena they point into.
    for (st.list) |*inst| for (inst.manifest.commands) |c| for (c.keys) |k| app.keymap.unbind(k);
    _ = app.dyn_commands.unregisterOwner(.integration);
    clearSegments(app);
    st.snapshot.reset();
    const arena = st.snapshot.allocator();
    st.list = &.{};
    st.problems = &.{};
    st.toml_count = 0;
    st.generation +%= 1;

    var found: std.ArrayListUnmanaged(Installed) = .empty;
    var problems: std.ArrayListUnmanaged([]const u8) = .empty;
    const roots = try dirs(app, arena);
    for (roots, 0..) |maybe, i| {
        const dir_path = maybe orelse continue;
        const source: Source = if (i == 0) .home else .workspace;
        // A workspace's manifests spawn binaries: they wait for trust
        // (`config/trust.zig`, the `workspace_manifests` sink). Quiet,
        // like every other stripped sink — the RESTRICTED chip says so.
        if (source == .workspace and !app.workspace_trusted) continue;
        try scanDir(app, arena, dir_path, source, &found, &problems);
    }
    std.mem.sort(Installed, found.items, {}, byLabel);
    st.list = try found.toOwnedSlice(arena);
    st.problems = try problems.toOwnedSlice(arena);
    st.scanned = true;

    // Register the commands now that the list is final.
    for (st.list) |*inst| try registerCommands(app, arena, inst);
    try app.keymap.rebuildPrefixes();
    try setSegments(app);
    // The schedule follows the manifests: an install, an uninstall or a
    // disable changes what the poller runs without a restart.
    try integration_poll.restart(app);
    for (st.problems) |p| try app.toastLevel(.warn, "integrations: {s}", .{p});
    try noticeToml(app);
    if (st.panel.cursor >= st.list.len) st.panel.cursor = st.list.len -| 1;
    app.needs_render = true;
}

/// The id of the 0.2-manifests notice toast: its right-click menu
/// carries *Don't show again* (`integrations.dismiss_toml_notice`).
pub const toml_toast_id = "integrations-toml";

/// `N integrations from mnml 0.2 are not loaded — …`: the one thing
/// said about the `.toml` manifests, which are never read (E2).
pub fn tomlNoticeText(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    const n = app.integrations.toml_count;
    return std.fmt.allocPrint(arena, "{d} integration{s} from mnml 0.2 {s} not loaded — 0.3 integrations install from the Marketplace", .{ n, if (n == 1) "" else "s", if (n == 1) "is" else "are" });
}

/// Whether the Installed tab's empty state and the toast mention the
/// 0.2 manifests: some were found and the user has not said no.
fn tomlNoticeDue(app: *App) bool {
    return app.integrations.toml_count > 0 and !app.cfg.ui.integrations_toml_notice_shown;
}

/// The first scan of a launch that walks past 0.2 manifests toasts the
/// count once (walkthrough 1.1: a data root full of them read
/// `Inst (0)` and said nothing). The files are never deleted or
/// renamed; the toast's menu offers *Don't show again*.
fn noticeToml(app: *App) Allocator.Error!void {
    const st = &app.integrations;
    if (!tomlNoticeDue(app) or st.toml_noticed) return;
    st.toml_noticed = true;
    app.toastReplaceLevel(toml_toast_id, .warn, "{s}", .{try tomlNoticeText(app, app.frame.allocator())});
    // // changed (bottom-row): the message says where 0.3 integrations
    // come from, so it carries the way there. The Marketplace tab, not
    // an install: the description, version and source are readable
    // before anything is fetched.
    app.attachToastAction(toml_toast_id, .{ .marketplace = .{
        .label = try app.gpa.dupe(u8, "Marketplace"),
        .id = try app.gpa.dupe(u8, ""),
    } });
}

/// `integrations.dismiss_toml_notice`: *Don't show again* —
/// `ui.integrations_toml_notice_shown = true` in the home config, the
/// toast and the empty-state line gone.
fn dismissTomlNotice(app: *App) CommandError!void {
    app.cfg.ui.integrations_toml_notice_shown = true;
    _ = try settings.persist(app, .home, &.{ "ui", "integrations_toml_notice_shown" }, true);
    app.dismissToast(toml_toast_id);
    app.toast("the mnml 0.2 manifests will not be mentioned again (ui.integrations_toml_notice_shown)", .{});
}

fn byLabel(_: void, a: Installed, b: Installed) bool {
    return std.ascii.lessThanIgnoreCase(a.manifest.label, b.manifest.label);
}

fn scanDir(app: *App, arena: Allocator, dir_path: []const u8, source: Source, found: *std.ArrayListUnmanaged(Installed), problems: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    const io = app.io;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        // A 0.2 manifest: counted for the notice, never opened.
        if (std.mem.endsWith(u8, entry.name, ".toml")) {
            app.integrations.toml_count += 1;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        const m = readManifest(app, arena, dir, entry.name, path, problems) orelse continue;
        // A workspace manifest replaces a home one with the same id.
        var replaced = false;
        // A launcher has no binary to find; its lines check their own
        // program when they fire.
        const have = m.isLauncher() or binaryFound(app, arena, m.binary);
        for (found.items) |*prev| if (std.mem.eql(u8, prev.id(), m.id)) {
            prev.* = .{ .manifest = m, .path = path, .source = source, .binary_found = have, .slots = &.{} };
            replaced = true;
        };
        if (replaced) continue;
        try found.append(arena, .{ .manifest = m, .path = path, .source = source, .binary_found = have, .slots = &.{} });
    }
}

/// `<dir>/<name>` parsed as a manifest, or null with the reason in
/// `problems`.
fn readManifest(app: *App, arena: Allocator, dir: Io.Dir, name: []const u8, path: []const u8, problems: *std.ArrayListUnmanaged([]const u8)) ?Manifest {
    const text = dir.readFileAllocOptions(app.io, name, arena, .limited(1 << 20), .of(u8), 0) catch |err| {
        problems.append(arena, std.fmt.allocPrint(arena, "{s}: {s}", .{ path, @errorName(err) }) catch return null) catch {};
        return null;
    };
    var why: []const u8 = "";
    return manifest_mod.parse(arena, text, &why) catch |err| switch (err) {
        error.OutOfMemory => null,
        error.BadManifest => {
            problems.append(arena, std.fmt.allocPrint(arena, "{s}: {s}", .{ app.relPath(path), why }) catch return null) catch {};
            return null;
        },
    };
}

/// The glyph a manifest chip paints: `chip.glyph`, else its pinned
/// `glyph_codepoint` decoded onto `arena`, else nothing.
pub fn chipGlyph(arena: Allocator, chip: ?manifest_mod.Chip) Allocator.Error![]const u8 {
    const c = chip orelse return "";
    if (c.glyph.len > 0) return c.glyph;
    var buf: [4]u8 = undefined;
    const g = c.glyphText(&buf);
    if (g.len == 0) return "";
    return try arena.dupe(u8, g);
}

/// A `mnml`-source row's state, read off what is installed: a
/// catalogue entry is one BINARY, so it counts as installed when any
/// manifest naming that binary is, and as an update when one of those
/// manifests is older than the catalogue's version.
///
/// The two sides are matched on the binary's FILE NAME, `$VAR`
/// expanded: a catalogue may point at `$MNML_SAMPLE_INTEGRATION` or an
/// absolute path while the manifest `--install` wrote names the bare
/// `mnml-sample`, and those are the same program.
pub fn catalogueState(app: *App, arena: Allocator, binary: []const u8, version: []const u8) Allocator.Error!catalogue.State {
    const want = std.fs.path.basename(try expandEnv(app, arena, binary));
    var state: catalogue.State = .not_installed;
    for (app.integrations.list) |*inst| {
        const have = std.fs.path.basename(try expandEnv(app, arena, inst.manifest.binary));
        if (!std.mem.eql(u8, have, want)) continue;
        if (catalogue.olderThan(inst.manifest.version, version)) return .update;
        state = .installed;
    }
    return state;
}

/// Whether any manifest OTHER than `except` still names `binary` —
/// what decides whether an uninstall may take the link with it.
fn binaryStillUsed(app: *App, binary: []const u8, except: []const u8) bool {
    for (app.integrations.list) |*inst| {
        if (std.mem.eql(u8, inst.id(), except)) continue;
        if (std.mem.eql(u8, inst.manifest.binary, binary)) return true;
    }
    return false;
}

/// Absolute → exists; bare → somewhere on PATH.
pub fn binaryFound(app: *App, arena: Allocator, binary: []const u8) bool {
    return resolveBinary(app, arena, binary) != null;
}

/// `$NAME` or `$NAME/rest` with the variable's value in place, else
/// `binary` as given. How a manifest reaches a binary the environment
/// names (`$MNML_SAMPLE_INTEGRATION` in the corpus).
pub fn expandEnv(app: *App, arena: Allocator, binary: []const u8) Allocator.Error![]const u8 {
    if (binary.len < 2 or binary[0] != '$') return binary;
    const end = std.mem.indexOfScalar(u8, binary, '/') orelse binary.len;
    const value = app.env.get(binary[1..end]) orelse return binary;
    if (value.len == 0) return binary;
    if (end == binary.len) return value;
    return std.mem.concat(arena, u8, &.{ value, binary[end..] });
}

/// Where a manifest's binary is: itself when absolute (or `$VAR`),
/// else `<data root>/bin/<name>` (what an install links), else the
/// first PATH hit. Null when nowhere.
pub fn resolveBinary(app: *App, arena: Allocator, binary_in: []const u8) ?[]const u8 {
    const io = app.io;
    const binary = expandEnv(app, arena, binary_in) catch return null;
    if (std.fs.path.isAbsolute(binary) or std.mem.indexOfScalar(u8, binary, '/') != null) {
        Io.Dir.cwd().access(io, binary, .{}) catch return null;
        return binary;
    }
    if (app.data_root.len > 0) {
        const linked = std.fs.path.join(arena, &.{ app.data_root, "bin", binary }) catch return null;
        if (Io.Dir.cwd().access(io, linked, .{})) |_| return linked else |_| {}
    }
    const path_var = app.env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(arena, &.{ dir, binary }) catch return null;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return full;
    }
    return null;
}

fn registerCommands(app: *App, arena: Allocator, inst: *Installed) Allocator.Error!void {
    const m = inst.manifest;
    const slots = try arena.alloc(u32, m.commands.len);
    var n: usize = 0;
    for (m.commands) |c| {
        const args = try std.mem.concat(arena, []const u8, &.{ m.args, c.args });
        // A `run` / `ex` line runs through `launchers.fire` (its tokens
        // expanded); anything else opens the binary.
        const runner: command.DynInit.Runner = if (c.line()) |line|
            .{ .ex = line }
        else
            .{ .mount = .{ .binary = m.binary, .args = args, .pty = m.mode == .pty, .label = m.label } };
        const slot = app.dyn_commands.register(.{
            .id = c.id,
            .title = c.title,
            .group = c.group,
            .keys = c.keys,
            .runner = runner,
            .owner = .{ .integration = m.id },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ShadowsBuiltin => {
                try app.toastLevel(.warn, "integrations: {s}: {s} shadows a built-in command", .{ m.id, c.id });
                continue;
            },
        };
        slots[n] = slot;
        n += 1;
        for (c.keys) |k| try app.keymap.bind(k, c.id);
    }
    inst.slots = slots[0..n];
}

fn refreshCmd(app: *App) CommandError!void {
    try refresh(app);
    if (app.integrations.dev_scanned) try scanDev(app);
    app.toast("integrations: {d} installed", .{app.integrations.list.len});
}

// ─── statusline segments ────────────────────────────────────────────────

/// Every enabled, runnable manifest's `statusline[]` entries become
/// segments keyed `<id>.<segment id>`; a refresh replaces the set.
fn setSegments(app: *App) Allocator.Error!void {
    const st = &app.integrations;
    const gpa = app.gpa;
    for (st.list) |*inst| {
        if (!inst.enabled() or !inst.binary_found) continue;
        for (inst.manifest.statusline) |seg| {
            const id = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ inst.id(), seg.id });
            errdefer gpa.free(id);
            try app.ipc_fx.setSegment(gpa, .{
                .id = id,
                .side = switch (seg.side) {
                    .left => .left,
                    .right => .right,
                },
                .text = seg.text,
                .color = seg.color,
                .click_command = seg.click_command,
                .priority = seg.priority,
                .tooltip = seg.tooltip,
            });
            try st.segment_ids.append(gpa, id);
        }
    }
}

fn clearSegments(app: *App) void {
    const st = &app.integrations;
    for (st.segment_ids.items) |id| {
        _ = app.ipc_fx.clearSegment(app.gpa, id);
        app.gpa.free(id);
    }
    st.segment_ids.clearRetainingCapacity();
}

// ─── the dev roots ──────────────────────────────────────────────────────

/// The roots the Dev tab scans: `integrations.dev_roots` (relative to
/// the workspace, `~` expanded), then the workspace's own
/// `integrations/` when it is an SDK checkout (`sdk/mnml-sdk` exists).
pub fn devRoots(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (app.cfg.integrations.dev_roots) |r| {
        const expanded = try app.expandTilde(r);
        const abs = if (std.fs.path.isAbsolute(expanded)) expanded else try std.fs.path.join(arena, &.{ app.workspace, expanded });
        try out.append(arena, abs);
    }
    const sdk = try std.fs.path.join(arena, &.{ app.workspace, "sdk", "mnml-sdk" });
    if (isDir(app.io, sdk)) {
        // …and its `launchers/`, the manifests with no binary.
        for ([_][]const u8{ "integrations", "launchers" }) |name| {
            const own = try std.fs.path.join(arena, &.{ app.workspace, name });
            var seen = false;
            for (out.items) |r| if (std.mem.eql(u8, r, own)) {
                seen = true;
            };
            if (!seen) try out.append(arena, own);
        }
    }
    return out.toOwnedSlice(arena);
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file or st.kind == .sym_link;
}

/// Scan the dev roots: every folder with a `build.zig` and a
/// `manifest.zon` is an entry, and so is every launcher `*.zon` lying
/// in a root; sorted by label.
pub fn scanDev(app: *App) Allocator.Error!void {
    const st = &app.integrations;
    st.dev_snapshot.reset();
    const arena = st.dev_snapshot.allocator();
    st.dev = &.{};
    st.dev_problems = &.{};
    var found: std.ArrayListUnmanaged(DevEntry) = .empty;
    var problems: std.ArrayListUnmanaged([]const u8) = .empty;
    const roots = try devRoots(app, arena);
    for (roots) |root| {
        var dir = Io.Dir.cwd().openDir(app.io, root, .{ .iterate = true }) catch {
            try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: not a directory", .{app.relPath(root)}));
            continue;
        };
        defer dir.close(app.io);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if ((entry.kind == .file or entry.kind == .sym_link) and std.mem.endsWith(u8, entry.name, ".zon")) {
                const file_path = try std.fs.path.join(arena, &.{ root, entry.name });
                const m = readManifest(app, arena, dir, entry.name, file_path, &problems) orelse continue;
                if (!m.isLauncher()) {
                    try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: names a binary — a bare manifest in a dev root is a launcher; a binary lives in a folder with its build.zig", .{app.relPath(file_path)}));
                    continue;
                }
                try found.append(arena, .{ .dir = root, .root = std.fs.path.basename(root), .manifest_path = file_path, .manifest = m, .launcher = true });
                continue;
            }
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            const sub = try std.fs.path.join(arena, &.{ root, entry.name });
            const build_path = try std.fs.path.join(arena, &.{ sub, "build.zig" });
            const manifest_path = try std.fs.path.join(arena, &.{ sub, "manifest.zon" });
            if (!isFile(app.io, build_path) or !isFile(app.io, manifest_path)) continue;
            var subdir = Io.Dir.cwd().openDir(app.io, sub, .{}) catch continue;
            defer subdir.close(app.io);
            const m = readManifest(app, arena, subdir, "manifest.zon", manifest_path, &problems) orelse continue;
            try found.append(arena, .{ .dir = sub, .root = std.fs.path.basename(root), .manifest_path = manifest_path, .manifest = m });
        }
    }
    const Ctx = struct {
        fn lt(_: void, a: DevEntry, b: DevEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.manifest.label, b.manifest.label);
        }
    };
    std.mem.sort(DevEntry, found.items, {}, Ctx.lt);
    st.dev = try found.toOwnedSlice(arena);
    st.dev_problems = try problems.toOwnedSlice(arena);
    st.dev_scanned = true;
    for (st.dev_problems) |p| try app.toastLevel(.warn, "integrations: dev: {s}", .{p});
    app.needs_render = true;
}

/// Whether the Dev tab shows: the session's toggle, else the config,
/// else whenever there is a root to scan.
pub fn showDev(app: *App) bool {
    const st = &app.integrations;
    if (st.show_dev_override) |o| return o;
    if (app.cfg.marketplace.show_dev_tab) return true;
    if (app.cfg.integrations.dev_roots.len > 0) return true;
    return st.dev.len > 0;
}

/// The binary a dev folder's build leaves: the manifest's binary when
/// it is absolute or `$VAR` (already somewhere), else
/// `<dir>/zig-out/bin/<binary>`.
pub fn devBuiltBinary(app: *App, arena: Allocator, d: *const DevEntry) Allocator.Error![]const u8 {
    const b = try expandEnv(app, arena, d.manifest.binary);
    if (std.fs.path.isAbsolute(b) or std.mem.indexOfScalar(u8, b, '/') != null) return b;
    const name = if (builtin.os.tag == .windows) try std.fmt.allocPrint(arena, "{s}.exe", .{b}) else b;
    return std.fs.path.join(arena, &.{ d.dir, "zig-out", "bin", name });
}

fn devEntryAt(app: *App, idx: usize) CommandError!*DevEntry {
    const st = &app.integrations;
    if (idx >= st.dev.len) return app.diag.fail(app.frame.allocator(), "integrations: no dev entry there", .{});
    return &st.dev[idx];
}

/// `integrations.dev_build`: `zig build` in the folder, as a task pane.
pub fn devBuild(app: *App, idx: usize) CommandError!void {
    const d = try devEntryAt(app, idx);
    if (d.launcher) return app.diag.fail(app.frame.allocator(), "integrations: {s} is a launcher — nothing to build; Install copies the manifest", .{d.id()});
    if (!pty_pane.supported) return app.diag.fail(app.frame.allocator(), "integrations: a task pane is not available on this platform", .{});
    if (!runners.onPath(app, "zig")) return app.diag.fail(app.frame.allocator(), "integrations: zig is not on PATH", .{});
    const label = try std.fmt.allocPrint(app.frame.allocator(), "{s}: zig build", .{d.id()});
    _ = try runners.spawn(app, label, "zig build", d.dir, .task);
    app.toast("integrations: building {s} in {s}", .{ d.id(), app.relPath(d.dir) });
}

/// `integrations.dev_install` / `dev_rebuild`: build when nothing is
/// built (or always, with `rebuild`), then `<binary> --install`, in a
/// task pane; `tick` links the binary and rescans once it exits.
pub fn devInstall(app: *App, idx: usize, rebuild: bool) CommandError!void {
    const st = &app.integrations;
    const arena = app.frame.allocator();
    const d = try devEntryAt(app, idx);
    // A launcher: the file is the whole install.
    if (d.launcher) return launchers.installFile(app, d.manifest_path);
    if (st.job != null) return app.diag.fail(arena, "integrations: an install is already running", .{});
    if (!pty_pane.supported) return app.diag.fail(arena, "integrations: a task pane is not available on this platform", .{});
    if (app.data_root.len == 0) return app.diag.fail(arena, "integrations: no data root to install into", .{});
    const built = try devBuiltBinary(app, arena, d);
    const have = isFile(app.io, built);
    const build_first = rebuild or !have;
    if (build_first and !runners.onPath(app, "zig")) return app.diag.fail(arena, "integrations: zig is not on PATH", .{});
    // The data root travels as the environment the shell hands the
    // binary — `sh -c` takes the assignment in front, `cmd` a `set`.
    const install_line = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(arena, "set \"MNML_DATA_ROOT={s}\" && \"{s}\" --install", .{ app.data_root, built })
    else
        try std.fmt.allocPrint(arena, "MNML_DATA_ROOT='{s}' '{s}' --install", .{ app.data_root, built });
    const cmdline = if (build_first) try std.fmt.allocPrint(arena, "zig build && {s}", .{install_line}) else install_line;
    const label = try std.fmt.allocPrint(arena, "{s}: {s}", .{ d.id(), if (build_first) "build + install" else "install" });
    const pane = try runners.spawn(app, label, cmdline, d.dir, .task);
    const gpa = app.gpa;
    var job: DevJob = .{ .pane = pane, .dir = try gpa.dupe(u8, d.dir), .id = &.{}, .built = &.{} };
    errdefer job.deinit(gpa);
    job.id = try gpa.dupe(u8, d.id());
    job.built = try gpa.dupe(u8, built);
    st.job = job;
    app.toast("integrations: installing {s} from {s}…", .{ d.id(), app.relPath(d.dir) });
}

/// From `App.tick`: a dev install's task pane has exited — link the
/// binary and rescan on success, say why on failure.
pub fn tick(app: *App) Allocator.Error!void {
    const st = &app.integrations;
    const job = if (st.job) |*j| j else return;
    const p = app.panes.get(job.pane) orelse {
        finishJob(app, "its pane was closed");
        return;
    };
    const exit = switch (p.*) {
        .pty => |*t| t.exit orelse return,
        else => {
            finishJob(app, "its pane was closed");
            return;
        },
    };
    const ok = switch (exit) {
        .code => |c| c == 0,
        .signal => false,
    };
    if (!ok) {
        const why: []const u8 = switch (exit) {
            .code => |c| try std.fmt.allocPrint(app.frame.allocator(), "exit code {d}", .{c}),
            .signal => "killed",
        };
        finishJob(app, why);
        return;
    }
    // Reachable by its bare name: `<root>/bin` is on `runMount`'s path.
    const arena = app.frame.allocator();
    const link_dir = try std.fs.path.join(arena, &.{ app.data_root, "bin" });
    Io.Dir.cwd().createDirPath(app.io, link_dir) catch {};
    const link = try std.fs.path.join(arena, &.{ link_dir, std.fs.path.basename(job.built) });
    Io.Dir.cwd().deleteFile(app.io, link) catch {};
    Io.Dir.cwd().symLink(app.io, job.built, link, .{}) catch {
        // No symlinks (Windows without the privilege): a copy does.
        Io.Dir.cwd().copyFile(job.built, Io.Dir.cwd(), link, app.io, .{}) catch {};
    };
    const id = try arena.dupe(u8, job.id);
    const dir = try arena.dupe(u8, job.dir);
    job.deinit(app.gpa);
    st.job = null;
    try refresh(app);
    if (st.dev_scanned) try scanDev(app);
    app.toast("integrations: installed {s} from {s}", .{ id, app.relPath(dir) });
}

fn finishJob(app: *App, why: []const u8) void {
    const st = &app.integrations;
    var job = st.job orelse return;
    app.toast("integrations: install of {s} failed: {s}", .{ job.id, why });
    job.deinit(app.gpa);
    st.job = null;
    app.needs_render = true;
}

fn devBuildCmd(app: *App) CommandError!void {
    return devBuild(app, try focusedDev(app));
}

fn devInstallCmd(app: *App) CommandError!void {
    return devInstall(app, try focusedDev(app), false);
}

fn devRebuildCmd(app: *App) CommandError!void {
    return devInstall(app, try focusedDev(app), true);
}

/// The dev entry a command acts on: the menu's row, the active detail
/// pane's, else the section's cursor on the Dev tab.
fn focusedDev(app: *App) CommandError!usize {
    const st = &app.integrations;
    if (st.menu_row) |r| {
        st.menu_row = null;
        if (r.tab == .dev and r.idx < st.dev.len) return r.idx;
    }
    if (activeDetail(app)) |ap| if (ap.p.target == .dev) if (st.findDev(ap.p.target.dev)) |i| return i;
    if (!st.dev_scanned) try scanDev(app);
    if (st.tab == .dev) if (try cursorEntry(app)) |i| return i;
    return app.diag.fail(app.frame.allocator(), "integrations: open the Dev tab and pick a folder first", .{});
}

// ─── running ────────────────────────────────────────────────────────────

/// What `runMount` opens. Borrowed for the call.
pub const Run = struct {
    /// The manifest id (its settings reach the child), or empty.
    id: []const u8 = "",
    binary: []const u8,
    args: []const []const u8 = &.{},
    pty: bool = false,
    label: []const u8,
    /// // changed (focus-row): how many of `args` at the end are a deep
    /// link rather than part of what this command IS. A pane is known
    /// by the rest, so `--focus ENG-2` and `--focus ENG-5` reach the
    /// same pane instead of opening two.
    deep_link: usize = 0,
    /// The one thing the pane should land on, when the press named one
    /// — forwarded down the mount if that pane is already open.
    focus: []const u8 = "",
};

/// `Open as ▸ Split / Tab` — the row every integration menu carries,
/// with the mode in force ticked.
/// // changed (integration-split).
/// The open menu keeps a POINTER to a row's `submenu`, so these two
/// rows cannot be a temporary of the function that built them; they are
/// the same two every time, only the tick moves. One menu is open at a
/// time and `openMenu` frees the previous one first.
var open_as_kids: [2]command.MenuItem = undefined;

pub fn openAsRow(app: *const App) command.MenuItem {
    const cur = app.cfg.integrations.open_as;
    open_as_kids = .{
        .{ .label = "Split (beside the active pane)", .action = .{ .command = .@"integrations.open_as_split" }, .checked = cur == .split },
        .{ .label = "Tab (in the active leaf)", .action = .{ .command = .@"integrations.open_as_tab" }, .checked = cur == .tab },
    };
    return .{ .label = "Open as", .action = .none, .separator_before = true, .submenu = &open_as_kids };
}

fn setOpenAs(app: *App, v: config.Config.IntegrationOpenAs) CommandError!void {
    app.cfg.integrations.open_as = v;
    _ = try settings.persist(app, .home, &.{ "integrations", "open_as" }, v);
    app.toast("integrations open as: {s}", .{@tagName(v)});
    app.needs_render = true;
}

fn openAsSplitCmd(app: *App) CommandError!void {
    return setOpenAs(app, .split);
}

fn openAsTabCmd(app: *App) CommandError!void {
    return setOpenAs(app, .tab);
}

/// A manifest command's runner: the binary as a mount (or a pty).
pub fn runMount(app: *App, r: Run) CommandError!void {
    const arena = app.frame.allocator();
    const id = r.id;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, resolveBinary(app, arena, r.binary) orelse r.binary);
    for (r.args) |a| try argv.append(arena, a);
    if (r.pty) {
        if (!pty_pane.supported) return app.diag.fail(arena, "{s}: a pty pane is not available on this platform", .{r.label});
        _ = try pty_pane.open(app, .{ .argv = argv.items, .label = r.label, .placement = .tab, .kind = .command });
        return;
    }
    const extra = try settingsEnv(app, arena, id);
    // The deep link rides on the argv but is not part of the pane's
    // identity: `findOpen` matches on what is left when it is cut off.
    const identity = argv.items[0 .. argv.items.len - @min(r.deep_link, argv.items.len - 1)];
    _ = try mount_pane.open(app, .{
        .argv = argv.items,
        .identity = identity,
        .focus = r.focus,
        .label = r.label,
        .integration = id,
        .extra_env = extra,
    });
}

/// `MNML_SETTING_<KEY>` for every setting the manifest declares: the
/// stored choice, else the manifest's default.
fn settingsEnv(app: *App, arena: Allocator, id: []const u8) Allocator.Error![]mount_pane.EnvPair {
    const st = &app.integrations;
    const idx = st.find(id) orelse return &.{};
    const m = st.list[idx].manifest;
    var out: std.ArrayListUnmanaged(mount_pane.EnvPair) = .empty;
    for (m.settings) |s| {
        const value = settingValue(app, id, s);
        const name = try std.fmt.allocPrint(arena, "MNML_SETTING_{s}", .{s.key});
        for (name["MNML_SETTING_".len..]) |*c| c.* = std.ascii.toUpper(c.*);
        try out.append(arena, .{ .name = name, .value = value });
    }
    return out.toOwnedSlice(arena);
}

/// Run the integration's first command (what the chip and Enter do).
/// Enter (or a second click) on an Installed row: a first-party row
/// runs its command, a manifest its first command — or, when it
/// declares none, the binary itself.
fn openRow(app: *App, virtual: usize) CommandError!void {
    const st = &app.integrations;
    const idx = switch (installedRow(virtual)) {
        .first_party => |i| return command.runNamed(app, first_party[i].command),
        .manifest => |i| i,
    };
    if (idx >= st.list.len) return;
    const inst = &st.list[idx];
    if (inst.slots.len == 0) {
        // No manifest command: open the binary itself.
        return runMount(app, .{ .id = inst.id(), .binary = inst.manifest.binary, .args = inst.manifest.args, .pty = inst.manifest.mode == .pty, .label = inst.manifest.label });
    }
    return command.run(app, .{ .dyn = inst.slots[0] });
}

// ─── chips ──────────────────────────────────────────────────────────────

/// Every chip there is — config icons and installed manifests with a
/// chip, on the bar or not — in `ui.integration_icon_order` first,
/// then by id. `chips` is the strip's subset.
pub fn allChips(app: *App, arena: Allocator) Allocator.Error![]Chip {
    var out: std.ArrayListUnmanaged(Chip) = .empty;
    for (app.cfg.ui.integration_icons) |icon| {
        if (icon.id.len == 0) continue;
        // The Claude row's mark is `ui.claude_mark`'s to say wherever
        // this chip paints — the launcher dock, the palette bar — so it
        // matches the tab bar's cluster. A user who typed a glyph of
        // their own on the row keeps it: only the shipped figure is
        // swapped (`app/claude_mark.zig`).
        const branded = std.mem.eql(u8, icon.id, "claude_code") and std.mem.eql(u8, icon.glyph, bufferline.claude_glyph);
        const m = claude_mark.mark(app);
        try out.append(arena, .{
            .id = icon.id,
            .glyph = if (branded) m.glyph else icon.glyph,
            .fallback = if (branded) m.fallback else icon.fallback,
            .color = icon.color,
            .tooltip = icon.label orelse icon.id,
            .enabled = icon.enabled,
            .in_palette_bar = icon.in_palette_bar,
            .action = if (icon.command.len > 0) .{ .named = icon.command } else .none,
            .installed = null,
        });
    }
    for (app.integrations.list, 0..) |*inst, i| {
        const c = inst.manifest.chip orelse continue;
        try out.append(arena, .{
            .id = inst.id(),
            .glyph = try chipGlyph(arena, c),
            .fallback = c.fallback,
            .color = c.color,
            .tooltip = if (c.tooltip.len > 0) c.tooltip else inst.manifest.label,
            .enabled = c.enabled and inst.binary_found,
            .in_palette_bar = c.in_palette_bar,
            .action = if (inst.slots.len > 0) .{ .dyn = inst.slots[0] } else .none,
            .installed = i,
        });
    }
    const icon_order = app.cfg.ui.integration_icon_order;
    const Ctx = struct {
        order: []const []const u8,
        fn rank(self: @This(), id: []const u8) usize {
            for (self.order, 0..) |o, i| if (std.mem.eql(u8, o, id)) return i;
            return self.order.len;
        }
        fn less(self: @This(), a: Chip, b: Chip) bool {
            const ra = self.rank(a.id);
            const rb = self.rank(b.id);
            if (ra != rb) return ra < rb;
            return std.ascii.lessThanIgnoreCase(a.id, b.id);
        }
    };
    std.mem.sort(Chip, out.items, Ctx{ .order = icon_order }, Ctx.less);
    return out.toOwnedSlice(arena);
}

/// The palette-bar chips: `allChips` less the ones kept off the bar.
pub fn chips(app: *App, arena: Allocator) Allocator.Error![]Chip {
    const all = try allChips(app, arena);
    var out: std.ArrayListUnmanaged(Chip) = .empty;
    for (all) |c| if (c.in_palette_bar) try out.append(arena, c);
    return out.toOwnedSlice(arena);
}

/// The chip with `id`, on the bar or not.
pub fn findChip(app: *App, arena: Allocator, id: []const u8) Allocator.Error!?Chip {
    for (try allChips(app, arena)) |c| if (std.mem.eql(u8, c.id, id)) return c;
    return null;
}

/// A press on chip `idx` of the strip as `chips` ordered it.
pub fn chipClick(app: *App, idx: usize, m: Mouse) Allocator.Error!void {
    const list = try chips(app, app.frame.allocator());
    if (idx >= list.len) return;
    const chip = list[idx];
    if (m.button == .right) {
        if (chip.installed) |row| return openInstalledMenu(app, manifestVirtual(row), m.x, m.y);
        // The AI chips: their launch profiles.
        if (std.mem.eql(u8, chip.id, "claude_code")) return launch_profiles.openChipMenu(app, .claude, m.x, m.y);
        if (std.mem.eql(u8, chip.id, "codex")) return launch_profiles.openChipMenu(app, .codex, m.x, m.y);
        return openIconMenu(app, chip, m.x, m.y);
    }
    return runChip(app, chip);
}

/// What a left press on a chip does, wherever the chip is painted.
fn runChip(app: *App, chip: Chip) Allocator.Error!void {
    if (!chip.enabled) {
        app.toast("{s} is disabled — right-click to enable", .{chip.tooltip});
        return;
    }
    switch (chip.action) {
        .dyn => |slot| command.run(app, .{ .dyn = slot }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .named => |id| command.runNamed(app, id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        },
        .none => app.toast("{s}: nothing to run", .{chip.tooltip}),
    }
}

// ─── the pinned activity-bar icons ──────────────────────────────────────

/// The chips `ui.activity_bar_pinned_integrations` names, in that
/// order; an id no chip answers to is skipped.
pub fn pinnedChips(app: *App, arena: Allocator) Allocator.Error![]Pinned {
    const all = try allChips(app, arena);
    var out: std.ArrayListUnmanaged(Pinned) = .empty;
    for (app.cfg.ui.activity_bar_pinned_integrations) |id| {
        for (all) |c| if (std.mem.eql(u8, c.id, id)) {
            try out.append(arena, .{ .chip = c });
            break;
        };
    }
    return out.toOwnedSlice(arena);
}

pub fn isPinned(app: *App, id: []const u8) bool {
    for (app.cfg.ui.activity_bar_pinned_integrations) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

/// A left press on the `i`-th pinned icon: the chip's command, as the
/// chip on the bar would run it.
pub fn pinClick(app: *App, i: usize) Allocator.Error!void {
    const pins = try pinnedChips(app, app.frame.allocator());
    if (i >= pins.len) return;
    try runChip(app, pins[i].chip);
}

/// The right click on a pinned icon: the chip's menu — Enable / Disable
/// and the palette-bar row for an installed manifest, Remove from
/// activity bar, Copy id.
pub fn openPinMenu(app: *App, i: usize, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    const pins = try pinnedChips(app, app.frame.allocator());
    if (i >= pins.len) return;
    const chip = pins[i].chip;
    try st.setMenuChip(app.gpa, chip.id);
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    if (chip.installed) |row| {
        st.menu_row = .{ .tab = .installed, .idx = manifestVirtual(row) };
        const inst = &st.list[row];
        const on_bar = if (inst.manifest.chip) |c| c.in_palette_bar else true;
        try items.append(app.gpa, .{ .label = if (inst.enabled()) "Disable" else "Enable", .action = .{ .command = .@"integrations.toggle_enabled" } });
        try items.append(app.gpa, .{ .label = if (on_bar) "Hide from top bar" else "Show on top bar", .action = .{ .command = .@"integrations.toggle_palette_bar" } });
        try items.append(app.gpa, .{ .label = "Remove from activity bar", .action = .{ .command = .@"integrations.unpin_from_activity_bar" } });
        try items.append(app.gpa, try dockPinRow(app, chip.id));
        try items.append(app.gpa, .{ .label = "Copy id", .action = .{ .command = .@"integrations.copy_id" } });
        try items.append(app.gpa, openAsRow(app));
    } else {
        try items.append(app.gpa, .{ .label = "Remove from activity bar", .action = .{ .command = .@"integrations.unpin_from_activity_bar" } });
        try items.append(app.gpa, .{ .label = "Copy id", .action = .{ .copy_text = chip.id } });
    }
    try app.openMenu(chip.tooltip, try items.toOwnedSlice(app.gpa), x, y);
}

/// The right click on a config icon's chip (not a manifest's, not an
/// AI chip): Add / Remove from activity bar when its command is a
/// `term` line — the only kind a pinned icon can run without a side
/// panel, Rust's rule — and Copy id.
fn openIconMenu(app: *App, chip: Chip, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    try st.setMenuChip(app.gpa, chip.id);
    st.menu_row = null;
    var items: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    const term_line = switch (chip.action) {
        .named => |cmd| launchers.termProgram(cmd) != null,
        .dyn => true,
        .none => false,
    };
    if (term_line) {
        if (isPinned(app, chip.id))
            try items.append(app.gpa, .{ .label = "Remove from activity bar", .action = .{ .command = .@"integrations.unpin_from_activity_bar" } })
        else
            try items.append(app.gpa, .{ .label = "Add to activity bar", .action = .{ .command = .@"integrations.pin_to_activity_bar" } });
    }
    // // changed (launcher-dock): the dock's row, beside the rail's.
    try items.append(app.gpa, try dockPinRow(app, chip.id));
    try items.append(app.gpa, .{ .label = "Copy id", .action = .{ .copy_text = chip.id } });
    try app.openMenu(chip.tooltip, try items.toOwnedSlice(app.gpa), x, y);
}

/// The Pin to / Unpin from dock row for a chip — the one row every
/// chip menu grows so the dock is reachable from wherever a chip is.
fn dockPinRow(app: *App, chip_id: []const u8) Allocator.Error!command.MenuItem {
    const cmd_id = (try chipCommandId(app, chip_id)) orelse "";
    const on = isPinnedToDock(app, cmd_id);
    return .{
        .label = if (on) "Unpin from dock" else "Pin to dock",
        .action = .{ .command = if (on) .@"integrations.unpin_from_dock" else .@"integrations.pin_to_dock" },
    };
}

/// The id a pin / unpin acts on: the chip a menu was opened on, else
/// the focused Installed row's, else null (a picker opens).
fn pinTarget(app: *App) Allocator.Error!?[]const u8 {
    const st = &app.integrations;
    if (st.menu_chip) |c| {
        const copy = try app.frame.allocator().dupe(u8, c);
        try st.setMenuChip(app.gpa, null);
        st.menu_row = null;
        return copy;
    }
    if (try focusedRow(app)) |r| return st.list[r].id();
    return null;
}

fn pinCmd(app: *App) CommandError!void {
    if (try pinTarget(app)) |id| return pinId(app, id);
    return pickRow(app, .integrations_pin, "Add to activity bar");
}

fn unpinCmd(app: *App) CommandError!void {
    if (try pinTarget(app)) |id| return unpinId(app, id);
    return pickRow(app, .integrations_unpin, "Remove from activity bar");
}

/// Append `id` to `ui.activity_bar_pinned_integrations` and write it home.
pub fn pinId(app: *App, id: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (isPinned(app, id)) {
        app.toast("{s} is already on the activity bar", .{id});
        return;
    }
    if ((try findChip(app, arena, id)) == null) return app.diag.fail(arena, "integrations: {s} has no chip to pin", .{id});
    const old = app.cfg.ui.activity_bar_pinned_integrations;
    const next = try arena.alloc([]const u8, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = id;
    try setPinned(app, next);
    app.toast("{s}: added to the activity bar", .{id});
}

/// Drop `id` from `ui.activity_bar_pinned_integrations` and write it home.
pub fn unpinId(app: *App, id: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (!isPinned(app, id)) {
        app.toast("{s} is not on the activity bar", .{id});
        return;
    }
    const old = app.cfg.ui.activity_bar_pinned_integrations;
    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    for (old) |p| if (!std.mem.eql(u8, p, id)) try next.append(arena, p);
    try setPinned(app, next.items);
    app.toast("{s}: removed from the activity bar", .{id});
}

// ─── the launcher dock's pins ───────────────────────────────────────────
//
// // changed (launcher-dock): the activity bar's pair above, for the
// strip in `app/launcher_dock.zig`. The difference is what is stored:
// the rail pins a CHIP id, the dock pins the COMMAND id that chip
// runs, because `ui.dock.pins` is a list of commands — a pinned row
// there can be any command, not only an integration's.

/// `ui.dock.pins` already holds `id` (a command id).
pub fn isPinnedToDock(app: *const App, id: []const u8) bool {
    if (id.len == 0) return false;
    for (app.cfg.ui.dock.pins) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

/// Remember which chip a launcher-dock menu was opened on, so the two
/// runners below know their target without a picker.
pub fn setDockMenuChip(app: *App, id: []const u8) Allocator.Error!void {
    try app.integrations.setMenuChip(app.gpa, id);
}

/// The command id the chip `id` runs — what the dock pins.
fn chipCommandId(app: *App, id: []const u8) Allocator.Error!?[]const u8 {
    const chip = (try findChip(app, app.frame.allocator(), id)) orelse return null;
    return switch (chip.action) {
        .named => |n| n,
        .dyn => |slot| if (app.dyn_commands.at(slot)) |c| c.id else null,
        .none => null,
    };
}

/// `integrations.pin_to_dock`.
fn pinDockCmd(app: *App) CommandError!void {
    const target = (try pinTarget(app)) orelse return pickRow(app, .integrations_pin, "Pin to the launcher dock");
    const id = (try chipCommandId(app, target)) orelse
        return app.diag.fail(app.frame.allocator(), "integrations: {s} has no command to pin", .{target});
    return pinDockId(app, id);
}

/// `integrations.unpin_from_dock`.
fn unpinDockCmd(app: *App) CommandError!void {
    const target = (try pinTarget(app)) orelse return pickRow(app, .integrations_unpin, "Unpin from the launcher dock");
    const id = (try chipCommandId(app, target)) orelse target;
    return unpinDockId(app, id);
}

/// Append a command id to `ui.dock.pins` and write it home.
pub fn pinDockId(app: *App, id: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (isPinnedToDock(app, id)) {
        app.toast("{s} is already on the dock", .{id});
        return;
    }
    if (command.resolve(app, id) == null) return app.diag.fail(arena, "dock: no such command: {s}", .{id});
    const old = app.cfg.ui.dock.pins;
    const next = try arena.alloc([]const u8, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = id;
    try setDockPins(app, next);
    app.toast("{s}: pinned to the dock", .{id});
}

/// Drop a command id from `ui.dock.pins` and write it home.
pub fn unpinDockId(app: *App, id: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (!isPinnedToDock(app, id)) {
        app.toast("{s} is not pinned to the dock", .{id});
        return;
    }
    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    for (app.cfg.ui.dock.pins) |p| if (!std.mem.eql(u8, p, id)) try next.append(arena, p);
    try setDockPins(app, next.items);
    app.toast("{s}: unpinned from the dock", .{id});
}

/// The new `ui.dock.pins`, gpa-owned by the state and persisted home.
pub fn setDockPins(app: *App, ids: []const []const u8) Allocator.Error!void {
    const st = &app.integrations;
    const gpa = app.gpa;
    const owned = try gpa.alloc([]u8, ids.len);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |p| gpa.free(p);
        gpa.free(owned);
    }
    for (ids) |id| {
        owned[n] = try gpa.dupe(u8, id);
        n += 1;
    }
    st.freeDockPins(gpa);
    st.dock_pins_owned = owned;
    app.cfg.ui.dock.pins = @ptrCast(owned);
    _ = try settings.persist(app, .home, &.{ "ui", "dock", "pins" }, app.cfg.ui.dock.pins);
    app.needs_render = true;
}

/// The new list, gpa-owned by the state and named by the config field,
/// persisted to the home config.
pub fn setPinned(app: *App, ids: []const []const u8) Allocator.Error!void {
    const st = &app.integrations;
    const gpa = app.gpa;
    const owned = try gpa.alloc([]u8, ids.len);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |p| gpa.free(p);
        gpa.free(owned);
    }
    for (ids) |id| {
        owned[n] = try gpa.dupe(u8, id);
        n += 1;
    }
    st.freePins(gpa);
    st.pins_owned = owned;
    app.cfg.ui.activity_bar_pinned_integrations = @ptrCast(owned);
    _ = try settings.persist(app, .home, &.{ "ui", "activity_bar_pinned_integrations" }, app.cfg.ui.activity_bar_pinned_integrations);
    app.needs_render = true;
}

/// `integrations.toggle_palette_bar`: flip the chip's `in_palette_bar`
/// and write the manifest back.
fn togglePaletteBar(app: *App) CommandError!void {
    const st = &app.integrations;
    if (st.menu_chip) |c| {
        const row = st.find(c);
        const fp = firstPartyIndex(c);
        try st.setMenuChip(app.gpa, null);
        st.menu_row = null;
        if (row) |r| return toggleChipField(app, r, .in_palette_bar);
        if (fp) |i| return fpToggle(app, i, .in_palette_bar);
        return app.diag.fail(app.frame.allocator(), "integrations: only a manifest's chip can leave the bar — a config icon's `in_palette_bar` lives in config.zon", .{});
    }
    if (try focusedFirstParty(app)) |i| return fpToggle(app, i, .in_palette_bar);
    if (try focusedRow(app)) |r| return toggleChipField(app, r, .in_palette_bar);
    return pickRow(app, .integrations_toggle_bar, "Show / hide on the palette bar");
}

// ─── the section ────────────────────────────────────────────────────────

/// Show the section on `tab`, the keys with it.
pub fn showTab(app: *App, tab: Tab) CommandError!void {
    @import("activity_bar.zig").enter(app, .integrations);
    const st = &app.integrations;
    if (!st.scanned) try refresh(app);
    // The Dev count in the tab strip is read before the tab is opened,
    // so the roots are scanned on entering the section, not the tab.
    if (!st.dev_scanned) try scanDev(app);
    setTab(app, tab);
    side.place(app, .integrations, true);
    switch (tab) {
        .marketplace => if (app.marketplace.fetched_at_ms == null and !app.marketplace.fetching) marketplace.refresh(app) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (app.diag.msg) |msg| app.toast("{s}", .{msg});
                app.diag.clear();
            },
        },
        .dev => if (!st.dev_scanned) try scanDev(app),
        .installed => {},
    }
}

/// Switch tabs, each keeping its own cursor and scroll.
pub fn setTab(app: *App, tab: Tab) void {
    const st = &app.integrations;
    if (st.tab == tab) return;
    st.tab_cursor[@intFromEnum(st.tab)] = st.panel.cursor;
    st.tab_scroll[@intFromEnum(st.tab)] = st.panel.scroll;
    st.tab = tab;
    st.panel.cursor = st.tab_cursor[@intFromEnum(tab)];
    st.panel.scroll = st.tab_scroll[@intFromEnum(tab)];
    st.panel.on_new = false;
    if (tab == .dev and !st.dev_scanned) scanDev(app) catch {};
    app.needs_render = true;
}

fn showInstalled(app: *App) CommandError!void {
    return showTab(app, .installed);
}

fn showMarketplace(app: *App) CommandError!void {
    return showTab(app, .marketplace);
}

/// // changed (bottom-row): the Marketplace tab, filtered to one entry
/// — where an actionable toast's ` Marketplace ` button lands. The row,
/// not an install: the description, version and source are readable
/// there before anything is fetched.
pub fn revealInMarketplace(app: *App, id: []const u8) CommandError!void {
    try showTab(app, .marketplace);
    const st = &app.integrations;
    st.panel.filter.clearRetainingCapacity();
    try st.panel.filter.appendSlice(app.gpa, id);
    st.panel.filter_caret = st.panel.filter.items.len;
    st.panel.cursor = 0;
    st.panel.scroll = 0;
    app.needs_render = true;
}

fn showDevCmd(app: *App) CommandError!void {
    app.integrations.show_dev_override = true;
    return showTab(app, .dev);
}

fn toggleDevTab(app: *App) CommandError!void {
    const st = &app.integrations;
    const now = !showDev(app);
    st.show_dev_override = now;
    if (!now and st.tab == .dev) setTab(app, .installed);
    app.toast("integrations: the Dev tab is {s}", .{if (now) "shown" else "hidden"});
    app.needs_render = true;
}

fn toggleTab(app: *App) CommandError!void {
    const st = &app.integrations;
    if (!side.isShown(app, .integrations)) return showTab(app, .installed);
    setTab(app, st.tab.next(showDev(app)));
    if (st.tab == .marketplace and app.marketplace.fetched_at_ms == null and !app.marketplace.fetching) marketplace.refresh(app) catch {};
}

fn cycleSort(app: *App) CommandError!void {
    const st = &app.integrations;
    switch (st.tab) {
        .installed => st.installed_sort = st.installed_sort.next(),
        .marketplace, .dev => st.market_sort = st.market_sort.next(),
    }
    app.toast("integrations: sorted by {s}", .{sortLabel(app)});
    app.needs_render = true;
}

/// The sort menu's row: a `ListSort` mapped onto the active tab's order.
pub fn setSort(app: *App, sort: ListSort) Allocator.Error!void {
    const st = &app.integrations;
    switch (st.tab) {
        .installed => st.installed_sort = InstalledSort.fromList(sort),
        .marketplace, .dev => st.market_sort = MarketSort.fromList(sort),
    }
    app.needs_render = true;
}

fn sortLabel(app: *App) []const u8 {
    const st = &app.integrations;
    return switch (st.tab) {
        .installed => st.installed_sort.label(),
        .marketplace, .dev => st.market_sort.label(),
    };
}

/// What the header's sort chip pads to on the active tab.
fn sortWidest(app: *App) usize {
    return switch (app.integrations.tab) {
        .installed => InstalledSort.widest_label,
        .marketplace, .dev => MarketSort.widest_label,
    };
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// The active tab's entries after the filter and the sort, as indices
/// into that tab's underlying list. On `arena`.
pub fn visibleEntries(app: *App, arena: Allocator) Allocator.Error![]usize {
    const st = &app.integrations;
    const q = st.panel.filterText();
    var out: std.ArrayListUnmanaged(usize) = .empty;
    switch (st.tab) {
        .installed => {
            for (st.list, 0..) |*inst, i| {
                const m = inst.manifest;
                const first: []const u8 = if (m.commands.len > 0) m.commands[0].id else m.binary;
                if (q.len > 0 and !(containsIgnoreCase(m.label, q) or containsIgnoreCase(m.id, q) or containsIgnoreCase(first, q) or containsIgnoreCase(m.category, q))) continue;
                try out.append(arena, manifestVirtual(i));
            }
            const Ctx = struct {
                list: []Installed,
                sort: InstalledSort,
                fn lt(self: @This(), a: usize, b: usize) bool {
                    const ma = self.list[a - first_party.len].manifest;
                    const mb = self.list[b - first_party.len].manifest;
                    switch (self.sort) {
                        .name => {},
                        .name_desc => return std.ascii.lessThanIgnoreCase(mb.label, ma.label),
                        .enabled_first => {
                            const ea = self.list[a - first_party.len].enabled();
                            const eb = self.list[b - first_party.len].enabled();
                            if (ea != eb) return ea;
                        },
                        .category => {
                            const c = std.ascii.orderIgnoreCase(ma.category, mb.category);
                            if (c != .eq) return c == .lt;
                        },
                    }
                    return std.ascii.lessThanIgnoreCase(ma.label, mb.label);
                }
            };
            std.mem.sort(usize, out.items, Ctx{ .list = st.list, .sort = st.installed_sort }, Ctx.lt);
            // The four first-party rows go above whatever is installed,
            // in table order, whatever the sort chip says — they are the
            // editor's own surfaces, not entries competing for a place in
            // the list. The filter still hides them.
            var head: std.ArrayListUnmanaged(usize) = .empty;
            for (first_party, 0..) |fp, i| {
                if (q.len > 0 and !(containsIgnoreCase(fp.label, q) or containsIgnoreCase(fp.id, q) or containsIgnoreCase(fp.command, q))) continue;
                try head.append(arena, i);
            }
            try head.appendSlice(arena, out.items);
            return head.toOwnedSlice(arena);
        },
        .marketplace => {
            for (app.marketplace.entries, 0..) |e, i| {
                if (q.len > 0 and !(containsIgnoreCase(e.label, q) or containsIgnoreCase(e.id, q) or containsIgnoreCase(e.description, q))) continue;
                try out.append(arena, i);
            }
            const Ctx = struct {
                list: []marketplace.Entry,
                sort: MarketSort,
                fn lt(self: @This(), a: usize, b: usize) bool {
                    const ea = self.list[a];
                    const eb = self.list[b];
                    switch (self.sort) {
                        .name => {},
                        .name_desc => return std.ascii.lessThanIgnoreCase(eb.label, ea.label),
                        .kind => if (ea.kind != eb.kind) return @intFromEnum(ea.kind) < @intFromEnum(eb.kind),
                        .source => {
                            const c = std.ascii.orderIgnoreCase(ea.source, eb.source);
                            if (c != .eq) return c == .lt;
                        },
                    }
                    return std.ascii.lessThanIgnoreCase(ea.label, eb.label);
                }
            };
            std.mem.sort(usize, out.items, Ctx{ .list = app.marketplace.entries, .sort = st.market_sort }, Ctx.lt);
        },
        .dev => {
            for (st.dev, 0..) |*d, i| {
                const m = d.manifest;
                if (q.len > 0 and !(containsIgnoreCase(m.label, q) or containsIgnoreCase(m.id, q) or containsIgnoreCase(d.dir, q))) continue;
                try out.append(arena, i);
            }
            const Ctx = struct {
                list: []DevEntry,
                sort: MarketSort,
                fn lt(self: @This(), a: usize, b: usize) bool {
                    const da = self.list[a];
                    const db = self.list[b];
                    switch (self.sort) {
                        .name, .kind => {},
                        .name_desc => return std.ascii.lessThanIgnoreCase(db.manifest.label, da.manifest.label),
                        .source => {
                            const c = std.ascii.orderIgnoreCase(da.root, db.root);
                            if (c != .eq) return c == .lt;
                        },
                    }
                    return std.ascii.lessThanIgnoreCase(da.manifest.label, db.manifest.label);
                }
            };
            std.mem.sort(usize, out.items, Ctx{ .list = st.dev, .sort = st.market_sort }, Ctx.lt);
        },
    }
    return out.toOwnedSlice(arena);
}

/// The underlying index of the section's cursor on the active tab.
fn cursorEntry(app: *App) Allocator.Error!?usize {
    const st = &app.integrations;
    const rows = try visibleEntries(app, app.frame.allocator());
    if (st.panel.cursor >= rows.len) return null;
    return rows[st.panel.cursor];
}

fn entryAt(app: *App, visible_idx: usize) Allocator.Error!?usize {
    const rows = try visibleEntries(app, app.frame.allocator());
    if (visible_idx >= rows.len) return null;
    return rows[visible_idx];
}

/// The marketplace entry a `marketplace.*_focused` command acts on: the
/// menu's row, the active detail pane's, else the section's cursor.
pub fn marketRow(app: *App) CommandError!usize {
    const st = &app.integrations;
    if (st.menu_row) |r| {
        st.menu_row = null;
        if (r.tab == .marketplace and r.idx < app.marketplace.entries.len) return r.idx;
    }
    if (activeDetail(app)) |ap| if (ap.p.target == .marketplace) if (marketplace.find(app, ap.p.target.marketplace)) |i| return i;
    if (st.tab == .marketplace) if (try cursorEntry(app)) |i| return i;
    return app.diag.fail(app.frame.allocator(), "marketplace: open the Marketplace tab and pick an entry first", .{});
}

/// Enter / a second click on an entry: Installed opens it, the other
/// tabs open the detail pane.
fn activate(app: *App, visible_idx: usize) CommandError!void {
    const st = &app.integrations;
    const idx = (try entryAt(app, visible_idx)) orelse return;
    switch (st.tab) {
        .installed => return openRow(app, idx),
        .marketplace => return openDetail(app, .{ .marketplace = app.marketplace.entries[idx].id }),
        .dev => return openDetail(app, .{ .dev = st.dev[idx].key() }),
    }
}

pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.integrations;
    switch (try Panel.handleKey(&st.panel, app.gpa, k)) {
        .consumed => {
            app.needs_render = true;
            return true;
        },
        .filter_changed => {
            st.panel.cursor = 0;
            app.needs_render = true;
            return true;
        },
        .activate => |i| {
            runToast(app, activate(app, i));
            return true;
        },
        .new_activate => return true,
        .ignored => {},
    }
    if (st.panel.filter_focused) return false;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .tab => setTab(app, st.tab.next(showDev(app))),
        .backtab => setTab(app, st.tab.prev(showDev(app))),
        .left => setTab(app, st.tab.prev(showDev(app))),
        .right => setTab(app, st.tab.next(showDev(app))),
        .char => |c| switch (c) {
            'h' => setTab(app, st.tab.prev(showDev(app))),
            'l' => setTab(app, st.tab.next(showDev(app))),
            '1' => setTab(app, .installed),
            '2' => runToast(app, showTab(app, .marketplace)),
            '3' => if (showDev(app)) setTab(app, .dev),
            'd' => runToast(app, showDetails(app)),
            'r' => runToast(app, refreshTab(app)),
            's' => runToast(app, cycleSort(app)),
            'i' => runToast(app, installFocused(app)),
            'b' => if (st.tab == .dev) runToast(app, devBuildCmd(app)) else return false,
            'B' => if (st.tab == .dev) runToast(app, devRebuildCmd(app)) else return false,
            'e' => if (st.tab == .installed) runToast(app, toggleEnabled(app)) else return false,
            'm' => runToast(app, showManifest(app)),
            'y' => runToast(app, copyId(app)),
            'x' => if (st.tab == .installed) runToast(app, removeCmd(app)) else return false,
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// The refresh chip's action for the active tab.
fn refreshTab(app: *App) CommandError!void {
    switch (app.integrations.tab) {
        .installed => return refreshCmd(app),
        .marketplace => return command.run(app, .{ .static = .@"marketplace.refresh" }),
        .dev => {
            try scanDev(app);
            app.toast("integrations: {d} dev folder{s}", .{ app.integrations.dev.len, if (app.integrations.dev.len == 1) "" else "s" });
        },
    }
}

/// `i`: install the focused marketplace or dev entry.
fn installFocused(app: *App) CommandError!void {
    switch (app.integrations.tab) {
        .installed => return app.diag.fail(app.frame.allocator(), "integrations: already installed — the Marketplace and Dev tabs install", .{}),
        .marketplace => return command.run(app, .{ .static = .@"marketplace.install_focused" }),
        .dev => return devInstallCmd(app),
    }
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| switch (err) {
        error.Canceled => {},
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("integrations: {s}", .{@errorName(err)});
            app.diag.clear();
        },
    };
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .integrations };
    app.needs_render = true;
}

const double_click_ms: i64 = 500;

/// A press on an entry's rows: left selects (twice, or a double click,
/// activates); right opens the entry's menu.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.integrations;
    switch (m.kind) {
        .press => {
            const rows = try visibleEntries(app, app.frame.allocator());
            if (idx >= rows.len) return;
            focusPanel(app);
            st.panel.cursor = idx;
            if (m.button == .right) return openEntryMenu(app, rows[idx], m.x, m.y);
            if (m.button != .left) return;
            const again = if (st.last_click) |lc| lc.tab == st.tab and lc.idx == idx and app.now_ms - lc.at_ms <= double_click_ms else false;
            st.last_click = .{ .tab = st.tab, .idx = idx, .at_ms = app.now_ms };
            if (again) {
                st.last_click = null;
                runToast(app, activate(app, idx));
            }
        },
        else => {},
    }
    app.needs_render = true;
}

/// The wheel over the list moves the cursor `rows` entries (Rust
/// scrolls three cells per unit — one entry).
pub fn wheel(app: *App, down: bool, rows: usize) void {
    const st = &app.integrations;
    st.panel.cursor = if (down) @min(st.panel.cursor + rows, st.panel.total -| 1) else st.panel.cursor -| rows;
    app.needs_render = true;
}

pub fn kebabMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    const rows = try visibleEntries(app, app.frame.allocator());
    if (idx >= rows.len) return;
    focusPanel(app);
    app.integrations.panel.cursor = idx;
    try openEntryMenu(app, rows[idx], m.x, m.y);
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .sort => if (m.button == .right) try openSortMenu(app, m.x, m.y) else runToast(app, cycleSort(app)),
        .refresh => if (m.button == .right) try auto_refresh.openRefreshMenu(app, .integrations, m.x, m.y) else runToast(app, refreshTab(app)),
        .new, .view, .history => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.integrations.panel.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.integrations;
    const total = st.panel.total;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            const off: usize = m.y -| bar.y;
            st.panel.cursor = @min(off * total / bar.h, total - 1);
        },
        .scroll_up => st.panel.cursor -|= 1,
        .scroll_down => st.panel.cursor = @min(st.panel.cursor + 1, total - 1),
        else => {},
    }
    app.needs_render = true;
}

/// A press on tab `idx` of the strip.
pub fn tabClick(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    if (m.kind != .press or m.button != .left or idx >= Tab.all.len) return;
    const tab: Tab = @enumFromInt(idx);
    if (tab == .dev and !showDev(app)) return;
    focusPanel(app);
    runToast(app, showTab(app, tab));
}

fn openSortMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    const items = try app.gpa.alloc(command.MenuItem, 4);
    errdefer app.gpa.free(items);
    switch (st.tab) {
        .installed => for (InstalledSort.all, 0..) |s, i| {
            items[i] = .{ .label = s.menuLabel(), .action = .{ .set_panel_sort = .{ .panel = .integrations, .sort = s.toList() } }, .checked = s == st.installed_sort };
        },
        .marketplace, .dev => for (MarketSort.all, 0..) |s, i| {
            items[i] = .{ .label = s.menuLabel(), .action = .{ .set_panel_sort = .{ .panel = .integrations, .sort = s.toList() } }, .checked = s == st.market_sort };
        },
    }
    try app.openMenu("Sort by", items, x, y);
}

/// The entry's menu: the actions of its tab, over its real index.
fn openEntryMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    switch (st.tab) {
        .installed => return openInstalledMenu(app, idx, x, y),
        .marketplace => {
            if (idx >= app.marketplace.entries.len) return;
            st.menu_row = .{ .tab = .marketplace, .idx = idx };
            const e = app.marketplace.entries[idx];
            const installed = st.find(e.id) != null;
            const items = try app.gpa.dupe(command.MenuItem, &.{
                .{ .label = if (installed) "Reinstall" else "Install", .action = .{ .command = .@"marketplace.install_focused" } },
                .{ .label = "Details", .action = .{ .command = .@"marketplace.open_detail_focused" } },
                .{ .label = "Copy id", .action = .{ .command = .@"marketplace.copy_id_focused" } },
            });
            errdefer app.gpa.free(items);
            try app.openMenu(e.label, items, x, y);
        },
        .dev => {
            if (idx >= st.dev.len) return;
            st.menu_row = .{ .tab = .dev, .idx = idx };
            const d = &st.dev[idx];
            const installed = st.find(d.id()) != null;
            const items = try app.gpa.dupe(command.MenuItem, &.{
                .{ .label = "Build", .action = .{ .command = .@"integrations.dev_build" } },
                .{ .label = if (installed) "Reinstall" else "Install", .action = .{ .command = .@"integrations.dev_install" } },
                .{ .label = "Rebuild + reinstall", .action = .{ .command = .@"integrations.dev_rebuild" } },
                .{ .label = "Details", .action = .{ .command = .@"integrations.show_details" }, .separator_before = true },
                .{ .label = "Open manifest.zon", .action = .{ .command = .@"integrations.show_manifest" } },
                .{ .label = "Copy id", .action = .{ .command = .@"integrations.copy_id" } },
            });
            errdefer app.gpa.free(items);
            try app.openMenu(d.manifest.label, items, x, y);
        },
    }
}

/// The first-party row's menu: the surface it reaches, then the two
/// preferences `ui.integration_icons` persists. Claude and Codex lead
/// with their sessions — *New session ▸* is the chip's own profile
/// menu, so the two never drift — then the usage pane and the profiles.
fn openFirstPartyMenu(app: *App, i: usize, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    if (i >= first_party.len) return;
    const fp = first_party[i];
    st.menu_row = .{ .tab = .installed, .idx = i };
    try st.setMenuChip(app.gpa, null);
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    var rows: std.ArrayListUnmanaged(command.MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    const product: ?launch_profiles.Product = if (std.mem.eql(u8, fp.id, "claude_code"))
        .claude
    else if (std.mem.eql(u8, fp.id, "codex"))
        .codex
    else
        null;
    if (product) |p| {
        try rows.append(app.gpa, .{ .label = "New session", .action = .none, .submenu = try launch_profiles.menuItems(app, mem.allocator(), p) });
        try rows.append(app.gpa, .{ .label = "Usage", .action = .{ .command = if (p == .codex) .@"ai.codex_usage" else .@"ai.claude_usage" } });
        // Codex has no login of its own — its reader counts
        // transcripts on disk, so there is nothing to link.
        if (p == .claude) try rows.append(app.gpa, .{ .label = "Login", .action = .{ .command = .@"ai.link_claude_token" } });
        try rows.append(app.gpa, .{ .label = "Configure profiles…", .action = .{ .ai_profile = .{ .product = p, .index = launch_profiles.legacy_index, .set_default = false } } });
    } else if (std.mem.eql(u8, fp.id, "browser")) {
        try rows.append(app.gpa, .{ .label = "Open", .action = .{ .command = .@"browser.open" } });
    } else {
        try rows.append(app.gpa, .{ .label = "New request", .action = .{ .command = .@"http.new_request" } });
        try rows.append(app.gpa, .{ .label = "Collections", .action = .{ .command = .@"view.activity_http" } });
    }
    try rows.append(app.gpa, .{ .label = if (fpEnabled(app, i)) "Disable" else "Enable", .action = .{ .command = .@"integrations.toggle_enabled" }, .separator_before = true });
    try rows.append(app.gpa, .{ .label = if (fpOnBar(app, i)) "Hide from palette bar" else "Show in palette bar", .action = .{ .command = .@"integrations.toggle_palette_bar" } });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try context_menus.openOwned(app, fp.label, owned, x, y, mem);
}

/// `virtual` is an Installed-tab index: a first-party row or a manifest.
fn openInstalledMenu(app: *App, virtual: usize, x: u16, y: u16) Allocator.Error!void {
    const st = &app.integrations;
    const row = switch (installedRow(virtual)) {
        .first_party => |i| return openFirstPartyMenu(app, i, x, y),
        .manifest => |i| i,
    };
    if (row >= st.list.len) return;
    st.menu_row = .{ .tab = .installed, .idx = virtual };
    try st.setMenuChip(app.gpa, null);
    const inst = &st.list[row];
    const enabled = inst.enabled();
    const on_bar = if (inst.manifest.chip) |c| c.in_palette_bar else false;
    const pinned = isPinned(app, inst.id());
    const items = try app.gpa.dupe(command.MenuItem, &.{
        .{ .label = "Details", .action = .{ .command = .@"integrations.show_details" } },
        .{ .label = if (enabled) "Disable" else "Enable", .action = .{ .command = .@"integrations.toggle_enabled" } },
        .{ .label = if (on_bar) "Hide from top bar" else "Show on top bar", .action = .{ .command = .@"integrations.toggle_palette_bar" } },
        .{ .label = if (pinned) "Remove from activity bar" else "Add to activity bar", .action = .{ .command = if (pinned) .@"integrations.unpin_from_activity_bar" else .@"integrations.pin_to_activity_bar" } },
        .{ .label = "Open manifest", .action = .{ .command = .@"integrations.show_manifest" }, .separator_before = true },
        .{ .label = "Copy id", .action = .{ .command = .@"integrations.copy_id" } },
        openAsRow(app),
        .{ .label = "Update (relink the binary)", .action = .{ .command = .@"integrations.update" }, .separator_before = true },
        .{ .label = "Uninstall…", .action = .{ .command = .@"integrations.remove" } },
    });

    errdefer app.gpa.free(items);
    try app.openMenu(st.list[row].manifest.label, items, x, y);
}

/// The section's frame.
pub fn drawSection(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.integrations;
    if (!st.scanned) try refresh(app);
    const idxs = try visibleEntries(app, ui.arena);
    const rows = try ui.arena.alloc(view.Entry, idxs.len);
    for (idxs, 0..) |i, k| rows[k] = try entryRow(app, ui.arena, i);
    st.panel.total = rows.len;
    // The FONTS section: the Marketplace tab, no filter, not scrolled —
    // hidden otherwise, as Rust hides it, so the list math stays put.
    const fonts: ?fonts_section.Props = if (st.tab == .marketplace and st.panel.filterText().len == 0 and st.panel.scroll == 0)
        try font_scan.sectionProps(app, ui.arena)
    else
        null;
    const fonts_rows: u16 = if (fonts) |fp| fonts_section.height(fp, area.h -| view.body_top) else 0;
    st.panel.visible = @max((area.h -| view.body_top -| fonts_rows) + 1, 1) / view.rows_per_entry;
    if (st.panel.cursor >= rows.len) st.panel.cursor = rows.len -| 1;
    const q = st.panel.filterText();
    const empty: list_panel.EmptyState = if (q.len > 0)
        .{ .message = ui.fmt("No matches for \"{s}\" — Esc clears", .{q}) }
    else switch (st.tab) {
        .installed => .{ .message = "Nothing installed yet — try the Marketplace tab", .hint = if (tomlNoticeDue(app)) try tomlNoticeText(app, ui.arena) else "or a Dev folder: Install runs <binary> --install" },
        .marketplace => if (marketplace.sourceCount(app) == 0)
            .{ .message = "No sources yet — the official set comes with the first Zig integrations", .hint = "marketplace.sources in config.zon adds one" }
        else if (app.marketplace.fetching)
            .{ .message = if (ui.ascii) "Fetching the sources..." else "Fetching the sources…" }
        else if (app.marketplace.fetched_at_ms == null)
            .{ .message = "No marketplace entries yet — run `marketplace.refresh`", .hint = "r fetches the configured sources" }
        else
            .{ .message = "Nothing listed — the sources are empty", .hint = "marketplace.sources in config.zon" },
        .dev => .{ .message = "No dev folders — nothing under integrations.dev_roots", .hint = "a folder is a build.zig with a manifest.zon beside it" },
    };
    const caret = view.drawSection(ui, area, .{
        .tab = st.tab,
        .counts = .{ installedCount(app), app.marketplace.entries.len, st.dev.len },
        .show_dev = showDev(app),
        .filter = st.panel.filterText(),
        .filter_caret = st.panel.filter_caret,
        .filter_focused = st.panel.filter_focused,
        .sort_label = sortLabel(app),
        .sort_widest = sortWidest(app),
        .rows = rows,
        .scroll = &st.panel.scroll,
        .cursor = st.panel.cursor,
        .focused = ui.isFocused(.{ .panel = .integrations }),
        .empty = empty,
        .busy = marketplace.busy(app) or st.job != null,
        .now_ms = app.now_ms,
        .fonts = fonts,
    });
    if (caret) |c| if (app.focus == .panel and app.focus.panel == .integrations) {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

/// A first-party row. Its second line is the command Enter runs —
/// except for the two AI surfaces, where it is the quota the usage
/// reader last saw, so the numbers are in the list without opening the
/// pane (`usage_pane.claudeSummary` / `codexSummary`).
fn firstPartyRow(app: *App, arena: Allocator, i: usize) Allocator.Error!view.Entry {
    const fp = first_party[i];
    const line2: []const u8 = if (std.mem.eql(u8, fp.id, "claude_code"))
        try usage_pane.claudeSummary(app, arena)
    else if (std.mem.eql(u8, fp.id, "codex"))
        try usage_pane.codexSummary(app, arena)
    else
        fp.command;
    return .{
        .glyph = fp.glyph,
        .fallback = fp.fallback,
        .color = fp.color,
        .kind = .installed,
        .label = fp.label,
        .hidden = !fpEnabled(app, i),
        .badge = .first_party,
        .line2 = line2,
    };
}

/// One entry of the active tab as the painter wants it.
fn entryRow(app: *App, arena: Allocator, idx: usize) Allocator.Error!view.Entry {
    const st = &app.integrations;
    switch (st.tab) {
        .installed => {
            const inst = switch (installedRow(idx)) {
                .first_party => |i| return firstPartyRow(app, arena, i),
                .manifest => |i| &st.list[i],
            };
            const m = inst.manifest;
            return .{
                .glyph = try chipGlyph(arena, m.chip),
                .fallback = if (m.chip) |c| c.fallback else "",
                .color = if (m.chip) |c| c.color else "",
                .kind = .installed,
                .label = m.label,
                .hidden = !inst.enabled(),
                .missing = if (inst.binary_found) null else std.fs.path.basename(m.binary),
                .version = m.version,
                .line2 = if (m.commands.len > 0) m.commands[0].id else m.binary,
            };
        },
        .marketplace => {
            const e = app.marketplace.entries[idx];
            // A catalogue row is one binary, not one manifest, so what
            // counts as installed is read off the binary
            // (`catalogueState`) rather than looked up by the row's id.
            const state: ?catalogue.State = if (e.kind == .builtin) try catalogueState(app, arena, e.binary, e.version) else null;
            const installed = if (state) |s2| s2 != .not_installed else st.find(e.id) != null;
            return .{
                .glyph = e.glyph,
                .fallback = e.fallback,
                .color = e.color,
                .kind = switch (e.kind) {
                    .launcher => .launcher,
                    // A catalogue row IS an app — one mnml ships — so
                    // it wears the same `[app]` tag; the `✓ Official`
                    // badge and the `(mnml)` source say where from.
                    .app, .builtin => .app,
                },
                .label = e.label,
                .badge = if (e.private) .private else if (e.official) .official else .community,
                .state = state orelse (if (installed) catalogue.State.installed else null),
                // A catalogue row carries the version the install will
                // land, which is what `update available` is read
                // against; the other sources' rows keep the label
                // alone.
                .version = if (e.kind == .builtin) e.version else "",
                .source = e.source,
                .line2 = if (e.description.len > 0) e.description else "(no description)",
                .dim = installed,
                .installing = if (app.marketplace.installing) |cur| std.mem.eql(u8, cur, e.id) else false,
            };
        },
        .dev => {
            const d = &st.dev[idx];
            const m = d.manifest;
            const installed = st.find(m.id) != null;
            return .{
                .glyph = try chipGlyph(arena, m.chip),
                .fallback = if (m.chip) |c| c.fallback else "",
                .color = if (m.chip) |c| c.color else "",
                .kind = .dev,
                .label = m.label,
                .version = m.version,
                .badge = if (installed) .installed_here else .not_installed,
                .source = d.root,
                .line2 = try arena.dupe(u8, app.relPath(if (d.launcher) d.manifest_path else d.dir)),
                .installing = if (st.job) |j| std.mem.eql(u8, j.dir, d.dir) else false,
            };
        },
    }
}

// ─── the detail pane ────────────────────────────────────────────────────

fn activeDetail(app: *App) ?struct { id: PaneId, p: *IntegrationsPane } {
    const id = app.active orelse return null;
    const pane = app.panes.get(id) orelse return null;
    return switch (pane.*) {
        .integrations => |*p| .{ .id = id, .p = p },
        else => null,
    };
}

/// Open (or refocus) the detail pane on `target`.
pub fn openDetail(app: *App, target: IntegrationsPane.TargetRef) CommandError!void {
    // One detail pane at a time: retarget an open one.
    if (app.panes.findKind(.integrations)) |id| {
        const p = &app.panes.get(id).?.integrations;
        const copy = try app.gpa.dupe(u8, target.key());
        p.deinit(app.gpa);
        p.target = switch (target) {
            .installed => .{ .installed = copy },
            .marketplace => .{ .marketplace = copy },
            .dev => .{ .dev = copy },
        };
        p.cursor = 0;
        app.showPane(id);
        return;
    }
    const copy = try app.gpa.dupe(u8, target.key());
    errdefer app.gpa.free(copy);
    const owned: IntegrationsPane.Target = switch (target) {
        .installed => .{ .installed = copy },
        .marketplace => .{ .marketplace = copy },
        .dev => .{ .dev = copy },
    };
    const id = try app.panes.add(.{ .integrations = .{ .target = owned } });
    app.showPane(id);
}

/// The row a command acts on: the menu's, the detail pane's, else the
/// section's cursor on the Installed tab, else null (a picker opens).
fn focusedRow(app: *App) Allocator.Error!?usize {
    const st = &app.integrations;
    if (st.menu_row) |r| {
        st.menu_row = null;
        if (r.tab == .installed) return switch (installedRow(r.idx)) {
            .first_party => null,
            .manifest => |i| if (i < st.list.len) i else null,
        };
        if (r.tab == .dev and r.idx < st.dev.len) return st.find(st.dev[r.idx].id());
        return null;
    }
    if (activeDetail(app)) |ap| switch (ap.p.target) {
        .installed => |id| return st.find(id),
        .dev => |dir| if (st.findDev(dir)) |i| return st.find(st.dev[i].id()),
        .marketplace => {},
    };
    if (app.focus == .panel and app.focus.panel == .integrations) {
        if (st.tab == .installed) {
            if (try cursorEntry(app)) |v| return switch (installedRow(v)) {
                .first_party => null,
                .manifest => |i| i,
            };
            return null;
        }
        if (st.tab == .dev) if (try cursorEntry(app)) |i| return st.find(st.dev[i].id());
    }
    return null;
}

/// The first-party row a command acts on: the one its menu was opened
/// on, else the section's cursor when it is on one. Asked BEFORE
/// `focusedRow`, which consumes `menu_row`.
fn focusedFirstParty(app: *App) Allocator.Error!?usize {
    const st = &app.integrations;
    if (st.menu_row) |r| {
        if (r.tab != .installed) return null;
        return switch (installedRow(r.idx)) {
            .first_party => |i| blk: {
                st.menu_row = null;
                break :blk i;
            },
            .manifest => null,
        };
    }
    if (app.focus == .panel and app.focus.panel == .integrations and st.tab == .installed) {
        if (try cursorEntry(app)) |v| return switch (installedRow(v)) {
            .first_party => |i| i,
            .manifest => null,
        };
    }
    return null;
}

/// The picker over installed integrations for `kind`.
fn pickRow(app: *App, kind: app_mod.PickerKind, title: []const u8) CommandError!void {
    const st = &app.integrations;
    if (!st.scanned) try refresh(app);
    if (st.list.len == 0) return app.diag.fail(app.frame.allocator(), "no integrations installed", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (st.list) |*inst| try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}  {s}", .{ inst.manifest.label, inst.id() }));
    const owned = try labels.toOwnedSlice(gpa);
    errdefer {
        for (owned) |l| gpa.free(l);
        gpa.free(owned);
    }
    try cmd_picker.openPicker(app, title, kind, owned, &.{});
}

/// A picker row chosen: `i` is the installed index.
pub fn acceptPicker(app: *App, kind: app_mod.PickerKind, i: usize) Allocator.Error!void {
    const result: CommandError!void = switch (kind) {
        .integrations_details => detailsAt(app, i),
        .integrations_manifest => manifestAt(app, i),
        .integrations_toggle => toggleAt(app, i),
        .integrations_remove => removeAt(app, i),
        .integrations_copy_id => copyIdAt(app, i),
        .integrations_pin => if (i < app.integrations.list.len) pinId(app, app.integrations.list[i].id()) else {},
        .integrations_unpin => if (i < app.integrations.list.len) unpinId(app, app.integrations.list[i].id()) else {},
        .integrations_toggle_bar => toggleChipField(app, i, .in_palette_bar),
        else => {},
    };
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("integrations: {s}", .{@errorName(err)}),
    };
}

fn showDetails(app: *App) CommandError!void {
    const st = &app.integrations;
    // On the Dev / Marketplace tab, the detail pane of the entry under
    // the cursor (or the menu's row) — installed or not.
    if (st.menu_row) |r| if (r.tab == .dev and r.idx < st.dev.len) {
        st.menu_row = null;
        return openDetail(app, .{ .dev = st.dev[r.idx].key() });
    };
    if (app.focus == .panel and app.focus.panel == .integrations) switch (st.tab) {
        .dev => if (try cursorEntry(app)) |i| return openDetail(app, .{ .dev = st.dev[i].key() }),
        .marketplace => if (try cursorEntry(app)) |i| return openDetail(app, .{ .marketplace = app.marketplace.entries[i].id }),
        .installed => {},
    };
    if (try focusedRow(app)) |r| return detailsAt(app, r);
    return pickRow(app, .integrations_details, "Integration details");
}

fn detailsAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    return openDetail(app, .{ .installed = st.list[i].id() });
}

fn showManifest(app: *App) CommandError!void {
    const st = &app.integrations;
    // A dev folder's manifest.zon is the file to edit.
    if (st.menu_row) |r| if (r.tab == .dev and r.idx < st.dev.len) {
        st.menu_row = null;
        return openFile(app, st.dev[r.idx].manifest_path);
    };
    if (activeDetail(app)) |ap| if (ap.p.target == .dev) if (st.findDev(ap.p.target.dev)) |i| return openFile(app, st.dev[i].manifest_path);
    if (app.focus == .panel and app.focus.panel == .integrations and st.tab == .dev) if (try cursorEntry(app)) |i| return openFile(app, st.dev[i].manifest_path);
    if (try focusedRow(app)) |r| return manifestAt(app, r);
    return pickRow(app, .integrations_manifest, "Open manifest");
}

fn editCmd(app: *App) CommandError!void {
    if (try focusedRow(app)) |r| return manifestAt(app, r);
    return pickRow(app, .integrations_manifest, "Edit integration (its manifest)");
}

fn manifestAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    return openFile(app, st.list[i].path);
}

fn openFile(app: *App, path_in: []const u8) CommandError!void {
    const path = try app.frame.allocator().dupe(u8, path_in);
    _ = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(app.frame.allocator(), "cannot open {s}: {s}", .{ path, @errorName(err) }),
    };
}

fn toggleEnabled(app: *App) CommandError!void {
    if (try focusedFirstParty(app)) |i| return fpToggle(app, i, .enabled);
    if (try focusedRow(app)) |r| return toggleAt(app, r);
    return pickRow(app, .integrations_toggle, "Enable / disable integration");
}

/// Flip `chip.enabled` and write the manifest back.
fn toggleAt(app: *App, i: usize) CommandError!void {
    return toggleChipField(app, i, .enabled);
}

const ChipFlag = enum { enabled, in_palette_bar };

/// Flip a first-party row's `enabled` / `in_palette_bar`. A scanned
/// integration's two flags live in its manifest file, which
/// `toggleChipField` rewrites; a first-party surface has no manifest,
/// so its two live in `ui.integration_icons` in the home config —
/// written whole, the way a reorder writes a list.
fn fpToggle(app: *App, i: usize, flag: ChipFlag) CommandError!void {
    if (i >= first_party.len) return;
    const fp = first_party[i];
    const arena = app.frame.allocator();
    var rows: std.ArrayListUnmanaged(config.Config.IntegrationIcon) = .empty;
    var seen = false;
    for (app.cfg.ui.integration_icons) |ic| {
        var row = ic;
        if (std.mem.eql(u8, ic.id, fp.id)) {
            seen = true;
            switch (flag) {
                .enabled => row.enabled = !row.enabled,
                .in_palette_bar => row.in_palette_bar = !row.in_palette_bar,
            }
        }
        try rows.append(arena, row);
    }
    // A config that dropped the row: put it back, flipped off its
    // table default, so the toggle has somewhere to land.
    if (!seen) try rows.append(arena, .{
        .id = fp.id,
        .glyph = fp.glyph,
        .fallback = fp.fallback,
        .command = fp.command,
        .color = fp.color,
        .label = fp.label,
        .enabled = if (flag == .enabled) !fp.enabled else fp.enabled,
        .in_palette_bar = if (flag == .in_palette_bar) !fp.in_palette_bar else fp.in_palette_bar,
    });
    try setIcons(app, rows.items);
    const now = switch (flag) {
        .enabled => fpEnabled(app, i),
        .in_palette_bar => fpOnBar(app, i),
    };
    switch (flag) {
        .enabled => app.toast("{s}: {s}", .{ fp.id, if (now) "enabled" else "disabled" }),
        .in_palette_bar => app.toast("{s}: {s} the palette bar", .{ fp.id, if (now) "shown on" else "hidden from" }),
    }
}

/// The new `ui.integration_icons`, owned by the state (arena, strings
/// and all) and named by the config field, persisted to the home
/// config — `setPinned`'s shape for an array of records.
fn setIcons(app: *App, rows: []const config.Config.IntegrationIcon) Allocator.Error!void {
    const st = &app.integrations;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    const owned = try a.alloc(config.Config.IntegrationIcon, rows.len);
    for (rows, 0..) |ic, i| owned[i] = try dupeIcon(a, ic);
    _ = try settings.persist(app, .home, &.{ "ui", "integration_icons" }, owned);
    // Nothing fallible past here: the arena moves into the state and
    // the errdefer above must not fire on the copy that shares it.
    if (st.icons_arena) |*old| old.deinit();
    st.icons_arena = arena_state;
    app.cfg.ui.integration_icons = owned;
    app.needs_render = true;
}

fn dupeIcon(a: Allocator, ic: config.Config.IntegrationIcon) Allocator.Error!config.Config.IntegrationIcon {
    const opt = struct {
        fn dupe(al: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
            return if (s) |v| try al.dupe(u8, v) else null;
        }
    }.dupe;
    const cmds = try a.alloc(config.Config.IntegrationIconCommand, ic.commands.len);
    for (ic.commands, 0..) |c, i| cmds[i] = .{ .id = try a.dupe(u8, c.id), .title = try a.dupe(u8, c.title) };
    return .{
        .id = try a.dupe(u8, ic.id),
        .glyph = try a.dupe(u8, ic.glyph),
        .fallback = try a.dupe(u8, ic.fallback),
        .command = try a.dupe(u8, ic.command),
        .color = try a.dupe(u8, ic.color),
        .label = try opt(a, ic.label),
        .enabled = ic.enabled,
        .in_palette_bar = ic.in_palette_bar,
        .description = try opt(a, ic.description),
        .homepage = try opt(a, ic.homepage),
        .docs = try opt(a, ic.docs),
        .repository = try opt(a, ic.repository),
        .author = try opt(a, ic.author),
        .version = try opt(a, ic.version),
        .commands = cmds,
    };
}

/// Flip one of the chip's two user-preference flags and write the
/// manifest back; the list follows.
fn toggleChipField(app: *App, i: usize, flag: ChipFlag) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    const inst = &st.list[i];
    var m = inst.manifest;
    var chip: manifest_mod.Chip = m.chip orelse .{};
    switch (flag) {
        .enabled => chip.enabled = !chip.enabled,
        .in_palette_bar => chip.in_palette_bar = !chip.in_palette_bar,
    }
    m.chip = chip;
    const text = try manifest_mod.render(app.gpa, m);
    defer app.gpa.free(text);
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = inst.path, .data = text }) catch |err| {
        return app.diag.fail(app.frame.allocator(), "cannot write {s}: {s}", .{ app.relPath(inst.path), @errorName(err) });
    };
    const id = try app.frame.allocator().dupe(u8, inst.id());
    const now = switch (flag) {
        .enabled => chip.enabled,
        .in_palette_bar => chip.in_palette_bar,
    };
    try refresh(app);
    switch (flag) {
        .enabled => app.toast("{s}: {s}", .{ id, if (now) "enabled" else "disabled" }),
        .in_palette_bar => app.toast("{s}: {s} the palette bar", .{ id, if (now) "shown on" else "hidden from" }),
    }
}

fn removeCmd(app: *App) CommandError!void {
    if (try focusedRow(app)) |r| return removeAt(app, r);
    return pickRow(app, .integrations_remove, "Remove integration");
}

/// Ask first; `removeAccept` deletes the manifest.
fn removeAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    const inst = &st.list[i];
    // // changed (int-distribution): the link goes with the manifest
    // when nothing else names the binary, so an uninstall leaves
    // neither half behind. The binary itself is not ours to delete —
    // it is PREFIX's, or the checkout's.
    const arena = app.frame.allocator();
    const bin = std.fs.path.basename(try expandEnv(app, arena, inst.manifest.binary));
    const takes_link = !inst.manifest.isLauncher() and !binaryStillUsed(app, inst.manifest.binary, inst.id());
    const msg = if (takes_link)
        try std.fmt.allocPrint(app.gpa, "  Remove {s}? Its manifest {s} and the link bin/{s} are deleted; the binary itself stays.", .{ inst.manifest.label, app.relPath(inst.path), bin })
    else
        try std.fmt.allocPrint(app.gpa, "  Remove {s}? Its manifest {s} is deleted; the binary stays.", .{ inst.manifest.label, app.relPath(inst.path) });
    errdefer app.gpa.free(msg);
    const id = try app.gpa.dupe(u8, inst.id());
    errdefer app.gpa.free(id);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Remove integration", .message = msg, .choices = &remove_choices },
        .purpose = .{ .remove_integration = id },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const remove_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'r', .label = "Remove" }, .{ .key = 'c', .label = "Cancel" } };

/// The confirm's yes: the manifest goes, and with it the commands, the
/// chip and the segments the next scan no longer finds.
pub fn removeAccept(app: *App, id: []const u8) Allocator.Error!void {
    const st = &app.integrations;
    const arena = app.frame.allocator();
    const i = st.find(id) orelse return;
    const path = try arena.dupe(u8, st.list[i].path);
    const manifest_binary = try arena.dupe(u8, st.list[i].manifest.binary);
    const launcher = st.list[i].manifest.isLauncher();
    Io.Dir.cwd().deleteFile(app.io, path) catch |err| {
        app.toast("cannot delete {s}: {s}", .{ app.relPath(path), @errorName(err) });
        return;
    };
    // The link too, once no other manifest names the binary. The check
    // runs against the list as it still is — `refresh` below is what
    // drops this one — so `except` is this id.
    var link_went = false;
    if (!launcher and app.data_root.len > 0 and !binaryStillUsed(app, manifest_binary, id)) {
        const name = std.fs.path.basename(try expandEnv(app, arena, manifest_binary));
        const link = try std.fs.path.join(arena, &.{ app.data_root, "bin", name });
        if (Io.Dir.cwd().deleteFile(app.io, link)) |_| {
            link_went = true;
        } else |_| {}
    }
    const copy = try arena.dupe(u8, id);
    try refresh(app);
    if (link_went) app.toast("removed {s} — the manifest and the link", .{copy}) else app.toast("removed {s}", .{copy});
}

/// `integrations.update`: relink `<data root>/bin/<binary>` at
/// wherever the binary is NOW — PREFIX's copy after a `run.sh install`,
/// else this checkout's fresh build. The manifest names the bare
/// binary and `resolveBinary` prefers the link, so this one file is the
/// whole update: nothing is downloaded, nothing is rewritten, and a
/// version bump reaches every manifest that binary wrote at once.
fn updateCmd(app: *App) CommandError!void {
    const i = (try focusedRow(app)) orelse
        return app.diag.fail(app.frame.allocator(), "integrations: pick an installed integration first", .{});
    return updateAt(app, i);
}

fn updateAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    const arena = app.frame.allocator();
    if (i >= st.list.len) return;
    const inst = &st.list[i];
    if (inst.manifest.isLauncher())
        return app.diag.fail(arena, "integrations: {s} is a launcher \u{2014} it has no binary to relink", .{inst.id()});
    if (app.data_root.len == 0) return app.diag.fail(arena, "integrations: no data root to link into", .{});
    const id = try arena.dupe(u8, inst.id());
    const version = try arena.dupe(u8, inst.manifest.version);
    const binary = try expandEnv(app, arena, inst.manifest.binary);
    const path_var = app.env.get("PATH") orelse "";
    const repo = try catalogue.repoOf(app.io, arena, try marketplace.cataloguePath(app, arena));
    const target = (try catalogue.linkTarget(app.io, arena, binary, path_var, app.data_root, repo)) orelse
        return app.diag.fail(arena, "integrations: {s} is not on PATH and not built in this checkout \u{2014} `zig build`, or `run.sh install`", .{binary});
    const link = marketplace.linkBinary(app.io, arena, app.data_root, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LinkFailed => return app.diag.fail(arena, "integrations: cannot link {s} into {s}/bin", .{ target, app.relPath(app.data_root) }),
    };
    const shown = try arena.dupe(u8, app.relPath(link));
    try refresh(app);
    if (version.len > 0)
        app.toast("updated {s} {s} \u{2014} {s} \u{2192} {s}", .{ id, version, shown, target })
    else
        app.toast("updated {s} \u{2014} {s} \u{2192} {s}", .{ id, shown, target });
}

fn copyId(app: *App) CommandError!void {
    const st = &app.integrations;
    if (st.menu_row) |r| if (r.tab == .dev and r.idx < st.dev.len) {
        st.menu_row = null;
        try app.clipboard.set(st.dev[r.idx].id(), false);
        app.toast("copied {s}", .{st.dev[r.idx].id()});
        return;
    };
    if (activeDetail(app)) |ap| {
        const key = ap.p.target.key();
        const id: []const u8 = if (ap.p.target == .dev) (if (st.findDev(key)) |d| st.dev[d].id() else std.fs.path.basename(key)) else key;
        try app.clipboard.set(id, false);
        app.toast("copied {s}", .{id});
        return;
    }
    if (try focusedRow(app)) |r| return copyIdAt(app, r);
    return pickRow(app, .integrations_copy_id, "Copy integration id");
}

fn copyIdAt(app: *App, i: usize) CommandError!void {
    const st = &app.integrations;
    if (i >= st.list.len) return;
    try app.clipboard.set(st.list[i].id(), false);
    app.toast("copied {s}", .{st.list[i].id()});
}

/// The detail pane's buttons for its target, in order.
const Button = enum {
    open,
    toggle,
    edit_manifest,
    copy_id,
    refresh,
    update,
    uninstall,
    install,
    reinstall,
    build,
    rebuild,

    fn label(b: Button, app: *App, p: *const IntegrationsPane) []const u8 {
        return switch (b) {
            .open => "Open",
            .toggle => if (p.target == .installed) (if (app.integrations.find(p.target.installed)) |i| (if (app.integrations.list[i].enabled()) "Disable" else "Enable") else "Enable") else "Enable",
            .edit_manifest => "Edit manifest",
            .copy_id => "Copy id",
            .refresh => "Refresh",
            .update => "Update",
            .uninstall => "Uninstall",
            .install => "Install",
            .reinstall => "Reinstall",
            .build => "Build",
            .rebuild => "Rebuild + reinstall",
        };
    }
};

fn buttonsFor(app: *App, p: *const IntegrationsPane) []const Button {
    const st = &app.integrations;
    return switch (p.target) {
        // A launcher has no binary to relink, so no Update button.
        .installed => |id| if (st.find(id)) |i| (if (st.list[i].manifest.isLauncher())
            @as([]const Button, &.{ .open, .toggle, .edit_manifest, .copy_id, .refresh, .uninstall })
        else
            @as([]const Button, &.{ .open, .toggle, .edit_manifest, .copy_id, .refresh, .update, .uninstall })) else &.{ .open, .toggle, .edit_manifest, .copy_id, .refresh, .uninstall },
        .marketplace => |id| if (st.find(id) != null) &.{ .reinstall, .copy_id, .refresh } else &.{ .install, .copy_id, .refresh },
        .dev => |key| if (st.findDev(key)) |i| blk: {
            const d = &st.dev[i];
            const have = st.find(d.id()) != null;
            // A launcher has nothing to build: Install is a copy.
            if (d.launcher) break :blk if (have) &.{ .reinstall, .open, .edit_manifest, .copy_id } else &.{ .install, .edit_manifest, .copy_id };
            break :blk if (have) &.{ .build, .reinstall, .rebuild, .open, .edit_manifest, .copy_id } else &.{ .build, .install, .rebuild, .edit_manifest, .copy_id };
        } else &.{.refresh},
    };
}

/// Fire the detail pane's focused button.
fn fireButton(app: *App, p: *IntegrationsPane) CommandError!void {
    const st = &app.integrations;
    const buttons = buttonsFor(app, p);
    if (p.cursor >= buttons.len) return;
    switch (buttons[p.cursor]) {
        .open => switch (p.target) {
            .installed => |id| if (st.find(id)) |i| return openRow(app, manifestVirtual(i)),
            .dev => |key| if (st.findDev(key)) |d| if (st.find(st.dev[d].id())) |i| return openRow(app, manifestVirtual(i)),
            .marketplace => {},
        },
        .toggle => if (try focusedRow(app)) |i| return toggleAt(app, i),
        .edit_manifest => return showManifest(app),
        .copy_id => return copyId(app),
        .refresh => return refreshCmd(app),
        .update => if (try focusedRow(app)) |i| return updateAt(app, i),
        .uninstall => if (try focusedRow(app)) |i| return removeAt(app, i),
        .install, .reinstall => switch (p.target) {
            .marketplace => return command.run(app, .{ .static = .@"marketplace.install_focused" }),
            .dev => return devInstallCmd(app),
            .installed => {},
        },
        .build => return devBuildCmd(app),
        .rebuild => return devRebuildCmd(app),
    }
}

/// Keys in the detail pane: the arrows / h l / tab walk the buttons,
/// Enter fires, Esc / q close.
pub fn paneKey(app: *App, id: PaneId, p: *IntegrationsPane, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const n = buttonsFor(app, p).len;
    switch (k.code) {
        .left, .up, .backtab => p.cursor -|= 1,
        .right, .down, .tab => p.cursor = @min(p.cursor + 1, n -| 1),
        .home => p.cursor = 0,
        .end => p.cursor = n -| 1,
        .enter => runToast(app, fireButton(app, p)),
        .esc => try app.forceClosePane(id),
        .char => |c| switch (c) {
            'h', 'k' => p.cursor -|= 1,
            'l', 'j' => p.cursor = @min(p.cursor + 1, n -| 1),
            'q' => try app.forceClosePane(id),
            'y' => runToast(app, copyId(app)),
            'r' => runToast(app, refreshCmd(app)),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// A press on button `hit` of the detail pane.
pub fn click(app: *App, id: PaneId, p: *IntegrationsPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    _ = id;
    if (m.kind != .press or m.button != .left) return;
    if (hit_id >= buttonsFor(app, p).len) return;
    p.cursor = hit_id;
    runToast(app, fireButton(app, p));
    app.needs_render = true;
}

pub fn scrollBy(app: *App, p: *IntegrationsPane, delta: i64) void {
    const n: i64 = @intCast(buttonsFor(app, p).len);
    const cur: i64 = @intCast(p.cursor);
    p.cursor = @intCast(std.math.clamp(cur + delta, 0, @max(n - 1, 0)));
}

pub fn draw(app: *App, ui: Ui, id: PaneId, p: *IntegrationsPane, rect: Rect) Allocator.Error!void {
    const st = &app.integrations;
    const focused = app.active == id and app.focus == .pane;
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const buttons = buttonsFor(app, p);
    const labels = try ui.arena.alloc([]const u8, buttons.len);
    for (buttons, 0..) |b, i| labels[i] = b.label(app, p);
    if (p.cursor >= labels.len) p.cursor = labels.len -| 1;
    var props: view.DetailProps = .{ .label = "", .id = p.target.key(), .buttons = labels, .cursor = p.cursor, .focused = focused };
    switch (p.target) {
        .installed => |mid| if (st.find(mid)) |i| {
            const inst = &st.list[i];
            fillManifest(ui.arena, &props, inst.manifest);
            props.origin = ui.fmt("installed · {s}", .{app.relPath(inst.path)});
            props.status = if (!inst.binary_found) "binary missing" else if (!inst.enabled()) "disabled" else null;
        } else {
            props.label = mid;
            props.description = "not installed — was it uninstalled?";
        },
        .marketplace => |mid| if (marketplace.find(app, mid)) |i| {
            const e = app.marketplace.entries[i];
            props.label = e.label;
            props.version = e.version;
            props.description = e.description;
            props.glyph = e.glyph;
            props.fallback = e.fallback;
            props.color = e.color;
            props.origin = ui.fmt("marketplace · {s} ({s}){s}", .{ e.source, @tagName(e.kind), if (e.private) " · private" else if (e.official) " · official" else "" });
            props.binary = e.url;
            if (st.find(mid)) |k| {
                fillManifest(ui.arena, &props, st.list[k].manifest);
                props.status = "installed";
            }
            if (app.marketplace.installing) |cur| if (std.mem.eql(u8, cur, mid)) {
                props.status = if (ui.ascii) "installing..." else "installing…";
            };
        } else {
            props.label = mid;
            props.description = "not listed — refresh the marketplace";
        },
        .dev => |key| if (st.findDev(key)) |i| {
            const d = &st.dev[i];
            fillManifest(ui.arena, &props, d.manifest);
            props.origin = ui.fmt("dev · {s} · {s}", .{ d.root, app.relPath(if (d.launcher) d.manifest_path else d.dir) });
            if (d.launcher) {
                props.status = if (st.find(d.id()) != null) "installed from here" else "not installed";
            } else {
                const built = try devBuiltBinary(app, ui.arena, d);
                props.status = if (st.job != null and std.mem.eql(u8, st.job.?.dir, d.dir)) (if (ui.ascii) "installing..." else "installing…") else if (st.find(d.id()) != null) "installed from here" else if (isFile(app.io, built)) "built, not installed" else "not built";
            }
        } else {
            props.label = std.fs.path.basename(key);
            props.description = "not a dev folder any more — refresh";
        },
    }
    view.drawDetail(ui, id, rect, props);
}

fn fillManifest(arena: Allocator, props: *view.DetailProps, m: Manifest) void {
    props.label = m.label;
    props.id = m.id;
    props.version = m.version;
    props.category = m.category;
    props.description = m.description;
    props.binary = if (m.isLauncher()) "(a launcher — no binary; its commands run their lines)" else m.binary;
    props.mode = if (m.isLauncher()) "" else @tagName(m.mode);
    if (m.chip) |c| {
        var gbuf: [4]u8 = undefined;
        // A pinned codepoint is decoded into the frame's own bytes.
        props.glyph = if (c.glyph.len > 0) c.glyph else (arena.dupe(u8, c.glyphText(&gbuf)) catch "");
        props.fallback = c.fallback;
        props.color = c.color;
    }
    props.commands = m.commands;
    props.settings = m.settings;
    props.requires = m.requires;
    props.statusline = m.statusline;
    props.context_menu = m.context_menu;
    props.menu_bar = m.menu_bar;
}

// ─── settings ───────────────────────────────────────────────────────────

/// A stored `<id>.<key>` value, else the manifest default, else the
/// first option.
pub fn settingValue(app: *App, id: []const u8, s: manifest_mod.Setting) []const u8 {
    var kbuf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ id, s.key }) catch return s.default;
    if (app.integrations.settings.get(key)) |v| return v;
    if (s.default.len > 0) return s.default;
    return if (s.options.len > 0) s.options[0] else "";
}

/// One settings row per manifest setting, flattened across the list.
pub const SettingRef = struct { installed: usize, setting: usize };

pub fn settingRefs(app: *App, arena: Allocator) Allocator.Error![]SettingRef {
    var out: std.ArrayListUnmanaged(SettingRef) = .empty;
    for (app.integrations.list, 0..) |*inst, i| for (inst.manifest.settings, 0..) |_, k| try out.append(arena, .{ .installed = i, .setting = k });
    return out.toOwnedSlice(arena);
}

pub fn settingIndex(app: *App, ref: SettingRef) usize {
    const inst = &app.integrations.list[ref.installed];
    const s = inst.manifest.settings[ref.setting];
    const v = settingValue(app, inst.id(), s);
    for (s.options, 0..) |o, i| if (std.mem.eql(u8, o, v)) return i;
    return 0;
}

pub fn settingDefaultIndex(app: *App, ref: SettingRef) usize {
    const s = app.integrations.list[ref.installed].manifest.settings[ref.setting];
    for (s.options, 0..) |o, i| if (std.mem.eql(u8, o, s.default)) return i;
    return 0;
}

/// Set a manifest setting to its `idx`th option and write the file.
pub fn setSetting(app: *App, ref: SettingRef, idx: usize) Allocator.Error!void {
    const gpa = app.gpa;
    const inst = &app.integrations.list[ref.installed];
    const s = inst.manifest.settings[ref.setting];
    if (s.options.len == 0) return;
    const value = s.options[idx % s.options.len];
    const key = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ inst.id(), s.key });
    errdefer gpa.free(key);
    const copy = try gpa.dupe(u8, value);
    errdefer gpa.free(copy);
    if (app.integrations.settings.fetchRemove(key)) |old| {
        gpa.free(old.key);
        gpa.free(old.value);
    }
    try app.integrations.settings.put(gpa, key, copy);
    try writeSettings(app);
}

const StoredSetting = struct { key: []const u8, value: []const u8 };

fn settingsPath(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    if (app.data_root.len == 0) return null;
    return try std.fs.path.join(arena, &.{ app.data_root, settings_file });
}

fn writeSettings(app: *App) Allocator.Error!void {
    const arena = app.frame.allocator();
    const path = (try settingsPath(app, arena)) orelse {
        app.toast("nowhere to save integration settings (no data root)", .{});
        return;
    };
    var rows: std.ArrayListUnmanaged(StoredSetting) = .empty;
    var it = app.integrations.settings.iterator();
    while (it.next()) |e| try rows.append(arena, .{ .key = e.key_ptr.*, .value = e.value_ptr.* });
    std.mem.sort(StoredSetting, rows.items, {}, struct {
        fn less(_: void, a: StoredSetting, b: StoredSetting) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);
    var out: Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// Integration settings, one per `<integration>.<key>`; the settings overlay writes this.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(rows.items, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(path).?) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() }) catch |err| {
        app.toast("could not write {s}: {s}", .{ path, @errorName(err) });
    };
}

/// Read `<data root>/integration-settings.zon` into `settings`.
pub fn loadSettings(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const path = (try settingsPath(app, arena)) orelse return;
    const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(1 << 20), .of(u8), 0) catch return;
    const rows = std.zon.parse.fromSliceAlloc([]StoredSetting, arena, text, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            try app.toastLevel(.warn, "integration settings: {s} did not parse", .{path});
            return;
        },
    };
    for (rows) |r| {
        const key = try gpa.dupe(u8, r.key);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, r.value);
        errdefer gpa.free(value);
        if (app.integrations.settings.fetchRemove(key)) |old| {
            gpa.free(old.key);
            gpa.free(old.value);
        }
        try app.integrations.settings.put(gpa, key, value);
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const build_options = @import("build_options");
const screen_mod = @import("../ipc/screen.zig");

const fixture_manifest =
    \\.{
    \\    .id = "hello",
    \\    .label = "Hello",
    \\    .description = "The sample",
    \\    .version = "0.1.0",
    \\    .binary = "/definitely/not/here/mnml-hello",
    \\    .category = "sample",
    \\    .chip = .{ .glyph = "H", .fallback = "H", .color = "cyan", .tooltip = "Hello" },
    \\    .commands = .{
    \\        .{ .id = "hello.open", .title = "Hello: open", .keys = .{ "ctrl+k h" } },
    \\        .{ .id = "hello.shell", .title = "Hello: shell", .ex = "term true" },
    \\    },
    \\    .statusline = .{ .{ .id = "chip", .text = "H·1", .click_command = "hello.open" } },
    \\    .settings = .{ .{ .key = "greeting", .label = "Greeting", .options = .{ "HELLO", "HOWDY" }, .default = "HELLO" } },
    \\}
    \\
;

fn testApp(tmp: *testing.TmpDir) !App {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "integrations");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/hello.zon", .data = fixture_manifest });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/broken.zon", .data = ".{ .id = " });
    try tmp.dir.createDirPath(testing.io, "ws");
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    return App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 24 });
}

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(testing.allocator, &app.screen);
}

test "discovery: manifests become dyn commands with bindings; a broken file is a warning; refresh is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try refresh(&app);
    const st = &app.integrations;
    try testing.expectEqual(@as(usize, 1), st.list.len);
    try testing.expectEqualStrings("hello", st.list[0].id());
    try testing.expect(!st.list[0].binary_found);
    try testing.expectEqual(@as(usize, 2), st.list[0].slots.len);
    try testing.expectEqual(@as(usize, 1), st.problems.len);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "broken.zon") != null);
    // The commands resolve by name and the key binds.
    const ref = command.resolve(&app, "hello.open").?;
    try testing.expect(ref == .dyn);
    const dc = app.dyn_commands.at(ref.dyn).?;
    try testing.expect(dc.runner == .mount);
    try testing.expectEqualStrings("/definitely/not/here/mnml-hello", dc.runner.mount.binary);
    try testing.expect(dc.owner == .integration);
    var kbuf: [@import("../core/keymap.zig").max_seq]key_mod.Chord = undefined;
    const seq = @import("../core/keymap.zig").parseKeySeqBuf("ctrl+k h", &kbuf).?;
    try testing.expect(app.keymap.resolveSeq(seq) != .none);
    // The ex-backed command reaches the interpreter.
    try testing.expect(command.resolve(&app, "hello.shell").?.dyn != ref.dyn);
    // Running the mount command with a missing binary fails with a diag, not a pane.
    try testing.expectError(error.Failed, command.run(&app, ref));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "cannot run") != null);
    try testing.expectEqual(@as(usize, 0), app.panes.count());
    // A second scan does not double-register or leak the old bindings.
    try refresh(&app);
    try testing.expectEqual(@as(usize, 1), st.list.len);
    try testing.expect(command.resolve(&app, "hello.open") != null);
    try testing.expect(app.keymap.resolveSeq(seq) != .none);
    // Chips: the config's browser icon plus the manifest's, with the order honored.
    const c = try chips(&app, app.frame.allocator());
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqualStrings("browser", c[0].id);
    try testing.expectEqualStrings("hello", c[1].id);
    try testing.expect(!c[1].enabled); // the binary is missing
    // A missing binary sets no statusline segment.
    try testing.expect(app.ipc_fx.find("hello.chip") == null);
}

test "a `\\$VAR` binary resolves through the environment; a runnable manifest's statusline entry is a segment, gone on uninstall" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "integrations");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tool", .data = "#!/bin/sh\n" });
    const with_var = try std.mem.replaceOwned(u8, testing.allocator, fixture_manifest, "/definitely/not/here/mnml-hello", "$HELLO_BIN");
    defer testing.allocator.free(with_var);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/hello.zon", .data = with_var });
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const tool = try std.fs.path.join(testing.allocator, &.{ root, "tool" });
    defer testing.allocator.free(tool);
    try env.put("HELLO_BIN", tool);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 24, .env = &env });
    defer app.deinit();
    try refresh(&app);
    try testing.expect(app.integrations.list[0].binary_found);
    try testing.expectEqualStrings(tool, resolveBinary(&app, app.frame.allocator(), "$HELLO_BIN").?);
    try testing.expect(resolveBinary(&app, app.frame.allocator(), "$NOPE_BIN") == null);
    const seg = app.ipc_fx.find("hello.chip").?;
    try testing.expectEqualStrings("H·1", app.ipc_fx.segments.items[seg].text);
    try testing.expectEqualStrings("hello.open", app.ipc_fx.segments.items[seg].click_command.?);
    // The statusline paints it.
    const txt = try screenText(&app);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "H·1") != null);
    // Uninstall: the segment, the command and the chip go with the file.
    try removeAccept(&app, "hello");
    try testing.expect(app.ipc_fx.find("hello.chip") == null);
    try testing.expect(command.resolve(&app, "hello.open") == null);
    try testing.expectEqual(@as(usize, 1), (try chips(&app, app.frame.allocator())).len);
}

test "toggle_enabled rewrites the manifest and the list follows; remove deletes it after a confirm" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try refresh(&app);
    try testing.expect(app.integrations.list[0].enabled());
    try toggleAt(&app, 0);
    try testing.expect(!app.integrations.list[0].enabled());
    const text = try tmp.dir.readFileAlloc(testing.io, "integrations/hello.zon", testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".enabled = false") != null);
    try toggleAt(&app, 0);
    try testing.expect(app.integrations.list[0].enabled());
    // Remove: the confirm box, then the file goes.
    try removeAt(&app, 0);
    try testing.expect(app.overlay == .confirm);
    try testing.expect(app.overlay.confirm.purpose == .remove_integration);
    try removeAccept(&app, "hello");
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "integrations/hello.zon", .{}));
    try testing.expect(command.resolve(&app, "hello.open") == null);
}

test "settings: a manifest setting reads its default, persists a choice, and reaches the child's env" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try refresh(&app);
    const refs = try settingRefs(&app, app.frame.allocator());
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqual(@as(usize, 0), settingIndex(&app, refs[0]));
    try setSetting(&app, refs[0], 1);
    try testing.expectEqual(@as(usize, 1), settingIndex(&app, refs[0]));
    const env = try settingsEnv(&app, app.frame.allocator(), "hello");
    try testing.expectEqualStrings("MNML_SETTING_GREETING", env[0].name);
    try testing.expectEqualStrings("HOWDY", env[0].value);
    // A fresh app reads the file back.
    var app2 = try App.initWith(testing.allocator, testing.io, .{ .workspace = app.workspace, .data_root = app.data_root, .cols = 80, .rows = 10 });
    defer app2.deinit();
    try refresh(&app2);
    try testing.expectEqual(@as(usize, 1), settingIndex(&app2, refs[0]));
}

test "the section: Installed lists the manifest in the Rust row shape, the tabs switch, the keys act on the cursor, the detail pane opens" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    app.tree.width = 44; // the column these rows read; the pane keeps its buttons row
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    try testing.expect(side.isShown(&app, .integrations));
    try testing.expect(app.focus == .panel and app.focus.panel == .integrations);
    var txt = try screenText(&app);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "INTEGRATIONS") != null);
    // Four first-party rows plus the one manifest.
    try testing.expect(std.mem.indexOf(u8, txt, "Installed (5)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Browser  first-party") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "browser.open") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Claude Code (hidden)  first-party") != null);
    // The manifest is the fifth row; the column holds three entries, so
    // it takes the cursor to scroll into view.
    app.integrations.panel.cursor = first_party.len;
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "H Hello (mnml-hello not installed)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "hello.open") != null);
    // `tab` walks to the marketplace (no fetch without a source that answers — the empty state).
    try testing.expect(try handleKey(&app, .{ .code = .tab }));
    try testing.expectEqual(Tab.marketplace, app.integrations.tab);
    try testing.expect(try handleKey(&app, .{ .code = .backtab }));
    try testing.expectEqual(Tab.installed, app.integrations.tab);
    // `y` copies the id; `d` opens the detail pane with its buttons —
    // both on the manifest row, which the first-party block sits above.
    try testing.expect(try handleKey(&app, .{ .code = .{ .char = 'y' } }));
    try testing.expectEqualStrings("hello", app.clipboard.text());
    try testing.expect(try handleKey(&app, .{ .code = .{ .char = 'd' } }));
    const id = app.panes.findKind(.integrations).?;
    try testing.expectEqualStrings("hello", app.panes.get(id).?.title());
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "[ Open ]  [ Disable ]  [ Edit manifest ]") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "hello.open  Hello: open  ctrl+k h") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "binary missing") != null);
    // The pane's keys: `l` to Disable, Enter fires it.
    const p = &app.panes.get(id).?.integrations;
    try testing.expect(try paneKey(&app, id, p, .{ .code = .{ .char = 'l' } }));
    try testing.expect(try paneKey(&app, id, p, .{ .code = .enter }));
    try testing.expect(!app.integrations.list[0].enabled());
    // The filter narrows to nothing and says so.
    app.integrations.panel.filter_focused = true;
    try testing.expect(try handleKey(&app, .{ .code = .{ .char = 'z' } }));
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "No matches for \"z\"") != null);
}

test "dev roots: the repo's integrations/ is scanned when sdk/mnml-sdk exists, a configured root too; a folder without a manifest is skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws/sdk/mnml-sdk");
    try tmp.dir.createDirPath(testing.io, "ws/integrations/sample");
    try tmp.dir.createDirPath(testing.io, "ws/integrations/nomanifest");
    try tmp.dir.createDirPath(testing.io, "elsewhere/other");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/integrations/sample/build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/integrations/nomanifest/build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/integrations/sample/manifest.zon", .data = ".{ .id = \"sample\", .label = \"Sample\", .binary = \"mnml-sample\", .description = \"A counter\" }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "elsewhere/other/build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "elsewhere/other/manifest.zon", .data = ".{ .id = \"other\", .label = \"Other\", .binary = \"mnml-other\" }" });
    // The checkout's launchers/: a bare manifest is a launcher entry; one
    // naming a binary is a problem, not a row.
    try tmp.dir.createDirPath(testing.io, "ws/launchers");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/launchers/htop.zon", .data = ".{ .id = \"htop\", .label = \"htop\", .description = \"Process viewer\", .chip = .{ .glyph_codepoint = \"F1D00\", .fallback = \"H\" }, .commands = .{ .{ .id = \"htop.open\", .title = \"htop: open\", .run = \":term htop\" } } }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/launchers/stray.zon", .data = ".{ .id = \"stray\", .label = \"Stray\", .binary = \"mnml-stray\" }" });
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var cfg: config.Config = .{};
    cfg.integrations.dev_roots = &.{"../elsewhere"};
    var app = try App.initWith(testing.allocator, testing.io, .{ .cfg = cfg, .workspace = ws, .data_root = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    // Entering the section on any tab scans the roots: the strip's Dev
    // count is right before the tab is ever opened.
    const st = &app.integrations;
    try testing.expect(!st.dev_scanned);
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    try testing.expect(st.dev_scanned);
    try testing.expectEqual(@as(usize, 3), st.dev.len);
    try testing.expectEqualStrings("htop", st.dev[0].id());
    try testing.expectEqualStrings("launchers", st.dev[0].root);
    try testing.expect(st.dev[0].launcher);
    try testing.expect(std.mem.endsWith(u8, st.dev[0].key(), "launchers/htop.zon"));
    try testing.expectEqualStrings("other", st.dev[1].id());
    try testing.expectEqualStrings("elsewhere", st.dev[1].root);
    try testing.expectEqualStrings("sample", st.dev[2].id());
    try testing.expectEqualStrings("integrations", st.dev[2].root);
    try testing.expectEqual(@as(usize, 1), st.dev_problems.len);
    try testing.expect(std.mem.indexOf(u8, st.dev_problems[0], "stray.zon: names a binary") != null);
    try testing.expect(showDev(&app));
    // The Dev tab paints them with their state.
    app.tree.width = 60;
    try command.run(&app, .{ .static = .@"integrations.show_in_dev" });
    try testing.expectEqual(Tab.dev, st.tab);
    var txt = try screenText(&app);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "[dev] Other  not installed  (elsewhere)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[dev] Sample  not installed  (integrations)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "integrations/sample") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "\u{F1D00}  [dev] htop  not installed  (launchers)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "launchers/htop.zon") != null);
    // Nothing built: the built binary is the folder's zig-out.
    const built = try devBuiltBinary(&app, app.frame.allocator(), &st.dev[2]);
    try testing.expect(std.mem.endsWith(u8, built, "integrations/sample/zig-out/bin/mnml-sample"));
    // `i` on the launcher row: no build, no task pane — the file is
    // copied into the data root and the row says so.
    st.panel.cursor = 0;
    try testing.expect(try handleKey(&app, .{ .code = .{ .char = 'i' } }));
    try testing.expect(st.job == null);
    try testing.expectEqual(@as(usize, 0), app.panes.count());
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "installed htop") != null);
    try testing.expectEqual(@as(usize, 1), st.list.len);
    try testing.expect(st.list[0].manifest.isLauncher());
    try tmp.dir.access(testing.io, "integrations/htop.zon", .{});
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "[dev] htop  installed from here  (launchers)") != null);
    // Build has nothing to do for a launcher.
    try testing.expectError(error.Failed, devBuild(&app, 0));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "nothing to build") != null);
    // Its detail pane: Reinstall, no Build; the binary line says what it is.
    try openDetail(&app, .{ .dev = st.dev[0].key() });
    testing.allocator.free(txt);
    // The scan's problem toast (a long path, wrapped) would cover the
    // detail pane's last rows: read the pane without it.
    app.dismissToasts();
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "[ Reinstall ]  [ Open ]") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[ Build ]") == null);
    try testing.expect(std.mem.indexOf(u8, txt, "installed from here") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "a launcher — no binary") != null);
}

/// Poll `tick` until `pred` holds or `ms` elapse.
fn waitFor(app: *App, ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 10) {
        try app.tick(App.nowMs(app.io));
        if (pred(ctx)) return;
        app.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOut;
}

test "install from a dev folder: the prebuilt sample's --install runs in a task pane, the binary is linked, the manifest lands with its chip, command and segment; uninstall removes all of it" {
    if (!pty_pane.supported) return error.SkipZigTest;
    const exe = build_options.sample_integration_exe;
    Io.Dir.cwd().access(testing.io, exe, .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws/dev/sample");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/dev/sample/build.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/dev/sample/manifest.zon", .data = ".{ .id = \"sample\", .label = \"Sample\", .binary = \"$MNML_SAMPLE_INTEGRATION\" }" });
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("MNML_SAMPLE_INTEGRATION", exe);
    var cfg: config.Config = .{};
    cfg.integrations.dev_roots = &.{"dev"};
    var app = try App.initWith(testing.allocator, testing.io, .{ .cfg = cfg, .workspace = ws, .data_root = root, .cols = 100, .rows = 24, .env = &env });
    defer app.deinit();
    app.tree.width = 60;
    try command.run(&app, .{ .static = .@"integrations.show_in_dev" });
    try testing.expectEqual(@as(usize, 1), app.integrations.dev.len);
    // `i` on the Dev tab: the binary is already built (the env names it), so only --install runs.
    try testing.expect(try handleKey(&app, .{ .code = .{ .char = 'i' } }));
    try testing.expect(app.integrations.job != null);
    const Done = struct {
        fn done(a: *App) bool {
            return a.integrations.job == null;
        }
    };
    try waitFor(&app, 20_000, &app, Done.done);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "installed sample") != null);
    const st = &app.integrations;
    try testing.expectEqual(@as(usize, 1), st.list.len);
    try testing.expectEqualStrings("sample", st.list[0].id());
    try testing.expect(st.list[0].binary_found); // through <root>/bin/mnml-sample
    try testing.expect(command.resolve(&app, "sample.open") != null);
    try testing.expect(command.resolve(&app, "sample.hello") != null);
    try testing.expect(app.ipc_fx.find("sample.chip") != null);
    const c = try chips(&app, app.frame.allocator());
    try testing.expectEqualStrings("sample", c[c.len - 1].id);
    try testing.expect(c[c.len - 1].enabled);
    // The Dev tab now says so; the Installed tab lists it.
    var txt = try screenText(&app);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "[dev] Sample  installed from here  (dev)") != null);
    setTab(&app, .installed);
    // The four first-party rows sit above the manifests: put the cursor
    // on the new row so the short test column scrolls to it.
    app.integrations.panel.cursor = first_party.len;
    testing.allocator.free(txt);
    txt = try screenText(&app);
    try testing.expect(std.mem.indexOf(u8, txt, "Sample  0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "sample.open") != null);
    // The ex-backed command toasts.
    try command.runNamed(&app, "sample.hello");
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "Hello from the sample integration") != null);
    // Uninstall: everything goes.
    try removeAccept(&app, "sample");
    try testing.expectEqual(@as(usize, 0), st.list.len);
    try testing.expect(command.resolve(&app, "sample.open") == null);
    try testing.expect(app.ipc_fx.find("sample.chip") == null);
    try testing.expect(app.integrations.find("sample") == null);
}

test "a workspace manifest waits for trust: skipped while the workspace is untrusted, registered once it is trusted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws/.mnml/integrations");
    const ws_manifest = std.mem.replaceOwned(u8, testing.allocator, fixture_manifest, "hello", "wsonly") catch unreachable;
    defer testing.allocator.free(ws_manifest);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.mnml/integrations/wsonly.zon", .data = ws_manifest });
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .cols = 100, .rows = 20, .workspace_trusted = false });
    defer app.deinit();
    try refresh(&app);
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expect(command.resolve(&app, "wsonly.open") == null);
    // The trust decision lands: the scan takes the manifest.
    app.workspace_trusted = true;
    try refresh(&app);
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expectEqualStrings("wsonly", app.integrations.list[0].id());
    try testing.expect(command.resolve(&app, "wsonly.open") != null);
    // The claim the dialog lists: one per file.
    const facts_names = try @import("../config/trust.zig").manifestNames(app.frame.allocator(), app.io, ws);
    try testing.expectEqual(@as(usize, 1), facts_names.len);
    try testing.expectEqualStrings("wsonly.zon", facts_names[0]);
}

test "a workspace launcher waits for trust too: a cloned repo's `run` line is not registered until the workspace is trusted, and never fires before" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws/.mnml/integrations");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.mnml/integrations/evil.zon", .data = ".{ .id = \"evil\", .label = \"Evil\", .commands = .{ .{ .id = \"evil.run\", .title = \"Evil: run\", .keys = .{ \"ctrl+k e\" }, .run = \":term /tmp/evil.sh {{workspace}}\" } } }" });
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 20, .workspace_trusted = false });
    defer app.deinit();
    try refresh(&app);
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expect(command.resolve(&app, "evil.run") == null);
    try testing.expectError(error.Failed, command.runNamed(&app, "evil.run"));
    try testing.expectEqual(@as(usize, 0), app.panes.count());
    try testing.expectEqual(@as(usize, 0), (try chips(&app, app.frame.allocator())).len - 1); // the browser icon only
    // Trusted: the launcher registers, its chord binds.
    app.workspace_trusted = true;
    try refresh(&app);
    try testing.expectEqual(@as(usize, 1), app.integrations.list.len);
    try testing.expect(app.integrations.list[0].manifest.isLauncher());
    try testing.expectEqual(Source.workspace, app.integrations.list[0].source);
    try testing.expect(command.resolve(&app, "evil.run") != null);
}

test "0.2 .toml manifests: counted, never read, one notice toast per launch, the Installed empty state names them; Don't show again persists ui.integrations_toml_notice_shown and the files stay" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "integrations");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/amplify.toml", .data = "[integration]\nid = \"amplify\"\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/codex.override.toml", .data = "[integration]\nid = \"codex\"\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "integrations/amplify.toml.bak-1", .data = "" });
    try tmp.dir.createDirPath(testing.io, "ws");
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 24 });
    defer app.deinit();
    try refresh(&app);
    const st = &app.integrations;
    try testing.expectEqual(@as(usize, 0), st.list.len);
    try testing.expectEqual(@as(usize, 2), st.toml_count); // the .bak is not a manifest
    const first = app.lastToast() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("2 integrations from mnml 0.2 are not loaded — 0.3 integrations install from the Marketplace", first);
    try testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    // The Installed tab is never empty — the four first-party rows are
    // always on it — so the notice's panel surface is the toast, which
    // stands while the tab is opened.
    try showInstalled(&app);
    const text = try screenText(&app);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Inst (4)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 integrations from mnml 0.2") != null);
    // A second scan this launch says nothing more.
    try refresh(&app);
    try testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    // Don't show again: the flag written, the toast gone, the line gone,
    // the files untouched.
    try command.run(&app, .{ .static = .@"integrations.dismiss_toml_notice" });
    try testing.expect(app.cfg.ui.integrations_toml_notice_shown);
    for (app.toasts.items) |t| try testing.expect(t.id == null or !std.mem.eql(u8, t.id.?, toml_toast_id));
    const home = try tmp.dir.readFileAlloc(testing.io, "config.zon", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(home);
    try testing.expect(std.mem.indexOf(u8, home, "integrations_toml_notice_shown = true") != null);
    const after = try screenText(&app);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "from mnml 0.2") == null);
    try tmp.dir.access(testing.io, "integrations/amplify.toml", .{});
    try tmp.dir.access(testing.io, "integrations/codex.override.toml", .{});
    // A fresh launch on this data root: nothing said.
    app.integrations.toml_noticed = false;
    app.dismissToasts();
    try refresh(&app);
    try testing.expectEqual(@as(usize, 0), app.toasts.items.len);
}

// ─── the first-party rows ───────────────────────────────────────────────

test "the table: four rows in Rust's order, every glyph with a fallback, and `ui.integration_icons` mirroring it" {
    try testing.expectEqual(@as(usize, 4), first_party.len);
    const ids = [_][]const u8{ "browser", "claude_code", "codex", "http" };
    for (first_party, ids, 0..) |fp, id, i| {
        try testing.expectEqualStrings(id, fp.id);
        try testing.expectEqual(i, firstPartyIndex(id).?);
        // Every row is reachable: a command, a label, a glyph, and the
        // `--ascii` twin `glyph-audit` insists on.
        try testing.expect(fp.command.len > 0);
        try testing.expect(fp.label.len > 0);
        try testing.expect(fp.glyph.len > 0);
        try testing.expect(fp.fallback.len > 0);
        try testing.expect(command.by_name.get(fp.command) != null);
    }
    try testing.expect(firstPartyIndex("nope") == null);
    // Claude's brand orange is a literal, not a theme role, and it is
    // spelled in exactly one place.
    try testing.expectEqualStrings("#D97757", first_party[1].color);
    try testing.expectEqualStrings(@import("../ui/brand.zig").claude_hex, first_party[1].color);
    // The config array is the storage for the same four, field for field.
    const icons = config.Config.default_integration_icons;
    try testing.expectEqual(first_party.len, icons.len);
    for (first_party, icons) |fp, ic| {
        try testing.expectEqualStrings(fp.id, ic.id);
        try testing.expectEqualStrings(fp.glyph, ic.glyph);
        try testing.expectEqualStrings(fp.fallback, ic.fallback);
        try testing.expectEqualStrings(fp.command, ic.command);
        try testing.expectEqualStrings(fp.color, ic.color);
        try testing.expectEqualStrings(fp.label, ic.label.?);
        try testing.expectEqual(fp.enabled, ic.enabled);
        try testing.expectEqual(fp.in_palette_bar, ic.in_palette_bar);
    }
    // The index space: the four, then the manifests.
    try testing.expectEqual(@as(usize, 0), installedRow(0).first_party);
    try testing.expectEqual(@as(usize, 3), installedRow(3).first_party);
    try testing.expectEqual(@as(usize, 0), installedRow(4).manifest);
    try testing.expectEqual(@as(usize, 4), manifestVirtual(0));
}

test "a fresh data root: the four rows are on the Installed tab at the SHIPPED column width, sorted first whatever the sort chip says" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws");
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    // `ui.tree_width` is 30 out of the box, which leaves the column 26
    // cells — the width the badge has to survive.
    try testing.expectEqual(@as(u16, 30), app.tree.width);
    const txt = try screenText(&app);
    defer testing.allocator.free(txt);
    // Nothing is installed, and the tab is still not empty.
    try testing.expectEqual(@as(usize, 0), app.integrations.list.len);
    try testing.expect(std.mem.indexOf(u8, txt, "Inst (4)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Nothing installed yet") == null);
    // 26 cells: the short label leaves room for the whole badge; the
    // long ones clip it, the way every badge of this section clips
    // (`scripts_marketplace_default.test` pins the same for `✓ Offi…`).
    try testing.expect(std.mem.indexOf(u8, txt, "Browser  first-party") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Codex (hidden)  first-") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "browser.open") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Claude Code (hidden)") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "not logged in") != null);
    const rows = try visibleEntries(&app, app.frame.allocator());
    try testing.expectEqual(@as(usize, 4), rows.len);
    // Z–A does not shuffle them: they are the editor's own surfaces, not
    // entries competing for a place in the list.
    try setSort(&app, InstalledSort.name_desc.toList());
    const desc = try visibleEntries(&app, app.frame.allocator());
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, desc);
    // The filter still narrows them, on the label, the id or the command.
    try setSort(&app, InstalledSort.name.toList());
    try app.handle(.{ .key = app_mod.Key.char('/') });
    for ("codex") |c| try app.handle(.{ .key = app_mod.Key.char(c) });
    const one = try visibleEntries(&app, app.frame.allocator());
    try testing.expectEqualSlices(usize, &.{2}, one);
}

test "the row menus: Claude's sessions, usage, login and profiles; Browser's and HTTP's own; every command id resolves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    const Want = struct { row: usize, title: []const u8, first: []const u8, sub: bool };
    const wants = [_]Want{
        .{ .row = 0, .title = "Browser", .first = "Open", .sub = false },
        .{ .row = 1, .title = "Claude Code", .first = "New session", .sub = true },
        .{ .row = 2, .title = "Codex", .first = "New session", .sub = true },
        .{ .row = 3, .title = "HTTP", .first = "New request", .sub = false },
    };
    for (wants) |w| {
        try rowMouse(&app, @intCast(w.row), .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
        const m = &app.overlay.menu;
        try testing.expectEqualStrings(w.title, m.title);
        try testing.expectEqualStrings(w.first, m.items[0].label);
        try testing.expectEqual(w.sub, m.items[0].submenu.len > 0);
        // Every row goes somewhere real, submenu rows included.
        for (m.items) |it| {
            switch (it.action) {
                .command => |id| try testing.expect(command.by_name.get(command.name(id)) != null),
                .ai_profile, .none => {},
                else => return error.TestUnexpectedResult,
            }
            for (it.submenu) |sub| switch (sub.action) {
                .ai_profile => {},
                else => return error.TestUnexpectedResult,
            };
        }
        // The two preference rows close every menu.
        const last = m.items[m.items.len - 1];
        const prev = m.items[m.items.len - 2];
        try testing.expectEqual(command.CommandId.@"integrations.toggle_palette_bar", last.action.command);
        try testing.expectEqual(command.CommandId.@"integrations.toggle_enabled", prev.action.command);
        try app.handle(.{ .key = app_mod.Key.named(.esc) });
    }
    // Claude's rows in full; Codex has no login of its own.
    try rowMouse(&app, 1, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    const claude = try labelsOf(&app, app.frame.allocator());
    try testing.expectEqualStrings("Usage", claude[1]);
    try testing.expectEqualStrings("Login", claude[2]);
    try testing.expectEqualStrings("Configure profiles…", claude[3]);
    try testing.expectEqual(command.CommandId.@"ai.claude_usage", app.overlay.menu.items[1].action.command);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try rowMouse(&app, 2, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    const codex = try labelsOf(&app, app.frame.allocator());
    try testing.expectEqualStrings("Usage", codex[1]);
    try testing.expectEqualStrings("Configure profiles…", codex[2]);
    try testing.expectEqual(command.CommandId.@"ai.codex_usage", app.overlay.menu.items[1].action.command);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // The manifest row keeps the menu it had, one place further down.
    try rowMouse(&app, first_party.len, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
    try testing.expectEqualStrings("Hello", app.overlay.menu.title);
    try testing.expectEqualStrings("Details", app.overlay.menu.items[0].label);
}

fn labelsOf(app: *App, arena: Allocator) Allocator.Error![][]const u8 {
    const items = app.overlay.menu.items;
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |it, i| out[i] = it.label;
    return out;
}

test "the two preferences persist to the home config and come back on the next launch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, "ws");
    const ws = try std.fs.path.join(testing.allocator, &.{ root, "ws" });
    defer testing.allocator.free(ws);
    {
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 40 });
        defer app.deinit();
        try command.run(&app, .{ .static = .@"integrations.show_installed" });
        try testing.expect(!fpEnabled(&app, 1)); // claude_code, off out of the box
        try testing.expect(!fpOnBar(&app, 1));
        // Enable + show, from the row the menu was opened on.
        try rowMouse(&app, 1, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
        try command.run(&app, .{ .static = .@"integrations.toggle_enabled" });
        try testing.expect(fpEnabled(&app, 1));
        try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "claude_code: enabled") != null);
        try rowMouse(&app, 1, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
        try command.run(&app, .{ .static = .@"integrations.toggle_palette_bar" });
        try testing.expect(fpOnBar(&app, 1));
        // The chip cluster follows: it is on the bar now, and the other
        // three are not.
        const bar = try chips(&app, app.frame.allocator());
        var seen = false;
        for (bar) |c| if (std.mem.eql(u8, c.id, "claude_code")) {
            seen = true;
            try testing.expect(c.enabled);
        };
        try testing.expect(seen);
        // Off again, and the row's `(hidden)` comes back.
        try rowMouse(&app, 1, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
        try command.run(&app, .{ .static = .@"integrations.toggle_enabled" });
        try testing.expect(!fpEnabled(&app, 1));
        try rowMouse(&app, 1, .{ .kind = .press, .button = .right, .x = 5, .y = 5 });
        try command.run(&app, .{ .static = .@"integrations.toggle_enabled" });
    }
    const home = try tmp.dir.readFileAlloc(testing.io, "config.zon", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(home);
    try testing.expect(std.mem.indexOf(u8, home, ".integration_icons = ") != null);
    try testing.expect(std.mem.indexOf(u8, home, "claude_code") != null);
    // A fresh launch on the same data root reads the file back — through
    // the real loader, which is the half a written-and-never-parsed
    // literal would fail.
    const home_path = try std.fs.path.join(testing.allocator, &.{ root, "config.zon" });
    defer testing.allocator.free(home_path);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const loaded = try @import("../config/load.zig").load(testing.allocator, testing.io, .{ .explicit = home_path, .workspace = ws, .trust = .trusted, .env = .{ .vars = &env } });
    var next = try App.initWith(testing.allocator, testing.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = root, .cols = 100, .rows = 40 });
    defer next.deinit();
    try testing.expectEqual(@as(usize, 4), next.cfg.ui.integration_icons.len);
    try testing.expect(fpEnabled(&next, 1));
    try testing.expect(fpOnBar(&next, 1));
    try testing.expect(fpEnabled(&next, 0)); // browser stays on
    try testing.expect(!fpEnabled(&next, 2)); // codex untouched
}

test "Enter on a first-party row runs its command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(&tmp);
    defer app.deinit();
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    // A frame first: the panel learns how many rows it has, which is
    // what Enter walks.
    try app.render();
    app.integrations.panel.cursor = 3; // HTTP
    try testing.expect(try handleKey(&app, .{ .code = .enter }));
    try testing.expect(side.isShown(&app, .http));
}
