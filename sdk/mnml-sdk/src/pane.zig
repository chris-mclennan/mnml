//! The pane toolkit — mnml's panel chrome, so an integration paints a
//! pane that belongs in mnml rather than one transplanted from a web UI,
//! and so two integrations cannot drift apart into two design languages.
//!
//!   theme   the host theme's roles (`hello.palette`), the integration's
//!           own brand colour, and the state colours a PR, a pipeline or
//!           a ticket status paints in
//!   hit     the click map, generic over the pane's own target union
//!   chrome  `Painter` — the caps header and its chip ladder, the tab
//!           strip, the filter pill, the app-colour left gutter, the row
//!           ground, `Show more (N)`, a detail panel with its `×` and
//!           scrollbar, and the hint row where every entry is a hit
//!   text    widths and fitting, counted the way `Frame` paints
//!   figure  what a statusline segment is allowed to say — one named
//!           figure, and a bracketed subset only when the pane has one
//!   expect  what an integration's OWN tests assert about the chrome
//!           it painted — the check that a pane CALLS the toolkit,
//!           which the toolkit's self-consistency cannot show
//!   work    the one-job channel a pane refetches through, so a slow
//!           fetch never freezes its keys or its repaint
//!   build   the build lines under a pull-request row — one pipeline
//!           run each, `state · branch · age · #n`
//!   merge   whether a pull request may merge, the dim button that
//!           says which condition does not hold, and the Claude Code
//!           session a press dispatches
//!   action  a row's action button and what a press leaves behind on
//!           it — the spinner it turns while its session runs, the
//!           `⏸` when that session stops to ask something, the `view`
//!           it becomes when it ends, the ✗ it wears when it failed
//!
//! Ten lines put a pane in mnml's chrome:
//!
//! ```zig
//! const Target = union(enum) { row: u32, filter, quit };
//! var hits: sdk.pane.HitMap(Target) = .{};
//! var p: sdk.pane.Painter(Target) = .{ .f = &frame, .gpa = gpa, .arena = arena,
//!     .hits = &hits, .th = sdk.pane.Theme.fromHelloBranded(hello.palette, "teal"),
//!     .ui = .{ .nerd = hello.capabilities.nerd_font } };
//! _ = p.capsTitle(2, 0, "SAMPLE", "  (5)");
//! try p.filterPill(.{ .x = 2, .y = 1, .w = frame.cols - 3, .h = 1 }, q, q.len, editing, .filter);
//! p.gutter(.{ .x = 0, .y = 0, .w = 1, .h = frame.rows - 1 }, cursor_y);
//! try p.rowGround(.{ .x = 0, .y = y, .w = frame.cols, .h = 1 }, y == cursor_y, .{ .row = i });
//! try p.hintRow(frame.rows - 1, status, &.{.{ .key = "q", .title = "quit", .target = .quit }});
//! ```

const hit = @import("pane/hit.zig");

pub const theme = @import("pane/theme.zig");
pub const work = @import("pane/work.zig");
pub const action = @import("pane/action.zig");
pub const build = @import("pane/build.zig");
pub const merge = @import("pane/merge.zig");
pub const chrome = @import("pane/chrome.zig");
pub const text = @import("pane/text.zig");
/// What a statusline segment is allowed to say: one named figure, and
/// a bracketed subset only when the pane genuinely has one.
pub const figure = @import("pane/figure.zig");
/// The assertions an integration's own tests make about the shared
/// chrome, so two families check one expectation rather than two.
pub const expect = @import("pane/expect.zig");

pub const Theme = theme.Theme;
pub const Rect = hit.Rect;
pub const HitMap = hit.Map;
pub const Painter = chrome.Painter;
pub const Chip = chrome.Chip;
pub const Hint = chrome.Hint;
pub const Tab = chrome.Tab;
pub const Ui = chrome.Ui;
pub const asciiFromEnv = chrome.asciiFromEnv;
pub const width = text.width;
pub const fit = text.fit;
pub const scrollAt = chrome.scrollAt;
/// The cells one build line's click covers — the whole line, so a pane
/// that paints its build line as a table cell registers the same door.
pub const buildHit = hit.buildHit;
pub const Slot = work.Slot;
pub const BuildRun = build.Run;
pub const Readiness = merge.Readiness;
pub const MergeStrategy = merge.Strategy;
pub const buildCaption = build.caption;
pub const Figure = figure.Figure;
pub const figureText = figure.text;
pub const ActionState = action.State;
pub const ActionStore = action.Store;
pub const actionStateOf = action.fromSessionState;
pub const actionWatchKey = action.watchKey;

test {
    _ = hit;
    _ = theme;
    _ = chrome;
    _ = text;
    _ = work;
    _ = action;
    _ = build;
    _ = merge;
    _ = figure;
    _ = expect;
    // The anti-drift test: the shared elements painted from two panes'
    // target vocabularies must come out cell for cell identical.
    _ = @import("pane/consistency_test.zig");
}
