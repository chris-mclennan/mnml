//! The pane's hit map — what the frame's cells mean to a click, written
//! by the painter in the same statement as the cells (the shape of
//! mnml's own `ui/hit.zig`). A target covers exactly what it paints: a
//! row is its row, a chip its cells, a chevron its one cell, a picker
//! entry its line. Dispatch is one lookup; the last thing painted wins,
//! so an overlay drawn after the body takes the click.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sdk = @import("mnml_sdk");
const keymap = @import("keymap.zig");

pub const Rect = sdk.pane.Rect;

/// The header and toolbar chips. One enum for both families' toolbars.
pub const Chip = enum {
    refresh,
    help,
    basic,
    jql,
    /// A `jql_editable` tab's `E` chip — the vars editor's door.
    vars,
    search,
    assignee,
    type,
    status,
    fixv_pill,
    fixv_remove,
    board,
    sprint,
    version,
    epic,
    label,
    quick_filters,
    unassigned,
    overflow,
    settings,
    /// The header's API budget chip (`sdk.budget`): a click stops
    /// waiting out a 429's pause; the hover is the budget in full.
    budget,
};

pub const PrButton = enum { review, merge, open };

pub const Target = union(enum) {
    /// A list / tree row, by its index in the row list.
    row: u32,
    /// The row's chevron — folds without selecting the row's URL.
    chevron: u32,
    /// A `Show all N PRs` row.
    show_more: u32,
    /// The listing's trailing `Show older (…)` row — one press widens
    /// the tab's date window a step.
    show_older: u32,
    /// A build line under a pull request. Its own target rather than
    /// the row's, because the only thing a build line stands for is
    /// that run's page: a click on it goes there, the same as the
    /// forge pane's (`sdk.pane.buildHit`).
    build_line: u32,
    /// A `[ Review ]` / `[ Merge ]` / `[ Open ]` chip on a PR row.
    pr_button: struct { row: u32, which: PrButton },
    /// A DIM `[ Merge ]`. It paints but is not a `pr_button`, so a
    /// stray click cannot merge anything — this target only lets a
    /// hover (or a click) say which condition fails.
    merge_blocked: u32,
    /// The merge confirm's two chips and its body.
    confirm_ok,
    confirm_cancel,
    confirm_body,
    /// An action button on a ticket row / card.
    action: struct { issue: u32, button: u8 },
    tab: u8,
    chip: Chip,
    /// An avatar in the kanban toolbar's cluster, by cache index.
    avatar: u32,
    /// The filter pill.
    filter,
    /// A kanban card's body / chevron, by ticket index.
    card: u32,
    card_chevron: u32,
    /// A kanban column's body, for the wheel.
    column: u8,
    /// A picker's rows and its box.
    picker_row: u32,
    picker_body,
    /// The detail modal's close chip and body.
    modal_close,
    modal_body,
    /// The vars editor: a line, its `save` chip, and the box itself.
    vars_row: u32,
    vars_save,
    vars_close,
    vars_body,
    /// The JQL editor's text: the cell index the click maps to.
    jql_text: struct { col: u16, row: u16 },
    jql_body,
    /// The key sheet.
    help_body,
    /// The detail pane's body (the wheel scrolls it), its `\u{d7}` and
    /// its scrollbar (a press or a drag on the track scrolls it).
    detail,
    detail_close,
    detail_bar,
    /// The list's own scrollbar. The whole track is one hit, so a
    /// press or a drag on it turns back into a position, the same way
    /// the detail panel's does.
    list_bar,
    /// A `key label` entry of the hint row, and a row of the key sheet:
    /// clicking either runs what the key runs.
    hint: keymap.Action,
    help_row: keymap.Action,
    /// The comment editor.
    comment,
};

/// The map itself is the SDK's (`sdk.pane.HitMap`), generic over the
/// targets above — one implementation shared with every other mnml
/// integration, so "the last thing painted wins" means the same thing
/// in every pane.
pub const Map = sdk.pane.HitMap(Target);
pub const Entry = Map.Entry;

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "jira's targets over the SDK's map: the last thing painted wins, an empty rect is never a target" {
    var m: Map = .{};
    defer m.deinit(testing.allocator);
    try m.add(testing.allocator, .{ .x = 0, .y = 2, .w = 40, .h = 1 }, .{ .row = 1 });
    try m.add(testing.allocator, .{ .x = 4, .y = 2, .w = 1, .h = 1 }, .{ .chevron = 1 });
    try m.add(testing.allocator, .{ .x = 0, .y = 3, .w = 0, .h = 1 }, .{ .row = 2 });
    try testing.expectEqual(Target{ .chevron = 1 }, m.at(4, 2).?);
    try testing.expectEqual(Target{ .row = 1 }, m.at(5, 2).?);
    try testing.expect(m.at(5, 3) == null);
    try testing.expect(m.at(39, 2) != null and m.at(40, 2) == null);
    try testing.expectEqual(@as(u16, 4), m.rectOf(.{ .chevron = 1 }).?.x);
    try testing.expect(m.rectOf(.{ .row = 9 }) == null);
    try testing.expectEqual(@as(usize, 2), m.count());
    m.reset();
    try testing.expect(m.at(5, 2) == null);
}
