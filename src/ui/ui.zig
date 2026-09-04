//! src/ui — the render layer (D6): geometry and painting primitives on a
//! tty-free `vaxis.Screen`, the frame hit map, the theme, and every
//! component the app paints with. Components take a `Ui`, never `*App`.
//!
//! This barrel is the ui test root: `main.zig`'s `test {}` imports it, so
//! every module's tests run under `zig build test` on
//! `std.testing.allocator` (leak = failure).

pub const Rect = @import("rect.zig");
pub const color = @import("color.zig");
pub const Canvas = @import("canvas.zig");
pub const clip = @import("clip.zig");
pub const text = @import("text.zig");
pub const border = @import("border.zig");

pub const Theme = @import("theme.zig");
pub const hit = @import("hit.zig");
pub const HitMap = hit.HitMap;
pub const HitTarget = hit.HitTarget;
pub const ChipKind = hit.ChipKind;
pub const Ui = @import("context.zig");

pub const editor_view = @import("editor_view.zig");
pub const statusline = @import("statusline.zig");
pub const bufferline = @import("bufferline.zig");

pub const chip = @import("chip.zig");
pub const text_field = @import("text_field.zig");
pub const scrollbar = @import("scrollbar.zig");
pub const empty_state = @import("empty_state.zig");
pub const header = @import("header.zig");
pub const filter_input = @import("filter_input.zig");
pub const list_panel = @import("list_panel.zig");
pub const ListPanel = list_panel.ListPanel;

pub const fuzzy = @import("fuzzy.zig");
pub const overlay = @import("overlay.zig");
pub const prompt = @import("prompt.zig");
pub const Prompt = prompt;
pub const confirm = @import("confirm.zig");
pub const Confirm = confirm;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test_fixture.zig");
}
