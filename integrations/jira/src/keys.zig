//! Keys → actions. One table, read in strict priority order: whatever
//! overlay is open answers first and answers completely, so a modal can
//! never leak a key to the list underneath. `Mode` says which arm runs.
//!
//! The chords are the Rust tracker's where it has one, and the family's
//! tree convention where the tracker has nothing (`→`/`←` expand and
//! collapse, Enter / Space toggle, `E` / `C` all, `x` hide, `H` unhide).

const std = @import("std");

pub const Mode = enum {
    /// The ticket list has the keys.
    list,
    /// The filter line is being typed.
    filter,
    /// A list overlay — transitions, assignees, versions, issue types.
    picker,
    /// A one-line prompt — the comment box, a create field.
    prompt,
    /// A yes / no.
    confirm,
    /// The help sheet.
    help,
};

pub const Action = union(enum) {
    none,
    quit,
    refresh,
    /// Rows, signed.
    move: i8,
    page: i8,
    top,
    bottom,
    expand,
    collapse,
    toggle_row,
    expand_all,
    collapse_all,
    hide_row,
    unhide_all,
    next_tab,
    prev_tab,
    /// 1-based, from the number keys.
    go_tab: u8,
    open_browser,
    copy_key,
    copy_url,
    transition,
    assign,
    assign_to_me,
    comment,
    create,
    set_fix_version,
    open_filter,
    toggle_detail,
    detail_scroll: i8,
    show_all_prs,
    help,
    /// Overlay verbs.
    accept,
    cancel,
    backspace,
    /// A printable code point typed into a filter / prompt / picker.
    insert: u21,
    /// Word-wise and line-wise editing in a prompt.
    kill_to_start,
    kill_to_end,
    delete_word_back,
    cursor_left,
    cursor_right,
    cursor_home,
    cursor_end,
    /// A prompt that takes more than one line.
    newline,
    /// `Tab` in the create form.
    next_field,
    prev_field,
};

/// `spec` is mnml's key grammar (`a`, `ctrl+p`, `enter`, `shift+f5`).
pub fn map(mode: Mode, spec_in: []const u8) Action {
    var upper: [1]u8 = undefined;
    const spec = normalise(spec_in, &upper);
    return switch (mode) {
        .help => helpKeys(spec),
        .confirm => confirmKeys(spec),
        .prompt => promptKeys(spec),
        .picker => pickerKeys(spec),
        .filter => filterKeys(spec),
        .list => listKeys(spec),
    };
}

/// `shift+h` and `H` are the same key, and which one arrives depends on
/// the terminal and on how the event was synthesised — a `.test`'s
/// `key H` is not a `type H`. Fold the shifted-letter form into the
/// letter so the table only ever spells it one way.
pub fn normalise(spec: []const u8, buf: *[1]u8) []const u8 {
    const prefix = "shift+";
    if (spec.len != prefix.len + 1) return spec;
    if (!std.mem.startsWith(u8, spec, prefix)) return spec;
    const c = spec[prefix.len];
    if (c < 'a' or c > 'z') return spec;
    buf[0] = std.ascii.toUpper(c);
    return buf[0..1];
}

fn helpKeys(spec: []const u8) Action {
    if (eq(spec, "esc") or eq(spec, "q") or eq(spec, "?") or eq(spec, "enter")) return .cancel;
    if (eq(spec, "down") or eq(spec, "j")) return .{ .move = 1 };
    if (eq(spec, "up") or eq(spec, "k")) return .{ .move = -1 };
    return .none;
}

fn confirmKeys(spec: []const u8) Action {
    if (eq(spec, "y") or eq(spec, "Y") or eq(spec, "enter")) return .accept;
    if (eq(spec, "n") or eq(spec, "N") or eq(spec, "esc") or eq(spec, "q")) return .cancel;
    return .none;
}

fn promptKeys(spec: []const u8) Action {
    if (eq(spec, "esc")) return .cancel;
    if (eq(spec, "ctrl+s")) return .accept;
    if (eq(spec, "enter")) return .newline;
    if (eq(spec, "tab")) return .next_field;
    if (eq(spec, "shift+tab")) return .prev_field;
    if (eq(spec, "backspace")) return .backspace;
    if (eq(spec, "ctrl+u")) return .kill_to_start;
    if (eq(spec, "ctrl+k")) return .kill_to_end;
    if (eq(spec, "ctrl+w") or eq(spec, "alt+backspace")) return .delete_word_back;
    if (eq(spec, "ctrl+a") or eq(spec, "home")) return .cursor_home;
    if (eq(spec, "ctrl+e") or eq(spec, "end")) return .cursor_end;
    if (eq(spec, "left")) return .cursor_left;
    if (eq(spec, "right")) return .cursor_right;
    return printable(spec);
}

fn pickerKeys(spec: []const u8) Action {
    if (eq(spec, "esc")) return .cancel;
    if (eq(spec, "enter")) return .accept;
    if (eq(spec, "down")) return .{ .move = 1 };
    if (eq(spec, "up")) return .{ .move = -1 };
    if (eq(spec, "pagedown")) return .{ .page = 1 };
    if (eq(spec, "pageup")) return .{ .page = -1 };
    if (eq(spec, "backspace")) return .backspace;
    // Digits jump; everything else printable filters, so `j`/`k` type.
    if (spec.len == 1 and spec[0] >= '1' and spec[0] <= '9') return .{ .go_tab = spec[0] - '0' };
    return printable(spec);
}

fn filterKeys(spec: []const u8) Action {
    if (eq(spec, "esc")) return .cancel;
    if (eq(spec, "enter")) return .accept;
    if (eq(spec, "backspace")) return .backspace;
    if (eq(spec, "ctrl+u")) return .kill_to_start;
    if (eq(spec, "ctrl+w")) return .delete_word_back;
    if (eq(spec, "left")) return .cursor_left;
    if (eq(spec, "right")) return .cursor_right;
    if (eq(spec, "home") or eq(spec, "ctrl+a")) return .cursor_home;
    if (eq(spec, "end") or eq(spec, "ctrl+e")) return .cursor_end;
    if (eq(spec, "down")) return .{ .move = 1 };
    if (eq(spec, "up")) return .{ .move = -1 };
    return printable(spec);
}

fn listKeys(spec: []const u8) Action {
    // Leaving.
    if (eq(spec, "q") or eq(spec, "ctrl+c")) return .quit;
    if (eq(spec, "esc")) return .cancel;
    // Moving.
    if (eq(spec, "down") or eq(spec, "j")) return .{ .move = 1 };
    if (eq(spec, "up") or eq(spec, "k")) return .{ .move = -1 };
    if (eq(spec, "pagedown") or eq(spec, "ctrl+f")) return .{ .page = 1 };
    if (eq(spec, "pageup") or eq(spec, "ctrl+b")) return .{ .page = -1 };
    if (eq(spec, "home") or eq(spec, "g")) return .top;
    if (eq(spec, "end") or eq(spec, "G")) return .bottom;
    // The tree.
    if (eq(spec, "right") or eq(spec, "l")) return .expand;
    if (eq(spec, "left") or eq(spec, "h")) return .collapse;
    if (eq(spec, "enter") or eq(spec, "space")) return .toggle_row;
    if (eq(spec, "E")) return .expand_all;
    if (eq(spec, "C")) return .collapse_all;
    if (eq(spec, "x")) return .hide_row;
    if (eq(spec, "H")) return .unhide_all;
    if (eq(spec, "P")) return .show_all_prs;
    // Tabs.
    if (eq(spec, "tab")) return .next_tab;
    if (eq(spec, "shift+tab") or eq(spec, "backtab")) return .prev_tab;
    if (spec.len == 1 and spec[0] >= '1' and spec[0] <= '9') return .{ .go_tab = spec[0] - '0' };
    // Actions.
    if (eq(spec, "r")) return .refresh;
    if (eq(spec, "o")) return .open_browser;
    if (eq(spec, "y")) return .copy_key;
    if (eq(spec, "Y")) return .copy_url;
    if (eq(spec, "t")) return .transition;
    if (eq(spec, "a")) return .assign;
    if (eq(spec, "m")) return .assign_to_me;
    if (eq(spec, "c")) return .comment;
    if (eq(spec, "n")) return .create;
    if (eq(spec, "f")) return .set_fix_version;
    if (eq(spec, "/")) return .open_filter;
    if (eq(spec, "d")) return .toggle_detail;
    if (eq(spec, "ctrl+d")) return .{ .detail_scroll = 4 };
    if (eq(spec, "ctrl+u")) return .{ .detail_scroll = -4 };
    if (eq(spec, "?")) return .help;
    return .none;
}

/// One printable code point, or nothing. `space` is its own spelling in
/// mnml's grammar; a modified key never types.
fn printable(spec: []const u8) Action {
    if (eq(spec, "space")) return .{ .insert = ' ' };
    if (std.mem.indexOfScalar(u8, spec, '+') != null) return .none;
    const view = std.unicode.Utf8View.init(spec) catch return .none;
    var it = view.iterator();
    const first = it.nextCodepoint() orelse return .none;
    if (it.nextCodepoint() != null) return .none; // a named key: `enter`, `f5`
    if (first < 0x20 or first == 0x7f) return .none;
    return .{ .insert = first };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The help sheet — one row per line, in the order it paints. Kept
/// beside the table so the two cannot drift.
pub const help_rows = [_][2][]const u8{
    .{ "j / k · ↓ / ↑", "move" },
    .{ "g / G", "first / last row" },
    .{ "l / h · → / ←", "expand / collapse (← from a leaf climbs)" },
    .{ "Enter · Space", "toggle the row" },
    .{ "E / C", "expand / collapse everything" },
    .{ "x / H", "hide the branch / unhide all" },
    .{ "P", "show every linked PR on this ticket" },
    .{ "Tab · 1–9", "switch tab" },
    .{ "r", "refresh this tab" },
    .{ "/", "filter" },
    .{ "d", "detail pane" },
    .{ "ctrl+d / ctrl+u", "scroll the detail pane" },
    .{ "o", "open in the browser" },
    .{ "y / Y", "copy the key / the URL" },
    .{ "t", "transition (asks first)" },
    .{ "a / m", "assign / assign to me" },
    .{ "f", "set the fix version" },
    .{ "c", "comment" },
    .{ "n", "new ticket" },
    .{ "?", "this sheet" },
    .{ "q", "close the pane" },
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the list keys: movement, the tree convention, the tabs, the actions" {
    try testing.expectEqual(Action.quit, map(.list, "q"));
    try testing.expectEqual(Action.quit, map(.list, "ctrl+c"));
    try testing.expectEqual(Action{ .move = 1 }, map(.list, "j"));
    try testing.expectEqual(Action{ .move = -1 }, map(.list, "up"));
    try testing.expectEqual(Action{ .page = 1 }, map(.list, "pagedown"));
    try testing.expectEqual(Action.top, map(.list, "g"));
    try testing.expectEqual(Action.bottom, map(.list, "G"));
    // The family's tree convention, both spellings of each.
    try testing.expectEqual(Action.expand, map(.list, "l"));
    try testing.expectEqual(Action.expand, map(.list, "right"));
    try testing.expectEqual(Action.collapse, map(.list, "h"));
    try testing.expectEqual(Action.collapse, map(.list, "left"));
    try testing.expectEqual(Action.toggle_row, map(.list, "enter"));
    try testing.expectEqual(Action.toggle_row, map(.list, "space"));
    try testing.expectEqual(Action.expand_all, map(.list, "E"));
    try testing.expectEqual(Action.collapse_all, map(.list, "C"));
    try testing.expectEqual(Action.hide_row, map(.list, "x"));
    try testing.expectEqual(Action.unhide_all, map(.list, "H"));
    try testing.expectEqual(Action.next_tab, map(.list, "tab"));
    try testing.expectEqual(Action{ .go_tab = 3 }, map(.list, "3"));
    try testing.expectEqual(Action.transition, map(.list, "t"));
    try testing.expectEqual(Action.assign_to_me, map(.list, "m"));
    try testing.expectEqual(Action.copy_key, map(.list, "y"));
    try testing.expectEqual(Action.copy_url, map(.list, "Y"));
    try testing.expectEqual(Action{ .detail_scroll = 4 }, map(.list, "ctrl+d"));
    // An unbound key is nothing, never an accidental insert.
    try testing.expectEqual(Action.none, map(.list, "f5"));
    try testing.expectEqual(Action.none, map(.list, "ctrl+z"));
    try testing.expectEqual(Action.none, map(.list, "z"));
}

test "a modal answers its own keys and never leaks one to the list" {
    // `j` types in a filter and a picker's filter, and moves in a list.
    try testing.expectEqual(Action{ .insert = 'j' }, map(.filter, "j"));
    try testing.expectEqual(Action{ .insert = 'j' }, map(.picker, "j"));
    try testing.expectEqual(Action{ .move = 1 }, map(.list, "j"));
    // `q` quits from the list but types in a prompt.
    try testing.expectEqual(Action.quit, map(.list, "q"));
    try testing.expectEqual(Action{ .insert = 'q' }, map(.prompt, "q"));
    // Esc is the way out of every modal.
    for ([_]Mode{ .filter, .picker, .prompt, .confirm, .help }) |m| {
        try testing.expectEqual(Action.cancel, map(m, "esc"));
    }
    // A confirm takes only y / n / Enter / Esc.
    try testing.expectEqual(Action.accept, map(.confirm, "y"));
    try testing.expectEqual(Action.accept, map(.confirm, "enter"));
    try testing.expectEqual(Action.cancel, map(.confirm, "n"));
    try testing.expectEqual(Action.none, map(.confirm, "x"));
    // Enter commits a filter and a picker, but makes a newline in the
    // comment prompt — which commits on ctrl+s.
    try testing.expectEqual(Action.accept, map(.filter, "enter"));
    try testing.expectEqual(Action.accept, map(.picker, "enter"));
    try testing.expectEqual(Action.newline, map(.prompt, "enter"));
    try testing.expectEqual(Action.accept, map(.prompt, "ctrl+s"));
}

test "a shifted letter is the same key as the capital, whichever spelling arrives" {
    try testing.expectEqual(Action.unhide_all, map(.list, "H"));
    try testing.expectEqual(Action.unhide_all, map(.list, "shift+h"));
    try testing.expectEqual(Action.expand_all, map(.list, "shift+e"));
    try testing.expectEqual(Action.collapse_all, map(.list, "shift+c"));
    try testing.expectEqual(Action.bottom, map(.list, "shift+g"));
    try testing.expectEqual(Action.copy_url, map(.list, "shift+y"));
    try testing.expectEqual(Action{ .insert = 'H' }, map(.filter, "shift+h"));
    // Only a single shifted letter folds; a named key keeps its spelling.
    try testing.expectEqual(Action.none, map(.list, "shift+f5"));
    try testing.expectEqual(Action.prev_tab, map(.list, "shift+tab"));
    var buf: [1]u8 = undefined;
    try testing.expectEqualStrings("shift+1", normalise("shift+1", &buf));
    try testing.expectEqualStrings("ctrl+h", normalise("ctrl+h", &buf));
}

test "printable: one code point types, a named or modified key does not" {
    try testing.expectEqual(Action{ .insert = 'a' }, map(.filter, "a"));
    try testing.expectEqual(Action{ .insert = 'A' }, map(.filter, "A"));
    try testing.expectEqual(Action{ .insert = ' ' }, map(.filter, "space"));
    try testing.expectEqual(Action{ .insert = '\u{00e9}' }, map(.filter, "é"));
    try testing.expectEqual(Action.none, map(.filter, "f5"));
    try testing.expectEqual(Action.none, map(.filter, "ctrl+x"));
    try testing.expectEqual(Action.none, map(.filter, "insert"));
    try testing.expectEqual(Action.none, map(.filter, ""));
}

test "a picker's digits jump to a row instead of typing" {
    try testing.expectEqual(Action{ .go_tab = 4 }, map(.picker, "4"));
    // `0` is not a jump, so it types.
    try testing.expectEqual(Action{ .insert = '0' }, map(.picker, "0"));
}

test "the prompt has readline editing, so a long comment is not append-only" {
    try testing.expectEqual(Action.kill_to_start, map(.prompt, "ctrl+u"));
    try testing.expectEqual(Action.kill_to_end, map(.prompt, "ctrl+k"));
    try testing.expectEqual(Action.delete_word_back, map(.prompt, "ctrl+w"));
    try testing.expectEqual(Action.delete_word_back, map(.prompt, "alt+backspace"));
    try testing.expectEqual(Action.cursor_home, map(.prompt, "ctrl+a"));
    try testing.expectEqual(Action.cursor_end, map(.prompt, "end"));
    try testing.expectEqual(Action.cursor_left, map(.prompt, "left"));
    try testing.expectEqual(Action.next_field, map(.prompt, "tab"));
    try testing.expectEqual(Action.prev_field, map(.prompt, "shift+tab"));
}

test "every help row names a chord the table actually answers" {
    for (help_rows) |row| {
        // Take the first spelling of the chord — `j / k · ↓ / ↑` → `j`.
        var it = std.mem.splitAny(u8, row[0], " /·");
        const first = it.next().?;
        if (first.len == 0) continue;
        if (std.mem.eql(u8, first, "Enter")) continue; // spelled `enter`
        if (std.mem.eql(u8, first, "Tab")) continue; // spelled `tab`
        if (std.mem.eql(u8, first, "1–9")) continue;
        try testing.expect(map(.list, first) != .none);
    }
}
