//! Hover help for a pane's elements — what the host's info view says
//! when the pointer rests on a chip, a row or a button, sent up with
//! `Mount.hover` (`wire.SiblingMessage.hover`).
//!
//! A mounted pane paints every one of its cells, so the host cannot
//! know that the thing under the pointer is an `assignee:` chip rather
//! than a row; only the pane can. The toolkit's own chrome — the
//! refresh and `?` chips, the tab strip, the filter pill, a tree row
//! and its chevron, a build line, the PR row's buttons, the detail
//! panel, the scrollbar, the hint row, the key sheet — has ONE entry
//! here, so the same element reads the same in every pane; a pane adds
//! its own words only for what is its own (a Jira chip, a pipelines
//! page).

const std = @import("std");
const budget_mod = @import("../budget.zig");

/// One entry: a few words of title, a sentence or two of body, and —
/// when the element's click runs a command — that command's id, so the
/// host can end the entry with its `Key:` chord. The id is the pane's
/// own published one (`<integration>.<verb>`) or a host id; the host
/// spells the chord, so the pane never guesses at the user's profile.
pub const Help = struct {
    title: []const u8,
    body: []const u8 = "",
    command: ?[]const u8 = null,
    /// The row the element stands for, when it is one (`wire.RowRef`):
    /// what lets a right-click there carry other integrations' menu
    /// rows for its kind (docs/SDK.md, *Menu contributions*).
    row: ?@import("../wire.zig").RowRef = null,

    /// The same entry, naming the command its element's click runs.
    pub fn runs(h: Help, id: []const u8) Help {
        var out = h;
        out.command = id;
        return out;
    }
};

/// The toolkit's own elements.
pub const Common = enum {
    refresh,
    keys_chip,
    tab,
    filter,
    tree_row,
    list_row,
    chevron,
    show_more,
    build_line,
    open_button,
    review_button,
    merge_button,
    merge_blocked,
    confirm_ok,
    confirm_cancel,
    detail,
    detail_close,
    scrollbar,
    picker_row,
    menu_item,
    key_sheet,
};

pub fn common(c: Common) Help {
    return switch (c) {
        .refresh => .{ .title = "Refresh", .body = "Fetches this tab again; it turns while a fetch is out. A failed fetch keeps the rows it had and says why beside the title. Key: r." },
        .keys_chip => .{ .title = "Keys", .body = "Opens the key sheet: every key this pane answers to, by section. A row of the sheet runs what its key runs. Key: ?." },
        .tab => .{ .title = "Tab", .body = "One of this pane's listings. Click to switch; 1–9 and Tab / Shift+Tab do the same from the keyboard." },
        .filter => .{ .title = "Filter", .body = "Narrows the rows to the ones whose text matches what is typed; the header says how many of how many. Esc clears it. Key: /." },
        .tree_row => .{ .title = "Row", .body = "Click selects it; click again (or Enter / Space) folds it open or shut. Right / Left expand and collapse." },
        .list_row => .{ .title = "Row", .body = "Click selects it; Enter acts on it; o opens it on the web; right-click is the row's menu." },
        .chevron => .{ .title = "Fold", .body = "Folds this row open or shut without moving the selection. Right / Left from the keyboard." },
        .show_more => .{ .title = "Show more", .body = "The rows a cap or a filter hid. Click (or Enter) lifts it." },
        .build_line => .{ .title = "Build", .body = "One pipeline run on the commit this pull request is about — state, branch, age, number. Click opens that run's page." },
        .open_button => .{ .title = "Open", .body = "Opens this pull request's page in the browser." },
        .review_button => .{ .title = "Review", .body = "Starts a Claude Code review session on this pull request; the button turns while it runs and becomes `view` when it ends." },
        .merge_button => .{ .title = "Merge", .body = "Opens the merge confirm — source, target and strategy — and a confirmed merge runs as a Claude Code session. Only offered when the pull request may merge." },
        .merge_blocked => .{ .title = "Merge — not yet", .body = "Dim because the pull request may not merge yet; the line under the list says which condition does not hold." },
        .confirm_ok => .{ .title = "Confirm", .body = "Runs the action this box names. Enter does the same." },
        .confirm_cancel => .{ .title = "Cancel", .body = "Closes the box and does nothing. Esc does the same." },
        .detail => .{ .title = "Detail", .body = "The selected row, in full. The wheel scrolls it; it follows the cursor. Key: d." },
        .detail_close => .{ .title = "Close the detail", .body = "Closes the detail panel. Key: d, or Esc." },
        .scrollbar => .{ .title = "Scrollbar", .body = "Press or drag along it to move through the list." },
        .picker_row => .{ .title = "Choice", .body = "Click picks it (Space toggles one of several); type to narrow the list; Esc closes it." },
        .menu_item => .{ .title = "Menu entry", .body = "Runs this entry; the key beside it does the same from the list." },
        .key_sheet => .{ .title = "Key sheet", .body = "Every key this pane answers to. Click a row to run it; Esc closes the sheet." },
    };
}

/// The API budget chip: what the API says is left, this hour's calls,
/// the cache's hit ratio, the daily tally and the state (a pause, dry
/// run) — one entry, written into `buf`, the same on every pane.
pub fn budget(buf: []u8, snap: budget_mod.Snapshot) Help {
    return .{ .title = "API budget", .body = snap.helpBody(buf) };
}

/// A hint-row entry or a key-sheet row: the key and what it does. The
/// title is written into `buf`.
pub fn key(buf: []u8, key_label: []const u8, what: []const u8) Help {
    const title = std.fmt.bufPrint(buf, "{s} — {s}", .{ key_label, what }) catch what;
    return .{ .title = title, .body = "Click runs what the key runs. The hint row offers only the keys that do something here; `?` lists them all." };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "every common element has a title and a body, and none of them is the host's generic row" {
    inline for (@typeInfo(Common).@"enum".fields) |f| {
        const h = common(@field(Common, f.name));
        try testing.expect(h.title.len > 0 and h.title.len <= 40);
        try testing.expect(h.body.len > 0 and h.body.len <= 300);
        try testing.expect(std.mem.indexOf(u8, h.body, "pane row") == null);
    }
    var buf: [64]u8 = undefined;
    const k = key(&buf, "r", "refresh");
    try testing.expectEqualStrings("r — refresh", k.title);
}
