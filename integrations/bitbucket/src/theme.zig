//! The pane's colours, in mnml's roles. `hello.palette` carries the
//! host theme's roles; a host that sends none (an older mnml, a theme
//! that leaves a role to the terminal) falls back to the 16-colour
//! palette, so the pane reads the same either way — just less native.

const std = @import("std");
const sdk = @import("mnml_sdk");

pub const Style = sdk.Style;
pub const Color = sdk.Color;

/// The pane's theme is the SDK's (`sdk.pane.Theme`) - one definition of
/// every role, shared with the Jira pane and with the sample, so a chip
/// at rest, a merged PR and a `Show more (N)` are the same colour in
/// every mnml integration. This module is the name this pane has always
/// called it by.
pub const Theme = sdk.pane.Theme;

// --- tests ---------------------------------------------------------------

const t = std.testing;

test "a hello without a palette paints with indices; one with it paints the theme" {
    const plain = Theme.fromHello(null);
    try t.expectEqual(Color{ .index = 6 }, plain.accent);
    try t.expect(plain.fg == null);
    const themed = Theme.fromHello(.{ .accent = .{ .rgb = .{ 97, 175, 239 } }, .fg = .{ .rgb = .{ 1, 2, 3 } } });
    try t.expectEqual(Color{ .rgb = .{ 97, 175, 239 } }, themed.accent);
    try t.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, themed.fg.?);
    try t.expectEqual(Color{ .index = 8 }, themed.muted);
    try t.expectEqual(themed.green, themed.prState("open").fg.?);
    try t.expectEqual(themed.red, themed.pipelineState("FAILED").fg.?);
}
